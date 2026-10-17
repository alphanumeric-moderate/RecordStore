--!nocheck
-- Opt-in durable messaging v2 service layer. Requiring this module has no side effects.
-- Cross-key workflows are sagas, indexes are eventual, and local scheduling is not durable.

local V2 = {}
local MAX_REQUEST_BYTES = 16384
local MAX_BATCH_ITEMS = 16
local MAX_INBOX_RECEIPTS = 128
local MAX_INBOX_RECEIPT_BYTES = 4096
local MAX_TRACE_EVENTS = 2048
local MAX_ERASURE_TEMPLATES = 100
local MAX_ERASURE_ITEMS = 512
local RESERVED = "__recordstore_v2_"

local resolved_task_api = false
local cached_task_api = nil
local function spawn_scheduled(callback)
	if not resolved_task_api then
		resolved_task_api = true
		local global_ok, global_value = pcall(function() return task end)
		if global_ok and type(global_value) == "table" and type(global_value.spawn) == "function" then
			cached_task_api = global_value
		else
			local module_ok, module_value = pcall(require, "@lune/task")
			if module_ok and type(module_value) == "table" and type(module_value.spawn) == "function" then
				cached_task_api = module_value
			end
		end
	end
	if cached_task_api ~= nil then cached_task_api.spawn(callback) else callback() end
end

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function copy(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > 64 then error("value exceeds maximum depth", 3) end
	if type(value) ~= "table" then return value end
	if seen[value] then error("cyclic table is unsupported", 3) end
	seen[value] = true
	local result = {}
	for key, child in pairs(value) do result[copy(key, depth + 1, seen)] = copy(child, depth + 1, seen) end
	seen[value] = nil
	return result
end

local function canonical(value, stack, depth)
	stack = stack or {}
	depth = depth or 0
	if depth > 64 then error("value exceeds maximum depth", 3) end
	local kind = type(value)
	if value == nil then return "n" end
	if kind == "boolean" then return if value then "b1" else "b0" end
	if kind == "number" then
		if not finite(value) then error("non-finite number", 3) end
		return if value == 0 then "d0" else "d" .. string.format("%.17g", value)
	end
	if kind == "string" then return "s" .. tostring(#value) .. ":" .. value end
	if kind ~= "table" then error("unsupported protocol type " .. kind, 3) end
	if stack[value] then error("cyclic table is unsupported", 3) end
	stack[value] = true
	local count, numeric, string_keys, max_index = 0, true, true, 0
	for key in pairs(value) do
		count += 1
		if type(key) ~= "number" or not finite(key) or math.floor(key) ~= key or key < 1 then numeric = false
		else max_index = math.max(max_index, key) end
		if type(key) ~= "string" then string_keys = false end
	end
	local result
	if count > 0 and numeric and max_index == count then
		local parts = {}
		for i = 1, count do parts[i] = canonical(value[i], stack, depth + 1) end
		result = "a" .. tostring(count) .. "[" .. table.concat(parts, "") .. "]"
	elseif count == 0 or string_keys then
		local keys = {}
		for key in pairs(value) do table.insert(keys, key) end
		table.sort(keys)
		local parts = {}
		for _, key in ipairs(keys) do
			parts[#parts + 1] = canonical(key, stack, depth + 1)
			parts[#parts + 1] = canonical(value[key], stack, depth + 1)
		end
		result = "o" .. tostring(#keys) .. "{" .. table.concat(parts, "") .. "}"
	else
		stack[value] = nil
		error("mixed, sparse, or unsupported object keys", 3)
	end
	stack[value] = nil
	return result
end

-- Compact route fingerprint only. Exact canonical material is persisted on transaction receipts.
local function digest(text)
	local a, b = 5381, 1
	for i = 1, #text do
		local byte = string.byte(text, i)
		a = (a * 33 + byte) % 2147483647
		b = (b * 65599 + byte) % 2147483629
	end
	return tostring(#text) .. "-" .. string.format("%08x%08x", a, b)
end

local function pure(fn, ...)
	if type(fn) ~= "function" then return nil, "callback must be a function" end
	local args = table.pack(...)
	local result
	local thread = coroutine.create(function() result = table.pack(pcall(fn, table.unpack(args, 1, args.n))) end)
	local resumed, resume_error = coroutine.resume(thread)
	if not resumed then return nil, tostring(resume_error) end
	if coroutine.status(thread) ~= "dead" then coroutine.close(thread); return nil, "callback must not yield" end
	if result == nil then return nil, "callback did not return" end
	if not result[1] then return nil, tostring(result[2]) end
	return table.unpack(result, 2, result.n)
end

-- Adapter callbacks may yield; UpdateAsync transforms must use pure() instead.
local function io_call(fn, ...)
	if type(fn) ~= "function" then return nil, "callback must be a function" end
	local args = table.pack(...)
	local result = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
	if not result[1] then return nil, tostring(result[2]) end
	return table.unpack(result, 2, result.n)
end

local function key_count(value)
	local n = 0
	if type(value) == "table" then for _ in pairs(value) do n += 1 end end
	return n
end

local function text_error(value, maximum)
	return string.sub(string.gsub(tostring(value or ""), "[^ -~]", "?"), 1, maximum)
end

local function normalize_result(code, message)
	local mapping = {
		success = "committed", created = "committed", saved = "committed", loaded = "committed",
		duplicate = "duplicate", conflict = "conflict", capacity = "capacity", unknown = "unknown",
		fenced = "fenced", closing = "fenced", busy = "retryable", budget = "retryable",
		retry_exhausted = "retryable", future_schema = "unsupported_schema", invalid = "invalid",
		validation = "invalid", corrupt = "corrupt", tombstoned = "erased", not_found = "not_found",
	}
	return { code = mapping[code] or tostring(code or "unknown"), native_code = code, message = message }
end

local function adapter_call(store, method, ...)
	if type(store) ~= "table" and type(store) ~= "userdata" then return nil, "storage adapter is missing" end
	local args = table.pack(...)
	local result = table.pack(pcall(function()
		local fn = store[method]
		if type(fn) ~= "function" then error("storage adapter lacks " .. method) end
		return fn(store, table.unpack(args, 1, args.n))
	end))
	if not result[1] then return nil, tostring(result[2]) end
	return result[2], nil
end

local function record_data(record)
	if type(record) ~= "table" or type(record.Get) ~= "function" then return nil, "active Record with Get is required" end
	local data, message = io_call(function() return record:Get() end)
	if data == nil then return nil, message or "record data is unavailable" end
	return data, nil
end

local function record_stats(record)
	if type(record) ~= "table" or type(record.Stats) ~= "function" then return {} end
	local stats = io_call(function() return record:Stats() end)
	return if type(stats) == "table" then stats else {}
end

local function request_material(value)
	local ok, material = pcall(canonical, value)
	if not ok then return nil, tostring(material) end
	if #material > MAX_REQUEST_BYTES then return nil, "canonical request exceeds the exact-material bound" end
	return material, nil
end

local function transaction_run(record, operation_id, request, reducer, mode, events)
	if type(record) ~= "table" then return { code = "invalid", message = "record is required" } end
	if not valid_text(operation_id, 128) then return { code = "invalid", message = "operation_id must be 1 to 128 bytes" } end
	if type(reducer) ~= "function" then return { code = "invalid", message = "reducer must be a pure non-yielding function" } end
	local material, material_error = request_material(request)
	if not material then return { code = "invalid", message = material_error } end
	local fingerprint = digest(material)
	local fn = if mode == "inbox" then record.ApplyInboxAsync elseif mode == "outbox" then record.CommitWithOutboxAsync else record.TransactAsync
	if type(fn) ~= "function" then return { code = "invalid", message = "record lacks the requested transaction API" } end
	local function transform(data)
		-- Erasure fencing must share the atomic profile-key mutation boundary.
		-- An out-of-key IsErased lookup is advisory and may race this transform.
		if type(data) == "table" then
			local tombstone = data[RESERVED .. "erasure_tombstone"]
			if tombstone ~= nil and tombstone ~= false then
				error("v2 profile mutation is blocked by the durable erasure tombstone")
			end
		end
		local next_data, reducer_error = pure(reducer, data, request)
		if next_data == nil then error("v2 reducer rejected request: " .. tostring(reducer_error or "returned nil")) end
		return next_data
	end
	local code, message
	if mode == "outbox" then
		code, message = fn(record, operation_id, fingerprint, transform, events or {}, material)
	else
		code, message = fn(record, operation_id, fingerprint, transform, material)
	end
	return normalize_result(code, message)
end

local function dense_array(value, maximum)
	if type(value) ~= "table" then return false, "expected array" end
	local length = #value
	if length < 1 or length > maximum then return false, "array size must be 1.." .. tostring(maximum) end
	for key in pairs(value) do
		if type(key) ~= "number" or not finite(key) or math.floor(key) ~= key or key < 1 or key > length then return false, "array must be dense" end
	end
	return true, nil
end

local function normalize_message(item)
	if type(item) ~= "table" then return nil, "message must be a table" end
	local id = item.message_id or item.MessageId or item.id
	local kind = item.message_type or item.MessageType or item.type
	local payload = if item.payload ~= nil then item.payload else item.Payload
	local version = item.payload_version or item.PayloadVersion or item.version or 1
	if not valid_text(id, 256) then return nil, "message_id must be 1..256 bytes" end
	if not valid_text(kind, 100) then return nil, "message_type must be 1..100 bytes" end
	if not finite(version) or math.floor(version) ~= version or version < 1 then return nil, "payload version must be a positive integer" end
	local material, message = request_material({ message_id = id, message_type = kind, payload_version = version, payload = payload })
	if not material then return nil, message end
	if #material > MAX_INBOX_RECEIPT_BYTES then return nil, "single inbox receipt exceeds its byte budget" end
	return { message_id = id, message_type = kind, payload = payload, payload_version = version, canonical_request = material }, nil
end

local function new_inbox()
	local service = {}
	function service.ApplyBatch(record, batch_id, items, reducer, options)
		options = options or {}
		if not valid_text(batch_id, 96) then return { code = "invalid", message = "batch_id must be 1..96 bytes" } end
		if type(reducer) ~= "function" then return { code = "invalid", message = "reducer required" } end
		local valid, array_message = dense_array(items, math.clamp(math.floor(options.max_batch_items or MAX_BATCH_ITEMS), 1, MAX_BATCH_ITEMS))
		if not valid then return { code = "invalid", message = array_message } end
		local normalized, seen, total_bytes = {}, {}, 0
		for index, item in ipairs(items) do
			local message, message_error = normalize_message(item)
			if not message then return { code = "invalid", message = ("item %d: %s"):format(index, message_error or "invalid") } end
			if seen[message.message_id] then return { code = "conflict", message = "batch repeats message_id" } end
			seen[message.message_id] = true
			total_bytes += #message.canonical_request
			normalized[index] = message
		end
		if total_bytes > MAX_REQUEST_BYTES then return { code = "capacity", message = "batch request material exceeds the bounded receipt budget" } end
		local request = { batch_id = batch_id, items = normalized }
		local applied, duplicates = 0, 0
		local result = transaction_run(record, "rv2:inbox:" .. digest(batch_id), request, function(current)
			if type(current) ~= "table" then error("inbox batching requires table profile data") end
			local data = copy(current)
			local receipts = data[RESERVED .. "inbox_receipts"] or {}
			if type(receipts) ~= "table" then error("inbox receipt namespace is malformed") end
			local count = key_count(receipts)
			applied, duplicates = 0, 0
			for _, message in ipairs(normalized) do
				local prior = receipts[message.message_id]
				if prior then
					if type(prior) ~= "table" or prior.canonical_request ~= message.canonical_request then error("message_id reused with different exact request material") end
					duplicates += 1
				else
					if count >= (options.max_receipts or MAX_INBOX_RECEIPTS) then error("inbox receipt capacity reached; retention pruning is required") end
					local changed, reducer_error = pure(reducer, data, copy(message.payload), copy(message))
					if type(changed) ~= "table" then error("inbox reducer rejected item: " .. tostring(reducer_error)) end
					data = changed
					receipts = data[RESERVED .. "inbox_receipts"] or receipts
					if type(receipts) ~= "table" then error("reducer corrupted reserved inbox receipt namespace") end
					receipts[message.message_id] = {
						canonical_request = message.canonical_request,
						message_type = message.message_type,
						payload_version = message.payload_version,
						received_at = if finite(options.now_unix) then options.now_unix else os.time(),
					}
					data[RESERVED .. "inbox_receipts"] = receipts
					count += 1
					applied += 1
				end
			end
			data[RESERVED .. "inbox_receipts"] = receipts
			return data
		end, "inbox")
		result.batch_id = batch_id
		result.applied = if result.code == "committed" then applied else 0
		result.duplicates = duplicates
		result.count = #normalized
		return result
	end
	function service.ApplyAsync(record, message, reducer, options)
		local normalized, message_error = normalize_message(message)
		if not normalized then return { code = "invalid", message = message_error } end
		return service.ApplyBatch(record, "single-" .. digest(normalized.message_id), { message }, reducer, options)
	end
	function service.PruneReceipts(record, older_than_unix, max_items, operation_id)
		if not finite(older_than_unix) then return { code = "invalid", message = "cutoff must be finite Unix seconds" } end
		max_items = math.clamp(math.floor(max_items or 16), 1, MAX_INBOX_RECEIPTS)
		operation_id = operation_id or ("rv2:inbox-prune:" .. digest(tostring(older_than_unix) .. ":" .. tostring(max_items)))
		return transaction_run(record, operation_id, { older_than_unix = older_than_unix, max_items = max_items }, function(current)
			if type(current) ~= "table" then error("table profile data required") end
			local data = copy(current)
			local receipts = data[RESERVED .. "inbox_receipts"] or {}
			local eligible = {}
			for id, receipt in pairs(receipts) do
				if type(receipt) == "table" and finite(receipt.received_at) and receipt.received_at < older_than_unix then table.insert(eligible, id) end
			end
			table.sort(eligible)
			local pruned = math.min(max_items, #eligible)
			for index = 1, pruned do receipts[eligible[index]] = nil end
			data[RESERVED .. "inbox_receipts"] = receipts
			return data
		end)
	end
	return service
end

local function new_outbox()
	local service = {}
	function service.DispatchBatches(record, dispatcher, batch_size, max_batches)
		batch_size = math.clamp(math.floor(batch_size or 8), 1, 16)
		max_batches = math.clamp(math.floor(max_batches or 4), 1, 32)
		if type(record) ~= "table" or (type(record.DispatchOutboxBatchAsync) ~= "function" and type(record.DispatchOutboxAsync) ~= "function") then return { code = "invalid", dispatched = 0 } end
		local total = 0
		for batch = 1, max_batches do
			local method = if type(record.DispatchOutboxBatchAsync) == "function" then record.DispatchOutboxBatchAsync else record.DispatchOutboxAsync
			local count, code, message = method(record, dispatcher, batch_size)
			total += count or 0
			if code == "duplicate" then return { code = "committed", dispatched = total, batches = batch - 1 } end
			if code ~= "success" then return { code = normalize_result(code, message).code, dispatched = total, message = message } end
			if message then return { code = "retryable", dispatched = total, message = message } end
			if (count or 0) < batch_size then return { code = "committed", dispatched = total, batches = batch } end
		end
		return { code = "incomplete", dispatched = total, batches = max_batches, message = "batch cap reached; resume later" }
	end
	function service.PruneBatches(record, cutoff_ms, batch_size, max_batches)
		batch_size = math.clamp(math.floor(batch_size or 16), 1, 32)
		max_batches = math.clamp(math.floor(max_batches or 4), 1, 32)
		local total = 0
		for batch = 1, max_batches do
			local count, code, message = record:PruneOutboxAsync(cutoff_ms, batch_size)
			if code == "success" then total += count or 0
			elseif code == "duplicate" then return { code = "committed", pruned = total, batches = batch - 1 }
			else return { code = normalize_result(code, message).code, pruned = total, message = message } end
			if (count or 0) < batch_size then return { code = "committed", pruned = total, batches = batch } end
		end
		return { code = "incomplete", pruned = total, message = "batch cap reached; resume later" }
	end
	function service.PruneTransactionReceiptsBatches(record, cutoff_ms, batch_size, max_batches)
		batch_size = math.clamp(math.floor(batch_size or 16), 1, 32)
		max_batches = math.clamp(math.floor(max_batches or 4), 1, 32)
		local total = 0
		for batch = 1, max_batches do
			local count, code, message = record:PruneTransactionReceiptsAsync(cutoff_ms, batch_size)
			if code == "success" then total += count or 0
			elseif code == "duplicate" then return { code = "committed", pruned = total, batches = batch - 1 }
			else return { code = normalize_result(code, message).code, pruned = total, message = message } end
			if (count or 0) < batch_size then return { code = "committed", pruned = total, batches = batch } end
		end
		return { code = "incomplete", pruned = total, message = "batch cap reached; resume later" }
	end
	return service
end

local dirty_seen = setmetatable({}, { __mode = "k" })

local function new_governor(options)
	options = options or {}
	local function now_ms() return if type(options.now_ms) == "function" then options.now_ms() else os.clock() * 1000 end end
	local governor = {
		policy = {
			revision = 1, mode = "normal", max_in_flight = 32, critical_reserve = 4,
			queue_capacity = 1024, max_batch = 16, batch_window_ms = 5,
			batch_latency_ceiling_ms = 40, high_burst = 4, retry_token_capacity = 32,
			retry_tokens_per_second = 4, minimum_budget = 2, circuit_threshold = 5, circuit_cooldown_ms = 15000,
		},
		in_flight = 0, by_class = {}, queue = {}, due = {}, completed = {}, known = {},
		owner_finish = {}, high_streak = 0, retry_tokens = 32, last_token_time = now_ms(),
		last_budget = nil, last_budget_by_kind = {}, latency_ewma = {}, consecutive_errors = {}, circuits = {},
		stats = { admitted = 0, rejected = 0, completed = 0, throttled = 0, errors = 0 },
	}
	local limits = { critical = 32, profile_save = 32, profile_release = 32, interactive = 24, messaging = 20, migration = 4, maintenance = 2, tracing = 1 }
	local function policy_valid(policy)
		if type(policy) ~= "table" then return false, "policy must be a table" end
		local fields = { "revision", "max_in_flight", "critical_reserve", "queue_capacity", "max_batch", "batch_window_ms", "batch_latency_ceiling_ms", "high_burst", "retry_token_capacity", "retry_tokens_per_second", "minimum_budget", "circuit_threshold", "circuit_cooldown_ms" }
		for _, field in ipairs(fields) do if not finite(policy[field]) then return false, "policy." .. field .. " must be finite" end end
		if policy.mode ~= "normal" and policy.mode ~= "reject_noncritical" and policy.mode ~= "bounded_buffer" and policy.mode ~= "read_only" then return false, "invalid degraded mode" end
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
		return true, nil
	end
	function governor:SetPolicy(patch)
		if type(patch) ~= "table" or not finite(patch.revision) or patch.revision <= self.policy.revision then return false, "policy revision must increase" end
		local allowed = {
			revision = true, mode = true, max_in_flight = true, critical_reserve = true, queue_capacity = true,
			max_batch = true, batch_window_ms = true, batch_latency_ceiling_ms = true, high_burst = true,
			retry_token_capacity = true, retry_tokens_per_second = true, minimum_budget = true,
			circuit_threshold = true, circuit_cooldown_ms = true,
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
	function governor:AcquireRetryToken()
		local now = now_ms()
		self.retry_tokens = math.min(self.policy.retry_token_capacity, self.retry_tokens + math.max(0, now - self.last_token_time) / 1000 * self.policy.retry_tokens_per_second)
		self.last_token_time = now
		if self.retry_tokens < 1 then
			return false, if self.policy.retry_tokens_per_second > 0 then math.ceil((1 - self.retry_tokens) / self.policy.retry_tokens_per_second * 1000) else math.huge
		end
		self.retry_tokens -= 1
		return true, 0
	end
	function governor:ChooseBatchSize(requested, latency_ms)
		local maximum = math.min(math.clamp(math.floor(requested or self.policy.max_batch), 1, 16), self.policy.max_batch)
		latency_ms = if finite(latency_ms) then latency_ms else 0
		if latency_ms >= self.policy.batch_latency_ceiling_ms then return 1 end
		if latency_ms >= self.policy.batch_latency_ceiling_ms * 0.75 then return math.max(1, math.floor(maximum / 2)) end
		return maximum
	end
	function governor:ScheduleDue(id, due_at_ms, value)
		if not valid_text(id, 128) or not finite(due_at_ms) then return false, "invalid due item" end
		self.due[id] = { id = id, due_at_ms = due_at_ms, value = copy(value) }
		return true
	end
	function governor:PopDue(limit)
		limit = math.clamp(math.floor(limit or 32), 1, 256)
		local ids = {}
		for id, item in pairs(self.due) do if item.due_at_ms <= now_ms() then table.insert(ids, id) end end
		table.sort(ids, function(a, b)
			local x, y = self.due[a], self.due[b]
			if x.due_at_ms ~= y.due_at_ms then return x.due_at_ms < y.due_at_ms end
			return a < b
		end)
		local result = {}
		for i = 1, math.min(limit, #ids) do local id = ids[i]; table.insert(result, self.due[id]); self.due[id] = nil end
		return result
	end
	function governor:Enqueue(item)
		if type(item) ~= "table" or not valid_text(item.id, 128) or not valid_text(item.owner_id, 128) then return { code = "invalid" } end
		if self.known[item.id] then return { code = "duplicate" } end
		if #self.queue >= self.policy.queue_capacity then self.stats.rejected += 1; return { code = "capacity", message = "local queue full; no accepted durable work is evicted" } end
		local lane = item.lane or "normal"
		if lane ~= "high" and lane ~= "normal" and lane ~= "background" and lane ~= "lease_renewal" then return { code = "invalid", message = "unsupported lane" } end
		local value = copy(item)
		value.lane, value.original_lane = lane, lane
		value.cost = value.cost or 1
		value.enqueued_at_ms = now_ms()
		value.due_at_ms = value.due_at_ms or value.enqueued_at_ms
		value.dependencies = value.dependencies or {}
		self.known[value.id] = value
		table.insert(self.queue, value)
		for _, dependent in ipairs(self.queue) do
			if dependent.lane == "high" then
				for _, prerequisite_id in ipairs(dependent.dependencies) do
					local prerequisite = self.known[prerequisite_id]
					if prerequisite and prerequisite.lane == "background" then prerequisite.lane = "normal"; prerequisite.inherited_priority = true end
				end
			end
		end
		return { code = "accepted", count = #self.queue }
	end
	local function choose_index(self)
		local now, eligible = now_ms(), {}
		for index, item in ipairs(self.queue) do
			local ready = (item.due_at_ms or 0) <= now
			for _, dependency in ipairs(item.dependencies or {}) do if not self.completed[dependency] then ready = false break end end
			if ready and (not item.expires_at_ms or item.expires_at_ms > now) then table.insert(eligible, { index = index, item = item }) end
		end
		for _, row in ipairs(eligible) do
			local item = row.item
			if item.lane == "lease_renewal" and item.deadline_ms and item.deadline_ms - now <= 5000 then return row.index end
		end
		local high, regular, background = {}, {}, {}
		for _, row in ipairs(eligible) do
			if row.item.lane == "high" then table.insert(high, row)
			elseif row.item.lane == "background" then table.insert(background, row)
			else table.insert(regular, row) end
		end
		local candidates
		if #high > 0 and self.high_streak < self.policy.high_burst then candidates = high
		elseif #regular > 0 then
			candidates = regular
			for _, row in ipairs(background) do if now - row.item.enqueued_at_ms >= 10000 then candidates = background break end end
		elseif #background > 0 then candidates = background else candidates = high end
		local best, best_score
		for _, row in ipairs(candidates or {}) do
			local item = row.item
			local weight = if item.lane == "high" then 4 elseif item.lane == "background" then 1 else 2
			local finish = self.owner_finish[item.owner_id] or 0
			local age_bonus = math.min(60000, math.max(0, now - item.enqueued_at_ms)) / 100
			local deadline_bonus = if item.deadline_ms then math.max(0, 5000 - (item.deadline_ms - now)) / 50 else 0
			local score = finish - weight * 1000 - age_bonus - deadline_bonus
			if best_score == nil or score < best_score then best, best_score = row.index, score end
		end
		return best
	end
	function governor:TakeNext()
		local now = now_ms()
		for index = #self.queue, 1, -1 do
			local item = self.queue[index]
			if item.expires_at_ms and item.expires_at_ms <= now then self.known[item.id] = nil; table.remove(self.queue, index) end
		end
		local index = choose_index(self)
		if not index then return nil, "empty" end
		local item = table.remove(self.queue, index)
		if item.lane == "high" then self.high_streak += 1 else self.high_streak = 0 end
		local weight = if item.lane == "high" then 4 elseif item.lane == "background" then 1 else 2
		self.owner_finish[item.owner_id] = (self.owner_finish[item.owner_id] or 0) + (item.cost or 1) / weight
		item.selected_at_ms = now
		return item, "success"
	end
	function governor:MarkCompleted(id)
		if not valid_text(id, 128) then return false, "invalid id" end
		self.completed[id] = true; self.known[id] = nil
		return true
	end
	function governor:ShadowNext()
		local shadow = { queue = copy(self.queue), completed = copy(self.completed), known = copy(self.known), owner_finish = copy(self.owner_finish), high_streak = self.high_streak, policy = self.policy }
		local index = choose_index(shadow)
		return if index then copy(self.queue[index]) else nil
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
	function governor:GetDurabilitySLO(record, threshold)
		local stats, now = record_stats(record), if type(options.now_unix) == "function" then options.now_unix() else os.time()
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
		local stats = record_stats(record)
		return { state = stats.state, busy = stats.busy == 1, queue_busy = stats.queue_busy == 1, takeover_requested = stats.takeover_requested == 1, generation = stats.generation, revision = stats.revision, last_error = stats.last_error, can_force_takeover = false }
	end
	function governor:Stats()
		local lanes = { high = 0, normal = 0, background = 0, lease_renewal = 0 }
		for _, item in ipairs(self.queue) do lanes[item.lane] = (lanes[item.lane] or 0) + 1 end
		return { policy = copy(self.policy), in_flight = self.in_flight, queue_items = #self.queue, lanes = lanes, classes = copy(self.by_class), stats = copy(self.stats), latency_ewma = copy(self.latency_ewma), circuits = copy(self.circuits), last_budget_by_kind = copy(self.last_budget_by_kind), retry_tokens = self.retry_tokens }
	end
	return governor
end

local runtime_governors_by_record_store = setmetatable({}, { __mode = "k" })

local function shared_runtime_governor(record_store, options)
	local governor = runtime_governors_by_record_store[record_store]
	if governor == nil then
		governor = new_governor(options)
		runtime_governors_by_record_store[record_store] = governor
	end
	return governor
end

local function path_diff(left, right, options)
	options = options or {}
	local max_nodes = math.clamp(math.floor(options.max_nodes or 256), 1, 2048)
	local max_bytes = math.clamp(math.floor(options.max_bytes or 16384), 256, 131072)
	local changes, nodes, bytes, truncated = {}, 0, 0, false
	local function add(path, before, after)
		nodes += 1
		local row = { path = string.sub(path, 1, 256), old_type = type(before), new_type = type(after) }
		local old_ok, old_text = pcall(canonical, before)
		local new_ok, new_text = pcall(canonical, after)
		row.old_digest = if old_ok then digest(old_text) else nil
		row.new_digest = if new_ok then digest(new_text) else nil
		bytes += #row.path + 128
		if #changes >= max_nodes or bytes > max_bytes then truncated = true; return end
		table.insert(changes, row)
	end
	local function walk(a, b, path, depth)
		if truncated then return end
		if depth > 32 then truncated = true; return end
		if type(a) ~= "table" or type(b) ~= "table" then
			local a_ok, a_text = pcall(canonical, a)
			local b_ok, b_text = pcall(canonical, b)
			if not a_ok or not b_ok or a_text ~= b_text then add(path, a, b) end
			return
		end
		local keys, sorted = {}, {}
		for key in pairs(a) do if type(key) == "string" or type(key) == "number" then keys[tostring(key)] = key end end
		for key in pairs(b) do if type(key) == "string" or type(key) == "number" then keys[tostring(key)] = key end end
		for key in pairs(keys) do table.insert(sorted, key) end
		table.sort(sorted)
		for _, key_text in ipairs(sorted) do
			local key, av, bv = keys[key_text], a[keys[key_text]], b[keys[key_text]]
			if av == nil or bv == nil then if av ~= bv then add(path .. "/" .. key_text, av, bv) end
			else walk(av, bv, path .. "/" .. key_text, depth + 1) end
			if truncated then return end
		end
	end
	walk(left, right, "$", 0)
	return { changes = changes, truncated = truncated, nodes_examined = nodes, bytes_budget = max_bytes }
end

local function new_tracer(options)
	options = options or {}
	local capacity = math.clamp(math.floor(options.max_events or 256), 16, MAX_TRACE_EVENTS)
	local sample_every = math.clamp(math.floor(options.success_sample_every or 1), 1, 10000)
	local tracer = { events = {}, next_sequence = 1, dropped = 0, emitted = 0, sampled = 0, store = options.store }
	function tracer:Emit(event)
		if type(event) ~= "table" then return false, "trace event required" end
		local result = tostring(event.result or "unknown")
		local always = result == "unknown" or result == "corrupt" or result == "failed" or result == "conflict"
		if not always and result == "success" then self.sampled += 1; if self.sampled % sample_every ~= 0 then return true, "sampled_out" end end
		local value = {
			sequence = self.next_sequence, timestamp_unix = if finite(event.timestamp_unix) then event.timestamp_unix else os.time(),
			operation_id = if valid_text(event.operation_id, 128) then event.operation_id else nil,
			correlation_id = if valid_text(event.correlation_id, 128) then event.correlation_id else nil,
			causation_id = if valid_text(event.causation_id, 128) then event.causation_id else nil,
			component = if valid_text(event.component, 64) then event.component else "unknown",
			operation = if valid_text(event.operation, 64) then event.operation else "unknown",
			state = if valid_text(event.state, 64) then event.state else nil, result = result,
			attempt = if finite(event.attempt) then event.attempt else nil,
			duration_bucket_ms = if finite(event.duration_ms) then math.floor(math.max(0, event.duration_ms) / 10) * 10 else nil,
			revision = if finite(event.revision) then event.revision else nil,
			error_category = if valid_text(event.error_category, 64) then event.error_category else nil,
			complete = event.complete ~= false,
		}
		self.next_sequence += 1; self.emitted += 1
		table.insert(self.events, value)
		while #self.events > capacity do table.remove(self.events, 1); self.dropped += 1 end
		return true, nil
	end
	function tracer:GetOperationTrace(operation_id, limit)
		if not valid_text(operation_id, 128) then return { code = "invalid", events = {} } end
		local matches = {}
		for _, event in ipairs(self.events) do
			if event.operation_id == operation_id or event.correlation_id == operation_id or event.causation_id == operation_id then table.insert(matches, copy(event)) end
		end
		limit = math.clamp(math.floor(limit or 128), 1, 256)
		local truncated = #matches > limit
		while #matches > limit do table.remove(matches, 1) end
		return { code = "success", events = matches, truncated = truncated or self.dropped > 0, dropped_local_events = self.dropped, completeness = if self.dropped == 0 and not truncated then "local_ring_complete" else "incomplete", note = "not a linearizable cross-server snapshot" }
	end
	function tracer:FlushAsync(operation_id, maximum)
		if not self.store then return { code = "unsupported", message = "no durable trace adapter configured" } end
		if not valid_text(operation_id, 128) then return { code = "invalid" } end
		maximum = math.clamp(math.floor(maximum or 32), 1, 128)
		local batch = {}
		for _, event in ipairs(self.events) do
			if event.operation_id == operation_id or event.correlation_id == operation_id or event.causation_id == operation_id then table.insert(batch, copy(event)); if #batch >= maximum then break end end
		end
		if #batch == 0 then return { code = "empty", flushed = 0 } end
		local key = "rv2t-" .. digest(operation_id)
		local stored, write_error = adapter_call(self.store, "UpdateAsync", key, function(old)
			if old ~= nil and old.operation_id ~= operation_id then return old end
			local next_value = if type(old) == "table" then copy(old) else { version = 1, operation_id = operation_id, events = {}, truncated = false }
			for _, event in ipairs(batch) do
				local found = false
				for _, prior in ipairs(next_value.events) do if prior.sequence == event.sequence then found = true break end end
				if not found then table.insert(next_value.events, event) end
			end
			table.sort(next_value.events, function(a, b) return a.sequence < b.sequence end)
			while #next_value.events > 128 do table.remove(next_value.events, 1); next_value.truncated = true end
			next_value.updated_at = os.time()
			return next_value
		end)
		if write_error then return { code = "unknown", flushed = 0, message = write_error } end
		if type(stored) ~= "table" or stored.operation_id ~= operation_id then return { code = "conflict", flushed = 0 } end
		return { code = "committed", flushed = #batch, retained = #stored.events, truncated = stored.truncated }
	end
	function tracer:GetOperationTraceAsync(operation_id, limit)
		local result = self:GetOperationTrace(operation_id, limit)
		if not self.store then return result end
		local stored, read_error = adapter_call(self.store, "GetAsync", "rv2t-" .. digest(operation_id))
		if read_error then result.durable_read = "unknown"; result.message = read_error; return result end
		if not stored then result.durable_read = "not_found"; return result end
		if stored.operation_id ~= operation_id then return { code = "conflict", events = {} } end
		local merged, seen = {}, {}
		for _, event in ipairs(stored.events or {}) do local id = tostring(event.sequence); if not seen[id] then seen[id] = true; table.insert(merged, copy(event)) end end
		for _, event in ipairs(result.events) do local id = tostring(event.sequence); if not seen[id] then seen[id] = true; table.insert(merged, copy(event)) end end
		table.sort(merged, function(a, b) return a.sequence < b.sequence end)
		limit = math.clamp(math.floor(limit or 128), 1, 256)
		while #merged > limit do table.remove(merged, 1); result.truncated = true end
		result.events, result.durable_read = merged, "success"
		result.truncated = result.truncated or stored.truncated == true
		return result
	end
	function tracer:Drain(limit)
		limit = math.clamp(math.floor(limit or 64), 1, 256)
		local result = {}
		for _ = 1, math.min(limit, #self.events) do table.insert(result, table.remove(self.events, 1)) end
		return result
	end
	function tracer:Stats() return { retained = #self.events, capacity = capacity, dropped = self.dropped, emitted = self.emitted, sampled = self.sampled } end
	return tracer
end

local function new_migrations()
	local registry = { steps = {}, ids = {}, local_status = {} }
	function registry:Register(store_name, from_version, to_version, id, revision, migrate, validate, metadata)
		if not valid_text(store_name, 50) or not finite(from_version) or not finite(to_version) or from_version < 0
			or math.floor(from_version) ~= from_version or to_version ~= from_version + 1
			or not valid_text(id, 96) or not valid_text(revision, 96) or type(migrate) ~= "function"
			or (validate ~= nil and type(validate) ~= "function")
		then return false, "migration requires stable IDs, declared consecutive versions, transform and optional validator" end
		local prior = self.ids[id]
		if prior then
			if prior.revision ~= revision or prior.store_name ~= store_name or prior.from_version ~= from_version or prior.to_version ~= to_version then return false, "migration ID reused with incompatible metadata" end
			return true, "duplicate"
		end
		self.steps[store_name] = self.steps[store_name] or {}
		if self.steps[store_name][from_version] then return false, "ambiguous migration path" end
		local step = { store_name = store_name, from_version = from_version, to_version = to_version, id = id, revision = revision, migrate = migrate, validate = validate, metadata = copy(metadata or {}) }
		self.steps[store_name][from_version] = step; self.ids[id] = step
		return true, nil
	end
	function registry:Plan(store, from_version, target)
		if not finite(from_version) or not finite(target) or from_version < 0 or target < from_version or math.floor(from_version) ~= from_version or math.floor(target) ~= target then return nil, "invalid or backward version request" end
		local result = {}
		for version = from_version, target - 1 do
			local step = (self.steps[store] or {})[version]
			if not step or step.to_version ~= version + 1 then return nil, "missing migration from version " .. tostring(version) end
			table.insert(result, step)
		end
		return result, nil
	end
	function registry:Preview(record, store_name, target_version, options)
		options = options or {}
		local data, message = record_data(record)
		if type(data) ~= "table" then return { code = "unknown", message = message or "table profile required" } end
		local field = options.schema_field or (RESERVED .. "application_schema_version")
		local version = data[field] or 0
		local steps, plan_error = self:Plan(store_name, version, target_version)
		if not steps then return { code = "unsupported_schema", message = plan_error } end
		local before, proposed = copy(data), copy(data)
		for _, step in ipairs(steps) do
			local next_data, err = pure(step.migrate, copy(proposed), { store_name = store_name, from_version = step.from_version, to_version = step.to_version, migration_id = step.id, revision = step.revision, dry_run = true })
			if type(next_data) ~= "table" then return { code = "invalid", message = err or "migration must return table" } end
			if step.validate then local valid, validation_error = pure(step.validate, next_data); if valid ~= true then return { code = "validation", message = validation_error or "migration validator rejected data" } end end
			next_data[field] = step.to_version
			proposed = next_data
		end
		local a_ok, a_text = pcall(canonical, before); local b_ok, b_text = pcall(canonical, proposed)
		return { code = "success", from_version = version, target_version = target_version, steps = #steps, diff = path_diff(before, proposed, options.diff), estimated_before_bytes = if a_ok then #a_text else nil, estimated_after_bytes = if b_ok then #b_text else nil, preview_only = true }
	end
	function registry:MigrateAsync(record, store_name, target_version, options)
		options = options or {}
		local field = options.schema_field or (RESERVED .. "application_schema_version")
		local data, read_error = record_data(record)
		if type(data) ~= "table" then return { code = "fenced", message = read_error } end
		local version = data[field] or 0
		if not finite(version) or version < 0 or math.floor(version) ~= version then return { code = "corrupt", message = "application schema marker invalid" } end
		if version > target_version then return { code = "unsupported_schema", current_version = version } end
		local steps, plan_error = self:Plan(store_name, version, target_version)
		if not steps then return { code = "unsupported_schema", message = plan_error } end
		local completed = 0
		for _, step in ipairs(steps) do
			local operation_id = "rv2:migrate:" .. digest(store_name .. ":" .. step.id .. ":" .. step.revision)
			local request = { store_name = store_name, migration_id = step.id, revision = step.revision, from_version = step.from_version, to_version = step.to_version }
			local result = transaction_run(record, operation_id, request, function(current)
				if type(current) ~= "table" then error("migration requires table profile") end
				local current_version = current[field] or 0
				if current_version == step.to_version then return current end
				if current_version ~= step.from_version then error("migration source version changed; preview again") end
				local next_data, err = pure(step.migrate, copy(current), request)
				if type(next_data) ~= "table" then error("migration rejected: " .. tostring(err)) end
				if step.validate then local valid, validation_error = pure(step.validate, next_data); if valid ~= true then error("migration validation rejected: " .. tostring(validation_error)) end end
				next_data[field] = step.to_version
				return next_data
			end)
			self.local_status[operation_id] = { code = result.code, message = result.message, migration_id = step.id, revision = step.revision }
			if result.code ~= "committed" and result.code ~= "duplicate" then result.completed_steps = completed; result.current_version = step.from_version; return result end
			completed += 1
		end
		local after = record_data(record)
		return { code = "committed", completed_steps = completed, current_version = if type(after) == "table" then after[field] or 0 else target_version, target_version = target_version }
	end
	function registry:GetStatus(operation_id)
		return copy(self.local_status[operation_id] or { code = "not_found", message = "status cache is local; inspect durable profile revision/schema and transaction receipt" })
	end
	return registry
end

local function new_doctor(record_store)
	local doctor = {}
	function doctor.Inspect(record, options)
		options = options or {}
		local data, message = record_data(record)
		if data == nil then return { code = "unknown", classification = "inconclusive", message = message } end
		local stats = record_stats(record)
		local nodes, tables, string_bytes, max_depth = 0, 0, 0, 0
		local function visit(value, depth)
			nodes += 1; max_depth = math.max(max_depth, depth)
			if type(value) == "table" and depth < 64 then tables += 1; for _, child in pairs(value) do visit(child, depth + 1) end
			elseif type(value) == "string" then string_bytes += #value end
		end
		visit(data, 0)
		local ok, encoded = pcall(canonical, data)
		local bytes = if ok then #encoded else nil
		local limit = options.max_bytes or 3_800_000
		return {
			code = "success",
			classification = if stats.state == "future" then "future_schema" elseif stats.state == "corrupt" then "corrupt" elseif stats.state == "fenced" then "owner_or_session_mismatch" elseif stats.state == "unknown" then "write_outcome_unknown" else "readable",
			state = stats.state, revision = stats.revision, durable_revision = stats.last_saved_revision,
			application_schema_version = if type(data) == "table" then data[options.schema_field or (RESERVED .. "application_schema_version")] or 0 else nil,
			root_type = type(data), node_count = nodes, table_count = tables, string_bytes = string_bytes, maximum_depth = max_depth,
			estimated_canonical_bytes = bytes, size_near_limit = bytes ~= nil and bytes >= limit * 0.9 or false, raw_values_included = false,
			observed_at_unix = os.time(),
		}
	end
	function doctor.Diff(left, right, options) return path_diff(left, right, options) end
	function doctor.DiffVersionsAsync(store_name, scope, key, version_id, options)
		if type(record_store) ~= "table" or type(record_store.get_version_async) ~= "function" then return { code = "unsupported" } end
		local version_data, version, code, message = record_store.get_version_async(store_name, scope, key, version_id)
		if code ~= "success" then return { code = normalize_result(code, message).code, message = message } end
		return { code = "success", version = version, diff = path_diff(version_data, options and options.current_data or {}, options) }
	end
	function doctor.PreviewRepair(record, rule, options)
		options = options or {}
		if type(rule) ~= "table" or not valid_text(rule.id, 96) or not valid_text(rule.revision, 96) or type(rule.preview) ~= "function" or type(rule.validate) ~= "function" then
			return { code = "invalid", message = "repair needs stable ID/revision, preview and validation functions" }
		end
		local data, message = record_data(record)
		if type(data) ~= "table" then return { code = "fenced", message = message } end
		local stats = record_stats(record)
		if options.expected_revision ~= nil and stats.revision ~= options.expected_revision then return { code = "conflict", message = "record revision changed after preview" } end
		local proposed, err = pure(rule.preview, copy(data))
		if type(proposed) ~= "table" then return { code = "invalid", message = err or "repair preview must return table" } end
		local valid, validation_error = pure(rule.validate, proposed)
		if valid ~= true then return { code = "validation", message = validation_error or "repair validation failed" } end
		local result = { code = "success", rule_id = rule.id, rule_revision = rule.revision, expected_revision = stats.revision, diff = path_diff(data, proposed, options.diff), candidate_digest = digest(canonical(proposed)), preview_only = true }
		if options.include_candidate == true then result.candidate = copy(proposed) end
		return result
	end
	function doctor.Restore(record, historical_data, expected_revision, restore_id, operator_id, reason, options)
		options = options or {}
		if type(historical_data) ~= "table" or not valid_text(restore_id, 96) or not valid_text(operator_id, 96) or not valid_text(reason, 512) then return { code = "invalid", message = "restore needs historical data, restore ID, operator ID and reason" } end
		local stats = record_stats(record)
		if stats.state ~= "active" then return { code = "fenced", message = "restore requires active ownership" } end
		if stats.revision ~= expected_revision then return { code = "conflict", message = "revision changed after preview" } end
		if type(options.is_erased) == "function" and options.subject_user_id ~= nil then
			local erased, status = io_call(options.is_erased, options.subject_user_id)
			if erased == true then return { code = "erased", message = "restore is blocked by erasure tombstone" } end
			if erased == nil then return { code = "unknown", message = "erasure status unresolved", detail = status } end
		end
		local historical_ok, historical_text = pcall(canonical, historical_data)
		if not historical_ok then return { code = "invalid", message = tostring(historical_text) } end
		local request = { kind = "guarded_restore", restore_id = restore_id, operator_id = operator_id, reason = reason, expected_revision = expected_revision, historical_digest = digest(historical_text) }
		local result = transaction_run(record, "rv2:restore:" .. digest(restore_id), request, function(current)
			if type(current) ~= "table" then error("restore requires table profile") end
			-- The external erasure lookup above is advisory and can race a write.
			-- The durable profile-key tombstone is checked again inside the same
			-- profile transaction that would otherwise restore historical data.
			local erasure_tombstone_key = RESERVED .. "erasure_tombstone"
			local tombstone = current[erasure_tombstone_key]
			if tombstone ~= nil and tombstone ~= false then
				error("restore is blocked by the durable profile erasure tombstone")
			end
			local merged = {}
			for key, value in pairs(current) do if type(key) ~= "string" or not string.find(key, "^" .. RESERVED, 1) then merged[key] = copy(value) end end
			for key, value in pairs(historical_data) do if type(key) ~= "string" or not string.find(key, "^" .. RESERVED, 1) then merged[key] = copy(value) end end
			local audit = merged[RESERVED .. "repair_audit"] or {}
			if type(audit) ~= "table" then audit = {} end
			table.insert(audit, { restore_id = restore_id, operator_id = operator_id, reason = reason, before_revision = expected_revision, at_unix = os.time(), result = "requested" })
			while #audit > 32 do table.remove(audit, 1) end
			merged[RESERVED .. "repair_audit"] = audit
			return merged
		end)
		result.restore_id = restore_id
		return result
	end
	return doctor
end

local function saga_coordinator(store, options)
	options = options or {}
	local api = { store = store }
	local function update_saga(id, request, mutate)
		local material = canonical(request)
		local key, now = "rv2s-" .. digest(id), os.time()
		local decision
		local value, message = adapter_call(store, "UpdateAsync", key, function(old)
			decision = nil
			if old ~= nil and (type(old) ~= "table" or old.transfer_id ~= id or old.request_material ~= material) then decision = "conflict"; return old end
			local state = if type(old) == "table" then copy(old) else { version = 1, transfer_id = id, request_material = material, phase = "requested", status = "pending", created_at = now, attempts = 0 }
			local changed, err = pure(mutate, state)
			if type(changed) ~= "table" then decision = "invalid"; return state end
			changed.updated_at = now; changed.attempts = (changed.attempts or 0) + 1
			decision = "committed"
			return changed
		end)
		if message then
			local seen = adapter_call(store, "GetAsync", key)
			if type(seen) == "table" and seen.transfer_id == id and seen.request_material == material then return seen, "unknown_reconciled" end
			return nil, "unknown", message
		end
		if decision ~= "committed" then return nil, decision or "unknown" end
		return value, "committed"
	end
	function api:GetStatus(id)
		if not valid_text(id, 128) then return { code = "invalid" } end
		local value, message = adapter_call(store, "GetAsync", "rv2s-" .. digest(id))
		if message then return { code = "unknown", message = message } end
		if not value then return { code = "not_found" } end
		if value.transfer_id ~= id then return { code = "conflict", message = "saga route collision" } end
		value.code = value.status or "unknown"
		return copy(value)
	end
	function api:TransferAsync(id, sender, recipient, amount, transfer_options)
		transfer_options = transfer_options or {}
		if not valid_text(id, 128) or not finite(amount) or amount <= 0 or (transfer_options.allow_fractional ~= true and math.floor(amount) ~= amount) then return { code = "invalid", message = "stable transfer ID and positive amount required" } end
		local sender_id, recipient_id = transfer_options.sender_id or "sender", transfer_options.recipient_id or "recipient"
		if sender_id == recipient_id then return { code = "invalid", message = "self-transfer unsupported" } end
		local balance_field, escrow_field = transfer_options.balance_field or "Balance", RESERVED .. "escrow"
		local request = { transfer_id = id, sender_id = sender_id, recipient_id = recipient_id, amount = amount, balance_field = balance_field }
		local saga, saga_code, saga_error = update_saga(id, request, function(current)
			if current.phase ~= "settled" and current.phase ~= "rejected" then current.sender_id = sender_id; current.recipient_id = recipient_id; current.amount = amount end
			return current
		end)
		if not saga then return { code = saga_code, transfer_id = id, message = saga_error } end
		if saga.phase == "settled" or saga.phase == "rejected" then return copy(saga) end
		local function mark(phase, status, message)
			return update_saga(id, request, function(current)
				if current.phase ~= "settled" and current.phase ~= "rejected" then current.phase = phase; current.status = status or "pending"; current.last_error = message and text_error(message, 256) or nil end
				return current
			end)
		end
		if saga.phase == "requested" then
			local data, read_error = record_data(sender)
			if type(data) ~= "table" then return { code = "fenced", transfer_id = id, message = read_error } end
			if not finite(data[balance_field]) or data[balance_field] < amount then
				local rejected, code = mark("rejected", "rejected", "insufficient available balance")
				return { code = if rejected then "rejected" else code, phase = "rejected", transfer_id = id }
			end
			local reserve = transaction_run(sender, "rv2:transfer:" .. digest(id) .. ":reserve", { transfer_id = id, amount = amount, leg = "reserve", sender_id = sender_id }, function(current)
				local next_data = copy(current)
				local escrow = next_data[escrow_field] or {}
				if type(escrow) ~= "table" then error("escrow namespace malformed") end
				if escrow[id] then if escrow[id].amount ~= amount then error("escrow amount conflict") end; return next_data end
				if not finite(next_data[balance_field]) or next_data[balance_field] < amount then error("insufficient balance") end
				next_data[balance_field] -= amount; escrow[id] = { amount = amount, state = "reserved" }; next_data[escrow_field] = escrow
				return next_data
			end)
			if reserve.code ~= "committed" and reserve.code ~= "duplicate" then
				local phase = if reserve.code == "unknown" then "reconciliation_required" else "rejected"
				local marked, marked_code = mark("requested", phase, reserve.message)
				return { code = if marked then phase else marked_code, transfer_id = id, message = reserve.message }
			end
			saga = mark("reserved", "pending")
			if type(saga) ~= "table" or saga.phase ~= "reserved" then return { code = "unknown", transfer_id = id, message = "reservation committed but saga state is unresolved" } end
		end
		if saga.phase == "reserved" or saga.phase == "credit_pending" then
			if saga.phase == "reserved" then
				saga = mark("credit_pending", "pending")
				if type(saga) ~= "table" or saga.phase ~= "credit_pending" then return { code = "unknown", transfer_id = id } end
			end
			local credit = transaction_run(recipient, "rv2:transfer:" .. digest(id) .. ":credit", { transfer_id = id, amount = amount, leg = "credit", recipient_id = recipient_id }, function(current)
				local next_data = copy(current)
				local ledger = next_data[RESERVED .. "received_transfers"] or {}
				if type(ledger) ~= "table" then error("received-transfer ledger malformed") end
				if ledger[id] ~= nil then if ledger[id] ~= amount then error("transfer receipt amount conflict") end; return next_data end
				if not finite(next_data[balance_field]) then error("recipient balance missing or invalid") end
				next_data[balance_field] += amount; ledger[id] = amount; next_data[RESERVED .. "received_transfers"] = ledger
				return next_data
			end)
			if credit.code == "unknown" then
				local marked, code = mark("credit_pending", "reconciliation_required", credit.message)
				return { code = if marked then "reconciliation_required" else code, transfer_id = id, message = credit.message }
			end
			if credit.code ~= "committed" and credit.code ~= "duplicate" then
				local refund = transaction_run(sender, "rv2:transfer:" .. digest(id) .. ":refund", { transfer_id = id, amount = amount, leg = "refund" }, function(current)
					local next_data = copy(current); local escrow = next_data[escrow_field] or {}
					if not escrow[id] then return next_data end
					if escrow[id].amount ~= amount then error("escrow amount mismatch") end
					escrow[id] = nil; next_data[escrow_field] = escrow; next_data[balance_field] = (next_data[balance_field] or 0) + amount
					return next_data
				end)
				if refund.code == "committed" or refund.code == "duplicate" then
					local rejected, code = mark("rejected", "rejected", credit.message)
					return { code = if rejected then "rejected" else code, transfer_id = id, message = credit.message }
				end
				local marked, code = mark("credit_pending", "reconciliation_required", "recipient credit and source refund are unresolved")
				return { code = if marked then "reconciliation_required" else code, transfer_id = id }
			end
			saga = mark("credited", "pending")
			if type(saga) ~= "table" or saga.phase ~= "credited" then return { code = "unknown", transfer_id = id, message = "recipient credit committed; saga update unresolved" } end
		end
		if saga.phase == "credited" then
			local settle = transaction_run(sender, "rv2:transfer:" .. digest(id) .. ":settle", { transfer_id = id, amount = amount, leg = "settle" }, function(current)
				local next_data = copy(current); local escrow = next_data[escrow_field] or {}
				if not escrow[id] then return next_data end
				if escrow[id].amount ~= amount then error("escrow amount mismatch") end
				escrow[id] = nil; next_data[escrow_field] = escrow
				return next_data
			end)
			if settle.code ~= "committed" and settle.code ~= "duplicate" then
				local marked, code = mark("credited", "reconciliation_required", "recipient credited but source escrow settlement unresolved")
				return { code = if marked then "reconciliation_required" else code, transfer_id = id }
			end
			local finished, finish_code = mark("settled", "settled")
			return { code = if finished then "settled" else finish_code or "unknown", phase = "settled", transfer_id = id }
		end
		return self:GetStatus(id)
	end
	return api
end

local function new_receipt_processor(config)
	config = config or {}
	local products = config.products or {}
	if type(config.get_record) ~= "function" then error("ReceiptProcessor requires server-side get_record(user_id)", 2) end
	local granted = config.purchase_granted or (Enum and Enum.ProductPurchaseDecision and Enum.ProductPurchaseDecision.PurchaseGranted) or "PurchaseGranted"
	local retry = config.not_processed_yet or (Enum and Enum.ProductPurchaseDecision and Enum.ProductPurchaseDecision.NotProcessedYet) or "NotProcessedYet"
	local api = {}
	function api:GetStatusAsync(id, record)
		if not valid_text(id, 256) then return { code = "invalid" } end
		local data, message = record_data(record)
		if type(data) ~= "table" then return { code = "unknown", message = message } end
		local receipts = data[RESERVED .. "purchase_receipts"]
		local row = type(receipts) == "table" and receipts[id] or nil
		return if row then { code = "granted", receipt_id = id, product_id = row.product_id, granted_at = row.granted_at } else { code = "not_found", receipt_id = id }
	end
	function api:CreateHandler(default_grant)
		return function(receipt)
			if type(receipt) ~= "table" then return retry end
			local id, user_id, product_id = receipt.PurchaseId, receipt.PlayerId, receipt.ProductId
			if not valid_text(id, 256) or not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id or not finite(product_id) or product_id < 1 or math.floor(product_id) ~= product_id then return retry end
			local product = products[product_id] or products[tostring(product_id)]
			local grant = type(product) == "table" and (product.grant or default_grant) or nil
			if type(grant) ~= "function" then return retry end
			local record, resolve_error = io_call(config.get_record, user_id)
			if not record or record_stats(record).state ~= "active" then
				if type(config.on_unresolved) == "function" then pcall(config.on_unresolved, id, resolve_error or "active profile unavailable") end
				return retry
			end
			local revision = product.revision or "1"
			local request = { receipt_id = id, user_id = user_id, product_id = product_id, product_revision = revision }
			local result = transaction_run(record, "rv2:purchase:" .. digest(id), request, function(current)
				if type(current) ~= "table" then error("purchase profile data must be a table") end
				local data = copy(current); local field = RESERVED .. "purchase_receipts"
				local receipts = data[field] or {}
				if type(receipts) ~= "table" then error("purchase receipt ledger malformed") end
				if receipts[id] then
					local prior = receipts[id]
					if prior.user_id ~= user_id or prior.product_id ~= product_id or prior.revision ~= revision then error("purchase receipt conflict") end
					return data
				end
				local granted_data, grant_error = pure(grant, data, copy(receipt), copy(product))
				if type(granted_data) ~= "table" then error("purchase grant rejected: " .. tostring(grant_error)) end
				receipts = granted_data[field] or receipts
				if type(receipts) ~= "table" then error("grant reducer corrupted purchase receipt namespace") end
				receipts[id] = { user_id = user_id, product_id = product_id, revision = revision, granted_at = os.time() }
				granted_data[field] = receipts
				return granted_data
			end)
			if result.code == "committed" or result.code == "duplicate" then return granted end
			if type(config.on_unresolved) == "function" then pcall(config.on_unresolved, id, result) end
			return retry
		end
	end
	function api:BindLegacyProcessReceipt(service, default_grant)
		local ok, message = pcall(function() service.ProcessReceipt = self:CreateHandler(default_grant) end)
		return ok, if ok then nil else tostring(message)
	end
	return api
end

local function render_template(template, user_id)
	local result = copy(template)
	for _, field in ipairs({ "name", "scope", "key" }) do
		if type(result[field]) == "string" then result[field] = string.gsub(result[field], "{user_id}", tostring(user_id)) end
	end
	return result
end

local function new_erasure(store, families, options)
	options = options or {}
	families = families or {}
	local all_templates, by_name, template_signatures = {}, {}, {}
	for _, family in ipairs(families) do
		if not valid_text(family.name, 48) or by_name[family.name] then error("erasure families need unique names", 2) end
		by_name[family.name] = family
		local templates = family.templates or {}
		if #templates == 0 then error("each erasure family must declare at least one RTBF template", 2) end
		for _, template in ipairs(templates) do
			if type(template) ~= "table" then error("RTBF template must be table", 2) end
			if not valid_text(template.name, 50) or not valid_text(template.key, 50)
				or (template.scope ~= nil and not valid_text(template.scope, 50))
			then
				error("RTBF templates require bounded DataStore name/key and optional bounded scope", 2)
			end
			local matchable = false
			for _, field in ipairs({ "name", "scope", "key" }) do
				if type(template[field]) == "string" and string.find(template[field], "{user_id}", 1, true) then matchable = true end
			end
			if not matchable then error("RTBF template must place {user_id} in name, scope, or key", 2) end
			local signature = template.name .. "\0" .. tostring(template.scope or "") .. "\0" .. template.key
			if template_signatures[signature] then error("duplicate RTBF key-family template", 2) end
			template_signatures[signature] = true
			table.insert(all_templates, { family = family.name, template = copy(template) })
			if #all_templates > MAX_ERASURE_TEMPLATES then error("RTBF templates exceed 100-template limit", 2) end
		end
	end
	local coordinator = { store = store, families = families }
	local function manifest_key(user_id) return "rv2erase-u" .. tostring(user_id) end
	function coordinator:RenderTemplates(user_id)
		if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then return nil, "invalid UserId" end
		local result = {}
		for _, entry in ipairs(all_templates) do
			local rendered = render_template(entry.template, user_id)
			if not valid_text(rendered.name, 50) or not valid_text(rendered.key, 50)
				or (rendered.scope ~= nil and not valid_text(rendered.scope, 50))
			then
				return nil, "rendered RTBF template violates a DataStore name, scope or key bound"
			end
			table.insert(result, { family = entry.family, template = rendered })
		end
		return result, nil
	end
	function coordinator:PlanAsync(user_id, erasure_id)
		if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id or not valid_text(erasure_id, 96) then return { code = "invalid" } end
		local entries, coverage = {}, {}
		for _, family in ipairs(self.families) do
			if type(family.inventory) ~= "function" then
				coverage[family.name] = { status = "unresolved", count = 0 }
			else
				local items, message = io_call(family.inventory, user_id, MAX_ERASURE_ITEMS)
				if type(items) ~= "table" then coverage[family.name] = { status = "unresolved", count = 0, message = message }
				else
					local item_count = 0
					for index in pairs(items) do
						if type(index) ~= "number" or not finite(index) or math.floor(index) ~= index or index < 1 then
							return { code = "invalid", message = "inventory must be a dense array" }
						end
						item_count += 1
						if item_count > MAX_ERASURE_ITEMS then return { code = "capacity", message = "family inventory exceeds bounded item count" } end
					end
					for index = 1, item_count do
						if items[index] == nil then return { code = "invalid", message = "inventory must be a dense array" } end
					end
					for index = 1, item_count do
						local item = items[index]
						if type(item) ~= "table" or not valid_text(item.key, 50) or not finite(item.generation) then return { code = "invalid", message = "inventory items require key and observed generation" } end
						table.insert(entries, { family = family.name, item = copy(item) })
						if #entries > MAX_ERASURE_ITEMS then return { code = "capacity", message = "erasure plan exceeds bounded item count" } end
					end
					coverage[family.name] = {
						status = if family.templates_verified == true and family.inventory_verified == true
							then "coverage_verified_by_integrator" else "coverage_unverified",
						count = item_count,
						templates_verified = family.templates_verified == true,
						inventory_verified = family.inventory_verified == true,
					}
				end
			end
		end
		local rendered, render_error = self:RenderTemplates(user_id)
		if rendered == nil then return { code = "invalid", message = render_error or "RTBF templates could not be rendered safely" } end
		local template_ok = if type(options.verify_templates) == "function" then io_call(options.verify_templates, user_id, rendered) else false
		local verified = #self.families > 0
		for _, row in pairs(coverage) do if row.status ~= "coverage_verified_by_integrator" then verified = false end end
		local manifest = {
			version = 1, user_id = user_id, erasure_id = erasure_id, status = "planned", cursor = 0,
			completed_count = 0, entries = entries, coverage = coverage,
			rtbf_coverage_verified = verified and template_ok == true, created_at = os.time(), updated_at = os.time(),
		}
		local value, message = adapter_call(store, "UpdateAsync", manifest_key(user_id), function(old)
			-- The erasure ID owns one immutable plan. A retry must not reset progress
			-- or replace the authoritative inventory with a later, different snapshot.
			if old ~= nil then return old end
			return manifest
		end)
		if message then
			local old = adapter_call(store, "GetAsync", manifest_key(user_id))
			if type(old) == "table" and old.user_id == user_id and old.erasure_id == erasure_id then old.code = "unknown_reconciled"; return copy(old) end
			return { code = "unknown", message = message }
		end
		if type(value) ~= "table" or value.user_id ~= user_id or value.erasure_id ~= erasure_id then return { code = "conflict", message = "different erasure already owns this manifest key" } end
		value.code = "success"
		return copy(value)
	end
	function coordinator:ExecuteAsync(user_id, erasure_id, max_items)
		if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id or not valid_text(erasure_id, 96) then return { code = "invalid" } end
		max_items = math.clamp(math.floor(max_items or 16), 1, 64)
		local key = manifest_key(user_id)
		local manifest, message = adapter_call(store, "GetAsync", key)
		if message then return { code = "unknown", message = message } end
		if type(manifest) ~= "table" or manifest.user_id ~= user_id or manifest.erasure_id ~= erasure_id then return { code = "not_found" } end
		if manifest.rtbf_coverage_verified ~= true then
			return { code = "blocked", cursor = manifest.cursor or 0, completed_count = manifest.completed_count or 0,
				message = "RTBF coverage is not verified for every declared family, template and authoritative inventory; no erasure actions were run" }
		end
		if manifest.status == "completed" then return { code = "committed", completed_count = manifest.completed_count or 0, rtbf_coverage_verified = true } end
		if type(manifest.entries) ~= "table" or not finite(manifest.cursor) or math.floor(manifest.cursor) ~= manifest.cursor
			or manifest.cursor < 0 or manifest.cursor > #manifest.entries
		then
			return { code = "corrupt", message = "erasure manifest has an invalid bounded cursor or entries list" }
		end
		for _, family in ipairs(self.families) do
			if type(family.fence_user) ~= "function" or type(family.dependencies_clear) ~= "function"
				or type(family.redact_or_delete_if_generation) ~= "function"
			then
				return { code = "unsupported", message = "family needs writer fencing, dependency proof and generation-aware delete/redact" }
			end
			local fenced, fence_error = io_call(family.fence_user, user_id, erasure_id)
			if fenced ~= true then return { code = "retryable", message = fence_error or "writer fence unconfirmed" } end
		end
		local cursor, completed = manifest.cursor or 0, manifest.completed_count or 0
		for index = cursor + 1, math.min(#manifest.entries, cursor + max_items) do
			local entry, family = manifest.entries[index], by_name[manifest.entries[index].family]
			if not family then return { code = "corrupt", message = "unknown family in erasure plan" } end
			local clear, dependency_error = io_call(family.dependencies_clear, entry.item, user_id)
			if clear ~= true then return { code = "blocked", cursor = index - 1, message = dependency_error or "live dependency blocks deletion" }
			local status, action_error = io_call(family.redact_or_delete_if_generation, entry.item, user_id, erasure_id)
			if status ~= "deleted" and status ~= "redacted" then
				local observed, state_error = adapter_call(store, "UpdateAsync", key, function(old)
					if type(old) ~= "table" or old.erasure_id ~= erasure_id then return old end
					-- Do not regress a checkpoint another worker has already committed.
					if old.status == "completed" or (finite(old.cursor) and old.cursor >= index) then return old end
					local value = copy(old)
					value.status = if status == "unknown" then "unknown" else "in_progress"
					value.last_error = text_error(action_error or status, 256)
					return value
				end)
				if state_error == nil and type(observed) == "table" and observed.erasure_id == erasure_id
					and (observed.status == "completed" or (finite(observed.cursor) and observed.cursor >= index))
				then
					return { code = if observed.status == "completed" then "committed" else "incomplete",
						cursor = observed.cursor, completed_count = observed.completed_count,
						rtbf_coverage_verified = observed.rtbf_coverage_verified == true,
						message = "another worker already checkpointed this generation-safe action" }
				end
				return { code = if status == "unknown" or state_error ~= nil then "unknown" else "retryable",
					cursor = index - 1, message = action_error or state_error or "delete outcome unresolved" }
			end
			completed += 1
			local updated, progress_error = adapter_call(store, "UpdateAsync", key, function(old)
				if type(old) ~= "table" or old.erasure_id ~= erasure_id then return old end
				local old_cursor = old.cursor or 0
				-- Concurrent workers may run a generation-safe action more than once, but
				-- checkpoint progress is monotonic and may never move backwards.
				if old_cursor >= index then return old end
				if old_cursor ~= index - 1 then return old end
				local value = copy(old)
				value.cursor = index
				value.completed_count = (old.completed_count or 0) + 1
				value.status = "in_progress"
				value.updated_at = os.time()
				value.last_error = nil
				return value
			end)
			if progress_error then
				return { code = "unknown", cursor = index - 1, completed_count = completed,
					message = "action succeeded; progress write outcome is unresolved and must be reconciled" }
			end
			if type(updated) ~= "table" or updated.erasure_id ~= erasure_id then
				return { code = "unknown", cursor = index - 1, completed_count = completed,
					message = "action succeeded; manifest ownership could not be verified" }
			end
			if not finite(updated.cursor) or updated.cursor < index then
				return { code = "unknown", cursor = index - 1, completed_count = completed,
					message = "action succeeded; checkpoint did not advance contiguously" }
			end
			completed = updated.completed_count or completed
			if updated.cursor > index then
				return { code = if updated.status == "completed" then "committed" else "incomplete",
					cursor = updated.cursor, completed_count = completed, rtbf_coverage_verified = updated.rtbf_coverage_verified == true,
					message = "another worker advanced the immutable erasure checkpoint" }
			end
		end
		local final, final_error = adapter_call(store, "UpdateAsync", key, function(old)
			if type(old) ~= "table" or old.erasure_id ~= erasure_id then return old end
			local value = copy(old)
			value.completed_count = math.max(old.completed_count or 0, completed)
			value.status = if value.cursor >= #value.entries then "completed" else "in_progress"
			value.completed_at = if value.status == "completed" then (old.completed_at or os.time()) else nil
			value.updated_at = os.time()
			return value
		end)
		if final_error then return { code = "unknown", message = final_error } end
		if type(final) ~= "table" or final.erasure_id ~= erasure_id then
			return { code = "conflict", message = "erasure manifest changed ownership during finalization" }
		end
		return { code = if final.status == "completed" then "committed" else "incomplete",
			cursor = final.cursor or cursor, completed_count = final.completed_count or completed,
			rtbf_coverage_verified = final.rtbf_coverage_verified == true,
			message = if final.status ~= "completed" then "resume in bounded steps" else nil }
	end
	function coordinator:GetStatus(user_id)
		local result, message = adapter_call(store, "GetAsync", manifest_key(user_id))
		if message then return { code = "unknown", message = message } end
		if not result then return { code = "not_found" } end
		return copy(result)
	end
	function coordinator:IsErased(user_id)
		local status = self:GetStatus(user_id)
		if type(status) ~= "table" then return nil, { code = "unknown", message = "erasure status is not a table" } end
		if status.code == "not_found" then return false, status end
		if status.code == "unknown" or status.code == "corrupt" or status.code == "conflict" then
			return nil, status
		end
		if status.user_id ~= user_id or not valid_text(status.erasure_id, 96) or not valid_text(status.status, 32) then
			return nil, { code = "corrupt", message = "erasure status identity or state is invalid" }
		end
		if status.status == "planned" or status.status == "in_progress" or status.status == "completed" then
			return true, status
		end
		-- Unknown states, including cancellation without a defined protocol, remain blocked.
		-- Unknown states, blocked operations, or future schema revisions must not
		-- be interpreted as permission to recreate user-associated data.
		return nil, { code = "unsupported", message = "erasure state is unresolved or unsupported", state = status.status }
	end
	return coordinator
end

local function new_rollout(store, options)
	options = options or {}
	local api = {}
	local verifiers = {
		compatibility = options.verify_compatibility,
		writers_drained = options.verify_writers_drained,
		activation_frozen = options.verify_activation_frozen,
		rollback_rehearsed = options.verify_rollback_rehearsed,
		profile_key_fencing = options.verify_profile_key_fencing,
	}
	local required_verifiers = { "compatibility", "writers_drained", "activation_frozen", "rollback_rehearsed", "profile_key_fencing" }
	local function key_for(id) return "rv2rollout-" .. digest(id) end
	local function read(id)
		if not valid_text(id, 96) then return nil, { code = "invalid", message = "rollout ID must be 1..96 bytes" } end
		local value, message = adapter_call(store, "GetAsync", key_for(id))
		if message then return nil, { code = "unknown", message = message } end
		if value == nil then return nil, { code = "not_found" } end
		local valid_phases = { prepared = true, ready = true, active = true, frozen = true, rollback_pending = true, rolled_back = true }
		if type(value) ~= "table" then return nil, { code = "corrupt", message = "rollout manifest is not a table" } end
		if value.version ~= 1 then return nil, { code = "unsupported_schema", message = "unsupported rollout manifest version" } end
		if value.rollout_id ~= id or not valid_text(value.matrix_digest, 128)
			or not valid_text(value.phase, 32) or not valid_phases[value.phase]
			or not finite(value.revision) or value.revision < 1 or math.floor(value.revision) ~= value.revision
		then
			return nil, { code = "corrupt", message = "rollout manifest identity, revision or phase is invalid" }
		end
		return value, nil
	end
	local function attest(id, manifest)
		local evidence = {}
		for _, name in ipairs(required_verifiers) do
			local verifier = verifiers[name]
			if type(verifier) ~= "function" then
				return nil, { code = "unsupported", message = "rollout requires verifier: " .. name }
			end
			local verified, evidence_id = io_call(verifier, id, copy(manifest))
			if verified ~= true or not valid_text(evidence_id, 256) then
				return nil, { code = "blocked", message = "rollout verifier failed or supplied no durable evidence reference: " .. name }
			end
			evidence[name] = { evidence_id = evidence_id, verified_at = os.time() }
		end
		return evidence, nil
	end
	local function phase_update(id, expected_phase, next_phase, operation_field, operation_id, patch)
		if not valid_text(id, 96) then return { code = "invalid", message = "rollout ID must be 1..96 bytes" } end
		local manifest, read_error = read(id)
		if not manifest then return read_error end
		if manifest.phase == next_phase and operation_id ~= nil and manifest[operation_field] == operation_id then
			local result = copy(manifest); result.code = "duplicate"; return result
		end
		if manifest.phase ~= expected_phase then
			return { code = "conflict", phase = manifest.phase, message = "expected rollout phase " .. expected_phase }
		end
		local now = os.time()
		local updated, update_error = adapter_call(store, "UpdateAsync", key_for(id), function(old)
			if type(old) ~= "table" or old.rollout_id ~= id or old.matrix_digest ~= manifest.matrix_digest then return old end
			if old.phase ~= expected_phase or old.revision ~= manifest.revision then return old end
			local next_value = copy(old)
			next_value.phase = next_phase
			next_value.revision = (old.revision or 0) + 1
			next_value.updated_at = now
			if operation_field ~= nil then next_value[operation_field] = operation_id end
			for name, value in pairs(patch or {}) do next_value[name] = copy(value) end
			return next_value
		end)
		if update_error ~= nil then
			local reconciled, reconcile_error = read(id)
			if reconciled and reconciled.phase == next_phase
				and (operation_id == nil or reconciled[operation_field] == operation_id)
			then
				reconciled.code = "committed_reconciled"
				return reconciled
			end
			return { code = "unknown", message = update_error .. (reconcile_error and ("; reconcile: " .. tostring(reconcile_error.message)) or "") }
		end
		if type(updated) ~= "table" or updated.rollout_id ~= id then return { code = "conflict", message = "rollout manifest changed identity" } end
		if updated.phase ~= next_phase or (operation_id ~= nil and updated[operation_field] ~= operation_id) then
			return { code = "conflict", phase = updated.phase, message = "rollout phase changed concurrently" }
		end
		local result = copy(updated)
		result.code = "committed"
		return result
	end
	function api:PrepareAsync(id, matrix_digest)
		if not valid_text(id, 96) or not valid_text(matrix_digest, 128) then return { code = "invalid" } end
		local now = os.time()
		local initial = {
			version = 1, rollout_id = id, matrix_digest = matrix_digest, phase = "prepared",
			revision = 1, attestations = {}, created_at = now, updated_at = now,
		}
		local value, message = adapter_call(store, "UpdateAsync", key_for(id), function(old)
			if old ~= nil then return old end
			return initial
		end)
		if message then
			local observed, observe_error = read(id)
			if observed and observed.matrix_digest == matrix_digest then observed.code = "unknown_reconciled"; return observed end
			return { code = "unknown", message = message or (observe_error and observe_error.message) }
		end
		if type(value) ~= "table" or value.rollout_id ~= id or value.matrix_digest ~= matrix_digest then
			return { code = "conflict", message = "rollout ID is already bound to another matrix digest" }
		end
		local result = copy(value)
		result.code = if value.phase == "prepared" then "prepared" else "duplicate"
		return result
	end
	function api:AttestAsync(id)
		local manifest, read_error = read(id)
		if not manifest then return read_error end
		if manifest.phase ~= "prepared" then return { code = "conflict", phase = manifest.phase } end
		local evidence, evidence_error = attest(id, manifest)
		if not evidence then return evidence_error end
		return phase_update(id, "prepared", "ready", "attestation_operation_id", digest(id .. ":attest:" .. tostring(manifest.revision)), {
			attestations = evidence,
		})
	end
	function api:ActivateAsync(id, activation_id)
		if not valid_text(activation_id, 96) then return { code = "invalid", message = "activation_id must be stable and 1..96 bytes" } end
		local manifest, read_error = read(id)
		if not manifest then return read_error end
		if manifest.phase == "active" and manifest.activation_id == activation_id then
			local result = copy(manifest); result.code = "duplicate"; return result
		end
		if manifest.phase ~= "ready" then return { code = "conflict", phase = manifest.phase, message = "rollout must be ready before activation" } end
		local evidence, evidence_error = attest(id, manifest)
		if not evidence then return evidence_error end
		return phase_update(id, "ready", "active", "activation_id", activation_id, { attestations = evidence, activated_at = os.time() })
	end
	function api:FreezeAsync(id, freeze_id)
		if not valid_text(freeze_id, 96) then return { code = "invalid" } end
		return phase_update(id, "active", "frozen", "freeze_id", freeze_id, { frozen_at = os.time() })
	end
	function api:BeginRollbackAsync(id, rollback_id)
		if not valid_text(rollback_id, 96) then return { code = "invalid" } end
		return phase_update(id, "frozen", "rollback_pending", "rollback_id", rollback_id, { rollback_started_at = os.time() })
	end
	function api:CompleteRollbackAsync(id, rollback_id)
		if not valid_text(rollback_id, 96) then return { code = "invalid" } end
		local manifest, read_error = read(id)
		if not manifest then return read_error end
		if manifest.phase == "rolled_back" and manifest.rollback_id == rollback_id then
			local result = copy(manifest); result.code = "duplicate"; return result
		end
		if manifest.phase ~= "rollback_pending" or manifest.rollback_id ~= rollback_id then
			return { code = "conflict", phase = manifest.phase, message = "rollback must be frozen and match the rollback ID" }
		end
		if type(options.verify_rollback_completed) ~= "function" then
			return { code = "unsupported", message = "rollback completion needs a verifier for old-writer restoration and V2 fencing" }
		end
		local verified, evidence_id = io_call(options.verify_rollback_completed, id, copy(manifest))
		if verified ~= true or not valid_text(evidence_id, 256) then
			return { code = "blocked", message = "rollback completion is not verified" }
		end
		return phase_update(id, "rollback_pending", "rolled_back", "rollback_id", rollback_id, {
			rollback_evidence = { evidence_id = evidence_id, verified_at = os.time() },
			rolled_back_at = os.time(),
		})
	end
	function api:GetStatusAsync(id)
		if not valid_text(id, 96) then return { code = "invalid" } end
		local manifest, read_error = read(id)
		if not manifest then return read_error end
		manifest.code = "success"
		return copy(manifest)
	end
	function api:CanUseAsync(id, operation)
		if not valid_text(id, 96) then return false, "rollout ID must be 1..96 bytes" end
		local known_operations = {
			read = true, enqueue = true, process = true, recover = true, renew_claim = true,
			acknowledge = true, reconcile = true, replay = true, discard = true, maintenance = true,
		}
		if not valid_text(operation, 32) or not known_operations[operation] then return false, "operation is invalid or unsupported" end
		if operation == "read" then return true, "read-only diagnostics allowed" end
		local manifest, read_error = read(id)
		if not manifest then return false, "rollout state is unavailable: " .. tostring(read_error and read_error.code), read_error end
		if manifest.phase == "active" then return true, manifest.phase, copy(manifest) end
		local drain_operations = {
			process = true, recover = true, renew_claim = true, acknowledge = true, reconcile = true,
		}
		if (manifest.phase == "frozen" or manifest.phase == "rollback_pending") and drain_operations[operation] then
			return true, manifest.phase, copy(manifest)
		end
		return false, "rollout phase " .. tostring(manifest.phase) .. " denies operation " .. operation, copy(manifest)
	end
	function api:ActivationGuard(id, operation)
		local allowed, message, state = self:CanUseAsync(id, operation)
		return allowed, if allowed then nil else message, state
	end
	return api
end

local function new_projections(store, options)
	options = options or {}
	local service = { store = store, projections = {} }
	local function key_for(name, entity_id) return "rv2p-" .. digest(name .. ":" .. entity_id) end
	function service:Register(name, version, projector, definition)
		if not valid_text(name, 40) or not finite(version) or version < 1 or math.floor(version) ~= version or type(projector) ~= "function" then return false, "projection requires name, positive version, and pure projector" end
		if self.projections[name] and self.projections[name].version ~= version then return false, "use a versioned projection name and explicit cutover" end
		self.projections[name] = { name = name, version = version, projector = projector, definition = copy(definition or {}) }
		return true
	end
	function service:ApplyAsync(name, event)
		local def = self.projections[name]
		if not def then return { code = "not_found" } end
		if type(event) ~= "table" or not valid_text(event.event_id, 128) or not valid_text(event.entity_id, 128)
			or not finite(event.source_revision) or event.source_revision < 0 or math.floor(event.source_revision) ~= event.source_revision then return { code = "invalid" } end
		if type(options.is_erased) == "function" then
			for _, user_id in ipairs(event.subject_user_ids or {}) do
				local erased, error_value = io_call(options.is_erased, user_id)
				if erased == true then return { code = "erased" } elseif erased == nil then return { code = "unknown", message = error_value or "erasure state unresolved" } end
			end
		end
		local key, decision = key_for(name, event.entity_id), "unknown"
		local value, write_error = adapter_call(store, "UpdateAsync", key, function(old)
			decision = "unknown"
			if old ~= nil and (old.entity_id ~= event.entity_id or old.projection_name ~= name) then decision = "conflict"; return old end
			if old ~= nil and old.version ~= def.version then decision = "unsupported_schema"; return old end
			local current = if type(old) == "table" then old else { projection_name = name, version = def.version, entity_id = event.entity_id, value = {}, source_revision = -1, recent_events = {} }
			for _, event_id in ipairs(current.recent_events or {}) do if event_id == event.event_id then decision = "duplicate"; return current end end
			if event.source_revision <= current.source_revision then decision = "stale"; return current end
			local next_value = pure(def.projector, copy(current.value), copy(event))
			if type(next_value) ~= "table" then decision = "invalid"; return current end
			local result = copy(current); result.value = next_value; result.source_revision = event.source_revision; result.updated_at = os.time()
			result.recent_events = copy(current.recent_events or {}); table.insert(result.recent_events, event.event_id)
			while #result.recent_events > 64 do table.remove(result.recent_events, 1) end
			decision = "committed"
			return result
		end)
		if write_error then
			local observed = adapter_call(store, "GetAsync", key)
			if type(observed) == "table" then for _, id in ipairs(observed.recent_events or {}) do if id == event.event_id then return { code = "committed", row = observed, reconciled = true, consistency = "eventual" } end end end
			return { code = "unknown", message = write_error }
		end
		return { code = decision, row = value, consistency = "eventual" }
	end
	function service:GetAsync(name, entity_id)
		if not self.projections[name] or not valid_text(entity_id, 128) then return { code = "not_found" } end
		local value, message = adapter_call(store, "GetAsync", key_for(name, entity_id))
		if message then return { code = "unknown", message = message } end
		if value and value.entity_id ~= entity_id then return { code = "conflict", message = "projection key collision" } end
		return { code = if value then "success" else "not_found", row = value, consistency = "eventual" }
	end
	function service:RebuildAsync(name, fetch_page, cursor, max_pages)
		if not self.projections[name] or type(fetch_page) ~= "function" then return { code = "invalid" } end
		max_pages = math.clamp(math.floor(max_pages or 4), 1, 64)
		local processed = 0
		for _ = 1, max_pages do
			local items, next_cursor, complete = io_call(fetch_page, cursor, 64)
			if type(items) ~= "table" then return { code = "unknown", processed = processed, cursor = cursor } end
			for _, event in ipairs(items) do
				local result = self:ApplyAsync(name, event)
				if result.code ~= "committed" and result.code ~= "duplicate" and result.code ~= "stale" then return { code = result.code, processed = processed, cursor = cursor } end
				processed += 1
			end
			cursor = next_cursor
			if complete == true or cursor == nil then return { code = "committed", processed = processed, cursor = cursor, complete = true } end
		end
		return { code = "incomplete", processed = processed, cursor = cursor, complete = false }
	end
	function service:ReserveUnique(namespace, unique_value, entity_id, operation_id)
		if not valid_text(namespace, 32) or not valid_text(unique_value, 128) or not valid_text(entity_id, 128) or not valid_text(operation_id, 128) then return { code = "invalid" } end
		local key = "rv2u-" .. digest(namespace .. ":" .. unique_value)
		local decision = "unknown"
		local value, message = adapter_call(store, "UpdateAsync", key, function(old)
			if old ~= nil then
				decision = if old.namespace == namespace and old.unique_value == unique_value and old.entity_id == entity_id then "duplicate" else "conflict"
				return old
			end
			decision = "committed"
			return { namespace = namespace, unique_value = unique_value, entity_id = entity_id, operation_id = operation_id, created_at = os.time() }
		end)
		if message then
			local observed = adapter_call(store, "GetAsync", key)
			if type(observed) == "table" and observed.namespace == namespace and observed.unique_value == unique_value and observed.entity_id == entity_id then return { code = "committed", reservation = observed, reconciled = true } end
			return { code = "unknown", message = message }
		end
		return { code = decision, reservation = value }
	end
	return service
end

local function new_read_coalescer(fetch, options)
	options = options or {}
	local values, inflight = {}, {}
	local service = { hits = 0, misses = 0, coalesced = 0, evictions = 0 }
	local ttl, maximum = options.ttl_seconds or 1, math.clamp(math.floor(options.max_entries or 128), 1, 2048)
	function service:GetAsync(key, fence_key)
		if not valid_text(key, 256) then return nil, "invalid key" end
		local cache_key = tostring(fence_key or "") .. "\0" .. key
		local now = os.clock()
		local cached = values[cache_key]
		if cached and cached.expires > now then self.hits += 1; return copy(cached.value), nil, "cache" end
		local active = inflight[cache_key]
		if active then
			self.coalesced += 1
			if active.event then active.event.Event:Wait(); local result = values[cache_key]; return result and copy(result.value) or nil, active.message end
			return nil, "in-flight waiter signal unavailable"
		end
		self.misses += 1
		local event
		if Instance and type(Instance.new) == "function" then
			local ok, object = pcall(Instance.new, "BindableEvent")
			if ok and object and object.Event and type(object.Fire) == "function" then event = object end
		end
		local flight = { event = event }
		inflight[cache_key] = flight
		local result, message = io_call(fetch, key)
		if result ~= nil then
			values[cache_key] = { value = copy(result), expires = now + ttl }
			local size = 0; for _ in pairs(values) do size += 1 end
			while size > maximum do
				local oldest, expires
				for candidate, row in pairs(values) do if expires == nil or row.expires < expires then oldest, expires = candidate, row.expires end end
				if not oldest then break end
				values[oldest] = nil; self.evictions += 1; size -= 1
			end
		else flight.message = message or "fetch returned nil" end
		inflight[cache_key] = nil
		if event then event:Fire(); event:Destroy() end
		if result == nil then return nil, message end
		return copy(result), nil, "fetch"
	end
	function service:Invalidate(key, fence_key) values[tostring(fence_key or "") .. "\0" .. key] = nil; return true end
	function service:Clear() table.clear(values); return true end
	function service:Stats() return { entries = key_count(values), hits = self.hits, misses = self.misses, coalesced = self.coalesced, evictions = self.evictions } end
	return service
end

local function new_maintenance()
	local service = {}
	function service.AssessPayload(value, maximum_bytes)
		maximum_bytes = maximum_bytes or 3_800_000
		local material, message = request_material(value)
		if not material then return { code = "invalid", message = message } end
		return { code = if #material > maximum_bytes then "capacity" elseif #material >= maximum_bytes * 0.9 then "near_limit" else "within_limit", estimated_bytes = #material, maximum_bytes = maximum_bytes, remaining_bytes = math.max(0, maximum_bytes - #material), estimate = "canonical payload only; not exact envelope encoding" }
	end
	function service.SelectEncoding(value, codec, options)
		options = options or {}
		local assessment = service.AssessPayload(value, options.maximum_bytes)
		if not assessment.estimated_bytes then return assessment end
		if assessment.estimated_bytes < (options.compression_threshold_bytes or 4096) or type(codec) ~= "table" then assessment.encoding = "raw"; assessment.payload = copy(value); return assessment end
		if not valid_text(codec.id, 64) or not valid_text(codec.revision, 64) or type(codec.encode) ~= "function" or type(codec.decode) ~= "function" then return { code = "invalid", message = "codec needs stable id/revision and encode/decode" } end
		local encoded, encode_error = pure(codec.encode, copy(value))
		if type(encoded) ~= "string" then return { code = "invalid", message = encode_error or "codec must return string" } end
		local decoded, decode_error = pure(codec.decode, encoded, codec.revision)
		if decoded == nil then return { code = "invalid", message = decode_error or "decode failed" } end
		local decoded_text, original_text = canonical_request(decoded), canonical_request(value)
		if decoded_text ~= original_text then return { code = "invalid", message = "codec round-trip mismatch" } end
		if #encoded >= assessment.estimated_bytes then assessment.encoding = "raw"; assessment.payload = copy(value)
		else assessment.encoding = "codec"; assessment.codec_id = codec.id; assessment.codec_revision = codec.revision; assessment.payload = encoded end
		return assessment
	end
	function service.DecodeEncoding(encoding, codec_registry)
		if type(encoding) ~= "table" then return nil, "encoded value must be table" end
		if encoding.encoding == "raw" then return copy(encoding.payload), nil end
		if encoding.encoding ~= "codec" then return nil, "unsupported encoding" end
		local codec = codec_registry and codec_registry[encoding.codec_id]
		if type(codec) ~= "table" or codec.revision ~= encoding.codec_revision or type(codec.decode) ~= "function" then return nil, "matching immutable codec revision is not registered" end
		return pure(codec.decode, encoding.payload, encoding.codec_revision)
	end
	function service.ShouldSave(stats)
		if type(stats) ~= "table" then return { code = "unknown", reason = "missing stats" } end
		if stats.state == "unknown" then return { code = "unknown", reason = "previous write is unresolved" } end
		if tonumber(stats.dirty) ~= 1 then return { code = "skip", reason = "no tracked dirty generation" } end
		return { code = "save", reason = "dirty generation differs from saved generation" }
	end
	function service.NewCompactor(config)
		config = config or {}
		local compactor = { status = "idle", cursor = config.initial_cursor, processed = 0, removed = 0, last_error = nil }
		function compactor:RunStep(max_items, budget_ms)
			max_items = math.clamp(math.floor(max_items or 32), 1, 256)
			budget_ms = math.clamp(math.floor(budget_ms or 25), 1, 1000)
			if type(config.next_page) ~= "function" or type(config.inspect) ~= "function" or type(config.delete_if_generation) ~= "function" or type(config.persist_progress) ~= "function" then return { code = "invalid", message = "compactor requires page, inspect, generation-aware delete, and checkpoint adapters" } end
			local start = os.clock() * 1000
			local items, next_cursor, complete = io_call(config.next_page, self.cursor, max_items)
			if type(items) ~= "table" then self.status = "unknown"; return { code = "unknown", cursor = self.cursor } end
			local before_cursor = self.cursor
			self.status = "running"
			for _, item in ipairs(items) do
				if os.clock() * 1000 - start >= budget_ms then self.status = "paused"; break end
				local inspected, inspect_error = io_call(config.inspect, item)
				if type(inspected) ~= "table" or inspected.status == "unknown" then self.status = "unknown"; self.last_error = inspect_error; return { code = "unknown", cursor = before_cursor, message = inspect_error or "inspection unresolved" } end
				if inspected.eligible == true and inspected.dependencies_clear == true then
					local action, action_error = io_call(config.delete_if_generation, item, inspected.generation)
					if action == "unknown" then self.status = "unknown"; self.last_error = action_error; return { code = "unknown", cursor = before_cursor, message = action_error or "delete unresolved" } end
					if action == "deleted" then self.removed += 1 end
				end
				self.processed += 1
			end
			if self.status ~= "paused" then self.cursor = next_cursor end
			local persisted, persist_error = io_call(config.persist_progress, self.cursor, self.processed, self.removed, self.status)
			if persisted ~= true then self.status = "unknown"; self.last_error = persist_error; return { code = "unknown", cursor = before_cursor, message = persist_error or "checkpoint unresolved" } end
			if complete == true or next_cursor == nil then self.status = "completed" elseif self.status ~= "paused" then self.status = "incomplete" end
			return { code = self.status, cursor = self.cursor, processed = self.processed, removed = self.removed }
		end
		function compactor:Resume(cursor) self.cursor = cursor or self.cursor; self.status = "incomplete"; return true end
		function compactor:Pause() self.status = "paused"; return true end
		function compactor:Stats() return { status = self.status, cursor = self.cursor, processed = self.processed, removed = self.removed, last_error = self.last_error } end
		return compactor
	end
	return service
end

function V2.new(record_store, mailbox_module, options)
	options = options or {}
	if type(record_store) ~= "table" or type(record_store.new) ~= "function" then error("RecordStoreV2 requires RecordStore", 2) end
	if type(mailbox_module) ~= "table" or type(mailbox_module.new) ~= "function" then error("RecordStoreV2 requires RecordStoreMailboxV2", 2) end
	if type(record_store.apply_runtime_policy) ~= "function" or type(record_store.get_runtime_stats) ~= "function"
		or type(record_store.register_runtime_governor_hooks) ~= "function"
	then
		error("RecordStoreV2 requires the shared RecordStore runtime governor APIs", 2)
	end
	local runtime_governor = shared_runtime_governor(record_store, options.runtime)
	local registered, registration_error = record_store.register_runtime_governor_hooks({
		admit = function(work_class, request_kind, mutating)
			return runtime_governor:Admit(work_class, request_kind, 1, mutating)
		end,
		release = function(ticket)
			runtime_governor:Release(ticket)
		end,
		observe = function(request_kind, success, duration_ms, error_message)
			local stats = record_store.get_runtime_stats()
			local budget = if request_kind == "read" then stats.read_budget
				elseif request_kind == "service" then nil else stats.write_budget
			local error_class = nil
			if not success then
				local normalized = string.lower(tostring(error_message or ""))
				if string.find(normalized, "thrott", 1, true) ~= nil
					or string.find(normalized, "request limit", 1, true) ~= nil
					or string.find(normalized, "rate limit", 1, true) ~= nil
					or string.find(normalized, "429", 1, true) ~= nil
				then
					error_class = "throttled"
				elseif string.find(normalized, "budget", 1, true) ~= nil then
					error_class = "budget"
				else
					error_class = "request_error"
				end
			end
			runtime_governor:Observe(request_kind, success, duration_ms, error_class, budget)
		end,
	})
	if registered ~= "success" then error("failed to register shared runtime governor: " .. tostring(registration_error), 2) end
	local api = {
		Version = 2,
		DeliveryGuarantee = "at-least-once",
		OrderingContract = "strict ordering_key is not enabled; priority is a hint among eligible messages",
		Canonicalize = canonical,
		Fingerprint = function(value) local ok, material = pcall(canonical, value); return if ok then digest(material) else nil end end,
		Mailbox = { new = function(store, owner, mailbox_options) return mailbox_module.new(store, owner, mailbox_options) end },
		Transactions = {},
		Inbox = new_inbox(),
		Outbox = new_outbox(),
		RuntimeGovernor = {
			new = new_governor,
			get_shared = function() return runtime_governor end,
		},
		Tracing = { new = new_tracer },
		Migrations = { new = new_migrations },
		ProfileDoctor = new_doctor(record_store),
		ReceiptProcessor = { new = new_receipt_processor },
		Sagas = { new = saga_coordinator },
		Erasure = { new = new_erasure },
		Rollout = { new = new_rollout },
		Projections = { new = new_projections },
		ReadCoalescer = { new = new_read_coalescer },
		Maintenance = new_maintenance(),
	}
	api.Transactions.Run = function(record, id, request, reducer) return transaction_run(record, id, request, reducer) end
	api.Transactions.CommitWithOutbox = function(record, id, request, reducer, events) return transaction_run(record, id, request, reducer, "outbox", events) end
	api.Transactions.RetryAdvice = function(result)
		if type(result) ~= "table" then return { action = "stop", reason = "result unavailable" } end
		if result.code == "committed" or result.code == "duplicate" then return { action = "do_not_retry", reason = "durable result confirmed" } end
		if result.code == "retryable" then return { action = "retry_same_operation_id", reason = "known retryable result" } end
		if result.code == "unknown" then return { action = "reconcile_first", reason = "write may have committed" } end
		if result.code == "capacity" then return { action = "backpressure", reason = "no partial acceptance implied" } end
		return { action = "stop", reason = "conflict, validation, fencing, or unsupported state needs resolution" }
	end
	-- The core RecordStore module owns the one server-local request governor shared by all Records.
	-- This facade delegates policy application/snapshots to that governor instead of creating a
	-- second request-admission loop inside V2.
	api.ApplyRuntimePolicy = function(policy)
		return record_store.apply_runtime_policy(policy)
	end
	api.ApplySchedulerPolicy = function(policy)
		if type(policy) ~= "table" then return "invalid", "scheduler policy must be a table" end
		local applied, message = runtime_governor:SetPolicy(policy)
		return if applied then "success" else "invalid", message
	end
	api.GetRuntimeSnapshot = function()
		return record_store.get_runtime_stats()
	end
	api.GetDurabilitySLO = function(record, threshold)
		return runtime_governor:GetDurabilitySLO(record, threshold)
	end
	api.GetContentionDiagnostics = function(record)
		return runtime_governor:GetContentionDiagnostics(record)
	end
	api.ShouldSave = function(record) return new_maintenance().ShouldSave(record_stats(record)) end
	api.RenderErasureTemplate = render_template
	api.Acceleration = options.acceleration_module
	local dispatch_metrics = { accepted = 0, rejected = 0, dispatched = 0, callback_errors = 0, last_error = nil }
	local dispatch_callbacks = {}
	local dispatch_sequence = 0
	local dispatcher_running = false
	local function kick_dispatcher()
		if dispatcher_running then return end
		dispatcher_running = true
		spawn_scheduled(function()
			while true do
				local item = runtime_governor:TakeNext()
				if item == nil then break end
				local callback = dispatch_callbacks[item.id]
				dispatch_callbacks[item.id] = nil
				if callback ~= nil then
					local callback_ok, callback_error = pcall(callback)
					if callback_ok then
						dispatch_metrics.dispatched += 1
					else
						dispatch_metrics.callback_errors += 1
						dispatch_metrics.last_error = text_error(callback_error, 200)
					end
				end
				runtime_governor:MarkCompleted(item.id)
			end
			dispatcher_running = false
			-- Recheck after releasing the single dispatcher; enqueue never drops
			-- durable mailbox work, and later polling remains the liveness fallback.
			if runtime_governor:Stats().queue_items > 0 then kick_dispatcher() end
		end)
	end
	api.GetSchedulerDispatchStats = function() return copy(dispatch_metrics) end
	api.BindMailboxWakeups = function(accelerator, owner, mailbox, handler, max_messages_per_wake)
		if type(accelerator) ~= "table" or type(accelerator.Register) ~= "function" then
			return false, "an initialized RecordStoreV2Acceleration instance is required"
		end
		if type(mailbox) ~= "table" or type(mailbox.ProcessNextAsync) ~= "function" or type(mailbox.BindWakeups) ~= "function" then
			return false, "mailbox must expose ProcessNextAsync and BindWakeups"
		end
		if type(handler) ~= "function" then return false, "handler must be a function" end
		local owner_text, owner_error = request_material(owner)
		if owner_text == nil then return false, owner_error or "mailbox owner is not canonicalizable" end
		local owner_digest = digest(owner_text)
		local limit = math.clamp(math.floor(max_messages_per_wake or 4), 1, 32)
		local bound, bind_error = mailbox:BindWakeups(accelerator)
		if not bound then return false, bind_error end
		return accelerator:Register(owner_text, function(reason)
			dispatch_sequence += 1
			local job_id = "rv2w:" .. tostring(dispatch_sequence)
			local due_now = if options.runtime ~= nil and type(options.runtime.now_ms) == "function"
				then options.runtime.now_ms() else os.clock() * 1000
			local accepted = runtime_governor:Enqueue({
				id = job_id,
				owner_id = owner_digest,
				lane = "normal",
				due_at_ms = due_now,
				wake_reason = if valid_text(reason, 32) then reason else "unknown",
			})
			if type(accepted) ~= "table" or accepted.code ~= "accepted" then
				dispatch_metrics.rejected += 1
				return
			end
			dispatch_callbacks[job_id] = function()
				for _ = 1, limit do
					local result = mailbox:ProcessNextAsync(handler)
					if type(result) ~= "table" or result.code ~= "processed" then break end
				end
			end
			dispatch_metrics.accepted += 1
			kick_dispatcher()
		end)
	end
	return api
end

V2.canonical = canonical
V2.fingerprint = function(value) local ok, material = pcall(canonical, value); return if ok then digest(material) else nil end
return V2
