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

local operation_dimension_defaults = {
	default = { read = 1, write = 1, bytes = 16384, handlers = 1 },
	read = { read = 1, write = 0, bytes = 16384, handlers = 1 },
	update_async = { read = 1, write = 1, bytes = 16384, handlers = 1 },
	mailbox_claim = { read = 1, write = 1, bytes = 16384, handlers = 1 },
	lease_renewal = { read = 1, write = 1, bytes = 16384, handlers = 1 },
	outbox_dispatch = { read = 1, write = 1, bytes = 16384, handlers = 1 },
	maintenance = { read = 1, write = 1, bytes = 8192, handlers = 1 },
	migration = { read = 1, write = 1, bytes = 16384, handlers = 1 },
	projection = { read = 1, write = 1, bytes = 8192, handlers = 1 },
	tracing = { read = 0, write = 0, bytes = 1024, handlers = 1 },
	batch = { read = 1, write = 1, bytes = 65536, handlers = 1 },
}

local function estimate_dimensions(item, batch_count)
	local request_kind = if type(item.operation_class) == "string" then item.operation_class
		elseif type(item.work_class) == "string" then item.work_class else "default"
	local defaults = operation_dimension_defaults[request_kind] or operation_dimension_defaults.default
	local multiplier = if item.batchable == true and finite(batch_count)
		then math.clamp(math.floor(batch_count), 1, 16) else 1
	return {
		read_units = math.max(defaults.read, if finite(item.read_units) then item.read_units else 0) * multiplier,
		write_units = math.max(defaults.write, if finite(item.write_units) then item.write_units else 0) * multiplier,
		estimated_bytes = math.max(defaults.bytes, if finite(item.estimated_bytes) then item.estimated_bytes else 0) * multiplier,
		handler_slots = math.max(defaults.handlers, if finite(item.handler_slots) then item.handler_slots else 1),
	}
end

local MAX_CUSTOM_OPERATION_KIND_KEYS = 19
local OTHER_OPERATION_KIND = "__other__"
local CORE_OPERATION_KINDS = {
	default = true, read = true, update_async = true, mailbox_claim = true,
	lease_renewal = true, outbox_dispatch = true, maintenance = true,
	migration = true, projection = true, tracing = true, batch = true,
}

local function new_governor(options)
	options = options or {}
	local function now_ms()
		return if type(options.now_ms) == "function" then options.now_ms() else os.clock() * 1000
	end
	local function operation_metric_key(self, kind)
		if type(kind) ~= "string" or kind == "" then kind = "default" end
		-- Keep built-in persistence operations isolated. Internal-only labels cannot be
		-- claimed by custom work, because "service" tracks global latency and "__other__" aggregates overflow.
		if CORE_OPERATION_KINDS[kind] then return kind end
		if kind == OTHER_OPERATION_KIND or kind == "service" then return OTHER_OPERATION_KIND end
		local existing = self.operation_kind_keys[kind]
		if existing ~= nil then return existing end
		if key_count(self.operation_kind_keys) < MAX_CUSTOM_OPERATION_KIND_KEYS then
			self.operation_kind_keys[kind] = kind
			return kind
		end
		return OTHER_OPERATION_KIND
	end
	local governor = {
		policy = {
			revision = 1, mode = "normal", max_in_flight = 32, critical_reserve = 4,
			queue_capacity = 1024, max_batch = 16, batch_window_ms = 5,
			batch_latency_ceiling_ms = 40, high_burst = 4, retry_token_capacity = 32,
			retry_tokens_per_second = 4, minimum_budget = 2, circuit_threshold = 5, circuit_cooldown_ms = 15000,
			max_scheduled_in_flight = 8, scheduler_critical_reserve = 1, max_per_owner_in_flight = 2,
			max_read_units_in_flight = 32, max_write_units_in_flight = 32,
			read_critical_reserve = 4, write_critical_reserve = 4,
			max_estimated_bytes_in_flight = 16777216, max_handler_slots_in_flight = 16,
			drr_quantum = 4, max_item_cost = 64, urgent_deadline_burst = 4,
			priority_inheritance_max_ms = 1000, retry_jitter_percent = 20,
			algorithm = "drr", shadow_algorithm = "weighted", shadow_enabled = false, shadow_sample_rate = 0,
		},
		in_flight = 0, by_class = {}, active_tickets = {}, queue = {}, due = {}, due_heap = {}, queued_due_heap = {},
		read_units_in_flight = 0, write_units_in_flight = 0,
		estimated_bytes_in_flight = 0, handler_slots_in_flight = 0,
		request_budgets = { read = nil, write = nil, sampled_at_ms = nil },
		completed = {}, completed_order = {}, known = {}, active_owner = {}, active_renewals_by_owner = {},
		drr_deficit = {}, drr_cursor_key = nil, high_streak = 0, urgent_streak = 0,
		failed = {}, failed_order = {}, retry_cooldown_until = {}, retry_tokens_by_class = {},
		due_sequence = 0,
		retry_tokens = 32, last_token_time = now_ms(),
		last_budget = nil, last_budget_by_kind = {}, latency_ewma = {}, latency_samples_by_operation = {},
		operation_kind_keys = {}, consecutive_errors = {}, circuits = {},
		stats = { admitted = 0, rejected = 0, completed = 0, released = 0, throttled = 0, errors = 0,
			scheduled_selected = 0, scheduled_expired = 0, scheduled_overdue = 0, shadow_samples = 0 },
		scheduler_metrics = { by_lane = {}, wait_ms = {}, wait_by_lane_class = {}, last_shadow = nil },
	}
	local limits = { critical = 32, profile_save = 32, profile_release = 32, interactive = 24, messaging = 20, migration = 4, maintenance = 8, tracing = 1 }
	local function policy_valid(policy)
		if type(policy) ~= "table" then return false, "policy must be a table" end
		local fields = {
			"revision", "max_in_flight", "critical_reserve", "queue_capacity", "max_batch",
			"batch_window_ms", "batch_latency_ceiling_ms", "high_burst", "retry_token_capacity",
			"retry_tokens_per_second", "minimum_budget", "circuit_threshold", "circuit_cooldown_ms",
			"max_scheduled_in_flight", "scheduler_critical_reserve", "max_per_owner_in_flight",
			"max_read_units_in_flight", "max_write_units_in_flight", "read_critical_reserve",
			"write_critical_reserve", "max_estimated_bytes_in_flight", "max_handler_slots_in_flight",
			"drr_quantum", "max_item_cost", "urgent_deadline_burst", "priority_inheritance_max_ms",
			"retry_jitter_percent", "shadow_sample_rate"
		}
		for _, field in ipairs(fields) do if not finite(policy[field]) then return false, "policy." .. field .. " must be finite" end end
		if policy.mode ~= "normal" and policy.mode ~= "reject_noncritical" and policy.mode ~= "read_only" then return false, "invalid degraded mode" end
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
		for _, field in ipairs({ "max_read_units_in_flight", "max_write_units_in_flight", "max_handler_slots_in_flight" }) do
			if policy[field] < 1 or policy[field] > 256 or math.floor(policy[field]) ~= policy[field] then
				return false, field .. " must be an integer from 1 to 256"
			end
		end
		for _, pair in ipairs({
			{ "read_critical_reserve", "max_read_units_in_flight" },
			{ "write_critical_reserve", "max_write_units_in_flight" },
		}) do
			local reserve, maximum = policy[pair[1]], policy[pair[2]]
			if reserve < 0 or reserve >= maximum or math.floor(reserve) ~= reserve then
				return false, pair[1] .. " must be an integer below " .. pair[2]
			end
		end
		if policy.max_estimated_bytes_in_flight < 16384 or policy.max_estimated_bytes_in_flight > 67108864
			or math.floor(policy.max_estimated_bytes_in_flight) ~= policy.max_estimated_bytes_in_flight
		then
			return false, "max_estimated_bytes_in_flight must be an integer from 16384 to 67108864"
		end
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
			max_read_units_in_flight = true, max_write_units_in_flight = true,
			read_critical_reserve = true, write_critical_reserve = true,
			max_estimated_bytes_in_flight = true, max_handler_slots_in_flight = true,
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
		local metric_kind = operation_metric_key(self, kind)
		if finite(latency_ms) and latency_ms >= 0 then
			local prior = self.latency_ewma[metric_kind]
			self.latency_ewma[metric_kind] = prior and prior * 0.8 + latency_ms * 0.2 or latency_ms
			local samples = self.latency_samples_by_operation[metric_kind]
			if samples == nil then
				samples = {}
				self.latency_samples_by_operation[metric_kind] = samples
			end
			samples[#samples + 1] = latency_ms
			if #samples > 256 then table.remove(samples, 1) end
		end
		if finite(budget) then
			self.last_budget = budget
			self.last_budget_by_kind[metric_kind] = budget
		end
		if ok then
			self.consecutive_errors[metric_kind] = 0
			if self.circuits[metric_kind] and self.circuits[metric_kind].state == "half_open" then
				self.circuits[metric_kind] = { state = "closed" }
			end
		else
			self.stats.errors += 1
			self.consecutive_errors[metric_kind] = (self.consecutive_errors[metric_kind] or 0) + 1
			if error_class == "throttled" or error_class == "budget" then self.stats.throttled += 1 end
			if self.consecutive_errors[metric_kind] >= self.policy.circuit_threshold then
				self.circuits[metric_kind] = {
					state = "open", until_ms = now_ms() + self.policy.circuit_cooldown_ms,
					reason = error_class or "repeated_failure",
				}
			end
		end
		return true
	end
	local function admission_decision(self, work_class, request_kind, cost, mutating, critical_override, dimensions)
		work_class, request_kind, cost = work_class or "interactive", request_kind or "default", cost or 1
		request_kind = operation_metric_key(self, request_kind)
		if not finite(cost) or math.floor(cost) ~= cost or cost < 1 then
			return { code = "invalid", terminal = true }, false, false
		end
		dimensions = dimensions or estimate_dimensions({ operation_class = request_kind })
		local read_units, write_units = dimensions.read_units or 0, dimensions.write_units or 0
		local estimated_bytes, handler_slots = dimensions.estimated_bytes or 0, dimensions.handler_slots or 1
		if not finite(read_units) or read_units < 0 or not finite(write_units) or write_units < 0
			or not finite(estimated_bytes) or estimated_bytes < 0 or not finite(handler_slots) or handler_slots < 1
		then
			return { code = "invalid", terminal = true, message = "invalid multi-dimensional admission estimate" }, false, false
		end
		if read_units > self.policy.max_read_units_in_flight then
			return { code = "capacity", terminal = true, message = "work item exceeds the StandardRead admission cap" }, false, true
		end
		if write_units > self.policy.max_write_units_in_flight then
			return { code = "capacity", terminal = true, message = "work item exceeds the StandardWrite admission cap" }, false, true
		end
		if estimated_bytes > self.policy.max_estimated_bytes_in_flight then
			return { code = "capacity", terminal = true, message = "work item exceeds the estimated byte admission cap" }, false, true
		end
		if handler_slots > self.policy.max_handler_slots_in_flight then
			return { code = "capacity", terminal = true, message = "work item exceeds the handler-slot admission cap" }, false, true
		end
		local critical = critical_override == true or work_class == "critical"
			or work_class == "profile_save" or work_class == "profile_release"
		local class_limit = math.min(limits[work_class] or limits.interactive, self.policy.max_in_flight)
		if cost > self.policy.max_in_flight then
			return { code = "capacity", terminal = true, message = "work item cost exceeds max_in_flight" }, false, true
		end
		if cost > class_limit then
			return { code = "capacity", terminal = true, message = "work item cost exceeds its work-class admission cap" }, false, true
		end
		if self.policy.mode == "read_only" and mutating and not critical then
			return { code = "read_only", terminal = true, message = "mutating noncritical work is disabled" }, false, true
		end
		if self.policy.mode == "reject_noncritical" and not critical then
			return { code = "backpressure", terminal = true, message = "scheduler policy rejects noncritical work" }, false, true
		end
		local circuit = self.circuits[request_kind]
		local probe_needed = false
		if circuit and circuit.state == "open" then
			local wait_ms = circuit.until_ms - now_ms()
			if wait_ms > 0 then
				return { code = "circuit_open", transient = true, retry_after_ms = wait_ms, reason = circuit.reason }, false, false
			end
			probe_needed = true
		elseif circuit and circuit.state == "half_open" then
			if circuit.probe then
				return { code = "circuit_open", transient = true, retry_after_ms = 100, reason = "half-open probe already reserved" }, false, false
			end
			probe_needed = true
		end
		local observed_budget = self.last_budget_by_kind[request_kind]
		if finite(observed_budget) and observed_budget < self.policy.minimum_budget and not critical then
			return { code = "backpressure", transient = true, budget_limited = true, retry_after_ms = 250,
				message = "operation budget is below configured minimum" }, false, true
		end
		local budgets = self.request_budgets
		local budget_fresh = finite(budgets.sampled_at_ms) and now_ms() - budgets.sampled_at_ms <= 1000
		if budget_fresh then
			-- Critical work can use reserved local scheduler capacity below the normal
			-- headroom target, but cannot bypass an exhausted Roblox request budget.
			local read_threshold = if critical then read_units else math.max(self.policy.minimum_budget, read_units)
			local write_threshold = if critical then write_units else math.max(self.policy.minimum_budget, write_units)
			if read_units > 0 and finite(budgets.read) and budgets.read < read_threshold then
				return { code = "backpressure", transient = true, budget_limited = true, retry_after_ms = 250,
					message = "StandardRead budget is below the operation admission threshold" }, false, true
			end
			if write_units > 0 and finite(budgets.write) and budgets.write < write_threshold then
				return { code = "backpressure", transient = true, budget_limited = true, retry_after_ms = 250,
					message = "StandardWrite budget is below the operation admission threshold" }, false, true
			end
		end
		if self.in_flight + cost > self.policy.max_in_flight then
			return { code = "capacity", transient = true, message = "global estimated-work capacity reached" }, false, true
		end
		if not critical and self.in_flight + cost > self.policy.max_in_flight - self.policy.critical_reserve then
			return { code = "backpressure", transient = true, message = "critical persistence reserve protected" }, false, true
		end
		if self.read_units_in_flight + read_units > self.policy.max_read_units_in_flight then
			return { code = "capacity", transient = true, message = "StandardRead admission capacity reached" }, false, true
		end
		if not critical and self.read_units_in_flight + read_units > self.policy.max_read_units_in_flight - self.policy.read_critical_reserve then
			return { code = "backpressure", transient = true, message = "critical StandardRead reserve protected" }, false, true
		end
		if self.write_units_in_flight + write_units > self.policy.max_write_units_in_flight then
			return { code = "capacity", transient = true, message = "StandardWrite admission capacity reached" }, false, true
		end
		if not critical and self.write_units_in_flight + write_units > self.policy.max_write_units_in_flight - self.policy.write_critical_reserve then
			return { code = "backpressure", transient = true, message = "critical StandardWrite reserve protected" }, false, true
		end
		if self.estimated_bytes_in_flight + estimated_bytes > self.policy.max_estimated_bytes_in_flight then
			return { code = "capacity", transient = true, message = "estimated in-flight byte capacity reached" }, false, true
		end
		if self.handler_slots_in_flight + handler_slots > self.policy.max_handler_slots_in_flight then
			return { code = "capacity", transient = true, message = "handler-slot admission capacity reached" }, false, true
		end
		if (self.by_class[work_class] or 0) + cost > math.min(limits[work_class] or limits.interactive, self.policy.max_in_flight) then
			return { code = "capacity", transient = true, message = "work-class cap reached" }, false, true
		end
		return {
			code = "admitted", work_class = work_class, request_kind = request_kind,
			cost = cost, critical = critical, dimensions = dimensions,
		}, probe_needed, false
	end
	function governor:CanAdmit(work_class, request_kind, cost, mutating, critical_override, dimensions)
		local decision = admission_decision(self, work_class, request_kind, cost, mutating, critical_override, dimensions)
		return decision
	end
	function governor:Admit(work_class, request_kind, cost, mutating, critical_override, dimensions)
		local decision, probe_needed, counted_rejection =
			admission_decision(self, work_class, request_kind, cost, mutating, critical_override, dimensions)
		if decision.code ~= "admitted" then
			if counted_rejection then self.stats.rejected += 1 end
			return decision
		end
		local circuit = self.circuits[decision.request_kind]
		if probe_needed and circuit ~= nil then
			circuit.state = "half_open"
			circuit.probe = true
		end
		self.in_flight += decision.cost
		self.by_class[decision.work_class] = (self.by_class[decision.work_class] or 0) + decision.cost
		local dimensions_value = decision.dimensions
		self.read_units_in_flight += dimensions_value.read_units
		self.write_units_in_flight += dimensions_value.write_units
		self.estimated_bytes_in_flight += dimensions_value.estimated_bytes
		self.handler_slots_in_flight += dimensions_value.handler_slots
		self.stats.admitted += 1
		local ticket_id = tostring(self.policy.revision) .. ":" .. tostring(self.stats.admitted)
		local reservation = {
			ticket = ticket_id,
			cost = decision.cost,
			work_class = decision.work_class,
			request_kind = decision.request_kind,
			read_units = dimensions_value.read_units,
			write_units = dimensions_value.write_units,
			estimated_bytes = dimensions_value.estimated_bytes,
			handler_slots = dimensions_value.handler_slots,
			probe = probe_needed,
		}
		self.active_tickets[ticket_id] = reservation
		local returned = table.clone(reservation)
		returned.code = "admitted"
		return returned
	end
	function governor:Release(ticket)
		if type(ticket) ~= "table" or ticket.code ~= "admitted" or type(ticket.ticket) ~= "string" then
			return false
		end
		local reservation = self.active_tickets[ticket.ticket]
		if reservation == nil then return false end
		self.active_tickets[ticket.ticket] = nil
		self.in_flight = math.max(0, self.in_flight - reservation.cost)
		local remaining_class_cost = math.max(0, (self.by_class[reservation.work_class] or 0) - reservation.cost)
		if remaining_class_cost == 0 then
			self.by_class[reservation.work_class] = nil
		else
			self.by_class[reservation.work_class] = remaining_class_cost
		end
		self.read_units_in_flight = math.max(0, self.read_units_in_flight - reservation.read_units)
		self.write_units_in_flight = math.max(0, self.write_units_in_flight - reservation.write_units)
		self.estimated_bytes_in_flight = math.max(0, self.estimated_bytes_in_flight - reservation.estimated_bytes)
		self.handler_slots_in_flight = math.max(0, self.handler_slots_in_flight - reservation.handler_slots)
		local circuit = self.circuits[reservation.request_kind]
		if reservation.probe == true and circuit ~= nil and circuit.state == "half_open" and circuit.probe == true then
			circuit.probe = false
		end
		self.stats.released += 1
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
	function governor:ObserveRequestBudgets(read_budget, write_budget)
		if not finite(read_budget) or read_budget < 0 or not finite(write_budget) or write_budget < 0 then
			return false
		end
		self.request_budgets = { read = read_budget, write = write_budget, sampled_at_ms = now_ms() }
		return true
	end
	function governor:RefreshRequestBudgets()
		if type(options.get_request_budgets) ~= "function" then return false end
		local ok, budgets = pcall(options.get_request_budgets)
		if not ok or type(budgets) ~= "table" then return false end
		return self:ObserveRequestBudgets(budgets.read, budgets.write)
	end
	local function calculate_batch_size(policy, requested, latency_ms, backlog, oldest_age_ms, budget_headroom)
		local maximum = math.min(bounded_integer(requested, policy.max_batch, 1, 16), policy.max_batch)
		if finite(backlog) then
			maximum = math.min(maximum, bounded_integer(backlog, 1, 1, policy.queue_capacity))
		end
		latency_ms = if finite(latency_ms) then latency_ms else 0
		if finite(budget_headroom) and budget_headroom < policy.minimum_budget then return 1 end
		if latency_ms >= policy.batch_latency_ceiling_ms then return 1 end
		if latency_ms >= policy.batch_latency_ceiling_ms * 0.75 then
			maximum = math.max(1, math.floor(maximum / 2))
		end
		if finite(oldest_age_ms) and oldest_age_ms >= policy.batch_window_ms then
			return maximum
		end
		return maximum
	end
	function governor:ChooseBatchSize(requested, latency_ms, backlog, oldest_age_ms, budget_headroom)
		return calculate_batch_size(self.policy, requested, latency_ms, backlog, oldest_age_ms, budget_headroom)
	end
	local function selected_batch_size(self, item)
		if item.batchable ~= true then return nil end
		local now = now_ms()
		local operation_kind = operation_metric_key(self, item.operation_class or "default")
		local latency = math.max(
			self.latency_ewma[operation_kind] or 0,
			self.latency_ewma.service or 0
		)
		local budgets = self.request_budgets
		local budget_headroom
		local budget_fresh = finite(budgets.sampled_at_ms) and now - budgets.sampled_at_ms <= 1000
		if budget_fresh then
			budget_headroom = math.min(budgets.read or math.huge, budgets.write or math.huge)
		end
		local oldest_age = math.max(0, now - (item.enqueued_at_ms or now))
		local requested = item.batch_size or 1
		local backlog = item.batch_backlog or requested
		local count = calculate_batch_size(self.policy, requested, latency, backlog, oldest_age, budget_headroom)
		local unit = estimate_dimensions(item, 1)
		local critical = item.service_class == "critical" or item.lane == "lease_renewal"
		local read_limit = self.policy.max_read_units_in_flight - self.read_units_in_flight
		local write_limit = self.policy.max_write_units_in_flight - self.write_units_in_flight
		local byte_limit = self.policy.max_estimated_bytes_in_flight - self.estimated_bytes_in_flight
		local unit_cost = math.max(1, unit.read_units + unit.write_units, math.ceil(unit.estimated_bytes / 16384),
			if finite(item.requested_cost) then item.requested_cost else 0)
		local global_cost_room = self.policy.max_in_flight - self.in_flight
		local class_limit = math.min(limits[item.work_class] or limits.interactive, self.policy.max_in_flight)
		local class_cost_room = class_limit - (self.by_class[item.work_class] or 0)
		if not critical then
			read_limit -= self.policy.read_critical_reserve
			write_limit -= self.policy.write_critical_reserve
		end
		if unit.read_units > 0 then count = math.min(count, math.max(1, math.floor(math.max(0, read_limit) / unit.read_units))) end
		if unit.write_units > 0 then count = math.min(count, math.max(1, math.floor(math.max(0, write_limit) / unit.write_units))) end
		if unit.estimated_bytes > 0 then count = math.min(count, math.max(1, math.floor(math.max(0, byte_limit) / unit.estimated_bytes))) end
		if not critical then global_cost_room -= self.policy.critical_reserve end
		count = math.min(count, math.max(1, math.floor(math.max(0, global_cost_room) / unit_cost)))
		count = math.min(count, math.max(1, math.floor(math.max(0, class_cost_room) / unit_cost)))
		if budget_fresh and not critical then
			if unit.read_units > 0 and finite(budgets.read) then
				count = math.min(count, math.max(1, math.floor(math.max(0, budgets.read) / unit.read_units)))
			end
			if unit.write_units > 0 and finite(budgets.write) then
				count = math.min(count, math.max(1, math.floor(math.max(0, budgets.write) / unit.write_units)))
			end
		end
		return math.clamp(math.floor(count), 1, self.policy.max_batch)
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
	local function record_wait_sample(self, item, age_ms)
		local lane = item.lane or "normal"
		local work_class = item.work_class or "default"
		local service_class = item.service_class or "best_effort"
		local key = tostring(#lane) .. ":" .. lane
			.. tostring(#work_class) .. ":" .. work_class
			.. tostring(#service_class) .. ":" .. service_class
		local buckets = self.scheduler_metrics.wait_by_lane_class
		local bucket = buckets[key]
		if bucket == nil then
			local bucket_count = key_count(buckets)
			if bucket_count >= 64 then
				key = "__other__"
				bucket = buckets[key]
				if bucket == nil then
					bucket = { lane = "other", work_class = "other", service_class = "other",
						selected = 0, total_wait_ms = 0, max_wait_ms = 0, samples = {} }
					buckets[key] = bucket
				end
			else
				bucket = { lane = lane, work_class = work_class, service_class = service_class,
					selected = 0, total_wait_ms = 0, max_wait_ms = 0, samples = {} }
				buckets[key] = bucket
			end
		end
		bucket.selected += 1
		bucket.total_wait_ms += age_ms
		bucket.max_wait_ms = math.max(bucket.max_wait_ms, age_ms)
		bucket.samples[#bucket.samples + 1] = age_ms
		if #bucket.samples > 256 then table.remove(bucket.samples, 1) end
	end
	local function inherit_ready_prerequisites(self, dependent, instant)
		if dependent.lane ~= "high" then return end
		local now = instant or now_ms()
		for _, prerequisite_id in ipairs(dependent.dependencies or {}) do
			local prerequisite = self.known[prerequisite_id]
			local inherited_by_same_dependent = prerequisite ~= nil and prerequisite.inherited_from == dependent.id
			local inheritance_active = prerequisite ~= nil and prerequisite.inherited_lane ~= nil
				and finite(prerequisite.inherited_until_ms) and prerequisite.inherited_until_ms > now
			if prerequisite ~= nil and prerequisite.queued == true and prerequisite.lane == "background"
				and (prerequisite.due_at_ms or 0) <= now
				and (prerequisite.available_at_ms == nil or prerequisite.available_at_ms <= now)
				and (prerequisite.expires_at_ms == nil or prerequisite.expires_at_ms > now)
				and dependencies_ready(self, prerequisite)
				and not inherited_by_same_dependent and not inheritance_active
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
	local function effective_cost(item, batch_count)
		local default_batch_count = if item.batchable == true
			then math.min(item.batch_size or 1, item.batch_backlog or item.batch_size or 1) else nil
		local dimensions = estimate_dimensions(item, if batch_count ~= nil then batch_count else default_batch_count)
		local estimated = math.max(
			1,
			dimensions.read_units + dimensions.write_units,
			math.ceil(dimensions.estimated_bytes / 16384)
		)
		if finite(item.requested_cost) then estimated = math.max(estimated, math.floor(item.requested_cost)) end
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
		local urgent_fallback = self.urgent_streak >= self.policy.urgent_deadline_burst
		-- A dependent may be queued before its prerequisite becomes due/available.
		-- Re-evaluate only high-lane items with dependencies so inheritance begins
		-- when the prerequisite is actually ready, not only at dependent enqueue.
		for _, dependent in ipairs(self.queue) do
			if dependent.lane == "high" and #(dependent.dependencies or {}) > 0 then
				inherit_ready_prerequisites(self, dependent, now)
			end
		end
		for index, item in ipairs(self.queue) do
			local ready = (item.due_at_ms or 0) <= now
				and (item.available_at_ms == nil or item.available_at_ms <= now)
				and dependencies_ready(self, item)
			if item.admission_blocked_until_ms ~= nil then
				if item.admission_blocked_until_ms > now then ready = false
				else item.admission_blocked_until_ms = nil end
			end
			if renewal_mode == true and item.lane ~= "lease_renewal" then ready = false end
			if renewal_mode == false and item.lane == "lease_renewal" then ready = false end
			if ready and (not item.expires_at_ms or item.expires_at_ms > now) then
				local owner_active = self.active_owner[item.owner_id] or 0
				local effective_lane = scheduled_lane(item, now)
				local renewal_count = self.active_renewals_by_owner[item.owner_id] or 0
				-- At most one renewal may be active for a single claim/owner at a time.
				local owner_can_renew = effective_lane ~= "lease_renewal" or renewal_count < 1
				if owner_can_renew and (effective_lane == "lease_renewal" or owner_active < self.policy.max_per_owner_in_flight) then
					local batch_count = selected_batch_size(self, item)
					local admission = admission_decision(self,
						item.work_class, item.operation_class, effective_cost(item, batch_count), item.mutating ~= false,
						item.service_class == "critical" or item.lane == "lease_renewal", estimate_dimensions(item, batch_count)
					)
					if admission.code == "admitted" then
						eligible[#eligible + 1] = { index = index, item = item, effective_lane = effective_lane, batch_count = batch_count }
					elseif finite(admission.retry_after_ms) then
						if admission.budget_limited then
							self.stats.rejected += 1
							self.stats.throttled += 1
						end
						item.admission_blocked_until_ms = now + math.max(1, admission.retry_after_ms)
					end
				end
			end
		end
		if #eligible == 0 then return nil, false end
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
			return best and best.index or nil, urgent_fallback
		elseif algorithm == "weighted" or algorithm == "deadline" then
			local best, best_score
			for _, row in ipairs(eligible) do
				local item = row.item
				local age = math.min(60000, math.max(0, now - item.enqueued_at_ms))
				local slack = if finite(item.deadline_ms) then item.deadline_ms - now else 60000
				-- After a bounded urgent burst, preserve lane/service priority but age
				-- rather than deadline slack decides the next candidate.
				local urgency_score = if self.urgent_streak >= self.policy.urgent_deadline_burst then 0 else slack
				local lane = row.effective_lane
				local lane_weight = if lane == "lease_renewal" then 8 elseif lane == "high" then 4 elseif lane == "normal" then 2 else 1
				local service_rank = if item.service_class == "critical" then 4 elseif item.service_class == "interactive" then 3 elseif item.service_class == "normal" then 2 elseif item.service_class == "bulk" then 1 else 0
				local score = if algorithm == "deadline"
					then -service_rank * 10000 - lane_weight * 1000 + urgency_score - age * 0.25
					else -lane_weight * 1000 - service_rank * 500 - age * 0.25 + urgency_score * 0.01
				if best_score == nil or score < best_score then best, best_score = row, score end
			end
			return best and best.index or nil, urgent_fallback
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
				local cost = effective_cost(best.item, best.batch_count)
				if cost <= self.drr_deficit[key] then
					self.drr_deficit[key] -= cost
					self.drr_cursor_key = key
					return best.index, urgent_fallback
				end
			end
		end
		return nil, false
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
		if value.mutating ~= nil and type(value.mutating) ~= "boolean" then return { code = "invalid", message = "mutating must be boolean" } end
		if value.batchable ~= nil and type(value.batchable) ~= "boolean" then return { code = "invalid", message = "batchable must be boolean" } end
		if value.batchable == true then
			local batch_size = if value.batch_size == nil then math.min(4, self.policy.max_batch) else value.batch_size
			local batch_backlog = if value.batch_backlog == nil then batch_size else value.batch_backlog
			if not finite(batch_size) or math.floor(batch_size) ~= batch_size or batch_size < 1 or batch_size > self.policy.max_batch then
				return { code = "invalid", message = "batch_size must fit max_batch" }
			end
			if not finite(batch_backlog) or math.floor(batch_backlog) ~= batch_backlog
				or batch_backlog < 1 or batch_backlog > self.policy.queue_capacity
			then
				return { code = "invalid", message = "batch_backlog must fit queue_capacity" }
			end
			value.batch_size, value.batch_backlog = batch_size, batch_backlog
		elseif value.batch_size ~= nil or value.batch_backlog ~= nil then
			return { code = "invalid", message = "batch sizing requires batchable = true" }
		end
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
		local requested_due = value.due_at_ms or value.available_at_ms or value.enqueued_at_ms
		value.due_at_ms = math.max(requested_due, value.available_at_ms or -math.huge)
		-- Expiry is a terminal wake boundary; unlike availability, it may precede the no-start boundary.
		if value.expires_at_ms ~= nil and value.expires_at_ms < value.due_at_ms then
			value.due_at_ms = value.expires_at_ms
		end
		value.dependencies = dependencies
		value.requested_cost = if finite(value.cost) then value.cost else nil
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
	function governor:CancelQueued(id, message)
		if not valid_text(id, 128) then return nil, "invalid id" end
		local item = self.known[id]
		if item == nil or item.queued ~= true then return nil, "scheduled item is not queued" end
		local queue_index
		for index, queued in ipairs(self.queue) do
			if queued == item then
				queue_index = index
				break
			end
		end
		if queue_index == nil then return nil, "queued item was not present in the queue" end
		table.remove(self.queue, queue_index)
		item.queued = false
		item.terminal_result = {
			code = "cancelled",
			message = if type(message) == "string" and message ~= "" then string.sub(message, 1, 200)
				else "scheduled work was cancelled before it started",
		}
		return item, nil
	end
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
			else
				local batch_count = selected_batch_size(self, item)
				local admission = admission_decision(self,
					item.work_class, item.operation_class, effective_cost(item, batch_count), item.mutating ~= false,
					item.service_class == "critical" or item.lane == "lease_renewal", estimate_dimensions(item, batch_count)
				)
				if admission.terminal then
					self.stats.rejected += 1
					table.remove(self.queue, index)
					item.queued = false
					item.terminal_result = admission
					self.known[item.id] = item
					return item, "admission_rejected"
				end
			end
		end
		local index, urgent_fallback = choose_index(self, self.policy.algorithm or "drr", renewal_mode)
		if not index then return nil, "empty" end
		if self.policy.shadow_enabled and self.policy.shadow_sample_rate > 0 then
			local interval = math.max(1, math.floor(1 / self.policy.shadow_sample_rate))
			if (self.stats.scheduled_selected + 1) % interval == 0 then self:ShadowDecision(renewal_mode) end
		end
		local selected_item = self.queue[index]
		local selected_count = selected_batch_size(self, selected_item)
		local item = table.remove(self.queue, index)
		item.admission_batch_size = selected_count
		item.admission_cost = effective_cost(item, selected_count)
		item.queued = false
		local age = math.max(0, now - (item.enqueued_at_ms or now))
		self.scheduler_metrics.wait_ms[#self.scheduler_metrics.wait_ms + 1] = age
		if #self.scheduler_metrics.wait_ms > 256 then table.remove(self.scheduler_metrics.wait_ms, 1) end
		local lane_stats = self.scheduler_metrics.by_lane[item.lane] or { selected = 0, total_wait_ms = 0, max_wait_ms = 0 }
		lane_stats.selected += 1
		lane_stats.total_wait_ms += age
		lane_stats.max_wait_ms = math.max(lane_stats.max_wait_ms, age)
		self.scheduler_metrics.by_lane[item.lane] = lane_stats
		record_wait_sample(self, item, age)
		self.stats.scheduled_selected += 1
		item.overdue = item.deadline_ms ~= nil and item.deadline_ms < now
		if item.overdue then self.stats.scheduled_overdue += 1 end
		local effective_lane = scheduled_lane(item, now)
		if effective_lane == "high" then self.high_streak += 1 else self.high_streak = 0 end
		if urgent_fallback then
			-- A fairness yield consumes the urgent burst; deadline preference may
			-- resume after this older eligible item receives service.
			self.urgent_streak = 0
		elseif finite(item.deadline_ms) and item.deadline_ms - now <= 5000 then
			self.urgent_streak += 1
		else
			self.urgent_streak = 0
		end
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
			if entry.item.queued ~= true or self.known[entry.id] ~= entry.item
				or entry.due_at_ms ~= entry.item.due_at_ms
			then
				-- Reschedule mutates the queue item's due time and pushes a replacement
				-- heap entry. Ignore the stale entry or observers may see the old deadline.
				heap_pop(self.queued_due_heap)
			else
				return entry.due_at_ms
			end
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
				if item.admission_blocked_until_ms ~= nil and item.admission_blocked_until_ms > now then
					candidate = item.admission_blocked_until_ms
				end
				if (item.due_at_ms or 0) > now and (candidate == nil or item.due_at_ms < candidate) then candidate = item.due_at_ms end
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
			operation_kind_keys = copy(self.operation_kind_keys),
			active_renewals_by_owner = copy(self.active_renewals_by_owner),
			drr_deficit = copy(self.drr_deficit), drr_cursor_key = self.drr_cursor_key,
			high_streak = self.high_streak, urgent_streak = self.urgent_streak,
			policy = copy(self.policy), in_flight = self.in_flight, by_class = copy(self.by_class),
			active_tickets = copy(self.active_tickets),
			read_units_in_flight = self.read_units_in_flight, write_units_in_flight = self.write_units_in_flight,
			estimated_bytes_in_flight = self.estimated_bytes_in_flight, handler_slots_in_flight = self.handler_slots_in_flight,
			request_budgets = copy(self.request_budgets), last_budget_by_kind = copy(self.last_budget_by_kind),
			latency_ewma = copy(self.latency_ewma), latency_samples_by_operation = copy(self.latency_samples_by_operation),
			scheduler_metrics = copy(self.scheduler_metrics),
			circuits = copy(self.circuits), stats = copy(self.stats),
		}
	end
	function governor:MarkCompleted(id, outcome)
		if not valid_text(id, 128) then return false, "invalid id" end
		local item = self.known[id]
		if item == nil then return false, "scheduled item is not known" end
		if item.queued == true and item.terminal_result == nil then
			return false, "scheduled item is still queued"
		end
		if item.dispatch_state ~= "in_flight" and item.terminal_result == nil then
			return false, "scheduled item is not in flight"
		end
		if item.dispatch_state == "in_flight" then
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
			or code == "acknowledged" or code == "processed" or code == "empty" or code == "completed" or code == "duplicate" or code == "renewed"
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
			if (item.due_at_ms or 0) <= now
				and (item.available_at_ms == nil or item.available_at_ms <= now)
				and dependencies_ready(self, item)
				and (item.expires_at_ms == nil or item.expires_at_ms > now)
			then oldest_eligible_age_ms = math.max(oldest_eligible_age_ms, now - item.enqueued_at_ms) end
		end
		local waits = copy(self.scheduler_metrics.wait_ms)
		table.sort(waits)
		local function percentile(values, p)
			if #values == 0 then return 0 end
			return values[math.clamp(math.ceil(#values * p), 1, #values)]
		end
		local wait_by_lane_class = {}
		for key, bucket in pairs(self.scheduler_metrics.wait_by_lane_class) do
			local samples = copy(bucket.samples)
			table.sort(samples)
			wait_by_lane_class[key] = {
				lane = bucket.lane, work_class = bucket.work_class, service_class = bucket.service_class,
				selected = bucket.selected, total_wait_ms = bucket.total_wait_ms, max_wait_ms = bucket.max_wait_ms,
				p50_ms = percentile(samples, 0.50), p95_ms = percentile(samples, 0.95), p99_ms = percentile(samples, 0.99),
			}
		end
		local latency_percentiles_by_operation = {}
		for operation, samples_source in pairs(self.latency_samples_by_operation) do
			local samples = copy(samples_source)
			table.sort(samples)
			latency_percentiles_by_operation[operation] = {
				count = #samples, p50_ms = percentile(samples, 0.50),
				p95_ms = percentile(samples, 0.95), p99_ms = percentile(samples, 0.99),
			}
		end
		return {
			policy = copy(self.policy), in_flight = self.in_flight, queue_items = #self.queue,
			active_reservation_tickets = key_count(self.active_tickets),
			read_units_in_flight = self.read_units_in_flight, write_units_in_flight = self.write_units_in_flight,
			estimated_bytes_in_flight = self.estimated_bytes_in_flight,
			handler_slots_in_flight = self.handler_slots_in_flight,
			request_budgets = copy(self.request_budgets),
			lanes = lanes, classes = copy(self.by_class), stats = copy(self.stats),
			latency_ewma = copy(self.latency_ewma), latency_percentiles_by_operation = latency_percentiles_by_operation,
			circuits = copy(self.circuits),
			last_budget_by_kind = copy(self.last_budget_by_kind), retry_tokens = self.retry_tokens,
			scheduler = {
				by_lane = copy(self.scheduler_metrics.by_lane), by_lane_class = wait_by_lane_class,
				oldest_eligible_age_ms = oldest_eligible_age_ms,
				queue_wait_p50_ms = percentile(waits, 0.50), queue_wait_p95_ms = percentile(waits, 0.95),
				queue_wait_p99_ms = percentile(waits, 0.99),
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
	if api == nil or type(api.delay) ~= "function" then return nil end
	return api.delay(seconds, callback)
end

local function cancel_scheduled(thread_to_cancel)
	if thread_to_cancel == nil then return end
	local api = get_task_api()
	if api ~= nil and type(api.cancel) == "function" then
		pcall(api.cancel, thread_to_cancel)
	end
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
		closing = false,
		wake_generation = 0,
		wake_due_ms = nil,
		wake_thread = nil,
		metrics = {
			accepted = 0, rejected = 0, completed = 0, retries = 0, retry_deferred = 0,
			expired = 0, dependency_failed = 0, callback_errors = 0, retry_exhausted = 0,
			batch_calls = 0, batch_items_requested = 0, batch_items_processed = 0, max_batch_size = 0,
			batch_utilization_samples = {},
			outcome_classes = { transient = 0, throttled = 0, permanent = 0, conflict = 0, unknown = 0, success = 0 },
			max_in_flight = 0, cancelled = 0, last_error = nil, last_outcome_class = nil,
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
		cancel_scheduled(dispatcher.wake_thread)
		dispatcher.wake_thread = nil
		dispatcher.wake_due_ms = due_at_ms
		local delay_ms = math.max(0, due_at_ms - now_ms())
		dispatcher.wake_thread = delay_scheduled(delay_ms / 1000, function()
			if dispatcher.closed or generation ~= dispatcher.wake_generation then return end
			dispatcher.wake_thread = nil
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
	local retry_classes = { transient = true, throttled = true, conflict = true }
	local function classify_outcome(result, callback_ok)
		if not callback_ok or type(result) ~= "table" then
			if not callback_ok then return "unknown" end
			local simple_code = if result == true or result == nil then "success" else tostring(result)
			if simple_code == "success" or simple_code == "committed" or simple_code == "completed" then return "success" end
			if simple_code == "throttled" or simple_code == "budget" then return "throttled" end
			if simple_code == "conflict" then return "conflict" end
			if simple_code == "unknown" then return "unknown" end
			if simple_code == "busy" or simple_code == "backpressure" or simple_code == "capacity" then return "transient" end
			return "permanent"
		end
		local code = result.code
		if code == nil or code == "success" or code == "committed" or code == "acknowledged"
			or code == "processed" or code == "empty" or code == "completed" or code == "saved" or code == "renewed"
			or code == "released" or code == "closed" or code == "deleted" or code == "duplicate"
		then
			return "success"
		end
		if code == "unknown" then return "unknown" end
		if code == "throttled" or code == "budget" then return "throttled" end
		if code == "conflict" then return "conflict" end
		if code == "retryable" or code == "retry_exhausted" then
			local retry_class = result.retry_class
			return if retry_class == "throttled" or retry_class == "conflict" or retry_class == "transient"
				then retry_class else "transient"
		end
		if code == "busy" or code == "backpressure" or code == "capacity" or code == "circuit_open" then return "transient" end
		return "permanent"
	end
	local function record_outcome(result, callback_ok)
		local class = classify_outcome(result, callback_ok)
		dispatcher.metrics.outcome_classes[class] = (dispatcher.metrics.outcome_classes[class] or 0) + 1
		dispatcher.metrics.last_outcome_class = class
		return class
	end
	local function retry_due(item, entry, result)
		local retry_class = if type(result) == "table" and type(result.retry_class) == "string"
			then result.retry_class else "transient"
		if retry_classes[retry_class] ~= true then
			local code = if retry_class == "unknown" then "unknown" else "retry_rejected"
			return false, { code = code, message = "retry was requested with a non-retryable outcome class", retry_class = retry_class, last_result = copy(result) }
		end
		if entry.retry_attempt >= entry.max_retries then
			return false, { code = "retry_exhausted", message = "configured retry cap reached", retry_class = retry_class, last_result = copy(result) }
		end
		local token, wait_ms = governor:AcquireRetryToken(entry.work_class)
		local now = now_ms()
		local delay_ms
		local retry_after_ms = if type(result) == "table" and finite(result.retry_after_ms)
			then math.clamp(math.floor(result.retry_after_ms), 0, 60000) else 0
		if token then
			local class_multiplier = if retry_class == "throttled" then 4 elseif retry_class == "conflict" then 2 else 1
			local exponential = math.min(60000, entry.retry_delay_ms * class_multiplier * (2 ^ entry.retry_attempt))
			local jitter_span = exponential * entry.retry_jitter_percent / 100
			local jitter = if jitter_span > 0 then (math.random() * 2 - 1) * jitter_span else 0
			delay_ms = math.clamp(math.max(retry_after_ms, math.floor(exponential + jitter), 10), 10, 60000)
		else
			-- Token pressure can defer retries, but cannot shorten a caller's retry-after.
			local token_wait_ms = if finite(wait_ms) then math.floor(wait_ms) else 60000
			delay_ms = math.clamp(math.max(token_wait_ms, retry_after_ms), 10, 60000)
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
			-- Defer visibly; do not execute a retry without class/global admission.
			entry.retry_waiting_for_token = true
			dispatcher.metrics.retry_deferred += 1
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
		local admission_ticket = if type(entry) == "table" and entry.admission_ticket ~= nil
			then entry.admission_ticket else item.admission_ticket
		if admission_ticket ~= nil then governor:Release(admission_ticket) end
		if type(entry) == "table" then entry.admission_ticket = nil end
		item.admission_ticket = nil
		local retry_scheduled = false
		if status == "success" and callback_ok and type(entry) == "table" and entry.batchable == true
			and type(callback_result) == "table" and finite(callback_result.processed_count)
			and classify_outcome(callback_result, callback_ok) == "success"
		then
			local requested_count = math.max(1, item.admission_batch_size or entry.batch_size or 1)
			local processed_count = math.clamp(math.floor(callback_result.processed_count), 0, requested_count)
			dispatcher.metrics.batch_items_processed += processed_count
			local utilization = processed_count / requested_count
			dispatcher.metrics.batch_utilization_samples[#dispatcher.metrics.batch_utilization_samples + 1] = utilization
			if #dispatcher.metrics.batch_utilization_samples > 256 then
				table.remove(dispatcher.metrics.batch_utilization_samples, 1)
			end
		end
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
		if status == "success" then
			record_outcome(callback_result, callback_ok)
			if type(callback_result) == "table" and callback_result.code == "retry_exhausted" then
				dispatcher.metrics.retry_exhausted += 1
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
	function dispatcher:CancelQueued(message)
		if self.closed then return 0 end
		local pending = {}
		for _, item in ipairs(governor.queue) do
			pending[#pending + 1] = item
		end
		local was_running = self.running
		self.running = true
		local cancelled_count = 0
		for _, item in ipairs(pending) do
			local cancelled = governor:CancelQueued(item.id, message)
			if cancelled ~= nil then
				cancelled_count += 1
				self.metrics.cancelled += 1
				finish_scheduled_item(cancelled, "cancelled", self.callbacks[cancelled.id], true, nil, false)
			end
		end
		self.running = was_running
		self.wake_generation += 1
		cancel_scheduled(self.wake_thread)
		self.wake_thread = nil
		self.wake_due_ms = nil
		if not was_running and not self.closed and not self.closing then self:Kick() end
		return cancelled_count
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
				dispatcher.metrics.retry_deferred += 1
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
		local admission = governor:Admit(
			item.work_class, item.operation_class, item.admission_cost or item.cost or 1, item.mutating ~= false,
			item.service_class == "critical" or item.lane == "lease_renewal",
			estimate_dimensions(item, item.admission_batch_size)
		)
		if admission.code ~= "admitted" then
			-- Admission is checked during selection and cannot race in this
			-- non-yielding section, but defer safely if a future caller changes that.
			if admission.terminal then
				item.terminal_result = admission
				finish_scheduled_item(item, "admission_rejected", entry, true, admission, false)
			else
				local delay_ms = if finite(admission.retry_after_ms)
					then math.clamp(math.floor(admission.retry_after_ms), 10, 60000) else 25
				local requeued, retry_error, retry_due_at = governor:Reschedule(
					item.id, math.max(now_ms() + delay_ms, item.available_at_ms or -math.huge)
				)
				if requeued then
					item.is_retry = false
					schedule_wake_at(retry_due_at)
				else
					item.terminal_result = { code = "backpressure", message = tostring(retry_error or "request admission deferred") }
					finish_scheduled_item(item, "admission_rejected", entry, true, item.terminal_result, false)
				end
			end
			return
		end
		item.admission_ticket = admission
		if type(entry) == "table" then entry.admission_ticket = admission end
		dispatcher.in_flight += 1
		if item.lane ~= "lease_renewal" then dispatcher.normal_in_flight += 1 end
		dispatcher.metrics.max_in_flight = math.max(dispatcher.metrics.max_in_flight, dispatcher.in_flight)
		spawn_scheduled(function()
			if dispatcher.closed or dispatcher.closing then
				finish_scheduled_item(item, "cancelled", entry, true, nil, true)
				return
			end
			-- A queued item can become expired after selection but before its
			-- coroutine actually starts. Check the no-new-start boundary again here.
			if finite(item.expires_at_ms) and item.expires_at_ms <= now_ms() then
				finish_scheduled_item(item, "expired", entry, true, nil, true)
				return
			end
			local started_at_ms = now_ms()
			local callback_ok, callback_result
			if type(entry) == "table" and type(entry.callback) == "function" then
				if entry.batchable == true then
					local batch_count = item.admission_batch_size or 1
					dispatcher.metrics.batch_calls += 1
					dispatcher.metrics.batch_items_requested += batch_count
					dispatcher.metrics.max_batch_size = math.max(dispatcher.metrics.max_batch_size, batch_count)
					callback_ok, callback_result = pcall(entry.callback, batch_count)
				else
					callback_ok, callback_result = pcall(entry.callback)
				end
			else
				callback_ok, callback_result = false, "scheduled callback is missing"
			end
			local elapsed_ms = math.max(0, now_ms() - started_at_ms)
			local result_code = if type(callback_result) == "table" then callback_result.code
				elseif callback_ok and (callback_result == true or callback_result == nil) then "success"
				elseif not callback_ok then "unknown" else tostring(callback_result)
			-- Schedule normalizes operation_class to work_class when omitted;
			-- keep observations keyed exactly like the admission reservation.
			local operation_kind = if type(entry) == "table"
				then entry.operation_class or entry.work_class or "default" else "scheduled_callback"
			local outcome_class = classify_outcome(callback_result, callback_ok)
			local failed = outcome_class ~= "success"
			local observed_budget = if type(callback_result) == "table" and finite(callback_result.budget)
				then callback_result.budget else nil
			governor:Observe(operation_kind, not failed, elapsed_ms, if failed then outcome_class else nil, observed_budget)
			local prior_service_latency = governor.latency_ewma.service
			governor.latency_ewma.service = if finite(prior_service_latency)
				then prior_service_latency * 0.8 + elapsed_ms * 0.2 else elapsed_ms
			finish_scheduled_item(item, "success", entry, callback_ok, callback_result, true)
		end)
	end
	kick_dispatcher = function()
		if dispatcher.closed or dispatcher.closing or dispatcher.running then return end
		dispatcher.running = true
		spawn_scheduled(function()
			governor:RefreshRequestBudgets()
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
		batchable = true, batch_size = true, batch_backlog = true, on_complete = true, mutating = true,
	}
	function dispatcher:Schedule(owner_id, work_id, callback, schedule_options)
		if self.closed or self.closing then return { code = "closed", message = "scheduler dispatcher is closing or closed" } end
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
		local current_policy = governor:Stats().policy
		local jitter = if schedule_options.retry_jitter_percent == nil
			then current_policy.retry_jitter_percent else schedule_options.retry_jitter_percent
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
		local batch_size = if schedule_options.batch_size == nil then math.min(4, current_policy.max_batch) else schedule_options.batch_size
		local batch_backlog = if schedule_options.batch_backlog == nil then batch_size else schedule_options.batch_backlog
		if not finite(batch_size) or math.floor(batch_size) ~= batch_size
			or batch_size < 1 or batch_size > current_policy.max_batch
		then
			return { code = "invalid", message = "batch_size must be an integer within max_batch" }
		end
		if not finite(batch_backlog) or math.floor(batch_backlog) ~= batch_backlog
			or batch_backlog < 1 or batch_backlog > current_policy.queue_capacity
		then
			return { code = "invalid", message = "batch_backlog must be an integer within queue_capacity" }
		end
		if schedule_options.batchable ~= true and (schedule_options.batch_size ~= nil or schedule_options.batch_backlog ~= nil) then
			return { code = "invalid", message = "batch_size and batch_backlog require batchable = true" }
		end
		if schedule_options.on_complete ~= nil and type(schedule_options.on_complete) ~= "function" then
			return { code = "invalid", message = "on_complete must be a function" }
		end
		if schedule_options.mutating ~= nil and type(schedule_options.mutating) ~= "boolean" then
			return { code = "invalid", message = "mutating must be a boolean" }
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
			batch_window = if finite(schedule_options.batch_window_ms) then schedule_options.batch_window_ms else current_policy.batch_window_ms
			local latency = math.max(governor.latency_ewma[work_class] or 0, governor.latency_ewma.outbox_dispatch or 0,
				governor.latency_ewma.write or 0, governor.latency_ewma.update_async or 0, governor.latency_ewma.service or 0)
			local snapshot = governor:Stats()
			local budget_headroom
			local budgets = snapshot.request_budgets
			if finite(budgets.sampled_at_ms) and now - budgets.sampled_at_ms <= 1000 then
				budget_headroom = math.min(budgets.read or math.huge, budgets.write or math.huge)
			end
			if latency >= current_policy.batch_latency_ceiling_ms
				or (finite(budget_headroom) and budget_headroom < current_policy.minimum_budget)
				or (finite(snapshot.scheduler.oldest_eligible_age_ms) and snapshot.scheduler.oldest_eligible_age_ms >= batch_window)
			then
				batch_window = 0
			elseif latency >= current_policy.batch_latency_ceiling_ms * 0.75 then
				batch_window = math.floor(batch_window / 2)
			elseif batch_backlog < batch_size then
				batch_window = math.min(batch_window, 2)
			end
		end
		due = math.max(due, now + batch_window)
		if finite(schedule_options.available_at_ms) then due = math.max(due, schedule_options.available_at_ms) end
		-- Deadlines influence selection priority; they never override availability.
		if finite(schedule_options.expires_at_ms) and due >= schedule_options.expires_at_ms then due = schedule_options.expires_at_ms end
		local item = {
			id = id, owner_id = owner_id, lane = lane, due_at_ms = due,
			available_at_ms = schedule_options.available_at_ms, deadline_ms = schedule_options.deadline_ms,
			expires_at_ms = schedule_options.expires_at_ms, service_class = schedule_options.service_class,
			work_class = work_class, operation_class = schedule_options.operation_class or work_class,
			dependencies = schedule_options.dependencies, read_units = schedule_options.read_units,
			write_units = schedule_options.write_units, estimated_bytes = schedule_options.estimated_bytes,
			handler_slots = schedule_options.handler_slots, cost = schedule_options.cost,
			mutating = schedule_options.mutating, batchable = schedule_options.batchable == true,
			batch_size = if schedule_options.batchable == true then batch_size else nil,
			batch_backlog = if schedule_options.batchable == true then batch_backlog else nil,
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
			batchable = schedule_options.batchable == true, batch_size = batch_size, batch_backlog = batch_backlog,
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
		if ok then self:Kick() end
		return if ok then "success" else "invalid", message
	end
	function dispatcher:Stats()
		local snapshot = copy(self.metrics)
		local utilization = snapshot.batch_utilization_samples
		snapshot.batch_utilization_samples = nil
		table.sort(utilization)
		local function percentile(p)
			if #utilization == 0 then return 0 end
			return utilization[math.clamp(math.ceil(#utilization * p), 1, #utilization)]
		end
		local utilization_total = 0
		for _, value in ipairs(utilization) do utilization_total += value end
		snapshot.batch_utilization = {
			samples = #utilization,
			average = if #utilization > 0 then utilization_total / #utilization else 0,
			p50 = percentile(0.50), p95 = percentile(0.95), p99 = percentile(0.99),
		}
		snapshot.in_flight = self.in_flight
		snapshot.normal_in_flight = self.normal_in_flight
		snapshot.next_wake_due_ms = self.wake_due_ms
		snapshot.closed = self.closed
		snapshot.governor = governor:Stats()
		return snapshot
	end
	function dispatcher:Close()
		if self.closed or self.closing then return end
		self.closing = true
		self:CancelQueued("scheduler dispatcher closed before work started")
		self.closed = true
		self.closing = false
		self.wake_generation += 1
		cancel_scheduled(self.wake_thread)
		self.wake_thread = nil
		self.wake_due_ms = nil
	end
	return dispatcher
end

Scheduler.new = new_governor
Scheduler.new_dispatcher = new_dispatcher

return Scheduler
