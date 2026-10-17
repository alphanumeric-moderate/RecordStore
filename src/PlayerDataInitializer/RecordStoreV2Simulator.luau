--!nocheck
-- Deterministic fault/crash simulator infrastructure for the separate verification phase.
-- This feature-only benchmark pass does not execute fault scripts.

local Simulator = {}
Simulator.__index = Simulator
local FakeStore = {}
FakeStore.__index = FakeStore

local function copy(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > 64 then error("simulator value exceeds depth bound", 3) end
	if type(value) ~= "table" then return value end
	if seen[value] then error("cyclic simulator values are unsupported", 3) end
	seen[value] = true
	local result = {}
	for key, child in pairs(value) do result[copy(key, depth + 1, seen)] = copy(child, depth + 1, seen) end
	seen[value] = nil
	return result
end

function FakeStore.new(simulator, name)
	return setmetatable({ simulator = simulator, name = name or "default" }, FakeStore)
end

function FakeStore:GetAsync(key)
	local owner = self.simulator
	owner:_event("get_begin", self.name, key)
	local fault = owner:_take_fault("get", self.name, key)
	if fault and fault.mode == "fail_before_commit" then owner:_event("get_failed", self.name, key, fault.mode); error(fault.message or "injected GetAsync failure") end
	local result = owner.stores[self.name][key]
	owner:_event("get_end", self.name, key)
	return copy(result)
end

function FakeStore:UpdateAsync(key, transform)
	local owner = self.simulator
	owner:_event("update_begin", self.name, key)
	local fault = owner:_take_fault("update", self.name, key)
	if fault and fault.mode == "fail_before_commit" then owner:_event("update_failed", self.name, key, fault.mode); error(fault.message or "injected pre-commit UpdateAsync failure") end
	local stores = owner.stores[self.name]
	local old_value = copy(stores[key])
	local count = if fault and fault.mode == "replay_transform" then math.max(1, fault.count or 2) else math.max(1, owner.transform_replays + 1)
	local proposed
	for attempt = 1, count do
		owner.transform_attempt += 1
		owner:_event("transform_attempt", self.name, key, attempt)
		proposed = transform(copy(old_value))
	end
	if proposed ~= nil then stores[key] = copy(proposed) end
	owner:_event("update_commit", self.name, key, proposed ~= nil)
	if fault and fault.mode == "commit_then_error" then owner:_event("update_failed", self.name, key, fault.mode); error(fault.message or "injected commit-then-response-loss") end
	return copy(stores[key])
end

function FakeStore:RemoveAsync(key)
	local owner = self.simulator
	owner:_event("remove_begin", self.name, key)
	local fault = owner:_take_fault("remove", self.name, key)
	if fault and fault.mode == "fail_before_commit" then error(fault.message or "injected pre-commit RemoveAsync failure") end
	local old_value = owner.stores[self.name][key]
	owner.stores[self.name][key] = nil
	owner:_event("remove_commit", self.name, key)
	if fault and fault.mode == "commit_then_error" then error(fault.message or "injected RemoveAsync response loss") end
	return copy(old_value)
end

function Simulator.new(options)
	options = options or {}
	return setmetatable({
		now_ms = options.now_ms or 0,
		stores = {},
		faults = {},
		events = {},
		next_event = 1,
		transform_replays = 0,
		transform_attempt = 0,
		budgets = { read = math.huge, write = math.huge },
		hints = {},
		hint_policy = { drop_first = 0, duplicate_count = 0, delay_ms = 0, reverse = false },
		servers = {},
		fault_script = {},
		fault_script_cursor = 1,
	}, Simulator)
end

function Simulator:Store(name)
	name = name or "default"
	self.stores[name] = self.stores[name] or {}
	return FakeStore.new(self, name)
end

function Simulator:Advance(ms)
	assert(type(ms) == "number" and ms >= 0, "time increment must be non-negative")
	self.now_ms += ms
	self:_event("clock_advance", nil, nil, ms)
	return self.now_ms
end

function Simulator:ScheduleFault(operation, store_name, key, mode, options)
	assert(operation == "get" or operation == "update" or operation == "remove", "unknown storage operation")
	assert(mode == "fail_before_commit" or mode == "commit_then_error" or mode == "replay_transform", "unknown fault mode")
	table.insert(self.faults, {
		operation = operation, store_name = store_name, key = key, mode = mode,
		count = options and options.count, message = options and options.message,
	})
	return #self.faults
end

function Simulator:SetTransformReplayCount(count)
	assert(type(count) == "number" and count >= 0 and math.floor(count) == count, "invalid transform replay count")
	self.transform_replays = count
end

function Simulator:_take_fault(operation, store_name, key)
	for index, fault in ipairs(self.faults) do
		if fault.operation == operation and (fault.store_name == nil or fault.store_name == store_name)
			and (fault.key == nil or fault.key == key) then return table.remove(self.faults, index) end
	end
	if self.fault_script_cursor <= #self.fault_script then
		local next_fault = self.fault_script[self.fault_script_cursor]
		if next_fault.operation == operation and (next_fault.store_name == nil or next_fault.store_name == store_name)
			and (next_fault.key == nil or next_fault.key == key) then
			self.fault_script_cursor += 1
			return copy(next_fault)
		end
	end
	return nil
end

function Simulator:_event(kind, store_name, key, detail)
	local event = { sequence = self.next_event, at_ms = self.now_ms, kind = kind, store_name = store_name, key = key, detail = detail }
	self.next_event += 1
	table.insert(self.events, event)
	return event
end

function Simulator:SetBudget(kind, value)
	assert(kind == "read" or kind == "write", "budget kind must be read or write")
	assert(type(value) == "number" and value >= 0, "budget must be non-negative")
	self.budgets[kind] = value
end

function Simulator:ConsumeBudget(kind, amount)
	amount = amount or 1
	if self.budgets[kind] == math.huge then return true end
	if self.budgets[kind] < amount then self:_event("budget_rejected", nil, nil, { kind = kind, amount = amount }); return false end
	self.budgets[kind] -= amount
	return true
end

function Simulator:SetHintPolicy(policy)
	for key, value in pairs(policy) do self.hint_policy[key] = value end
end

function Simulator:PublishHint(channel, payload)
	table.insert(self.hints, { channel = channel, payload = copy(payload), due_at_ms = self.now_ms + (self.hint_policy.delay_ms or 0) })
	self:_event("hint_publish", nil, channel)
	return true
end

function Simulator:DeliverHints(handler)
	local pending, future = {}, {}
	for _, item in ipairs(self.hints) do
		if item.due_at_ms <= self.now_ms then table.insert(pending, item) else table.insert(future, item) end
	end
	self.hints = future
	if self.hint_policy.reverse then
		for left = 1, math.floor(#pending / 2) do local right = #pending - left + 1; pending[left], pending[right] = pending[right], pending[left] end
	end
	local delivered = 0
	for index, item in ipairs(pending) do
		if index <= (self.hint_policy.drop_first or 0) then
			self:_event("hint_drop", nil, item.channel)
		else
			handler(copy(item.payload), item.channel)
			delivered += 1
			self:_event("hint_deliver", nil, item.channel)
			for _ = 1, self.hint_policy.duplicate_count or 0 do handler(copy(item.payload), item.channel); self:_event("hint_duplicate", nil, item.channel) end
		end
	end
	return delivered
end

function Simulator:CrashServer(id)
	self.servers[id] = nil
	self:_event("server_crash", nil, id)
end

function Simulator:RestartServer(id, state)
	self.servers[id] = { local_state = copy(state or {}), started_at_ms = self.now_ms }
	self:_event("server_restart", nil, id)
	return self.servers[id]
end

function Simulator:SetFaultScript(script)
	assert(type(script) == "table", "fault script must be an array")
	self.fault_script = copy(script)
	self.fault_script_cursor = 1
end

function Simulator:Trace()
	return copy(self.events)
end

function Simulator:Snapshot()
	return {
		now_ms = self.now_ms, stores = copy(self.stores), faults = copy(self.faults),
		fault_script_cursor = self.fault_script_cursor, hints = copy(self.hints),
		budgets = copy(self.budgets), servers = copy(self.servers),
	}
end

Simulator.FakeStore = FakeStore
return Simulator
