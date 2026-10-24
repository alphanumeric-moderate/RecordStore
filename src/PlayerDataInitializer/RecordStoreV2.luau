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
local RESERVED_ROOT = "__recordstore_"
local RESERVED = "__recordstore_v2_"

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function valid_text(value, maximum)
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function is_reserved_data_key(key)
	return type(key) == "string" and string.sub(key, 1, #RESERVED_ROOT) == RESERVED_ROOT
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
	local selection_now_override: number? = nil
	local function now_ms()
		if selection_now_override ~= nil then return selection_now_override end
		return if type(options.now_ms) == "function" then options.now_ms() else os.clock() * 1000
	end
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
			for _, row in ipairs(background) do if now - row.item.enqueued_at_ms >= (self.aging_threshold_ms or 10000) then candidates = background break end end
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

	function governor:SelectCandidates(candidates, owner_id, observed_now_ms, priority_aging_ms)
		if type(candidates) ~= "table" or #candidates > 4096 then
			return nil, "candidate list must be a table with at most 4096 entries"
		end
		if type(owner_id) ~= "string" or owner_id == "" or not finite(observed_now_ms) then
			return nil, "candidate selection needs owner identity and a finite observation time"
		end
		local age_limit = priority_aging_ms or 60000
		if not finite(age_limit) or age_limit < 1 or age_limit > 3600000 then
			return nil, "priority_aging_ms must be between 1 and 3600000"
		end
		local owner_key = digest(owner_id)
		local original_by_id = {}
		local queue = {}
		for index, value in ipairs(candidates) do
			local candidate = if type(value) == "table" then value else nil
			local route = if candidate ~= nil then candidate.Id else nil
			if type(route) ~= "string" or route == "" then
				return nil, ("candidate %d has no stable string Id"):format(index)
			end
			-- Mailbox routes are already unique, bounded durable key identities. Reuse them
			-- directly instead of hashing every candidate on every poll.
			local identity = route
			if original_by_id[identity] == nil then
				local lane = tostring(candidate.Priority or "normal")
				if lane ~= "high" and lane ~= "normal" and lane ~= "background" then lane = "normal" end
				local created_at = if finite(candidate.CreatedAt) then candidate.CreatedAt else observed_now_ms
				local due_at = if finite(candidate.AvailableAt) then candidate.AvailableAt else created_at
				local deadline = if finite(candidate.ExpiresAt) then candidate.ExpiresAt else nil
				original_by_id[identity] = candidate
				table.insert(queue, {
					id = identity,
					owner_id = owner_key,
					lane = lane,
					cost = 1,
					enqueued_at_ms = created_at,
					due_at_ms = due_at,
					deadline_ms = deadline,
					-- Expired durable messages must still reach _claim so the mailbox can
					-- commit the terminal "expired" transition. Expiry remains authoritative there.
					dependencies = {},
				})
			end
		end
		local shadow = {
			queue = queue,
			completed = {},
			known = {},
			owner_finish = copy(self.owner_finish),
			high_streak = self.high_streak,
			policy = self.policy,
			aging_threshold_ms = age_limit,
		}
		local previous_override = selection_now_override
		selection_now_override = observed_now_ms
		local ok, ordered_or_error = pcall(function()
			local ordered = {}
			while #shadow.queue > 0 do
				local index = choose_index(shadow)
				if index == nil then break end
				local item = table.remove(shadow.queue, index)
				local original = original_by_id[item.id]
				if original ~= nil then table.insert(ordered, original) end
				if item.lane == "high" then shadow.high_streak += 1 else shadow.high_streak = 0 end
				local weight = if item.lane == "high" then 4 elseif item.lane == "background" then 1 else 2
				shadow.owner_finish[item.owner_id] = (shadow.owner_finish[item.owner_id] or 0) + (item.cost or 1) / weight
			end
			return ordered
		end)
		selection_now_override = previous_override
		if not ok then return nil, tostring(ordered_or_error) end
		return ordered_or_error, nil
	end

	function governor:MarkSelected(candidate, owner_id)
		if type(candidate) ~= "table" or type(candidate.Id) ~= "string" or type(owner_id) ~= "string" or owner_id == "" then
			return false, "candidate selection receipt is invalid"
		end
		local lane = tostring(candidate.Priority or "normal")
		if lane ~= "high" then self.high_streak = 0 else self.high_streak += 1 end
		local weight = if lane == "high" then 4 elseif lane == "background" then 1 else 2
		local owner_key = digest(owner_id)
		self.owner_finish[owner_key] = (self.owner_finish[owner_key] or 0) + 1 / weight
		return true, nil
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

local function new_migrations(options)
	options = options or {}
	local manifest_store = options.manifest_store or options.store
	local require_durable_manifest = options.require_durable_manifest == true
	local registry = { steps = {}, ids = {}, local_status = {}, operation_steps = {} }
	local function manifest_key(step)
		return "rv2m-" .. digest(step.store_name .. ":" .. step.id)
	end
	local function same_manifest(value, step)
		return type(value) == "table" and value.version == 1
			and value.store_name == step.store_name and value.from_version == step.from_version
			and value.to_version == step.to_version and value.id == step.id and value.revision == step.revision
	end
	local function apply_manifest_patch(target, patch)
		for key, field_value in pairs(patch) do
			if key ~= "clear_fields" then target[key] = copy(field_value) end
		end
		if type(patch.clear_fields) == "table" then
			for _, key in ipairs(patch.clear_fields) do
				if type(key) == "string" then target[key] = nil end
			end
		end
		return target
	end
	local function manifest_matches_patch(value, step, patch)
		if not same_manifest(value, step) then return false end
		if patch == nil then return true end
		for key, expected in pairs(patch) do
			if key ~= "clear_fields" then
				local expected_ok, expected_text = pcall(canonical, expected)
				local observed_ok, observed_text = pcall(canonical, value[key])
				if not expected_ok or not observed_ok or expected_text ~= observed_text then return false end
			end
		end
		if type(patch.clear_fields) == "table" then
			for _, key in ipairs(patch.clear_fields) do
				if type(key) == "string" and value[key] ~= nil then return false end
			end
		end
		return true
	end
	local function save_manifest(step, patch)
		if manifest_store == nil then
			if require_durable_manifest then return false, "durable manifest store is required" end
			return true, "process_local"
		end
		local decision = "unknown"
		local value, write_error = adapter_call(manifest_store, "UpdateAsync", manifest_key(step), function(old)
			decision = "unknown"
			if old ~= nil then
				if not same_manifest(old, step) then decision = "conflict"; return old end
				local next_value = copy(old)
				if patch ~= nil then apply_manifest_patch(next_value, patch) end
				decision = if patch == nil then "duplicate" else "committed"
				return next_value
			end
			local created = {
				version = 1, store_name = step.store_name, from_version = step.from_version,
				to_version = step.to_version, id = step.id, revision = step.revision,
				status = "registered", created_at = os.time(), updated_at = os.time(),
			}
			if patch ~= nil then apply_manifest_patch(created, patch) end
			decision = "committed"
			return created
		end)
		if write_error then
			local observed, read_error = adapter_call(manifest_store, "GetAsync", manifest_key(step))
			if read_error == nil and manifest_matches_patch(observed, step, patch) then
				return true, "unknown_reconciled"
			end
			return false, read_error or write_error
		end
		if decision == "conflict" or not same_manifest(value, step) then
			return false, "migration ID conflicts with its durable manifest"
		end
		return true, decision
	end
	function registry:Register(store_name, from_version, to_version, id, revision, migrate, validate, metadata)
		if not valid_text(store_name, 50) or not finite(from_version) or not finite(to_version) or from_version < 0
			or math.floor(from_version) ~= from_version or to_version ~= from_version + 1
			or not valid_text(id, 96) or not valid_text(revision, 96) or type(migrate) ~= "function"
			or (validate ~= nil and type(validate) ~= "function")
		then return false, "migration requires stable IDs, declared consecutive versions, transform and optional validator" end
		local prior = self.ids[id]
		if prior and (prior.revision ~= revision or prior.store_name ~= store_name or prior.from_version ~= from_version or prior.to_version ~= to_version) then
			return false, "migration ID reused with incompatible metadata"
		end
		self.steps[store_name] = self.steps[store_name] or {}
		local existing_step = self.steps[store_name][from_version]
		if existing_step and existing_step.id ~= id then return false, "ambiguous migration path" end
		local step = prior or {
			store_name = store_name, from_version = from_version, to_version = to_version,
			id = id, revision = revision, migrate = migrate, validate = validate, metadata = copy(metadata or {}),
		}
		local persisted, persist_result = save_manifest(step, nil)
		if not persisted then return false, persist_result end
		if prior then return true, "duplicate" end
		self.steps[store_name][from_version] = step
		self.ids[id] = step
		self.operation_steps["rv2:migrate:" .. digest(store_name .. ":" .. step.id .. ":" .. step.revision)] = step
		return true, persist_result
	end
	function registry:Plan(store, from_version, target)
		if not finite(from_version) or not finite(target) or from_version < 0 or target < from_version or math.floor(from_version) ~= from_version or math.floor(target) ~= target then return nil, "invalid or backward version request" end
		local result = {}
		for version = from_version, target - 1 do
			local step = (self.steps[store] or {})[version]
			if not step or step.to_version ~= version + 1 then return nil, "missing migration from version " .. tostring(version) end
			if require_durable_manifest and manifest_store == nil then return nil, "durable migration manifest store is required" end
			if manifest_store ~= nil then
				local manifest, manifest_error = adapter_call(manifest_store, "GetAsync", manifest_key(step))
				if manifest_error then return nil, "migration manifest status unknown: " .. tostring(manifest_error) end
				if not same_manifest(manifest, step) then return nil, "durable migration manifest is missing or incompatible" end
				if manifest.status == "quarantined" then return nil, "migration is durably quarantined" end
			end
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
		local active_ok, record_state, record_open = pcall(function() return record:GetState(), record:IsOpen() end)
		if not active_ok or record_state ~= "active" or record_open ~= true then return { code = "fenced", message = "migration requires an active Record session" } end
		for _, step in ipairs(steps) do
			local operation_id = "rv2:migrate:" .. digest(store_name .. ":" .. step.id .. ":" .. step.revision)
			local expected_revision = if type(record.GetRevision) == "function" then record:GetRevision() else nil
			local expected_generation = if type(record.GetGeneration) == "function" then record:GetGeneration() else nil
			local request = {
				store_name = store_name, migration_id = step.id, revision = step.revision,
				from_version = step.from_version, to_version = step.to_version,
				expected_revision = expected_revision, expected_generation = expected_generation,
			}
			local manifest_saved, manifest_result = save_manifest(step, {
				status = "running", operation_id = operation_id, expected_revision = expected_revision,
				expected_generation = expected_generation, started_at = os.time(), updated_at = os.time(),
			})
			if not manifest_saved then return { code = "unknown", migration_id = step.id, message = manifest_result } end
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
			if result.code ~= "committed" and result.code ~= "duplicate" then
				local quarantine = result.code == "validation" or result.code == "invalid" or result.code == "unsupported_schema"
				local saved, save_error = save_manifest(step, {
					status = if quarantine then "quarantined" else "unknown",
					last_error = text_error(result.message or result.code, 256),
					failed_at = os.time(), updated_at = os.time(), failed_revision = expected_revision,
				})
				result.manifest_status = if saved then (if quarantine then "quarantined" else "unknown") else "unknown"
				result.manifest_message = save_error
				result.completed_steps = completed; result.current_version = step.from_version
				return result
			end
			local manifest_updated, manifest_message = save_manifest(step, {
				status = "committed", operation_id = operation_id, committed_at = os.time(),
				updated_at = os.time(), committed_revision = if type(record.GetRevision) == "function" then record:GetRevision() else nil,
				committed_generation = if type(record.GetGeneration) == "function" then record:GetGeneration() else nil,
				clear_fields = { "last_error" },
			})
			if not manifest_updated then
				return { code = "unknown", migration_id = step.id, message = "profile step is committed but manifest confirmation is unresolved: " .. tostring(manifest_message), completed_steps = completed }
			end
			completed += 1
		end
		local after = record_data(record)
		return { code = "committed", completed_steps = completed, current_version = if type(after) == "table" then after[field] or 0 else target_version, target_version = target_version }
	end
	function registry:GetStatus(operation_id)
		local step = self.operation_steps[operation_id]
		if step ~= nil and manifest_store ~= nil then
			local manifest, message = adapter_call(manifest_store, "GetAsync", manifest_key(step))
			if message then return { code = "unknown", message = message } end
			if same_manifest(manifest, step) then return copy(manifest) end
		end
		return copy(self.local_status[operation_id] or { code = "not_found", message = "status not found in available durable migration manifests or local cache" })
	end
	function registry:ResolveQuarantine(store_name, migration_id, revision, operator_id, reason)
		if not manifest_store then return { code = "unsupported", message = "durable manifest store is required" } end
		if not valid_text(operator_id, 96) or not valid_text(reason, 512) then return { code = "invalid", message = "resolution requires operator ID and reason" } end
		local step = self.ids[migration_id]
		if not step or step.store_name ~= store_name or step.revision ~= revision then return { code = "not_found" } end
		local decision = "unknown"
		local value, message = adapter_call(manifest_store, "UpdateAsync", manifest_key(step), function(old)
			decision = "unknown"
			if not same_manifest(old, step) then decision = "conflict"; return old end
			if old.status ~= "quarantined" then decision = if old.status == "registered" then "duplicate" else "conflict"; return old end
			local next_value = copy(old)
			next_value.status = "registered"
			next_value.resolution = { operator_id = operator_id, reason = reason, at_unix = os.time() }
			next_value.updated_at = os.time()
			decision = "committed"
			return next_value
		end)
		if message then return { code = "unknown", message = message } end
		if decision == "conflict" then return { code = "conflict" } end
		return { code = decision, manifest = value }
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
		if type(options.authorize) ~= "function" then
			return { code = "disabled", message = "restore requires an explicit application authorization callback" }
		end
		if not finite(options.subject_user_id) or options.subject_user_id < 1
			or math.floor(options.subject_user_id) ~= options.subject_user_id
			or type(options.is_erased) ~= "function"
		then
			return { code = "invalid", message = "restore requires a UserId and a durable erasure-status callback" }
		end
		local authorized, authorization_error = io_call(
			options.authorize,
			operator_id,
			reason,
			expected_revision,
			options.subject_user_id,
			record
		)
		if authorized ~= true then
			return {
				code = if authorized == nil then "unknown" else "denied",
				message = "restore authorization was not granted",
				detail = authorization_error,
			}
		end
		local erased, erasure_status = io_call(options.is_erased, options.subject_user_id)
		if erased == true then return { code = "erased", message = "restore is blocked by erasure tombstone" } end
		if erased ~= false then
			return { code = "unknown", message = "erasure status unresolved; restore fails closed", detail = erasure_status }
		end
		local current_data, current_error = record_data(record)
		if type(current_data) ~= "table" then
			return { code = "unknown", message = "current profile snapshot is unavailable", detail = current_error }
		end
		local current_ok, current_text = pcall(canonical, current_data)
		if not current_ok then return { code = "corrupt", message = tostring(current_text) } end
		local expected_data_digest = digest(current_text)
		local historical_ok, historical_text = pcall(canonical, historical_data)
		if not historical_ok then return { code = "invalid", message = tostring(historical_text) } end
		local request = {
			kind = "guarded_restore",
			restore_id = restore_id,
			operator_id = operator_id,
			reason = reason,
			expected_revision = expected_revision,
			expected_data_digest = expected_data_digest,
			subject_user_id = options.subject_user_id,
			historical_digest = digest(historical_text),
		}
		local result = transaction_run(record, "rv2:restore:" .. digest(restore_id), request, function(current)
			if type(current) ~= "table" then error("restore requires table profile") end
			local current_ok, current_text = pcall(canonical, current)
			if not current_ok or digest(current_text) ~= expected_data_digest then
				error("profile data changed after restore preflight")
			end
			local merged = {}
			for key, value in pairs(current) do if not is_reserved_data_key(key) then merged[key] = copy(value) end end
			for key, value in pairs(historical_data) do if not is_reserved_data_key(key) then merged[key] = copy(value) end end
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
	function doctor.QuarantineAsync(record, quarantine_store, quarantine_id, operator_id, reason, expected_revision)
		if type(quarantine_store) ~= "table" or not valid_text(quarantine_id, 96)
			or not valid_text(operator_id, 96) or not valid_text(reason, 512)
		then return { code = "invalid", message = "durable quarantine store, quarantine ID, operator ID and reason are required" } end
		local active_ok, state, is_open, identity = pcall(function()
			return record:GetState(), record:IsOpen(), record:GetIdentity()
		end)
		if not active_ok or state ~= "active" or is_open ~= true or type(identity) ~= "table" then return { code = "fenced" } end
		local stats = record_stats(record)
		if expected_revision ~= nil and stats.revision ~= expected_revision then return { code = "conflict", message = "record revision changed after diagnosis" } end
		local identity_text = canonical({ store_name = identity.store_name, scope = identity.scope, profile_key = identity.profile_key })
		local key = "rv2q-" .. digest(identity_text)
		local decision = "unknown"
		local value, message = adapter_call(quarantine_store, "UpdateAsync", key, function(old)
			decision = "unknown"
			if old ~= nil then
				if old.identity_text ~= identity_text then decision = "conflict"; return old end
				if old.quarantine_id == quarantine_id then decision = "duplicate"; return old end
				if old.status == "quarantined" then decision = "conflict"; return old end
			end
			decision = "committed"
			return {
				version = 1, identity_text = identity_text, store_name = identity.store_name,
				scope = identity.scope, profile_key = identity.profile_key, quarantine_id = quarantine_id,
				status = "quarantined", observed_revision = stats.revision, observed_generation = stats.generation,
				operator_id = operator_id, reason = reason, created_at = os.time(), updated_at = os.time(),
			}
		end)
		if message then
			local observed = adapter_call(quarantine_store, "GetAsync", key)
			if type(observed) == "table" and observed.identity_text == identity_text and observed.quarantine_id == quarantine_id then
				return { code = "unknown_reconciled", status = observed.status, manifest = copy(observed) }
			end
			return { code = "unknown", message = message }
		end
		if decision == "conflict" then return { code = "conflict", message = "another quarantine owns this profile" } end
		return { code = decision, status = value and value.status, manifest = copy(value) }
	end
	function doctor.GetQuarantineStatusAsync(record, quarantine_store)
		if type(quarantine_store) ~= "table" then return { code = "unsupported" } end
		local identity_ok, identity = pcall(function() return record:GetIdentity() end)
		if not identity_ok or type(identity) ~= "table" then return { code = "unknown" } end
		local identity_text = canonical({ store_name = identity.store_name, scope = identity.scope, profile_key = identity.profile_key })
		local value, message = adapter_call(quarantine_store, "GetAsync", "rv2q-" .. digest(identity_text))
		if message then return { code = "unknown", message = message } end
		if not value then return { code = "not_found", status = "not_quarantined" } end
		if type(value) ~= "table" or value.identity_text ~= identity_text then return { code = "conflict" } end
		return { code = "success", status = value.status, manifest = copy(value) }
	end
	function doctor.CheckWritableAsync(record, quarantine_store)
		local status = doctor.GetQuarantineStatusAsync(record, quarantine_store)
		if type(status) ~= "table" then
			return { code = "unknown", allowed = false, message = "quarantine lookup returned no status" }
		end
		if status.code == "not_found" then return { code = "success", allowed = true, status = "not_quarantined" } end
		if status.code ~= "success" then
			return { code = "unknown", allowed = false, message = status.message or ("quarantine lookup returned " .. tostring(status.code)) }
		end
		if status.status == "resolved" then return { code = "success", allowed = true, status = "resolved" } end
		if status.status == "quarantined" then return { code = "quarantined", allowed = false, manifest = status.manifest } end
		return { code = "unknown", allowed = false, message = "unrecognized quarantine state" }
	end
	function doctor.ResolveQuarantineAsync(record, quarantine_store, quarantine_id, operator_id, reason, expected_revision)
		if type(quarantine_store) ~= "table" or not valid_text(quarantine_id, 96)
			or not valid_text(operator_id, 96) or not valid_text(reason, 512)
		then return { code = "invalid", message = "durable store, quarantine ID, operator ID and reason are required" } end
		local active_ok, state, is_open, identity = pcall(function() return record:GetState(), record:IsOpen(), record:GetIdentity() end)
		if not active_ok or state ~= "active" or is_open ~= true or type(identity) ~= "table" then return { code = "fenced" } end
		local stats = record_stats(record)
		if expected_revision ~= nil and stats.revision ~= expected_revision then return { code = "conflict", message = "record revision changed after quarantine" } end
		local identity_text = canonical({ store_name = identity.store_name, scope = identity.scope, profile_key = identity.profile_key })
		local key = "rv2q-" .. digest(identity_text)
		local decision = "unknown"
		local value, message = adapter_call(quarantine_store, "UpdateAsync", key, function(old)
			decision = "unknown"
			if type(old) ~= "table" or old.identity_text ~= identity_text or old.quarantine_id ~= quarantine_id then decision = "conflict"; return old end
			if old.status == "resolved" then decision = "duplicate"; return old end
			if old.status ~= "quarantined" then decision = "conflict"; return old end
			local next_value = copy(old)
			next_value.status = "resolved"
			next_value.resolution = { operator_id = operator_id, reason = reason, at_unix = os.time(), revision = stats.revision }
			next_value.updated_at = os.time()
			decision = "committed"
			return next_value
		end)
		if message then return { code = "unknown", message = message } end
		return { code = decision, status = value and value.status, manifest = copy(value) }
	end
	return doctor
end

local function saga_coordinator(store, options)
	options = options or {}
	local api = { store = store }
	local function update_saga(id, request, mutate)
		local material = canonical(request)
		local key, now = "rv2s-" .. digest(id), os.time()
		local decision, candidate
		local value, message = adapter_call(store, "UpdateAsync", key, function(old)
			decision = nil
			candidate = nil
			if old ~= nil and (type(old) ~= "table" or old.transfer_id ~= id or old.request_material ~= material) then decision = "conflict"; return old end
			local state = if type(old) == "table" then copy(old) else { version = 1, transfer_id = id, request_material = material, phase = "requested", status = "pending", created_at = now, attempts = 0 }
			local changed, err = pure(mutate, state)
			if type(changed) ~= "table" then
				decision = if err == "conflict" or err == "duplicate" or err == "manual_resolution_required"
					then err else "invalid"
				return nil
			end
			changed.updated_at = now
			changed.attempts = (changed.attempts or 0) + 1
			candidate = copy(changed)
			decision = "committed"
			return changed
		end)
		if message then
			local seen = adapter_call(store, "GetAsync", key)
			if type(seen) == "table" and type(candidate) == "table"
				and seen.transfer_id == id and seen.request_material == material
			then
				local expected_ok, expected_material = pcall(canonical, candidate)
				local seen_ok, seen_material = pcall(canonical, seen)
				if expected_ok and seen_ok and expected_material == seen_material then
					return copy(seen), "committed"
				end
			end
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
	function api:RequireManualResolutionAsync(id, request, expected_phase, expected_status, manual_request_id, operator_id, reason)
		if not valid_text(id, 128) or type(request) ~= "table" or request.transfer_id ~= id
			or not valid_text(manual_request_id, 128) or not valid_text(operator_id, 96)
			or not valid_text(reason, 512)
		then return { code = "invalid", message = "stable transfer/request IDs, operator identity, and reason are required" } end
		local request_bytes, request_error = request_material(request)
		if not request_bytes then return { code = "invalid", message = request_error } end
		if expected_phase ~= "requested" and expected_phase ~= "reserved"
			and expected_phase ~= "credit_pending" and expected_phase ~= "credited"
		then return { code = "invalid", message = "expected_phase is not a manually recoverable saga phase" } end
		if expected_status ~= "pending" and expected_status ~= "reconciliation_required" then
			return { code = "invalid", message = "expected_status must be pending or reconciliation_required" }
		end
		local value, code, message = update_saga(id, request, function(current)
			if current.phase == "settled" or current.phase == "rejected" then return nil, "conflict" end
			if current.phase == "manual_resolution_required" then
				if type(current.manual_resolution) == "table"
					and current.manual_resolution.request_id == manual_request_id
				then return nil, "duplicate" end
				return nil, "conflict"
			end
			if current.phase ~= expected_phase or current.status ~= expected_status then return nil, "conflict" end
			current.manual_resolution = {
				request_id = manual_request_id,
				requested_by = operator_id,
				reason = text_error(reason, 512),
				requested_at = os.time(),
				prior_phase = current.phase,
				prior_status = current.status,
			}
			current.phase = "manual_resolution_required"
			current.status = "manual_resolution_required"
			return current
		end)
		if not value then return { code = code or "unknown", transfer_id = id, message = message } end
		if value.phase ~= "manual_resolution_required" or type(value.manual_resolution) ~= "table"
			or value.manual_resolution.request_id ~= manual_request_id
		then return { code = "conflict", transfer_id = id, message = "durable saga did not enter the requested manual-resolution state" } end
		return {
			code = if code == "duplicate" then "duplicate" else "committed",
			transfer_id = id,
			phase = value.phase,
			status = value.status,
			manual_request_id = manual_request_id,
		}
	end
	function api:ResolveManualAsync(id, request, manual_request_id, resolution_id, decision, operator_id, reason, verify_outcome)
		if not valid_text(id, 128) or type(request) ~= "table" or request.transfer_id ~= id
			or not valid_text(manual_request_id, 128) or not valid_text(resolution_id, 128)
			or not valid_text(operator_id, 96) or not valid_text(reason, 512)
		then return { code = "invalid", message = "stable IDs, operator identity, and reason are required" } end
		if decision ~= "resume" and decision ~= "confirm_settled" and decision ~= "confirm_rejected" then
			return { code = "invalid", message = "decision must be resume, confirm_settled, or confirm_rejected" }
		end
		local request_bytes, request_error = request_material(request)
		if not request_bytes then return { code = "invalid", message = request_error } end
		local observed = self:GetStatus(id)
		if observed.code == "unknown" or observed.code == "not_found" or observed.code == "invalid" then
			return { code = observed.code, transfer_id = id, message = observed.message }
		end
		if observed.transfer_id ~= id or observed.request_material ~= request_bytes then
			return { code = "conflict", transfer_id = id, message = "transfer request identity does not match the durable saga" }
		end
		local manual = observed.manual_resolution
		if observed.phase ~= "manual_resolution_required" then
			if type(manual) == "table" and type(manual.resolution) == "table"
				and manual.resolution.resolution_id == resolution_id and manual.resolution.decision == decision
			then return { code = "duplicate", transfer_id = id, phase = observed.phase, status = observed.status } end
			return { code = "conflict", transfer_id = id, message = "saga is not awaiting manual resolution" }
		end
		if type(manual) ~= "table" or manual.request_id ~= manual_request_id then
			return { code = "conflict", transfer_id = id, message = "manual-resolution request ID does not match the durable state" }
		end
		local evidence_id
		if decision == "confirm_settled" or decision == "confirm_rejected" then
			if type(verify_outcome) ~= "function" then
				return { code = "invalid", transfer_id = id, message = "terminal manual decisions require an application-supplied durable-outcome verifier" }
			end
			local verification_state = {
				transfer_id = id,
				phase = observed.phase,
				status = observed.status,
				prior_phase = manual.prior_phase,
				prior_status = manual.prior_status,
				sender_id = observed.sender_id,
				recipient_id = observed.recipient_id,
				amount = observed.amount,
				balance_field = observed.balance_field,
				last_error = observed.last_error,
			}
			local verified, durable_evidence_id = io_call(verify_outcome, copy(verification_state), decision)
			if verified ~= true or not valid_text(durable_evidence_id, 128) then
				return { code = "verification_failed", transfer_id = id, message = "application could not verify the requested terminal outcome" }
			end
			evidence_id = durable_evidence_id
		end
		local snapshot_attempts, snapshot_updated_at = observed.attempts, observed.updated_at
		local value, code, message = update_saga(id, request, function(current)
			local current_manual = current.manual_resolution
			if current.phase ~= "manual_resolution_required" or type(current_manual) ~= "table"
				or current_manual.request_id ~= manual_request_id
			then
				if type(current_manual) == "table" and type(current_manual.resolution) == "table"
					and current_manual.resolution.resolution_id == resolution_id
					and current_manual.resolution.decision == decision
				then return nil, "duplicate" end
				return nil, "conflict"
			end
			if current.attempts ~= snapshot_attempts or current.updated_at ~= snapshot_updated_at then return nil, "conflict" end
			local resolved_at = os.time()
			current_manual.resolution = {
				resolution_id = resolution_id,
				decision = decision,
				operator_id = operator_id,
				reason = text_error(reason, 512),
				evidence_id = evidence_id,
				resolved_at = resolved_at,
			}
			current_manual.resolved_at = resolved_at
			current_manual.resolved_by = operator_id
			if decision == "resume" then
				local prior_phase = current_manual.prior_phase
				if prior_phase ~= "requested" and prior_phase ~= "reserved"
					and prior_phase ~= "credit_pending" and prior_phase ~= "credited"
				then return nil, "conflict" end
				current.phase = prior_phase
				current.status = "pending"
				current.last_error = nil
			elseif decision == "confirm_settled" then
				current.phase = "settled"
				current.status = "settled"
				current.last_error = nil
			else
				current.phase = "rejected"
				current.status = "rejected"
				current.last_error = nil
			end
			return current
		end)
		if not value then return { code = code or "unknown", transfer_id = id, message = message } end
		if type(value.manual_resolution) ~= "table" or type(value.manual_resolution.resolution) ~= "table"
			or value.manual_resolution.resolution.resolution_id ~= resolution_id
			or value.manual_resolution.resolution.decision ~= decision
		then return { code = "conflict", transfer_id = id, message = "manual resolution did not match the durable result" } end
		return {
			code = if code == "duplicate" then "duplicate" else "committed",
			transfer_id = id,
			phase = value.phase,
			status = value.status,
			resolution_id = resolution_id,
			decision = decision,
		}
	end
	function api:TransferAsync(id, sender, recipient, amount, transfer_options)
		transfer_options = transfer_options or {}
		if not valid_text(id, 128) or not finite(amount) or amount <= 0 or (transfer_options.allow_fractional ~= true and math.floor(amount) ~= amount) then return { code = "invalid", message = "stable transfer ID and positive amount required" } end
		local sender_id, recipient_id = transfer_options.sender_id or "sender", transfer_options.recipient_id or "recipient"
		if sender_id == recipient_id then return { code = "invalid", message = "self-transfer unsupported" } end
		local balance_field, escrow_field = transfer_options.balance_field or "Balance", RESERVED .. "escrow"
		local request = { transfer_id = id, sender_id = sender_id, recipient_id = recipient_id, amount = amount, balance_field = balance_field }
		local saga, saga_code, saga_error = update_saga(id, request, function(current)
			if current.phase == "manual_resolution_required" then return nil, "manual_resolution_required" end
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
			local finished, finish_code, finish_error = mark("settled", "settled")
			if type(finished) ~= "table" or finished.phase ~= "settled" or finished.status ~= "settled" then
				return {
					code = "unknown",
					phase = if type(finished) == "table" then finished.phase else saga.phase,
					transfer_id = id,
					message = finish_error or (finish_code and tostring(finish_code)) or "settlement manifest is unresolved",
				}
			end
			return { code = "settled", phase = "settled", transfer_id = id }
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
	local all_templates, by_name = {}, {}
	for _, family in ipairs(families) do
		if not valid_text(family.name, 48) or by_name[family.name] then error("erasure families need unique names", 2) end
		by_name[family.name] = family
		local templates = family.templates or {}
		if #templates == 0 then error("each erasure family must declare at least one RTBF template", 2) end
		for _, template in ipairs(templates) do
			if type(template) ~= "table" then error("RTBF template must be table", 2) end
			local matchable = false
			for _, field in ipairs({ "name", "scope", "key" }) do
				if type(template[field]) == "string" and string.find(template[field], "{user_id}", 1, true) then matchable = true end
			end
			if not matchable then error("RTBF template must place {user_id} in name, scope, or key", 2) end
			table.insert(all_templates, { family = family.name, template = copy(template) })
			if #all_templates > MAX_ERASURE_TEMPLATES then error("RTBF templates exceed 100-template limit", 2) end
		end
	end
	local coordinator = { store = store, families = families }
	local function manifest_key(user_id) return "rv2erase-u" .. tostring(user_id) end
	function coordinator:RenderTemplates(user_id)
		if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then return nil, "invalid UserId" end
		local result = {}
		for _, entry in ipairs(all_templates) do table.insert(result, { family = entry.family, template = render_template(entry.template, user_id) }) end
		return result, nil
	end
	function coordinator:PlanAsync(user_id, erasure_id)
		if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id or not valid_text(erasure_id, 96) then return { code = "invalid" } end
		local entries, coverage, rendered = {}, {}, self:RenderTemplates(user_id)
		for _, family in ipairs(self.families) do
			if type(family.inventory) ~= "function" then
				coverage[family.name] = { status = "unresolved", count = 0, inventory_complete = false, unmatched_count = 0 }
			else
				local items, inventory_complete = io_call(family.inventory, user_id, MAX_ERASURE_ITEMS)
				if type(items) ~= "table" then
					coverage[family.name] = {
						status = "unresolved", count = 0, inventory_complete = false, unmatched_count = 0,
						message = inventory_complete,
					}
				else
					if #items > MAX_ERASURE_ITEMS then
						return { code = "capacity", family = family.name, maximum = MAX_ERASURE_ITEMS, message = "erasure inventory exceeds its per-family bound" }
					end
					if key_count(items) ~= #items then
						return { code = "invalid", family = family.name, message = "erasure inventory must be a dense array" }
					end
					for item_key in pairs(items) do
						if type(item_key) ~= "number" or not finite(item_key) or math.floor(item_key) ~= item_key
							or item_key < 1 or item_key > #items
						then return { code = "invalid", family = family.name, message = "erasure inventory must be a dense numeric array" } end
					end
					local count, unmatched_count, unmatched_samples = 0, 0, {}
					local seen_items = {}
					for _, item in ipairs(items) do
						if type(item) ~= "table" or not valid_text(item.key, 50) or not finite(item.generation) then
							return { code = "invalid", family = family.name, message = "inventory items require key and observed generation" }
						end
						if (item.name ~= nil and type(item.name) ~= "string")
							or (item.scope ~= nil and type(item.scope) ~= "string")
						then return { code = "invalid", family = family.name, message = "inventory name and scope must be strings when supplied" } end
						local locator = tostring(item.name or "") .. "\0" .. tostring(item.scope or "") .. "\0" .. item.key
					if seen_items[locator] then return { code = "invalid", family = family.name, message = "inventory repeats a DataStore name/scope/key locator" } end
						seen_items[locator] = true
						local matched_template = false
						for _, template_entry in ipairs(rendered) do
							if template_entry.family == family.name then
								local matches = true
								for _, field in ipairs({ "name", "scope", "key" }) do
									local expected = template_entry.template[field]
									if type(expected) == "string" and item[field] ~= expected then matches = false; break end
								end
								if matches then matched_template = true; break end
							end
						end
						if not matched_template then
							unmatched_count += 1
							if #unmatched_samples < 8 then table.insert(unmatched_samples, item.key) end
						end
						table.insert(entries, { family = family.name, item = copy(item) })
						count += 1
						if #entries > MAX_ERASURE_ITEMS then return { code = "capacity", family = family.name, message = "erasure plan exceeds bounded item count" } end
					end
					local inventory_is_complete = inventory_complete == true
					local status = if not inventory_is_complete then "inventory_incomplete"
						elseif family.templates_verified ~= true then "template_unverified"
						elseif unmatched_count > 0 then "unmatched_inventory"
						else "template_verified_by_integrator"
					coverage[family.name] = {
						status = status, count = count, inventory_complete = inventory_is_complete,
						unmatched_count = unmatched_count, unmatched_samples = unmatched_samples,
					}
				end
			end
		end
		local template_ok = if type(options.verify_templates) == "function" then io_call(options.verify_templates, user_id, rendered) else false
		local verified = #self.families > 0
		for _, row in pairs(coverage) do
			if row.status ~= "template_verified_by_integrator" or row.inventory_complete ~= true or row.unmatched_count ~= 0 then verified = false end
		end
		local manifest = {
			version = 1, user_id = user_id, erasure_id = erasure_id, status = "planned", cursor = 0,
			completed_count = 0, entries = entries, coverage = coverage,
			rtbf_coverage_verified = verified and template_ok == true, created_at = os.time(), updated_at = os.time(),
		}
		local value, message = adapter_call(store, "UpdateAsync", manifest_key(user_id), function(old)
			if old ~= nil then
				if type(old) ~= "table" or old.user_id ~= user_id or old.erasure_id ~= erasure_id then return old end
				return old
			end
			return manifest
		end)
		if message then
			local old = adapter_call(store, "GetAsync", manifest_key(user_id))
			if type(old) == "table" and old.user_id == user_id and old.erasure_id == erasure_id then
				local result = copy(old)
				result.code = "unknown_reconciled"
				return result
			end
			return { code = "unknown", message = message }
		end
		if type(value) ~= "table" or value.user_id ~= user_id or value.erasure_id ~= erasure_id then return { code = "conflict", message = "different erasure already owns this manifest key" } end
		if value.version ~= 1 or type(value.entries) ~= "table" or type(value.coverage) ~= "table"
			or not finite(value.cursor) or math.floor(value.cursor) ~= value.cursor or value.cursor < 0 or value.cursor > #value.entries
			or not finite(value.completed_count) or value.completed_count < 0 or math.floor(value.completed_count) ~= value.completed_count
			or (value.status ~= "planned" and value.status ~= "in_progress" and value.status ~= "unknown"
				and value.status ~= "blocked" and value.status ~= "completed" and value.status ~= "resolved")
		then return { code = "corrupt", message = "existing erasure manifest failed validation" } end
		local result = copy(value)
		result.code = "success"
		return result
	end
	function coordinator:ExecuteAsync(user_id, erasure_id, max_items)
		if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id or not valid_text(erasure_id, 96) then return { code = "invalid" } end
		max_items = math.clamp(math.floor(max_items or 16), 1, 64)
		local key = manifest_key(user_id)
		local manifest, message = adapter_call(store, "GetAsync", key)
		if message then return { code = "unknown", message = message } end
		if type(manifest) ~= "table" or manifest.user_id ~= user_id or manifest.erasure_id ~= erasure_id then return { code = "not_found" } end
		if manifest.status == "completed" then return { code = "committed", completed_count = manifest.completed_count or 0, cursor = manifest.cursor, rtbf_coverage_verified = manifest.rtbf_coverage_verified } end
		if manifest.status == "resolved" then return { code = "resolved", completed_count = manifest.completed_count or 0, cursor = manifest.cursor } end
		for _, family in ipairs(self.families) do
			if type(family.fence_user) ~= "function" or type(family.redact_or_delete_if_generation) ~= "function" then return { code = "unsupported", message = "family needs writer fence and generation-aware delete/redact" } end
			local fenced, fence_error = io_call(family.fence_user, user_id, erasure_id)
			if fenced ~= true then return { code = "retryable", message = fence_error or "writer fence unconfirmed" } end
		end
		local cursor, completed = manifest.cursor or 0, manifest.completed_count or 0
		for index = cursor + 1, math.min(#manifest.entries, cursor + max_items) do
			local entry, family = manifest.entries[index], by_name[manifest.entries[index].family]
			if not family then return { code = "corrupt", message = "unknown family in erasure plan" } end
			if type(family.dependencies_clear) == "function" then
				local clear, dependency_error = io_call(family.dependencies_clear, entry.item, user_id)
				if clear ~= true then return { code = "blocked", cursor = index - 1, message = dependency_error or "live dependency blocks deletion" } end
			end
			local status, action_error = io_call(family.redact_or_delete_if_generation, entry.item, user_id, erasure_id)
			if status ~= "deleted" and status ~= "redacted" then
				adapter_call(store, "UpdateAsync", key, function(old)
					if type(old) ~= "table" or old.user_id ~= user_id or old.erasure_id ~= erasure_id
						or old.status == "completed" or old.status == "resolved"
					then return old end
					local value = copy(old)
					value.status = if status == "unknown" then "unknown" else "in_progress"
					value.last_error = text_error(action_error or status, 256)
					return value
				end)
				return { code = if status == "unknown" then "unknown" else "retryable", cursor = index - 1, message = action_error or "delete outcome unresolved" }
			end
			completed += 1
			local progress_decision = "unknown"
			local updated, progress_error = adapter_call(store, "UpdateAsync", key, function(old)
				progress_decision = "unknown"
				if type(old) ~= "table" or old.user_id ~= user_id or old.erasure_id ~= erasure_id then
					progress_decision = "conflict"
					return old
				end
				if old.status == "completed" or old.status == "resolved" then
					progress_decision = "already_terminal"
					return old
				end
				local durable_cursor = old.cursor or 0
				if durable_cursor >= index then
					progress_decision = "already_checkpointed"
					return old
				end
				if durable_cursor ~= index - 1 then
					progress_decision = "conflict"
					return old
				end
				local value = copy(old)
				value.cursor = index
				value.completed_count = math.max(value.completed_count or 0, completed)
				value.status = "in_progress"
				value.updated_at = os.time()
				value.last_error = nil
				progress_decision = "committed"
				return value
			end)
			if progress_error or type(updated) ~= "table" then
				return { code = "unknown", cursor = index - 1, completed_count = completed, message = "action succeeded; repeat idempotently because cursor is unresolved" }
			end
			if progress_decision == "conflict" then
				return { code = "conflict", cursor = updated.cursor, completed_count = updated.completed_count, message = "erasure progress changed outside the expected cursor" }
			end
			cursor = updated.cursor or cursor
			completed = updated.completed_count or completed
		end
		local final, final_error = adapter_call(store, "UpdateAsync", key, function(old)
			if type(old) ~= "table" or old.user_id ~= user_id or old.erasure_id ~= erasure_id
				or old.status == "completed" or old.status == "resolved"
			then return old end
			local value = copy(old)
			value.completed_count = math.max(value.completed_count or 0, completed)
			value.status = if value.cursor >= #value.entries then "completed" else "in_progress"
			value.completed_at = if value.status == "completed" then os.time() else nil
			value.updated_at = os.time()
			return value
		end)
		if final_error then return { code = "unknown", message = final_error } end
		if type(final) ~= "table" or final.user_id ~= user_id or final.erasure_id ~= erasure_id then
			return { code = "conflict", message = "erasure terminal checkpoint identity changed" }
		end
		return {
			code = if final.status == "completed" then "committed" elseif final.status == "resolved" then "resolved" else "incomplete",
			cursor = final.cursor, completed_count = final.completed_count or completed,
			rtbf_coverage_verified = final.rtbf_coverage_verified == true,
			message = if final.status == "completed" or final.status == "resolved" then nil else "resume in bounded steps",
		}
	end
	function coordinator:GetStatus(user_id)
		local result, message = adapter_call(store, "GetAsync", manifest_key(user_id))
		if message then return { code = "unknown", message = message } end
		if not result then return { code = "not_found" } end
		return copy(result)
	end
	function coordinator:IsErased(user_id)
		local status = self:GetStatus(user_id)
		if type(status) ~= "table" then return nil, { code = "unknown", message = "erasure status returned no record" } end
		if status.code == "not_found" then return false, status end
		if status.code == "unknown" or status.code == "conflict" or status.code == "corrupt" then
			return nil, status
		end
		if status.status == "resolved" then return false, status end
		if status.status == "planned" or status.status == "in_progress" or status.status == "completed" then
			return true, status
		end
		return nil, { code = "unknown", message = "erasure manifest status is unrecognized", observed = status }
	end
	return coordinator
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
	local function projection_event_receipt_status(recent_events, event_id, fingerprint)
		for _, receipt in ipairs(recent_events) do
			if type(receipt) == "table" and receipt.event_id == event_id then
				return if receipt.fingerprint == fingerprint then "duplicate" else "conflict"
			end
			if type(receipt) == "string" and receipt == event_id then
				return "conflict"
			end
		end
		return nil
	end
	local function valid_projection_receipts(recent_events)
		if type(recent_events) ~= "table" or #recent_events > 64 or key_count(recent_events) ~= #recent_events then return false end
		for receipt_key, receipt in pairs(recent_events) do
			if type(receipt_key) ~= "number" or not finite(receipt_key) or math.floor(receipt_key) ~= receipt_key
				or receipt_key < 1 or receipt_key > #recent_events
			then return false end
			if type(receipt) == "string" then
				if not valid_text(receipt, 128) then return false end
			elseif type(receipt) == "table" then
				if not valid_text(receipt.event_id, 128) or not valid_text(receipt.fingerprint, 128) then return false end
			else
				return false
			end
		end
		return true
	end
	function service:ApplyAsync(name, event)
		local def = self.projections[name]
		if not def then return { code = "not_found" } end
		if type(event) ~= "table" or not valid_text(event.event_id, 128) or not valid_text(event.entity_id, 128)
			or not finite(event.source_revision) or event.source_revision < 0 or math.floor(event.source_revision) ~= event.source_revision
		then return { code = "invalid" } end
		local event_ok, event_material = pcall(canonical, event)
		if not event_ok then return { code = "invalid", message = tostring(event_material) } end
		local event_fingerprint = digest(event_material)
		if type(options.is_erased) == "function" then
			if event.subject_user_ids ~= nil and type(event.subject_user_ids) ~= "table" then
				return { code = "invalid", message = "subject_user_ids must be an array" }
			end
			for _, user_id in ipairs(event.subject_user_ids or {}) do
				if not finite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
					return { code = "invalid", message = "subject_user_ids must contain positive integer UserIds" }
				end
				local erased, error_value = io_call(options.is_erased, user_id)
				if erased == true then return { code = "erased" } elseif erased == nil then return { code = "unknown", message = error_value or "erasure state unresolved" } end
			end
		end
		local key, decision = key_for(name, event.entity_id), "unknown"
		local value, write_error = adapter_call(store, "UpdateAsync", key, function(old)
			decision = "unknown"
			if old ~= nil and (type(old) ~= "table" or old.entity_id ~= event.entity_id or old.projection_name ~= name) then
				decision = "conflict"
				return old
			end
			if old ~= nil and old.version ~= def.version then decision = "unsupported_schema"; return old end
			local current = if type(old) == "table" then old else {
				projection_name = name, version = def.version, entity_id = event.entity_id,
				value = {}, source_revision = -1, recent_events = {},
			}
			if type(current.value) ~= "table" or not finite(current.source_revision)
				or current.source_revision < -1 or math.floor(current.source_revision) ~= current.source_revision
				or not valid_projection_receipts(current.recent_events)
			then decision = "corrupt"; return current end
			local receipt_status = projection_event_receipt_status(current.recent_events, event.event_id, event_fingerprint)
			if receipt_status ~= nil then decision = receipt_status; return current end
			if event.source_revision <= current.source_revision then decision = "stale"; return current end
			local next_value = pure(def.projector, copy(current.value), copy(event))
			if type(next_value) ~= "table" then decision = "invalid"; return current end
			local result = copy(current)
			result.value = next_value
			result.source_revision = event.source_revision
			result.updated_at = os.time()
			result.recent_events = copy(current.recent_events)
			table.insert(result.recent_events, { event_id = event.event_id, fingerprint = event_fingerprint })
			while #result.recent_events > 64 do table.remove(result.recent_events, 1) end
			decision = "committed"
			return result
		end)
		if write_error then
			local observed = adapter_call(store, "GetAsync", key)
			if type(observed) == "table" then
				if observed.entity_id ~= event.entity_id or observed.projection_name ~= name then
					return { code = "conflict", message = "projection identity changed after ambiguous update" }
				end
				if observed.version ~= def.version then return { code = "unsupported_schema" } end
				if type(observed.recent_events) == "table" and valid_projection_receipts(observed.recent_events) then
					local receipt_status = projection_event_receipt_status(observed.recent_events, event.event_id, event_fingerprint)
					if receipt_status == "duplicate" then return { code = "committed", row = observed, reconciled = true, consistency = "eventual" } end
					if receipt_status == "conflict" then return { code = "conflict", message = "event ID was durably used for a different request" } end
				end
			end
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
	local function same_canonical(left, right)
		local left_ok, left_text = pcall(canonical, left)
		if not left_ok then return false end
		local right_ok, right_text = pcall(canonical, right)
		return right_ok and left_text == right_text
	end
	local function rebuild_key(name, rebuild_id)
		return "rv2rb-" .. digest(name .. ":" .. rebuild_id)
	end
	function service:GetRebuildStatusAsync(name, rebuild_id)
		if not valid_text(name, 40) or not valid_text(rebuild_id, 128) then return { code = "invalid" } end
		local def = self.projections[name]
		if not def then return { code = "not_found" } end
		local manifest, message = adapter_call(store, "GetAsync", rebuild_key(name, rebuild_id))
		if message then return { code = "unknown", message = message } end
		if manifest == nil then return { code = "not_found", rebuild_id = rebuild_id } end
		if type(manifest) ~= "table" or manifest.rebuild_id ~= rebuild_id or manifest.projection_name ~= name then
			return { code = "conflict", message = "rebuild manifest identity does not match the requested rebuild" }
		end
		if manifest.version ~= def.version then return { code = "unsupported_schema", message = "rebuild projection version differs from the registered projector" } end
		local result = copy(manifest)
		result.code = "success"
		result.consistency = "durable"
		return result
	end
	function service:RebuildDurableAsync(name, rebuild_id, source_snapshot_id, fetch_page, max_pages)
		local def = self.projections[name]
		if not def or not valid_text(rebuild_id, 128) or not valid_text(source_snapshot_id, 128)
			or type(fetch_page) ~= "function"
		then return { code = "invalid", message = "durable rebuild requires a registered projection, stable rebuild/snapshot IDs, and a page adapter" } end
		max_pages = math.clamp(math.floor(max_pages or 4), 1, 64)
		local key = rebuild_key(name, rebuild_id)
		local function matches(manifest)
			return type(manifest) == "table" and manifest.rebuild_id == rebuild_id
				and manifest.projection_name == name and manifest.version == def.version
				and manifest.source_snapshot_id == source_snapshot_id
		end
		local manifest, message = adapter_call(store, "GetAsync", key)
		if message then return { code = "unknown", rebuild_id = rebuild_id, message = message } end
		if manifest == nil then
			local now = os.time()
			local initial = {
				version = def.version, rebuild_id = rebuild_id, projection_name = name,
				source_snapshot_id = source_snapshot_id, status = "in_progress",
				pages = 0, processed = 0, created_at = now, updated_at = now,
			}
			local inserted, insert_error = adapter_call(store, "UpdateAsync", key, function(old)
				if old ~= nil then return old end
				return copy(initial)
			end)
			if insert_error then
				manifest, message = adapter_call(store, "GetAsync", key)
				if message or not matches(manifest) then return { code = "unknown", rebuild_id = rebuild_id, message = insert_error } end
			elseif type(inserted) == "table" then
				manifest = inserted
			else
				return { code = "unknown", rebuild_id = rebuild_id, message = "initial rebuild manifest was not returned" }
			end
		end
		if type(manifest) ~= "table" or manifest.rebuild_id ~= rebuild_id or manifest.projection_name ~= name then
			return { code = "conflict", rebuild_id = rebuild_id, message = "another rebuild owns the durable manifest key" }
		end
		if manifest.version ~= def.version then return { code = "unsupported_schema", rebuild_id = rebuild_id } end
		if manifest.source_snapshot_id ~= source_snapshot_id then
			return { code = "conflict", rebuild_id = rebuild_id, message = "a rebuild ID cannot be reused for another source snapshot" }
		end
		local function result(code, detail)
			local value = {
				code = code, rebuild_id = rebuild_id, projection_name = name, version = def.version,
				source_snapshot_id = source_snapshot_id, status = manifest.status,
				pages = manifest.pages or 0, processed = manifest.processed or 0,
				complete = manifest.status == "completed", consistency = "durable",
			}
			if manifest.cursor ~= nil then value.cursor = copy(manifest.cursor) end
			if detail ~= nil then value.message = detail end
			return value
		end
		if manifest.status == "completed" then return result("committed") end
		if manifest.status ~= "in_progress" and manifest.status ~= "unknown" and manifest.status ~= "blocked" then
			return result("corrupt", "durable rebuild status is unrecognized")
		end
		local function replace_manifest(expected, candidate)
			local updated, update_error = adapter_call(store, "UpdateAsync", key, function(old)
				if same_canonical(old, expected) then return copy(candidate) end
				return old
			end)
			if update_error then
				local observed, read_error = adapter_call(store, "GetAsync", key)
				if not read_error and same_canonical(observed, candidate) then return copy(observed), nil end
				return nil, "unknown", update_error
			end
			if same_canonical(updated, candidate) then return copy(updated), nil end
			return nil, "conflict", updated
		end
		local function stop_with_status(outcome, status, detail)
			local candidate = copy(manifest)
			candidate.status = status
			candidate.last_error = text_error(detail, 256)
			candidate.updated_at = os.time()
			local updated, update_code, update_message = replace_manifest(manifest, candidate)
			if not updated then
				return result("unknown", update_message or "failed to checkpoint rebuild status: " .. tostring(update_code))
			end
			manifest = updated
			return result(outcome, detail)
		end
		for _ = 1, max_pages do
			local page, next_cursor, complete, observed_snapshot = io_call(fetch_page, manifest.cursor, 64, source_snapshot_id)
			if type(page) ~= "table" then
				return stop_with_status("unknown", "unknown", tostring(next_cursor or "source page read failed"))
			end
			if observed_snapshot ~= source_snapshot_id then
				return stop_with_status("conflict", "blocked", "source page does not belong to the pinned snapshot")
			end
			if type(complete) ~= "boolean" or #page > 64 or key_count(page) ~= #page then
				return stop_with_status("invalid", "blocked", "source page must be a dense array of at most 64 events with a completion flag")
			end
			for page_key in pairs(page) do
				if type(page_key) ~= "number" or not finite(page_key) or math.floor(page_key) ~= page_key or page_key < 1 or page_key > #page then
					return stop_with_status("invalid", "blocked", "source page is not a dense numeric array")
				end
			end
			if complete == true and next_cursor ~= nil then
				return stop_with_status("invalid", "blocked", "complete source page must not return a next cursor")
			end
			if complete == false and next_cursor == nil then
				return stop_with_status("invalid", "blocked", "incomplete source page must return a next cursor")
			end
			local cursor_ok, next_cursor_text = pcall(canonical, next_cursor)
			if not cursor_ok then return stop_with_status("invalid", "blocked", "source cursor is not canonicalizable") end
			local prior_ok, prior_cursor_text = pcall(canonical, manifest.cursor)
			if not prior_ok then return stop_with_status("corrupt", "blocked", "durable rebuild cursor is malformed") end
			if complete == false and next_cursor_text == prior_cursor_text then
				return stop_with_status("blocked", "blocked", "source cursor made no progress")
			end
			for _, event in ipairs(page) do
				local applied = self:ApplyAsync(name, event)
				if applied.code ~= "committed" and applied.code ~= "duplicate" and applied.code ~= "stale" then
					return stop_with_status(applied.code, if applied.code == "unknown" then "unknown" else "blocked", applied.message or ("projection event returned " .. tostring(applied.code)))
				end
			end
			local candidate = copy(manifest)
			candidate.cursor = next_cursor
			candidate.pages = (manifest.pages or 0) + 1
			candidate.processed = (manifest.processed or 0) + #page
			candidate.status = if complete then "completed" else "in_progress"
			candidate.last_error = nil
			candidate.updated_at = os.time()
			local updated, update_code, update_message = replace_manifest(manifest, candidate)
			if not updated then
				return result(if update_code == "conflict" then "conflict" else "unknown", update_message or "source page applied; durable rebuild cursor is unresolved")
			end
			manifest = updated
			if manifest.status == "completed" then return result("committed") end
		end
		return result("incomplete")
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

local function canonical_request(value)
	local ok, result = pcall(canonical, value)
	return if ok then result else nil
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
			local before_cursor = self.cursor
			local function checkpoint(status, cursor)
				local persisted, persist_error = io_call(config.persist_progress, cursor, self.processed, self.removed, status)
				if persisted ~= true then
					self.status = "unknown"
					self.last_error = persist_error
					return false, persist_error
				end
				return true, nil
			end
			local items, next_cursor, complete = io_call(config.next_page, before_cursor, max_items)
			if type(items) ~= "table" then
				self.status = "unknown"
				self.last_error = "page adapter returned no item list"
				checkpoint(self.status, before_cursor)
				return { code = "unknown", cursor = before_cursor, message = self.last_error }
			end
			if #items > max_items then
				return { code = "capacity", cursor = before_cursor, message = "page adapter exceeded the requested item bound" }
			end
			self.status = "running"
			for _, item in ipairs(items) do
				if os.clock() * 1000 - start >= budget_ms then self.status = "paused"; break end
				local inspected, inspect_error = io_call(config.inspect, item)
				if type(inspected) ~= "table" or inspected.status == "unknown" then
					self.status = "unknown"
					self.last_error = inspect_error or "inspection unresolved"
					checkpoint(self.status, before_cursor)
					return { code = "unknown", cursor = before_cursor, message = self.last_error }
				end
				if inspected.eligible == true and inspected.dependencies_clear == true then
					local action, action_error = io_call(config.delete_if_generation, item, inspected.generation)
					if action == "unknown" then
						self.status = "unknown"
						self.last_error = action_error or "delete unresolved"
						checkpoint(self.status, before_cursor)
						return { code = "unknown", cursor = before_cursor, message = self.last_error }
					end
					if action == "deleted" then self.removed += 1 end
				end
				self.processed += 1
			end
			if self.status ~= "paused" then
				self.cursor = next_cursor
				self.status = if complete == true or next_cursor == nil then "completed" else "incomplete"
			end
			local persisted, persist_error = checkpoint(self.status, self.cursor)
			if not persisted then return { code = "unknown", cursor = before_cursor, message = persist_error or "checkpoint unresolved" } end
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
	local runtime_governor = shared_runtime_governor(record_store, options.runtime)
	local runtime_policy = { revision = 1, max_dirty_age_seconds = 60, mode = "normal" }
	local scheduler_policy_fields = {
		mode = true, max_in_flight = true, critical_reserve = true, queue_capacity = true,
		max_batch = true, batch_window_ms = true, batch_latency_ceiling_ms = true, high_burst = true,
		retry_token_capacity = true, retry_tokens_per_second = true, minimum_budget = true,
		circuit_threshold = true, circuit_cooldown_ms = true, max_scheduled_in_flight = true,
		scheduler_critical_reserve = true, max_per_owner_in_flight = true,
		max_read_units_in_flight = true, max_write_units_in_flight = true, read_critical_reserve = true,
		write_critical_reserve = true, max_estimated_bytes_in_flight = true, max_handler_slots_in_flight = true,
		estimated_bytes_critical_reserve = true, handler_slots_critical_reserve = true,
		drr_quantum = true, max_item_cost = true, urgent_deadline_burst = true,
		priority_inheritance_max_ms = true, retry_jitter_percent = true, algorithm = true,
		shadow_algorithm = true, shadow_enabled = true, shadow_sample_rate = true,
	}
	local api = {
		Version = 2,
		DeliveryGuarantee = "at-least-once",
		OrderingContract = "strict ordering_key is not enabled; priority is a hint among eligible messages",
		Canonicalize = canonical,
		Fingerprint = function(value)
			local ok, material = pcall(canonical, value)
			return if ok then digest(material) else nil
		end,
		Mailbox = {
			new = function(store, owner, mailbox_options)
				local merged_options = {}
				if mailbox_options ~= nil then
					if type(mailbox_options) ~= "table" then error("mailbox_options must be a table", 2) end
					merged_options = table.clone(mailbox_options)
				end
				if merged_options.encode == nil then
					merged_options.encode = function(value) return game:GetService("HttpService"):JSONEncode(value) end
				end
				if merged_options.activation_guard == nil and merged_options.allow_unattested_activation ~= true then
					local guard = options.mailbox_activation_guard
					if type(guard) == "function" then
						merged_options.activation_guard = function(operation)
							return guard(merged_options.active_record, operation)
						end
				else
						merged_options.activation_guard = function()
							return false, "Mailbox V2 activation requires an application-supplied guard"
						end
					end
				end
				if options.allow_unattested_activation == true then merged_options.allow_unattested_activation = true end
				return mailbox_module.new(store, owner, merged_options)
			end,
		},
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
		if type(policy) ~= "table" or not finite(policy.revision)
			or math.floor(policy.revision) ~= policy.revision or policy.revision <= runtime_policy.revision
		then
			return "invalid", "runtime policy revision must be a higher positive integer"
		end
		for key in pairs(policy) do
			if key ~= "revision" and key ~= "max_dirty_age_seconds" and not scheduler_policy_fields[key] then
				return "invalid", "unsupported runtime policy field: " .. tostring(key)
			end
		end
		if policy.max_dirty_age_seconds ~= nil and (not finite(policy.max_dirty_age_seconds)
			or policy.max_dirty_age_seconds < 1 or policy.max_dirty_age_seconds > 86400)
		then
			return "invalid", "max_dirty_age_seconds must be finite seconds in [1, 86400]"
		end
		local scheduler_patch = {}
		for key, value in pairs(policy) do
			if scheduler_policy_fields[key] then scheduler_patch[key] = value end
		end
		if next(scheduler_patch) ~= nil then
			if type(record_store.configure_scheduler_policy) ~= "function" then
				return "unsupported", "core RecordStore scheduler policy API is unavailable"
			end
			scheduler_patch.revision = policy.revision
			local status, message = record_store.configure_scheduler_policy(scheduler_patch)
			if status ~= "success" then return status, message end
		end
		local next_policy = copy(runtime_policy)
		next_policy.revision = policy.revision
		if policy.max_dirty_age_seconds ~= nil then next_policy.max_dirty_age_seconds = policy.max_dirty_age_seconds end
		if policy.mode ~= nil then next_policy.mode = policy.mode end
		runtime_policy = next_policy
		return "success", nil
	end
	api.ApplySchedulerPolicy = function(policy)
		if type(policy) ~= "table" then return "invalid", "scheduler policy must be a table" end
		if type(record_store.configure_scheduler_policy) == "function" then
			return record_store.configure_scheduler_policy(policy)
		end
		local applied, message = runtime_governor:SetPolicy(policy)
		return if applied then "success" else "invalid", message
	end
	api.GetRuntimeSnapshot = function()
		local scheduler, scheduler_error = nil, nil
		if type(record_store.get_scheduler_snapshot) == "function" then
			local ok, value = pcall(record_store.get_scheduler_snapshot)
			if ok then scheduler = value else scheduler_error = tostring(value) end
		elseif type(record_store.get_runtime_stats) == "function" then
			local ok, value = pcall(record_store.get_runtime_stats)
			if ok then scheduler = value else scheduler_error = tostring(value) end
		end
		local health = nil
		if type(record_store.get_health_snapshot) == "function" then
			local ok, value = pcall(record_store.get_health_snapshot)
			if ok then health = value end
		end
		return {
			policy = copy(runtime_policy),
			scheduler = scheduler,
			health = health,
			local_governor = runtime_governor:Stats(),
			scheduler_error = scheduler_error,
			integration_mode = if type(record_store.configure_scheduler_policy) == "function"
				then "core_scheduler_policy" else "standalone_advisory_governor",
			request_gate_hooks_registered = false,
		}
	end
	api.GetDurabilitySLO = function(record, threshold)
		return runtime_governor:GetDurabilitySLO(record, threshold or runtime_policy.max_dirty_age_seconds)
	end
	api.GetContentionDiagnostics = function(record)
		return runtime_governor:GetContentionDiagnostics(record)
	end
	api.ShouldSave = function(record) return new_maintenance().ShouldSave(record_stats(record)) end
	api.RenderErasureTemplate = render_template
	api.Acceleration = options.acceleration_module
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
		local limit = math.clamp(math.floor(max_messages_per_wake or 4), 1, 32)
		local bound, bind_error = mailbox:BindWakeups(accelerator)
		if not bound then return false, bind_error end
		return accelerator:Register(owner_text, function()
			for _ = 1, limit do
				local result = mailbox:ProcessNextAsync(handler)
				if type(result) ~= "table" or result.code ~= "processed" then break end
			end
		end)
	end
	return api
end

V2.canonical = canonical
V2.fingerprint = function(value) local ok, material = pcall(canonical, value); return if ok then digest(material) else nil end
return V2
