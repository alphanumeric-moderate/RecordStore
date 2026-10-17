--!nocheck
-- Deterministic DataStore-shaped fake for the real RecordStore backend path under Lune.
-- This is a fault-testing model, not a claim about live Roblox service quotas or concurrency.
local FakeService = {}
FakeService.__index = FakeService
local FakeStore = {}
FakeStore.__index = FakeStore
local Pages = {}
Pages.__index = Pages

local function clone(value, seen)
	if type(value) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then error("cyclic fake DataStore values are unsupported", 3) end
	seen[value] = true
	local result = {}
	for key, child in pairs(value) do result[clone(key, seen)] = clone(child, seen) end
	seen[value] = nil
	return result
end

local function store_identity(name, scope)
	return tostring(#name) .. ":" .. name .. tostring(#scope) .. ":" .. scope
end

local function key_info(row)
	if row == nil then return nil end
	return {
		Version = row.Version,
		CreatedTime = row.CreatedTime,
		UpdatedTime = row.UpdatedTime,
		UserIds = clone(row.UserIds or {}),
		Metadata = clone(row.Metadata or {}),
		GetUserIds = function(self) return clone(self.UserIds or {}) end,
		GetMetadata = function(self) return clone(self.Metadata or {}) end,
	}
end

local function now_ms(self)
	if type(self.clock) == "function" then return self.clock() end
	return os.time() * 1000
end

function FakeService.new()
	return setmetatable({
		stores = {},
		next_version = 0,
		faults = {},
		fault_script = {},
		fault_script_cursor = 1,
		budgets = { StandardRead = math.huge, StandardWrite = math.huge, StandardList = math.huge, StandardRemove = math.huge },
		calls = { get = 0, update = 0, list_versions = 0, get_version = 0, get_version_at_time = 0, remove = 0 },
		clock = nil,
		last_updated_ms = 0,
		transform_replays = 0,
		transform_attempts = 0,
		trace = {},
		next_trace = 1,
	}, FakeService)
end

function FakeService:_event(kind, name, scope, key, detail)
	table.insert(self.trace, { sequence = self.next_trace, at_ms = now_ms(self), kind = kind,
		store_name = name, scope = scope, key = key, detail = clone(detail) })
	self.next_trace += 1
end

function FakeService:SetClock(clock)
	assert(clock == nil or type(clock) == "function", "clock must be a function or nil")
	self.clock = clock
end

function FakeService:NowMilliseconds()
	return now_ms(self)
end

function FakeService:SetBudget(request_type, budget)
	local name = if type(request_type) == "table" then request_type.Name else request_type
	assert(type(name) == "string" and self.budgets[name] ~= nil, "unsupported request budget class")
	assert(type(budget) == "number" and budget >= 0 and budget == budget, "budget must be non-negative")
	self.budgets[name] = budget
end

function FakeService:GetRequestBudgetForRequestType(request_type)
	local name = if type(request_type) == "table" then request_type.Name else request_type
	return self.budgets[name] or 0
end

function FakeService:_consume_budget(kind)
	local remaining = self.budgets[kind]
	if remaining == nil then return true end
	if remaining <= 0 then error("injected fake DataStore " .. kind .. " budget exhaustion", 3) end
	if remaining ~= math.huge then self.budgets[kind] = remaining - 1 end
	return true
end

function FakeService:ScheduleFault(operation, store_name, scope, key, mode, options)
	assert(operation == "get" or operation == "update" or operation == "list_versions"
		or operation == "get_version" or operation == "get_version_at_time" or operation == "remove",
		"unsupported fake DataStore operation")
	assert(mode == "before" or mode == "after" or mode == "replay_transform", "unsupported fake DataStore fault mode")
	assert(mode ~= "after" or operation == "update" or operation == "remove", "after-commit fault requires a mutating operation")
	assert(mode ~= "replay_transform" or operation == "update", "transform replay applies only to UpdateAsync")
	local skip_matches = options and options.skip_matches or 0
	assert(type(skip_matches) == "number" and skip_matches >= 0 and skip_matches <= 1000
		and skip_matches == math.floor(skip_matches), "skip_matches must be an integer from 0 to 1000")
	table.insert(self.faults, {
		operation = operation, store_name = store_name, scope = scope, key = key, mode = mode,
		count = options and options.count, skip_matches = skip_matches, message = options and options.message,
	})
	return #self.faults
end

function FakeService:SetFaultScript(script)
	assert(type(script) == "table", "fault script must be an array")
	local prepared = clone(script)
	for index, fault in ipairs(prepared) do
		assert(type(fault) == "table", ("fault script entry %d must be a table"):format(index))
		assert(fault.operation == "get" or fault.operation == "update" or fault.operation == "list_versions"
			or fault.operation == "get_version" or fault.operation == "get_version_at_time" or fault.operation == "remove",
			("fault script entry %d has an unsupported operation"):format(index))
		assert(fault.mode == "before" or fault.mode == "after" or fault.mode == "replay_transform",
			("fault script entry %d has an unsupported mode"):format(index))
		assert(fault.mode ~= "after" or fault.operation == "update" or fault.operation == "remove",
			("fault script entry %d uses after-commit mode for a read"):format(index))
		assert(fault.mode ~= "replay_transform" or fault.operation == "update",
			("fault script entry %d replays a non-update operation"):format(index))
	end
	self.fault_script, self.fault_script_cursor = prepared, 1
end

function FakeService:_take_fault(operation, name, scope, key)
	if self.fault_script_cursor <= #self.fault_script then
		local expected = self.fault_script[self.fault_script_cursor]
		local matches = expected.operation == operation
			and (expected.store_name == nil or expected.store_name == name)
			and (expected.scope == nil or expected.scope == scope)
			and (expected.key == nil or expected.key == key)
		if not matches then
			self:_event("fault_script_mismatch", name, scope, key, {
				index = self.fault_script_cursor, expected = clone(expected),
				actual = { operation = operation, store_name = name, scope = scope, key = key },
			})
			error(("fake DataStore fault script entry %d expected %s before %s"):format(
				self.fault_script_cursor, tostring(expected.operation), tostring(operation)
			), 3)
		end
		self.fault_script_cursor += 1
		self:_event("fault_script_consume", name, scope, key, { operation = operation, mode = expected.mode })
		return clone(expected)
	end
	for index, fault in ipairs(self.faults) do
		if fault.operation == operation
			and (fault.store_name == nil or fault.store_name == name)
			and (fault.scope == nil or fault.scope == scope)
			and (fault.key == nil or fault.key == key)
		then
			if (fault.skip_matches or 0) > 0 then
				fault.skip_matches -= 1
				self:_event("scheduled_fault_skip", name, scope, key, {
					operation = operation, remaining = fault.skip_matches, target_mode = fault.mode,
				})
			else
				table.remove(self.faults, index)
				self:_event("scheduled_fault_consume", name, scope, key, { operation = operation, mode = fault.mode })
				return fault
			end
		end
	end
	return nil
end

function FakeStore.new(service, name, scope)
	return setmetatable({ service = service, name = name, scope = scope, rows = {} }, FakeStore)
end

function FakeService:GetDataStore(name, scope)
	assert(type(name) == "string" and name ~= "", "DataStore name must be non-empty")
	scope = scope or "global"
	assert(type(scope) == "string" and scope ~= "", "DataStore scope must be non-empty")
	local identity = store_identity(name, scope)
	if self.stores[identity] == nil then self.stores[identity] = FakeStore.new(self, name, scope) end
	return self.stores[identity]
end

function FakeService:Reset()
	table.clear(self.stores); table.clear(self.faults); table.clear(self.fault_script); table.clear(self.trace)
	self.fault_script_cursor, self.next_version, self.next_trace = 1, 0, 1
	self.last_updated_ms = 0
	self.transform_replays, self.transform_attempts = 0, 0
	self.calls = { get = 0, update = 0, list_versions = 0, get_version = 0, get_version_at_time = 0, remove = 0 }
	self.budgets = { StandardRead = math.huge, StandardWrite = math.huge, StandardList = math.huge, StandardRemove = math.huge }
end

function FakeService:SetTransformReplayCount(count)
	assert(type(count) == "number" and count >= 0 and count <= 20 and count == math.floor(count),
		"transform replay count must be an integer from 0 to 20")
	self.transform_replays = count
end

function FakeService:GetRaw(store_name, scope, key)
	local row = self:GetDataStore(store_name, scope).rows[key]
	return if row == nil or row.IsDeleted then nil else clone(row.Value)
end

function FakeService:GetKeyInfo(store_name, scope, key)
	return key_info(self:GetDataStore(store_name, scope).rows[key])
end

function FakeService:Stats()
	return { calls = clone(self.calls), faults_remaining = #self.faults,
		fault_script_cursor = self.fault_script_cursor, fault_script_length = #self.fault_script,
		trace = clone(self.trace), budgets = clone(self.budgets) }
end

local function row_version(service, prior, value, user_ids, metadata, deleted)
	service.next_version += 1
	local updated_at = math.max(now_ms(service), service.last_updated_ms)
	service.last_updated_ms = updated_at
	local created_at = if prior ~= nil then prior.CreatedTime else updated_at
	local version = ("%013d-%06d"):format(updated_at, service.next_version)
	return { Version = version, Sequence = service.next_version, Value = clone(value),
		UserIds = clone(user_ids or (prior and prior.UserIds) or {}),
		Metadata = clone(metadata or (prior and prior.Metadata) or {}), CreatedTime = created_at,
		UpdatedTime = updated_at, IsDeleted = deleted == true }
end

local function current_raw(row)
	return if row == nil or row.IsDeleted then nil else clone(row.Value)
end

function FakeStore:GetAsync(key, _options)
	local service = self.service
	service.calls.get += 1; service:_consume_budget("StandardRead")
	local fault = service:_take_fault("get", self.name, self.scope, key)
	if fault and fault.mode == "before" then error(fault.message or "injected GetAsync failure", 2) end
	local row = self.rows[key]
	local raw = current_raw(row)
	service:_event("get", self.name, self.scope, key, { found = raw ~= nil })
	return raw, key_info(row)
end

function FakeStore:UpdateAsync(key, transform)
	local service = self.service
	service.calls.update += 1
	service:_consume_budget("StandardRead"); service:_consume_budget("StandardWrite")
	local fault = service:_take_fault("update", self.name, self.scope, key)
	if fault and fault.mode == "before" then error(fault.message or "injected failure before commit", 2) end
	local row = self.rows[key]
	local raw, info = current_raw(row), key_info(row)
	local next_value, next_user_ids, next_metadata
	local replay_count
	if fault and fault.mode == "replay_transform" then
		replay_count = math.max(1, fault.count or 2)
	else
		replay_count = service.transform_replays + 1
		service.transform_replays = 0
	end
	for attempt = 1, replay_count do
		service.transform_attempts += 1
		service:_event("update_transform", self.name, self.scope, key, { attempt = attempt })
		next_value, next_user_ids, next_metadata = transform(clone(raw), info)
	end
	if next_value == nil then
		service:_event("update_cancelled", self.name, self.scope, key)
		return nil, nil
	end
	local updated = row_version(service, row, next_value, next_user_ids, next_metadata, false)
	updated.Versions = clone(row and row.Versions or {})
	table.insert(updated.Versions, { Version = updated.Version, Sequence = updated.Sequence,
		Value = clone(updated.Value), UserIds = clone(updated.UserIds), Metadata = clone(updated.Metadata),
		CreatedTime = updated.CreatedTime, UpdatedTime = updated.UpdatedTime, IsDeleted = false })
	self.rows[key] = updated
	service:_event("update_commit", self.name, self.scope, key, { version = updated.Version, transform_attempts = replay_count })
	if fault and fault.mode == "after" then error(fault.message or "injected response loss after commit", 2) end
	return clone(updated.Value), key_info(updated)
end

function FakeStore:RemoveAsync(key)
	local service = self.service
	service.calls.remove += 1; service:_consume_budget("StandardRemove")
	local fault = service:_take_fault("remove", self.name, self.scope, key)
	if fault and fault.mode == "before" then error(fault.message or "injected RemoveAsync failure before commit", 2) end
	local row = self.rows[key]
	if row == nil then return nil, nil end
	local deleted = row_version(service, row, nil, row.UserIds, row.Metadata, true)
	deleted.Versions = clone(row.Versions or {})
	table.insert(deleted.Versions, { Version = deleted.Version, Sequence = deleted.Sequence,
		UserIds = clone(deleted.UserIds), Metadata = clone(deleted.Metadata), CreatedTime = deleted.CreatedTime,
		UpdatedTime = deleted.UpdatedTime, IsDeleted = true })
	self.rows[key] = deleted
	service:_event("remove_commit", self.name, self.scope, key, { version = deleted.Version })
	if fault and fault.mode == "after" then error(fault.message or "injected RemoveAsync response loss", 2) end
	return clone(row.Value), key_info(deleted)
end

function Pages:GetCurrentPage()
	return clone(self.values[self.index] or {})
end

function Pages:AdvanceToNextPageAsync()
	local service, store = self.store.service, self.store
	service:_consume_budget("StandardList")
	local fault = service:_take_fault("list_versions", store.name, store.scope, self.key)
	if fault and fault.mode == "before" then error(fault.message or "injected version-page failure", 2) end
	if self.index >= #self.values then self.IsFinished = true; return end
	self.index += 1
	self.IsFinished = self.index >= #self.values
end

local function pages_for(store, key, values, page_size)
	local pages = {}
	for start = 1, #values, page_size do
		local page = {}
		for i = start, math.min(#values, start + page_size - 1) do table.insert(page, clone(values[i])) end
		table.insert(pages, page)
	end
	if #pages == 0 then pages[1] = {} end
	return setmetatable({ store = store, key = key, values = pages, index = 1, IsFinished = #pages <= 1 }, Pages)
end

function FakeStore:ListVersionsAsync(key, sort_direction, min_date_ms, max_date_ms, page_size)
	local service = self.service
	service.calls.list_versions += 1; service:_consume_budget("StandardList")
	local fault = service:_take_fault("list_versions", self.name, self.scope, key)
	if fault and fault.mode == "before" then error(fault.message or "injected ListVersionsAsync failure", 2) end
	local row = self.rows[key]
	local values, filtered = clone(row and row.Versions or {}), {}
	for _, item in ipairs(values) do
		if (min_date_ms == nil or item.UpdatedTime >= min_date_ms) and (max_date_ms == nil or item.UpdatedTime <= max_date_ms) then
			table.insert(filtered, item)
		end
	end
	if sort_direction ~= nil and sort_direction.Name == "Descending" then
		for left = 1, math.floor(#filtered / 2) do local right = #filtered - left + 1; filtered[left], filtered[right] = filtered[right], filtered[left] end
	end
	service:_event("list_versions", self.name, self.scope, key, { count = #filtered })
	return pages_for(self, key, filtered, math.clamp(math.floor(page_size or 100), 1, 100))
end

function FakeStore:GetVersionAsync(key, version)
	local service = self.service
	service.calls.get_version += 1; service:_consume_budget("StandardRead")
	local fault = service:_take_fault("get_version", self.name, self.scope, key)
	if fault and fault.mode == "before" then error(fault.message or "injected GetVersionAsync failure", 2) end
	local row = self.rows[key]
	for _, item in ipairs(row and row.Versions or {}) do
		if item.Version == version then service:_event("get_version", self.name, self.scope, key, { version = version }); return clone(item.Value), key_info(item) end
	end
	return nil, nil
end

function FakeStore:GetVersionAtTimeAsync(key, timestamp_ms)
	local service = self.service
	service.calls.get_version_at_time += 1; service:_consume_budget("StandardRead")
	local fault = service:_take_fault("get_version_at_time", self.name, self.scope, key)
	if fault and fault.mode == "before" then error(fault.message or "injected GetVersionAtTimeAsync failure", 2) end
	local row, selected = self.rows[key], nil
	for _, item in ipairs((self.rows[key] and self.rows[key].Versions) or {}) do
		if item.UpdatedTime <= timestamp_ms and (
			selected == nil
			or item.UpdatedTime > selected.UpdatedTime
			or (item.UpdatedTime == selected.UpdatedTime and (item.Sequence or 0) > (selected.Sequence or 0))
		) then
			selected = item
		end
	end
	if selected ~= nil then service:_event("get_version_at_time", self.name, self.scope, key, { version = selected.Version }); return clone(selected.Value), key_info(selected) end
	return nil, nil
end

function FakeService:Trace()
	return clone(self.trace)
end

return FakeService
