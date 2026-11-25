--!strict
local Worker = {}
local Client = {}
Client.__index = Client

local MAX_BATCH_MESSAGES = 32

type ClientType = {
	_stream: any,
	_group: string,
	_partition: number,
	_owner_token: string,
	_handler: (any, any) -> (boolean, string?),
	_lease_seconds: number,
	_batch_size: number,
	_min_poll_delay: number,
	_max_poll_delay: number,
	_jitter_fraction: number,
	_backoff: number,
	_claim: any,
	_running: boolean,
	_inflight: boolean,
	_wake_pending: boolean,
	_scheduled: boolean,
	_schedule_generation: number,
	_heartbeat_generation: number,
	_heartbeat_busy: boolean,
	_schedule: (number, () -> ()) -> (),
	_defer: (() -> ()) -> (),
	_random: () -> number,
	_on_result: ((any) -> ())?,
	_on_error: ((string) -> ())?,
	Start: (self: ClientType) -> any,
	Wake: (self: ClientType) -> any,
	StopAsync: (self: ClientType) -> any,
	GetStatus: (self: ClientType) -> any,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value: any, maximum: number): boolean
	return type(value) == "string" and #value > 0 and #value <= maximum
end

local function integer_at_least(value: any, minimum: number): boolean
	return finite(value) and math.floor(value) == value and value >= minimum
end

local function notify_result(self: ClientType, result: any)
	if self._on_result ~= nil then
		local ok, callback_error = pcall(self._on_result, result)
		if not ok and self._on_error ~= nil then
			pcall(self._on_error, tostring(callback_error))
		end
	end
end

local function cancel_poll(self: ClientType)
	self._schedule_generation += 1
	self._scheduled = false
end

local function cancel_heartbeat(self: ClientType)
	self._heartbeat_generation += 1
end

local function schedule_poll(self: ClientType, delay_seconds: number)
	if not self._running or self._scheduled then
		return
	end
	self._schedule_generation += 1
	local generation = self._schedule_generation
	self._scheduled = true
	local ok, schedule_error = pcall(self._schedule, delay_seconds, function()
		if not self._running or not self._scheduled or generation ~= self._schedule_generation then
			return
		end
		self._scheduled = false
		self._defer(function()
			self:_Poll()
		end)
	end)
	if not ok then
		self._scheduled = false
		if self._on_error ~= nil then
			pcall(self._on_error, "poll scheduling failed: " .. tostring(schedule_error))
		end
	end
end

local function next_backoff(self: ClientType, worked: boolean): number
	if worked then
		self._backoff = self._min_poll_delay
	else
		self._backoff = math.min(self._max_poll_delay, math.max(self._min_poll_delay, self._backoff * 2))
	end
	local random_value = self._random()
	if not finite(random_value) then
		random_value = 0.5
	end
	random_value = math.clamp(random_value, 0, 1)
	local factor = 1 + ((random_value * 2) - 1) * self._jitter_fraction
	return math.clamp(self._backoff * factor, self._min_poll_delay, self._max_poll_delay)
end

local function schedule_heartbeat(self: ClientType, claim: any)
	if not self._running or self._claim ~= claim then
		return
	end
	self._heartbeat_generation += 1
	local generation = self._heartbeat_generation
	local ok, schedule_error = pcall(self._schedule, self._lease_seconds / 3, function()
		if not self._running or generation ~= self._heartbeat_generation or self._claim ~= claim then
			return
		end
		self._defer(function()
			if not self._running or generation ~= self._heartbeat_generation or self._claim ~= claim or self._heartbeat_busy then
				return
			end
			self._heartbeat_busy = true
			local success, result = pcall(function()
				return self._stream:RenewConsumerAsync(claim)
			end)
			self._heartbeat_busy = false
			if not success or type(result) ~= "table" or result.code ~= "renewed" then
				self._claim = nil
				cancel_heartbeat(self)
				if self._on_error ~= nil then
					pcall(self._on_error, "consumer lease renewal was not confirmed: " .. tostring(if success then result and result.message or result and result.code else result))
				end
				self:Wake()
				return
			end
			schedule_heartbeat(self, claim)
		end)
	end)
	if not ok and self._on_error ~= nil then
		pcall(self._on_error, "heartbeat scheduling failed: " .. tostring(schedule_error))
	end
end

function Worker.Open(
	stream: any,
	group: string,
	partition: number,
	owner_token: string,
	handler: (any, any) -> (boolean, string?),
	raw_options: any?
): (ClientType?, string?)
	if stream == nil
		or type(stream.ClaimConsumerAsync) ~= "function"
		or type(stream.RenewConsumerAsync) ~= "function"
		or type(stream.ConsumeBatchAsync) ~= "function"
		or type(stream.ReleaseConsumerAsync) ~= "function"
	then
		return nil, "durable stream does not expose the consumer lease and batch APIs"
	end
	if not valid_text(group, 96) then
		return nil, "group must be 1..96 bytes"
	end
	if not integer_at_least(partition, 1) then
		return nil, "partition must be a positive integer"
	end
	if not valid_text(owner_token, 128) then
		return nil, "owner_token must be 1..128 bytes and unique to this worker incarnation"
	end
	if type(handler) ~= "function" then
		return nil, "handler must be a function"
	end
	if raw_options ~= nil and type(raw_options) ~= "table" then
		return nil, "options must be a table"
	end
	local options = raw_options or {}
	local lease_seconds = options.lease_seconds or 30
	local stream_batch_limit = if type(stream._options) == "table" and integer_at_least(stream._options.max_batch_messages, 1)
		then math.min(stream._options.max_batch_messages, MAX_BATCH_MESSAGES)
		else MAX_BATCH_MESSAGES
	local batch_size = options.batch_size or stream_batch_limit
	local max_poll_delay = options.max_poll_delay or math.min(5, lease_seconds / 3)
	local min_poll_delay = options.min_poll_delay or math.min(0.1, max_poll_delay)
	local jitter_fraction = if options.jitter_fraction == nil then 0.2 else options.jitter_fraction
	local schedule = options.schedule
	local defer = options.defer
	local random = options.random or math.random
	local on_result = options.on_result
	local on_error = options.on_error
	if not integer_at_least(lease_seconds, 5) or lease_seconds > 120 then
		return nil, "lease_seconds must be 5..120"
	end
	if not integer_at_least(batch_size, 1) or batch_size > stream_batch_limit then
		return nil, "batch_size exceeds the configured durable-stream batch limit"
	end
	if not finite(min_poll_delay) or min_poll_delay < 0.01 or not finite(max_poll_delay)
		or max_poll_delay < min_poll_delay or max_poll_delay > lease_seconds / 3
	then
		return nil, "poll delay bounds must satisfy 0.01 <= min <= max <= lease_seconds / 3"
	end
	if not finite(jitter_fraction) or jitter_fraction < 0 or jitter_fraction > 0.5 then
		return nil, "jitter_fraction must be 0..0.5"
	end
	if schedule ~= nil and type(schedule) ~= "function" then
		return nil, "schedule must be a function"
	end
	if defer ~= nil and type(defer) ~= "function" then
		return nil, "defer must be a function"
	end
	if type(random) ~= "function" then
		return nil, "random must be a function"
	end
	if on_result ~= nil and type(on_result) ~= "function" then
		return nil, "on_result must be a function"
	end
	if on_error ~= nil and type(on_error) ~= "function" then
		return nil, "on_error must be a function"
	end
	local selected_schedule = schedule or function(delay_seconds: number, callback: () -> ())
		task.delay(delay_seconds, callback)
	end
	local selected_defer = defer or function(callback: () -> ())
		task.defer(callback)
	end
	local client: any = {
		_stream = stream,
		_group = group,
		_partition = partition,
		_owner_token = owner_token,
		_handler = handler,
		_lease_seconds = lease_seconds,
		_batch_size = batch_size,
		_min_poll_delay = min_poll_delay,
		_max_poll_delay = max_poll_delay,
		_jitter_fraction = jitter_fraction,
		_backoff = min_poll_delay,
		_claim = nil,
		_running = false,
		_inflight = false,
		_wake_pending = false,
		_scheduled = false,
		_schedule_generation = 0,
		_heartbeat_generation = 0,
		_heartbeat_busy = false,
		_schedule = selected_schedule,
		_defer = selected_defer,
		_random = random,
		_on_result = on_result,
		_on_error = on_error,
	}
	return setmetatable(client, Client) :: ClientType, nil
end

function Client.GetStatus(self: ClientType): any
	return {
		running = self._running,
		inflight = self._inflight,
		claimed = self._claim ~= nil,
		backoff_seconds = self._backoff,
		scheduled = self._scheduled,
	}
end

function Client.Start(self: ClientType): any
	if self._running then
		return { code = "started", already_running = true }
	end
	if self._inflight then
		return { code = "busy", message = "previous poll has not finished" }
	end
	self._running = true
	self._backoff = self._min_poll_delay
	schedule_poll(self, 0)
	return { code = "started" }
end

function Client.Wake(self: ClientType): any
	if not self._running then
		return { code = "stopped" }
	end
	if self._inflight then
		self._wake_pending = true
		return { code = "coalesced" }
	end
	self._wake_pending = false
	self._backoff = self._min_poll_delay
	cancel_poll(self)
	schedule_poll(self, 0)
	return { code = "scheduled" }
end

function Client._Poll(self: ClientType)
	if not self._running or self._inflight then
		return
	end
	self._inflight = true
	local ok, result = pcall(function()
		local claim = self._claim
		if claim == nil then
			local claimed = self._stream:ClaimConsumerAsync(
				self._group,
				self._partition,
				self._owner_token,
				self._lease_seconds
			)
			if type(claimed) ~= "table" or claimed.code ~= "claimed" then
				return claimed
			end
			claim = claimed.claim
			self._claim = claim
			schedule_heartbeat(self, claim)
		end
		if not self._running then
			return { code = "stopping" }
		end
		return self._stream:ConsumeBatchAsync(claim, self._handler, self._batch_size)
	end)
	if not ok then
		result = { code = "unknown", message = tostring(result) }
	elseif type(result) ~= "table" then
		result = { code = "unknown", message = "consumer API returned a malformed result" }
	end
	if result.code == "fenced" or result.code == "expired" or result.code == "removed" or result.code == "invalid" then
		self._claim = nil
		cancel_heartbeat(self)
	end
	self._inflight = false
	notify_result(self, result)
	if not self._running then
		if self._claim ~= nil then
			local release_ok, release_result = pcall(function()
				return self._stream:ReleaseConsumerAsync(self._claim)
			end)
			if not release_ok or type(release_result) ~= "table"
				or (release_result.code ~= "released" and release_result.code ~= "fenced")
			then
				if self._on_error ~= nil then
					pcall(self._on_error, "consumer stop could not confirm lease release: " .. tostring(if release_ok then release_result and release_result.message or release_result and release_result.code else release_result))
				end
			end
			self._claim = nil
		end
		cancel_heartbeat(self)
		return
	end
	if self._wake_pending then
		self._wake_pending = false
		self._backoff = self._min_poll_delay
		schedule_poll(self, 0)
		return
	end
	local worked = result.code == "committed" and (result.count or 0) > 0
	local delay_seconds = next_backoff(self, worked)
	schedule_poll(self, delay_seconds)
end

function Client.StopAsync(self: ClientType): any
	if not self._running and self._claim == nil then
		return { code = "stopped" }
	end
	self._running = false
	self._wake_pending = false
	cancel_poll(self)
	cancel_heartbeat(self)
	if self._inflight then
		return { code = "stopping" }
	end
	if self._claim == nil then
		return { code = "stopped" }
	end
	local ok, result = pcall(function()
		return self._stream:ReleaseConsumerAsync(self._claim)
	end)
	if not ok or type(result) ~= "table" then
		return { code = "unknown", message = tostring(result) }
	end
	if result.code == "released" or result.code == "fenced" then
		self._claim = nil
		return { code = "stopped", release = result }
	end
	return { code = result.code or "unknown", message = result.message }
end

return table.freeze(Worker)
