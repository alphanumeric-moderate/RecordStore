--!nocheck
-- Server-local advanced scheduler. Queue selection is advisory; durable state,
-- session fencing and idempotency remain authoritative.
local Scheduler = {}

local function finite(value)
	return type(value) == "number" and math.isfinite(value)
end

local function valid_text(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function bounded_integer(value, default_value, minimum, maximum)
	local selected = if finite(value) then value else default_value
	return math.clamp(math.floor(selected), minimum, maximum)
end

local function key_count(value)
	local count = 0
	for _ in pairs(value) do count += 1 end
	return count
end

local function copy(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > 64 then error("scheduler value exceeds maximum depth", 3) end
	if type(value) ~= "table" then return value end
	if seen[value] then error("scheduler does not accept cyclic values", 3) end
	seen[value] = true
	local result = {}
	for key, child in pairs(value) do
		result[copy(key, depth + 1, seen)] = copy(child, depth + 1, seen)
	end
	seen[value] = nil
	return result
end

local dirty_seen = setmetatable({}, { __mode = "k" })

local function new_governor(options)
	options = options or {}
	local function now_ms()
		return if type(options.now_ms) == "function" then options.now_ms() else os.clock() * 1000
	end
	local governor = {
		policy = {
			revision = 1, mode = "normal", max_in_flight = 32, critical_reserve = 4,
			queue_capacity = 1024, max_batch = 16, batch_window_ms = 5,
			batch_latency_ceiling_ms = 40, high_burst = 4, retry_token_capacity = 32,
			retry_tokens_per_second = 4, minimum_budget = 2, circuit_threshold = 5, circuit_cooldown_ms = 15000,
			max_scheduled_in_flight = 8, scheduler_critical_reserve = 1, max_per_owner_in_flight = 2,
			drr_quantum = 4, max_item_cost = 64, urgent_deadline_burst = 4,
			priority_inheritance_max_ms = 1000, retry_jitter_percent = 20,
			algorithm = "drr", shadow_algorithm = "weighted", shadow_enabled = false, shadow_sample_rate = 0,
		},
		in_flight = 0, by_class = {}, queue = {}, due = {}, due_heap = {}, queued_due_heap = {},
		completed = {}, completed_order = {}, known = {}, active_owner = {}, active_renewals_by_owner = {},
		drr_deficit = {}, drr_cursor_key = nil, high_streak = 0, urgent_streak = 0,
		failed = {}, failed_order = {}, retry_cooldown_until = {}, retry_tokens_by_class = {},
		due_sequence = 0,
		retry_tokens = 32, last_token_time = now_ms(),
		last_budget = nil, last_budget_by_kind = {}, latency_ewma = {}, consecutive_errors = {}, circuits = {},
		stats = { admitted = 0, rejected = 0, completed = 0, throttled = 0, errors = 0,
			scheduled_selected = 0, scheduled_expired = 0, scheduled_overdue = 0, shadow_samples = 0 },
		scheduler_metrics = { by_lane = {}, wait_ms = {}, last_shadow = nil },
	}
	local limits = { critical = 32, profile_save = 32, profile_release = 32, interactive = 24, messaging = 20, migration = 4, maintenance = 2, tracing = 1 }
	local function policy_valid(policy)
		if type(policy) ~= "table" then return false, "policy must be a table" end
		local fields = { "revision", "max_in_flight", "critical_reserve", "queue_capacity", "max_batch", "batch_window_ms", "batch_latency_ceiling_ms", "high_burst", "retry_token_capacity", "retry_tokens_per_second", "minimum_budget", "circuit_threshold", "circuit_cooldown_ms", "max_scheduled_in_flight", "scheduler_critical_reserve", "max_per_owner_in_flight", "drr_quantum", "max_item_cost", "urgent_deadline_burst", "priority_inheritance_max_ms", "retry_jitter_percent", "shadow_sample_rate" }
		for _, field in ipairs(fields) do if not finite(policy[field]) then return false, "policy." .. field .. " must be finite" end end
		if policy.mode ~= "normal" and policy.mode ~= "reject_noncritical" and policy.mode ~= "bounded_buffer" and policy.mode ~= "read_only" then return false, "invalid degraded mode" end
		if policy.algorithm ~= "drr" and policy.algorithm ~= "weighted" and policy.algorithm ~= "fifo" and policy.algorithm ~= "deadline" then return false, "invalid scheduler algorithm" end
		if policy.shadow_algorithm ~= "drr" and policy.shadow_algorithm ~= "weighted" and policy.shadow_algorithm ~= "fifo" and policy.shadow_algorithm ~= "deadline" then return false, "invalid shadow scheduler algorithm" end
		if type(policy.shadow_enabled) ~= "boolean" then return false, "shadow_enabled must be boolean" end
		if policy.revision < 1 or math.floor(policy.revision) ~= policy.revision then return false, "revision must be positive integer" end
		if policy.max_in_flight < 1 or policy.max_in_flight > 256 or math.floor(policy.max_in_flight) ~= policy.max_in_flight then return false, "invalid max_in_flight" end
		if policy.critical_reserve < 0 or policy.critical_reserve >= policy.max_in_flight
			or math.floor(policy.critical_reserve) ~= policy.critical_reserve
		then
			return false, "critical_reserve must be an integer below max_in_flight"
		end
		if policy.queue_capacity < 1 or policy.queue_capacity > 8192 or math.floor(policy.queue_capacity) ~= policy.queue_capacity then return false, "invalid queue_capacity" end
		if policy.max_batch < 1 or policy.max_batch > 16 or math.floor(policy.max_batch) ~= policy.max_batch then return false, "invalid max_batch" end
		if policy.batch_window_ms < 0 or policy.batch_window_ms > 50 or policy.batch_latency_ceiling_ms < 1 or policy.batch_latency_ceiling_ms > 500 then return false, "invalid batch latency policy" end
		if policy.high_burst < 1 or policy.high_burst > 64 or math.floor(policy.high_burst) ~= policy.high_burst then
			return false, "high_burst must be an integer from 1 to 64"
		end
		if policy.minimum_budget < 0 or policy.minimum_budget > 100000 or math.floor(policy.minimum_budget) ~= policy.minimum_budget then
			return false, "minimum_budget must be an integer from 0 to 100000"
		end
		if policy.retry_token_capacity < 1 or policy.retry_token_capacity > 256 or math.floor(policy.retry_token_capacity) ~= policy.retry_token_capacity
			or policy.retry_tokens_per_second < 0 or policy.retry_tokens_per_second > 128
		then
			return false, "invalid retry policy"
		end
		if policy.circuit_threshold < 1 or policy.circuit_threshold > 100 or math.floor(policy.circuit_threshold) ~= policy.circuit_threshold then
			return false, "circuit_threshold must be an integer from 1 to 100"
		end
		if policy.circuit_cooldown_ms < 100 or policy.circuit_cooldown_ms > 600000 or math.floor(policy.circuit_cooldown_ms) ~= policy.circuit_cooldown_ms then
			return false, "circuit_cooldown_ms must be an integer from 100 to 600000"
		end
		if policy.max_scheduled_in_flight < 1 or policy.max_scheduled_in_flight > 64 or math.floor(policy.max_scheduled_in_flight) ~= policy.max_scheduled_in_flight then return false, "invalid max_scheduled_in_flight" end
		if policy.scheduler_critical_reserve < 0 or policy.scheduler_critical_reserve >= policy.max_scheduled_in_flight or math.floor(policy.scheduler_critical_reserve) ~= policy.scheduler_critical_reserve then return false, "scheduler_critical_reserve must be below max_scheduled_in_flight" end
		if policy.max_per_owner_in_flight < 1 or policy.max_per_owner_in_flight > 16 or math.floor(policy.max_per_owner_in_flight) ~= policy.max_per_owner_in_flight then return false, "invalid max_per_owner_in_flight" end
		if policy.drr_quantum < 1 or policy.drr_quantum > 32 or math.floor(policy.drr_quantum) ~= policy.drr_quantum then return false, "drr_quantum must be an integer from 1 to 32" end
		if policy.max_item_cost < 1 or policy.max_item_cost > 256 or math.floor(policy.max_item_cost) ~= policy.max_item_cost then return false, "max_item_cost must be an integer from 1 to 256" end
		if policy.urgent_deadline_burst < 1 or policy.urgent_deadline_burst > 64 or math.floor(policy.urgent_deadline_burst) ~= policy.urgent_deadline_burst then return false, "invalid urgent_deadline_burst" end
		if policy.priority_inheritance_max_ms < 10 or policy.priority_inheritance_max_ms > 60000 or math.floor(policy.priority_inheritance_max_ms) ~= policy.priority_inheritance_max_ms then return false, "invalid priority_inheritance_max_ms" end
		if policy.retry_jitter_percent < 0 or policy.retry_jitter_percent > 50 then return false, "retry_jitter_percent must be 0..50" end
		if policy.shadow_sample_rate < 0 or policy.shadow_sample_rate > 1 then return false, "shadow_sample_rate must be in 0..1" end
		return true, nil
	end
	function governor:SetPolicy(patch)
		if type(patch) ~= "table" or not finite(patch.revision) or patch.revision <= self.policy.revision then return false, "policy revision must increase" end
		local allowed = {
			revision = true, mode = true, max_in_flight = true, critical_reserve = true, queue_capacity = true,
			max_batch = true, batch_window_ms = true, batch_latency_ceiling_ms = true, high_burst = true,
			retry_token_capacity = true, retry_tokens_per_second = true, minimum_budget = true,
			circuit_threshold = true, circuit_cooldown_ms = true,
			max_scheduled_in_flight = true, scheduler_critical_reserve = true, max_per_owner_in_flight = true,
			drr_quantum = true, max_item_cost = true, urgent_deadline_burst = true,
			priority_inheritance_max_ms = true, retry_jitter_percent = true,
			algorithm = true, shadow_algorithm = true, shadow_enabled = true, shadow_sample_rate = true,
		}
		for key in pairs(patch) do
			if not allowed[key] then return false, "unsupported scheduler policy field: " .. tostring(key) end
		end
		local next_policy = copy(self.policy)
		for key, value in pairs(patch) do next_policy[key] = value end
		local valid, message = policy_valid(next_policy)
		if not valid then return false, message end
		self.policy = next_policy
		self.retry_tokens = math.min(self.retry_tokens, self.policy.retry_token_capacity)
		return true, nil
	end
	function governor:Observe(kind, ok, latency_ms, error_class, budget)
		if type(kind) ~= "string" or kind == "" then return false end
		if finite(latency_ms) and latency_ms >= 0 then
			local prior = self.latency_ewma[kind]
			self.latency_ewma[kind] = prior and prior * 0.8 + latency_ms * 0.2 or latency_ms
		end
		if finite(budget) then
			self.last_budget = budget
			self.last_budget_by_kind[kind] = budget
		end
		if ok then
			self.consecutive_errors[kind] = 0
			if self.circuits[kind] and self.circuits[kind].state == "half_open" then self.circuits[kind] = { state = "closed" } end
		else
			self.stats.errors += 1
			self.consecutive_errors[kind] = (self.consecutive_errors[kind] or 0) + 1
			if error_class == "throttled" or error_class == "budget" then self.stats.throttled += 1 end
			if self.consecutive_errors[kind] >= self.policy.circuit_threshold then self.circuits[kind] = { state = "open", until_ms = now_ms() + self.policy.circuit_cooldown_ms, reason = error_class or "repeated_failure" } end
		end
		return true
	end
	function governor:Admit(work_class, request_kind, cost, mutating)
		work_class, request_kind, cost = work_class or "interactive", request_kind or "default", cost or 1
		if not finite(cost) or math.floor(cost) ~= cost or cost < 1 then return { code = "invalid" } end
		local critical = work_class == "critical" or work_class == "profile_save" or work_class == "profile_release"
		if self.policy.mode == "read_only" and mutating and not critical then self.stats.rejected += 1; return { code = "read_only" } end
		if self.policy.mode == "reject_noncritical" and not critical then self.stats.rejected += 1; return { code = "backpressure" } end
		local circuit = self.circuits[request_kind]
		local probe_needed = false
		if circuit and circuit.state == "open" then
			if now_ms() < circuit.until_ms then return { code = "circuit_open", retry_after_ms = circuit.until_ms - now_ms(), reason = circuit.reason } end
			probe_needed = true
		elseif circuit and circuit.state == "half_open" then
			if circuit.probe then return { code = "circuit_open", reason = "half-open probe already reserved" } end
			probe_needed = true
		end
		local observed_budget = self.last_budget_by_kind[request_kind]
		if finite(observed_budget) and observed_budget < self.policy.minimum_budget and not critical then
			self.stats.rejected += 1
			return { code = "backpressure", message = "request budget is below configured minimum" }
		end
		if self.in_flight + cost > self.policy.max_in_flight then self.stats.rejected += 1; return { code = "capacity" } end
		if not critical and self.in_flight + cost > self.policy.max_in_flight - self.policy.critical_reserve then self.stats.rejected += 1; return { code = "backpressure", message = "critical save/release reserve protected" } end
		if (self.by_class[work_class] or 0) + cost > math.min(limits[work_class] or limits.interactive, self.policy.max_in_flight) then self.stats.rejected += 1; return { code = "capacity", message = "work-class cap reached" } end
		if probe_needed and circuit ~= nil then
			circuit.state = "half_open"
			circuit.probe = true
		end
		self.in_flight += cost
		self.by_class[work_class] = (self.by_class[work_class] or 0) + cost
		self.stats.admitted += 1
		return {
			code = "admitted",
			ticket = tostring(self.policy.revision) .. ":" .. tostring(self.stats.admitted),
			cost = cost,
			work_class = work_class,
			request_kind = request_kind,
			probe = probe_needed,
		}
	end
	function governor:Release(ticket)
		if type(ticket) ~= "table" or ticket.code ~= "admitted" then return false end
		self.in_flight = math.max(0, self.in_flight - (ticket.cost or 1))
		self.by_class[ticket.work_class] = math.max(0, (self.by_class[ticket.work_class] or 0) - (ticket.cost or 1))
		local circuit = self.circuits[ticket.request_kind]
		if ticket.probe == true and circuit ~= nil and circuit.state == "half_open" and circuit.probe == true then
			-- Core admission can fail after the advanced governor reserved this probe.
			-- If no outcome was observed, release the probe reservation for the next attempt.
			circuit.probe = false
		end
		self.stats.completed += 1
		return true
	end
	function governor:AcquireRetryToken(work_class)
		local now = now_ms()
		self.retry_tokens = math.min(self.policy.retry_token_capacity, self.retry_tokens + math.max(0, now - self.last_token_time) / 1000 * self.policy.retry_tokens_per_second)
		self.last_token_time = now
		if self.retry_tokens < 1 then
			return false, if self.policy.retry_tokens_per_second > 0 then math.ceil((1 - self.retry_tokens) / self.policy.retry_tokens_per_second * 1000) else math.huge
		end
		local class = if valid_text(work_class, 64) then work_class else "default"
		local bucket = self.retry_tokens_by_class[class]
		if bucket == nil then
			if key_count(self.retry_tokens_by_class) >= 32 then
				local oldest_key, oldest_time = nil, math.huge
				for bucket_key, bucket_value in pairs(self.retry_tokens_by_class) do
					if bucket_value.at_ms < oldest_time then oldest_key, oldest_time = bucket_key, bucket_value.at_ms end
				end
				if oldest_key ~= nil then self.retry_tokens_by_class[oldest_key] = nil end
			end
			bucket = { tokens = math.max(1, math.floor(self.policy.retry_token_capacity / 4)), at_ms = now }
			self.retry_tokens_by_class[class] = bucket
		end
		local capacity = math.max(1, math.floor(self.policy.retry_token_capacity / 4))
		local refill = self.policy.retry_tokens_per_second / 4
		bucket.tokens = math.min(capacity, bucket.tokens + math.max(0, now - bucket.at_ms) / 1000 * refill)
		bucket.at_ms = now
		if bucket.tokens < 1 then
			local wait_ms = if refill > 0 then math.ceil((1 - bucket.tokens) / refill * 1000) else math.huge
			return false, wait_ms
		end
		self.retry_tokens -= 1
		bucket.tokens -= 1
		return true, 0
	end
	function governor:ChooseBatchSize(requested, latency_ms)
		local maximum = math.min(bounded_integer(requested, self.policy.max_batch, 1, 16), self.policy.max_batch)
		latency_ms = if finite(latency_ms) then latency_ms else 0
		if latency_ms >= self.policy.batch_latency_ceiling_ms then return 1 end
		if latency_ms >= self.policy.batch_latency_ceiling_ms * 0.75 then return math.max(1, math.floor(maximum / 2)) end
		return maximum
	end
	local function heap_less(left, right)
		if left.due_at_ms ~= right.due_at_ms then return left.due_at_ms < right.due_at_ms end
		if left.id ~= right.id then return left.id < right.id end
		return (left.sequence or 0) < (right.sequence or 0)
	end
	local function heap_push(heap, value)
		local index = #heap + 1
		heap[index] = value
		while index > 1 do
			local parent = math.floor(index / 2)
			if not heap_less(heap[index], heap[parent]) then break end
			heap[index], heap[parent] = heap[parent], heap[index]
			index = parent
		end
	end
	local function heap_pop(heap)
		if #heap == 0 then return nil end
		local first, last = heap[1], table.remove(heap)
		if #heap > 0 then
			heap[1] = last
			local index = 1
			while true do
				local left, right, smallest = index * 2, index * 2 + 1, index
				if left <= #heap and heap_less(heap[left], heap[smallest]) then smallest = left end
				if right <= #heap and heap_less(heap[right], heap[smallest]) then smallest = right end
				if smallest == index then break end
				heap[index], heap[smallest] = heap[smallest], heap[index]
				index = smallest
			end
		end
		return first
	end
	local function rebuild_due_heap()
		local rebuilt = {}
		for _, item in pairs(governor.due) do heap_push(rebuilt, item) end
		governor.due_heap = rebuilt
	end
	function governor:ScheduleDue(id, due_at_ms, value)
		if not valid_text(id, 128) or not finite(due_at_ms) then return false, "invalid due item" end
		if self.due[id] == nil and key_count(self.due) >= self.policy.queue_capacity then return false, "due queue full" end
		self.due_sequence = (self.due_sequence or 0) + 1
		local item = { id = id, due_at_ms = due_at_ms, value = copy(value), sequence = self.due_sequence }
		self.due[id] = item
		heap_push(self.due_heap, item)
		if #self.due_heap > self.policy.queue_capacity * 2 then rebuild_due_heap() end
		return true, nil
	end
	function governor:PopDue(limit)
		limit = bounded_integer(limit, 32, 1, 256)
		local result, now = {}, now_ms()
		while #result < limit do
			local item = self.due_heap[1]
			if item == nil then break end
			if self.due[item.id] ~= item then
				heap_pop(self.due_heap)
			elseif item.due_at_ms > now then
				break
			else
				heap_pop(self.due_heap)
				self.due[item.id] = nil
				result[#result + 1] = item
			end
		end
		return result
	end
	function governor:NextDueAt()
		while true do
			local item = self.due_heap[1]
			if item == nil then return nil end
			if self.due[item.id] ~= item then heap_pop(self.due_heap)
			else return item.due_at_ms end
		end
	end
	local function dependencies_ready(self, item)
		for _, dependency in ipairs(item.dependencies or {}) do
			if not self.completed[dependency] then return false end
		end
		return true
	end
	local function scheduled_lane(item, now)
		if item.inherited_lane ~= nil and finite(item.inherited_until_ms) and item.inherited_until_ms > now then
			return item.inherited_lane
		end
		return item.lane
	end
	local function item_priority(item)
		return if item.service_class == "critical" then 0 elseif item.service_class == "interactive" then 1
			elseif item.service_class == "normal" then 2 elseif item.service_class == "bulk" then 3 else 4
	end
	local function inherit_ready_prerequisites(self, dependent)
		if dependent.lane ~= "high" then return end
		local now = now_ms()
		for _, prerequisite_id in ipairs(dependent.dependencies or {}) do
			local prerequisite = self.known[prerequisite_id]
			if prerequisite ~= nil and prerequisite.queued == true and prerequisite.lane == "background"
				and (prerequisite.due_at_ms or 0) <= now
				and (prerequisite.expires_at_ms == nil or prerequisite.expires_at_ms > now)
				and dependencies_ready(self, prerequisite)
			then
				prerequisite.inherited_lane = "normal"
				prerequisite.inherited_until_ms = now + self.policy.priority_inheritance_max_ms
				prerequisite.inherited_from = dependent.id
			end
		end
	end
	local function item_precedes(left, right, now)
		local left_service, right_service = item_priority(left), item_priority(right)
		if left_service ~= right_service then return left_service < right_service end
		local left_slack = if finite(left.deadline_ms) then left.deadline_ms - now else math.huge
		local right_slack = if finite(right.deadline_ms) then right.deadline_ms - now else math.huge
		local left_age = math.min(60000, math.max(0, now - (left.enqueued_at_ms or now)))
		local right_age = math.min(60000, math.max(0, now - (right.enqueued_at_ms or now)))
		left_slack -= left_age * 0.25
		right_slack -= right_age * 0.25
		if left_slack ~= right_slack then return left_slack < right_slack end
		return (left.enqueued_at_ms or 0) < (right.enqueued_at_ms or 0)
	end
	local function effective_cost(item)
		local operation_cost = {
			default = 3, read = 2, update_async = 4, mailbox_claim = 4,
			lease_renewal = 4, outbox_dispatch = 4, maintenance = 3,
			migration = 4, projection = 3, tracing = 1, batch = 4,
		}
		local estimated = operation_cost[item.operation_class or "default"] or operation_cost.default
		if finite(item.read_units) then estimated = math.max(estimated, item.read_units) end
		if finite(item.write_units) then estimated = math.max(estimated, item.write_units) end
		if finite(item.read_units) and finite(item.write_units) then estimated = math.max(estimated, item.read_units + item.write_units) end
		if finite(item.estimated_bytes) then estimated = math.max(estimated, math.ceil(item.estimated_bytes / 16384)) end
		if finite(item.handler_slots) then estimated = math.max(estimated, item.handler_slots * 4) end
		if finite(item.cost) then estimated = math.max(estimated, math.floor(item.cost)) end
		return math.clamp(math.ceil(estimated), 1, 256)
	end
	local function lane_key(item, now)
		local instant = now or now_ms()
		local function component(value)
			value = tostring(value or "default")
			return tostring(#value) .. ":" .. value
		end
		-- Length-prefix every identity component; hash collisions must not merge owners.
		return component(item.owner_id)
			.. component(item.work_class or "default")
			.. component(scheduled_lane(item, instant))
			.. component(item.service_class or "best_effort")
	end
	local function choose_index(self, algorithm, renewal_mode)
		local now, eligible = now_ms(), {}
		for index, item in ipairs(self.queue) do
			local ready = (item.due_at_ms or 0) <= now and dependencies_ready(self, item)
			if renewal_mode == true and item.lane ~= "lease_renewal" then ready = false end
			if renewal_mode == false and item.lane == "lease_renewal" then ready = false end
			if ready and (not item.expires_at_ms or item.expires_at_ms > now) then
				local owner_active = self.active_owner[item.owner_id] or 0
				local effective_lane = scheduled_lane(item, now)
				local renewal_count = self.active_renewals_by_owner[item.owner_id] or 0
				-- At most one renewal may be active for a single claim/owner at a time.
				local owner_can_renew = effective_lane ~= "lease_renewal" or renewal_count < 1
				if owner_can_renew and (effective_lane == "lease_renewal" or owner_active < self.policy.max_per_owner_in_flight) then
					eligible[#eligible + 1] = { index = index, item = item, effective_lane = effective_lane }
				end
			end
		end
		if #eligible == 0 then return nil end
		if self.high_streak >= self.policy.high_burst then
			local has_non_high = false
			for _, row in ipairs(eligible) do
				if row.effective_lane ~= "high" and row.effective_lane ~= "lease_renewal" then has_non_high = true break end
			end
			if has_non_high then
				local filtered = {}
				for _, row in ipairs(eligible) do if row.effective_lane ~= "high" then filtered[#filtered + 1] = row end end
				eligible = filtered
			end
		end
		if algorithm == "fifo" then
			local best
			for _, row in ipairs(eligible) do
				if best == nil or row.item.enqueued_at_ms < best.item.enqueued_at_ms then best = row end
			end
			return best and best.index or nil
		elseif algorithm == "weighted" or algorithm == "deadline" then
			local best, best_score
			for _, row in ipairs(eligible) do
				local item = row.item
				local age = math.min(60000, math.max(0, now - item.enqueued_at_ms))
				local slack = if finite(item.deadline_ms) then item.deadline_ms - now else 60000
				local lane = row.effective_lane
				local lane_weight = if lane == "lease_renewal" then 8 elseif lane == "high" then 4 elseif lane == "normal" then 2 else 1
				local service_rank = if item.service_class == "critical" then 4 elseif item.service_class == "interactive" then 3 elseif item.service_class == "normal" then 2 elseif item.service_class == "bulk" then 1 else 0
				local score = if algorithm == "deadline"
					then -service_rank * 10000 - lane_weight * 1000 + slack - age * 0.25
					else -lane_weight * 1000 - service_rank * 500 - age * 0.25 + slack * 0.01
				if best_score == nil or score < best_score then best, best_score = row, score end
			end
			return best and best.index or nil
		end
		local lane_rows, lane_keys = {}, {}
		for _, row in ipairs(eligible) do
			local key = lane_key(row.item, now)
			if lane_rows[key] == nil then
				lane_rows[key] = {}
				lane_keys[#lane_keys + 1] = key
			end
			lane_rows[key][#lane_rows[key] + 1] = row
		end
		table.sort(lane_keys)
		local lane_count = #lane_keys
		local start_index = 1
		if self.drr_cursor_key ~= nil then
			for i, key in ipairs(lane_keys) do
				if key == self.drr_cursor_key then start_index = (i % lane_count) + 1 break end
			end
		end
		local rounds = math.ceil(self.policy.max_item_cost / self.policy.drr_quantum) + 2
		for _ = 1, rounds do
			for offset = 0, lane_count - 1 do
				local lane_index = ((start_index + offset - 1) % lane_count) + 1
				local key = lane_keys[lane_index]
				local rows = lane_rows[key]
				local lane = rows[1].effective_lane
				local lane_weight = if lane == "lease_renewal" then 4 elseif lane == "high" then 4 elseif lane == "normal" then 2 else 1
				local service_class = rows[1].item.service_class or "best_effort"
				local service_weight = if service_class == "critical" then 4 elseif service_class == "interactive" then 3
					elseif service_class == "normal" then 2 else 1
				local weight = lane_weight * service_weight
				self.drr_deficit[key] = math.min(self.policy.max_item_cost * 2, (self.drr_deficit[key] or 0) + self.policy.drr_quantum * weight)
				local best = rows[1]
				local has_urgent = false
				for _, row in ipairs(rows) do
					if finite(row.item.deadline_ms) and row.item.deadline_ms - now <= 5000 then has_urgent = true end
				end
				if has_urgent and self.urgent_streak < self.policy.urgent_deadline_burst then
					for _, row in ipairs(rows) do if item_precedes(row.item, best.item, now) then best = row end end
				else
					for _, row in ipairs(rows) do
						if row.item.enqueued_at_ms < best.item.enqueued_at_ms then best = row end
					end
				end
				local cost = effective_cost(best.item)
				if cost <= self.drr_deficit[key] then
					self.drr_deficit[key] -= cost
					self.drr_cursor_key = key
					return best.index
				end
			end
		end
		return nil
	end
	function governor:Enqueue(item)
		if type(item) ~= "table" or not valid_text(item.id, 128) or not valid_text(item.owner_id, 512) then return { code = "invalid" } end
		if self.known[item.id] then return { code = "duplicate" } end
		if #self.queue >= self.policy.queue_capacity then self.stats.rejected += 1; return { code = "capacity", message = "local queue full; no accepted durable work is evicted" } end
		local lane = item.lane or "normal"
		if lane ~= "high" and lane ~= "normal" and lane ~= "background" and lane ~= "lease_renewal" then return { code = "invalid", message = "unsupported lane" } end
		local value = copy(item)
		if value.work_class ~= nil and not valid_text(value.work_class, 64) then return { code = "invalid", message = "work_class must be 1..64 bytes" } end
		if value.operation_class ~= nil and not valid_text(value.operation_class, 64) then return { code = "invalid", message = "operation_class must be 1..64 bytes" } end
		if value.available_at_ms ~= nil and not finite(value.available_at_ms) then return { code = "invalid", message = "available_at_ms must be finite" } end
		if value.due_at_ms ~= nil and not finite(value.due_at_ms) then return { code = "invalid", message = "due_at_ms must be finite" } end
		if value.deadline_ms ~= nil and not finite(value.deadline_ms) then return { code = "invalid", message = "deadline_ms must be finite" } end
		if value.expires_at_ms ~= nil and not finite(value.expires_at_ms) then return { code = "invalid", message = "expires_at_ms must be finite" } end
		local valid_service_classes = { critical = true, interactive = true, normal = true, bulk = true, best_effort = true }
		if value.service_class ~= nil and not valid_service_classes[value.service_class] then return { code = "invalid", message = "unsupported service_class" } end
		local dependencies = value.dependencies or {}
		if type(dependencies) ~= "table" or #dependencies > 32 then return { code = "invalid", message = "dependencies must be an array of at most 32 IDs" } end
		local dependency_count, seen_dependencies = 0, {}
		for key in pairs(dependencies) do
			dependency_count += 1
			if type(key) ~= "number" or key < 1 or key > #dependencies or math.floor(key) ~= key then return { code = "invalid", message = "dependencies must be a dense array" } end
		end
		if dependency_count ~= #dependencies then return { code = "invalid", message = "dependencies must be a dense array" } end
		for _, dependency in ipairs(dependencies) do
			if not valid_text(dependency, 128) or dependency == value.id or seen_dependencies[dependency] then return { code = "invalid", message = "dependency IDs must be unique, valid and not self-referential" } end
			seen_dependencies[dependency] = true
			if not self.completed[dependency] and not self.known[dependency] then
				return { code = "invalid", message = "dependency is missing; enqueue its prerequisite before the dependent item" }
			end
		end
		local dimensions = { "read_units", "write_units", "handler_slots" }
		for _, field in ipairs(dimensions) do
			if value[field] ~= nil and (not finite(value[field]) or value[field] < 0 or value[field] > 64 or math.floor(value[field]) ~= value[field]) then
				return { code = "invalid", message = field .. " must be an integer in 0..64" }
			end
		end
		if value.estimated_bytes ~= nil and (not finite(value.estimated_bytes) or value.estimated_bytes < 0 or value.estimated_bytes > 16777216) then
			return { code = "invalid", message = "estimated_bytes must be in 0..16777216" }
		end
		if value.cost ~= nil and (not finite(value.cost) or value.cost < 1 or value.cost > self.policy.max_item_cost
			or math.floor(value.cost) ~= value.cost)
		then return { code = "invalid", message = "cost must be an integer within max_item_cost" } end
		value.lane, value.original_lane = lane, lane
		value.work_class = value.work_class or value.operation_class or "default"
		value.enqueued_at_ms = now_ms()
		value.due_at_ms = value.due_at_ms or value.available_at_ms or value.enqueued_at_ms
		value.dependencies = dependencies
		value.cost = effective_cost(value)
		if value.cost > self.policy.max_item_cost then return { code = "invalid", message = "estimated scheduler cost exceeds max_item_cost" } end
		value.queued = true
		self.known[value.id] = value
		table.insert(self.queue, value)
		heap_push(self.queued_due_heap, { id = value.id, due_at_ms = value.due_at_ms, item = value })
		inherit_ready_prerequisites(self, value)
		if #self.queued_due_heap > self.policy.queue_capacity * 2 then
			local rebuilt = {}
			for _, queued in ipairs(self.queue) do heap_push(rebuilt, { id = queued.id, due_at_ms = queued.due_at_ms, item = queued }) end
			self.queued_due_heap = rebuilt
		end
		return { code = "accepted", count = #self.queue }
	end
	local remember_terminal
	function governor:TakeNext(renewal_mode)
		local now = now_ms()
		for index = #self.queue, 1, -1 do
			local item = self.queue[index]
			local failed_dependency
			for _, dependency in ipairs(item.dependencies or {}) do if self.failed[dependency] ~= nil then failed_dependency = dependency break end end
			if failed_dependency ~= nil then
				table.remove(self.queue, index)
				item.queued = false
				self.known[item.id] = nil
				self.retry_cooldown_until[item.owner_id] = nil
				item.terminal_result = {
					code = "dependency_failed", message = "prerequisite reached a non-success terminal outcome",
					dependency_id = failed_dependency, dependency_code = self.failed[failed_dependency],
				}
				remember_terminal(self, item.id, "dependency_failed")
				return item, "dependency_failed"
			elseif item.expires_at_ms and item.expires_at_ms <= now then
				table.remove(self.queue, index)
				item.queued = false
				self.known[item.id] = nil
				self.retry_cooldown_until[item.owner_id] = nil
				self.stats.scheduled_expired += 1
				item.terminal_result = { code = "expired", message = "scheduled work expired before it could start" }
				remember_terminal(self, item.id, "expired")
				return item, "expired"
			end
		end
		local index = choose_index(self, self.policy.algorithm or "drr", renewal_mode)
		if not index then return nil, "empty" end
		if self.policy.shadow_enabled and self.policy.shadow_sample_rate > 0 then
			local interval = math.max(1, math.floor(1 / self.policy.shadow_sample_rate))
			if (self.stats.scheduled_selected + 1) % interval == 0 then self:ShadowDecision(renewal_mode) end
		end
		local item = table.remove(self.queue, index)
		item.queued = false
		local age = math.max(0, now - (item.enqueued_at_ms or now))
		self.scheduler_metrics.wait_ms[#self.scheduler_metrics.wait_ms + 1] = age
		if #self.scheduler_metrics.wait_ms > 256 then table.remove(self.scheduler_metrics.wait_ms, 1) end
		local lane_stats = self.scheduler_metrics.by_lane[item.lane] or { selected = 0, total_wait_ms = 0, max_wait_ms = 0 }
		lane_stats.selected += 1
		lane_stats.total_wait_ms += age
		lane_stats.max_wait_ms = math.max(lane_stats.max_wait_ms, age)
		self.scheduler_metrics.by_lane[item.lane] = lane_stats
		self.stats.scheduled_selected += 1
		item.overdue = item.deadline_ms ~= nil and item.deadline_ms < now
		if item.overdue then self.stats.scheduled_overdue += 1 end
		local effective_lane = scheduled_lane(item, now)
		if effective_lane == "high" then self.high_streak += 1 else self.high_streak = 0 end
		if finite(item.deadline_ms) and item.deadline_ms - now <= 5000 then self.urgent_streak += 1 else self.urgent_streak = 0 end
		self.active_owner[item.owner_id] = (self.active_owner[item.owner_id] or 0) + 1
		if item.lane == "lease_renewal" then self.active_renewals_by_owner[item.owner_id] = (self.active_renewals_by_owner[item.owner_id] or 0) + 1 end
		item.selected_at_ms = now
		item.dispatch_state = "in_flight"
		return item, "success"
	end
	function governor:NextQueuedDueAt()
		while true do
			local entry = self.queued_due_heap[1]
			if entry == nil then return nil end
			if entry.item.queued ~= true or self.known[entry.id] ~= entry.item then heap_pop(self.queued_due_heap)
			else return entry.due_at_ms end
		end
	end
	function governor:NextWakeAt()
		local now, next_wake = now_ms(), nil
		for _, item in ipairs(self.queue) do
			local owner_at_cap = (self.active_owner[item.owner_id] or 0) >= self.policy.max_per_owner_in_flight
			local renewal_can_run = item.lane == "lease_renewal" and
				(self.active_renewals_by_owner[item.owner_id] or 0) < self.policy.max_per_owner_in_flight
			if dependencies_ready(self, item) and (renewal_can_run or not owner_at_cap) then
				local candidate
				if (item.due_at_ms or 0) > now then candidate = item.due_at_ms end
				-- Expiry must wake the dispatcher even when it precedes available_at.
				if item.expires_at_ms ~= nil and item.expires_at_ms > now
					and (candidate == nil or item.expires_at_ms < candidate)
				then candidate = item.expires_at_ms end
				if candidate ~= nil and (next_wake == nil or candidate < next_wake) then next_wake = candidate end
			elseif item.expires_at_ms ~= nil and item.expires_at_ms > now
				and (next_wake == nil or item.expires_at_ms < next_wake)
			then
				-- Even an owner-saturated item must eventually report expiry. Its
				-- callback still cannot start until a dispatch slot is available.
				next_wake = item.expires_at_ms
			end
		end
		return next_wake
	end
	function governor:Reschedule(id, due_at_ms)
		if not valid_text(id, 128) or not finite(due_at_ms) then return false, "invalid retry schedule" end
		local item = self.known[id]
		if item == nil or item.dispatch_state ~= "in_flight" then return false, "scheduled item is not in flight" end
		if #self.queue >= self.policy.queue_capacity then return false, "local queue full; retry was not accepted" end
		local now = now_ms()
		local cooldown_until = self.retry_cooldown_until[item.owner_id] or 0
		local next_due = math.max(due_at_ms, cooldown_until, now)
		item.due_at_ms = next_due
		item.is_retry = true
		item.queued = true
		item.dispatch_state = nil
		item.selected_at_ms = nil
		local owner_count = math.max(0, (self.active_owner[item.owner_id] or 1) - 1)
		if owner_count == 0 then self.active_owner[item.owner_id] = nil else self.active_owner[item.owner_id] = owner_count end
		if item.lane == "lease_renewal" then
			local renewal_count = math.max(0, (self.active_renewals_by_owner[item.owner_id] or 1) - 1)
			if renewal_count == 0 then self.active_renewals_by_owner[item.owner_id] = nil
			else self.active_renewals_by_owner[item.owner_id] = renewal_count end
		end
		table.insert(self.queue, item)
		heap_push(self.queued_due_heap, { id = item.id, due_at_ms = item.due_at_ms, item = item })
		if #self.queued_due_heap > self.policy.queue_capacity * 2 then
			local rebuilt = {}
			for _, queued in ipairs(self.queue) do heap_push(rebuilt, { id = queued.id, due_at_ms = queued.due_at_ms, item = queued }) end
			self.queued_due_heap = rebuilt
		end
		self.retry_cooldown_until[item.owner_id] = next_due
		return true, nil, next_due
	end
	local function rebuild_queued_due_heap(self)
		local rebuilt = {}
		for _, item in ipairs(self.queue) do heap_push(rebuilt, { id = item.id, due_at_ms = item.due_at_ms, item = item }) end
		self.queued_due_heap = rebuilt
	end
	remember_terminal = function(self, id, code)
		self.failed[id] = code
		self.failed_order[#self.failed_order + 1] = id
		local limit = self.policy.queue_capacity * 2
		while #self.failed_order > limit do
			local oldest = table.remove(self.failed_order, 1)
			local still_required = false
			for _, queued in ipairs(self.queue) do
				for _, dependency in ipairs(queued.dependencies or {}) do
					if dependency == oldest then still_required = true break end
				end
				if still_required then break end
			end
			if not still_required then self.failed[oldest] = nil end
		end
	end
	local function make_shadow_state(self)
		return {
			queue = copy(self.queue), completed = copy(self.completed), known = copy(self.known),
			failed = copy(self.failed), active_owner = copy(self.active_owner),
			active_renewals_by_owner = copy(self.active_renewals_by_owner),
			drr_deficit = copy(self.drr_deficit), drr_cursor_key = self.drr_cursor_key,
			high_streak = self.high_streak, urgent_streak = self.urgent_streak,
			policy = copy(self.policy),
		}
	end
	function governor:MarkCompleted(id, outcome)
		if not valid_text(id, 128) then return false, "invalid id" end
		local item = self.known[id]
		if item ~= nil and item.dispatch_state == "in_flight" then
			local owner_count = math.max(0, (self.active_owner[item.owner_id] or 1) - 1)
			if owner_count == 0 then self.active_owner[item.owner_id] = nil else self.active_owner[item.owner_id] = owner_count end
			if item.lane == "lease_renewal" then
				local renewal_count = math.max(0, (self.active_renewals_by_owner[item.owner_id] or 1) - 1)
				if renewal_count == 0 then self.active_renewals_by_owner[item.owner_id] = nil
				else self.active_renewals_by_owner[item.owner_id] = renewal_count end
			end
		end
		self.known[id] = nil
		if item ~= nil then self.retry_cooldown_until[item.owner_id] = nil end
		for _, queued in ipairs(self.queue) do
			if queued.inherited_from == id then
				queued.inherited_lane = nil
				queued.inherited_until_ms = nil
				queued.inherited_from = nil
			end
		end
		local code = if type(outcome) == "table" then outcome.code else outcome
		if code == nil or code == true or code == "success" or code == "committed"
			or code == "acknowledged" or code == "processed" or code == "completed" or code == "duplicate" or code == "renewed"
			or code == "saved" or code == "closed" or code == "created" or code == "loaded"
			or code == "enqueued" or code == "deleted" or code == "released" or code == "committed_reconciled"
		then
			self.completed[id] = true
			self.failed[id] = nil
			self.completed_order[#self.completed_order + 1] = id
			while #self.completed_order > self.policy.queue_capacity * 2 do
				local oldest = table.remove(self.completed_order, 1)
				local still_required = false
				for _, queued in ipairs(self.queue) do
					for _, dependency in ipairs(queued.dependencies or {}) do if dependency == oldest then still_required = true break end end
					if still_required then break end
				end
				if not still_required then self.completed[oldest] = nil end
			end
		else
			self.completed[id] = nil
			remember_terminal(self, id, tostring(code or "unknown"))
		end
		local active_lane_keys = {}
		local instant = now_ms()
		for _, queued in ipairs(self.queue) do active_lane_keys[lane_key(queued, instant)] = true end
		for _, known_item in pairs(self.known) do
			if known_item.dispatch_state == "in_flight" then active_lane_keys[lane_key(known_item, instant)] = true end
		end
		for key in pairs(self.drr_deficit) do if not active_lane_keys[key] then self.drr_deficit[key] = nil end end
		self.stats.completed += 1
		return true
	end
	function governor:ShadowNext(algorithm)
		local shadow = make_shadow_state(self)
		local index = choose_index(shadow, algorithm or shadow.policy.shadow_algorithm)
		return if index then copy(shadow.queue[index]) else nil
	end
	function governor:ShadowDecision(renewal_mode)
		local real_state, shadow_state = make_shadow_state(self), make_shadow_state(self)
		local real_index = choose_index(real_state, self.policy.algorithm, renewal_mode)
		local shadow_index = choose_index(shadow_state, self.policy.shadow_algorithm, renewal_mode)
		local real = if real_index then self.queue[real_index] else nil
		local shadow = if shadow_index then self.queue[shadow_index] else nil
		local now = now_ms()
		local summary = {
			observed_at_ms = now, real_algorithm = self.policy.algorithm, shadow_algorithm = self.policy.shadow_algorithm,
			real_lane = if real then real.lane else nil, shadow_lane = if shadow then shadow.lane else nil,
			real_cost = if real then effective_cost(real) else nil, shadow_cost = if shadow then effective_cost(shadow) else nil,
			real_age_ms = if real then math.max(0, now - real.enqueued_at_ms) else nil,
			shadow_age_ms = if shadow then math.max(0, now - shadow.enqueued_at_ms) else nil,
			real_slack_ms = if real and finite(real.deadline_ms) then real.deadline_ms - now else nil,
			shadow_slack_ms = if shadow and finite(shadow.deadline_ms) then shadow.deadline_ms - now else nil,
			candidate_count = #self.queue,
			same_choice = real ~= nil and shadow ~= nil and real.id == shadow.id,
			reason = if real == nil and shadow == nil then "no_eligible_candidates"
				elseif real ~= nil and shadow ~= nil and real.id == shadow.id then "algorithms_agree"
				else "alternate_policy_differs",
		}
		self.scheduler_metrics.last_shadow = summary
		self.stats.shadow_samples += 1
		return copy(summary)
	end
	function governor:Replay(log)
		local result = {}
		for _, entry in ipairs(log or {}) do
			if entry.kind == "enqueue" then self:Enqueue(entry.item)
			elseif entry.kind == "complete" then self:MarkCompleted(entry.id)
			elseif entry.kind == "take" then local item = self:TakeNext(); result[#result + 1] = if item then item.id else "<empty>"
			elseif entry.kind == "advance" and finite(entry.ms) and type(options.advance_ms) == "function" then options.advance_ms(entry.ms) end
		end
		return result
	end
	local function read_record_stats(record)
		if type(options.get_record_stats) ~= "function" then return {} end
		local ok, value = pcall(options.get_record_stats, record)
		return if ok and type(value) == "table" then value else {}
	end
	function governor:GetDurabilitySLO(record, threshold)
		local stats = read_record_stats(record)
		local now = if type(options.now_unix) == "function" then options.now_unix() else os.time()
		local dirty = tonumber(stats.dirty) == 1
		local core_dirty_since = tonumber(stats.dirty_since_unix)
		local seen = dirty_seen[record]
		if not dirty then
			dirty_seen[record] = nil
			seen = nil
		elseif seen == nil or seen.sequence ~= stats.change_sequence then
			seen = { sequence = stats.change_sequence, since = now }
			dirty_seen[record] = seen
		end
		local core_tracking = finite(core_dirty_since) and (core_dirty_since :: number) > 0
		local age_start = if core_tracking then core_dirty_since else if seen then seen.since else nil
		local age = if dirty and age_start ~= nil then math.max(0, now - (age_start :: number)) else 0
		return {
			state = stats.state or "unknown", durable_revision = stats.last_saved_revision or 0,
			current_revision = stats.revision or 0, dirty = dirty, last_confirmed_save_unix = stats.last_saved_at or 0,
			dirty_age_lower_bound_seconds = age,
			age_basis = if core_tracking then "RecordStore dirty-generation timestamp" else "time since first observation of this dirty generation",
			max_dirty_age_seconds = threshold or 60, slo_exceeded = dirty and age > (threshold or 60),
			slo_conclusion = if not dirty then "clean" elseif core_tracking then "tracked_generation" elseif seen then "lower_bound_only" else "age_unavailable",
			write_outcome_uncertain = stats.state == "unknown", observed_at_unix = now,
		}
	end
	function governor:GetContentionDiagnostics(record)
		local stats = read_record_stats(record)
		return { state = stats.state, busy = stats.busy == 1, queue_busy = stats.queue_busy == 1, takeover_requested = stats.takeover_requested == 1, generation = stats.generation, revision = stats.revision, last_error = stats.last_error, can_force_takeover = false }
	end
	function governor:Stats()
		local lanes = { high = 0, normal = 0, background = 0, lease_renewal = 0 }
		local oldest_eligible_age_ms, now = 0, now_ms()
		for _, item in ipairs(self.queue) do
			lanes[item.lane] = (lanes[item.lane] or 0) + 1
			if (item.due_at_ms or 0) <= now and dependencies_ready(self, item)
				and (item.expires_at_ms == nil or item.expires_at_ms > now)
			then oldest_eligible_age_ms = math.max(oldest_eligible_age_ms, now - item.enqueued_at_ms) end
		end
		local waits = copy(self.scheduler_metrics.wait_ms)
		table.sort(waits)
		local function percentile(p)
			if #waits == 0 then return 0 end
			return waits[math.clamp(math.ceil(#waits * p), 1, #waits)]
		end
		return {
			policy = copy(self.policy), in_flight = self.in_flight, queue_items = #self.queue,
			lanes = lanes, classes = copy(self.by_class), stats = copy(self.stats),
			latency_ewma = copy(self.latency_ewma), circuits = copy(self.circuits),
			last_budget_by_kind = copy(self.last_budget_by_kind), retry_tokens = self.retry_tokens,
			scheduler = {
				by_lane = copy(self.scheduler_metrics.by_lane), oldest_eligible_age_ms = oldest_eligible_age_ms,
				queue_wait_p50_ms = percentile(0.50), queue_wait_p95_ms = percentile(0.95), queue_wait_p99_ms = percentile(0.99),
				next_due_at_ms = self:NextQueuedDueAt(), due_heap_items = #self.due_heap,
				queued_due_heap_items = #self.queued_due_heap, active_by_owner = copy(self.active_owner),
				last_shadow = copy(self.scheduler_metrics.last_shadow),
			},
		}
	end
	return governor
end

local runtime_governors_by_record_store = setmetatable({}, { __mode = "k" })

local function get_task_api()
	local ok, value = pcall(function() return task end)
	if ok and type(value) == "table" and type(value.spawn) == "function" then
		return value
	end
	local module_ok, module_value = pcall(require, "@lune/task")
	if module_ok and type(module_value) == "table" and type(module_value.spawn) == "function" then
		return module_value
	end
	return nil
end

local function spawn_scheduled(callback)
	local api = get_task_api()
	if api ~= nil then api.spawn(callback) else callback() end
end

local function delay_scheduled(seconds, callback)
	local api = get_task_api()
	if api == nil or type(api.delay) ~= "function" then return false end
	api.delay(seconds, callback)
	return true
end

local function new_dispatcher(governor, options)
	options = options or {}
	assert(type(governor) == "table" and type(governor.Enqueue) == "function"
		and type(governor.TakeNext) == "function", "a scheduler governor is required")
	local dispatcher = {
		governor = governor,
		callbacks = {},
		sequence = 0,
		in_flight = 0,
		normal_in_flight = 0,
		running = false,
		closed = false,
		wake_generation = 0,
		wake_due_ms = nil,
		metrics = {
			accepted = 0, rejected = 0, completed = 0, retries = 0,
			expired = 0, dependency_failed = 0, callback_errors = 0,
			max_in_flight = 0, last_error = nil,
		},
	}
	local function now_ms()
		return if type(options.now_ms) == "function" then options.now_ms() else os.clock() * 1000
	end
	local kick_dispatcher
	local function schedule_wake_at(due_at_ms)
		if dispatcher.closed or not finite(due_at_ms) then return end
		local current = dispatcher.wake_due_ms
		if current ~= nil and current <= due_at_ms then return end
		dispatcher.wake_generation += 1
		local generation = dispatcher.wake_generation
		dispatcher.wake_due_ms = due_at_ms
		local delay_ms = math.max(0, due_at_ms - now_ms())
		delay_scheduled(delay_ms / 1000, function()
			if dispatcher.closed or generation ~= dispatcher.wake_generation then return end
			dispatcher.wake_due_ms = nil
			kick_dispatcher()
		end)
	end
	local function schedule_next_wake()
		local due = governor:NextWakeAt()
		if due ~= nil then schedule_wake_at(due) end
	end
	local function invoke_completion(entry, result)
		if type(entry) ~= "table" or type(entry.on_complete) ~= "function" then return end
		local ok, message = pcall(entry.on_complete, copy(result))
		if not ok then
			dispatcher.metrics.callback_errors += 1
			dispatcher.metrics.last_error = string.sub(tostring(message), 1, 200)
		end
	end
	local function retry_due(item, entry, result)
		if entry.retry_attempt >= entry.max_retries then
			return false, { code = "retry_exhausted", message = "configured retry cap reached", last_result = copy(result) }
		end
		local token, wait_ms = governor:AcquireRetryToken(entry.work_class)
		local now = now_ms()
		local delay_ms
		if token then
			local exponential = math.min(60000, entry.retry_delay_ms * (2 ^ entry.retry_attempt))
			local jitter_span = exponential * entry.retry_jitter_percent / 100
			local jitter = if jitter_span > 0 then (math.random() * 2 - 1) * jitter_span else 0
			delay_ms = math.max(10, math.floor(exponential + jitter))
		else
			-- A depleted token bucket defers retry traffic; it must not spin a tight timer.
			delay_ms = if finite(wait_ms) then math.clamp(math.floor(wait_ms), 10, 60000) else 60000
		end
		local due_at_ms = now + delay_ms
		local queued, message = governor:Reschedule(item.id, due_at_ms)
		if not queued then
			return false, { code = "retry_rejected", message = tostring(message or "retry admission failed"), last_result = copy(result) }
		end
		if token then
			entry.retry_attempt += 1
			entry.retry_waiting_for_token = false
			dispatcher.metrics.retries += 1
		else
			-- Do not execute a retry until its class receives an admission token.
			entry.retry_waiting_for_token = true
		end
		entry.last_result = copy(result)
		schedule_wake_at(due_at_ms)
		return true, nil
	end
	local function terminal_result(item, status)
		local result = if type(item.terminal_result) == "table" then copy(item.terminal_result)
			else { code = status, message = "scheduled item reached a terminal scheduler state" }
		if status == "expired" then dispatcher.metrics.expired += 1 end
		if status == "dependency_failed" then dispatcher.metrics.dependency_failed += 1 end
		return result
	end
	local function finish_scheduled_item(item, status, entry, callback_ok, callback_result, counted_in_flight)
		local retry_scheduled = false
		if status ~= "success" then
			callback_ok = true
			callback_result = terminal_result(item, status)
		elseif not callback_ok then
			dispatcher.metrics.callback_errors += 1
			dispatcher.metrics.last_error = string.sub(tostring(callback_result), 1, 200)
			-- A raised callback may have committed an external side effect. Never retry it automatically.
			callback_result = { code = "unknown", message = "scheduled callback raised; effect outcome may be unknown" }
		elseif type(callback_result) == "table" and callback_result.code == "retryable"
			and type(entry) == "table" and entry.retry_attempt < entry.max_retries
		then
			local queued, retry_error = retry_due(item, entry, callback_result)
			if queued then
				retry_scheduled = true
			else
				callback_result = retry_error
			end
		elseif type(callback_result) == "table" and callback_result.code == "retryable"
			and type(entry) == "table"
		then
			callback_result = { code = "retry_exhausted", message = "configured retry cap reached", last_result = copy(callback_result) }
		end
		if counted_in_flight then
			dispatcher.in_flight = math.max(0, dispatcher.in_flight - 1)
			if item.lane ~= "lease_renewal" then
				dispatcher.normal_in_flight = math.max(0, dispatcher.normal_in_flight - 1)
			end
		end
		if not retry_scheduled then
			if status == "success" and callback_ok then dispatcher.metrics.completed += 1 end
			dispatcher.callbacks[item.id] = nil
			invoke_completion(entry, type(callback_result) == "table" and callback_result
				or { code = if callback_result == true or callback_result == nil then "success" else tostring(callback_result) })
			local outcome = if type(callback_result) == "table" then callback_result.code
				elseif callback_ok and (callback_result == true or callback_result == nil) then "success"
				elseif not callback_ok then "unknown" else tostring(callback_result)
			governor:MarkCompleted(item.id, outcome)
		end
		if not dispatcher.closed then
			kick_dispatcher()
			schedule_next_wake()
		end
	end
	local function dispatch_one(item, status)
		local entry = dispatcher.callbacks[item.id]
		if status ~= "success" then
			finish_scheduled_item(item, status, entry, true, nil, false)
			return
		end
		if type(entry) == "table" and entry.retry_waiting_for_token == true then
			local token, wait_ms = governor:AcquireRetryToken(entry.work_class)
			if not token then
				local token_wait_ms = if finite(wait_ms) then math.clamp(math.floor(wait_ms), 10, 60000) else 60000
				local retry_due_at = now_ms() + token_wait_ms
				local requeued, retry_error = governor:Reschedule(item.id, retry_due_at)
				if requeued then
					schedule_wake_at(retry_due_at)
				else
					finish_scheduled_item(item, "success", entry, true, {
						code = "retry_rejected", message = tostring(retry_error or "retry admission failed"),
					}, false)
				end
				return
			end
			entry.retry_waiting_for_token = false
			entry.retry_attempt += 1
			dispatcher.metrics.retries += 1
		end
		dispatcher.in_flight += 1
		if item.lane ~= "lease_renewal" then dispatcher.normal_in_flight += 1 end
		dispatcher.metrics.max_in_flight = math.max(dispatcher.metrics.max_in_flight, dispatcher.in_flight)
		spawn_scheduled(function()
			-- A queued item can become expired after selection but before its
			-- coroutine actually starts. Check the no-new-start boundary again here.
			if finite(item.expires_at_ms) and item.expires_at_ms <= now_ms() then
				finish_scheduled_item(item, "expired", entry, true, nil, true)
				return
			end
			local started_at_ms = now_ms()
			local callback_ok, callback_result
			if type(entry) == "table" and type(entry.callback) == "function" then
				callback_ok, callback_result = pcall(entry.callback)
			else
				callback_ok, callback_result = false, "scheduled callback is missing"
			end
			local elapsed_ms = math.max(0, now_ms() - started_at_ms)
			local result_code = if type(callback_result) == "table" then callback_result.code
				elseif callback_ok and (callback_result == true or callback_result == nil) then "success"
				elseif not callback_ok then "unknown" else tostring(callback_result)
			local operation_kind = if type(entry) == "table" then entry.operation_class or entry.work_class else "scheduled_callback"
			local failed = not callback_ok or result_code == "unknown" or result_code == "budget"
				or result_code == "retryable" or result_code == "retry_rejected" or result_code == "retry_exhausted"
			governor:Observe(operation_kind, not failed, elapsed_ms, if failed then tostring(result_code or "unknown") else nil)
			local prior_service_latency = governor.latency_ewma.service
			governor.latency_ewma.service = if finite(prior_service_latency)
				then prior_service_latency * 0.8 + elapsed_ms * 0.2 else elapsed_ms
			finish_scheduled_item(item, "success", entry, callback_ok, callback_result, true)
		end)
	end
	kick_dispatcher = function()
		if dispatcher.closed or dispatcher.running then return end
		dispatcher.running = true
		spawn_scheduled(function()
			local policy = governor:Stats().policy
			local maximum = policy.max_scheduled_in_flight
			local normal_limit = math.max(0, maximum - policy.scheduler_critical_reserve)
			while dispatcher.in_flight < maximum do
				local item, status = governor:TakeNext(true)
				if item == nil and dispatcher.normal_in_flight < normal_limit then
					item, status = governor:TakeNext(false)
				end
				if item == nil then break end
				dispatch_one(item, status)
			end
			dispatcher.running = false
			if dispatcher.in_flight < governor:Stats().policy.max_scheduled_in_flight then schedule_next_wake() end
		end)
	end
	local allowed_options = {
		lane = true, due_at_ms = true, available_at_ms = true, deadline_ms = true, expires_at_ms = true,
		service_class = true, work_class = true, operation_class = true, dependencies = true,
		read_units = true, write_units = true, estimated_bytes = true, handler_slots = true, cost = true,
		max_retries = true, retry_delay_ms = true, retry_jitter_percent = true, batch_window_ms = true,
		batchable = true, on_complete = true,
	}
	function dispatcher:Schedule(owner_id, work_id, callback, schedule_options)
		if self.closed then return { code = "closed", message = "scheduler dispatcher is closed" } end
		if not valid_text(owner_id, 512) or not valid_text(work_id, 96) or type(callback) ~= "function" then
			return { code = "invalid", message = "owner_id, work_id and callback are required" }
		end
		if schedule_options == nil then schedule_options = {} end
		if type(schedule_options) ~= "table" then return { code = "invalid", message = "schedule_options must be a table" } end
		for key in pairs(schedule_options) do
			if not allowed_options[key] then return { code = "invalid", message = "unsupported scheduled-work option: " .. tostring(key) } end
		end
		local lane = schedule_options.lane or "normal"
		if lane ~= "high" and lane ~= "normal" and lane ~= "background" and lane ~= "lease_renewal" then
			return { code = "invalid", message = "unsupported scheduler lane" }
		end
		local retry_limit = if schedule_options.max_retries == nil then 0 else schedule_options.max_retries
		local retry_delay_ms = if schedule_options.retry_delay_ms == nil then 100 else schedule_options.retry_delay_ms
		local jitter = if schedule_options.retry_jitter_percent == nil
			then governor:Stats().policy.retry_jitter_percent else schedule_options.retry_jitter_percent
		if not finite(retry_limit) or math.floor(retry_limit) ~= retry_limit or retry_limit < 0 or retry_limit > 8 then
			return { code = "invalid", message = "max_retries must be an integer in 0..8" }
		end
		if not finite(retry_delay_ms) or math.floor(retry_delay_ms) ~= retry_delay_ms or retry_delay_ms < 10 or retry_delay_ms > 60000 then
			return { code = "invalid", message = "retry_delay_ms must be an integer in 10..60000" }
		end
		if not finite(jitter) or jitter < 0 or jitter > 50 then
			return { code = "invalid", message = "retry_jitter_percent must be in 0..50" }
		end
		if schedule_options.batchable ~= nil and type(schedule_options.batchable) ~= "boolean" then
			return { code = "invalid", message = "batchable must be a boolean" }
		end
		if schedule_options.on_complete ~= nil and type(schedule_options.on_complete) ~= "function" then
			return { code = "invalid", message = "on_complete must be a function" }
		end
		for _, field in ipairs({ "due_at_ms", "available_at_ms", "deadline_ms", "expires_at_ms" }) do
			if schedule_options[field] ~= nil and not finite(schedule_options[field]) then
				return { code = "invalid", message = field .. " must be finite" }
			end
		end
		if schedule_options.batch_window_ms ~= nil and (not finite(schedule_options.batch_window_ms)
			or schedule_options.batch_window_ms < 0
			or schedule_options.batch_window_ms > governor:Stats().policy.batch_window_ms)
		then
			return { code = "invalid", message = "batch_window_ms must fit the bounded scheduler window" }
		end
		self.sequence += 1
		local id = "rsjob:" .. tostring(self.sequence)
		local now = now_ms()
		local due = if finite(schedule_options.due_at_ms) then schedule_options.due_at_ms
			elseif finite(schedule_options.available_at_ms) then schedule_options.available_at_ms else now
		local work_class = schedule_options.work_class or schedule_options.operation_class or "default"
		if not valid_text(work_class, 64) then return { code = "invalid", message = "work_class must be 1..64 bytes" } end
		local batch_window = 0
		if schedule_options.batchable == true then
			local policy = governor:Stats().policy
			batch_window = if finite(schedule_options.batch_window_ms) then schedule_options.batch_window_ms else policy.batch_window_ms
			local latency = math.max(governor.latency_ewma.outbox_dispatch or 0, governor.latency_ewma.write or 0,
				governor.latency_ewma.update_async or 0, governor.latency_ewma.service or 0)
			if latency >= policy.batch_latency_ceiling_ms then batch_window = 0
			elseif latency >= policy.batch_latency_ceiling_ms * 0.75 then batch_window = math.floor(batch_window / 2) end
		end
		due = math.max(due, now + batch_window)
		if finite(schedule_options.deadline_ms) and due > schedule_options.deadline_ms then due = now end
		if finite(schedule_options.expires_at_ms) and due >= schedule_options.expires_at_ms then due = schedule_options.expires_at_ms end
		local item = {
			id = id, owner_id = owner_id, lane = lane, due_at_ms = due,
			available_at_ms = schedule_options.available_at_ms, deadline_ms = schedule_options.deadline_ms,
			expires_at_ms = schedule_options.expires_at_ms, service_class = schedule_options.service_class,
			work_class = work_class, operation_class = schedule_options.operation_class or work_class,
			dependencies = schedule_options.dependencies, read_units = schedule_options.read_units,
			write_units = schedule_options.write_units, estimated_bytes = schedule_options.estimated_bytes,
			handler_slots = schedule_options.handler_slots, cost = schedule_options.cost,
		}
		local accepted = governor:Enqueue(item)
		if type(accepted) ~= "table" or accepted.code ~= "accepted" then
			self.metrics.rejected += 1
			return { code = if type(accepted) == "table" then accepted.code else "unknown",
				message = if type(accepted) == "table" then accepted.message else "scheduler rejected work" }
		end
		self.callbacks[id] = {
			callback = callback, on_complete = schedule_options.on_complete,
			work_id = work_id, work_class = work_class,
			operation_class = schedule_options.operation_class or work_class,
			retry_attempt = 0, max_retries = retry_limit,
			retry_delay_ms = retry_delay_ms, retry_jitter_percent = jitter,
		}
		self.metrics.accepted += 1
		kick_dispatcher()
		if due > now then schedule_wake_at(due) end
		return { code = "accepted", id = id, due_at_ms = due, work_id = work_id }
	end
	function dispatcher:Kick()
		kick_dispatcher()
		schedule_next_wake()
	end
	function dispatcher:SetPolicy(policy)
		local ok, message = governor:SetPolicy(policy)
		return if ok then "success" else "invalid", message
	end
	function dispatcher:Stats()
		local snapshot = copy(self.metrics)
		snapshot.in_flight = self.in_flight
		snapshot.normal_in_flight = self.normal_in_flight
		snapshot.next_wake_due_ms = self.wake_due_ms
		snapshot.closed = self.closed
		snapshot.governor = governor:Stats()
		return snapshot
	end
	function dispatcher:Close()
		self.closed = true
		self.wake_generation += 1
		self.wake_due_ms = nil
	end
	return dispatcher
end

Scheduler.new = new_governor
Scheduler.new_dispatcher = new_dispatcher

return Scheduler
