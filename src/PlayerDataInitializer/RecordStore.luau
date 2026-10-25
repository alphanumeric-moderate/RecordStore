--!strict
--!optimize 2
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local RecordStore = {}


-- BEGIN EMBEDDED SCHEDULER MODULE
type EmbeddedSchedulerDynamicRecord = { [string]: any }
type EmbeddedSchedulerOptions = {
	now_ms: (() -> number)?,
	get_request_budgets: (() -> any)?,
	advance_ms: ((number) -> ())?,
	get_record_stats: ((any) -> any)?,
	now_unix: (() -> number)?,
}
type EmbeddedSchedulerDispatcherOptions = {
	now_ms: (() -> number)?,
}

type EmbeddedSchedulerGovernor = {
	SetPolicy: (self: EmbeddedSchedulerGovernor, patch: { [string]: unknown }) -> (boolean, string?),
	Stats: (self: EmbeddedSchedulerGovernor) -> { [string]: any },
	ShadowDecision: (self: EmbeddedSchedulerGovernor, renewal_mode: string?) -> any,
	LeaseRenewalAdvice: (self: EmbeddedSchedulerGovernor) -> any,
	Replay: (self: EmbeddedSchedulerGovernor, log: { any }) -> { any },
}
type EmbeddedSchedulerScheduleOptions = {
	lane: string?,
	due_at_ms: number?,
	available_at_ms: number?,
	deadline_ms: number?,
	expires_at_ms: number?,
	service_class: string?,
	work_class: string?,
	operation_class: string?,
	dependencies: unknown?,
	read_units: number?,
	write_units: number?,
	estimated_bytes: number?,
	handler_slots: number?,
	cost: number?,
	max_retries: number?,
	retry_delay_ms: number?,
	retry_jitter_percent: number?,
	batch_window_ms: number?,
	batchable: boolean?,
	batch_size: number?,
	batch_backlog: number?,
	on_complete: ((result: any) -> ())?,
	mutating: boolean?,
}
type EmbeddedSchedulerScheduleResult = {
	code: string,
	id: string?,
	due_at_ms: number?,
	work_id: string?,
	message: string?,
}
type EmbeddedSchedulerDispatcher = {
	CancelQueued: (self: EmbeddedSchedulerDispatcher, message: string) -> number,
	Schedule: (
		self: EmbeddedSchedulerDispatcher,
		owner_id: string,
		work_id: string,
		callback: (...any) -> any,
		schedule_options: EmbeddedSchedulerScheduleOptions?
	) -> EmbeddedSchedulerScheduleResult,
	Kick: (self: EmbeddedSchedulerDispatcher) -> (),
	SetPolicy: (self: EmbeddedSchedulerDispatcher, policy: { [string]: unknown }) -> (string, string?),
	Stats: (self: EmbeddedSchedulerDispatcher) -> { [string]: any },
	Close: (self: EmbeddedSchedulerDispatcher) -> (),
}
type EmbeddedSchedulerModule = {
	new: (options: EmbeddedSchedulerOptions?) -> EmbeddedSchedulerGovernor,
	new_dispatcher: (governor: EmbeddedSchedulerGovernor, options: EmbeddedSchedulerDispatcherOptions?) -> EmbeddedSchedulerDispatcher,
}
local RecordStoreScheduler: EmbeddedSchedulerModule = {} :: EmbeddedSchedulerModule
do
	local Scheduler = RecordStoreScheduler
	local MAX_REPLAY_TRACE_EVENTS = 8192
	local MAX_REPLAY_ADVANCE_MS = 31_536_000_000

	local function finite(value: unknown): boolean
		return type(value) == "number" and math.isfinite(value)
	end

	local function valid_text(value: unknown, maximum: number): boolean
		return type(value) == "string" and value ~= "" and #value <= maximum
	end

	local function bounded_integer(value: unknown, default_value: number, minimum: number, maximum: number): number
		local selected = if type(value) == "number" and math.isfinite(value) then value else default_value
		return math.clamp(math.floor(selected), minimum, maximum)
	end

	local function key_count(value: any): number
		local count = 0
		for _ in pairs(value) do count += 1 end
		return count
	end

	local function copy(value: any, depth: number?, seen: { [any]: boolean }?): any
		local level: number = depth or 0
		local visited: { [any]: boolean } = seen or {}
		if level > 64 then error("scheduler value exceeds maximum depth", 3) end
		if type(value) ~= "table" then return value end
		if visited[value] then error("scheduler does not accept cyclic values", 3) end
		visited[value] = true
		local result: { [any]: any } = {}
		for key, child in pairs(value) do
			result[copy(key, level + 1, visited)] = copy(child, level + 1, visited)
		end
		visited[value] = nil
		return result
	end

	local MAX_SCHEDULER_COPY_NODES = 4096

	local function copy_bounded(value: any, maximum_nodes: number): any
		local seen = {}
		local nodes = 0
		local function visit(current: any, depth: number): any
			nodes += 1
			if nodes > maximum_nodes then error("scheduler value exceeds maximum node count", 3) end
			if depth > 64 then error("scheduler value exceeds maximum depth", 3) end
			if type(current) ~= "table" then return current end
			if seen[current] then error("scheduler does not accept cyclic values", 3) end
			seen[current] = true
			local result = {}
			for key, child in pairs(current) do
				result[visit(key, depth + 1)] = visit(child, depth + 1)
			end
			seen[current] = nil
			return result
		end
		return visit(value, 0)
	end

	local dirty_seen = setmetatable({}, { __mode = "k" })

	local operation_dimension_defaults: { [string]: EmbeddedSchedulerDynamicRecord } = {
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

	local function estimate_dimensions(item: EmbeddedSchedulerDynamicRecord, batch_count: number?): EmbeddedSchedulerDynamicRecord
		local request_kind = if type(item.operation_class) == "string" then item.operation_class
			elseif type(item.work_class) == "string" then item.work_class else "default"
		local defaults = operation_dimension_defaults[request_kind] or operation_dimension_defaults.default
		local multiplier: number = if item.batchable == true and type(batch_count) == "number" and math.isfinite(batch_count)
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
	local CORE_OPERATION_KINDS: { [string]: boolean } = {
		default = true, read = true, update_async = true, mailbox_claim = true,
		lease_renewal = true, profile_release = true, outbox_dispatch = true, maintenance = true,
		migration = true, projection = true, tracing = true, batch = true,
	}

	local function uses_critical_reserve(item: EmbeddedSchedulerDynamicRecord): boolean
		return item.lane == "lease_renewal" or item.service_class == "critical"
	end

	local function noncritical_queue_capacity(queue_capacity: number): number
		if queue_capacity <= 1 then return queue_capacity end
		local protected_slots = math.min(64, math.max(1, math.floor(queue_capacity / 16)), queue_capacity - 1)
		return queue_capacity - protected_slots
	end

	local function new_governor(options: EmbeddedSchedulerOptions?): EmbeddedSchedulerDynamicRecord
		if options == nil then options = {} end
		if type(options) ~= "table" then error("scheduler options must be a table", 2) end
		local function now_ms(): number
			return if type(options.now_ms) == "function" then options.now_ms() else os.clock() * 1000
		end
		local function operation_metric_key(self: EmbeddedSchedulerDynamicRecord, kind: unknown): string
			local operation_kind = if type(kind) == "string" and kind ~= "" then kind else "default"
			if CORE_OPERATION_KINDS[operation_kind] then return operation_kind end
			if operation_kind == OTHER_OPERATION_KIND or operation_kind == "service" then return OTHER_OPERATION_KIND end
			local existing = self.operation_kind_keys[operation_kind]
			if existing ~= nil then return existing end
			if key_count(self.operation_kind_keys) < MAX_CUSTOM_OPERATION_KIND_KEYS then
				self.operation_kind_keys[operation_kind] = operation_kind
				return operation_kind
			end
			return OTHER_OPERATION_KIND
		end
		local governor: EmbeddedSchedulerDynamicRecord = {
			policy = {
				revision = 1, mode = "normal", max_in_flight = 32, critical_reserve = 4,
				queue_capacity = 1024, max_batch = 16, batch_window_ms = 5,
				batch_latency_ceiling_ms = 40, high_burst = 4, retry_token_capacity = 32,
				retry_tokens_per_second = 4, minimum_budget = 2, circuit_threshold = 5, circuit_cooldown_ms = 15000,
				max_scheduled_in_flight = 8, scheduler_critical_reserve = 1, max_per_owner_in_flight = 2,
				max_read_units_in_flight = 32, max_write_units_in_flight = 32,
				read_critical_reserve = 4, write_critical_reserve = 4,
				max_estimated_bytes_in_flight = 16777216, max_handler_slots_in_flight = 16,
				estimated_bytes_critical_reserve = 4194304, handler_slots_critical_reserve = 1,
				drr_quantum = 4, max_item_cost = 64, urgent_deadline_burst = 4,
				priority_inheritance_max_ms = 1000, retry_jitter_percent = 20,
				algorithm = "drr", shadow_algorithm = "weighted", shadow_enabled = false, shadow_sample_rate = 0,
			},
			in_flight = 0, by_class = {}, active_tickets = {}, queue = {}, due = {}, due_heap = {}, queued_due_heap = {},
			wake_heap = {}, wake_sequence = 0,
			read_units_in_flight = 0, write_units_in_flight = 0,
			estimated_bytes_in_flight = 0, handler_slots_in_flight = 0,
			request_budgets = { read = nil, write = nil, sampled_at_ms = nil },
			completed = {}, completed_order = {}, known = {}, active_owner = {}, active_renewals_by_owner = {}, active_critical_by_owner = {},
			dependency_ref_counts = {}, pending_completed_prune = {}, pending_failed_prune = {},
			drr_deficit = {}, drr_cursor_key = nil, high_streak = 0, urgent_streak = 0,
			failed = {}, failed_order = {}, retry_cooldown_until = {}, retry_tokens_by_class = {},
			due_sequence = 0,
			retry_tokens = 32, last_token_time = now_ms(),
			last_budget = nil, last_budget_by_kind = {}, last_budget_sampled_at_by_kind = {},
			latency_ewma = {}, latency_samples_by_operation = {},
			operation_kind_keys = {}, consecutive_errors = {}, circuits = {},
			stats = { admitted = 0, rejected = 0, completed = 0, released = 0, throttled = 0, errors = 0,
				scheduled_selected = 0, scheduled_expired = 0, scheduled_overdue = 0, shadow_samples = 0 },
			scheduler_metrics = { by_lane = {}, wait_ms = {}, wait_by_lane_class = {}, last_shadow = nil },
		}
		local limits = { critical = 32, profile_save = 32, profile_release = 32, interactive = 24, messaging = 20, migration = 4, maintenance = 8, tracing = 1 }
		local function policy_valid(policy: EmbeddedSchedulerDynamicRecord): (boolean, string?)
			if type(policy) ~= "table" then return false, "policy must be a table" end
			local fields = {
				"revision", "max_in_flight", "critical_reserve", "queue_capacity", "max_batch",
				"batch_window_ms", "batch_latency_ceiling_ms", "high_burst", "retry_token_capacity",
				"retry_tokens_per_second", "minimum_budget", "circuit_threshold", "circuit_cooldown_ms",
				"max_scheduled_in_flight", "scheduler_critical_reserve", "max_per_owner_in_flight",
				"max_read_units_in_flight", "max_write_units_in_flight", "read_critical_reserve",
				"write_critical_reserve", "max_estimated_bytes_in_flight", "max_handler_slots_in_flight",
				"estimated_bytes_critical_reserve", "handler_slots_critical_reserve",
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
			if policy.estimated_bytes_critical_reserve < 0
				or policy.estimated_bytes_critical_reserve >= policy.max_estimated_bytes_in_flight
				or math.floor(policy.estimated_bytes_critical_reserve) ~= policy.estimated_bytes_critical_reserve
			then
				return false, "estimated_bytes_critical_reserve must be an integer below max_estimated_bytes_in_flight"
			end
			if policy.handler_slots_critical_reserve < 0
				or policy.handler_slots_critical_reserve >= policy.max_handler_slots_in_flight
				or math.floor(policy.handler_slots_critical_reserve) ~= policy.handler_slots_critical_reserve
			then
				return false, "handler_slots_critical_reserve must be an integer below max_handler_slots_in_flight"
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
				estimated_bytes_critical_reserve = true, handler_slots_critical_reserve = true,
				drr_quantum = true, max_item_cost = true, urgent_deadline_burst = true,
				priority_inheritance_max_ms = true, retry_jitter_percent = true,
				algorithm = true, shadow_algorithm = true, shadow_enabled = true, shadow_sample_rate = true,
			}
			for key in pairs(patch) do
				if not allowed[key] then return false, "unsupported scheduler policy field: " .. tostring(key) end
			end
			local next_policy = copy(self.policy)
			for key, value in pairs(patch) do next_policy[key] = value end
			if patch.max_estimated_bytes_in_flight ~= nil and patch.estimated_bytes_critical_reserve == nil
				and finite(next_policy.max_estimated_bytes_in_flight)
			then
				next_policy.estimated_bytes_critical_reserve = math.min(
					self.policy.estimated_bytes_critical_reserve,
					math.floor(next_policy.max_estimated_bytes_in_flight / 4)
				)
			end
			if patch.max_handler_slots_in_flight ~= nil and patch.handler_slots_critical_reserve == nil
				and finite(next_policy.max_handler_slots_in_flight)
			then
				next_policy.handler_slots_critical_reserve = math.min(
					self.policy.handler_slots_critical_reserve,
					math.max(0, next_policy.max_handler_slots_in_flight - 1)
				)
			end
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
				self.last_budget_sampled_at_by_kind[metric_kind] = now_ms()
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
		local function admission_decision(self: EmbeddedSchedulerDynamicRecord, work_class: any, request_kind: any, cost: any, mutating: any, critical_override: any, dimensions: any): (EmbeddedSchedulerDynamicRecord, boolean, boolean)
			if work_class == nil then work_class = "interactive" end
			if request_kind == nil then request_kind = "default" end
			if cost == nil then cost = 1 end
			if mutating == nil then
				mutating = true
			elseif type(mutating) ~= "boolean" then
				return { code = "invalid", terminal = true, message = "mutating must be boolean" }, false, false
			end
			if critical_override == nil then
				critical_override = false
			elseif type(critical_override) ~= "boolean" then
				return { code = "invalid", terminal = true, message = "critical_override must be boolean" }, false, false
			end
			if not valid_text(work_class, 64) then
				return { code = "invalid", terminal = true, message = "work_class must be 1..64 bytes" }, false, false
			end
			if not valid_text(request_kind, 128) then
				return { code = "invalid", terminal = true, message = "request_kind must be 1..128 bytes" }, false, false
			end
			request_kind = operation_metric_key(self, request_kind)
			if not finite(cost) or math.floor(cost) ~= cost or cost < 1 or cost > self.policy.max_item_cost then
				return { code = "invalid", terminal = true, message = "cost must be an integer within max_item_cost" }, false, false
			end
			if dimensions == nil then
				dimensions = estimate_dimensions({ operation_class = request_kind })
			elseif type(dimensions) ~= "table" then
				return { code = "invalid", terminal = true, message = "dimensions must be a table" }, false, false
			end
			for field in pairs(dimensions) do
				if field ~= "read_units" and field ~= "write_units"
					and field ~= "estimated_bytes" and field ~= "handler_slots"
				then
					return { code = "invalid", terminal = true, message = "unsupported admission dimension: " .. tostring(field) }, false, false
				end
			end
			if dimensions.read_units == nil or dimensions.write_units == nil
				or dimensions.estimated_bytes == nil or dimensions.handler_slots == nil
			then
				return {
					code = "invalid", terminal = true,
					message = "dimensions must explicitly provide read_units, write_units, estimated_bytes, and handler_slots",
				}, false, false
			end
			local read_units = dimensions.read_units
			local write_units = dimensions.write_units
			local estimated_bytes = dimensions.estimated_bytes
			local handler_slots = dimensions.handler_slots
			if not finite(read_units) or read_units < 0 or math.floor(read_units) ~= read_units
				or not finite(write_units) or write_units < 0 or math.floor(write_units) ~= write_units
				or not finite(estimated_bytes) or estimated_bytes < 0 or math.floor(estimated_bytes) ~= estimated_bytes
				or not finite(handler_slots) or handler_slots < 1 or math.floor(handler_slots) ~= handler_slots
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
			local observed_budget_at = self.last_budget_sampled_at_by_kind[request_kind]
			local observed_budget_age = if finite(observed_budget_at) then now_ms() - observed_budget_at else math.huge
			local observed_budget_fresh = observed_budget_age >= 0 and observed_budget_age <= 1000
			if finite(observed_budget) and observed_budget < self.policy.minimum_budget and observed_budget_fresh and not critical then
				return { code = "backpressure", transient = true, budget_limited = true, retry_after_ms = 250,
					message = "operation budget is below configured minimum" }, false, true
			end
			local budgets = self.request_budgets
			local budget_fresh = finite(budgets.sampled_at_ms) and now_ms() - budgets.sampled_at_ms <= 1000
			if budget_fresh then
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
			if not critical and self.estimated_bytes_in_flight + estimated_bytes
				> self.policy.max_estimated_bytes_in_flight - self.policy.estimated_bytes_critical_reserve
			then
				return { code = "backpressure", transient = true, message = "critical estimated-byte reserve protected" }, false, true
			end
			if self.handler_slots_in_flight + handler_slots > self.policy.max_handler_slots_in_flight then
				return { code = "capacity", transient = true, message = "handler-slot admission capacity reached" }, false, true
			end
			if not critical and self.handler_slots_in_flight + handler_slots
				> self.policy.max_handler_slots_in_flight - self.policy.handler_slots_critical_reserve
			then
				return { code = "backpressure", transient = true, message = "critical handler-slot reserve protected" }, false, true
			end
			if (self.by_class[work_class] or 0) + cost > math.min(limits[work_class] or limits.interactive, self.policy.max_in_flight) then
				return { code = "capacity", transient = true, message = "work-class cap reached" }, false, true
			end
			return {
				code = "admitted", work_class = work_class, request_kind = request_kind,
				cost = cost, critical = critical,
				dimensions = {
					read_units = read_units, write_units = write_units,
					estimated_bytes = estimated_bytes, handler_slots = handler_slots,
				},
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
		local function calculate_batch_size(policy: EmbeddedSchedulerDynamicRecord, requested: any, latency_ms: any, backlog: any, oldest_age_ms: any, budget_headroom: any): number
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
		local function selected_batch_size(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord): number?
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
		local function heap_less(left: any, right: any): boolean
			if left.due_at_ms ~= right.due_at_ms then return left.due_at_ms < right.due_at_ms end
			if left.id ~= right.id then return left.id < right.id end
			return (left.sequence or 0) < (right.sequence or 0)
		end
		local function heap_push(heap: any, value: any)
			local index = #heap + 1
			heap[index] = value
			while index > 1 do
				local parent = math.floor(index / 2)
				if not heap_less(heap[index], heap[parent]) then break end
				heap[index], heap[parent] = heap[parent], heap[index]
				index = parent
			end
		end
		local function heap_pop(heap: any): any
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
		local rebuild_queue_wake_heap
		local function push_wake_event(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord, kind: string, due_at_ms: number)
			self.wake_sequence += 1
			item.wake_tokens = item.wake_tokens or {}
			item.wake_tokens[kind] = self.wake_sequence
			heap_push(self.wake_heap, {
				id = item.id, item = item, kind = kind,
				due_at_ms = due_at_ms, sequence = self.wake_sequence,
			})
			if #self.wake_heap > self.policy.queue_capacity * 4 and rebuild_queue_wake_heap ~= nil then
				rebuild_queue_wake_heap(self)
			end
		end
		rebuild_queue_wake_heap = function(self)
			self.wake_heap = {}
			local now = now_ms()
			for _, item in ipairs(self.queue) do
				if finite(item.due_at_ms) and item.due_at_ms > now then
					push_wake_event(self, item, "due", item.due_at_ms)
				end
				if finite(item.expires_at_ms) and item.expires_at_ms > now then
					push_wake_event(self, item, "expiry", item.expires_at_ms)
				end
				if finite(item.admission_blocked_until_ms) and item.admission_blocked_until_ms > now then
					push_wake_event(self, item, "admission", item.admission_blocked_until_ms)
				end
			end
		end
		local function index_item_wake_events(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord)
			local now = now_ms()
			if finite(item.due_at_ms) and item.due_at_ms > now then
				push_wake_event(self, item, "due", item.due_at_ms)
			end
			if finite(item.expires_at_ms) and item.expires_at_ms > now then
				push_wake_event(self, item, "expiry", item.expires_at_ms)
			end
			if finite(item.admission_blocked_until_ms) and item.admission_blocked_until_ms > now then
				push_wake_event(self, item, "admission", item.admission_blocked_until_ms)
			end
		end
		local function rebuild_due_heap()
			local rebuilt = {}
			for _, item in pairs(governor.due) do heap_push(rebuilt, item) end
			governor.due_heap = rebuilt
		end
		function governor:ScheduleDue(id, due_at_ms, value)
			if not valid_text(id, 128) or not finite(due_at_ms) then return false, "invalid due item" end
			if self.due[id] == nil and key_count(self.due) >= self.policy.queue_capacity then return false, "due queue full" end
			local copy_ok, copied_value = pcall(copy_bounded, value, MAX_SCHEDULER_COPY_NODES)
			if not copy_ok then
				return false, "due item value must be acyclic, within the maximum depth, and within the node limit"
			end
			self.due_sequence = (self.due_sequence or 0) + 1
			local item = { id = id, due_at_ms = due_at_ms, value = copied_value, sequence = self.due_sequence }
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
		local function dependencies_ready(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord): boolean
			for _, dependency in ipairs(item.dependencies or {}) do
				if not self.completed[dependency] then return false end
			end
			return true
		end
		local function retain_dependencies(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord)
			for _, dependency in ipairs(item.dependencies or {}) do
				self.dependency_ref_counts[dependency] = (self.dependency_ref_counts[dependency] or 0) + 1
			end
		end
		local function release_dependencies(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord)
			for _, dependency in ipairs(item.dependencies or {}) do
				local count = self.dependency_ref_counts[dependency]
				if count ~= nil then
					count -= 1
					if count <= 0 then
						self.dependency_ref_counts[dependency] = nil
						if self.pending_completed_prune[dependency] then
							self.pending_completed_prune[dependency] = nil
							self.completed[dependency] = nil
						end
						if self.pending_failed_prune[dependency] then
							self.pending_failed_prune[dependency] = nil
							self.failed[dependency] = nil
						end
					else
						self.dependency_ref_counts[dependency] = count
					end
				end
			end
		end
		local function scheduled_lane(item: EmbeddedSchedulerDynamicRecord, now: number): string
			if item.inherited_lane ~= nil and finite(item.inherited_until_ms) and item.inherited_until_ms > now then
				return item.inherited_lane
			end
			return item.lane
		end
		local function item_priority(item: EmbeddedSchedulerDynamicRecord): number
			return if item.service_class == "critical" then 0 elseif item.service_class == "interactive" then 1
				elseif item.service_class == "normal" then 2 elseif item.service_class == "bulk" then 3 else 4
		end
		local function record_wait_sample(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord, age_ms: number)
			local lane = if item.lane == nil then "normal" else item.lane
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
		local function inherit_ready_prerequisites(self: EmbeddedSchedulerDynamicRecord, dependent: EmbeddedSchedulerDynamicRecord, instant: number)
			if dependent.lane ~= "high" then return end
			if not finite(dependent.deadline_ms)
				and dependent.service_class ~= "interactive"
				and dependent.service_class ~= "critical"
			then
				return
			end
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
		local function item_precedes(left: EmbeddedSchedulerDynamicRecord, right: EmbeddedSchedulerDynamicRecord, now: number): boolean
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
		local function estimated_service_time_ms(self: EmbeddedSchedulerDynamicRecord, item: EmbeddedSchedulerDynamicRecord, cache: any): number
			local operation_kind = if type(item.operation_class) == "string" then item.operation_class else "default"
			local metric_kind = operation_metric_key(self, operation_kind)
			local cached = cache[metric_kind]
			if cached ~= nil then return cached end
			local estimate = self.latency_ewma[metric_kind] or 0
			local samples = self.latency_samples_by_operation[metric_kind]
			if samples ~= nil and #samples > 0 then
				local ordered = copy(samples)
				table.sort(ordered)
				estimate = math.max(estimate, ordered[math.ceil(#ordered * 0.95)] or 0)
			end
			cache[metric_kind] = estimate
			return estimate
		end
		local function effective_cost(item: EmbeddedSchedulerDynamicRecord, batch_count: number?): number
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
		local function lane_key(item: EmbeddedSchedulerDynamicRecord, now: number): string
			local instant = now or now_ms()
			local function component(value: unknown): string
				local text = tostring(value or "default")
				return tostring(#text) .. ":" .. text
			end
			return component(item.owner_id)
				.. component(item.work_class or "default")
				.. component(scheduled_lane(item, instant))
				.. component(item.service_class or "best_effort")
		end
		local function choose_index(self: EmbeddedSchedulerDynamicRecord, algorithm: any, renewal_mode: any): (number?, boolean)
			local now, eligible = now_ms(), {}
			local urgent_fallback = self.urgent_streak >= self.policy.urgent_deadline_burst
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
				if renewal_mode == "critical" and not uses_critical_reserve(item) then ready = false end
				if renewal_mode == "regular" and uses_critical_reserve(item) then ready = false end
				if ready and (not item.expires_at_ms or item.expires_at_ms > now) then
					local owner_active = self.active_owner[item.owner_id] or 0
					local effective_lane = scheduled_lane(item, now)
					local renewal_count = self.active_renewals_by_owner[item.owner_id] or 0
					local critical_owner_count = self.active_critical_by_owner[item.owner_id] or 0
					local owner_can_renew = effective_lane ~= "lease_renewal" or renewal_count < 1
					local owner_can_use_reserve = not uses_critical_reserve(item) or critical_owner_count < 1
					if owner_can_renew and owner_can_use_reserve
						and (uses_critical_reserve(item) or owner_active < self.policy.max_per_owner_in_flight)
					then
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
							push_wake_event(self, item, "admission", item.admission_blocked_until_ms)
						end
					end
				end
			end
			if #eligible == 0 then return nil, false end
			if self.high_streak >= self.policy.high_burst then
				local has_non_high = false
				for _, row in ipairs(eligible) do
					if row.effective_lane ~= "high" and row.effective_lane ~= "lease_renewal" then
						has_non_high = true
						break
					end
				end
				if has_non_high then
					local filtered = {}
					for _, row in ipairs(eligible) do if row.effective_lane ~= "high" then filtered[#filtered + 1] = row end end
					eligible = filtered
				end
			end
			if renewal_mode == true then
				local best
				for _, row in ipairs(eligible) do
					if best == nil or item_precedes(row.item, best.item, now) then best = row end
				end
				return best and best.index or nil, urgent_fallback
			elseif renewal_mode == "critical" then
				local best
				for _, row in ipairs(eligible) do
					if best == nil or item_precedes(row.item, best.item, now) then best = row end
				end
				return best and best.index or nil, urgent_fallback
			end
			if algorithm == "fifo" then
				local best
				for _, row in ipairs(eligible) do
					if best == nil or row.item.enqueued_at_ms < best.item.enqueued_at_ms then best = row end
				end
				return best and best.index or nil, urgent_fallback
			elseif algorithm == "weighted" or algorithm == "deadline" then
				local best, best_score
				local service_time_estimates = {}
				for _, row in ipairs(eligible) do
					local item = row.item
					local age = math.min(60000, math.max(0, now - item.enqueued_at_ms))
					local slack = if finite(item.deadline_ms)
						then item.deadline_ms - now - estimated_service_time_ms(self, item, service_time_estimates)
						else 60000
					local urgency_score = if self.urgent_streak >= self.policy.urgent_deadline_burst then 0 else slack
					local lane = row.effective_lane
					local lane_weight = if lane == "lease_renewal" then 8 elseif lane == "high" then 4 elseif lane == "normal" then 2 else 1
					local service_rank = if item.service_class == "critical" then 4 elseif item.service_class == "interactive" then 3 elseif item.service_class == "normal" then 2 elseif item.service_class == "bulk" then 1 else 0
					local deadline_bonus = math.clamp(urgency_score, -499, 499)
					local weighted_deadline_bonus = math.clamp(urgency_score * 0.01, -249, 249)
					local score = if algorithm == "deadline"
						then -service_rank * 1000 - lane_weight * 1000 + deadline_bonus - age * 0.25
						else -lane_weight * 1000 - service_rank * 500 - age * 0.25 + weighted_deadline_bonus
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
					if key == self.drr_cursor_key then
						start_index = (i % lane_count) + 1
						break
					end
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
		function governor:Enqueue(item, protect_critical_queue)
			if protect_critical_queue ~= nil and type(protect_critical_queue) ~= "boolean" then
				return { code = "invalid", message = "protect_critical_queue must be boolean" }
			end
			if type(item) ~= "table" or not valid_text(item.id, 128) or not valid_text(item.owner_id, 512) then return { code = "invalid" } end
			if self.known[item.id] or self.completed[item.id] == true or self.failed[item.id] ~= nil then
				return { code = "duplicate", message = "work ID is active or has retained terminal history" }
			end
			local lane = if item.lane == nil then "normal" else item.lane
			if lane ~= "high" and lane ~= "normal" and lane ~= "background" and lane ~= "lease_renewal" then return { code = "invalid", message = "unsupported lane" } end
			local copy_ok, value = pcall(copy_bounded, item, MAX_SCHEDULER_COPY_NODES)
			if not copy_ok or type(value) ~= "table" then
				return { code = "invalid", message = "scheduled item must be acyclic, within the maximum depth, and within the node limit" }
			end
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
			local dependencies = if value.dependencies == nil then {} else value.dependencies
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
			local queue_capacity = self.policy.queue_capacity
			if #self.queue >= queue_capacity then
				self.stats.rejected += 1
				return { code = "capacity", message = "local queue full; no accepted work is evicted" }
			end
			if protect_critical_queue == true and not uses_critical_reserve(value) then
				local noncritical_capacity = noncritical_queue_capacity(queue_capacity)
				if #self.queue >= noncritical_capacity then
					self.stats.rejected += 1
					return {
						code = "capacity",
						message = "local queue full; capacity is reserved for internal critical work",
					}
				end
			end
			value.work_class = value.work_class or value.operation_class or "default"
			value.enqueued_at_ms = now_ms()
			local requested_due = value.due_at_ms or value.available_at_ms or value.enqueued_at_ms
			value.due_at_ms = math.max(requested_due, value.available_at_ms or -math.huge)
			if value.expires_at_ms ~= nil and value.expires_at_ms < value.due_at_ms then
				value.due_at_ms = value.expires_at_ms
			end
			value.dependencies = dependencies
			value.requested_cost = if finite(value.cost) then value.cost else nil
			value.cost = effective_cost(value)
			if value.cost > self.policy.max_item_cost then return { code = "invalid", message = "estimated scheduler cost exceeds max_item_cost" } end
			value.queued = true
			self.known[value.id] = value
			retain_dependencies(self, value)
			table.insert(self.queue, value)
			heap_push(self.queued_due_heap, { id = value.id, due_at_ms = value.due_at_ms, item = value })
			index_item_wake_events(self, value)
			inherit_ready_prerequisites(self, value, now_ms())
			if #self.queued_due_heap > self.policy.queue_capacity * 2 then
				local rebuilt = {}
				for _, queued in ipairs(self.queue) do heap_push(rebuilt, { id = queued.id, due_at_ms = queued.due_at_ms, item = queued }) end
				self.queued_due_heap = rebuilt
			end
			return { code = "accepted", count = #self.queue }
		end
		local remember_terminal
		local function refresh_owner_retry_cooldown(self: EmbeddedSchedulerDynamicRecord, owner_id: string)
			local latest_due = nil
			for _, queued in ipairs(self.queue) do
				if queued.owner_id == owner_id and queued.is_retry == true then
					local due = if finite(queued.due_at_ms) then queued.due_at_ms else now_ms()
					latest_due = if latest_due == nil then due else math.max(latest_due, due)
				end
			end
			self.retry_cooldown_until[owner_id] = latest_due
		end
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
			refresh_owner_retry_cooldown(self, item.owner_id)
			item.terminal_result = {
				code = "cancelled",
				message = if type(message) == "string" and message ~= "" then string.sub(message :: string, 1, 200)
					else "scheduled work was cancelled before it started",
			}
			return item, nil
		end
		function governor:TakeNext(renewal_mode)
			local now = now_ms()
			for index = #self.queue, 1, -1 do
				local item = self.queue[index]
				local failed_dependency
				for _, dependency in ipairs(item.dependencies or {}) do
					if self.failed[dependency] ~= nil then
						failed_dependency = dependency
						break
					end
				end
				if failed_dependency ~= nil then
					table.remove(self.queue, index)
					item.queued = false
					local dependency_code = self.failed[failed_dependency]
					item.terminal_result = {
						code = "dependency_failed", message = "prerequisite reached a non-success terminal outcome",
						dependency_id = failed_dependency, dependency_code = dependency_code,
					}
					release_dependencies(self, item)
					self.known[item.id] = nil
					refresh_owner_retry_cooldown(self, item.owner_id)
					remember_terminal(self, item.id, "dependency_failed")
					return item, "dependency_failed"
				elseif item.expires_at_ms and item.expires_at_ms <= now then
					table.remove(self.queue, index)
					item.queued = false
					self.stats.scheduled_expired += 1
					item.terminal_result = { code = "expired", message = "scheduled work expired before it could start" }
					release_dependencies(self, item)
					self.known[item.id] = nil
					refresh_owner_retry_cooldown(self, item.owner_id)
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
			if selected_item == nil then return nil, "empty" end
			local selected_count = selected_batch_size(self, selected_item)
			local item = table.remove(self.queue, index)
			if item == nil then return nil, "empty" end
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
				self.urgent_streak = 0
			elseif finite(item.deadline_ms) and item.deadline_ms - now <= 5000 then
				self.urgent_streak += 1
			else
				self.urgent_streak = 0
			end
			self.active_owner[item.owner_id] = (self.active_owner[item.owner_id] or 0) + 1
			if uses_critical_reserve(item) then
				self.active_critical_by_owner[item.owner_id] = (self.active_critical_by_owner[item.owner_id] or 0) + 1
			end
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
					heap_pop(self.queued_due_heap)
				else
					return entry.due_at_ms
				end
			end
		end
		function governor:NextWakeAt()
			local now = now_ms()
			while true do
				local event = self.wake_heap[1]
				if event == nil then return nil end
				local item = event.item
				local tokens = item.wake_tokens
				local current_at = if event.kind == "due" then item.due_at_ms
					elseif event.kind == "expiry" then item.expires_at_ms
					else item.admission_blocked_until_ms
				local valid = item.queued == true and self.known[event.id] == item
					and tokens ~= nil and tokens[event.kind] == event.sequence
					and current_at == event.due_at_ms
				if not valid or event.due_at_ms <= now then
					heap_pop(self.wake_heap)
				else
					return event.due_at_ms
				end
			end
		end
		function governor:Reschedule(id, due_at_ms, protect_critical_queue)
			if not valid_text(id, 128) or not finite(due_at_ms) then return false, "invalid retry schedule" end
			local item = self.known[id]
			if item == nil or item.dispatch_state ~= "in_flight" then return false, "scheduled item is not in flight" end
			if #self.queue >= self.policy.queue_capacity then return false, "local queue full; retry was not accepted" end
			if protect_critical_queue == true and not uses_critical_reserve(item)
				and #self.queue >= noncritical_queue_capacity(self.policy.queue_capacity)
			then
				return false, "local queue full; capacity is reserved for internal critical work"
			end
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
			if uses_critical_reserve(item) then
				local critical_count = math.max(0, (self.active_critical_by_owner[item.owner_id] or 1) - 1)
				if critical_count == 0 then self.active_critical_by_owner[item.owner_id] = nil
				else self.active_critical_by_owner[item.owner_id] = critical_count end
			end
			table.insert(self.queue, item)
			heap_push(self.queued_due_heap, { id = item.id, due_at_ms = item.due_at_ms, item = item })
			index_item_wake_events(self, item)
			if #self.queued_due_heap > self.policy.queue_capacity * 2 then
				local rebuilt = {}
				for _, queued in ipairs(self.queue) do heap_push(rebuilt, { id = queued.id, due_at_ms = queued.due_at_ms, item = queued }) end
				self.queued_due_heap = rebuilt
			end
			self.retry_cooldown_until[item.owner_id] = next_due
			return true, nil, next_due
		end
		local function terminal_dependency_referenced(self: EmbeddedSchedulerDynamicRecord, id: string): boolean
			return (self.dependency_ref_counts[id] or 0) > 0
		end
		local function prune_terminal_history(self: EmbeddedSchedulerDynamicRecord)
			local limit = self.policy.queue_capacity * 2
			local function prune(order: any, outcomes: any, pending: any)
				while #order > limit do
					local oldest = table.remove(order, 1) :: string
					if terminal_dependency_referenced(self, oldest) then
						pending[oldest] = true
					else
						outcomes[oldest] = nil
						pending[oldest] = nil
					end
				end
			end
			prune(self.completed_order, self.completed, self.pending_completed_prune)
			prune(self.failed_order, self.failed, self.pending_failed_prune)
		end
		remember_terminal = function(self, id, code)
			self.failed[id] = code
			self.failed_order[#self.failed_order + 1] = id
			prune_terminal_history(self)
		end
		local function make_shadow_state(self: EmbeddedSchedulerDynamicRecord): EmbeddedSchedulerDynamicRecord
			local queue = copy(self.queue)
			local queued_by_id = {}
			for _, item in ipairs(queue) do
				queued_by_id[item.id] = item
			end
			local known = {}
			for id, item in pairs(self.known) do
				known[id] = queued_by_id[id] or copy(item)
			end
			return {
				queue = queue, completed = copy(self.completed), known = known,
				failed = copy(self.failed), active_owner = copy(self.active_owner),
				operation_kind_keys = copy(self.operation_kind_keys),
				active_renewals_by_owner = copy(self.active_renewals_by_owner),
				active_critical_by_owner = copy(self.active_critical_by_owner),
				drr_deficit = copy(self.drr_deficit), drr_cursor_key = self.drr_cursor_key,
				high_streak = self.high_streak, urgent_streak = self.urgent_streak,
				policy = copy(self.policy), in_flight = self.in_flight, by_class = copy(self.by_class),
				active_tickets = copy(self.active_tickets),
				wake_heap = copy(self.wake_heap), wake_sequence = self.wake_sequence,
				read_units_in_flight = self.read_units_in_flight, write_units_in_flight = self.write_units_in_flight,
				estimated_bytes_in_flight = self.estimated_bytes_in_flight, handler_slots_in_flight = self.handler_slots_in_flight,
				request_budgets = copy(self.request_budgets),
				last_budget_by_kind = copy(self.last_budget_by_kind),
				last_budget_sampled_at_by_kind = copy(self.last_budget_sampled_at_by_kind),
				latency_ewma = copy(self.latency_ewma), latency_samples_by_operation = copy(self.latency_samples_by_operation),
				scheduler_metrics = copy(self.scheduler_metrics),
				circuits = copy(self.circuits), stats = copy(self.stats),
			}
		end
		function governor:MarkCompleted(id, outcome)
			if not valid_text(id, 128) then return false, "invalid id" end
			local code = if type(outcome) == "table" then outcome.code else outcome
			local item = self.known[id]
			if item == nil then
				if self.failed[id] ~= nil and tostring(code or "unknown") == self.failed[id] then return true end
				return false, "scheduled item is not known"
			end
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
				if uses_critical_reserve(item) then
					local critical_count = math.max(0, (self.active_critical_by_owner[item.owner_id] or 1) - 1)
					if critical_count == 0 then self.active_critical_by_owner[item.owner_id] = nil
					else self.active_critical_by_owner[item.owner_id] = critical_count end
				end
			end
			release_dependencies(self, item)
			self.known[id] = nil
			if item ~= nil then refresh_owner_retry_cooldown(self, item.owner_id) end
			for _, dependent_item in pairs(self.known) do
				if dependent_item.inherited_from == id then
					dependent_item.inherited_lane = nil
					dependent_item.inherited_until_ms = nil
					dependent_item.inherited_from = nil
				end
			end
			if code == nil or code == true or code == "success" or code == "committed"
				or code == "acknowledged" or code == "processed" or code == "empty" or code == "completed" or code == "duplicate" or code == "renewed"
				or code == "saved" or code == "closed" or code == "created" or code == "loaded"
				or code == "enqueued" or code == "deleted" or code == "released" or code == "committed_reconciled"
			then
				self.completed[id] = true
				self.failed[id] = nil
				self.completed_order[#self.completed_order + 1] = id
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
			prune_terminal_history(self)
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
			local function invalid_trace(message: string)
				return { code = "invalid", message = message }
			end
			if type(log) ~= "table" then return invalid_trace("scheduler trace must be an array") end
			local event_count = 0
			for key in pairs(log) do
				if not finite(key) or math.floor(key) ~= key or key < 1 or key > MAX_REPLAY_TRACE_EVENTS then
					return invalid_trace("scheduler trace must be a dense array within the event limit")
				end
				event_count += 1
				if event_count > MAX_REPLAY_TRACE_EVENTS then
					return invalid_trace("scheduler trace exceeds the event limit")
				end
			end
			if #log ~= event_count then
				return invalid_trace("scheduler trace must be a dense array")
			end
			for index = 1, event_count do
				local entry = rawget(log, index)
				if type(entry) ~= "table" then
					return invalid_trace("scheduler trace event " .. tostring(index) .. " must be a table")
				end
				if entry.kind == "enqueue" then
					if type(entry.item) ~= "table" then
						return invalid_trace("enqueue event " .. tostring(index) .. " must include an item table")
					end
				elseif entry.kind == "complete" then
					if not valid_text(entry.id, 128) then
						return invalid_trace("complete event " .. tostring(index) .. " must include a valid work ID")
					end
					local outcome_type = type(entry.outcome)
					if entry.outcome ~= nil and outcome_type ~= "string" and outcome_type ~= "boolean"
						and outcome_type ~= "number" and outcome_type ~= "table"
					then
						return invalid_trace("complete event " .. tostring(index) .. " has an unsupported outcome")
					end
				elseif entry.kind == "take" then
					if entry.renewal_mode ~= nil and type(entry.renewal_mode) ~= "boolean" then
						return invalid_trace("take event " .. tostring(index) .. " has an invalid renewal mode")
					end
					if entry.mode ~= nil and entry.mode ~= "critical" and entry.mode ~= "regular" then
						return invalid_trace("take event " .. tostring(index) .. " has an invalid selector mode")
					end
					if entry.mode ~= nil and entry.renewal_mode ~= nil then
						return invalid_trace("take event " .. tostring(index) .. " cannot combine mode and renewal_mode")
					end
				elseif entry.kind == "budget" then
					if not finite(entry.read) or entry.read < 0 or not finite(entry.write) or entry.write < 0 then
						return invalid_trace("budget event " .. tostring(index) .. " requires non-negative finite read and write budgets")
					end
				elseif entry.kind == "observe" then
					if not valid_text(entry.operation_kind, 64) or type(entry.succeeded) ~= "boolean"
						or not finite(entry.latency_ms) or entry.latency_ms < 0
					then
						return invalid_trace("observe event " .. tostring(index) .. " requires an operation kind, success flag and non-negative finite latency")
					end
					if entry.error_class ~= nil and not valid_text(entry.error_class, 64) then
						return invalid_trace("observe event " .. tostring(index) .. " has an invalid error class")
					end
					if entry.budget ~= nil and (not finite(entry.budget) or entry.budget < 0) then
						return invalid_trace("observe event " .. tostring(index) .. " has an invalid budget")
					end
				elseif entry.kind == "advance" then
					if not finite(entry.ms) or entry.ms < 0 or entry.ms > MAX_REPLAY_ADVANCE_MS then
						return invalid_trace("advance event " .. tostring(index) .. " must be within the bounded virtual-time range")
					end
					if type(options.advance_ms) ~= "function" then
						return invalid_trace("scheduler trace requires a virtual-time advance function")
					end
				else
					return invalid_trace("scheduler trace event " .. tostring(index) .. " has an unknown kind")
				end
			end
			local result = { statuses = {} }
			for index = 1, event_count do
				local entry = rawget(log, index)
				if entry.kind == "enqueue" then self:Enqueue(entry.item)
				elseif entry.kind == "complete" then self:MarkCompleted(entry.id, entry.outcome)
				elseif entry.kind == "take" then
					local item, status = self:TakeNext(entry.mode or entry.renewal_mode)
					result[#result + 1] = if item then item.id else "<empty>"
					result.statuses[#result.statuses + 1] = status or "empty"
				elseif entry.kind == "budget" then
					self:ObserveRequestBudgets(entry.read, entry.write)
				elseif entry.kind == "observe" then
					self:Observe(entry.operation_kind, entry.succeeded, entry.latency_ms, entry.error_class, entry.budget)
				elseif entry.kind == "advance" then
					local advance = options.advance_ms
					if advance ~= nil then advance(entry.ms) end
				end
			end
			return result
		end
		local function read_record_stats(record: any): EmbeddedSchedulerDynamicRecord
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
		function governor:OldestEligibleAgeMs()
			local oldest_eligible_age_ms, instant = 0, now_ms()
			for _, item in ipairs(self.queue) do
				if (item.due_at_ms or 0) <= instant
					and (item.available_at_ms == nil or item.available_at_ms <= instant)
					and dependencies_ready(self, item)
					and (item.expires_at_ms == nil or item.expires_at_ms > instant)
				then
					oldest_eligible_age_ms = math.max(oldest_eligible_age_ms, instant - item.enqueued_at_ms)
				end
			end
			return oldest_eligible_age_ms
		end

		function governor:LeaseRenewalAdvice()
			local function p95_for(operation: string): number?
				local source = self.latency_samples_by_operation[operation]
				if source == nil or #source == 0 then return nil end
				local samples = copy(source)
				table.sort(samples)
				return samples[math.clamp(math.ceil(#samples * 0.95), 1, #samples)]
			end
			return {
				lease_renewal_p95_ms = p95_for("lease_renewal"),
				update_async_p95_ms = p95_for("update_async"),
				lease_renewal_ewma_ms = self.latency_ewma.lease_renewal or 0,
				update_async_ewma_ms = self.latency_ewma.update_async or 0,
				service_ewma_ms = self.latency_ewma.service or 0,
				oldest_eligible_age_ms = self:OldestEligibleAgeMs(),
			}
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
			local function percentile(values: any, p: number): number
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
				last_budget_by_kind = copy(self.last_budget_by_kind),
				last_budget_sampled_at_by_kind = copy(self.last_budget_sampled_at_by_kind),
				retry_tokens = self.retry_tokens,
				scheduler = {
					by_lane = copy(self.scheduler_metrics.by_lane), by_lane_class = wait_by_lane_class,
					oldest_eligible_age_ms = oldest_eligible_age_ms,
					queue_wait_p50_ms = percentile(waits, 0.50), queue_wait_p95_ms = percentile(waits, 0.95),
					queue_wait_p99_ms = percentile(waits, 0.99),
					next_due_at_ms = self:NextQueuedDueAt(), due_heap_items = #self.due_heap,
					queued_due_heap_items = #self.queued_due_heap, wake_heap_items = #self.wake_heap,
					active_owner_count = key_count(self.active_owner),
					last_shadow = copy(self.scheduler_metrics.last_shadow),
				},
			}
		end
		return governor
	end


	local function get_task_api(): any
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

	local function spawn_scheduled(callback: () -> ())
		local api = get_task_api()
		if api ~= nil then api.spawn(callback) else callback() end
	end

	local function delay_scheduled(seconds: number, callback: () -> ()): thread?
		local api = get_task_api()
		if api == nil or type(api.delay) ~= "function" then return nil end
		return api.delay(seconds, callback)
	end

	local function cancel_scheduled(thread_to_cancel: thread?)
		if thread_to_cancel == nil then return end
		local api = get_task_api()
		if api ~= nil and type(api.cancel) == "function" then
			pcall(api.cancel, thread_to_cancel)
		end
	end

	local function new_dispatcher(governor: EmbeddedSchedulerDynamicRecord, options: EmbeddedSchedulerDispatcherOptions?): EmbeddedSchedulerDynamicRecord
		local dispatcher_options: EmbeddedSchedulerDispatcherOptions = options or {}
		assert(type(governor) == "table" and type(governor.Enqueue) == "function"
			and type(governor.TakeNext) == "function", "a scheduler governor is required")
		local dispatcher: EmbeddedSchedulerDynamicRecord = {
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
		local function now_ms(): number
			local clock = dispatcher_options.now_ms
			return if clock ~= nil then clock() else os.clock() * 1000
		end
		local kick_dispatcher
		local function schedule_wake_at(due_at_ms: number)
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
			if due ~= nil then
				schedule_wake_at(due)
			elseif dispatcher.wake_due_ms ~= nil or dispatcher.wake_thread ~= nil then
				dispatcher.wake_generation += 1
				cancel_scheduled(dispatcher.wake_thread)
				dispatcher.wake_thread = nil
				dispatcher.wake_due_ms = nil
			end
		end
		local function safe_result_copy(result: any): any
			local ok, copied = pcall(copy_bounded, result, MAX_SCHEDULER_COPY_NODES)
			if ok then return copied end
			return {
				code = "invalid_result",
				message = "scheduled callback returned a cyclic or excessively deep result",
			}
		end
		local function invoke_completion(entry: any, result: any)
			if type(entry) ~= "table" or type(entry.on_complete) ~= "function" then return end
			local ok, message = pcall(entry.on_complete, safe_result_copy(result))
			if not ok then
				dispatcher.metrics.callback_errors += 1
				dispatcher.metrics.last_error = string.sub(tostring(message), 1, 200)
			end
		end
		local retry_classes = { transient = true, throttled = true, conflict = true }
		local function classify_outcome(result: any, callback_ok: boolean): string
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
		local function record_outcome(result: any, callback_ok: boolean): string
			local class = classify_outcome(result, callback_ok)
			dispatcher.metrics.outcome_classes[class] = (dispatcher.metrics.outcome_classes[class] or 0) + 1
			dispatcher.metrics.last_outcome_class = class
			return class
		end
		local function retry_due(item: any, entry: any, result: any): (boolean, EmbeddedSchedulerDynamicRecord?)
			local retry_class = if type(result) == "table" and type(result.retry_class) == "string"
				then result.retry_class else "transient"
			if retry_classes[retry_class] ~= true then
				local code = if retry_class == "unknown" then "unknown" else "retry_rejected"
				return false, { code = code, message = "retry was requested with a non-retryable outcome class", retry_class = retry_class, last_result = safe_result_copy(result) }
			end
			if entry.retry_attempt >= entry.max_retries then
				return false, { code = "retry_exhausted", message = "configured retry cap reached", retry_class = retry_class, last_result = safe_result_copy(result) }
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
				local token_wait_ms = if finite(wait_ms) then math.floor(wait_ms) else 60000
				delay_ms = math.clamp(math.max(token_wait_ms, retry_after_ms), 10, 60000)
			end
			local due_at_ms = now + delay_ms
			local queued, message = governor:Reschedule(item.id, due_at_ms, true)
			if not queued then
				return false, { code = "retry_rejected", message = tostring(message or "retry admission failed"), last_result = safe_result_copy(result) }
			end
			if token then
				entry.retry_attempt += 1
				entry.retry_waiting_for_token = false
				dispatcher.metrics.retries += 1
			else
				entry.retry_waiting_for_token = true
				dispatcher.metrics.retry_deferred += 1
			end
			entry.last_result = safe_result_copy(result)
			schedule_wake_at(due_at_ms)
			return true, nil
		end
		local function terminal_result(item: any, status: string): EmbeddedSchedulerDynamicRecord
			local result = if type(item.terminal_result) == "table" then copy(item.terminal_result)
				else { code = status, message = "scheduled item reached a terminal scheduler state" }
			if status == "expired" then dispatcher.metrics.expired += 1 end
			if status == "dependency_failed" then dispatcher.metrics.dependency_failed += 1 end
			return result
		end
		local function finish_scheduled_item(item: any, status: string, entry: any, callback_ok: boolean, callback_result: any, counted_in_flight: boolean)
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
				callback_result = { code = "retry_exhausted", message = "configured retry cap reached", last_result = safe_result_copy(callback_result) }
			end
			if counted_in_flight then
				dispatcher.in_flight = math.max(0, dispatcher.in_flight - 1)
				if not uses_critical_reserve(item) then
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
				local completion_result: EmbeddedSchedulerDynamicRecord = if type(callback_result) == "table"
					then table.clone(callback_result)
					else { code = if callback_result == true or callback_result == nil then "success" else tostring(callback_result) }
				if item.overdue == true then
					completion_result.scheduler_overdue = true
					completion_result.scheduler_deadline_ms = item.deadline_ms
					completion_result.scheduler_selected_at_ms = item.selected_at_ms
				end
				invoke_completion(entry, completion_result)
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

		local function dispatch_one(item: any, status: any)
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
					local requeued, retry_error = governor:Reschedule(item.id, retry_due_at, true)
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
				if admission.terminal then
					item.terminal_result = admission
					finish_scheduled_item(item, "admission_rejected", entry, true, admission, false)
				else
					local delay_ms = if finite(admission.retry_after_ms)
						then math.clamp(math.floor(admission.retry_after_ms), 10, 60000) else 25
					local requeued, retry_error, retry_due_at = governor:Reschedule(
						item.id, math.max(now_ms() + delay_ms, item.available_at_ms or -math.huge), true
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
			if not uses_critical_reserve(item) then dispatcher.normal_in_flight += 1 end
			dispatcher.metrics.max_in_flight = math.max(dispatcher.metrics.max_in_flight, dispatcher.in_flight)
			spawn_scheduled(function()
				if dispatcher.closed or dispatcher.closing then
					finish_scheduled_item(item, "cancelled", entry, true, nil, true)
					return
				end
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
				local policy = governor.policy
				local maximum = policy.max_scheduled_in_flight
				local normal_limit = math.max(0, maximum - policy.scheduler_critical_reserve)
				while dispatcher.in_flight < maximum do
					local critical_in_flight = dispatcher.in_flight - dispatcher.normal_in_flight
					local item, status
					if critical_in_flight < policy.scheduler_critical_reserve then
						item, status = governor:TakeNext("critical")
					end
					if item == nil and dispatcher.normal_in_flight < normal_limit then
						item, status = governor:TakeNext("regular")
					end
					if item == nil then item, status = governor:TakeNext("critical") end
					if item == nil then break end
					dispatch_one(item, status)
				end
				dispatcher.running = false
				if dispatcher.in_flight < governor.policy.max_scheduled_in_flight then schedule_next_wake() end
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
			local lane = if schedule_options.lane == nil then "normal" else schedule_options.lane
			if lane ~= "high" and lane ~= "normal" and lane ~= "background" and lane ~= "lease_renewal" then
				return { code = "invalid", message = "unsupported scheduler lane" }
			end
			if schedule_options.work_class ~= nil and not valid_text(schedule_options.work_class, 64) then
				return { code = "invalid", message = "work_class must be 1..64 bytes" }
			end
			if schedule_options.operation_class ~= nil and not valid_text(schedule_options.operation_class, 64) then
				return { code = "invalid", message = "operation_class must be 1..64 bytes" }
			end
			local work_class = if schedule_options.work_class ~= nil then schedule_options.work_class
				elseif schedule_options.operation_class ~= nil then schedule_options.operation_class else "default"
			local operation_class = if schedule_options.operation_class ~= nil
				then schedule_options.operation_class else work_class
			local retry_limit = if schedule_options.max_retries == nil then 0 else schedule_options.max_retries
			local retry_delay_ms = if schedule_options.retry_delay_ms == nil then 100 else schedule_options.retry_delay_ms
			local current_policy = governor.policy
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
				or schedule_options.batch_window_ms > governor.policy.batch_window_ms)
			then
				return { code = "invalid", message = "batch_window_ms must fit the bounded scheduler window" }
			end
			self.sequence += 1
			local id = "rsjob:" .. tostring(self.sequence)
			local now = now_ms()
			local due = if finite(schedule_options.due_at_ms) then schedule_options.due_at_ms
				elseif finite(schedule_options.available_at_ms) then schedule_options.available_at_ms else now
			local batch_window = 0
			if schedule_options.batchable == true then
				batch_window = if finite(schedule_options.batch_window_ms) then schedule_options.batch_window_ms else current_policy.batch_window_ms
				local latency = math.max(governor.latency_ewma[work_class] or 0, governor.latency_ewma.outbox_dispatch or 0,
					governor.latency_ewma.write or 0, governor.latency_ewma.update_async or 0, governor.latency_ewma.service or 0)
				local budgets = governor.request_budgets
				local budget_headroom
				if finite(budgets.sampled_at_ms) and now - budgets.sampled_at_ms <= 1000 then
					budget_headroom = math.min(budgets.read or math.huge, budgets.write or math.huge)
				end
				local oldest_eligible_age_ms = governor:OldestEligibleAgeMs()
				if latency >= current_policy.batch_latency_ceiling_ms
					or (finite(budget_headroom) and budget_headroom < current_policy.minimum_budget)
					or (finite(oldest_eligible_age_ms) and oldest_eligible_age_ms >= batch_window)
				then
					batch_window = 0
				elseif latency >= current_policy.batch_latency_ceiling_ms * 0.75 then
					batch_window = math.floor(batch_window / 2)
				elseif batch_backlog < batch_size then
					batch_window = math.min(batch_window, 2)
				end
			end
			if finite(schedule_options.deadline_ms) then
				batch_window = math.min(batch_window, math.max(0, schedule_options.deadline_ms - now))
			end
			due = math.max(due, now + batch_window)
			if finite(schedule_options.available_at_ms) then due = math.max(due, schedule_options.available_at_ms) end
			if finite(schedule_options.expires_at_ms) and due >= schedule_options.expires_at_ms then due = schedule_options.expires_at_ms end
			local item = {
				id = id, owner_id = owner_id, lane = lane, due_at_ms = due,
				available_at_ms = schedule_options.available_at_ms, deadline_ms = schedule_options.deadline_ms,
				expires_at_ms = schedule_options.expires_at_ms, service_class = schedule_options.service_class,
				work_class = work_class, operation_class = operation_class,
				dependencies = schedule_options.dependencies, read_units = schedule_options.read_units,
				write_units = schedule_options.write_units, estimated_bytes = schedule_options.estimated_bytes,
				handler_slots = schedule_options.handler_slots, cost = schedule_options.cost,
				mutating = schedule_options.mutating, batchable = schedule_options.batchable == true,
				batch_size = if schedule_options.batchable == true then batch_size else nil,
				batch_backlog = if schedule_options.batchable == true then batch_backlog else nil,
			}
			local accepted = governor:Enqueue(item, true)
			if type(accepted) ~= "table" or accepted.code ~= "accepted" then
				self.metrics.rejected += 1
				return { code = if type(accepted) == "table" then accepted.code else "unknown",
					message = if type(accepted) == "table" then accepted.message else "scheduler rejected work" }
			end
			self.callbacks[id] = {
				callback = callback, on_complete = schedule_options.on_complete,
				work_id = work_id, work_class = work_class,
				operation_class = operation_class,
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
			local function percentile(p: number): number
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

	local function create_governor(options: EmbeddedSchedulerOptions?): EmbeddedSchedulerGovernor
		return (new_governor(options) :: unknown) :: EmbeddedSchedulerGovernor
	end

	local function create_dispatcher(governor: EmbeddedSchedulerGovernor, options: EmbeddedSchedulerDispatcherOptions?): EmbeddedSchedulerDispatcher
		local internal_governor = (governor :: unknown) :: EmbeddedSchedulerDynamicRecord
		return (new_dispatcher(internal_governor, options) :: unknown) :: EmbeddedSchedulerDispatcher
	end

	Scheduler.new = create_governor
	Scheduler.new_dispatcher = create_dispatcher

end
-- END EMBEDDED SCHEDULER MODULE

-- BEGIN EMBEDDED MAILBOX V2 MODULE
local MailboxV2 = {}
MailboxV2.__index = MailboxV2
type EmbeddedMailboxDict = { [string]: unknown }
type EmbeddedMailboxOwner = {
	store_name: string,
	scope: string,
	profile_key: string,
	user_id: number?,
}
type EmbeddedMailboxActiveRecordLike = {
	GetIdentity: (self: EmbeddedMailboxActiveRecordLike) -> EmbeddedMailboxDict,
	IsOpen: (self: EmbeddedMailboxActiveRecordLike) -> boolean,
	GetState: (self: EmbeddedMailboxActiveRecordLike) -> string,
	Stats: (self: EmbeddedMailboxActiveRecordLike) -> EmbeddedMailboxDict,
}
type EmbeddedMailboxStoreAdapter = {
	GetAsync: (self: EmbeddedMailboxStoreAdapter, key: string) -> unknown,
	GetAsyncFresh: ((self: EmbeddedMailboxStoreAdapter, key: string) -> unknown)?,
	UpdateAsync: (self: EmbeddedMailboxStoreAdapter, key: string, transform: (unknown, unknown?) -> (unknown, { number }?, EmbeddedMailboxDict?)) -> unknown,
	RemoveAsync: ((self: EmbeddedMailboxStoreAdapter, key: string) -> ())?,
}
type EmbeddedMailboxWakeupAdapter = {
	Publish: (self: EmbeddedMailboxWakeupAdapter, owner_identity: string, reason: string) -> EmbeddedMailboxDict,
}
type EmbeddedMailboxOptions = {
	active_record: EmbeddedMailboxActiveRecordLike?,
	wakeups: EmbeddedMailboxWakeupAdapter?,
	sender_job_id: string?,
	now_ms: (() -> number)?,
	guid: (() -> string)?,
	encode: ((unknown) -> string)?,
	max_segments: number?,
	segment_max_messages: number?,
	max_payload_bytes: number?,
	max_request_bytes: number?,
	preparation_shard_count: number?,
	preparation_max_entries_per_shard: number?,
	preparation_max_entry_bytes: number?,
	dlq_max_segments: number?,
	dlq_segment_max_messages: number?,
	lease_ms: number?,
	lease_renewal_horizon_ms: number?,
	clock_skew_grace_ms: number?,
	max_attempts: number?,
	retry_base_ms: number?,
	retry_max_ms: number?,
	priority_aging_ms: number?,
	high_priority_burst: number?,
	strict_ordering_enabled: boolean?,
	lease_renewal_scheduler: ((string, number, number, () -> unknown, (unknown) -> ()) -> unknown)?,
	activation_guard: ((string) -> (boolean, string?))?,
	allow_unattested_activation: boolean?,
}
type EmbeddedMailboxLocator = { slot: number, generation: number, key: string }
type EmbeddedMailboxResult = {
	code: string,
	message_id: string?,
	message: EmbeddedMailboxDict?,
	error: string?,
}
type EmbeddedMailboxHandlerContext = {
	is_cancelled: () -> boolean,
	cancellation_reason: () -> string?,
	renew_lease_async: () -> EmbeddedMailboxResult,
}
type EmbeddedMailbox = typeof(setmetatable({} :: {
	store: EmbeddedMailboxStoreAdapter,
	owner: EmbeddedMailboxOwner,
	owner_text: string,
	sender_job_id: string,
	options: EmbeddedMailboxOptions,
	processing: boolean,
	high_priority_streak: number,
	wakeup_published: number,
	wakeup_publish_errors: number,
}, MailboxV2))
do
	local VERSION = 2
	local MAX_KEY_LENGTH = 50
	local DEFAULT_MAX_SEGMENTS = 64
	local DEFAULT_SEGMENT_MAX_MESSAGES = 32
	local DEFAULT_PREPARATION_SHARDS = 16
	local DEFAULT_PREPARATION_ENTRIES = 16
	local DEFAULT_PREPARATION_ENTRY_BYTES = 131072
	local DEFAULT_MAX_PAYLOAD_BYTES = 65536
	local DEFAULT_MAX_REQUEST_BYTES = 131072
	local DEFAULT_DLQ_MAX_SEGMENTS = 64
	local DEFAULT_DLQ_SEGMENT_MAX_MESSAGES = 32
	local DEFAULT_LEASE_MS = 60000
	local DEFAULT_CLOCK_SKEW_GRACE_MS = 5000
	local DEFAULT_MAX_ATTEMPTS = 5
	local DEFAULT_RETRY_BASE_MS = 1000
	local DEFAULT_RETRY_MAX_MS = 60000
	local DEFAULT_PRIORITY_AGING_MS = 60000
	local DEFAULT_HIGH_PRIORITY_BURST = 4
	local MAX_ORDERING_KEY_LENGTH = 256

	local resolved_task_api = false
	local cached_task_api: any = nil
	local function task_api(): any
		if resolved_task_api then return cached_task_api end
		resolved_task_api = true
		local global_ok, global_value = pcall(function() return task end)
		if global_ok and type(global_value) == "table"
			and type(global_value.spawn) == "function" and type(global_value.wait) == "function"
		then
			cached_task_api = global_value
			return cached_task_api
		end
		local module_ok, module_value = pcall(require, "@lune/task")
		if module_ok and type(module_value) == "table"
			and type(module_value.spawn) == "function" and type(module_value.wait) == "function"
		then
			cached_task_api = module_value
		end
		return cached_task_api
	end
	local function spawn_scheduled(callback: () -> ())
		local api = task_api()
		if api ~= nil then api.spawn(callback) else callback() end
	end
	local function wait_scheduled(seconds: number)
		local api = task_api()
		if api ~= nil then api.wait(seconds) end
	end

	local TERMINAL = {
		acknowledged = true,
		dead_lettered = true,
		discarded = true,
		expired = true,
	}

	local function is_finite(value: unknown): boolean
		return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
	end

	local function valid_text(value: unknown, maximum: number): boolean
		return type(value) == "string" and value ~= "" and #value <= maximum
	end

	local function as_dict(value: unknown): EmbeddedMailboxDict?
		if type(value) == "table" then
			return value :: EmbeddedMailboxDict
		end
		return nil
	end

	local function clone_json(value: unknown, depth: number?): unknown
		local level = depth or 0
		if level > 64 then
			error("value exceeds the supported nesting depth", 2)
		end
		if type(value) ~= "table" then
			return value
		end
		local result: { [string | number]: unknown } = {}
		for key, child in value :: any do
			if type(key) ~= "string" and (type(key) ~= "number" or not is_finite(key)) then
				error("JSON object keys must be strings and array keys must be finite numbers", 2)
			end
			local result_key: string | number = if type(key) == "string" then key else key :: number
			result[result_key] = clone_json(child, level + 1)
		end
		return result
	end

	local function canonical(value: unknown, stack: { [any]: boolean }?, depth: number?): string
		local active: { [any]: boolean } = stack or {}
		local level = depth or 0
		if level > 64 then
			error("value exceeds the supported nesting depth", 2)
		end
		local kind = type(value)
		if value == nil then
			return "n"
		elseif kind == "boolean" then
			return if value then "b1" else "b0"
		elseif kind == "number" then
			local number_value = value :: number
			if not is_finite(number_value) then error("non-finite numbers are not valid mailbox payloads", 2) end
			return "d" .. (if number_value == 0 then "0" else string.format("%.17g", number_value))
		elseif kind == "string" then
			local string_value = value :: string
			return "s" .. tostring(#string_value) .. ":" .. string_value
		elseif kind ~= "table" then
			error("mailbox values must contain only JSON-compatible scalars and tables", 2)
		end

		local table_value = value :: { [string | number]: unknown }
		if active[table_value] then
			error("cyclic tables are not valid mailbox payloads", 2)
		end
		active[table_value] = true
		local source: { [string | number]: unknown } = table_value
		local count = 0
		local max_array_index = 0
		local array_only = true
		for key in source do
			count += 1
			if type(key) == "number" and is_finite(key) and key >= 1 and key == math.floor(key) then
				max_array_index = math.max(max_array_index, key)
			else
				array_only = false
			end
		end
		if array_only and max_array_index == count and count > 0 then
			local parts = table.create(count)
			for index = 1, count do
				parts[index] = canonical(source[index], active, level + 1)
			end
			active[table_value] = nil
			return "a" .. tostring(count) .. "[" .. table.concat(parts, "") .. "]"
		end

		local keys: { string } = {}
		for key in source do
			if type(key) ~= "string" then
				active[table_value] = nil
				error("mixed or sparse arrays are not valid mailbox objects", 2)
			end
			table.insert(keys, key)
		end
		table.sort(keys)
		local parts = table.create(#keys)
		for index, key in keys do
			parts[index] = canonical(key, active, level + 1) .. canonical(source[key], active, level + 1)
		end
		active[table_value] = nil
		return "o" .. tostring(#keys) .. "{" .. table.concat(parts, "") .. "}"
	end

	local function digest(value: string): string
		local result = table.create(4)
		for seed_index = 1, 4 do
			local hash = 2166136261 + seed_index * 7919
			for index = 1, #value do
				hash = (string.byte(value, index) + hash * 65599) % 4294967296
			end
			result[seed_index] = string.format("%08x", hash)
		end
		return table.concat(result, "")
	end

	local function now_default(): number
		local success, value = pcall(function()
			return DateTime.now().UnixTimestampMillis
		end)
		if success and is_finite(value) then
			return value
		end
		return os.time() * 1000
	end

	local function ok(code: string, message_id: string?, message: EmbeddedMailboxDict?, error_message: string?): EmbeddedMailboxResult
		local message_dict = as_dict(message)
		if message_dict ~= nil then
			local public_id = if type(message_dict.Id) == "string" then message_dict.Id else message_dict.public_id
			if type(public_id) == "string" then message_id = public_id end
		end
		return { code = code, message_id = message_id, message = message, error = error_message }
	end

	local function storage_error_code(error_message: string): string
		if string.find(error_message, "unsupported schema version", 1, true) ~= nil then
			return "unsupported_schema"
		end
		return "unknown"
	end

	local function clone_owner(owner: EmbeddedMailboxOwner): EmbeddedMailboxOwner
		return {
			store_name = owner.store_name,
			scope = owner.scope,
			profile_key = owner.profile_key,
			user_id = owner.user_id,
		}
	end

	local function valid_owner(owner: unknown): (EmbeddedMailboxOwner?, string?)
		local value = as_dict(owner)
		if value == nil
			or type(value.store_name) ~= "string" or value.store_name == "" or #value.store_name > 50
			or type(value.scope) ~= "string" or value.scope == "" or #value.scope > 50
			or type(value.profile_key) ~= "string" or value.profile_key == "" or #value.profile_key > 50
		then
			return nil, "owner requires store_name, scope and profile_key of 1 to 50 characters"
		end
		if value.user_id ~= nil and (not is_finite(value.user_id) or (value.user_id :: number) < 1 or (value.user_id :: number) ~= math.floor(value.user_id :: number)) then
			return nil, "user_id must be a positive integer when supplied"
		end
		return {
			store_name = value.store_name :: string,
			scope = value.scope :: string,
			profile_key = value.profile_key :: string,
			user_id = value.user_id :: number?,
		}, nil
	end

	local function same_owner(left: unknown, right: EmbeddedMailboxOwner): boolean
		local left_dict = as_dict(left)
		return left_dict ~= nil
			and left_dict.store_name == right.store_name
			and left_dict.scope == right.scope
			and left_dict.profile_key == right.profile_key
			and left_dict.user_id == right.user_id
	end

	local function result_route_key(self: EmbeddedMailbox, prefix: string, identity: string): string
		local full_digest = digest(self.owner_text .. "|" .. identity)
		local key = if self.owner.user_id ~= nil
			then prefix .. tostring(self.owner.user_id) .. "-" .. string.sub(full_digest, 1, 24)
			else prefix .. full_digest
		assert(#key <= MAX_KEY_LENGTH, "internal key codec exceeded the DataStore key limit")
		return key
	end

	local function route_shard(self: EmbeddedMailbox, route: string): number
		local value = tonumber(string.sub(digest(self.owner_text .. "|" .. route), 1, 8), 16) or 0
		return (value % (self.options.preparation_shard_count or DEFAULT_PREPARATION_SHARDS)) + 1
	end

	local function prefix_for_kind(kind: string): (string, string)
		if kind == "active" then
			return "mf2-", "si2-"
		end
		return "md2-", "di2-"
	end

	local function locate_slot(manifest: EmbeddedMailboxDict, slot_number: number): EmbeddedMailboxDict?
		local slots = manifest.slots
		if type(slots) ~= "table" then
			return nil
		end
		return as_dict((slots :: { unknown })[slot_number])
	end

	local function clone_dict(source: EmbeddedMailboxDict): EmbeddedMailboxDict
		return clone_json(source) :: EmbeddedMailboxDict
	end

	local function has_row(segment: EmbeddedMailboxDict, route: string, placement_generation: number): boolean
		local entries = segment.entries
		if type(entries) ~= "table" then
			return false
		end
		for _, entry in entries :: { unknown } do
			local row = as_dict(entry)
			if row ~= nil and row.route == route and row.placement_generation == placement_generation then
				return true
			end
		end
		return false
	end

	function MailboxV2.new(store: unknown, owner_value: EmbeddedMailboxOwner, options_value: EmbeddedMailboxOptions?): EmbeddedMailbox
		local owner, owner_error = valid_owner(owner_value)
		if owner == nil then
			error(owner_error or "invalid owner", 2)
		end
		if type(store) ~= "table"
			or type((store :: EmbeddedMailboxDict).GetAsync) ~= "function"
			or type((store :: EmbeddedMailboxDict).UpdateAsync) ~= "function"
		then
			error("store must implement GetAsync and UpdateAsync", 2)
		end
		local options = table.clone(options_value or {}) :: EmbeddedMailboxOptions
		if options.now_ms ~= nil and type(options.now_ms) ~= "function" then
			error("options.now_ms must be a function returning finite milliseconds", 2)
		end
		if options.guid ~= nil and type(options.guid) ~= "function" then
			error("options.guid must be a function returning a non-empty string of at most 256 bytes", 2)
		end
		if options.lease_renewal_scheduler ~= nil and type(options.lease_renewal_scheduler) ~= "function" then
			error("options.lease_renewal_scheduler must be a function", 2)
		end
		if type(options.encode) ~= "function" then
			error("options.encode must provide the exact serialized representation used by the DataStore adapter", 2)
		end
		if type(options.activation_guard) ~= "function" and options.allow_unattested_activation ~= true then
			error("mailbox v2 requires activation_guard; allow_unattested_activation=true is reserved for isolated tests or explicitly unsafe staging", 2)
		end
		options.max_segments = options.max_segments or DEFAULT_MAX_SEGMENTS
		options.segment_max_messages = options.segment_max_messages or DEFAULT_SEGMENT_MAX_MESSAGES
		options.max_payload_bytes = options.max_payload_bytes or DEFAULT_MAX_PAYLOAD_BYTES
		options.max_request_bytes = options.max_request_bytes or DEFAULT_MAX_REQUEST_BYTES
		options.preparation_shard_count = options.preparation_shard_count or DEFAULT_PREPARATION_SHARDS
		options.preparation_max_entries_per_shard = options.preparation_max_entries_per_shard or DEFAULT_PREPARATION_ENTRIES
		options.preparation_max_entry_bytes = options.preparation_max_entry_bytes or DEFAULT_PREPARATION_ENTRY_BYTES
		options.dlq_max_segments = options.dlq_max_segments or DEFAULT_DLQ_MAX_SEGMENTS
		options.dlq_segment_max_messages = options.dlq_segment_max_messages or DEFAULT_DLQ_SEGMENT_MAX_MESSAGES
		options.lease_ms = options.lease_ms or DEFAULT_LEASE_MS
		options.lease_renewal_horizon_ms = options.lease_renewal_horizon_ms or (options.lease_ms :: number) * 4
		options.clock_skew_grace_ms = options.clock_skew_grace_ms or DEFAULT_CLOCK_SKEW_GRACE_MS
		options.max_attempts = options.max_attempts or DEFAULT_MAX_ATTEMPTS
		options.retry_base_ms = options.retry_base_ms or DEFAULT_RETRY_BASE_MS
		options.retry_max_ms = options.retry_max_ms or DEFAULT_RETRY_MAX_MS
		options.priority_aging_ms = options.priority_aging_ms or DEFAULT_PRIORITY_AGING_MS
		if options.high_priority_burst == nil then
			options.high_priority_burst = DEFAULT_HIGH_PRIORITY_BURST
		end
		if options.strict_ordering_enabled ~= nil and type(options.strict_ordering_enabled) ~= "boolean" then
			error("strict_ordering_enabled must be a boolean", 2)
		end
		options.strict_ordering_enabled = options.strict_ordering_enabled == true
		if options.strict_ordering_enabled and type((store :: EmbeddedMailboxDict).GetAsyncFresh) ~= "function" then
			error("strict_ordering_enabled requires store:GetAsyncFresh(key) to bypass stale DataStore caches", 2)
		end
		local numeric_options = {
			"max_segments", "segment_max_messages", "max_payload_bytes", "max_request_bytes",
			"preparation_shard_count", "preparation_max_entries_per_shard", "preparation_max_entry_bytes",
			"dlq_max_segments", "dlq_segment_max_messages", "lease_ms", "lease_renewal_horizon_ms", "clock_skew_grace_ms",
			"max_attempts", "retry_base_ms", "retry_max_ms", "priority_aging_ms", "high_priority_burst",
		}
		for _, key in numeric_options do
			local value = ((options :: unknown) :: EmbeddedMailboxDict)[key]
			if not is_finite(value) or (value :: number) < 1 or (value :: number) ~= math.floor(value :: number) then
				error(key .. " must be a positive integer", 2)
			end
		end
		if (options.max_segments :: number) > 64 or (options.dlq_max_segments :: number) > 64 then
			error("initial v2 segment bounds may not exceed 64 slots", 2)
		end
		if (options.segment_max_messages :: number) > 32 or (options.dlq_segment_max_messages :: number) > 32 then
			error("initial v2 segment bounds may not exceed 32 rows per segment", 2)
		end
		if (options.lease_renewal_horizon_ms :: number) < (options.lease_ms :: number) then
			error("lease_renewal_horizon_ms must be at least lease_ms", 2)
		end
		if (options.high_priority_burst :: number) > 32 then
			error("high_priority_burst may not exceed 32", 2)
		end
		local sender_job_id = options.sender_job_id
		if sender_job_id == nil then
			local job_ok, job_id = pcall(function() return game.JobId end)
			sender_job_id = if job_ok and type(job_id) == "string" then job_id else ""
		end
		if type(sender_job_id) ~= "string" or #sender_job_id > 128 then error("sender_job_id must be a string of at most 128 bytes", 2) end
		local self = {
			store = store :: EmbeddedMailboxStoreAdapter,
			owner = owner,
			owner_text = canonical(owner),
			sender_job_id = sender_job_id,
			options = options,
			processing = false,
			high_priority_streak = 0,
			wakeup_published = 0,
			wakeup_publish_errors = 0,
		}
		return setmetatable(self, MailboxV2) :: EmbeddedMailbox
	end


	function MailboxV2._check_activation(self: EmbeddedMailbox, operation: string): EmbeddedMailboxResult?
		if self.options.allow_unattested_activation == true then return nil end
		local guard = self.options.activation_guard
		if type(guard) ~= "function" then
			return ok("disabled", nil, nil, "mailbox v2 has no authoritative rollout activation guard")
		end
		local call_ok, allowed, message = pcall(guard, operation)
		if not call_ok then
			return ok("unknown", nil, nil, "rollout activation guard failed: " .. tostring(allowed))
		end
		if allowed ~= true then
			return ok("disabled", nil, nil, tostring(message or ("rollout gate denied " .. operation)))
		end
		return nil
	end

	function MailboxV2._now(self: EmbeddedMailbox): number
		local value = if self.options.now_ms ~= nil then self.options.now_ms() else now_default()
		if not is_finite(value) then
			error("options.now_ms must return finite milliseconds", 2)
		end
		return value
	end

	function MailboxV2._guid(self: EmbeddedMailbox): (string?, string?)
		local value
		if self.options.guid == nil then
			local call_ok, generated = pcall(function()
				return game:GetService("HttpService"):GenerateGUID(false)
			end)
			if not call_ok then
				return nil, "HttpService:GenerateGUID(false) failed: " .. tostring(generated)
			end
			value = generated
		else
			local call_ok, generated = pcall(self.options.guid)
			if not call_ok then
				return nil, "options.guid raised: " .. tostring(generated)
			end
			value = generated
		end
		if type(value) ~= "string" or value == "" or #value > 256 then
			return nil, "GUID provider must return a non-empty string of at most 256 bytes"
		end
		return value, nil
	end

	function MailboxV2._encode_size(self: EmbeddedMailbox, value: unknown): (number?, string?)
		if self.options.encode == nil then
			return nil, "a production-compatible encoded-size callback is required"
		end
		local success, result = pcall(function()
			return (self.options.encode :: (unknown) -> string)(value)
		end)
		if not success or type(result) ~= "string" then
			return nil, "value is not serializable"
		end
		return #result, nil
	end

	function MailboxV2._get(self: EmbeddedMailbox, key: string): (unknown, string?)
		local success, value = pcall(function()
			return self.store:GetAsync(key)
		end)
		if not success then
			return nil, tostring(value)
		end
		return value, nil
	end

	function MailboxV2._get_fresh(self: EmbeddedMailbox, key: string): (unknown, string?)
		local fresh_get = self.store.GetAsyncFresh
		if type(fresh_get) ~= "function" then
			return nil, "store does not provide an authoritative uncached read"
		end
		local success, value = pcall(function()
			return (fresh_get :: (any, string) -> unknown)(self.store, key)
		end)
		if not success then
			return nil, tostring(value)
		end
		return value, nil
	end

	function MailboxV2._update(self: EmbeddedMailbox, key: string, transform: (unknown) -> unknown): (unknown, string?)
		local success, value = pcall(function()
			return self.store:UpdateAsync(key, function(raw: unknown, key_info: any)
				local next_value = transform(raw)
				if key_info ~= nil then
					return next_value, key_info:GetUserIds(), key_info:GetMetadata()
				end
				return next_value
			end)
		end)
		if not success then
			return nil, tostring(value)
		end
		return value, nil
	end

	function MailboxV2._route_key(self: EmbeddedMailbox, idempotency_key: string?): (string?, string?)
		if idempotency_key ~= nil then
			if type(idempotency_key) ~= "string" or idempotency_key == "" or #idempotency_key > 256 then
				return nil, "idempotency_key must be 1 to 256 bytes"
			end
			return result_route_key(self, "m2i-", "producer:" .. idempotency_key), nil
		end
		local guid, guid_error = self:_guid()
		if guid == nil then
			return nil, guid_error
		end
		return result_route_key(self, "m2g-", "generated:" .. guid), nil
	end

	function MailboxV2._legacy_route_key(self: EmbeddedMailbox, legacy_id: string): string
		return result_route_key(self, "m2l-", "legacy-v3:" .. legacy_id)
	end

	function MailboxV2._route_from_public_id(self: EmbeddedMailbox, message_id: string): string
		local prefix = string.sub(message_id, 1, 4)
		if prefix == "m2i-" or prefix == "m2g-" or prefix == "m2l-" then
			return message_id
		end
		return self:_legacy_route_key(message_id)
	end

	function MailboxV2._manifest_key(self: EmbeddedMailbox, kind: string): string
		local manifest_prefix = prefix_for_kind(kind)
		return result_route_key(self, manifest_prefix, "manifest:" .. kind)
	end

	function MailboxV2._segment_key(self: EmbeddedMailbox, kind: string, slot: number, generation: number): string
		local _, segment_prefix = prefix_for_kind(kind)
		return result_route_key(self, segment_prefix, kind .. ":" .. tostring(slot) .. ":" .. tostring(generation))
	end

	function MailboxV2._registry_key(self: EmbeddedMailbox, shard: number): string
		return result_route_key(self, "pr2-", "preparation-shard:" .. tostring(shard))
	end

	function MailboxV2._fresh_manifest(self: EmbeddedMailbox, kind: string): EmbeddedMailboxDict
		local max_slots = if kind == "active" then self.options.max_segments :: number else self.options.dlq_max_segments :: number
		local slots = table.create(max_slots)
		for index = 1, max_slots do
			slots[index] = { generation = 0, state = "empty" }
		end
		return {
			version = VERSION,
			kind = kind,
			owner = clone_owner(self.owner),
			slots = slots,
		}
	end

	function MailboxV2._get_manifest(self: EmbeddedMailbox, kind: string): (EmbeddedMailboxDict?, string?)
		local key = self:_manifest_key(kind)
		local current, read_error = self:_get(key)
		if read_error == nil and current ~= nil then
			local manifest = as_dict(current)
			if manifest == nil then
				return nil, "manifest is malformed"
			end
			if not same_owner(manifest.owner, self.owner) then
				return nil, "manifest belongs to another owner"
			end
			if manifest.version ~= VERSION then
				return nil, "unsupported schema version: manifest version is unsupported"
			end
			if manifest.kind ~= kind or type(manifest.slots) ~= "table" then
				return nil, "manifest is malformed"
			end
			return manifest, nil
		end
		local initial = self:_fresh_manifest(kind)
		local written, write_error = self:_update(key, function(raw)
			if raw == nil then
				return initial
			end
			-- A racing writer already created this key. Cancel rather than
			-- re-persisting an envelope that might belong to a newer schema.
			return nil
		end)
		if write_error ~= nil then
			return nil, "manifest initialization outcome is unknown: " .. write_error
		end
		local manifest = as_dict(written)
		if manifest == nil then
			local latest_value, latest_error = self:_get_fresh(key)
			if latest_error ~= nil then
				return nil, "manifest initialization outcome is unknown: " .. latest_error
			end
			if latest_value ~= nil and as_dict(latest_value) == nil then
				return nil, "manifest is malformed"
			end
			manifest = as_dict(latest_value)
		end
		if manifest == nil then
			return nil, "manifest initialization was cancelled and no manifest is visible"
		end
		if not same_owner(manifest.owner, self.owner) then
			return nil, "manifest belongs to another owner"
		end
		if manifest.version ~= VERSION then
			return nil, "unsupported schema version: manifest version is unsupported"
		end
		if manifest.kind ~= kind or type(manifest.slots) ~= "table" then
			return nil, "manifest is malformed"
		end
		return manifest, nil
	end

	function MailboxV2._set_slot_state(self: EmbeddedMailbox, kind: string, locator: EmbeddedMailboxLocator, expected_state: string, next_state: string, allocation_token: string?): boolean
		local key = self:_manifest_key(kind)
		local updated, update_error = self:_update(key, function(raw)
			local manifest = as_dict(raw)
			if manifest == nil or manifest.version ~= VERSION or not same_owner(manifest.owner, self.owner) then
				if manifest ~= nil and manifest.version ~= VERSION then return nil end
				return raw
			end
			local next_manifest = clone_dict(manifest)
			local slot = locate_slot(next_manifest, locator.slot)
			if slot == nil or slot.generation ~= locator.generation or slot.state ~= expected_state then
				return raw
			end
			if allocation_token ~= nil and slot.allocation_token ~= allocation_token then
				return raw
			end
			local next_slot = clone_dict(slot)
			next_slot.state = next_state
			next_slot.allocation_token = nil
			(next_manifest.slots :: { unknown })[locator.slot] = next_slot
			return next_manifest
		end)
		if update_error ~= nil then
			return false
		end
		local manifest = as_dict(updated)
		local slot = if manifest ~= nil then locate_slot(manifest, locator.slot) else nil
		return slot ~= nil and slot.generation == locator.generation and slot.state == next_state
	end

	function MailboxV2._finish_allocation(self: EmbeddedMailbox, kind: string, locator: EmbeddedMailboxLocator, token: string): (EmbeddedMailboxLocator?, string?)
		local segment_template: EmbeddedMailboxDict = {
			version = VERSION,
			kind = kind,
			owner = clone_owner(self.owner),
			slot = locator.slot,
			generation = locator.generation,
			state = "open",
			entries = {},
		}
		local segment, segment_error = self:_update(locator.key, function(raw)
			if raw == nil then
				return segment_template
			end
			local existing = as_dict(raw)
			if existing == nil or existing.version ~= VERSION then
				return nil
			end
			if existing.kind ~= kind or existing.slot ~= locator.slot
				or existing.generation ~= locator.generation or not same_owner(existing.owner, self.owner)
			then
				return nil
			end
			return raw
		end)
		if segment_error ~= nil then
			return nil, "segment allocation outcome is unknown: " .. segment_error
		end
		local segment_dict = as_dict(segment)
		if segment_dict == nil then
			local latest_value, latest_error = self:_get_fresh(locator.key)
			if latest_error ~= nil then
				return nil, "segment allocation outcome is unknown: " .. latest_error
			end
			if latest_value ~= nil and as_dict(latest_value) == nil then
				return nil, "segment allocation collided with malformed data"
			end
			segment_dict = as_dict(latest_value)
		end
		if segment_dict ~= nil and segment_dict.version ~= VERSION then
			return nil, "unsupported schema version: segment version is unsupported"
		end
		if segment_dict == nil or segment_dict.kind ~= kind or segment_dict.slot ~= locator.slot
			or segment_dict.generation ~= locator.generation or not same_owner(segment_dict.owner, self.owner)
		then
			return nil, "segment allocation collided with a different owner or generation"
		end
		local published = self:_set_slot_state(kind, locator, "allocating", "open", token)
		if not published then
			local latest_manifest = self:_get_manifest(kind)
			local slot = if latest_manifest ~= nil then locate_slot(latest_manifest, locator.slot) else nil
			if slot == nil or slot.generation ~= locator.generation or slot.state ~= "open" then
				return nil, "segment was initialized but its manifest publication is unknown"
			end
		end
		return locator, nil
	end

	function MailboxV2._reclaim_slot(self: EmbeddedMailbox, kind: string): boolean
		local manifest, _manifest_error = self:_get_manifest(kind)
		if manifest == nil then
			return false
		end
		local slots = manifest.slots :: { unknown }

		local function release_draining_slot(slot_number: number, generation: number): boolean
			local updated, update_error = self:_update(self:_manifest_key(kind), function(raw)
				local current = as_dict(raw)
				if current == nil then return raw end
				if current.version ~= VERSION then return nil end
				if not same_owner(current.owner, self.owner) then return nil end
				local next_manifest = clone_dict(current)
				local slot = locate_slot(next_manifest, slot_number)
				if slot == nil or slot.generation ~= generation or slot.state ~= "draining" then
					return raw
				end
				local next_slot = clone_dict(slot)
				next_slot.state = "empty"
				next_slot.allocation_token = nil
				(next_manifest.slots :: { unknown })[slot_number] = next_slot
				return next_manifest
			end)
			if update_error ~= nil then
				return false
			end
			local next_manifest = as_dict(updated)
			local next_slot = if next_manifest ~= nil then locate_slot(next_manifest, slot_number) else nil
			return next_slot ~= nil and next_slot.generation == generation and next_slot.state == "empty"
		end

		local function rows_are_safe(segment: EmbeddedMailboxDict, locator: EmbeddedMailboxLocator): boolean
			if segment.version ~= VERSION or segment.kind ~= kind or segment.slot ~= locator.slot
				or segment.generation ~= locator.generation or not same_owner(segment.owner, self.owner)
			then
				return false
			end
			local entries = segment.entries
			if type(entries) ~= "table" then
				return false
			end
			for _, raw_row in entries :: { unknown } do
				local row = as_dict(raw_row)
				if row == nil then
					return false
				end
				local record_value, record_error = self:_get_fresh(tostring(row.route))
				local record = as_dict(record_value)
				if record_error ~= nil or record == nil or not same_owner(record.owner, self.owner) then
					return false
				end
				if kind == "active" then
					local active_locator = as_dict(record.locator)
					local same_generation = record.placement_generation == row.placement_generation
					local same_location = active_locator == nil
						or (active_locator.slot == locator.slot and active_locator.generation == locator.generation)
					local terminal = record.state == "acknowledged" or record.state == "dead_lettered"
						or record.state == "discarded" or record.state == "expired"
					if same_generation and same_location and not terminal then
						-- A matching generation without a published locator can be a
						-- partially prepared placement. Do not reclaim it as stale.
						return false
					end
					if record.state == "replaying" and same_generation then
						return false
					end
				elseif record.state == "replaying"
					or (record.state == "dead_lettered" and record.dlq_placement_generation == row.placement_generation)
				then
					return false
				end
			end
			return true
		end

		for slot_number, raw_slot in slots do
			local slot = as_dict(raw_slot)
			if slot ~= nil and (slot.state == "sealed" or slot.state == "draining") then
				local generation = slot.generation :: number
				local locator: EmbeddedMailboxLocator = {
					slot = slot_number,
					generation = generation,
					key = self:_segment_key(kind, slot_number, generation),
				}
				local segment_value, segment_error = self:_get(locator.key)
				if segment_error ~= nil then
					return false
				end
				local segment = as_dict(segment_value)

				if slot.state == "draining" and segment == nil then
					if release_draining_slot(slot_number, generation) then
						return true
					end
					return false
				end
				if segment ~= nil and segment.generation == generation and same_owner(segment.owner, self.owner)
					and segment.version ~= VERSION
				then
					return false
				end
				if segment == nil or segment.generation ~= generation
					or not same_owner(segment.owner, self.owner)
					or segment.version ~= VERSION or segment.kind ~= kind
					or segment.slot ~= slot_number
					or (segment.state ~= "sealed" and segment.state ~= "retired")
				then
					continue
				end

				local safe = rows_are_safe(segment, locator)
				if not safe then
					continue
				end
				if slot.state == "sealed" then
					if not self:_set_slot_state(kind, locator, "sealed", "draining") then
						continue
					end
				end

				if segment.state == "sealed" then
					local expected_entries = canonical(segment.entries)
					local retired, retire_error = self:_update(locator.key, function(raw)
						local current = as_dict(raw)
						if current == nil then return nil end
						if current.version ~= VERSION then return nil end
						if current.kind ~= kind or current.slot ~= slot_number
							or current.generation ~= generation or current.state ~= "sealed"
							or not same_owner(current.owner, self.owner)
						then
							return nil
						end
						-- A new append after the safety scan invalidates this retirement.
						if canonical(current.entries) ~= expected_entries then return nil end
						local next_segment = clone_dict(current)
						next_segment.state = "retired"
						return next_segment
					end)
					local retired_segment = as_dict(retired)
					if retire_error ~= nil or retired_segment == nil
						or retired_segment.generation ~= generation or retired_segment.state ~= "retired"
					then
						return false
					end
				end

				local storage_remove = self.store.RemoveAsync
				if storage_remove == nil then
					return false
				end
				pcall(function()
					storage_remove(self.store, locator.key)
				end)
				local after_remove, verify_error = self:_update(locator.key, function(raw)
					return raw
				end)
				if verify_error ~= nil or after_remove ~= nil then
					return false
				end
				if release_draining_slot(slot_number, generation) then
					return true
				end
				return false
			end
		end
		return false
	end

	function MailboxV2._open_segment(self: EmbeddedMailbox, kind: string): (EmbeddedMailboxLocator?, string?)
		for _attempt = 1, 3 do
			local manifest, manifest_error = self:_get_manifest(kind)
			if manifest == nil then
				return nil, manifest_error
			end
			local slots = manifest.slots :: { unknown }
			for slot_number, raw_slot in slots do
				local slot = as_dict(raw_slot)
				if slot ~= nil and slot.state == "open" then
					local locator: EmbeddedMailboxLocator = {
						slot = slot_number,
						generation = slot.generation :: number,
						key = self:_segment_key(kind, slot_number, slot.generation :: number),
					}
					local segment_value, segment_error = self:_get(locator.key)
					local segment = as_dict(segment_value)
					if segment ~= nil and segment.generation == locator.generation and same_owner(segment.owner, self.owner)
						and segment.version ~= VERSION
					then
						return nil, "unsupported schema version: index segment version is unsupported"
					end
					if segment_error == nil and segment ~= nil and segment.version == VERSION
						and segment.kind == kind and segment.slot == locator.slot
						and type(segment.entries) == "table" and segment.state == "open"
						and segment.generation == locator.generation and same_owner(segment.owner, self.owner)
					then
						return locator, nil
					end
				end
			end
			for slot_number, raw_slot in slots do
				local slot = as_dict(raw_slot)
				if slot ~= nil and slot.state == "allocating" and type(slot.allocation_token) == "string" then
					local locator: EmbeddedMailboxLocator = {
						slot = slot_number,
						generation = slot.generation :: number,
						key = self:_segment_key(kind, slot_number, slot.generation :: number),
					}
					local finished, finish_error = self:_finish_allocation(kind, locator, slot.allocation_token :: string)
					if finished ~= nil then
						return finished, nil
					end
					return nil, finish_error
				end
			end
			local token, generation_error = self:_guid()
			if token == nil then return nil, generation_error end
			local allocated, allocate_error = self:_update(self:_manifest_key(kind), function(raw)
				local current = as_dict(raw)
				if current == nil then
					if raw == nil then return self:_fresh_manifest(kind) end
					return nil
				end
				if current.version ~= VERSION or not same_owner(current.owner, self.owner) then
					return nil
				end
				local next_manifest = clone_dict(current)
				local next_slots = next_manifest.slots :: { unknown }
				for slot_number, raw_slot in next_slots do
					local slot = as_dict(raw_slot)
					if slot ~= nil and slot.state == "empty" then
						local next_slot = clone_dict(slot)
						next_slot.generation = (if is_finite(slot.generation) then slot.generation :: number else 0) + 1
						next_slot.state = "allocating"
						next_slot.allocation_token = token
						next_slots[slot_number] = next_slot
						return next_manifest
					end
				end
				return raw
			end)
			if allocate_error ~= nil then
				return nil, "slot allocation outcome is unknown: " .. allocate_error
			end
			local next_manifest = as_dict(allocated)
			if next_manifest == nil then
				local latest_value, latest_error = self:_get_fresh(self:_manifest_key(kind))
				if latest_error ~= nil then
					return nil, "slot allocation outcome is unresolved: " .. latest_error
				end
				if latest_value ~= nil and as_dict(latest_value) == nil then
					return nil, "manifest is malformed"
				end
				next_manifest = as_dict(latest_value)
			end
			if next_manifest ~= nil and next_manifest.version ~= VERSION then
				return nil, "unsupported schema version: manifest version is unsupported"
			end
			if next_manifest ~= nil and not same_owner(next_manifest.owner, self.owner) then
				return nil, "manifest belongs to another owner"
			end
			local selected_slot: number? = nil
			local selected_generation: number? = nil
			if next_manifest ~= nil and type(next_manifest.slots) == "table" then
				for slot_number, raw_slot in next_manifest.slots :: { unknown } do
					local slot = as_dict(raw_slot)
					if slot ~= nil and slot.state == "allocating" and slot.allocation_token == token then
						selected_slot = slot_number
						selected_generation = slot.generation :: number
						break
					end
				end
			end
			if selected_slot ~= nil and selected_generation ~= nil then
				local locator: EmbeddedMailboxLocator = {
					slot = selected_slot,
					generation = selected_generation,
					key = self:_segment_key(kind, selected_slot, selected_generation),
				}
				return self:_finish_allocation(kind, locator, token)
			end
			if not self:_reclaim_slot(kind) then
				return nil, "capacity: all segment slots contain live or unresolved rows"
			end
		end
		return nil, "capacity: could not allocate an active segment"
	end

	function MailboxV2._set_registry_entry(self: EmbeddedMailbox, route: string, token: string, patch: EmbeddedMailboxDict?, remove_entry: boolean?): (EmbeddedMailboxDict?, string?)
		local key = self:_registry_key(route_shard(self, route))
		local updated, update_error = self:_update(key, function(raw)
			local current = as_dict(raw)
			if current == nil then
				return raw
			end
			if current.version ~= VERSION then return nil end
			if not same_owner(current.owner, self.owner) then return nil end
			local entries = as_dict(current.entries)
			if entries == nil then
				return raw
			end
			local active = as_dict(entries[route])
			if active == nil or active.token ~= token then
				return raw
			end
			local next_registry = clone_dict(current)
			local next_entries = clone_dict(entries)
			if remove_entry == true then
				next_entries[route] = nil
			elseif patch ~= nil then
				local next_entry = clone_dict(active)
				for field, value in patch do
					next_entry[field] = clone_json(value)
				end
				next_entries[route] = next_entry
			end
			next_registry.entries = next_entries
			return next_registry
		end)
		if update_error ~= nil then
			return nil, "preparation update outcome is unknown: " .. update_error
		end
		local registry = as_dict(updated)
		if registry == nil then
			local latest_value, latest_error = self:_get_fresh(key)
			if latest_error ~= nil then
				return nil, "preparation update outcome is unknown: " .. latest_error
			end
			registry = as_dict(latest_value)
		end
		if registry ~= nil and registry.version ~= VERSION then
			return nil, "unsupported schema version: preparation registry version is unsupported"
		end
		if registry ~= nil and not same_owner(registry.owner, self.owner) then
			return nil, "preparation registry belongs to another owner"
		end
		local entry = if registry ~= nil then as_dict(as_dict(registry.entries) and (as_dict(registry.entries) :: EmbeddedMailboxDict)[route]) else nil
		return entry, nil
	end

	function MailboxV2._get_registry_entry(self: EmbeddedMailbox, route: string): (EmbeddedMailboxDict?, string?)
		local raw, read_error = self:_get(self:_registry_key(route_shard(self, route)))
		if read_error ~= nil then
			return nil, read_error
		end
		local registry = as_dict(raw)
		if registry == nil then
			return nil, nil
		end
		if registry.version ~= VERSION then
			return nil, "unsupported schema version: preparation registry version is unsupported"
		end
		if not same_owner(registry.owner, self.owner) then
			return nil, "preparation registry belongs to another owner"
		end
		local entries = as_dict(registry.entries)
		return if entries ~= nil then as_dict(entries[route]) else nil, nil
	end

	function MailboxV2._reserve(self: EmbeddedMailbox, route: string, request_text: string, request: EmbeddedMailboxDict, token: string): (EmbeddedMailboxDict?, string?)
		local shard = route_shard(self, route)
		local key = self:_registry_key(shard)
		local maximum = self.options.preparation_max_entries_per_shard :: number
		local entry_size, size_error = self:_encode_size(request)
		if entry_size == nil or entry_size > (self.options.preparation_max_entry_bytes :: number) then
			return nil, size_error or "preparation entry exceeds the configured encoded-size cap"
		end
		local proposed: EmbeddedMailboxDict = {
			route = route,
			token = token,
			request_text = request_text,
			request = clone_json(request),
			sender_job_id = if type(request.legacy_sender_job_id) == "string" then request.legacy_sender_job_id else self.sender_job_id,
			phase = "reserved",
			created_at = self:_now(),
			placement_generation = 1,
		}
		local updated, update_error = self:_update(key, function(raw)
			local current = as_dict(raw)
			if current == nil then
				if raw ~= nil then return nil end
				current = ({
					version = VERSION,
					owner = clone_owner(self.owner),
					shard = shard,
					entries = {},
				} :: unknown) :: EmbeddedMailboxDict
			end
			assert(current ~= nil)
			if current.version ~= VERSION or current.shard ~= shard or not same_owner(current.owner, self.owner) then
				return nil
			end
			local entries = as_dict(current.entries)
			if entries == nil then
				return raw
			end
			local existing = as_dict(entries[route])
			if existing ~= nil then
				return raw
			end
			local count = 0
			for _ in entries do
				count += 1
			end
			if count >= maximum then
				return raw
			end
			local next_registry = clone_dict(current)
			local next_entries = clone_dict(entries)
			next_entries[route] = proposed
			next_registry.entries = next_entries
			return next_registry
		end)
		if update_error ~= nil then
			local observed = self:_get_registry_entry(route)
			if observed ~= nil then
				if observed.request_text == request_text then
					return observed, nil
				end
			end
			return nil, "unknown: preparation reservation write may have committed"
		end
		local registry = as_dict(updated)
		if registry == nil then
			local latest_value, latest_error = self:_get_fresh(key)
			if latest_error ~= nil then
				return nil, "unknown: preparation reservation state is unresolved: " .. latest_error
			end
			if latest_value ~= nil and as_dict(latest_value) == nil then
				return nil, "corrupt: preparation registry is malformed"
			end
			registry = as_dict(latest_value)
		end
		if registry ~= nil and registry.version ~= VERSION then
			return nil, "unsupported schema version: preparation registry version is unsupported"
		end
		if registry ~= nil and (registry.shard ~= shard or not same_owner(registry.owner, self.owner)) then
			return nil, "conflict: preparation registry owner or shard identity mismatch"
		end
		local entries = if registry ~= nil then as_dict(registry.entries) else nil
		local existing = if entries ~= nil then as_dict(entries[route]) else nil
		if existing ~= nil then
			if existing.request_text ~= request_text then
				return nil, "conflict: idempotency key is already bound to a different request"
			end
			return existing, nil
		end
		return nil, "capacity: preparation shard is full; no reservation was accepted"
	end

	function MailboxV2._update_message(self: EmbeddedMailbox, route: string, transform: (EmbeddedMailboxDict?) -> EmbeddedMailboxDict?): (EmbeddedMailboxDict?, string?)
		local updated, update_error = self:_update(route, function(raw)
			local current = as_dict(raw)
			if current ~= nil and not same_owner(current.owner, self.owner) then
				return nil
			end
			if current ~= nil and current.version ~= VERSION then
				return nil
			end
			return transform(current)
		end)
		if update_error ~= nil then
			return nil, update_error
		end
		local record = as_dict(updated)
		if updated == nil then
			-- UpdateAsync returning nil means the write was cancelled. Read back
			-- authoritatively to distinguish a missing record from an incompatible
			-- version that must never be re-persisted by an older writer.
			local latest_value, latest_error = self:_get_fresh(route)
			if latest_error ~= nil then
				return nil, "canonical update was cancelled but read-back is unresolved: " .. latest_error
			end
			if latest_value == nil then
				return nil, nil
			end
			local latest = as_dict(latest_value)
			if latest == nil then
				return nil, "canonical record is malformed after a cancelled update"
			end
			if not same_owner(latest.owner, self.owner) then
				return nil, "canonical route collision: owner identity mismatch"
			end
			if latest.version ~= VERSION then
				return nil, "unsupported schema version: canonical message version is not supported"
			end
			return latest, nil
		end
		if record ~= nil and not same_owner(record.owner, self.owner) then
			return nil, "canonical route collision: owner identity mismatch"
		end
		if record ~= nil and record.version ~= VERSION then
			return nil, "unsupported schema version: canonical message version is not supported"
		end
		return record, nil
	end

	function MailboxV2._record_snapshot(self: EmbeddedMailbox, record: EmbeddedMailboxDict): EmbeddedMailboxDict
		return {
			Id = if type(record.public_id) == "string" then record.public_id else record.route,
			Type = record.message_type,
			Data = clone_json(record.payload),
			SenderJobId = if type(record.sender_job_id) == "string" then record.sender_job_id else "",
			State = record.state,
			Attempts = record.attempts,
			TotalAttempts = record.total_attempts,
			ReplayCount = record.replay_count,
			CreatedAt = record.created_at,
			UpdatedAt = record.updated_at,
			AvailableAt = record.available_at,
			ExpiresAt = record.expires_at,
			Priority = record.priority,
			EffectOutcome = record.effect_outcome,
			LastError = record.last_error,
			CapacityBlocked = record.capacity_blocked == true,
			LeaseUntil = record.locked_until,
			ClaimStartedAt = record.claim_started_at,
			OrderingKey = record.ordering_key,
			OrderingSequence = record.ordering_sequence,
			PlacementGeneration = record.placement_generation,
			DeadLetteredAt = record.dead_lettered_at,
		}
	end

	local function valid_scheduling_record(record: EmbeddedMailboxDict, route: string): (boolean, string?)
		if record.version ~= VERSION then
			return false, "canonical message version is unsupported"
		end
		if type(record.route) ~= "string" or record.route ~= route then
			return false, "canonical route does not match its index entry"
		end
		if type(record.message_type) ~= "string" or record.message_type == "" or #record.message_type > 100 then
			return false, "canonical message type is malformed"
		end
		if record.priority ~= "high" and record.priority ~= "normal" and record.priority ~= "background" then
			return false, "canonical priority is malformed"
		end
		local attempts = record.attempts
		local total_attempts = record.total_attempts
		local replay_count = record.replay_count
		if not is_finite(attempts) or (attempts :: number) < 0 or math.floor(attempts :: number) ~= attempts
			or not is_finite(total_attempts) or (total_attempts :: number) < (attempts :: number)
			or math.floor(total_attempts :: number) ~= total_attempts
			or not is_finite(replay_count) or (replay_count :: number) < 0
			or math.floor(replay_count :: number) ~= replay_count
		then
			return false, "canonical retry counters are malformed"
		end
		local created_at = record.created_at
		local updated_at = record.updated_at
		local available_at = record.available_at
		local expires_at = record.expires_at
		if not is_finite(created_at) or not is_finite(updated_at) or not is_finite(available_at)
			or (expires_at ~= nil and (not is_finite(expires_at) or (expires_at :: number) <= (available_at :: number)))
		then
			return false, "canonical scheduling times are malformed"
		end
		local placement = record.placement_generation
		if not is_finite(placement) or (placement :: number) < 1 or math.floor(placement :: number) ~= placement then
			return false, "canonical placement generation is malformed"
		end
		if record.ordering_key == nil then
			if record.ordering_sequence ~= nil then
				return false, "canonical ordering sequence exists without an ordering_key"
			end
		elseif type(record.ordering_key) ~= "string" or record.ordering_key == ""
			or #record.ordering_key > MAX_ORDERING_KEY_LENGTH
			or not is_finite(record.ordering_sequence) or (record.ordering_sequence :: number) < 1
			or math.floor(record.ordering_sequence :: number) ~= record.ordering_sequence
			or (record.ordering_sequence :: number) > 9_007_199_254_740_991
		then
			return false, "canonical ordering metadata is malformed"
		end
		if record.state == "claimed" then
			if type(record.claim_token) ~= "string" or record.claim_token == "" or #record.claim_token > 256
				or not is_finite(record.claim_started_at) or not is_finite(record.locked_until)
				or (record.locked_until :: number) <= (record.claim_started_at :: number)
			then
				return false, "canonical claim lease metadata is malformed"
			end
		end
		return true, nil
	end

	function MailboxV2._ordering_route(self: EmbeddedMailbox, ordering_key: string): string
		return result_route_key(self, "m2o-", "ordering:" .. ordering_key)
	end

	local function valid_ordering_routes(routes: EmbeddedMailboxDict, next_sequence: unknown): boolean
		if not is_finite(next_sequence) then return false end
		local next_value = next_sequence :: number
		if next_value < 1 or next_value > 9_007_199_254_740_991
			or math.floor(next_value) ~= next_value
		then
			return false
		end
		local sequence_routes = {}
		for route, sequence in routes do
			if type(route) ~= "string" or route == "" or #route > MAX_KEY_LENGTH
				or not is_finite(sequence)
			then
				return false
			end
			local value = sequence :: number
			if value < 1 or value >= next_value or math.floor(value) ~= value
				or sequence_routes[value] ~= nil
			then
				return false
			end
			sequence_routes[value] = route
		end
		return true
	end

	function MailboxV2._ensure_ordering_slot(self: EmbeddedMailbox, route: string, ordering_key: string?): (number?, string?)
		if ordering_key == nil then return nil, nil end
		local ordering_route = self:_ordering_route(ordering_key)
		local updated_at = self:_now()
		local updated, update_error = self:_update(ordering_route, function(raw)
			local current = as_dict(raw)
			if current == nil then
				if raw ~= nil then return nil end
				current = ({
					version = VERSION,
					owner = clone_owner(self.owner),
					ordering_key = ordering_key,
					next_sequence = 1,
					routes = {},
				} :: unknown) :: EmbeddedMailboxDict
			end
			assert(current ~= nil)
			if current.version ~= VERSION or not same_owner(current.owner, self.owner)
				or current.ordering_key ~= ordering_key
			then
				return nil
			end
			local routes = as_dict(current.routes)
			if routes == nil or not valid_ordering_routes(routes, current.next_sequence) then return raw end
			local existing = routes[route]
			if existing ~= nil then
				return current
			end
			local next_sequence = current.next_sequence :: number
			if next_sequence >= 9_007_199_254_740_991 then
				return raw
			end
			local next_record = clone_dict(current)
			local next_routes = clone_dict(routes)
			next_routes[route] = next_sequence
			next_record.routes = next_routes
			next_record.next_sequence = (next_sequence :: number) + 1
			next_record.updated_at = updated_at
			return next_record
		end)
		if update_error ~= nil or updated == nil then
			local latest_value, read_error = self:_get_fresh(ordering_route)
			local latest = as_dict(latest_value)
			if read_error == nil and latest ~= nil and same_owner(latest.owner, self.owner)
				and latest.version ~= VERSION
			then
				return nil, "unsupported schema version: ordering index version is unsupported"
			end
			local routes = if latest ~= nil then as_dict(latest.routes) else nil
			local sequence = if routes ~= nil then routes[route] else nil
			if read_error == nil and latest ~= nil and latest.version == VERSION
				and same_owner(latest.owner, self.owner) and latest.ordering_key == ordering_key
				and routes ~= nil and valid_ordering_routes(routes, latest.next_sequence)
				and is_finite(sequence)
			then
				return sequence :: number, nil
			end
			return nil, "ordering sequence reservation is unresolved: " .. tostring(update_error or read_error or "no durable sequence")
		end
		local record = as_dict(updated)
		if record ~= nil and record.version ~= VERSION then
			return nil, "unsupported schema version: ordering index version is unsupported"
		end
		local routes = if record ~= nil then as_dict(record.routes) else nil
		local sequence = if routes ~= nil then routes[route] else nil
		if record == nil or not same_owner(record.owner, self.owner)
			or record.ordering_key ~= ordering_key or routes == nil
			or not valid_ordering_routes(routes, record.next_sequence) or not is_finite(sequence)
		then
			return nil, "ordering sequence reservation could not be verified"
		end
		return sequence :: number, nil
	end

	function MailboxV2._release_ordering_slot(
		self: EmbeddedMailbox,
		route: string,
		ordering_key: unknown,
		expected_sequence: number?
	): boolean
		if type(ordering_key) ~= "string" or ordering_key == "" then return true end
		local ordering_route = self:_ordering_route(ordering_key)
		local released_at = self:_now()
		local updated, update_error = self:_update(ordering_route, function(raw)
			local current = as_dict(raw)
			if current == nil then return raw end
			if current.version ~= VERSION then return nil end
			if not same_owner(current.owner, self.owner) or current.ordering_key ~= ordering_key then
				return nil
			end
			local routes = as_dict(current.routes)
			local route_sequence = if routes ~= nil then routes[route] else nil
			if routes == nil or route_sequence == nil
				or (expected_sequence ~= nil and route_sequence ~= expected_sequence)
			then
				return current
			end
			local next_record = clone_dict(current)
			local next_routes = clone_dict(routes)
			next_routes[route] = nil
			next_record.routes = next_routes
			local replay_operations = if current.replay_operations == nil then {} else as_dict(current.replay_operations)
			if replay_operations ~= nil then
				local replay_entry = as_dict(replay_operations[route])
				if replay_entry == nil or replay_entry.sequence == route_sequence then
					local next_replay_operations = clone_dict(replay_operations)
					next_replay_operations[route] = nil
					next_record.replay_operations = next_replay_operations
				end
			end
			next_record.updated_at = released_at
			return next_record
		end)
		if update_error ~= nil or updated == nil then
			local latest_value, read_error = self:_get_fresh(ordering_route)
			local latest = as_dict(latest_value)
			local routes = if latest ~= nil then as_dict(latest.routes) else nil
			local latest_sequence = if routes ~= nil then routes[route] else nil
			return read_error == nil and latest ~= nil and latest.version == VERSION
				and same_owner(latest.owner, self.owner) and latest.ordering_key == ordering_key
				and routes ~= nil and valid_ordering_routes(routes, latest.next_sequence)
				and (latest_sequence == nil or (expected_sequence ~= nil and latest_sequence ~= expected_sequence))
		end
		local record = as_dict(updated)
		local routes = if record ~= nil then as_dict(record.routes) else nil
		local latest_sequence = if routes ~= nil then routes[route] else nil
		return record ~= nil and record.version == VERSION and same_owner(record.owner, self.owner)
			and record.ordering_key == ordering_key and routes ~= nil
			and (latest_sequence == nil or (expected_sequence ~= nil and latest_sequence ~= expected_sequence))
	end

	function MailboxV2._reserve_replay_ordering_slot(
		self: EmbeddedMailbox,
		route: string,
		ordering_key: string,
		operation_id: string
	): (number?, string?)
		local ordering_route = self:_ordering_route(ordering_key)
		local reserved_at = self:_now()
		local updated, update_error = self:_update(ordering_route, function(raw)
			local current = as_dict(raw)
			if current == nil then
				if raw ~= nil then return nil end
				current = ({
					version = VERSION,
					owner = clone_owner(self.owner),
					ordering_key = ordering_key,
					next_sequence = 1,
					routes = {},
					replay_operations = {},
				} :: unknown) :: EmbeddedMailboxDict
			end
			assert(current ~= nil)
			if current.version ~= VERSION or not same_owner(current.owner, self.owner)
				or current.ordering_key ~= ordering_key
			then
				return nil
			end
			local routes = as_dict(current.routes)
			local replay_operations = if current.replay_operations == nil then {} else as_dict(current.replay_operations)
			if routes == nil or replay_operations == nil
				or not valid_ordering_routes(routes, current.next_sequence)
			then
				return raw
			end
			local prior_replay = as_dict(replay_operations[route])
			local current_sequence = routes[route]
			if prior_replay ~= nil and prior_replay.operation_id == operation_id
				and is_finite(prior_replay.sequence) and current_sequence == prior_replay.sequence
			then
				return current
			end
			local next_sequence = current.next_sequence
			if not is_finite(next_sequence) or (next_sequence :: number) < 1
				or math.floor(next_sequence :: number) ~= next_sequence
				or (next_sequence :: number) >= 9_007_199_254_740_991
			then
				return raw
			end
			local next_record = clone_dict(current)
			local next_routes = clone_dict(routes)
			local next_replay_operations = clone_dict(replay_operations)
			next_routes[route] = next_sequence
			next_replay_operations[route] = { operation_id = operation_id, sequence = next_sequence }
			next_record.routes = next_routes
			next_record.replay_operations = next_replay_operations
			next_record.next_sequence = (next_sequence :: number) + 1
			next_record.updated_at = reserved_at
			return next_record
		end)
		if update_error ~= nil then
			return nil, "replay ordering reservation is unresolved: " .. update_error
		end
		local record = as_dict(updated)
		if record == nil then
			local latest_value, latest_error = self:_get_fresh(ordering_route)
			if latest_error ~= nil then
				return nil, "replay ordering reservation is unresolved: " .. latest_error
			end
			record = as_dict(latest_value)
		end
		if record ~= nil and record.version ~= VERSION then
			return nil, "unsupported schema version: ordering index version is unsupported"
		end
		local routes = if record ~= nil then as_dict(record.routes) else nil
		local replay_operations = if record ~= nil then as_dict(record.replay_operations) else nil
		local replay_entry = if replay_operations ~= nil then as_dict(replay_operations[route]) else nil
		local sequence = if replay_entry ~= nil then replay_entry.sequence else nil
		if record == nil or record.version ~= VERSION or not same_owner(record.owner, self.owner)
			or record.ordering_key ~= ordering_key or routes == nil
			or not valid_ordering_routes(routes, record.next_sequence) or replay_entry == nil
			or replay_entry.operation_id ~= operation_id or not is_finite(sequence)
			or routes[route] ~= sequence
		then
			return nil, "replay ordering reservation could not be verified"
		end
		return sequence :: number, nil
	end

	function MailboxV2._ensure_replay_ordering_sequence(
		self: EmbeddedMailbox,
		route: string,
		operation_id: string,
		record: EmbeddedMailboxDict
	): (EmbeddedMailboxDict?, string?)
		local ordering_key = record.ordering_key
		if ordering_key == nil then return record, nil end
		if type(ordering_key) ~= "string" or ordering_key == "" or #ordering_key > MAX_ORDERING_KEY_LENGTH then
			return nil, "replaying message has invalid ordering metadata"
		end
		local sequence, reserve_error = self:_reserve_replay_ordering_slot(route, ordering_key, operation_id)
		if sequence == nil then return nil, reserve_error end
		local updated_at = self:_now()
		local updated, update_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= operation_id
				or current.ordering_key ~= ordering_key
			then
				return current
			end
			if current.ordering_sequence == sequence then return current end
			local next_record = clone_dict(current)
			next_record.ordering_sequence = sequence
			next_record.updated_at = updated_at
			return next_record
		end)
		if update_error ~= nil or updated == nil then
			return nil, "replay message ordering sequence is unresolved: " .. tostring(update_error or "missing canonical record")
		end
		local canonical_record = as_dict(updated)
		if canonical_record == nil or canonical_record.state ~= "replaying"
			or canonical_record.replay_operation_id ~= operation_id
			or canonical_record.ordering_key ~= ordering_key
			or canonical_record.ordering_sequence ~= sequence
		then
			return nil, "replay message ordering sequence could not be verified"
		end
		return canonical_record, nil
	end

	function MailboxV2._ordering_blocked(self: EmbeddedMailbox, record: EmbeddedMailboxDict, route: string): (boolean, string?)
		local ordering_key = record.ordering_key
		local sequence = record.ordering_sequence
		if ordering_key == nil then return false, nil end
		if type(ordering_key) ~= "string" or ordering_key == ""
			or #ordering_key > MAX_ORDERING_KEY_LENGTH
			or not is_finite(sequence) or (sequence :: number) < 1
			or math.floor(sequence :: number) ~= sequence
		then
			return true, "ordered message has invalid durable ordering metadata"
		end
		local order_route = self:_ordering_route(ordering_key)
		local ordering_value, read_error = self:_get_fresh(order_route)
		local ordering = as_dict(ordering_value)
		if read_error ~= nil then return true, "ordering state read failed: " .. read_error end
		local routes = if ordering ~= nil then as_dict(ordering.routes) else nil
		local next_sequence = if ordering ~= nil then ordering.next_sequence else nil
		if ordering == nil or ordering.version ~= VERSION or not same_owner(ordering.owner, self.owner)
			or ordering.ordering_key ~= ordering_key or routes == nil
			or not is_finite(next_sequence) or (next_sequence :: number) < 1
			or math.floor(next_sequence :: number) ~= next_sequence
			or (next_sequence :: number) > 9_007_199_254_740_991
			or (next_sequence :: number) <= (sequence :: number)
		then
			return true, "ordering state is missing or corrupt"
		end
		if routes[route] ~= sequence then
			return true, "ordered message does not match its durable ordering slot"
		end
		local sequence_routes = {}
		for prior_route, prior_sequence in routes do
			if type(prior_route) ~= "string" or prior_route == "" or #prior_route > MAX_KEY_LENGTH
				or not is_finite(prior_sequence) or (prior_sequence :: number) < 1
				or math.floor(prior_sequence :: number) ~= prior_sequence
				or (prior_sequence :: number) >= (next_sequence :: number)
			then
				return true, "ordering state contains a malformed route or sequence"
			end
			local prior_route_for_sequence = sequence_routes[prior_sequence]
			if prior_route_for_sequence ~= nil and prior_route_for_sequence ~= prior_route then
				return true, "ordering state assigns one sequence to multiple messages"
			end
			sequence_routes[prior_sequence] = prior_route
			if (prior_sequence :: number) < (sequence :: number) then
				local prior_value, prior_error = self:_get_fresh(prior_route)
				if prior_error ~= nil then return true, "predecessor state read failed: " .. prior_error end
				local prior = as_dict(prior_value)
				if prior == nil or not same_owner(prior.owner, self.owner) then
					return true, "earlier ordered message has no verifiable canonical record"
				end
				if prior.ordering_key ~= ordering_key or prior.ordering_sequence ~= prior_sequence then
					return true, "predecessor does not match its current durable ordering slot"
				end
				if not TERMINAL[tostring(prior.state)] then
					return true, "an earlier message with the same ordering_key is not terminal"
				end
				if type(prior_sequence) == "number" and is_finite(prior_sequence) then
				self:_release_ordering_slot(prior_route, ordering_key, prior_sequence :: number)
			end
			end
		end
		return false, nil
	end

	function MailboxV2._reservation_row(self: EmbeddedMailbox, entry: EmbeddedMailboxDict): EmbeddedMailboxDict
		return {
			route = entry.route,
			placement_generation = entry.placement_generation,
			reservation_token = entry.token,
		}
	end

	function MailboxV2._append_at_locator(self: EmbeddedMailbox, kind: string, locator: EmbeddedMailboxLocator, row: EmbeddedMailboxDict): (string, string?)
		local manifest, manifest_error = self:_get_manifest(kind)
		if manifest == nil then
			return "unknown", manifest_error
		end
		local manifest_slot = locate_slot(manifest, locator.slot)
		if manifest_slot == nil or manifest_slot.generation ~= locator.generation then
			return "unknown", "segment locator generation is no longer authoritative"
		end
		if manifest_slot.state ~= "open" then
			local previous, previous_error = self:_get(locator.key)
			local segment = as_dict(previous)
			if previous_error == nil and segment ~= nil
				and segment.generation == locator.generation
				and same_owner(segment.owner, self.owner)
				and has_row(segment, tostring(row.route), row.placement_generation :: number)
				and (manifest_slot.state == "sealed" or manifest_slot.state == "draining")
			then
				return "appended", nil
			end
			return "full", nil
		end
		local maximum = if kind == "active" then self.options.segment_max_messages :: number else self.options.dlq_segment_max_messages :: number
		local updated, update_error = self:_update(locator.key, function(raw)
			local segment = as_dict(raw)
			if segment == nil then return nil end
			if segment.version ~= VERSION then return nil end
			if segment.kind ~= kind or segment.slot ~= locator.slot
				or segment.generation ~= locator.generation or not same_owner(segment.owner, self.owner)
			then
				return raw
			end
			if segment.state == "retired" then return nil end
			if has_row(segment, tostring(row.route), row.placement_generation :: number) then
				return raw
			end
			if segment.state ~= "open" or type(segment.entries) ~= "table" or #(segment.entries :: { unknown }) >= maximum then
				local sealed = clone_dict(segment)
				sealed.state = "sealed"
				return sealed
			end
			local next_segment = clone_dict(segment)
			local entries = table.clone(segment.entries :: { unknown })
			table.insert(entries, clone_json(row))
			next_segment.entries = entries
			if #entries >= maximum then
				next_segment.state = "sealed"
			end
			return next_segment
		end)
		if update_error ~= nil then
			return "unknown", update_error
		end
		local segment = as_dict(updated)
		if segment ~= nil and segment.version ~= VERSION then
			return "unknown", "unsupported schema version: index segment version is unsupported"
		end
		if segment == nil then
			local latest_value, latest_error = self:_get_fresh(locator.key)
			if latest_error ~= nil then return "unknown", "segment update could not be verified: " .. latest_error end
			segment = as_dict(latest_value)
		end
		if segment ~= nil and segment.version ~= VERSION then
			return "unknown", "unsupported schema version: index segment version is unsupported"
		end
		if segment == nil or segment.generation ~= locator.generation or not same_owner(segment.owner, self.owner) then
			return "unknown", "segment update could not be verified"
		end
		if segment.state == "retired" then return "full", nil end
		if has_row(segment, tostring(row.route), row.placement_generation :: number) then
			if segment.state == "sealed" then
				self:_set_slot_state(kind, locator, "open", "sealed")
			end
			return "appended", nil
		end
		if segment.state == "sealed" then
			self:_set_slot_state(kind, locator, "open", "sealed")
			return "full", nil
		end
		return "unknown", "index row is not present after append"
	end

	function MailboxV2._append_index(self: EmbeddedMailbox, kind: string, row: EmbeddedMailboxDict): (EmbeddedMailboxLocator?, string?)
		local slot_limit = if kind == "active" then self.options.max_segments :: number else self.options.dlq_max_segments :: number
		for _attempt = 1, slot_limit + 2 do
			local locator, open_error = self:_open_segment(kind)
			if locator == nil then
				return nil, open_error
			end
			local status, append_error = self:_append_at_locator(kind, locator, row)
			if status == "appended" then
				return locator, nil
			elseif status == "unknown" then
				return nil, "unknown: " .. (append_error or "index append outcome is unknown")
			end
		end
		return nil, "capacity: no index segment can accept the row"
	end

	function MailboxV2._contains_index_row(self: EmbeddedMailbox, kind: string, locator: EmbeddedMailboxLocator, route: string, placement: number): boolean
		local value = self:_get(locator.key)
		local segment = as_dict(value)
		return segment ~= nil and segment.generation == locator.generation
			and same_owner(segment.owner, self.owner) and has_row(segment, route, placement)
	end

	function MailboxV2._locator_from_entry(self: EmbeddedMailbox, entry: EmbeddedMailboxDict): EmbeddedMailboxLocator?
		local locator = as_dict(entry.locator)
		if locator == nil or not is_finite(locator.slot) or not is_finite(locator.generation) then
			return nil
		end
		return {
			slot = locator.slot :: number,
			generation = locator.generation :: number,
			key = self:_segment_key("active", locator.slot :: number, locator.generation :: number),
		}
	end

	function MailboxV2._resume_reservation(self: EmbeddedMailbox, route: string, initial_entry: EmbeddedMailboxDict): EmbeddedMailboxResult
		local entry = initial_entry
		local request = as_dict(entry.request)
		if request == nil or type(entry.request_text) ~= "string" or type(entry.token) ~= "string" then
			return ok("corrupt", route, nil, "preparation entry is missing its request identity")
		end
		local token = entry.token :: string
		local request_text = entry.request_text :: string
		local request_ordering_key = request.ordering_key
		if request_ordering_key ~= nil and (type(request_ordering_key) ~= "string"
			or request_ordering_key == "" or #request_ordering_key > MAX_ORDERING_KEY_LENGTH)
		then
			return ok("corrupt", route, nil, "preparation entry has an invalid ordering_key")
		end
		local ordering_sequence, ordering_error = self:_ensure_ordering_slot(route, request_ordering_key :: string?)
		if ordering_error ~= nil then return ok("unknown", route, nil, ordering_error) end
		local locator = self:_locator_from_entry(entry)
		if locator == nil then
			local next_locator, open_error = self:_open_segment("active")
			if next_locator == nil then
				local blocked_entry, _blocked_error = self:_set_registry_entry(route, token, ({ capacity_blocked = true } :: unknown) :: EmbeddedMailboxDict)
				return ok("unknown", route, nil, open_error or (if blocked_entry ~= nil then "capacity-blocked preparing reservation" else "preparation remains unresolved"))
			end
			local patched, patch_error = self:_set_registry_entry(route, token, ({
				locator = { slot = next_locator.slot, generation = next_locator.generation },
				phase = "located",
			} :: unknown) :: EmbeddedMailboxDict)
			if patch_error ~= nil or patched == nil then
				return ok("unknown", route, nil, patch_error or "reservation locator update could not be verified")
			end
			entry = patched
			locator = next_locator
		end
		if locator == nil then
			return ok("unknown", route, nil, "reservation locator is unavailable")
		end
		local placement = if is_finite(entry.placement_generation) then entry.placement_generation :: number else 1

		if entry.phase == "reserved" or entry.phase == "located" then
			local row = self:_reservation_row(entry)
			local appended, append_error = self:_append_at_locator("active", locator, row)
			if appended == "full" then
				local next_locator, next_error = self:_open_segment("active")
				if next_locator == nil then
					local blocked_entry, _blocked_error = self:_set_registry_entry(route, token, ({ capacity_blocked = true } :: unknown) :: EmbeddedMailboxDict)
					return ok("unknown", route, nil, next_error or (if blocked_entry ~= nil then "capacity-blocked preparing reservation" else "preparation remains unresolved"))
				end
				local next_placement = placement + 1
				local patched, patch_error = self:_set_registry_entry(route, token, ({
					locator = { slot = next_locator.slot, generation = next_locator.generation },
					placement_generation = next_placement,
					phase = "located",
				} :: unknown) :: EmbeddedMailboxDict)
				if patch_error ~= nil or patched == nil then
					return ok("unknown", route, nil, patch_error or "reservation retarget could not be verified")
				end
				return self:_resume_reservation(route, patched)
			elseif appended ~= "appended" then
				return ok("unknown", route, nil, append_error or "index append has unknown outcome")
			end
			local patched, patch_error = self:_set_registry_entry(route, token, ({ phase = "indexed" } :: unknown) :: EmbeddedMailboxDict)
			if patch_error ~= nil or patched == nil then
				return ok("unknown", route, nil, patch_error or "index phase could not be verified")
			end
			entry = patched
			placement = entry.placement_generation :: number
			locator = self:_locator_from_entry(entry) :: EmbeddedMailboxLocator
		end

		local current_record_value, current_record_error = self:_get(route)
		if current_record_error ~= nil then
			return ok("unknown", route, nil, "canonical read failed: " .. current_record_error)
		end
		local current_record = as_dict(current_record_value)
		if current_record ~= nil then
			if not same_owner(current_record.owner, self.owner) or current_record.request_text ~= request_text then
				return ok("conflict", route, nil, "canonical route collision or different exact request")
			end
			if TERMINAL[tostring(current_record.state)] then
				self:_set_registry_entry(route, token, nil, true)
				return ok("duplicate", route, self:_record_snapshot(current_record), nil)
			end
			if current_record.state == "ready" or current_record.state == "claimed" or current_record.state == "acknowledging" then
				local current_locator = as_dict(current_record.locator)
				local same_locator = current_locator ~= nil
					and current_locator.slot == locator.slot
					and current_locator.generation == locator.generation
					and current_record.placement_generation == placement
				if not same_locator or not self:_contains_index_row("active", locator, route, placement) then
					return ok("unknown", route, self:_record_snapshot(current_record), "accepted-state receipt has no verified matching index row; registry retained")
				end
				local cleared, clear_error = self:_set_registry_entry(route, token, nil, true)
				if clear_error ~= nil or cleared ~= nil then
					return ok("duplicate", route, self:_record_snapshot(current_record), nil)
				end
				return ok("unknown", route, self:_record_snapshot(current_record), "registry clear outcome is unknown")
			end
		end

		local preparing_now = self:_now()
		local preparing, preparing_error = self:_update_message(route, function(current)
			if current == nil then
				return ({
					version = VERSION,
					owner = clone_owner(self.owner),
					route = route,
					public_id = if type(request.public_id) == "string" then request.public_id else nil,
					request_text = request_text,
					migration_target = request.migration_target,
					legacy_migration_id = request.legacy_migration_id,
					legacy_last_replay_token = request.legacy_last_replay_token,
					legacy_terminal_lock_token = request.legacy_terminal_lock_token,
					message_type = request.message_type,
					payload = clone_json(request.payload),
					sender_job_id = if type(entry.sender_job_id) == "string" then entry.sender_job_id else "",
					priority = request.priority,
					ordering_key = request_ordering_key,
					ordering_sequence = ordering_sequence,
					available_at = if is_finite(request.available_at) then request.available_at else entry.created_at,
					expires_at = request.expires_at,
					created_at = if is_finite(request.legacy_created_at) then request.legacy_created_at else entry.created_at,
					updated_at = preparing_now,
					attempts = if is_finite(request.legacy_attempts) then request.legacy_attempts else 0,
					total_attempts = if is_finite(request.legacy_total_attempts) then request.legacy_total_attempts else 0,
					replay_count = if is_finite(request.legacy_replay_count) then request.legacy_replay_count else 0,
					last_error = if type(request.legacy_last_error) == "string" then request.legacy_last_error else nil,
					state = "preparing",
					reservation_token = token,
					placement_generation = placement,
					locator = { slot = locator.slot, generation = locator.generation },
					effect_outcome = "not_started",
				} :: unknown) :: EmbeddedMailboxDict
			end
			if current.request_text ~= request_text then
				return current
			end
			if current.state == "preparing" and current.reservation_token == token then
				local next_record = clone_dict(current)
				next_record.locator = { slot = locator.slot, generation = locator.generation }
				next_record.placement_generation = placement
				next_record.updated_at = preparing_now
				return next_record
			end
			return current
		end)
		if preparing_error ~= nil then
			return ok("unknown", route, nil, "canonical preparation write is unknown: " .. preparing_error)
		end
		if preparing == nil or preparing.state ~= "preparing" or preparing.reservation_token ~= token then
			return ok("unknown", route, preparing, "canonical preparing state could not be verified")
		end
		local patched, phase_error = self:_set_registry_entry(route, token, ({ phase = "canonical" } :: unknown) :: EmbeddedMailboxDict)
		if phase_error ~= nil or patched == nil then
			return ok("unknown", route, nil, phase_error or "preparation phase update is unknown")
		end
		entry = patched
		locator = self:_locator_from_entry(entry) :: EmbeddedMailboxLocator
		placement = entry.placement_generation :: number
		if not self:_contains_index_row("active", locator, route, placement) then
			local row = self:_reservation_row(entry)
			local status, index_error = self:_append_at_locator("active", locator, row)
			if status ~= "appended" then
				return ok(if status == "full" then "capacity" else "unknown", route, nil, index_error or "canonical index row is unresolved")
			end
		end
		local ready_now = self:_now()
		local ready, ready_error = self:_update_message(route, function(current)
			if current == nil or not same_owner(current.owner, self.owner) or current.request_text ~= request_text then
				return current
			end
			if current.state == "ready" then
				return current
			end
			if current.state ~= "preparing" or current.reservation_token ~= token then
				return current
			end
			local active_locator = as_dict(current.locator)
			if active_locator == nil or active_locator.slot ~= locator.slot or active_locator.generation ~= locator.generation
				or current.placement_generation ~= placement
			then
				return current
			end
			local next_record = clone_dict(current)
			next_record.state = "ready"
			next_record.updated_at = ready_now
			return next_record
		end)
		if ready_error ~= nil then
			return ok("unknown", route, nil, "ready promotion outcome is unknown: " .. ready_error)
		end
		if ready == nil or ready.state ~= "ready" then
			return ok("unknown", route, ready, "ready state could not be verified")
		end
		if not self:_contains_index_row("active", locator, route, placement) then
			return ok("unknown", route, self:_record_snapshot(ready), "ready record has no verified matching index row")
		end
		local cleared_entry, clear_error = self:_set_registry_entry(route, token, nil, true)
		if clear_error ~= nil or cleared_entry ~= nil then
			return ok("unknown", route, self:_record_snapshot(ready), clear_error or "preparation registry clear was not verified")
		end
		return ok("accepted", route, self:_record_snapshot(ready), nil)
	end


	local function publish_after_enqueue(self: EmbeddedMailbox, result: EmbeddedMailboxResult): EmbeddedMailboxResult
		if result.code ~= "accepted" and result.code ~= "duplicate" then return result end
		local state = if type(result.message) == "table" then result.message.State else nil
		if state ~= nil and state ~= "ready" then return result end
		local wakeups = self.options.wakeups
		if wakeups == nil then return result end
		local ok, response = pcall(function()
			return wakeups:Publish(self.owner_text, "enqueue")
		end)
		if ok and type(response) == "table" and response.code == "scheduled" then
			self.wakeup_published += 1
		else
			self.wakeup_publish_errors += 1
		end
		return result
	end

	function MailboxV2.BindWakeups(self: EmbeddedMailbox, wakeups: unknown): (boolean, string?)
		if type(wakeups) ~= "table" or type((wakeups :: EmbeddedMailboxDict).Publish) ~= "function" then
			return false, "wakeups must expose Publish(owner_identity, reason)"
		end
		self.options.wakeups = wakeups :: EmbeddedMailboxWakeupAdapter
		return true, nil
	end

	function MailboxV2.SetLeaseRenewalScheduler(
		self: EmbeddedMailbox,
		scheduler: unknown
	): (boolean, string?)
		if scheduler ~= nil and type(scheduler) ~= "function" then
			return false, "lease renewal scheduler must be a function or nil"
		end
		self.options.lease_renewal_scheduler = scheduler :: ((string, number, number, () -> unknown, (unknown) -> ()) -> unknown)?
		return true, nil
	end

	function MailboxV2.GetOwner(self: EmbeddedMailbox): EmbeddedMailboxOwner
		return clone_owner(self.owner)
	end

	function MailboxV2.GetActiveRecord(self: EmbeddedMailbox): EmbeddedMailboxActiveRecordLike?
		return self.options.active_record
	end

	local function verify_active_record(self: EmbeddedMailbox): (string, string?)
		local record = self.options.active_record
		if record == nil then
			return "fenced", "an active Record must be configured before processing V2 messages"
		end
		local open_ok, is_open = pcall(function() return record:IsOpen() end)
		if not open_ok or is_open ~= true then
			return "fenced", "bound Record is not open"
		end
		local state_ok, record_state = pcall(function() return record:GetState() end)
		if not state_ok or record_state ~= "active" then
			return "fenced", "bound Record is not actively owned"
		end
		local identity_ok, identity = pcall(function() return record:GetIdentity() end)
		if not identity_ok or type(identity) ~= "table" then
			return "fenced", "bound Record identity could not be verified"
		end
		if identity.store_name ~= self.owner.store_name
			or identity.scope ~= self.owner.scope
			or identity.profile_key ~= self.owner.profile_key
		then
			return "fenced", "bound Record identity does not match the V2 mailbox owner"
		end
		local user_ids = identity.user_ids
		if type(user_ids) ~= "table" then
			return "fenced", "bound Record UserIds could not be verified"
		end
		local user_ids_array = user_ids :: { unknown }
		if self.owner.user_id ~= nil then
			local found = false
			for _, user_id in ipairs(user_ids_array) do
				if user_id == self.owner.user_id then found = true; break end
			end
			if not found then return "fenced", "V2 mailbox UserId does not match the bound Record" end
		elseif #user_ids_array > 0 then
			return "fenced", "V2 mailbox owner must include a UserId for this Record"
		end
		local stats_ok, stats = pcall(function() return record:Stats() end)
		if not stats_ok or type(stats) ~= "table" then
			return "fenced", "bound Record session state could not be verified"
		end
		local takeover_requested = stats.takeover_requested
		if takeover_requested == true or (type(takeover_requested) == "number" and takeover_requested > 0) then
			return "closing", "Record session takeover has been requested"
		end
		return "success", nil
	end

	function MailboxV2.EnqueueAsync(self: EmbeddedMailbox, message_type: string, payload: unknown, enqueue_options: EmbeddedMailboxDict?): EmbeddedMailboxResult
		local activation = self:_check_activation("enqueue")
		if activation ~= nil then return activation end
		if type(message_type) ~= "string" or message_type == "" or #message_type > 100 then
			return ok("invalid", nil, nil, "message_type must be 1 to 100 bytes")
		end
		local options: EmbeddedMailboxDict = enqueue_options or ({} :: EmbeddedMailboxDict)
		local ordering_key = options.ordering_key
		if ordering_key ~= nil and (type(ordering_key) ~= "string" or ordering_key == ""
			or #ordering_key > MAX_ORDERING_KEY_LENGTH)
		then
			return ok("invalid", nil, nil, "ordering_key must be 1 to " .. tostring(MAX_ORDERING_KEY_LENGTH) .. " bytes")
		end
		if ordering_key ~= nil and not self.options.strict_ordering_enabled then
			return ok("invalid", nil, nil, "ordering_key requires strict_ordering_enabled=true")
		end
		local priority = if options.priority == nil then "normal" else options.priority
		if priority ~= "high" and priority ~= "normal" and priority ~= "background" then
			return ok("invalid", nil, nil, "priority must be high, normal or background")
		end
		local available_at = if options.available_at == nil then self:_now() else options.available_at
		local expires_at = options.expires_at
		if not is_finite(available_at) or (expires_at ~= nil and (not is_finite(expires_at) or (expires_at :: number) <= (available_at :: number))) then
			return ok("invalid", nil, nil, "available_at and expires_at must be finite milliseconds, with expiry after eligibility")
		end
		local payload_size, payload_error = self:_encode_size(payload)
		if payload_size == nil then
			return ok("invalid", nil, nil, payload_error)
		end
		if payload_size > (self.options.max_payload_bytes :: number) then
			return ok("invalid", nil, nil, "payload exceeds the configured encoded-size cap")
		end
		local idempotency_value = options.idempotency_key
		if idempotency_value ~= nil and type(idempotency_value) ~= "string" then
			return ok("invalid", nil, nil, "idempotency_key must be a string when supplied")
		end
		local idempotency_key: string? = idempotency_value :: string?
		local route, route_error = self:_route_key(idempotency_key)
		if route == nil then
			return ok("invalid", nil, nil, route_error)
		end
		local request: EmbeddedMailboxDict = {
			owner = clone_owner(self.owner),
			idempotency_key = idempotency_key,
			message_type = message_type,
			payload = clone_json(payload),
			priority = priority,
			ordering_key = ordering_key,
			available_at = options.available_at,
			expires_at = expires_at,
		}
		local request_text = canonical(request)
		local request_size, request_size_error = self:_encode_size(request)
		if request_size == nil or request_size > (self.options.max_request_bytes :: number) then
			return ok("invalid", route, nil, request_size_error or "canonical request exceeds the configured size cap")
		end
		if #request_text > (self.options.preparation_max_entry_bytes :: number) then
			return ok("invalid", route, nil, "canonical request is too large for the bounded preparation registry")
		end

		local existing_value, existing_error = self:_get(route)
		if existing_error ~= nil then
			return ok("unknown", route, nil, "canonical status is unavailable: " .. existing_error)
		end
		local existing = as_dict(existing_value)
		if existing ~= nil then
			if not same_owner(existing.owner, self.owner) then
				return ok("conflict", route, nil, "idempotency route is already bound to a different owner")
			end
			if existing.version ~= VERSION then
				return ok("unsupported_schema", route, nil, "canonical producer receipt version is unsupported")
			end
			if existing.request_text ~= request_text then
				return ok("conflict", route, nil, "idempotency route is already bound to a different request")
			end
			if existing.state == "preparing" then
				local entry = self:_get_registry_entry(route)
				if entry ~= nil then
					return publish_after_enqueue(self, self:_resume_reservation(route, entry))
				end
				return ok("unknown", route, self:_record_snapshot(existing), "preparing record has no matching registry entry; quarantined")
			end
			return publish_after_enqueue(self, ok("duplicate", route, self:_record_snapshot(existing), nil))
		end

		local token, generation_error = self:_guid()
		if token == nil then return ok("invalid", route, nil, generation_error) end
		local entry, reserve_error = self:_reserve(route, request_text, request, token)
		if entry == nil then
			local code = if string.find(reserve_error or "", "capacity", 1, true) then "capacity"
				elseif string.find(reserve_error or "", "conflict", 1, true) then "conflict"
				else "unknown"
			return ok(code, route, nil, reserve_error)
		end
		return publish_after_enqueue(self, self:_resume_reservation(route, entry))
	end

	local function make_legacy_import_request(
		self: EmbeddedMailbox,
		raw_legacy: unknown,
		migration_id: string,
		target: string
	): (EmbeddedMailboxDict?, string?, string?)
		local legacy = as_dict(raw_legacy)
		if legacy == nil then return nil, nil, "legacy queue item must be a table" end
		if not valid_text(migration_id, 96) then return nil, nil, "migration_id must be 1 to 96 bytes" end
		if target ~= "active" and target ~= "dead_letter" then return nil, nil, "unsupported legacy migration target" end
		local legacy_id = if type(legacy.id) == "string" then legacy.id else legacy.Id
		local message_type = if type(legacy.type) == "string" then legacy.type else legacy.Type
		local payload = if legacy.data ~= nil then legacy.data else legacy.Data
		if not valid_text(legacy_id, MAX_KEY_LENGTH) then
			return nil, nil, "legacy message ID must be 1 to " .. tostring(MAX_KEY_LENGTH) .. " bytes"
		end
		local id_prefix = string.sub(legacy_id, 1, 4)
		if id_prefix == "m2i-" or id_prefix == "m2g-" or id_prefix == "m2l-" then
			return nil, nil, "legacy message ID collides with a reserved V2 ID namespace"
		end
		if not valid_text(message_type, 100) then return nil, nil, "legacy message type must be 1 to 100 bytes" end

		local attempts = if is_finite(legacy.attempts) then legacy.attempts else 0
		local total_attempts = if is_finite(legacy.total_attempts) then legacy.total_attempts else attempts
		local replay_count = if is_finite(legacy.replay_count) then legacy.replay_count else 0
		if attempts < 0 or math.floor(attempts) ~= attempts
			or total_attempts < attempts or math.floor(total_attempts) ~= total_attempts
			or replay_count < 0 or math.floor(replay_count) ~= replay_count
			or total_attempts > 9_007_199_254_740_991
		then
			return nil, nil, "legacy retry counters are malformed"
		end

		local created_seconds = if is_finite(legacy.created_at) then legacy.created_at else legacy.CreatedAt
		if not is_finite(created_seconds) or (created_seconds :: number) < 0
			or (created_seconds :: number) > 9_007_199_254_740
		then
			return nil, nil, "legacy created_at must be a finite Unix timestamp in seconds"
		end
		local created_at_ms = math.floor((created_seconds :: number) * 1000)
		local sender_job_id = if type(legacy.sender_job_id) == "string" then legacy.sender_job_id
			else if type(legacy.SenderJobId) == "string" then legacy.SenderJobId else ""
		if #sender_job_id > 128 then return nil, nil, "legacy sender_job_id exceeds 128 bytes" end
		local last_replay_token = legacy.last_replay_token
		if last_replay_token ~= nil and (type(last_replay_token) ~= "string" or #last_replay_token > 256) then
			return nil, nil, "legacy last_replay_token is malformed"
		end
		local last_error = if type(legacy.last_error) == "string" then legacy.last_error else legacy.LastError
		if last_error ~= nil and (type(last_error) ~= "string" or #last_error > 1024) then
			return nil, nil, "legacy last_error is malformed"
		end
		local terminal_lock_token = legacy.terminal_lock_token
		if terminal_lock_token ~= nil and (type(terminal_lock_token) ~= "string" or #terminal_lock_token > 256) then
			return nil, nil, "legacy terminal_lock_token is malformed"
		end
		local dead_lettered_at_ms = created_at_ms
		local raw_dead_lettered_at = if is_finite(legacy.dead_lettered_at) then legacy.dead_lettered_at else legacy.DeadLetteredAt
		if raw_dead_lettered_at ~= nil then
			if not is_finite(raw_dead_lettered_at) or (raw_dead_lettered_at :: number) < 0
				or (raw_dead_lettered_at :: number) > 9_007_199_254_740
			then
				return nil, nil, "legacy dead_lettered_at must be a finite Unix timestamp in seconds"
			end
			dead_lettered_at_ms = math.floor((raw_dead_lettered_at :: number) * 1000)
		end
		if target == "active" and self.options.strict_ordering_enabled ~= true then
			return nil, nil, "legacy FIFO preservation requires strict_ordering_enabled=true"
		end
		local ordering_key = if target == "active" then "legacy-v3:" .. migration_id else nil
		if ordering_key ~= nil and #ordering_key > MAX_ORDERING_KEY_LENGTH then
			return nil, nil, "migration_id produces an oversized legacy ordering key"
		end
		local payload_size, payload_error = self:_encode_size(payload)
		if payload_size == nil or payload_size > (self.options.max_payload_bytes :: number) then
			return nil, nil, payload_error or "legacy payload exceeds the configured encoded-size cap"
		end
		local copy_ok, payload_copy = pcall(clone_json, payload)
		if not copy_ok then return nil, nil, "legacy payload is not cloneable as JSON-compatible data" end
		local request: EmbeddedMailboxDict = {
			owner = clone_owner(self.owner),
			idempotency_key = "legacy-v3:" .. migration_id .. ":" .. legacy_id,
			migration_target = target,
			legacy_migration_id = migration_id,
			legacy_sender_job_id = sender_job_id,
			public_id = legacy_id,
			message_type = message_type,
			payload = payload_copy,
			priority = "normal",
			ordering_key = ordering_key,
			available_at = created_at_ms,
			expires_at = nil,
			legacy_created_at = created_at_ms,
			legacy_updated_at = created_at_ms,
			legacy_attempts = attempts,
			legacy_total_attempts = total_attempts,
			legacy_replay_count = replay_count,
			legacy_last_replay_token = last_replay_token,
			legacy_last_error = last_error,
			legacy_terminal_lock_token = terminal_lock_token,
			legacy_dead_lettered_at = dead_lettered_at_ms,
		}
		local request_text_ok, request_text = pcall(canonical, request)
		if not request_text_ok or type(request_text) ~= "string" then
			return nil, nil, "legacy queue item is not canonicalizable"
		end
		local request_size, size_error = self:_encode_size(request)
		if request_size == nil or request_size > (self.options.max_request_bytes :: number) then
			return nil, nil, size_error or "legacy request exceeds the configured encoded-size cap"
		end
		if #request_text > (self.options.preparation_max_entry_bytes :: number) then
			return nil, nil, "legacy request is too large for the bounded preparation registry"
		end
		return request, request_text, nil
	end

	local function legacy_import_status(self: EmbeddedMailbox, route: string, request_text: string, legacy_id: string): EmbeddedMailboxResult?
		local raw, read_error = self:_get_fresh(route)
		if read_error ~= nil then
			return ok("unknown", legacy_id, nil, "legacy import verification read failed: " .. read_error)
		end
		local current = as_dict(raw)
		if raw ~= nil and current == nil then return ok("corrupt", legacy_id, nil, "legacy import target is malformed") end
		if current == nil then return nil end
		if current.version ~= VERSION then
			return ok("unsupported_schema", legacy_id, nil, "legacy import target has an unsupported schema")
		end
		if not same_owner(current.owner, self.owner) then
			return ok("conflict", legacy_id, nil, "legacy ID route belongs to another mailbox owner")
		end
		if current.public_id ~= legacy_id or current.request_text ~= request_text
			or (current.migration_target ~= "active" and current.migration_target ~= "dead_letter")
		then
			return ok("conflict", legacy_id, self:_record_snapshot(current), "legacy ID is already bound to different content")
		end
		return ok("duplicate", legacy_id, self:_record_snapshot(current), nil)
	end

	function MailboxV2.ImportLegacyAsync(
		self: EmbeddedMailbox,
		legacy_message: unknown,
		migration_id: string
	): EmbeddedMailboxResult
		local activation = self:_check_activation("migration")
		if activation ~= nil then return activation end
		local request, request_text, request_error = make_legacy_import_request(self, legacy_message, migration_id, "active")
		if request == nil or request_text == nil then return ok("invalid", nil, nil, request_error) end
		local legacy_id = request.public_id :: string
		local route = self:_legacy_route_key(legacy_id)
		local existing_status = legacy_import_status(self, route, request_text, legacy_id)
		if existing_status ~= nil then
			if existing_status.code ~= "duplicate" then return existing_status end
			local existing = as_dict(existing_status.message)
			if existing ~= nil and existing.State ~= "preparing" then return existing_status end
			local entry, entry_error = self:_get_registry_entry(route)
			if entry_error ~= nil then return ok("unknown", legacy_id, existing_status.message, entry_error) end
			if entry == nil then return ok("unknown", legacy_id, existing_status.message, "preparing legacy import has no reservation") end
			local resumed = self:_resume_reservation(route, entry)
			resumed.message_id = legacy_id
			return publish_after_enqueue(self, resumed)
		end
		local token, token_error = self:_guid()
		if token == nil then return ok("invalid", legacy_id, nil, token_error) end
		local entry, reserve_error = self:_reserve(route, request_text, request, token)
		if entry == nil then
			local code = if string.find(reserve_error or "", "capacity", 1, true) then "capacity"
				elseif string.find(reserve_error or "", "conflict", 1, true) then "conflict"
				elseif string.find(reserve_error or "", "unsupported schema", 1, true) then "unsupported_schema"
				else "unknown"
			return ok(code, legacy_id, nil, reserve_error)
		end
		local result = self:_resume_reservation(route, entry)
		result.message_id = legacy_id
		return publish_after_enqueue(self, result)
	end

	function MailboxV2.ImportLegacyDeadLetterAsync(
		self: EmbeddedMailbox,
		legacy_message: unknown,
		migration_id: string
	): EmbeddedMailboxResult
		local activation = self:_check_activation("migration")
		if activation ~= nil then return activation end
		local request, request_text, request_error = make_legacy_import_request(self, legacy_message, migration_id, "dead_letter")
		if request == nil or request_text == nil then return ok("invalid", nil, nil, request_error) end
		local legacy_id = request.public_id :: string
		local route = self:_legacy_route_key(legacy_id)
		local existing_status = legacy_import_status(self, route, request_text, legacy_id)
		if existing_status ~= nil then
			if existing_status.code ~= "duplicate" then return existing_status end
			local existing = as_dict(existing_status.message)
			if existing ~= nil and existing.State == "dead_lettered" then return existing_status end
			local existing_record, existing_error = self:_get_fresh(route)
			local record = as_dict(existing_record)
			if existing_error ~= nil or record == nil then
				return ok("unknown", legacy_id, nil, existing_error or "dead-letter import record is unavailable")
			end
			if record.state ~= "dead_lettering" then
				return ok("conflict", legacy_id, self:_record_snapshot(record), "legacy dead-letter import has an incompatible state")
			end
			local completed = self:_finish_dead_letter(route)
			completed.message_id = legacy_id
			return completed
		end

		local token, token_error = self:_guid()
		if token == nil then return ok("invalid", legacy_id, nil, token_error) end
		local now = self:_now()
		local candidate: EmbeddedMailboxDict = {
			version = VERSION,
			owner = clone_owner(self.owner),
			route = route,
			public_id = legacy_id,
			request_text = request_text,
			migration_target = "dead_letter",
			legacy_migration_id = migration_id,
			legacy_last_replay_token = request.legacy_last_replay_token,
			legacy_terminal_lock_token = request.legacy_terminal_lock_token,
			message_type = request.message_type,
			payload = clone_json(request.payload),
			sender_job_id = if type(request.legacy_sender_job_id) == "string" then request.legacy_sender_job_id else "",
			priority = "normal",
			available_at = request.available_at,
			expires_at = nil,
			created_at = request.legacy_created_at,
			updated_at = now,
			attempts = request.legacy_attempts,
			total_attempts = request.legacy_total_attempts,
			replay_count = request.legacy_replay_count,
			last_error = if type(request.legacy_last_error) == "string" then request.legacy_last_error else "Imported from legacy V3 dead-letter queue",
			dead_letter_reason = if type(request.legacy_last_error) == "string" then request.legacy_last_error else "Imported from legacy V3 dead-letter queue",
			legacy_dead_lettered_at = request.legacy_dead_lettered_at,
			dead_letter_token = token,
			dlq_placement_generation = 1,
			state = "dead_lettering",
			effect_outcome = "not_started",
		}
		local imported, import_error = self:_update_message(route, function(current)
			if current ~= nil then return current end
			return candidate
		end)
		if import_error ~= nil or imported == nil then
			return ok("unknown", legacy_id, imported, import_error or "legacy dead-letter import outcome is unknown")
		end
		if imported.request_text ~= request_text or imported.public_id ~= legacy_id or imported.migration_target ~= "dead_letter" then
			return ok("conflict", legacy_id, self:_record_snapshot(imported), "legacy dead-letter route is already bound to different content")
		end
		if imported.state == "dead_lettered" then
			return ok("duplicate", legacy_id, self:_record_snapshot(imported), nil)
		end
		if imported.state ~= "dead_lettering" then
			return ok("conflict", legacy_id, self:_record_snapshot(imported), "legacy dead-letter target has an incompatible state")
		end
		local completed = self:_finish_dead_letter(route)
		completed.message_id = legacy_id
		return completed
	end

	function MailboxV2.GetDeliveryAsync(self: EmbeddedMailbox, message_id: string): (EmbeddedMailboxDict?, EmbeddedMailboxResult)
		if type(message_id) ~= "string" or #message_id == 0 or #message_id > MAX_KEY_LENGTH then
			return nil, ok("invalid", message_id, nil, "message_id must be a valid V2 or legacy message ID")
		end
		local route = self:_route_from_public_id(message_id)
		local raw, read_error = self:_get(route)
		if read_error ~= nil then
			return nil, ok("unknown", message_id, nil, read_error)
		end
		local record = as_dict(raw)
		if record ~= nil then
			if not same_owner(record.owner, self.owner) then
				return nil, ok("conflict", message_id, nil, "message route belongs to another owner")
			end
			if record.version ~= VERSION then
				return nil, ok("unsupported_schema", message_id, nil, "canonical message version is unsupported")
			end
			return self:_record_snapshot(record), ok("success", message_id, nil, nil)
		end
		local entry, entry_error = self:_get_registry_entry(route)
		if entry_error ~= nil then
			return nil, ok("unknown", message_id, nil, entry_error)
		end
		if entry ~= nil then
			local request = as_dict(entry.request)
			local snapshot = ({
				Id = if request ~= nil and type(request.public_id) == "string" then request.public_id else message_id,
				State = "preparing",
				Phase = entry.phase,
				CreatedAt = entry.created_at,
				CapacityBlocked = entry.capacity_blocked == true,
			} :: unknown) :: EmbeddedMailboxDict
			return snapshot, ok("preparing", message_id, nil, nil)
		end
		return nil, ok("not_found", message_id, nil, "no canonical message or active preparation is present")
	end
	function MailboxV2._rows(self: EmbeddedMailbox, kind: string): ({ EmbeddedMailboxDict }, string?)
		local manifest, manifest_error = self:_get_manifest(kind)
		if manifest == nil then
			return {}, manifest_error
		end
		local result: { EmbeddedMailboxDict } = {}
		for slot_number, raw_slot in manifest.slots :: { unknown } do
			local slot = as_dict(raw_slot)
			if slot ~= nil and (slot.state == "open" or slot.state == "sealed" or slot.state == "draining") then
				local locator: EmbeddedMailboxLocator = {
					slot = slot_number,
					generation = slot.generation :: number,
					key = self:_segment_key(kind, slot_number, slot.generation :: number),
				}
				local raw_segment, read_error = self:_get(locator.key)
				local segment = as_dict(raw_segment)
				if read_error ~= nil then
					return result, read_error
				end
				if segment ~= nil and segment.generation == locator.generation and same_owner(segment.owner, self.owner) then
					if segment.version ~= VERSION then
						return result, "unsupported schema version: index segment version is unsupported"
					end
					if segment.kind ~= kind or segment.slot ~= locator.slot or type(segment.entries) ~= "table" then
						return result, "index segment metadata or entries are malformed"
					end
					for _, raw_row in segment.entries :: { unknown } do
						local row = as_dict(raw_row)
						if row ~= nil then
							local copied = clone_dict(row)
							copied.locator = { slot = locator.slot, generation = locator.generation }
							table.insert(result, copied)
						end
					end
				end
			end
		end
		return result, nil
	end

	function MailboxV2.GetQueueAsync(self: EmbeddedMailbox): ({ EmbeddedMailboxDict }, EmbeddedMailboxResult)
		local rows, rows_error = self:_rows("active")
		if rows_error ~= nil then
			return {}, ok(storage_error_code(rows_error), nil, nil, rows_error)
		end
		local result: { EmbeddedMailboxDict } = {}
		local seen: { [string]: boolean } = {}
		for _, row in rows do
			local route = tostring(row.route)
			local record_value, record_error = self:_get(route)
			if record_error ~= nil then
				return {}, ok("unknown", nil, nil, "queue canonical read failed: " .. record_error)
			end
			local record = as_dict(record_value)
			if record_value ~= nil and record == nil then
				return {}, ok("corrupt", nil, nil, "queue index points to a malformed canonical record")
			end
			if record ~= nil and same_owner(record.owner, self.owner)
				and record.state == "ready" and record.version ~= VERSION
			then
				return {}, ok("unsupported_schema", route, nil, "canonical message version is unsupported")
			end
			local locator = as_dict(row.locator)
			local record_locator = if record ~= nil then as_dict(record.locator) else nil
			if record ~= nil and same_owner(record.owner, self.owner) and record.state == "ready"
				and record.placement_generation == row.placement_generation and locator ~= nil and record_locator ~= nil
				and locator.slot == record_locator.slot and locator.generation == record_locator.generation
				and not seen[route]
			then
				local attempts = record.attempts
				local total_attempts = record.total_attempts
				local replay_count = record.replay_count
				local created_at = record.created_at
				local updated_at = record.updated_at
				local available_at = record.available_at
				local expires_at = record.expires_at
				local priority_valid = record.priority == "high" or record.priority == "normal"
					or record.priority == "background"
				local counters_valid = is_finite(attempts) and (attempts :: number) >= 0
					and math.floor(attempts :: number) == attempts
					and is_finite(total_attempts) and (total_attempts :: number) >= (attempts :: number)
					and math.floor(total_attempts :: number) == total_attempts
					and is_finite(replay_count) and (replay_count :: number) >= 0
					and math.floor(replay_count :: number) == replay_count
				local times_valid = is_finite(created_at) and is_finite(updated_at) and is_finite(available_at)
					and (expires_at == nil or (is_finite(expires_at) and (expires_at :: number) > (available_at :: number)))
				local ordering_valid = record.ordering_key == nil and record.ordering_sequence == nil
				if record.ordering_key ~= nil then
					ordering_valid = type(record.ordering_key) == "string" and record.ordering_key ~= ""
						and #record.ordering_key <= MAX_ORDERING_KEY_LENGTH
						and is_finite(record.ordering_sequence) and (record.ordering_sequence :: number) >= 1
						and math.floor(record.ordering_sequence :: number) == record.ordering_sequence
						and (record.ordering_sequence :: number) <= 9_007_199_254_740_991
				end
				if type(record.route) ~= "string" or record.route ~= route
					or type(record.message_type) ~= "string" or record.message_type == "" or #record.message_type > 100
					or not priority_valid or not counters_valid or not times_valid or not ordering_valid
					or not is_finite(record.placement_generation) or (record.placement_generation :: number) < 1
					or math.floor(record.placement_generation :: number) ~= record.placement_generation
				then
					return {}, ok("corrupt", route, nil, "ready mailbox message contains malformed priority, counter, time or ordering metadata")
				end
				seen[route] = true
				table.insert(result, self:_record_snapshot(record))
			end
		end
		local rank = { high = 1, normal = 2, background = 3 }
		table.sort(result, function(left, right)
			local left_rank = rank[tostring(left.Priority)] :: number
			local right_rank = rank[tostring(right.Priority)] :: number
			if left_rank ~= right_rank then return left_rank < right_rank end
			if left.CreatedAt ~= right.CreatedAt then
				return (left.CreatedAt :: number) < (right.CreatedAt :: number)
			end
			return tostring(left.Id) < tostring(right.Id)
		end)
		return result, ok("success", nil, nil, nil)
	end

	function MailboxV2._finish_acknowledgement(self: EmbeddedMailbox, route: string, token: string): EmbeddedMailboxResult
		local completed_at = self:_now()
		local finished, finish_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "acknowledging" or current.claim_token ~= token then
				return current
			end
			local next_record = clone_dict(current)
			next_record.state = "acknowledged"
			next_record.updated_at = completed_at
			next_record.terminal_at = completed_at
			next_record.effect_outcome = "handler_succeeded"
			return next_record
		end)
		if finish_error ~= nil then
			local code = if string.find(finish_error, "unsupported schema version", 1, true) then "unsupported_schema" else "unknown"
			return ok(code, route, nil, finish_error)
		end
		if finished == nil then
			return ok("unknown", route, nil, "acknowledgement completion could not be verified")
		end
		if finished.state == "acknowledged" then
			if type(finished.ordering_key) == "string" and is_finite(finished.ordering_sequence) then
				self:_release_ordering_slot(route, finished.ordering_key, finished.ordering_sequence :: number)
			end
			return ok("processed", route, self:_record_snapshot(finished), nil)
		end
		return ok("unknown", route, self:_record_snapshot(finished), "acknowledgement terminal state was not confirmed")
	end

	function MailboxV2._finish_dead_letter(self: EmbeddedMailbox, route: string): EmbeddedMailboxResult
		local record_value, read_error = self:_get(route)
		local record = as_dict(record_value)
		if read_error ~= nil or record == nil then
			return ok("unknown", route, nil, read_error or "dead-letter source record is missing")
		end
		if record.version ~= VERSION then
			return ok("unsupported_schema", route, nil, "canonical message version is unsupported")
		end
		if record.state == "dead_lettered" then
			return ok("duplicate", route, self:_record_snapshot(record), nil)
		end
		if record.state ~= "dead_lettering" then
			return ok("conflict", route, self:_record_snapshot(record), "record is not in dead_lettering state")
		end
		local placement = if is_finite(record.dlq_placement_generation) then record.dlq_placement_generation :: number else 1
		local locator, index_error = self:_append_index("dlq", {
			route = route,
			placement_generation = placement,
			reservation_token = record.dead_letter_token or route,
		})
		if locator == nil then
			local blocked_at = self:_now()
			local current, _ = self:_update_message(route, function(raw)
				if raw == nil or raw.state ~= "dead_lettering" then
					return raw
				end
				local next_record = clone_dict(raw)
				next_record.capacity_blocked = true
				next_record.updated_at = blocked_at
				return next_record
			end)
			return ok(if string.find(index_error or "", "capacity", 1, true) then "capacity" else "unknown", route, current, index_error)
		end
		local dead_lettered_at = self:_now()
		local terminal, terminal_error = self:_update_message(route, function(raw)
			if raw == nil or raw.state == "dead_lettered" then
				return raw
			end
			if raw.state ~= "dead_lettering" then
				return raw
			end
			local next_record = clone_dict(raw)
			next_record.state = "dead_lettered"
			next_record.dead_lettered_at = if is_finite(next_record.legacy_dead_lettered_at)
				then next_record.legacy_dead_lettered_at else dead_lettered_at
			next_record.updated_at = dead_lettered_at
			next_record.capacity_blocked = false
			next_record.dlq_locator = { slot = locator.slot, generation = locator.generation }
			return next_record
		end)
		if terminal_error ~= nil or terminal == nil or terminal.state ~= "dead_lettered" then
			return ok("unknown", route, terminal, terminal_error or "DLQ append committed but terminal status is unknown")
		end
		if type(terminal.ordering_key) == "string" and is_finite(terminal.ordering_sequence) then
			self:_release_ordering_slot(route, terminal.ordering_key, terminal.ordering_sequence :: number)
		end
		return ok("dead_lettered", route, self:_record_snapshot(terminal), nil)
	end

	function MailboxV2._claim(self: EmbeddedMailbox, route: string): (EmbeddedMailboxDict?, EmbeddedMailboxResult)
		local current_value, current_error = self:_get(route)
		if current_error ~= nil then
			return nil, ok("unknown", route, nil, "canonical claim read failed: " .. current_error)
		end
		local current_record = as_dict(current_value)
		if current_record == nil or not same_owner(current_record.owner, self.owner) then
			return nil, ok("not_found", route, nil, "message does not exist")
		end
		if current_record.state == "ready" or current_record.state == "claimed" then
			local blocked, ordering_error = self:_ordering_blocked(current_record, route)
			if blocked then return nil, ok("ordered", route, self:_record_snapshot(current_record), ordering_error) end
		end
		local token, generation_error = self:_guid()
		if token == nil then return nil, ok("invalid", route, nil, generation_error) end
		local now = self:_now()
		local claimed, claim_error = self:_update_message(route, function(current)
			if current == nil or not same_owner(current.owner, self.owner) then
				return current
			end
			if current.state == "ready" or current.state == "claimed" then
				local valid = valid_scheduling_record(current, route)
				if not valid then return current end
			end
			if current.ordering_key ~= current_record.ordering_key
				or current.ordering_sequence ~= current_record.ordering_sequence
			then
				return current
			end
			if current.state == "acknowledging" then
				return current
			end
			if current.state == "dead_lettering" then
				return current
			end
			if current.state == "ready" and is_finite(current.expires_at) and (current.expires_at :: number) <= now then
				local next_record = clone_dict(current)
				next_record.state = "expired"
				next_record.updated_at = now
				next_record.terminal_at = now
				next_record.effect_outcome = if (current.attempts :: number) > 0 then "handler_failed_or_unknown" else "not_started"
				return next_record
			end
			if current.state == "claimed" and is_finite(current.locked_until)
				and (current.locked_until :: number) + (self.options.clock_skew_grace_ms :: number) > now
			then
				return current
			end
			if current.state ~= "ready" and current.state ~= "claimed" then
				return current
			end
			if current.state == "ready" and (current.available_at :: number) > now then
				return current
			end
			if is_finite(current.expires_at) and (current.expires_at :: number) <= now then
				local next_record = clone_dict(current)
				next_record.state = "expired"
				next_record.updated_at = now
				next_record.terminal_at = now
				next_record.effect_outcome = if (current.attempts :: number) > 0 then "handler_failed_or_unknown" else "not_started"
				return next_record
			end
			if (current.attempts :: number) >= (self.options.max_attempts :: number) then
				local next_record = clone_dict(current)
				next_record.state = "dead_lettering"
				next_record.dead_letter_token = token
				next_record.dlq_placement_generation = 1
				next_record.updated_at = now
				next_record.last_error = current.last_error or "attempt limit reached"
				return next_record
			end
			local next_record = clone_dict(current)
			next_record.state = "claimed"
			next_record.claim_token = token
			next_record.claim_started_at = now
			next_record.locked_until = now + (self.options.lease_ms :: number)
			next_record.attempts = (current.attempts :: number) + 1
			next_record.total_attempts = (current.total_attempts :: number) + 1
			next_record.updated_at = now
			next_record.effect_outcome = "running"
			return next_record
		end)
		if claim_error ~= nil then
			if string.find(claim_error, "unsupported schema version", 1, true) then
				return nil, ok("unsupported_schema", route, nil, claim_error)
			end
			return nil, ok("unknown", route, nil, "claim outcome is unknown: " .. claim_error)
		end
		if claimed == nil then
			return nil, ok("not_found", route, nil, "message does not exist")
		end
		if claimed.state == "ready" or claimed.state == "claimed" then
			local valid, validation_error = valid_scheduling_record(claimed, route)
			if not valid then
				local code = if validation_error == "canonical message version is unsupported" then "unsupported_schema" else "corrupt"
				return nil, ok(code, route, nil, validation_error or "canonical scheduling metadata is malformed")
			end
		end
		if claimed.state == "acknowledging" then
			return nil, self:_finish_acknowledgement(route, tostring(claimed.claim_token))
		end
		if claimed.state == "dead_lettering" then
			return nil, self:_finish_dead_letter(route)
		end
		if claimed.state == "expired" then
			if type(claimed.ordering_key) == "string" and is_finite(claimed.ordering_sequence) then
				self:_release_ordering_slot(route, claimed.ordering_key, claimed.ordering_sequence :: number)
			end
			return nil, ok("expired", route, self:_record_snapshot(claimed), nil)
		end
		if claimed.state ~= "claimed" or claimed.claim_token ~= token then
			return nil, ok("busy", route, self:_record_snapshot(claimed), nil)
		end
		local verified_now = self:_now()
		if (claimed.locked_until :: number) - verified_now <= math.min(2000, (self.options.lease_ms :: number) / 4) then
			return nil, ok("unknown", route, self:_record_snapshot(claimed), "claim has insufficient verified lease margin")
		end
		return claimed, ok("claimed", route, self:_record_snapshot(claimed), nil)
	end


	function MailboxV2.RenewClaimAsync(self: EmbeddedMailbox, message_id: string, claim_token: string): EmbeddedMailboxResult
		if type(message_id) ~= "string" or message_id == "" or #message_id > MAX_KEY_LENGTH then
			return ok("invalid", message_id, nil, "message_id must be a valid v2 key")
		end
		if type(claim_token) ~= "string" or claim_token == "" or #claim_token > 256 then
			return ok("invalid", message_id, nil, "claim_token must be 1 to 256 bytes")
		end

		local route = self:_route_from_public_id(message_id)
		local now = self:_now()
		local renewal_id, generation_error = self:_guid()
		if renewal_id == nil then return ok("invalid", message_id, nil, generation_error) end
		local renewed, update_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "claimed" or current.claim_token ~= claim_token then
				return current
			end
			if not is_finite(current.claim_started_at) or (current.claim_started_at :: number) > now
				or not is_finite(current.locked_until) or (current.locked_until :: number) <= now
			then
				return current
			end
			local claim_started_at = current.claim_started_at :: number
			local horizon_end = claim_started_at + (self.options.lease_renewal_horizon_ms :: number)
			if now >= horizon_end then
				return current
			end
			local next_lease_until = math.min(now + (self.options.lease_ms :: number), horizon_end)
			local margin = math.min(2000, (self.options.lease_ms :: number) / 4)
			if next_lease_until - now <= margin then
				return current
			end
			local next_record = clone_dict(current)
			next_record.locked_until = next_lease_until
			next_record.lease_renewed_at = now
			next_record.last_renewal_id = renewal_id
			next_record.updated_at = now
			return next_record
		end)

		if update_error ~= nil or renewed == nil then
			local latest_value, read_error = self:_get(route)
			local latest = as_dict(latest_value)
			if read_error ~= nil then
				return ok("unknown", message_id, nil, "claim renewal outcome is unknown; verification read failed: " .. read_error)
			end
			if latest == nil or not same_owner(latest.owner, self.owner) then
				return ok("lease_lost", message_id, nil, "claim is missing or belongs to another owner")
			end
			if latest.state == "claimed" and latest.claim_token == claim_token
				and latest.last_renewal_id == renewal_id and is_finite(latest.locked_until)
				and (latest.locked_until :: number) > self:_now()
			then
				return ok("renewed", message_id, self:_record_snapshot(latest), "renewal was committed despite an ambiguous response")
			end
			return ok("unknown", message_id, self:_record_snapshot(latest),
				"claim renewal outcome could not be proven: " .. tostring(update_error or "no canonical record"))
		end

		if renewed.state ~= "claimed" or renewed.claim_token ~= claim_token then
			return ok("lease_lost", message_id, self:_record_snapshot(renewed), "claim token was fenced or the message is no longer claimed")
		end
		if renewed.last_renewal_id ~= renewal_id then
			local started = renewed.claim_started_at
			if is_finite(started) and now >= (started :: number) + (self.options.lease_renewal_horizon_ms :: number) then
				return ok("lease_horizon_reached", message_id, self:_record_snapshot(renewed), "bounded claim-renewal horizon has been reached")
			end
			if is_finite(renewed.locked_until) and (renewed.locked_until :: number) <= now then
				return ok("lease_lost", message_id, self:_record_snapshot(renewed), "claim lease expired before renewal")
			end
			return ok("lease_not_renewed", message_id, self:_record_snapshot(renewed), "claim remained owned but renewal was not applied")
		end
		return ok("renewed", message_id, self:_record_snapshot(renewed), nil)
	end

	function MailboxV2._complete_claim(self: EmbeddedMailbox, route: string, token: string): EmbeddedMailboxResult
		local transition_now = self:_now()
		local transition, transition_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "claimed" or current.claim_token ~= token then
				return current
			end
			if (current.locked_until :: number) <= transition_now then
				return current
			end
			local next_record = clone_dict(current)
			next_record.state = "acknowledging"
			next_record.updated_at = transition_now
			return next_record
		end)
		if transition_error ~= nil or transition == nil then
			return ok("unknown", route, nil, transition_error or "acknowledgement transition is unresolved")
		end
		if transition.state == "acknowledged" then
			return ok("duplicate", route, self:_record_snapshot(transition), nil)
		end
		if transition.state ~= "acknowledging" or transition.claim_token ~= token then
			return ok("conflict", route, self:_record_snapshot(transition), "claim was fenced before acknowledgement")
		end
		return self:_finish_acknowledgement(route, token)
	end

	function MailboxV2._retry_claim(self: EmbeddedMailbox, route: string, token: string, reason: string): EmbeddedMailboxResult
		local now = self:_now()
		local updated, update_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "claimed" or current.claim_token ~= token then
				return current
			end
			local next_record = clone_dict(current)
			next_record.last_error = string.sub(string.gsub(reason, "[^ -~]", "?"), 1, 512)
			next_record.effect_outcome = "handler_failed_or_unknown"
			next_record.updated_at = now
			if is_finite(current.expires_at) and (current.expires_at :: number) <= now then
				next_record.state = "expired"
				next_record.terminal_at = now
				next_record.effect_outcome = "handler_failed_or_unknown"
				next_record.claim_token = nil
				next_record.locked_until = 0
				return next_record
			end
			if (current.attempts :: number) >= (self.options.max_attempts :: number) then
				next_record.state = "dead_lettering"
				next_record.dead_letter_token = token
				next_record.dlq_placement_generation = if is_finite(current.dlq_placement_generation) then current.dlq_placement_generation else 1
				return next_record
			end
			local retry_attempts: number = current.attempts :: number
			local exponent_candidate: number = retry_attempts - 1
			if exponent_candidate < 0 then exponent_candidate = 0 end
			local exponent: number = if exponent_candidate > 16 then 16 else exponent_candidate
			local delay: number = math.min(self.options.retry_max_ms :: number, (self.options.retry_base_ms :: number) * (2 ^ exponent))
			local digest_input: string = route .. ":" .. tostring(retry_attempts)
			local digest_value: string = digest(digest_input)
			local jitter_seed: number = tonumber(string.sub(digest_value, 1, 4), 16) or 0
			local jitter_divisor: number = math.max(1, math.floor(delay / 4))
			local jitter: number = jitter_seed % jitter_divisor
			next_record.state = "ready"
			next_record.available_at = now + delay - math.floor(delay / 8) + jitter
			next_record.claim_token = nil
			next_record.locked_until = 0
			return next_record
		end)
		if update_error ~= nil or updated == nil then
			return ok("unknown", route, nil, update_error or "retry state could not be verified")
		end
		if updated.state == "dead_lettering" then
			return self:_finish_dead_letter(route)
		end
		if updated.state == "expired" then
			if type(updated.ordering_key) == "string" and is_finite(updated.ordering_sequence) then
			self:_release_ordering_slot(route, updated.ordering_key, updated.ordering_sequence :: number)
			end
			return ok("expired", route, self:_record_snapshot(updated), nil)
		end
		if updated.state ~= "ready" then
			return ok("conflict", route, self:_record_snapshot(updated), "claim was fenced before retry")
		end
		return ok("retry_scheduled", route, self:_record_snapshot(updated), nil)
	end

	local function process_next_internal(self: EmbeddedMailbox, handler: (unknown, EmbeddedMailboxDict, EmbeddedMailboxHandlerContext?) -> (unknown, string?)): EmbeddedMailboxResult
		if type(handler) ~= "function" then
			return ok("invalid", nil, nil, "handler must be a function")
		end
		local session_code, session_error = verify_active_record(self)
		if session_code ~= "success" then return ok(session_code, nil, nil, session_error) end
		local recovery = self:RecoverAsync()
		if recovery.code ~= "success" and recovery.code ~= "empty" then
			return recovery
		end
		local queue, queue_result = self:GetQueueAsync()
		if queue_result.code ~= "success" then
			return queue_result
		end
		if #queue == 0 then
			return ok("empty", nil, nil, nil)
		end
		local now = self:_now()
		local rank = { high = 1, normal = 2, background = 3 }
		table.sort(queue, function(left, right)
			local left_age = math.max(0, now - (left.CreatedAt :: number))
			local right_age = math.max(0, now - (right.CreatedAt :: number))
			local left_rank = rank[tostring(left.Priority)] or 2
			local right_rank = rank[tostring(right.Priority)] or 2
			if left_age >= (self.options.priority_aging_ms :: number) * 2 then left_rank = 1
			elseif left_age >= (self.options.priority_aging_ms :: number) then left_rank = math.min(left_rank, 2) end
			if right_age >= (self.options.priority_aging_ms :: number) * 2 then right_rank = 1
			elseif right_age >= (self.options.priority_aging_ms :: number) then right_rank = math.min(right_rank, 2) end
			if self.high_priority_streak >= (self.options.high_priority_burst :: number) then
				if tostring(left.Priority) == "high" then left_rank = 4 end
				if tostring(right.Priority) == "high" then right_rank = 4 end
			end
			if left_rank ~= right_rank then return left_rank < right_rank end
			if left.CreatedAt ~= right.CreatedAt then
				return (left.CreatedAt :: number) < (right.CreatedAt :: number)
			end
			return tostring(left.Id) < tostring(right.Id)
		end)
		for _, candidate in queue do
			local route = tostring(candidate.Id)
			local record, claim_result = self:_claim(route)
			if record ~= nil then
				if tostring(record.priority) == "high" then
					self.high_priority_streak += 1
				else
					self.high_priority_streak = 0
				end
				local session_code_after_claim, session_error_after_claim = verify_active_record(self)
				if session_code_after_claim ~= "success" then
					local released = self:_retry_claim(route, tostring(record.claim_token), "active Record guard changed before handler start: " .. tostring(session_error_after_claim))
					if released.code ~= "retry_scheduled" and released.code ~= "expired" and released.code ~= "dead_lettered" then return released end
					return ok(session_code_after_claim, route, nil, session_error_after_claim)
				end
				local snapshot = self:_record_snapshot(record)
				local token = tostring(record.claim_token)
				local lease_until = record.locked_until :: number
				local lease_lost = false
				local cancellation_reason: string? = nil
				local handler_done = false
				local handler_ok = false
				local handler_result: unknown = nil
				local handler_error: unknown = nil
				local function renew_for_handler(): EmbeddedMailboxResult
					if lease_lost then
						return ok("lease_lost", route, nil, cancellation_reason or "claim lease has been lost")
					end
					local renewal: EmbeddedMailboxResult
					local renewal_scheduler = self.options.lease_renewal_scheduler
					if type(renewal_scheduler) == "function" then
						local completed = false
						local scheduled_result: EmbeddedMailboxResult? = nil
						local lease_remaining_ms = math.max(0, lease_until - self:_now())
						local call_ok, submission = pcall(
							renewal_scheduler,
							route,
							0,
							lease_remaining_ms,
							function(): EmbeddedMailboxResult
								return self:RenewClaimAsync(route, token)
							end,
							function(result_value: unknown)
								if type(result_value) == "table" then
									scheduled_result = result_value :: EmbeddedMailboxResult
								else
									scheduled_result = ok("unknown", route, nil, "scheduler returned no structured renewal result")
								end
								completed = true
							end
						)
						if not call_ok then
							return ok("unknown", route, nil, "lease renewal scheduler raised: " .. tostring(submission))
						end
						if type(submission) ~= "table" or (submission :: EmbeddedMailboxDict).code ~= "accepted" then
							local reason = if type(submission) == "table" then tostring((submission :: EmbeddedMailboxDict).message or (submission :: EmbeddedMailboxDict).code)
								else "scheduler rejected renewal"
							return ok("unknown", route, nil, "lease renewal was not accepted by the shared scheduler: " .. reason)
						end
						local wait_deadline = os.clock() + math.max(0.01, lease_remaining_ms / 1000)
						while not completed and not lease_lost and os.clock() < wait_deadline do
							wait_scheduled(0.001)
						end
						if not completed then
							return ok("unknown", route, nil, "lease renewal did not complete before the local wait deadline")
						end
						renewal = scheduled_result or ok("unknown", route, nil, "lease renewal completion was missing")
					else
						renewal = self:RenewClaimAsync(route, token)
					end
					if renewal.code == "renewed" then
						local renewed_snapshot = as_dict(renewal.message)
						if renewed_snapshot ~= nil and is_finite(renewed_snapshot.LeaseUntil) then
							lease_until = renewed_snapshot.LeaseUntil :: number
						end
					elseif renewal.code ~= "unknown" and renewal.code ~= "lease_not_renewed" then
						lease_lost = true
						cancellation_reason = renewal.error or renewal.code
					elseif self:_now() >= lease_until then
						lease_lost = true
						cancellation_reason = renewal.error or "claim renewal could not be verified before the last verified lease deadline"
					end
					return renewal
				end
				local context: EmbeddedMailboxHandlerContext = {
					is_cancelled = function(): boolean return lease_lost end,
					cancellation_reason = function(): string? return cancellation_reason end,
					renew_lease_async = renew_for_handler,
				}
				spawn_scheduled(function()
					local call_ok, result_value, error_value = pcall(handler, clone_json(record.payload), snapshot, context)
					handler_ok = call_ok
					handler_result = result_value
					handler_error = error_value
					handler_done = true
				end)
				local renewal_interval = math.max(1, math.floor((self.options.lease_ms :: number) / 3))
				while not handler_done do
					wait_scheduled(renewal_interval / 1000)
					if handler_done then break end
					if not lease_lost then
						renew_for_handler()
					end
				end
				if lease_lost then
					return ok("unknown", route, nil, "handler ended after claim lease loss; external effect outcome is uncertain: " .. tostring(cancellation_reason or "claim ownership changed"))
				end
				if handler_ok and handler_result ~= false then
					return self:_complete_claim(route, token)
				end
				local reason = if not handler_ok then tostring(handler_result) else tostring(handler_error or "handler returned false")
				return self:_retry_claim(route, token, reason)
			elseif claim_result.code == "unknown" or claim_result.code == "capacity" or claim_result.code == "corrupt" then
				return claim_result
			end
		end
		return ok("empty", nil, nil, nil)
	end

	function MailboxV2.ProcessNextAsync(self: EmbeddedMailbox, handler: (unknown, EmbeddedMailboxDict, EmbeddedMailboxHandlerContext?) -> (unknown, string?)): EmbeddedMailboxResult
		local activation = self:_check_activation("process")
		if activation ~= nil then return activation end
		if self.processing then return ok("busy", nil, nil, "a ProcessNextAsync call is already running on this mailbox instance") end
		self.processing = true
		local call_ok, result = pcall(process_next_internal, self, handler)
		self.processing = false
		if not call_ok then return ok("unknown", nil, nil, tostring(result)) end
		if type(result) ~= "table" then return ok("unknown", nil, nil, "ProcessNextAsync returned no structured result") end
		return result :: EmbeddedMailboxResult
	end

	function MailboxV2.RecoverAsync(self: EmbeddedMailbox): EmbeddedMailboxResult
		local activation = self:_check_activation("recover")
		if activation ~= nil then return activation end
		local capacity_blocked_preparations = 0
		for shard = 1, (self.options.preparation_shard_count :: number) do
			local raw, read_error = self:_get(self:_registry_key(shard))
			if read_error ~= nil then
				return ok("unknown", nil, nil, "preparation recovery read failed: " .. read_error)
			end
			local registry = as_dict(raw)
			if registry ~= nil then
				if registry.version ~= VERSION or registry.shard ~= shard or not same_owner(registry.owner, self.owner) then
					return ok("corrupt", nil, nil, "preparation registry identity/version mismatch")
				end
				local entries = as_dict(registry.entries)
				if entries ~= nil then
					local routes: { string } = {}
					for route in entries do
						table.insert(routes, route)
					end
					table.sort(routes)
					for _, route in routes do
						local entry = self:_get_registry_entry(route)
						if entry ~= nil then
							local result = self:_resume_reservation(route, entry)
							if result.code ~= "accepted" and result.code ~= "duplicate" then
								local latest_entry, entry_error = self:_get_registry_entry(route)
								if result.code == "unknown" and entry_error == nil and latest_entry ~= nil and latest_entry.capacity_blocked == true then
									capacity_blocked_preparations += 1
								else
									return result
								end
							end
						end
					end
				end
			end
		end
		local rows, rows_error = self:_rows("active")
		if rows_error ~= nil then
			return ok(storage_error_code(rows_error), nil, nil, rows_error)
		end
		for _, row in rows do
			local route = tostring(row.route)
			local record_value, read_error = self:_get(route)
			local record = as_dict(record_value)
			if read_error ~= nil then
				return ok("unknown", route, nil, read_error)
			end
			if record ~= nil and same_owner(record.owner, self.owner) then
				if record.state == "acknowledging" then
					local result = self:_finish_acknowledgement(route, tostring(record.claim_token))
					if result.code ~= "processed" and result.code ~= "duplicate" then
						return result
					end
				elseif record.state == "claimed"
					and is_finite(record.locked_until)
					and (record.locked_until :: number) + (self.options.clock_skew_grace_ms :: number) <= self:_now()
				then
					local result = self:_retry_claim(route, tostring(record.claim_token), "claim lease expired; handler outcome is unknown")
					if result.code ~= "retry_scheduled" and result.code ~= "expired" and result.code ~= "dead_lettered" then
						return result
					end
				elseif record.state == "dead_lettering" then
					local result = self:_finish_dead_letter(route)
					if result.code ~= "dead_lettered" and result.code ~= "duplicate" then
						return result
					end
				elseif record.state == "replaying" then
					local replay_token = tostring(record.replay_operation_id)
					local sequenced_record, ordering_error = self:_ensure_replay_ordering_sequence(route, replay_token, record)
					if sequenced_record == nil then
						return ok("unknown", route, nil, ordering_error or "replay ordering recovery is unresolved")
					end
					record = sequenced_record
					local generation = record.pending_replay_generation
					local locator, append_error = self:_append_index("active", {
						route = route,
						placement_generation = generation,
						reservation_token = replay_token,
					})
					if locator == nil then
						return ok("unknown", route, nil, append_error)
					end
					local recovered_at = self:_now()
					local ready, ready_error = self:_update_message(route, function(current)
						if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= replay_token then
							return current
						end
						local next_record = clone_dict(current)
						next_record.state = "ready"
						next_record.placement_generation = generation
						next_record.locator = { slot = locator.slot, generation = locator.generation }
						next_record.updated_at = recovered_at
						next_record.claim_token = nil
						next_record.locked_until = 0
						return next_record
					end)
					if ready_error ~= nil or ready == nil or ready.state ~= "ready" then
						return ok("unknown", route, ready, ready_error or "replay readiness is unknown")
					end
				end
			end
		end
		local dlq_rows, dlq_rows_error = self:_rows("dlq")
		if dlq_rows_error ~= nil then
			return ok("unknown", nil, nil, dlq_rows_error)
		end
		local replay_seen: { [string]: boolean } = {}
		for _, row in dlq_rows do
			local route = tostring(row.route)
			if not replay_seen[route] then
				replay_seen[route] = true
				local record_value = self:_get(route)
				local record = as_dict(record_value)
				if record ~= nil and same_owner(record.owner, self.owner) and record.state == "replaying" then
					local replay_token = tostring(record.replay_operation_id)
					local sequenced_record, ordering_error = self:_ensure_replay_ordering_sequence(route, replay_token, record)
					if sequenced_record == nil then
						return ok("unknown", route, nil, ordering_error or "replay ordering recovery is unresolved")
					end
					record = sequenced_record
					local generation = record.pending_replay_generation
					local locator, append_error = self:_append_index("active", {
						route = route,
						placement_generation = generation,
						reservation_token = replay_token,
					})
					if locator == nil then
						return ok("unknown", route, nil, append_error)
					end
					local recovered_at = self:_now()
					local ready, ready_error = self:_update_message(route, function(current)
						if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= replay_token then
							return current
						end
						local next_record = clone_dict(current)
						next_record.state = "ready"
						next_record.placement_generation = generation
						next_record.locator = { slot = locator.slot, generation = locator.generation }
						next_record.updated_at = recovered_at
						next_record.claim_token = nil
						next_record.locked_until = 0
						return next_record
					end)
					if ready_error ~= nil or ready == nil or ready.state ~= "ready" then
						return ok("unknown", route, ready, ready_error or "replay readiness is unknown")
					end
				end
			end
		end
		local recovery_metadata: EmbeddedMailboxDict? = if capacity_blocked_preparations > 0
			then ({ capacity_blocked_preparations = capacity_blocked_preparations } :: unknown) :: EmbeddedMailboxDict
			else nil
		return ok("success", nil, recovery_metadata, nil)
	end

	function MailboxV2.GetDeadLettersAsync(self: EmbeddedMailbox, cursor: string?, page_size: number?): ({ EmbeddedMailboxDict }, string?, EmbeddedMailboxResult)
		local rows, rows_error = self:_rows("dlq")
		if rows_error ~= nil then
			return {}, nil, ok(storage_error_code(rows_error), nil, nil, rows_error)
		end
		local messages: { EmbeddedMailboxDict } = {}
		local seen: { [string]: boolean } = {}
		for _, row in rows do
			local route = tostring(row.route)
			if not seen[route] then
				local record_value, record_error = self:_get(route)
				if record_error ~= nil then
					return {}, nil, ok("unknown", nil, nil, "dead-letter canonical read failed: " .. record_error)
				end
				local record = as_dict(record_value)
				if record_value ~= nil and record == nil then
					return {}, nil, ok("corrupt", nil, nil, "dead-letter index points to a malformed canonical record")
				end
				if record ~= nil and same_owner(record.owner, self.owner) and record.state == "dead_lettered" then
					if record.version ~= VERSION then
						return {}, nil, ok("unsupported_schema", route, nil, "canonical message version is unsupported")
					end
					seen[route] = true
					table.insert(messages, self:_record_snapshot(record))
				end
			end
		end
		table.sort(messages, function(left, right)
			return (left.DeadLetteredAt or left.CreatedAt :: number) > (right.DeadLetteredAt or right.CreatedAt :: number)
		end)
		local offset = 0
		if cursor ~= nil then
			offset = tonumber(cursor) or -1
			if offset < 0 or offset ~= math.floor(offset) then
				return {}, nil, ok("invalid", nil, nil, "cursor must be a non-negative integer string")
			end
		end
		local limit = page_size or 50
		if not is_finite(limit) or limit < 1 or limit > 100 or limit ~= math.floor(limit) then
			return {}, nil, ok("invalid", nil, nil, "page_size must be an integer from 1 to 100")
		end
		local page: { EmbeddedMailboxDict } = {}
		for index = offset + 1, math.min(#messages, offset + limit) do
			table.insert(page, messages[index])
		end
		local next_cursor = if offset + #page < #messages then tostring(offset + #page) else nil
		return page, next_cursor, ok("success", nil, nil, nil)
	end

	function MailboxV2.ReplayDeadLetterAsync(self: EmbeddedMailbox, message_id: string, operation_id: string): EmbeddedMailboxResult
		local activation = self:_check_activation("replay")
		if activation ~= nil then return activation end
		local route = self:_route_from_public_id(message_id)
		local replay_now = self:_now()
		if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
			return ok("invalid", message_id, nil, "replay operation_id must be 1 to 256 bytes")
		end
		local record, read_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "dead_lettered" then
				return current
			end
			if current.last_replay_operation_id == operation_id then
				return current
			end
			local next_record = clone_dict(current)
			next_record.state = "replaying"
			next_record.last_replay_operation_id = operation_id
			next_record.replay_operation_id = operation_id
			next_record.pending_replay_generation = (current.placement_generation :: number) + 1
			next_record.replay_count = (current.replay_count :: number) + 1
			next_record.attempts = 0
			next_record.claim_token = nil
			next_record.locked_until = 0
			next_record.last_error = nil
			next_record.effect_outcome = "not_started"
			next_record.updated_at = replay_now
			return next_record
		end)
		if read_error ~= nil or record == nil then
			return ok("unknown", message_id, nil, read_error or "replay reservation is unknown")
		end
		if record.state == "ready" or record.state == "claimed" or record.state == "acknowledging" or record.state == "acknowledged" then
			if record.last_replay_operation_id == operation_id then
				return ok("duplicate", message_id, self:_record_snapshot(record), nil)
			end
		end
		if record.state ~= "replaying" or record.replay_operation_id ~= operation_id then
			return ok("conflict", message_id, self:_record_snapshot(record), "message is not available for replay")
		end
		local sequenced_record, ordering_error = self:_ensure_replay_ordering_sequence(route, operation_id, record)
		if sequenced_record == nil then
			return ok("unknown", message_id, self:_record_snapshot(record), ordering_error or "replay ordering is unresolved")
		end
		record = sequenced_record
		local locator, append_error = self:_append_index("active", {
			route = route,
			placement_generation = record.pending_replay_generation,
			reservation_token = operation_id,
		})
		if locator == nil then
			return ok("unknown", message_id, self:_record_snapshot(record), append_error)
		end
		local ready, ready_error = self:_update_message(message_id, function(current)
			if current == nil or current.state ~= "replaying" or current.replay_operation_id ~= operation_id then
				return current
			end
			local next_record = clone_dict(current)
			next_record.state = "ready"
			next_record.placement_generation = current.pending_replay_generation
			next_record.locator = { slot = locator.slot, generation = locator.generation }
			next_record.claim_token = nil
			next_record.locked_until = 0
			next_record.available_at = replay_now
			next_record.updated_at = replay_now
			return next_record
		end)
		if ready_error ~= nil or ready == nil or ready.state ~= "ready" then
			return ok("unknown", message_id, ready, ready_error or "replay outcome is unknown")
		end
		return ok("accepted", message_id, self:_record_snapshot(ready), nil)
	end

	function MailboxV2.DiscardDeadLetterAsync(self: EmbeddedMailbox, message_id: string, expected_replay_count: number): EmbeddedMailboxResult
		local activation = self:_check_activation("discard")
		if activation ~= nil then return activation end
		local route = self:_route_from_public_id(message_id)
		local discarded_at = self:_now()
		local discarded, discard_error = self:_update_message(route, function(current)
			if current == nil or current.state ~= "dead_lettered" or current.replay_count ~= expected_replay_count then
				return current
			end
			local next_record = clone_dict(current)
			next_record.state = "discarded"
			next_record.updated_at = discarded_at
			next_record.terminal_at = discarded_at
			return next_record
		end)
		if discard_error ~= nil or discarded == nil then
			return ok("unknown", message_id, nil, discard_error or "discard result is unknown")
		end
		if discarded.state ~= "discarded" then
			return ok("conflict", message_id, self:_record_snapshot(discarded), "dead letter changed or replay generation no longer matches")
		end
		return ok("discarded", message_id, self:_record_snapshot(discarded), nil)
	end

	function MailboxV2.GetStatsAsync(self: EmbeddedMailbox): (EmbeddedMailboxDict, EmbeddedMailboxResult)
		local queue, queue_result = self:GetQueueAsync()
		if queue_result.code ~= "success" then
			return {}, queue_result
		end
		local dlq, dlq_cursor, dlq_result = self:GetDeadLettersAsync(nil, 100)
		if dlq_result.code ~= "success" then
			return {}, dlq_result
		end
		local preparing = 0
		for shard = 1, (self.options.preparation_shard_count :: number) do
			local value, read_error = self:_get(self:_registry_key(shard))
			if read_error ~= nil then
				return {}, ok("unknown", nil, nil, "preparation registry stats read failed: " .. read_error)
			end
			if value ~= nil then
				local registry = as_dict(value)
				if registry == nil or registry.version ~= VERSION or registry.shard ~= shard
					or not same_owner(registry.owner, self.owner)
				then
					return {}, ok("corrupt", nil, nil, "preparation registry stats row is malformed or belongs to another owner")
				end
				local entries = as_dict(registry.entries)
				if entries == nil then
					return {}, ok("corrupt", nil, nil, "preparation registry entries are malformed")
				end
				for route, raw_entry in entries do
					local entry = as_dict(raw_entry)
					if type(route) ~= "string" or entry == nil or entry.route ~= route
						or not valid_text(entry.token, 128) or not valid_text(entry.phase, 32)
					then
						return {}, ok("corrupt", nil, nil, "preparation registry contains a malformed entry")
					end
					preparing += 1
				end
			end
		end
		local active_capacity = (self.options.max_segments :: number) * (self.options.segment_max_messages :: number)
		local dlq_capacity = (self.options.dlq_max_segments :: number) * (self.options.dlq_segment_max_messages :: number)
		local preparation_capacity = (self.options.preparation_shard_count :: number) * (self.options.preparation_max_entries_per_shard :: number)
		return {
			observed_at = self:_now(),
			consistency = "bounded_non_linearizable",
			completeness = {
				active_index = "complete_for_observed_manifest",
				dead_letter_index = if dlq_cursor == nil then "first_page_complete" else "page_only",
				preparation_registry = "all_configured_shards_read",
				global_snapshot = false,
			},
			exactness = {
				ready = "exact_over_observed_active_index",
				dead_lettered_page = "page_count_not_total",
				preparing_reservations = "observed_registry_entry_count",
				wakeups_published = "process_local",
				wakeup_publish_errors = "process_local",
			},
			scan = {
				active_index_capacity = active_capacity,
				dead_letter_index_capacity = dlq_capacity,
				dead_letter_page_size = 100,
				preparation_shard_count = self.options.preparation_shard_count,
			},
			ready = #queue,
			dead_lettered_page = #dlq,
			dead_letter_page_cursor = dlq_cursor,
			dead_lettered_page_has_more = dlq_cursor ~= nil,
			preparing_reservations = preparing,
			active_capacity = active_capacity,
			dlq_index_capacity = dlq_capacity,
			preparation_capacity = preparation_capacity,
			wakeups_enabled = self.options.wakeups ~= nil,
			wakeups_published = self.wakeup_published,
			wakeup_publish_errors = self.wakeup_publish_errors,
			rtbf_keyed_by_user_id = self.owner.user_id ~= nil,
		}, ok("success", nil, nil, nil)
	end

	function MailboxV2.ReclaimAsync(self: EmbeddedMailbox): EmbeddedMailboxResult
		local activation = self:_check_activation("maintenance")
		if activation ~= nil then return activation end
		local reclaimed_active = self:_reclaim_slot("active")
		local reclaimed_dlq = self:_reclaim_slot("dlq")
		return ok(if reclaimed_active or reclaimed_dlq then "success" else "empty", nil, nil, nil)
	end

	function MailboxV2.MaintenanceAsync(self: EmbeddedMailbox): (EmbeddedMailboxDict, EmbeddedMailboxResult)
		local activation = self:_check_activation("maintenance")
		if activation ~= nil then return {}, activation end

		local report: EmbeddedMailboxDict = {
			owner = clone_owner(self.owner),
			observed_at = self:_now(),
			complete = false,
			consistency = "bounded_non_linearizable",
		}
		local function finish(result: EmbeddedMailboxResult): (EmbeddedMailboxDict, EmbeddedMailboxResult)
			return report, result
		end

		local recover_ok, recovery = pcall(function()
			return self:RecoverAsync()
		end)
		if not recover_ok or type(recovery) ~= "table" then
			return finish(ok("unknown", nil, nil,
				"mailbox recovery raised: " .. tostring(recovery)))
		end
		report.recovery = recovery
		if recovery.code ~= "success" then
			return finish(recovery)
		end

		local reclaim_ok, reclaimed = pcall(function()
			return self:ReclaimAsync()
		end)
		if not reclaim_ok or type(reclaimed) ~= "table" then
			return finish(ok("unknown", nil, nil,
				"mailbox reclamation raised: " .. tostring(reclaimed)))
		end
		report.reclaim = reclaimed
		if reclaimed.code ~= "success" and reclaimed.code ~= "empty" then
			return finish(reclaimed)
		end

		local stats_ok, stats, stats_result = pcall(function()
			return self:GetStatsAsync()
		end)
		if not stats_ok or type(stats) ~= "table" or type(stats_result) ~= "table" then
			return finish(ok("unknown", nil, nil,
				"mailbox status snapshot raised: " .. tostring(stats)))
		end
		report.stats = stats
		report.consistency = stats.consistency or "bounded_non_linearizable"
		if stats_result.code ~= "success" then
			return finish(stats_result)
		end

		report.complete = true
		report.completed_at = self:_now()
		return finish(ok("success", nil, nil, nil))
	end

	type MockStoreState = {
		values: { [string]: unknown },
		update_calls: number,
		committed_update_calls: number,
		get_calls: number,
		remove_calls: number,
		fail_next_mode: string?,
		fail_update_call: number?,
		fail_update_call_mode: string?,
		delay_next_update_ms: number,
		delay_update_key: string?,
		advance_time: ((number) -> ())?,
		replay_next_update: number,
	}

	local MockStore = {}
	MockStore.__index = MockStore

	function MockStore.new(): MockStoreState
		local state: MockStoreState = {
			values = {},
			update_calls = 0,
			committed_update_calls = 0,
			get_calls = 0,
			remove_calls = 0,
			fail_next_mode = nil,
			fail_update_call = nil,
			fail_update_call_mode = nil,
			delay_next_update_ms = 0,
			delay_update_key = nil,
			advance_time = nil,
			replay_next_update = 0,
		}
		setmetatable(state, MockStore)
		return (state :: unknown) :: MockStoreState
	end

	function MockStore.GetAsync(self: MockStoreState, key: string): unknown
		self.get_calls += 1
		return clone_json(self.values[key])
	end

	function MockStore.GetAsyncFresh(self: MockStoreState, key: string): unknown
		self.get_calls += 1
		return clone_json(self.values[key])
	end

	function MockStore.UpdateAsync(self: MockStoreState, key: string, transform: (unknown, unknown?) -> (unknown, { number }?, EmbeddedMailboxDict?)): unknown
		self.update_calls += 1
		local failure_mode = nil
		if self.fail_update_call == self.update_calls then
			failure_mode = self.fail_update_call_mode
			self.fail_update_call = nil
			self.fail_update_call_mode = nil
		elseif self.fail_next_mode ~= nil then
			failure_mode = self.fail_next_mode
			self.fail_next_mode = nil
		end
		if failure_mode == "before" then
			error("injected failure before commit")
		end
		local old_value = clone_json(self.values[key])
		local proposed = transform(clone_json(old_value), nil)
		if self.replay_next_update > 0 then
			self.replay_next_update -= 1
			proposed = transform(clone_json(old_value), nil)
		end
		if proposed ~= nil then
			self.committed_update_calls += 1
			self.values[key] = clone_json(proposed)
		end
		local result = clone_json(self.values[key])
		if self.delay_next_update_ms > 0 and (self.delay_update_key == nil or self.delay_update_key == key) then
			local delay_ms = self.delay_next_update_ms
			self.delay_next_update_ms = 0
			self.delay_update_key = nil
			if self.advance_time ~= nil then
				self.advance_time(delay_ms)
			end
		end
		if failure_mode == "after" then
			error("injected response loss after commit")
		end
		return result
	end

	function MockStore.RemoveAsync(self: MockStoreState, key: string)
		self.remove_calls += 1
		self.values[key] = nil
	end

	function MockStore.FailNextUpdate(self: MockStoreState, mode: string)
		assert(mode == "before" or mode == "after", "mode must be before or after")
		self.fail_next_mode = mode
	end

	function MockStore.ReplayNextUpdate(self: MockStoreState)
		self.replay_next_update += 1
	end

	function MockStore.FailUpdateAt(self: MockStoreState, update_call: number, mode: string)
		assert(type(update_call) == "number" and update_call == math.floor(update_call)
			and update_call > self.update_calls, "update_call must target a future UpdateAsync call")
		assert(mode == "before" or mode == "after", "mode must be before or after")
		self.fail_update_call = update_call
		self.fail_update_call_mode = mode
	end

	function MockStore:DelayNextUpdateBy(delay_ms: number)
		assert(is_finite(delay_ms) and delay_ms >= 0 and delay_ms <= 60_000,
			"delay_ms must be finite and between 0 and 60000")
		self.delay_next_update_ms = delay_ms
		self.delay_update_key = nil
	end

	function MockStore:DelayUpdateForKey(key: string, delay_ms: number)
		assert(type(key) == "string" and key ~= "", "key must be a non-empty string")
		assert(is_finite(delay_ms) and delay_ms >= 0 and delay_ms <= 60_000,
			"delay_ms must be finite and between 0 and 60000")
		self.delay_next_update_ms = delay_ms
		self.delay_update_key = key
	end

	function MailboxV2.MockStore()
		return MockStore.new()
	end

	MailboxV2.Version = VERSION

end
-- END EMBEDDED MAILBOX V2 MODULE

type MetadataValue = boolean | number | string
export type Metadata = { [string]: MetadataValue }

export type JsonValue =
	boolean
| number
| string
| buffer
| { JsonValue }
| { [string]: JsonValue }

export type SessionState =
	"closed"
| "acquiring"
| "active"
| "saving"
| "releasing"
| "fenced"
| "unknown"
| "tombstoned"
| "corrupt"
| "future"

export type ResultCode =
	"success"
| "created"
| "loaded"
| "saved"
| "closed"
| "deleted"
| "enqueued"
| "processed"
| "empty"
| "locked"
| "already_open"
| "busy"
| "closing"
| "fenced"
| "unknown"
| "conflict"
| "validation"
| "migration"
| "future_schema"
| "corrupt"
| "tombstoned"
| "legacy"
| "budget"
| "retry_exhausted"
| "invalid"
| "not_found"
| "duplicate"
| "capacity"
| "disabled"

local RESULT_CODE_SET: { [string]: boolean } = {
	success = true, created = true, loaded = true, saved = true, closed = true,
	deleted = true, enqueued = true, processed = true, empty = true, locked = true,
	already_open = true, busy = true, closing = true, fenced = true, unknown = true,
	conflict = true, validation = true, migration = true, future_schema = true,
	corrupt = true, tombstoned = true, legacy = true, budget = true,
	retry_exhausted = true, invalid = true, not_found = true, duplicate = true,
	capacity = true, disabled = true,
}

local function normalize_result_code(value: unknown): ResultCode?
	if value == nil then return nil end
	if type(value) == "string" and RESULT_CODE_SET[value] == true then
		return value :: ResultCode
	end
	return "unknown"
end

export type DiagnosticPhase =
	"create"
| "open"
| "normalize"
| "update"

export type Migration = (
	from_version: number,
	value: JsonValue
) -> JsonValue

export type Validator = (
	value: JsonValue
) -> (boolean, string?)

export type LegacyDecoder = (
	raw: unknown
) -> (JsonValue, number?)

export type Observer = (
	event: string,
	key: string,
	result: ResultCode,
	message: string?
) -> ()

export type ChangeEvent = {
	OperationId: string,
	Sequence: number,
	Path: { string },
	OldValue: JsonValue?,
	NewValue: JsonValue?,
	Truncated: boolean,
	Kind: string,
}

export type ChangeObserver = (event: ChangeEvent) -> ()

export type ChangeSubscription = {
	Disconnect: (self: ChangeSubscription) -> (),
}

export type HandoffStatus =
	"pending"
| "accepted"
| "released"
| "busy"
| "stale"
| "not_owner"
| "failed"

local HANDOFF_STATUS_SET: { [string]: boolean } = {
	pending = true, accepted = true, released = true, busy = true,
	stale = true, not_owner = true, failed = true,
}

local function normalize_handoff_status(value: unknown): HandoffStatus?
	if type(value) == "string" and HANDOFF_STATUS_SET[value] == true then
		return value :: HandoffStatus
	end
	return nil
end

export type HandoffResult = {
	RequestId: string,
	Status: HandoffStatus,
	Generation: number,
	TargetJobId: string,
	Published: boolean,
	Deadline: number,
	Suppressed: number,
	Acks: number,
}

export type RecordError = {
	Code: ResultCode,
	Message: string?,
	Retryable: boolean,
	RequiresVerification: boolean,
	DurableOutcome: "not_submitted" | "not_committed" | "unknown" | "committed",
	OperationId: string?,
	Generation: number?,
	Revision: number?,
}


export type MessageObserver = (
	message_type: string,
	data: JsonValue?,
	sent_at: number,
	sender_job_id: string
) -> ()

export type QueueObserver = (
	message_type: string,
	data: JsonValue?,
	attempts: number,
	message_id: string,
	sender_job_id: string,
	created_at: number
) -> (boolean, string?)

export type DurableSnapshot = {
	Data: JsonValue?,
	Revision: number,
	Generation: number,
	UpdatedAt: number,
	ConfirmedAt: number,
	WriteId: string?,
	Reason: string,
	Tombstoned: boolean,
	UserIds: { number },
	Metadata: Metadata,
	BackendVersion: string?,
	BackendCreatedAt: number?,
	BackendUpdatedAt: number?,
}

export type Snapshot = {
	Data: JsonValue?,
	State: SessionState,
	Key: string,
	SchemaVersion: number,
	Generation: number,
	Revision: number,
	CreatedAt: number,
	UpdatedAt: number,
	Tombstoned: boolean,
	SessionActive: boolean,
	LeaseUntil: number?,
	SessionJobId: string?,
	SessionPlaceId: number?,
	UserIds: { number },
	Metadata: Metadata,
	BackendVersion: string?,
	BackendCreatedAt: number?,
	BackendUpdatedAt: number?,
}

export type SessionStatus = {
	StoreName: string,
	Scope: string,
	ProfileKey: string,
	Observation: "not_found" | "tombstoned" | "no_session" | "active_lease_observed" | "expired_lease_observed",
	ObservedAt: number,
	Generation: number?,
	Revision: number?,
	OwnerJobId: string?,
	OwnerPlaceId: number?,
	AcquiredAt: number?,
	LeaseUntil: number?,
	LeaseRemainingSeconds: number?,
	LeaseAppearsAvailable: boolean,
	IsAuthoritativeOwnershipDecision: false,
}

type SessionStatusResolver = (
	name: string,
	scope: string,
	key: string,
	operation_deadline: number?,
	mock: boolean
) -> (SessionStatus?, ResultCode, string?)

export type ProfileDoctorClassification =
	"missing" | "legacy" | "future_schema" | "corrupt" | "unreadable"
	| "tombstoned" | "active_session" | "expired_session" | "no_session"

export type ProfileDoctorOptions = {
	operation_deadline: number?,
	legacy_decoder: LegacyDecoder?,
	max_nodes: number?,
	max_depth: number?,
	max_changes: number?,
}

export type ProfileInspection = {
	StoreName: string,
	Scope: string,
	ProfileKey: string,
	ObservedAt: number,
	Consistency: "point_in_time_non_authoritative",
	Classification: ProfileDoctorClassification,
	ReadResult: ResultCode,
	SchemaVersion: number?,
	Revision: number?,
	Generation: number?,
	CreatedAt: number?,
	UpdatedAt: number?,
	Tombstoned: boolean?,
	SessionActive: boolean?,
	LeaseUntil: number?,
	OwnerJobId: string?,
	OwnerPlaceId: number?,
	BackendVersion: string?,
	DataNodeCount: number?,
	DataDepth: number?,
	DataEncodedBytes: number?,
	DataSizeAvailable: boolean,
	DataSummaryTruncated: boolean,
}

export type ProfileDiffChange = {
	Path: string,
	Kind: "added" | "removed" | "changed",
	BeforeType: string?,
	AfterType: string?,
}

export type ProfileVersionDiff = {
	StoreName: string,
	Scope: string,
	ProfileKey: string,
	BeforeVersion: string,
	AfterVersion: string,
	BeforeRevision: number,
	AfterRevision: number,
	BeforeSchemaVersion: number,
	AfterSchemaVersion: number,
	ObservedAt: number,
	Consistency: "bounded_historical_diff",
	VisitedNodes: number,
	Truncated: boolean,
	Changes: { ProfileDiffChange },
}

export type MigrationRegistration = {
	id: string,
	from_version: number,
	to_version: number,
	implementation_revision: string,
	compatible_schema_min: number,
	compatible_schema_max: number,
	transform: Migration,
	validator: Validator?,
}

export type MigrationPreviewOptions = {
	operation_deadline: number?,
	legacy_decoder: LegacyDecoder?,
	max_nodes: number?,
	max_depth: number?,
	max_changes: number?,
}

export type MigrationPreviewStep = {
	Id: string,
	FromVersion: number,
	ToVersion: number,
	ImplementationRevision: string,
}

export type MigrationPreview = {
	StoreName: string,
	Scope: string,
	ProfileKey: string,
	ObservedAt: number,
	Consistency: "read_only_non_authoritative_preview",
	SourceSchemaVersion: number,
	TargetSchemaVersion: number,
	SourceRevision: number,
	SourceGeneration: number,
	SessionActive: boolean,
	Steps: { MigrationPreviewStep },
	Changes: { ProfileDiffChange },
	VisitedNodes: number,
	Truncated: boolean,
	TargetDataNodeCount: number,
	TargetDataDepth: number,
	TargetDataEncodedBytes: number?,
	TargetDataSizeAvailable: boolean,
}

export type HistoryEntry = {
	Version: string,
	CreatedTime: number,
	IsDeleted: boolean,
}

type HistoryRecoveryCandidate = {
	ObservedVersion: string,
	SourceVersion: string,
	CorruptReason: string,
	Envelope: Envelope,
	UserIds: { number },
	Metadata: Metadata,
}

export type BackendInfoView = {
	Version: string?,
	CreatedTime: number,
	UpdatedTime: number,
	UserIds: { number },
	Metadata: Metadata,
}

export type QueueMessage = {
	Id: string,
	Type: string,
	Data: JsonValue?,
	Attempts: number,
	TotalAttempts: number,
	ReplayCount: number,
	SenderJobId: string,
	CreatedAt: number,
	Priority: string?,
	OrderingKey: string?,
	OrderingSequence: number?,
	AvailableAt: number?,
	ExpiresAt: number?,
}

export type DeadLetterMessage = QueueMessage & {
	DeadLetteredAt: number,
	LastError: string,
	LockToken: string?,
	LockedUntil: number?,
}

export type MockQueueClaim = {
	Id: string,
	LockToken: string,
	LockedUntil: number,
}

export type TransactionStatus =
	"committed" | "duplicate" | "conflict" | "capacity" | "fenced" | "retryable"
	| "unknown" | "disabled" | "invalid" | "validation" | "corrupt"

export type TransactionReceiptStatusCode =
	"committed" | "not_found" | "expired" | "conflict" | "unknown"
	| "disabled" | "invalid" | "corrupt" | "legacy" | "future_schema" | "unsupported"

export type TransactionReceiptStatus = {
	code: TransactionReceiptStatusCode,
	message: string?,
	result: JsonValue?,
	result_present: boolean?,
	committed_revision: number?,
	created_at: number?,
	expires_at: number?,
}

export type TransactionOptions = {
	request: JsonValue?,
	receipt_retention_seconds: number?,
}

export type OutboxEventSpec = {
	target_store: string,
	target_scope: string,
	target_key: string,
	type: string,
	payload_version: number,
	data: JsonValue,
	target_user_id: number?,
	correlation_id: string?,
	causation_id: string?,
}

export type OutboxEvent = {
	EventId: string,
	EventType: string,
	PayloadVersion: number,
	Payload: JsonValue,
	DestinationStoreName: string,
	DestinationScope: string,
	DestinationProfileKey: string,
	DestinationUserId: number?,
	CorrelationId: string?,
	CausationId: string?,
	CreatedAt: number,
	Attempts: number,
	State: "pending" | "delivered" | "unknown" | "blocked",
	LastError: string?,
	DeliveredAt: number?,
	DestinationReceiptId: string?,
}

export type OutboxDispatcher = (event: OutboxEvent) -> (boolean, string?)

export type TransactionReducer = (JsonValue?, JsonValue?) -> (JsonValue?, JsonValue?)

export type Options = {
	schema_version: number,
	migrations: { [number]: Migration }?,
	validator: Validator?,
	legacy_decoder: LegacyDecoder?,
	user_ids: { number }?,
	metadata: Metadata?,
	autosave_interval: number?,
	lease_duration: number?,
	lease_renewal: number?,
	retry_attempts: number?,
	operation_deadline: number?,
	shutdown_deadline: number?,
	shutdown_attempts: number?,
	budget_wait: number?,
	messaging_enabled: boolean?,
	takeover_enabled: boolean?,
	takeover_wait: number?,
	message_topic_prefix: string?,
	durable_queue_enabled: boolean?,
	transactional_operations_enabled: boolean?,
	queue_store_name: string?,
	queue_poll_interval: number?,
	queue_lease_duration: number?,
	queue_max_messages: number?,
	queue_max_bytes: number?,
	queue_max_attempts: number?,
	on_event: Observer?,
	on_message: MessageObserver?,
	on_queue_message: QueueObserver?,
	on_queue_message_async: ((string, JsonValue?, number, string, string, number, unknown) -> (boolean, string?))?,
}


type Tombstone = {
	deleted_at: number,
	generation: number,
}

type SessionEnvelope = {
	token: string,
	generation: number,
	job_id: string,
	place_id: number,
	acquired_at: number,
	lease_until: number,
}

type OperationReceipt = {
	request_identity: string,
	result: JsonValue?,
	result_present: boolean,
	committed_revision: number,
	created_at: number,
	expires_at: number,
}

type OutboxEventRecord = {
	id: string,
	event_type: string,
	payload_version: number,
	request_identity: string,
	payload: JsonValue,
	destination_store_name: string,
	destination_scope: string,
	destination_profile_key: string,
	destination_user_id: number?,
	correlation_id: string?,
	causation_id: string?,
	created_at: number,
	attempts: number,
	state: "pending" | "delivered" | "unknown" | "blocked",
	last_error: string?,
	delivered_at: number?,
	destination_receipt_id: string?,
}

type OutboxEntry = {
	stored: OutboxEventRecord,
	public: OutboxEvent,
}

type EnvelopeSidecars = {
	version: number,
	inbox_receipts: { [string]: OperationReceipt },
	transaction_receipts: { [string]: OperationReceipt },
	outbox_events: { [string]: OutboxEventRecord },
}

type Envelope = {
	implementation_version: number,
	schema_version: number,
	revision: number,
	fencing_generation: number,
	created_at: number,
	updated_at: number,
	data: JsonValue?,
	user_ids: { number }?,
	tombstone: Tombstone?,
	session: SessionEnvelope?,
	sidecars: EnvelopeSidecars?,
	write_id: string,
}

type NonFiniteNumberKind = "nan" | "positive_infinity" | "negative_infinity"

type NonFinitePathSegment =
	{ kind: "string", key: string }
	| { kind: "number", key: number }

type NonFiniteNumberMarker = {
	path: { NonFinitePathSegment },
	kind: NonFiniteNumberKind,
}

type BackendInfo = {
	Version: string?,
	CreatedTime: number,
	UpdatedTime: number,
	UserIds: { number },
	Metadata: Metadata,
	RawMetadata: Metadata,
}

type Backend = {
	name: string,
	scope: string,
	key: string,
	store: DataStore?,
	mock: boolean,
}

type UpdateTransform = (
	raw: unknown,
	info: BackendInfo?
) -> (unknown, { number }?, Metadata?)

type MockVersion = {
	Version: string,
	CreatedTime: number,
	UpdatedTime: number,
	Value: JsonValue?,
	UserIds: { number },
	Metadata: Metadata,
	Deleted: boolean,
}

type MockEntry = {
	Value: JsonValue?,
	UserIds: { number },
	Metadata: Metadata,
	Version: string,
	CreatedTime: number,
	UpdatedTime: number,
	Versions: { [string]: MockVersion },
	VersionOrder: { string },
}

type QueueItem = {
	id: string,
	type: string,
	data: JsonValue?,
	attempts: number,
	total_attempts: number,
	replay_count: number,
	last_replay_token: string?,
	sender_job_id: string,
	created_at: number,
	locked_until: number,
	lock_token: string?,
}

type DeadLetterItem = QueueItem & {
	dead_lettered_at: number,
	last_error: string,
	terminal_lock_token: string?,
}

type QueueOwner = {
	name: string,
	scope: string,
	key: string,
}

type QueueEnvelope = {
	implementation_version: number,
	owner: QueueOwner,
	messages: { QueueItem },
	dead_letters: { DeadLetterItem },
}

type PendingDurableOperation = {
	kind: "save" | "renew" | "release",
	snapshot: JsonValue?,
	captured_change_sequence: number,
	expected_revision: number,
	target_revision: number,
	operation_id: string,
	session_token: string,
	fencing_generation: number,
	reason: string,
	started_at: number,
	attempts: number,
}

type InternalState = {
	change_observers: { [number]: ChangeObserver },
	change_observer_next_id: number,
	change_dispatch_queue: { ChangeEvent },
	change_dispatch_head: number,
	change_dispatch_tail: number,
	change_dispatch_running: boolean,
	change_events_dropped: number,
	takeover_seen: { [string]: HandoffStatus },
	takeover_seen_order: { string },
	takeover_request_id: string?,
	takeover_requester_job_id: string?,
	handoff_request_id: string?,
	handoff_target_job_id: string?,
	handoff_target_token: string?,
	handoff_target_generation: number?,
	handoff_status: HandoffStatus?,
	handoff_deadline: number,
	handoff_published: boolean,
	handoff_last_publish: number,
	handoff_requests_suppressed: number,
	handoff_ack_count: number,
	current_operation_id: string?,
	pending_open_token: string?,
	pending_open_write_id: string?,
	pending_open_default_data: JsonValue?,
	name: string,
	scope: string,
	key: string,
	backend: Backend,
	queue_backend: Backend?,
	queue_legacy_checked: boolean,
	options: Options,
	state: SessionState,
	data: JsonValue?,
	public_data_source: JsonValue?,
	public_data_detached: boolean,
	public_record: unknown,
	token: string?,
	generation: number,
	revision: number,
	created_at: number,
	updated_at: number,
	user_ids: { number },
	metadata: Metadata,
	tombstoned: boolean,
	next_autosave: number,
	next_renewal: number,
	next_message_subscribe: number,
	next_queue_poll: number,
	busy: boolean,
	queue_busy: boolean,
	mailbox_v2_binding: boolean,
	mailbox_v2: EmbeddedMailbox?,
	save_requested: boolean,
	shutdown: boolean,
	retired: boolean,
	takeover_requested: boolean,
	queue_hint: boolean,
	message_topic: string,
	message_subscription: RBXScriptConnection?,
	last_error: string?,
	last_error_info: RecordError?,
	last_result: ResultCode?,
	last_observed: number,
	observer_errors: number,
	last_saved: DurableSnapshot?,
	change_sequence: number,
	saved_change_sequence: number,
	durable_lease_until: number,
	pending_operation: PendingDurableOperation?,
	pending_transaction: { operation_id: string, kind: string, request_identity: string }?,
	next_reconciliation: number,
	last_reconciliation_category: string?,
	dirty_since_local: number?,
	last_successful_write_local: number?,
}

export type Record = {
	Data: JsonValue?,
	State: SessionState,
	Key: string,
	Generation: number,
	Revision: number,
	CreatedAt: number,
	UpdatedAt: number,
	Tombstoned: boolean,
	LastError: string?,
	Open: (self: Record, default_data: JsonValue?, recreate: boolean?) -> (ResultCode, string?),
	Get: (self: Record) -> JsonValue?,
	GetKey: (self: Record) -> string,
	GetState: (self: Record) -> SessionState,
	GetRevision: (self: Record) -> number,
	GetGeneration: (self: Record) -> number,
	IsOpen: (self: Record) -> boolean,
	GetBackendInfo: (self: Record) -> BackendInfoView,
	GetLastSaved: (self: Record) -> DurableSnapshot?,
	IsDirty: (self: Record) -> boolean,
	CanMutate: (self: Record) -> (boolean, string?),
	GetDurabilityStatus: (self: Record) -> { [string]: any },
	GetLastError: (self: Record) -> RecordError?,
	GetHandoff: (self: Record) -> HandoffResult?,
	SubscribeChanges: (self: Record, observer: ChangeObserver) -> (ChangeSubscription?, ResultCode, string?),
	GetUserIds: (self: Record) -> { number },
	SetUserIds: (self: Record, user_ids: { number }) -> (ResultCode, string?),
	AddUserId: (self: Record, user_id: number) -> (ResultCode, string?),
	RemoveUserId: (self: Record, user_id: number) -> (ResultCode, string?),
	GetMetadata: (self: Record) -> Metadata,
	SetMetadata: (self: Record, metadata: Metadata) -> (ResultCode, string?),
	UpdateMetadata: (self: Record, callback: (Metadata) -> Metadata) -> (ResultCode, string?),
	Touch: (self: Record) -> (ResultCode, string?),
	Update: (self: Record, callback: (JsonValue?) -> JsonValue?) -> (ResultCode, string?),
	Reconcile: (self: Record, template: JsonValue) -> (ResultCode, string?),
	Save: (self: Record, reason: string?) -> (ResultCode, string?),
	TransactAsync: (self: Record, operation_id: string, reducer: TransactionReducer, options: TransactionOptions) -> (JsonValue?, TransactionStatus, string?),
	GetTransactionStatusAsync: (self: Record, operation_id: string, request: JsonValue) -> TransactionReceiptStatus,
	ApplyInboxAsync: (self: Record, message_id: string, message_type: string, payload: JsonValue, reducer: TransactionReducer, options: TransactionOptions?) -> (JsonValue?, TransactionStatus, string?),
	CommitWithOutboxAsync: (self: Record, commit_key: string, command_type: string, command_payload: JsonValue, outbox_events: { OutboxEventSpec }, reducer: TransactionReducer, options: TransactionOptions?) -> (JsonValue?, TransactionStatus, string?),
	GetOutboxAsync: (self: Record, max_events: number?) -> ({ OutboxEvent }, ResultCode, string?),
	DispatchOutboxAsync: (self: Record, dispatcher: OutboxDispatcher, max_events: number?) -> (number, ResultCode, string?),
	PruneOutboxAsync: (self: Record, delivered_before_unix: number, max_events: number?) -> (number, ResultCode, string?),
	MessageAsync: (self: Record, message_type: string, data: JsonValue?) -> (ResultCode, string?),
	GetIdentity: (self: Record) -> { [string]: unknown },
	GetMailboxOwner: (self: Record) -> { [string]: unknown },
	CreateMailboxStoreAdapter: (self: Record) -> (unknown?, ResultCode, string?),
	BindMailboxV2Async: (self: Record, mailbox: unknown) -> (ResultCode, string?),
	EnqueueAsync: (self: Record, message_type: string, data: JsonValue?, enqueue_options: { [string]: unknown }?) -> (ResultCode, string?),
	ProcessQueueAsync: (self: Record, max_messages: number?) -> (ResultCode, string?),
	GetQueueAsync: (self: Record) -> ({ QueueMessage }, ResultCode, string?),
	GetDeadLettersAsync: (self: Record) -> ({ DeadLetterMessage }, ResultCode, string?),
	ClaimDeadLetterAsync: (self: Record, message_id: string) -> (DeadLetterMessage?, ResultCode, string?),
	ReplayDeadLetterAsync: (self: Record, message_id: string, lock_token: string) -> (ResultCode, string?),
	DiscardDeadLetterAsync: (self: Record, message_id: string, lock_token: string) -> (ResultCode, string?),
	Close: (self: Record) -> (ResultCode, string?),
	Delete: (self: Record) -> (ResultCode, string?),
	Stats: (self: Record) -> { [string]: number | string? },
}

local IMPLEMENTATION_VERSION = 2
local QUEUE_IMPLEMENTATION_VERSION = 3
local DEFAULT_AUTOSAVE_INTERVAL = 300
local DEFAULT_LEASE_DURATION = 180
local DEFAULT_LEASE_RENEWAL = 60
local DEFAULT_RETRY_ATTEMPTS = 5
local MAX_RETRY_ATTEMPTS = 12
local DEFAULT_OPERATION_DEADLINE = 20
local DEFAULT_SHUTDOWN_DEADLINE = 25
local DEFAULT_SHUTDOWN_ATTEMPTS = 2
local DEFAULT_MAX_CONCURRENT_REQUESTS = 4
local DEFAULT_BUDGET_WAIT = 2
local MIN_RETRY_DELAY = 0.25
local MAX_RETRY_DELAY = 4
local SCHEDULER_STEP = 1
local DEFAULT_TAKEOVER_WAIT = 2
local DEFAULT_MESSAGE_TOPIC_PREFIX = "recordstore:"
local DEFAULT_QUEUE_STORE_NAME = "RecordStoreQueue"
local DEFAULT_QUEUE_POLL_INTERVAL = 10
local DEFAULT_QUEUE_LEASE_DURATION = 60
local DEFAULT_QUEUE_MAX_MESSAGES = 100
local DEFAULT_QUEUE_MAX_BYTES = 250_000
local DEFAULT_QUEUE_MAX_ATTEMPTS = 5
local MAX_QUEUE_ATTEMPTS = 12
local MAX_QUEUE_ERROR_LENGTH = 256
local MAX_MESSAGE_BYTES = 900
local CHANGE_OBSERVER_CAPACITY = 1024
local CHANGE_DISPATCH_QUEUE_CAPACITY = 4096
local TAKEOVER_SEEN_CAPACITY = 64
local HANDOFF_PUBLISH_COOLDOWN = 0.5
local INTERNAL_METADATA_WRITE_ID = "__rs:w"
local INTERNAL_METADATA_GENERATION = "__rs:g"
local INTERNAL_METADATA_REVISION = "__rs:r"
local INTERNAL_METADATA_TOKEN = "__rs:t"
local MAX_DATASTORE_BYTES = 4_194_304
local MAX_METADATA_TOTAL_BYTES = 300
local MAX_METADATA_KEY_LENGTH = 50
local MAX_METADATA_VALUE_LENGTH = 250
local MAX_MESSAGE_TYPE_LENGTH = 100
local MESSAGE_SUBSCRIBE_RETRY = 10
local _QUEUE_OWNERSHIP_SAFETY_WINDOW = 5

local server_id = game.JobId
if server_id == "" then
	server_id = HttpService:GenerateGUID(false)
end

local closing = false
local scheduler_started = false
local shutdown_started = false
local active_requests = 0
local records: { [string]: Record } = {}
local private: { [Record]: InternalState } = {}
local active_records: { [Record]: boolean } = {}
local recovery_records: { [Record]: boolean } = {}
local recovery_in_flight = false
local mock_database: { [string]: { [string]: MockEntry } } = {}
local mock_counter = 0
local mock_test_clock: (() -> number)? = nil
local mock_test_clock_offset = 0
local mock_update_replay_retries = 0
local mock_update_replay_advance_seconds = 0
local mock_update_failure_count = 0
local mock_update_failure_code: ResultCode = "budget"
local mock_update_failure_message: string? = nil
local mock_update_commit_then_failure_count = 0
local mock_update_commit_then_failure_message: string? = nil
local mock_get_failure_count = 0
local mock_get_failure_message: string? = nil

local close_internal: (state: InternalState, shutdown: boolean) -> (ResultCode, string?)
local complete_deferred_takeover: (state: InternalState) -> ()
local process_queue_internal: (state: InternalState, max_messages: number) -> (ResultCode, string?)
local copy_value: (value: unknown) -> JsonValue?
local track_external_data_mutation: (state: InternalState) -> ()
local messaging_enabled: (state: InternalState) -> boolean
local publish_record_message: (state: InternalState, kind: string, message_type: string?, data: JsonValue?, generation: number?, target_job_id: string?, target_token: string?, request_id: string?, handoff_status: HandoffStatus?, requester_job_id: string?) -> (boolean, string?)
local verify_snapshot_write: (state: InternalState, write_id: string, token: string, generation: number, revision: number, operation_deadline: number) -> (boolean, Envelope?, BackendInfo?)
local verify_release_write: (state: InternalState, write_id: string, generation: number, revision: number, tombstone: boolean, operation_deadline: number) -> (boolean, Envelope?, BackendInfo?)

local function now_unix(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function session_now_unix(mock: boolean): number
	if mock and mock_test_clock ~= nil then
		return mock_test_clock() + mock_test_clock_offset
	end
	return now_unix()
end

local function queue_now_unix(mock: boolean): number
	return session_now_unix(mock)
end

local function now_local(): number
	return os.clock()
end

local function resolve_operation_deadline(operation_deadline: number?): (number?, string?)
	local duration = operation_deadline
	if duration == nil then
		duration = DEFAULT_OPERATION_DEADLINE
	end
	if type(duration) ~= "number" or not math.isfinite(duration) or duration <= 0 then
		return nil, "operation_deadline must be a positive finite number"
	end
	return now_local() + duration, nil
end

local function run_validator(validator: Validator, value: JsonValue): (boolean, boolean, string?)
	local accepted = false
	local message: string? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, callback_accepted, callback_message = pcall(validator, value)
		if not ok then
			callback_error = tostring(callback_accepted)
			return
		end
		accepted = callback_accepted == true
		if callback_message ~= nil and type(callback_message) == "string" then
			message = callback_message
		end
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, false, "validator must not yield"
	end
	if not resumed then
		return false, false, "validator execution failed"
	end
	if callback_error ~= nil then
		return false, false, "validator threw: " .. callback_error
	end
	return true, accepted, message
end

local function run_migration(migration: Migration, version: number, value: JsonValue): (JsonValue?, string?)
	local next_value: JsonValue? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, callback_value = pcall(migration, version, value)
		if not ok then
			callback_error = tostring(callback_value)
			return
		end
		if callback_value == nil then
			callback_error = "migration " .. tostring(version) .. " returned nil"
			return
		end
		next_value = callback_value
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return nil, "migration " .. tostring(version) .. " must not yield"
	end
	if not resumed then
		return nil, "migration " .. tostring(version) .. " execution failed"
	end
	if callback_error ~= nil then
		return nil, "migration " .. tostring(version) .. " failed: " .. callback_error
	end
	if next_value == nil then
		return nil, "migration " .. tostring(version) .. " returned nil"
	end
	local copy_ok, copied_or_error = pcall(function()
		return copy_value(next_value)
	end)
	if not copy_ok or copied_or_error == nil then
		return nil, "migration " .. tostring(version) .. " returned invalid data"
	end
	return copied_or_error, nil
end

local function run_legacy_decoder(decoder: LegacyDecoder, raw: unknown): (JsonValue?, number?, string?)
	local decoded_value: JsonValue? = nil
	local decoded_version: number? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, value, version = pcall(decoder, raw)
		if not ok then
			callback_error = tostring(value)
			return
		end
		if value == nil then
			callback_error = "legacy decoder returned nil"
			return
		end
		if version ~= nil and (type(version) ~= "number" or not math.isfinite(version) or version < 0 or math.floor(version) ~= version) then
			callback_error = "legacy decoder returned an invalid schema version"
			return
		end
		decoded_value = value
		decoded_version = version
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return nil, nil, "legacy decoder must not yield"
	end
	if not resumed then
		return nil, nil, "legacy decoder execution failed"
	end
	if callback_error ~= nil then
		return nil, nil, callback_error
	end
	if decoded_value == nil then
		return nil, nil, "legacy decoder returned nil"
	end
	local copy_ok, copied_or_error = pcall(function()
		return copy_value(decoded_value)
	end)
	if not copy_ok or copied_or_error == nil then
		return nil, nil, "legacy decoder returned invalid data"
	end
	return copied_or_error, decoded_version, nil
end

local function clone_metadata(metadata: Metadata?): Metadata
	local result: Metadata = {}
	if metadata == nil then
		return result
	end
	for key, value in pairs(metadata) do
		result[key] = value
	end
	return result
end

local function clone_user_ids(user_ids: { number }?): { number }
	local result: { number } = {}
	if user_ids == nil then
		return result
	end
	for _, user_id in ipairs(user_ids) do
		result[#result + 1] = user_id
	end
	return result
end

local function normalize_user_ids(user_ids: { number }): ({ number }?, string?)
	local seen: { [number]: boolean } = {}
	local result: { number } = {}
	local length = #user_ids
	local numeric_count = 0
	for index, user_id in user_ids do
		if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 then
			return nil, "user_ids must be a dense array of positive integers"
		end
		numeric_count += 1
		if index > length then
			return nil, "user_ids must be a dense array of positive integers"
		end
		if type(user_id) ~= "number" or not math.isfinite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
			return nil, ("user_ids[%d] must be a positive integer"):format(index)
		end
		if not seen[user_id] then
			seen[user_id] = true
			result[#result + 1] = user_id
		end
	end
	if numeric_count ~= length then
		return nil, "user_ids must be a dense array of positive integers"
	end
	table.sort(result)
	return result, nil
end

local function validate_metadata(metadata: Metadata, allow_reserved: boolean?): (boolean, string?)
	if type(metadata) ~= "table" then
		return false, "metadata must be a table"
	end
	for key, value in pairs(metadata) do
		if type(key) ~= "string" or key == "" or #key > MAX_METADATA_KEY_LENGTH then
			return false, "metadata keys must be non-empty strings of at most 50 characters"
		end
		if not allow_reserved and string.sub(key, 1, 5) == "__rs:" then
			return false, "metadata keys beginning with __rs: are reserved by RecordStore"
		end
		if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
			return false, "metadata values must be strings, numbers, or booleans"
		end
		if type(value) == "number" then
			if not math.isfinite(value) then
				return false, ("metadata.%s must be finite"):format(key)
			end
		elseif type(value) == "string" and #value > MAX_METADATA_VALUE_LENGTH then
			return false, ("metadata.%s exceeds 250 characters"):format(key)
		end
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(metadata)
	end)
	if not ok or type(encoded) ~= "string" then
		return false, "metadata could not be encoded"
	end
	if #encoded > MAX_METADATA_TOTAL_BYTES then
		return false, "metadata exceeds the 300 character limit"
	end
	return true, nil
end

local function validate_value_shape(value: unknown, max_depth: number?, max_nodes: number?, max_string_length: number?, allow_non_finite_numbers: boolean?): (boolean, string?)
	local depth_limit = max_depth or 64
	local node_limit = max_nodes or 100000
	local string_limit = max_string_length or 4_000_000
	local node_count = 0
	local active_tables: { [any]: boolean } = {}

	local function visit(current: unknown, depth: number): (boolean, string?)
		node_count += 1
		if node_count > node_limit then
			return false, "value exceeds the maximum node count"
		end
		if depth > depth_limit then
			return false, "value exceeds the maximum nesting depth"
		end
		if current == nil then
			return true, nil
		end
		if type(current) == "number" then
			if not math.isfinite(current) and allow_non_finite_numbers ~= true then
				return false, "value contains a non-finite number"
			end
			return true, nil
		end
		if type(current) == "string" then
			if #current > string_limit then
				return false, "value contains an overlong string"
			end
			return true, nil
		end
		if type(current) == "boolean" or type(current) == "buffer" then
			return true, nil
		end
		if type(current) ~= "table" then
			return false, "value contains an unsupported type: " .. type(current)
		end
		local table_value = current :: { [string | number]: unknown }
		if active_tables[table_value] then
			return false, "value contains a cyclic table"
		end
		active_tables[table_value] = true
		local string_keys = 0
		local numeric_keys = 0
		local max_numeric_key = 0
		for key, child in table_value do
			if type(key) ~= "string" and type(key) ~= "number" then
				active_tables[table_value] = nil
				return false, "value contains an unsupported table key type"
			end
			if type(key) == "number" then
				if not math.isfinite(key) or math.floor(key) ~= key or key < 1 then
					active_tables[table_value] = nil
					return false, "numeric table keys must be positive integers"
				end
				numeric_keys += 1
				if key > max_numeric_key then
					max_numeric_key = key
				end
			else
				string_keys += 1
			end
			local child_ok, child_message = visit(child, depth + 1)
			if not child_ok then
				active_tables[table_value] = nil
				return false, child_message
			end
		end
		if string_keys > 0 and numeric_keys > 0 then
			active_tables[table_value] = nil
			return false, "tables cannot mix string and numeric keys"
		end
		if numeric_keys > 0 and max_numeric_key ~= numeric_keys then
			active_tables[table_value] = nil
			return false, "numeric-keyed tables must be dense arrays"
		end
		active_tables[table_value] = nil
		return true, nil
	end

	return visit(value, 0)
end

local function make_backend_metadata(metadata: Metadata, envelope: Envelope): Metadata
	local combined = clone_metadata(metadata)
	combined[INTERNAL_METADATA_WRITE_ID] = envelope.write_id
	combined[INTERNAL_METADATA_GENERATION] = tostring(envelope.fencing_generation)
	combined[INTERNAL_METADATA_REVISION] = tostring(envelope.revision)
	combined[INTERNAL_METADATA_TOKEN] = if envelope.session ~= nil then envelope.session.token else ""
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(combined)
	end)
	if ok and type(encoded) == "string" and #encoded <= MAX_METADATA_TOTAL_BYTES then
		return combined
	end
	return clone_metadata(metadata)
end

local function backend_metadata_matches(info: BackendInfo?, envelope: Envelope): boolean
	if info == nil then
		return true
	end
	local write_id = info.RawMetadata[INTERNAL_METADATA_WRITE_ID]
	if write_id == nil then
		return true
	end
	if write_id ~= envelope.write_id then
		return false
	end
	local generation = info.RawMetadata[INTERNAL_METADATA_GENERATION]
	local revision = info.RawMetadata[INTERNAL_METADATA_REVISION]
	if generation ~= nil and generation ~= tostring(envelope.fencing_generation) then
		return false
	end
	if revision ~= nil and revision ~= tostring(envelope.revision) then
		return false
	end
	if envelope.session ~= nil then
		local token = info.RawMetadata[INTERNAL_METADATA_TOKEN]
		if token ~= nil and token ~= envelope.session.token then
			return false
		end
	end
	return true
end

copy_value = function(value: unknown): JsonValue?
	if value == nil then
		return nil
	end

	local active_tables: { [any]: boolean } = {}

	local function clone(current: unknown, depth: number): JsonValue?
		if current == nil then
			return nil
		end
		if depth > 64 then
			error("value exceeds the maximum nesting depth")
		end
		if type(current) == "boolean" then
			return current
		end
		if type(current) == "number" then
			return current
		end
		if type(current) == "string" then
			return current
		end
		if typeof(current) == "buffer" then
			return buffer.fromstring(buffer.tostring(current))
		end
		if type(current) ~= "table" then
			error("value contains an unsupported type")
		end

		local table_value = current :: any
		if active_tables[table_value] then
			error("value contains a cyclic table")
		end
		active_tables[table_value] = true
		local has_string_key = false
		local has_number_key = false
		local result_dictionary: { [string]: JsonValue }? = nil
		local result_array: { JsonValue }? = nil

		for key, child in table_value do
			local key_type = type(key)
			if key_type == "string" then
				if has_number_key then
					active_tables[table_value] = nil
					error("value contains mixed table keys")
				end
				has_string_key = true
				local dictionary_key = key :: string
				local copied = clone(child, depth + 1)
				if copied == nil then
					active_tables[table_value] = nil
					error("value contains an invalid nil child")
				end
				if result_dictionary == nil then result_dictionary = {} end
				local dictionary_result = result_dictionary :: { [string]: JsonValue }
				dictionary_result[dictionary_key] = copied :: JsonValue
			elseif key_type == "number" then
				if has_string_key then
					active_tables[table_value] = nil
					error("value contains mixed table keys")
				end
				has_number_key = true
				local numeric_key = key :: number
				if not math.isfinite(numeric_key)
					or math.floor(numeric_key) ~= numeric_key
					or numeric_key < 1
				then
					active_tables[table_value] = nil
					error("value contains an invalid array index")
				end
				local copied = clone(child, depth + 1)
				if copied == nil then
					active_tables[table_value] = nil
					error("value contains an invalid nil child")
				end
				if result_array == nil then result_array = {} end
				local array_result = result_array :: { JsonValue }
				array_result[numeric_key] = copied :: JsonValue
			else
				active_tables[table_value] = nil
				error("value contains an unsupported table key")
			end
		end

		active_tables[table_value] = nil
		if has_string_key then
			return result_dictionary
		end
		if result_array ~= nil then
			return result_array
		end
		local empty_result: { JsonValue } = {}
		return empty_result
	end
	return clone(value, 1)
end
local function encode_non_finite_numbers(
	value: JsonValue
): (JsonValue, { NonFiniteNumberMarker })
	local markers: { NonFiniteNumberMarker } = {}
	local path: { NonFinitePathSegment } = {}

	local function encode(current: JsonValue, depth: number): (JsonValue, boolean)
		if depth > 64 then
			error("value exceeds the maximum nesting depth")
		end

		if type(current) == "number" then
			if math.isfinite(current) then
				return current, false
			end

			local kind: NonFiniteNumberKind
			if math.isnan(current) then
				kind = "nan"
			elseif current > 0 then
				kind = "positive_infinity"
			else
				kind = "negative_infinity"
			end

			markers[#markers + 1] = {
				path = table.clone(path),
				kind = kind,
			}
			return 0, true
		end

		if typeof(current) == "buffer" or type(current) ~= "table" then
			return current, false
		end

		local source: any = current
		local dictionary: boolean? = nil
		local result: any = nil

		for key, child in source do
			local key_type = type(key)
			if key_type ~= "string" and key_type ~= "number" then
				error("value contains an unsupported table key")
			end

			local is_dictionary_key = key_type == "string"
			if dictionary == nil then
				dictionary = is_dictionary_key
			elseif dictionary ~= is_dictionary_key then
				error("value contains mixed table keys")
			end

			path[#path + 1] = if is_dictionary_key
				then { kind = "string", key = key :: string }
				else { kind = "number", key = key :: number }
			local encoded_child, child_changed = encode(child, depth + 1)
			path[#path] = nil

			if child_changed then
				if result == nil then
					result = table.clone(source)
				end
				result[key] = encoded_child
			end
		end

		if result == nil then
			return current, false
		end
		return result :: JsonValue, true
	end

	local encoded, _changed = encode(value, 1)
	return encoded, markers
end

local function restore_non_finite_numbers(
	value: JsonValue?,
	raw_markers: unknown
): (JsonValue?, string?)
	if raw_markers == nil then
		return value, nil
	end
	if value == nil or type(raw_markers) ~= "table" then
		return nil, "non-finite number metadata is invalid"
	end

	local markers = raw_markers :: { [number]: unknown }
	local count = 0
	local maximum_index = 0
	for index in markers do
		if type(index) ~= "number"
			or not math.isfinite(index)
			or math.floor(index) ~= index
			or index < 1
		then
			return nil, "non-finite number metadata must be a dense array"
		end
		count += 1
		maximum_index = math.max(maximum_index, index)
	end
	if count ~= maximum_index then
		return nil, "non-finite number metadata must be a dense array"
	end
	if count == 0 then
		return value, nil
	end
	local result: JsonValue? = value
	if result == nil then
		return nil, "stored data is missing before restoring non-finite numbers"
	end

	for index = 1, count do
		local raw_marker = markers[index]
		if type(raw_marker) ~= "table" then
			return nil, "non-finite number marker is invalid"
		end
		local marker = raw_marker :: { [string]: unknown }
		local kind = marker.kind
		local raw_path = marker.path
		if kind ~= "nan" and kind ~= "positive_infinity" and kind ~= "negative_infinity" then
			return nil, "non-finite number marker kind is invalid"
		end
		if type(raw_path) ~= "table" then
			return nil, "non-finite number marker path is invalid"
		end

		local path = raw_path :: { [number]: unknown }
		local path_count = 0
		local path_maximum = 0
		for path_index in path do
			if type(path_index) ~= "number"
				or not math.isfinite(path_index)
				or math.floor(path_index) ~= path_index
				or path_index < 1
			then
				return nil, "non-finite number marker path must be a dense array"
			end
			path_count += 1
			path_maximum = math.max(path_maximum, path_index)
		end
		if path_count ~= path_maximum or path_count > 64 then
			return nil, "non-finite number marker path is invalid"
		end

		local replacement: number
		if kind == "nan" then
			replacement = 0 / 0
		elseif kind == "positive_infinity" then
			replacement = math.huge
		else
			replacement = -math.huge
		end

		if path_count == 0 then
			if type(result) ~= "number" or result ~= 0 then
				return nil, "non-finite number marker does not match its stored placeholder"
			end
			result = replacement
			continue
		end

		local parent: JsonValue = result
		for path_index = 1, path_count do
			local raw_segment = path[path_index]
			if type(raw_segment) ~= "table" or type(parent) ~= "table" then
				return nil, "non-finite number marker path does not match stored data"
			end
			local segment = raw_segment :: { [string]: unknown }
			local segment_kind = segment.kind
			local key = segment.key
			local is_last = path_index == path_count
			local child: JsonValue?

			if segment_kind == "string" and type(key) == "string" then
				local dictionary = parent :: { [string]: JsonValue }
				child = dictionary[key]
				if child == nil then
					return nil, "non-finite number marker references a missing field"
				end
				if is_last then
					if type(child) ~= "number" or child ~= 0 then
						return nil, "non-finite number marker does not match its stored placeholder"
					end
					dictionary[key] = replacement
				else
					parent = child
				end
			elseif segment_kind == "number"
				and type(key) == "number"
				and math.isfinite(key)
				and math.floor(key) == key
				and key >= 1
			then
				local array = parent :: { [number]: JsonValue }
				child = array[key]
				if child == nil then
					return nil, "non-finite number marker references a missing array item"
				end
				if is_last then
					if type(child) ~= "number" or child ~= 0 then
						return nil, "non-finite number marker does not match its stored placeholder"
					end
					array[key] = replacement
				else
					parent = child
				end
			else
				return nil, "non-finite number marker path segment is invalid"
			end
		end
	end

	return result, nil
end

local prepared_envelope_cache: any = setmetatable({}, { __mode = "k" })

prepared_envelope_cache._sidecar_protocol = (function()
	local MAX_READABLE_IMPLEMENTATION_VERSION = 3
	local TRANSACTION_IMPLEMENTATION_VERSION = 3
	local MAX_INBOX_RECEIPTS = 256
	local MAX_TRANSACTION_RECEIPTS = 256
	local MAX_OUTBOX_EVENTS = 128
	local MAX_ENVELOPE_SIDECAR_BYTES = 48_000

	local function empty(): EnvelopeSidecars
		return {
			version = 1,
			inbox_receipts = {},
			transaction_receipts = {},
			outbox_events = {},
		}
	end

	local function clone(sidecars: EnvelopeSidecars?): EnvelopeSidecars?
		if sidecars == nil then return nil end
		local copied = copy_value(sidecars :: JsonValue)
		if type(copied) ~= "table" then return nil end
		return copied :: EnvelopeSidecars
	end

	local function validate(value: unknown): (boolean, string?)
		if type(value) ~= "table" then return false, "sidecars must be a table" end
		local sidecars = value :: { [string]: unknown }
		if sidecars.version ~= 1 then return false, "unsupported sidecar protocol version" end
		local inbox = sidecars.inbox_receipts
		local transactions = sidecars.transaction_receipts
		local outbox = sidecars.outbox_events
		if type(inbox) ~= "table" or type(transactions) ~= "table" or type(outbox) ~= "table" then
			return false, "sidecar collections must be tables"
		end
		local inbox_receipts = inbox :: { [string]: unknown }
		local transaction_receipts = transactions :: { [string]: unknown }
		local outbox_events = outbox :: { [string]: unknown }
		local inbox_count = 0
		for id, raw_receipt in inbox_receipts do
			inbox_count += 1
			if inbox_count > MAX_INBOX_RECEIPTS then return false, "inbox receipt capacity exceeded" end
			if type(id) ~= "string" or id == "" or #id > 256 or type(raw_receipt) ~= "table" then
				return false, "inbox receipt identity is invalid"
			end
			local receipt = raw_receipt :: { [string]: unknown }
			if type(receipt.request_identity) ~= "string" or receipt.request_identity == ""
				or #receipt.request_identity > 16_384
				or type(receipt.result_present) ~= "boolean"
				or (receipt.result_present and receipt.result == nil)
				or (not receipt.result_present and receipt.result ~= nil)
				or type(receipt.committed_revision) ~= "number"
				or not math.isfinite(receipt.committed_revision)
				or math.floor(receipt.committed_revision) ~= receipt.committed_revision
				or receipt.committed_revision < 0
				or type(receipt.created_at) ~= "number" or not math.isfinite(receipt.created_at)
				or type(receipt.expires_at) ~= "number" or not math.isfinite(receipt.expires_at)
				or receipt.expires_at <= receipt.created_at
			then
				return false, "inbox receipt metadata is invalid"
			end
		end
		local transaction_count = 0
		for id, raw_receipt in transaction_receipts do
			transaction_count += 1
			if transaction_count > MAX_TRANSACTION_RECEIPTS then return false, "transaction receipt capacity exceeded" end
			if type(id) ~= "string" or id == "" or #id > 256 or type(raw_receipt) ~= "table" then
				return false, "transaction receipt identity is invalid"
			end
			local receipt = raw_receipt :: { [string]: unknown }
			if type(receipt.request_identity) ~= "string" or receipt.request_identity == ""
				or #receipt.request_identity > 16_384
				or type(receipt.result_present) ~= "boolean"
				or (receipt.result_present and receipt.result == nil)
				or (not receipt.result_present and receipt.result ~= nil)
				or type(receipt.committed_revision) ~= "number"
				or not math.isfinite(receipt.committed_revision)
				or math.floor(receipt.committed_revision) ~= receipt.committed_revision
				or receipt.committed_revision < 0
				or type(receipt.created_at) ~= "number" or not math.isfinite(receipt.created_at)
				or type(receipt.expires_at) ~= "number" or not math.isfinite(receipt.expires_at)
				or receipt.expires_at <= receipt.created_at
			then
				return false, "transaction receipt metadata is invalid"
			end
		end
		local outbox_count = 0
		for id, raw_event in outbox_events do
			outbox_count += 1
			if outbox_count > MAX_OUTBOX_EVENTS then return false, "outbox capacity exceeded" end
			if type(id) ~= "string" or id == "" or #id > 256 or type(raw_event) ~= "table" then
				return false, "outbox event identity is invalid"
			end
			local event = raw_event :: { [string]: unknown }
			if event.id ~= id or type(event.event_type) ~= "string" or event.event_type == "" or #event.event_type > 100
				or type(event.payload_version) ~= "number" or not math.isfinite(event.payload_version)
				or math.floor(event.payload_version) ~= event.payload_version or event.payload_version < 1
				or type(event.request_identity) ~= "string" or event.request_identity == "" or #event.request_identity > 16_384
				or type(event.destination_store_name) ~= "string" or event.destination_store_name == "" or #event.destination_store_name > 50
				or type(event.destination_scope) ~= "string" or #event.destination_scope > 50
				or type(event.destination_profile_key) ~= "string" or event.destination_profile_key == "" or #event.destination_profile_key > 50
				or type(event.created_at) ~= "number" or not math.isfinite(event.created_at)
				or type(event.attempts) ~= "number" or not math.isfinite(event.attempts)
				or math.floor(event.attempts) ~= event.attempts or event.attempts < 0
				or (event.state ~= "pending" and event.state ~= "delivered" and event.state ~= "unknown" and event.state ~= "blocked")
				or (type(event.payload) ~= "table" and type(event.payload) ~= "string"
					and type(event.payload) ~= "number" and type(event.payload) ~= "boolean")
				or (event.destination_receipt_id ~= nil
					and (type(event.destination_receipt_id) ~= "string"
						or event.destination_receipt_id == "" or #event.destination_receipt_id > 256))
				or (event.delivered_at ~= nil
					and (type(event.delivered_at) ~= "number" or not math.isfinite(event.delivered_at)))
				or (event.state == "delivered"
					and (type(event.delivered_at) ~= "number" or not math.isfinite(event.delivered_at)
						or type(event.destination_receipt_id) ~= "string"
						or event.destination_receipt_id == "" or #event.destination_receipt_id > 256))
				or (event.state ~= "delivered"
					and (event.delivered_at ~= nil or event.destination_receipt_id ~= nil))
			then
				return false, "outbox event metadata is invalid"
			end
		end
		local encoded_ok, encoded = pcall(function()
			return HttpService:JSONEncode(sidecars)
		end)
		if not encoded_ok or type(encoded) ~= "string" then
			return false, "sidecars cannot be encoded as JSON"
		end
		if #encoded > MAX_ENVELOPE_SIDECAR_BYTES then
			return false, "sidecars exceed the configured encoded-size limit"
		end
		return true, nil
	end

	local function canonicalize(root: unknown): (string?, string?)
		local active: { [any]: boolean } = {}
		local nodes = 0
		local function visit(value: unknown, depth: number): (string?, string?)
			nodes += 1
			if nodes > 8192 then return nil, "canonical request exceeds the node limit" end
			if depth > 64 then return nil, "canonical request exceeds the depth limit" end
			local kind = type(value)
			if value == nil then return "z", nil end
			if kind == "boolean" then return if value then "b1" else "b0", nil end
			if kind == "string" then
				local text = value :: string
				return "s" .. tostring(#text) .. ":" .. text, nil
			end
			if kind == "number" then
				local number_value = value :: number
				if not math.isfinite(number_value) then
					return nil, "canonical request contains a non-finite number"
				end
				local encoded = string.format("%.17g", number_value)
				return "d" .. tostring(#encoded) .. ":" .. encoded, nil
			end
			if kind ~= "table" then return nil, "canonical request contains unsupported type " .. kind end
			local current = value :: { [any]: unknown }
			if active[current] then return nil, "canonical request contains a cyclic table" end
			active[current] = true
			local keys: { string | number } = {}
			for key in pairs(current) do
				if type(key) == "string" then
					keys[#keys + 1] = key
				elseif type(key) == "number" and math.isfinite(key) and math.floor(key) == key then
					keys[#keys + 1] = key
				else
					active[current] = nil
					return nil, "canonical request contains an unsupported table key"
				end
			end
			table.sort(keys, function(left, right)
				if type(left) ~= type(right) then return type(left) < type(right) end
				if type(left) == "number" then return (left :: number) < (right :: number) end
				return (left :: string) < (right :: string)
			end)
			local parts = { "t", tostring(#keys), ":" }
			for _, key in ipairs(keys) do
				local encoded_key, key_error = visit(key, depth + 1)
				if encoded_key == nil then active[current] = nil; return nil, key_error end
				local encoded_value, value_error = visit(current[key], depth + 1)
				if encoded_value == nil then active[current] = nil; return nil, value_error end
				parts[#parts + 1] = tostring(#encoded_key) .. ":" .. encoded_key
				parts[#parts + 1] = tostring(#encoded_value) .. ":" .. encoded_value
			end
			active[current] = nil
			return table.concat(parts), nil
		end
		return visit(root, 0)
	end

	local function stable_event_id(identity: string, ordinal: number): string
		local seeds = { 17, 131, 911, 3571 }
		local digests: { string } = {}
		for index, seed in ipairs(seeds) do
			local hash = seed
			for position = 1, #identity do
				hash = (hash * 131 + string.byte(identity, position) + index * 17) % 2147483647
			end
			digests[index] = string.format("%08x", hash)
		end
		return "outbox:" .. table.concat(digests) .. ":" .. tostring(ordinal)
	end

	return {
		max_readable_version = MAX_READABLE_IMPLEMENTATION_VERSION,
		transaction_version = TRANSACTION_IMPLEMENTATION_VERSION,
		empty = empty,
		clone = clone,
		validate = validate,
		canonicalize = canonicalize,
		stable_event_id = stable_event_id,
	}
end)()



local function encode_envelope_for_storage(envelope: Envelope): JsonValue
	local stored: { [string]: JsonValue } = {
		implementation_version = if envelope.sidecars ~= nil then prepared_envelope_cache._sidecar_protocol.transaction_version else envelope.implementation_version,
		schema_version = envelope.schema_version,
		revision = envelope.revision,
		fencing_generation = envelope.fencing_generation,
		created_at = envelope.created_at,
		updated_at = envelope.updated_at,
		write_id = envelope.write_id,
		non_finite_numbers = {},
	}

	if envelope.data ~= nil then
		local encoded_data, markers = encode_non_finite_numbers(envelope.data)
		stored.data = encoded_data
		stored.non_finite_numbers = (markers :: unknown) :: JsonValue
	end
	if envelope.user_ids ~= nil then
		stored.user_ids = copy_value(envelope.user_ids) :: JsonValue
	end
	if envelope.tombstone ~= nil then
		stored.tombstone = copy_value(envelope.tombstone) :: JsonValue
	end
	if envelope.session ~= nil then
		stored.session = copy_value(envelope.session) :: JsonValue
	end
	if envelope.sidecars ~= nil then
		stored.sidecars = copy_value(envelope.sidecars) :: JsonValue
	end
	return stored
end

local function encode_backend_update_value(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local candidate = value :: { [any]: unknown }
	if candidate[prepared_envelope_cache] == true then
		return candidate.raw_value
	end
	if candidate.implementation_version ~= nil
		and candidate.schema_version ~= nil
		and candidate.revision ~= nil
		and candidate.fencing_generation ~= nil
		and candidate.created_at ~= nil
		and candidate.updated_at ~= nil
		and candidate.write_id ~= nil
	then
		local envelope = value :: Envelope
		local prepared = prepared_envelope_cache[envelope]
		return if prepared ~= nil then prepared else encode_envelope_for_storage(envelope)
	end
	return value
end

local function validate_serialized_size(value: unknown): (boolean, string?)
	local shape_ok, shape_message = validate_value_shape(value)
	if not shape_ok then
		return false, shape_message
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if not ok or type(encoded) ~= "string" then
		return false, "value is not JSON-encodable"
	end
	if #encoded > MAX_DATASTORE_BYTES then
		return false, ("serialized value exceeds the %d byte DataStore limit"):format(MAX_DATASTORE_BYTES)
	end
	return true, nil
end

local function validate_value(value: JsonValue?, validator: Validator?): (boolean, string?)
	if value == nil then
		return false, "record data cannot be nil"
	end
	local shape_ok, shape_message = validate_value_shape(value, nil, nil, nil, true)
	if not shape_ok then
		return false, shape_message
	end
	local safe_value_ok, safe_value = pcall(function()
		local encoded_value = encode_non_finite_numbers(value)
		return encoded_value
	end)
	if not safe_value_ok then
		return false, "value could not be encoded for JSON persistence"
	end
	local encoded_ok, serialized = pcall(function()
		return HttpService:JSONEncode(safe_value)
	end)
	if not encoded_ok or type(serialized) ~= "string" then
		return false, "value is not JSON-encodable"
	end
	if #serialized > MAX_DATASTORE_BYTES then
		return false, ("serialized value exceeds the %d byte DataStore limit"):format(MAX_DATASTORE_BYTES)
	end
	if validator ~= nil then
		local completed, accepted, message = run_validator(validator, value)
		if not completed then
			return false, message
		end
		if not accepted then
			return false, message or "validator rejected the value"
		end
	end
	return true, nil
end

local function validate_store_identity(name: string, scope: string, key: string): (boolean, string?)
	if type(name) ~= "string" or type(scope) ~= "string" or type(key) ~= "string" then
		return false, "store name, scope, and key must be strings"
	end
	if name == "" or #name > 50 then
		return false, "store name must be 1 to 50 characters"
	end
	if #scope > 50 then
		return false, "scope must be at most 50 characters"
	end
	if key == "" or #key > 50 then
		return false, "key must be 1 to 50 characters"
	end
	return true, nil
end

local function hash_topic(value: string): string
	local hash = 5381
	for index = 1, #value do
		hash = bit32.band(
			bit32.lshift(hash, 5)
				+ hash
				+ string.byte(value, index),
			0xffffffff
		)
	end
	return string.format("%08x", hash)
end

local function make_message_topic(prefix: string, name: string, scope: string, key: string): string
	return prefix .. hash_topic(name .. "\0" .. scope .. "\0" .. key)
end

local function make_queue_key_legacy(name: string, scope: string, key: string): string
	return "q:" .. hash_topic(name .. "\0" .. scope .. "\0" .. key)
end

local function hash_sdbm(value: string): string
	local hash = 0
	for index = 1, #value do
		local byte = string.byte(value, index)
		hash = bit32.band(
			byte
				+ bit32.lshift(hash, 6)
				+ bit32.lshift(hash, 16)
			- hash,
			0xffffffff
		)
	end
	return string.format("%08x", hash)
end

local function make_queue_key_v2(name: string, scope: string, key: string): string
	local identity = name .. "\0" .. scope .. "\0" .. key
	return "q2:" .. hash_topic(identity) .. ":" .. hash_sdbm(identity)
end

local function make_queue_owner(name: string, scope: string, key: string): QueueOwner
	return {
		name = name,
		scope = scope,
		key = key,
	}
end

local function retry_delay(attempt: number): number
	local exponential = MIN_RETRY_DELAY * (2 ^ math.max(0, attempt - 1))
	return math.min(MAX_RETRY_DELAY, exponential) + math.random() * 0.25
end

local function is_retryable_result(result: ResultCode, operation: string?): boolean
	if result == "budget"
		or result == "busy"
		or result == "unknown"
		or result == "retry_exhausted"
	then
		return true
	end

	return operation == "open" and (result == "locked" or result == "conflict")
end

local DIAGNOSTIC_PHASE_CODES: { [DiagnosticPhase]: string } = {
	create = "CREATE",
	open = "OPEN",
	normalize = "NORMALIZE",
	update = "UPDATE",
}

local function get_diagnostic_code(phase: DiagnosticPhase, result: ResultCode): string
	local result_code = string.upper((string.gsub(result, "_", "-")))
	return "RS-" .. DIAGNOSTIC_PHASE_CODES[phase] .. "-" .. result_code
end

local function observe(state: InternalState, event: string, result: ResultCode, message: string?)
	state.last_result = result
	state.last_error = message
	local retryable = is_retryable_result(result, event)
	local requires_verification = result == "unknown"
	local durable_outcome: "not_submitted" | "not_committed" | "unknown" | "committed" = "not_committed"
	if result == "saved" or result == "closed" or result == "deleted" or result == "created" or result == "loaded" or result == "success" then
		durable_outcome = "committed"
	elseif result == "unknown" or result == "retry_exhausted" then
		durable_outcome = "unknown"
	end
	state.last_error_info = {
		Code = result,
		Message = message,
		Retryable = retryable,
		RequiresVerification = requires_verification,
		DurableOutcome = durable_outcome,
		OperationId = state.current_operation_id,
		Generation = if state.generation > 0 then state.generation else nil,
		Revision = if state.revision > 0 then state.revision else nil,
	}
	local observer = state.options.on_event
	if observer == nil then
		return
	end
	local thread = coroutine.create(function()
		observer(event, state.key, result, message)
	end)
	local resumed = coroutine.resume(thread)
	if not resumed or coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		state.observer_errors += 1
	end
end

local function append_change_event(events: { ChangeEvent }, path: { string | number }, old_value: JsonValue?, new_value: JsonValue?, operation_id: string, sequence: number, kind: string): boolean
	if #events >= CHANGE_OBSERVER_CAPACITY then
		return false
	end
	local event_path: { string } = {}
	for _, segment in ipairs(path) do
		event_path[#event_path + 1] = if type(segment) == "number" then "[" .. tostring(segment) .. "]" else segment
	end
	events[#events + 1] = {
		OperationId = operation_id,
		Sequence = sequence,
		Path = event_path,
		OldValue = old_value,
		NewValue = new_value,
		Truncated = false,
		Kind = kind,
	}
	return true
end

local function diff_change_events(events: { ChangeEvent }, old_value: JsonValue?, new_value: JsonValue?, path: { string | number }, operation_id: string, sequence: number, kind: string): boolean
	if old_value == new_value
		or (type(old_value) == "number"
			and type(new_value) == "number"
			and math.isnan(old_value)
			and math.isnan(new_value))
	then
		return true
	end
	if type(old_value) == "table" and type(new_value) == "table" then
		local old_table = old_value :: { [string | number]: JsonValue }
		local new_table = new_value :: { [string | number]: JsonValue }
		for key, old_child in old_table do
			if type(key) == "string" or type(key) == "number" then
				local new_child = new_table[key]
				local equal = old_child == new_child
				if not equal
					and type(old_child) == "number"
					and type(new_child) == "number"
					and math.isnan(old_child)
					and math.isnan(new_child)
				then
					equal = true
				end
				if not equal then
					path[#path + 1] = key
					local complete: boolean
					if type(old_child) == "table" and type(new_child) == "table" then
						complete = diff_change_events(events, old_child, new_child, path, operation_id, sequence, kind)
					else
						complete = append_change_event(events, path, old_child, new_child, operation_id, sequence, kind)
					end
					path[#path] = nil
					if not complete then
						return false
					end
				end
			end
		end
		for key, new_child in new_table do
			if (type(key) == "string" or type(key) == "number") and old_table[key] == nil then
				path[#path + 1] = key
				local complete = append_change_event(events, path, nil, new_child, operation_id, sequence, kind)
				path[#path] = nil
				if not complete then
					return false
				end
			end
		end
		return true
	end
	return append_change_event(events, path, old_value, new_value, operation_id, sequence, kind)
end

local function change_event_path_before(left: ChangeEvent, right: ChangeEvent): boolean
	local left_path = left.Path
	local right_path = right.Path
	local shared_length = math.min(#left_path, #right_path)
	for index = 1, shared_length do
		local left_segment = left_path[index]
		local right_segment = right_path[index]
		if left_segment ~= right_segment then
			return left_segment < right_segment
		end
	end
	return #left_path < #right_path
end

local function enqueue_change_observation(state: InternalState, old_value: unknown, new_value: unknown, operation_id: string, kind: string)
	if next(state.change_observers) == nil then
		return
	end
	local old_json = old_value :: JsonValue?
	local new_json = new_value :: JsonValue?
	local events: { ChangeEvent } = {}
	local complete = diff_change_events(
		events,
		old_json,
		new_json,
		{},
		operation_id,
		state.change_sequence,
		kind
	)
	if not complete then
		state.change_events_dropped += 1
		events = {}
		events[1] = {
			OperationId = operation_id,
			Sequence = state.change_sequence,
			Path = {},
			OldValue = copy_value(old_json),
			NewValue = copy_value(new_json),
			Truncated = true,
			Kind = kind,
		}
	else
		if #events > 1 then
			table.sort(events, change_event_path_before)
		end
	end
	local queued_events = if state.change_dispatch_tail >= state.change_dispatch_head then state.change_dispatch_tail - state.change_dispatch_head + 1 else 0
	if queued_events + #events > CHANGE_DISPATCH_QUEUE_CAPACITY then
		state.change_events_dropped += #events
		local fallback_event = events[1]
		state.change_dispatch_queue = {}
		state.change_dispatch_head = 1
		state.change_dispatch_tail = 1
		state.change_dispatch_queue[1] = if fallback_event ~= nil and #events == 1 and fallback_event.Truncated then fallback_event else {
			OperationId = operation_id,
			Sequence = state.change_sequence,
			Path = {},
			OldValue = copy_value(old_json),
			NewValue = copy_value(new_json),
			Truncated = true,
			Kind = kind,
		}
	else
		for _, event in ipairs(events) do
			if not event.Truncated then
				event.OldValue = if type(event.OldValue) == "table" or typeof(event.OldValue) == "buffer" then copy_value(event.OldValue) else event.OldValue
				event.NewValue = if type(event.NewValue) == "table" or typeof(event.NewValue) == "buffer" then copy_value(event.NewValue) else event.NewValue
			end
			state.change_dispatch_tail += 1
			state.change_dispatch_queue[state.change_dispatch_tail] = event
		end
	end
	if state.change_dispatch_running or state.change_dispatch_head > state.change_dispatch_tail then
		return
	end
	state.change_dispatch_running = true
	task.spawn(function()
		while state.change_dispatch_head <= state.change_dispatch_tail and not state.retired do
			local event = state.change_dispatch_queue[state.change_dispatch_head]
			state.change_dispatch_queue[state.change_dispatch_head] = nil
			state.change_dispatch_head += 1
			if event ~= nil then
				for _, observer in pairs(state.change_observers) do
					local thread = coroutine.create(observer)
					local ok = coroutine.resume(thread, {
						OperationId = event.OperationId,
						Sequence = event.Sequence,
						Path = table.clone(event.Path),
						OldValue = if type(event.OldValue) == "table" or typeof(event.OldValue) == "buffer" then copy_value(event.OldValue) else event.OldValue,
						NewValue = if type(event.NewValue) == "table" or typeof(event.NewValue) == "buffer" then copy_value(event.NewValue) else event.NewValue,
						Truncated = event.Truncated,
						Kind = event.Kind,
					})
					if not ok or coroutine.status(thread) ~= "dead" then
						coroutine.close(thread)
						state.observer_errors += 1
					end
				end
			end
		end
		state.change_dispatch_queue = {}
		state.change_dispatch_head = 1
		state.change_dispatch_tail = 0
		state.change_dispatch_running = false
	end)
end

local function budget_available(request_type: Enum.DataStoreRequestType): boolean?
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(request_type)
	end)
	if not ok or type(budget) ~= "number" then
		return nil
	end
	return budget >= 1
end

local function acquire_slot(deadline: number): boolean
	while active_requests >= DEFAULT_MAX_CONCURRENT_REQUESTS and now_local() < deadline do
		task.wait(0.05)
	end
	if active_requests >= DEFAULT_MAX_CONCURRENT_REQUESTS then
		return false
	end
	active_requests += 1
	return true
end

local function release_slot()
	active_requests = math.max(0, active_requests - 1)
end

local function acquire_request(state: InternalState?, deadline: number, update: boolean, request_type: Enum.DataStoreRequestType?): boolean
	if not acquire_slot(deadline) then
		return false
	end
	local wait_seconds = if state ~= nil then state.options.budget_wait or DEFAULT_BUDGET_WAIT else DEFAULT_BUDGET_WAIT
	local wait_deadline = math.min(deadline, now_local() + wait_seconds)
	while now_local() < wait_deadline do
		if request_type ~= nil then
			local available = budget_available(request_type)
			if available ~= false then
				return true
			end
		else
			local read_available = budget_available(Enum.DataStoreRequestType.StandardRead)
			local write_available = if update then budget_available(Enum.DataStoreRequestType.StandardWrite) else true
			if read_available ~= false and write_available ~= false then
				return true
			end
		end
		task.wait(0.05)
	end
	local available = if request_type ~= nil
		then budget_available(request_type)
		else budget_available(Enum.DataStoreRequestType.StandardRead) ~= false
		and (not update or budget_available(Enum.DataStoreRequestType.StandardWrite) ~= false)
	if available == false then
		release_slot()
		return false
	end
	return true
end

local function backend_info_from_key_info(key_info: DataStoreKeyInfo?): BackendInfo?
	if key_info == nil then
		return nil
	end
	local user_ids: { number } = {}
	for _, user_id in ipairs(key_info:GetUserIds()) do
		if type(user_id) == "number" then
			user_ids[#user_ids + 1] = user_id
		end
	end
	local metadata: Metadata = {}
	local preserved_metadata: Metadata = {}
	local raw_metadata = key_info:GetMetadata()
	for key, value in pairs(raw_metadata) do
		if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
			preserved_metadata[key] = value
			if string.sub(key, 1, 5) ~= "__rs:" then
				metadata[key] = value
			end
		end
	end
	return {
		Version = key_info.Version,
		CreatedTime = key_info.CreatedTime,
		UpdatedTime = key_info.UpdatedTime,
		UserIds = user_ids,
		Metadata = metadata,
		RawMetadata = preserved_metadata,
	}
end

local function make_mock_store_id(name: string, scope: string): string
	return HttpService:JSONEncode({ name, scope })
end

local function get_mock_store(name: string, scope: string): { [string]: MockEntry }
	local store_id = make_mock_store_id(name, scope)
	local store = mock_database[store_id]
	if store == nil then
		store = {}
		mock_database[store_id] = store
	end
	return store
end

local function make_backend(name: string, scope: string, key: string, mock: boolean): Backend
	return {
		name = name,
		scope = scope,
		key = key,
		store = if mock then nil else DataStoreService:GetDataStore(name, scope),
		mock = mock,
	}
end

local function backend_get(backend: Backend, use_cache: boolean, deadline: number, request_state: InternalState?): (unknown, BackendInfo?, ResultCode?, string?)
	if backend.mock then
		if mock_get_failure_count > 0 then
			mock_get_failure_count -= 1
			return nil, nil, "unknown", mock_get_failure_message or "injected mock read failure"
		end
		local store = get_mock_store(backend.name, backend.scope)
		local entry = store[backend.key]
		if entry == nil then
			return nil, nil, nil, nil
		end
		return copy_value(entry.Value), {
			Version = entry.Version,
			CreatedTime = entry.CreatedTime,
			UpdatedTime = entry.UpdatedTime,
			UserIds = clone_user_ids(entry.UserIds),
			Metadata = clone_metadata(entry.Metadata),
			RawMetadata = clone_metadata(entry.Metadata),
		}, nil, nil
	end
	local store = backend.store
	if store == nil then
		return nil, nil, "invalid", "backend store is missing"
	end
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = use_cache
	if not acquire_request(request_state, deadline, false, Enum.DataStoreRequestType.StandardRead) then
		return nil, nil, "budget", "read request deadline exceeded"
	end
	local ok, raw, key_info = pcall(function()
		return store:GetAsync(backend.key, options)
	end)
	release_slot()
	if not ok then
		return nil, nil, "unknown", tostring(raw)
	end
	return raw, backend_info_from_key_info(key_info), nil, nil
end

local function mock_write_version(entry: MockEntry?, value: JsonValue?, user_ids: { number }, metadata: Metadata, deleted: boolean): MockEntry
	mock_counter += 1
	local now = DateTime.now().UnixTimestampMillis
	local version = ("mock-%d-%s"):format(mock_counter, HttpService:GenerateGUID(false))
	local created_time = if entry ~= nil then entry.CreatedTime else now
	local next_entry: MockEntry = if entry ~= nil
		then entry
		else {
			Value = nil,
			UserIds = {},
			Metadata = {},
			Version = "",
			CreatedTime = now,
			UpdatedTime = now,
			Versions = {},
			VersionOrder = {},
		}
	next_entry.Value = copy_value(value)
	next_entry.UserIds = clone_user_ids(user_ids)
	next_entry.Metadata = clone_metadata(metadata)
	next_entry.Version = version
	next_entry.CreatedTime = created_time
	next_entry.UpdatedTime = now
	next_entry.Versions[version] = {
		Version = version,
		CreatedTime = now,
		UpdatedTime = now,
		Value = copy_value(value),
		UserIds = clone_user_ids(user_ids),
		Metadata = clone_metadata(metadata),
		Deleted = deleted,
	}
	next_entry.VersionOrder[#next_entry.VersionOrder + 1] = version
	return next_entry
end

local function backend_update(backend: Backend, transform: UpdateTransform, deadline: number, request_state: InternalState?): (unknown, BackendInfo?, ResultCode?, string?)
	if request_state ~= nil and request_state.retired then
		return nil, nil, "invalid", "record has been retired"
	end
	if backend.mock then
		if mock_update_failure_count > 0 then
			mock_update_failure_count -= 1
			return nil, nil, mock_update_failure_code, mock_update_failure_message
		end
		local store = get_mock_store(backend.name, backend.scope)
		local entry = store[backend.key]
		local raw = if entry ~= nil then copy_value(entry.Value) else nil
		local info: BackendInfo? = if entry ~= nil
			then {
				Version = entry.Version,
				CreatedTime = entry.CreatedTime,
				UpdatedTime = entry.UpdatedTime,
				UserIds = clone_user_ids(entry.UserIds),
				Metadata = clone_metadata(entry.Metadata),
				RawMetadata = clone_metadata(entry.Metadata),
			}
			else nil
		local replay_count = mock_update_replay_retries
		local replay_advance = mock_update_replay_advance_seconds
		mock_update_replay_retries = 0
		mock_update_replay_advance_seconds = 0
		local ok = true
		local new_value: unknown = nil
		local user_ids: { number }? = nil
		local metadata: Metadata? = nil
		for _ = 0, replay_count do
			ok, new_value, user_ids, metadata = pcall(transform, raw, info)
			if not ok then
				return nil, nil, "unknown", tostring(new_value)
			end
			mock_test_clock_offset += replay_advance
		end
		if new_value == nil then
			return raw, info, nil, nil
		end
		local normalized_user_ids = user_ids or (if info ~= nil then info.UserIds else {})
		local normalized_metadata = metadata or (if info ~= nil then info.Metadata else {})
		local ids, ids_error = normalize_user_ids(normalized_user_ids)
		if ids == nil then
			return nil, nil, "validation", ids_error
		end
		local metadata_ok, metadata_error = validate_metadata(normalized_metadata, true)
		if not metadata_ok then
			return nil, nil, "validation", metadata_error
		end
		local stored_new_value = encode_backend_update_value(new_value)
		local value = copy_value(stored_new_value)
		if value == nil then
			return nil, nil, "validation", "updated value is invalid"
		end
		if request_state ~= nil and request_state.retired then
			return nil, nil, "invalid", "record has been retired"
		end
		local data_ok, data_error = validate_serialized_size(value)
		if not data_ok then
			return nil, nil, "validation", data_error
		end
		local next_entry = mock_write_version(entry, value, ids, normalized_metadata, false)
		store[backend.key] = next_entry
		if mock_update_commit_then_failure_count > 0 then
			mock_update_commit_then_failure_count -= 1
			return nil, nil, "unknown", mock_update_commit_then_failure_message
				or "injected UpdateAsync response failure after commit"
		end
		return copy_value(next_entry.Value), {
			Version = next_entry.Version,
			CreatedTime = next_entry.CreatedTime,
			UpdatedTime = next_entry.UpdatedTime,
			UserIds = clone_user_ids(next_entry.UserIds),
			Metadata = clone_metadata(next_entry.Metadata),
			RawMetadata = clone_metadata(next_entry.Metadata),
		}, nil, nil
	end
	local store = backend.store
	if store == nil then
		return nil, nil, "invalid", "backend store is missing"
	end
	if not acquire_request(request_state, deadline, true, nil) then
		return nil, nil, "budget", "update request deadline exceeded"
	end
	local ok, result, key_info = pcall(function()
		return store:UpdateAsync(backend.key, function(raw, key_info)
			local info = backend_info_from_key_info(key_info)
			local new_value, user_ids, metadata = transform(raw, info)
			return encode_backend_update_value(new_value), user_ids, metadata
		end)
	end)
	release_slot()
	if not ok then
		return nil, nil, "unknown", tostring(result)
	end
	return result, backend_info_from_key_info(key_info), nil, nil
end
local function get_string_field(value: unknown, key: string): unknown
	if type(value) ~= "table" then return nil end
	return rawget(value :: any, key)
end


local function parse_envelope(raw: unknown): (Envelope?, string?, boolean)
	if raw == nil then
		return nil, nil, true
	end
	if type(raw) ~= "table" then
		return nil, "legacy payload", false
	end
	local stored_implementation_version = get_string_field(raw, "implementation_version")
	local stored_fencing_generation = get_string_field(raw, "fencing_generation")
	local legacy_generation = get_string_field(raw, "generation")
	local legacy_payload = get_string_field(raw, "payload")
	local legacy_deleted = get_string_field(raw, "deleted")
	local legacy_format = get_string_field(raw, "format")
	local legacy_operation_id = get_string_field(raw, "last_operation_id")
	local legacy_lease = get_string_field(raw, "lease")
	if stored_implementation_version ~= nil
		and stored_fencing_generation == nil
		and legacy_generation ~= nil
		and legacy_format ~= nil
		and legacy_deleted ~= nil
		and legacy_operation_id ~= nil
	then
		if legacy_format ~= "RecordStore" then
			local format_detail = string.gsub(tostring(legacy_format), "%c", " ")
			format_detail = string.sub(format_detail, 1, 80)
			return nil, ("unsupported legacy RecordStore format: expected string RecordStore, got type=%s value=%s"):format(
				type(legacy_format),
				format_detail
			), false
		end
		if legacy_lease ~= nil then
			return nil, "legacy RecordStore envelope contains a lease; automatic migration is refused because its ownership state cannot be verified", false
		end
		if type(legacy_generation) ~= "number"
			or not math.isfinite(legacy_generation)
			or math.floor(legacy_generation) ~= legacy_generation
			or legacy_generation < 0
		then
			return nil, "invalid legacy generation", false
		end
		if type(legacy_deleted) ~= "boolean" then
			return nil, "invalid legacy deleted flag", false
		end
		if type(legacy_operation_id) ~= "string" or legacy_operation_id == "" then
			return nil, "invalid legacy last_operation_id", false
		end
		local legacy_schema_version = get_string_field(raw, "schema_version")
		local legacy_revision = get_string_field(raw, "revision")
		local legacy_created_at = get_string_field(raw, "created_at")
		local legacy_updated_at = get_string_field(raw, "updated_at")
		local legacy_user_ids = get_string_field(raw, "user_ids")
		if type(legacy_schema_version) ~= "number"
			or not math.isfinite(legacy_schema_version)
			or math.floor(legacy_schema_version) ~= legacy_schema_version
			or legacy_schema_version < 0
		then
			return nil, "invalid legacy schema version", false
		end
		if type(legacy_revision) ~= "number"
			or not math.isfinite(legacy_revision)
			or math.floor(legacy_revision) ~= legacy_revision
			or legacy_revision < 0
		then
			return nil, "invalid legacy revision", false
		end
		if type(legacy_created_at) ~= "number"
			or not math.isfinite(legacy_created_at)
			or type(legacy_updated_at) ~= "number"
			or not math.isfinite(legacy_updated_at)
			or legacy_updated_at < legacy_created_at
		then
			return nil, "invalid legacy timestamps", false
		end
		if legacy_deleted and legacy_generation < 1 then
			return nil, "deleted legacy record has no valid fencing generation", false
		end
		if not legacy_deleted and legacy_payload == nil then
			return nil, "non-deleted legacy record is missing payload", false
		end
		local canonical_legacy: { [string]: unknown } = {
			implementation_version = stored_implementation_version,
			schema_version = legacy_schema_version,
			revision = legacy_revision,
			fencing_generation = legacy_generation,
			created_at = legacy_created_at,
			updated_at = legacy_updated_at,
			data = if legacy_deleted then nil else legacy_payload,
			user_ids = legacy_user_ids,
			tombstone = if legacy_deleted then { deleted_at = legacy_updated_at, generation = legacy_generation } else nil,
			session = nil,
			write_id = legacy_operation_id,
		}
		return parse_envelope(canonical_legacy)
	end

	local implementation_version = get_string_field(raw, "implementation_version")
	local schema_version = get_string_field(raw, "schema_version")
	local revision = get_string_field(raw, "revision")
	local fencing_generation = get_string_field(raw, "fencing_generation")
	local created_at = get_string_field(raw, "created_at")
	local updated_at = get_string_field(raw, "updated_at")
	local write_id = get_string_field(raw, "write_id")
	local raw_data = get_string_field(raw, "data")
	local raw_non_finite_numbers = get_string_field(raw, "non_finite_numbers")
	local data: JsonValue? = nil

	if raw_data ~= nil then
		local copied_data = copy_value(raw_data)
		if copied_data == nil then
			return nil, "invalid stored data", false
		end
		data = copied_data
	end
	local raw_user_ids = get_string_field(raw, "user_ids")
	local raw_tombstone = get_string_field(raw, "tombstone")
	local raw_session = get_string_field(raw, "session")
	local raw_sidecars = get_string_field(raw, "sidecars")
	if implementation_version == nil then
		local legacy_marker = get_string_field(raw, "__recordStore")
		if legacy_marker == "RecordStore" then
			local legacy_format = get_string_field(raw, "format")
			local legacy_revision = get_string_field(raw, "revision")
			local legacy_fence = get_string_field(raw, "fence")
			local legacy_commit_id = get_string_field(raw, "commitId")
			local legacy_deleted = get_string_field(raw, "deleted")
			local legacy_schema_version = get_string_field(raw, "version")

			if legacy_format ~= 1
				or type(legacy_revision) ~= "number"
				or not math.isfinite(legacy_revision)
				or math.floor(legacy_revision) ~= legacy_revision
				or legacy_revision < 0
				or type(legacy_fence) ~= "string"
				or legacy_fence == ""
				or type(legacy_commit_id) ~= "string"
				or legacy_commit_id == ""
				or type(legacy_deleted) ~= "boolean"
				or type(legacy_schema_version) ~= "number"
				or not math.isfinite(legacy_schema_version)
				or math.floor(legacy_schema_version) ~= legacy_schema_version
				or legacy_schema_version < 0
			then
				return nil, "malformed legacy RecordStore envelope", false
			end

			if legacy_deleted then
				if raw_data ~= nil then
					return nil, "deleted legacy RecordStore envelope unexpectedly contains data", false
				end
				return {
					implementation_version = IMPLEMENTATION_VERSION,
					schema_version = legacy_schema_version,
					revision = legacy_revision,
					fencing_generation = 1,
					created_at = 0,
					updated_at = 0,
					data = nil,
					user_ids = nil,
					tombstone = {
						deleted_at = 0,
						generation = 1,
					},
					session = nil,
					sidecars = nil,
					write_id = legacy_commit_id,
				}, nil, true
			end

			if data == nil then
				return nil, "non-deleted legacy RecordStore envelope is missing data", false
			end

			return {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = legacy_schema_version,
				revision = legacy_revision,
				fencing_generation = 1,
				created_at = 0,
				updated_at = 0,
				data = data,
				user_ids = nil,
				tombstone = nil,
				session = nil,
				sidecars = nil,
				write_id = legacy_commit_id,
			}, nil, true
		end

		if schema_version ~= nil or revision ~= nil or fencing_generation ~= nil or raw_session ~= nil or write_id ~= nil then
			return nil, "malformed RecordStore envelope", false
		end
		return nil, "legacy payload", false
	end
	if type(implementation_version) ~= "number" or not math.isfinite(implementation_version) or math.floor(implementation_version) ~= implementation_version then
		return nil, "invalid implementation version", false
	end
	if implementation_version > prepared_envelope_cache._sidecar_protocol.max_readable_version then
		return nil, "future implementation version", false
	end
	local parsed_sidecars: EnvelopeSidecars? = nil
	if implementation_version >= prepared_envelope_cache._sidecar_protocol.transaction_version then
		if raw_sidecars == nil then
			return nil, "version 3 envelope is missing transaction sidecars", false
		end
		local sidecars_valid, sidecars_error = prepared_envelope_cache._sidecar_protocol.validate(raw_sidecars)
		if not sidecars_valid then
			return nil, "invalid transaction sidecars: " .. (sidecars_error or "unknown error"), false
		end
		parsed_sidecars = prepared_envelope_cache._sidecar_protocol.clone(raw_sidecars :: EnvelopeSidecars)
	elseif raw_sidecars ~= nil then
		return nil, "version 2 envelope unexpectedly contains transaction sidecars", false
	end
	if implementation_version >= 2 and raw_non_finite_numbers == nil then
		return nil, "version 2 envelope is missing non-finite number metadata", false
	end
	if implementation_version < 1 then
		return nil, "unsupported implementation version", false
	end
	if type(schema_version) ~= "number" or not math.isfinite(schema_version) or math.floor(schema_version) ~= schema_version or schema_version < 0 then
		return nil, "invalid schema version", false
	end
	if type(revision) ~= "number" or not math.isfinite(revision) or math.floor(revision) ~= revision or revision < 0 then
		return nil, "invalid revision", false
	end
	if type(fencing_generation) ~= "number" then
		local key_names: { string } = {}
		for child_key in raw :: any do
			if type(child_key) == "string" then
				key_names[#key_names + 1] = child_key
			end
		end
		table.sort(key_names)
		while #key_names > 24 do
			table.remove(key_names)
		end
		return nil, ("invalid fencing generation: expected number, got %s; aliases generation=%s fence=%s; envelope keys={%s}"):format(
			type(fencing_generation),
			type(get_string_field(raw, "generation")),
			type(get_string_field(raw, "fence")),
			table.concat(key_names, ",")
		), false
	end
	if not math.isfinite(fencing_generation) then
		return nil, "invalid fencing generation: number is not finite", false
	end
	if math.floor(fencing_generation) ~= fencing_generation then
		return nil, "invalid fencing generation: number is not an integer", false
	end
	if fencing_generation < 0 then
		return nil, "invalid fencing generation: number is negative", false
	end
	if type(created_at) ~= "number" or not math.isfinite(created_at) or type(updated_at) ~= "number" or not math.isfinite(updated_at) then
		return nil, "invalid timestamps", false
	end
	if updated_at < created_at then
		return nil, "updated timestamp precedes created timestamp", false
	end
	if type(write_id) ~= "string" or write_id == "" then
		return nil, "invalid write id", false
	end
	if data ~= nil then
		local ok = pcall(function()
			HttpService:JSONEncode(data)
		end)
		if not ok then
			return nil, "invalid stored data", false
		end
	end
	local ids: { number }? = nil
	if raw_user_ids ~= nil then
		if type(raw_user_ids) ~= "table" then
			return nil, "invalid user_ids", false
		end
		local candidates: { number } = {}
		local raw_user_id_entries = raw_user_ids :: { [number]: unknown }
		for index, value in raw_user_id_entries do
			if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or type(value) ~= "number" then
				return nil, "invalid user_ids", false
			end
			candidates[index] = value
		end
		local normalized, ids_error = normalize_user_ids(candidates)
		if normalized == nil then
			return nil, ids_error or "invalid user_ids", false
		end
		ids = normalized
	end
	local tombstone: Tombstone? = nil
	if raw_tombstone ~= nil then
		if type(raw_tombstone) ~= "table" then
			return nil, "invalid tombstone", false
		end
		local deleted_at = get_string_field(raw_tombstone, "deleted_at")
		local generation = get_string_field(raw_tombstone, "generation")
		if type(deleted_at) ~= "number" or not math.isfinite(deleted_at) or type(generation) ~= "number" or not math.isfinite(generation) or math.floor(generation) ~= generation or generation < 1 then
			return nil, "invalid tombstone", false
		end
		tombstone = {
			deleted_at = deleted_at,
			generation = generation,
		}
	end
	local session: SessionEnvelope? = nil
	if raw_session ~= nil then
		if type(raw_session) ~= "table" then
			return nil, "invalid session", false
		end
		local token = get_string_field(raw_session, "token")
		local generation = get_string_field(raw_session, "generation")
		local job_id = get_string_field(raw_session, "job_id")
		local place_id = get_string_field(raw_session, "place_id")
		local acquired_at = get_string_field(raw_session, "acquired_at")
		local lease_until = get_string_field(raw_session, "lease_until")
		if type(token) ~= "string" or token == "" or type(generation) ~= "number" or not math.isfinite(generation) or math.floor(generation) ~= generation or generation < 1 or type(job_id) ~= "string" or job_id == "" or type(place_id) ~= "number" or not math.isfinite(place_id) or place_id < 0 or math.floor(place_id) ~= place_id or type(acquired_at) ~= "number" or not math.isfinite(acquired_at) or type(lease_until) ~= "number" or not math.isfinite(lease_until) then
			return nil, "invalid session", false
		end

		if lease_until < acquired_at then
			return nil, "session lease precedes acquisition", false
		end

		session = {
			token = token,
			generation = generation,
			job_id = job_id,
			place_id = place_id,
			acquired_at = acquired_at,
			lease_until = lease_until,
		}
	end
	if fencing_generation == 0 and (tombstone ~= nil or session ~= nil) then
		return nil, "zero fencing generation is only valid for an inactive non-tombstoned envelope", false
	end
	if tombstone ~= nil and tombstone.generation ~= fencing_generation then
		return nil, "tombstone generation does not match fencing generation", false
	end
	if tombstone == nil and data == nil then
		return nil, "non-tombstoned envelope is missing data", false
	end
	if tombstone ~= nil and (data ~= nil or session ~= nil) then
		return nil, "tombstoned envelope contains data or a session", false
	end
	if session ~= nil and session.generation ~= fencing_generation then
		return nil, "session generation does not match fencing generation", false
	end
	local restored_data = data
	if raw_non_finite_numbers ~= nil then
		if data == nil then
			if type(raw_non_finite_numbers) ~= "table" or next(raw_non_finite_numbers :: { [any]: unknown }) ~= nil then
				return nil, "tombstoned envelope has invalid non-finite number metadata", false
			end
		else
			local decoded, decode_error = restore_non_finite_numbers(data, raw_non_finite_numbers)
			if decoded == nil then
				return nil, decode_error or "invalid non-finite number metadata", false
			end
			restored_data = decoded
		end
	end

	return {
		implementation_version = implementation_version,
		schema_version = schema_version,
		revision = revision,
		fencing_generation = fencing_generation,
		created_at = created_at,
		updated_at = updated_at,
		data = restored_data,
		user_ids = ids,
		tombstone = tombstone,
		session = session,
		sidecars = parsed_sidecars,
		write_id = write_id,
	}, nil, true
end

local function matches_session(envelope: Envelope, token: string, generation: number): boolean
	return envelope.session ~= nil and envelope.session.token == token and envelope.session.generation == generation and envelope.fencing_generation == generation
end

local function apply_migrations(state: InternalState, from_version: number, value: JsonValue): (JsonValue?, string?)
	if from_version > state.options.schema_version then
		return nil, "stored schema is newer than this server supports"
	end
	local current = value
	if from_version == state.options.schema_version then
		return current, nil
	end
	if state.options.migrations == nil then
		return nil, "required migration is missing"
	end
	for version = from_version, state.options.schema_version - 1 do
		local migration = state.options.migrations[version]
		if migration == nil then
			return nil, "required migration is missing at version " .. tostring(version)
		end
		local next_value, migration_error = run_migration(migration, version, current)
		if next_value == nil then
			return nil, migration_error or "migration failed"
		end
		current = next_value
	end
	return current, nil
end

local function update_local_from_envelope(state: InternalState, envelope: Envelope, info: BackendInfo?)
	state.data = copy_value(envelope.data)
	state.public_data_source = copy_value(state.data)
	if state.public_record ~= nil then
		local public_record: any = state.public_record
		public_record.Data = state.data
	end
	state.generation = envelope.fencing_generation
	state.revision = envelope.revision
	state.created_at = envelope.created_at
	state.updated_at = envelope.updated_at
	state.user_ids = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {}
	state.metadata = if info ~= nil then clone_metadata(info.Metadata) else state.metadata
	state.tombstoned = envelope.tombstone ~= nil
	state.token = if envelope.session ~= nil then envelope.session.token else nil
	state.durable_lease_until = if envelope.session ~= nil then envelope.session.lease_until else 0
	state.last_observed = now_unix()
	if envelope.session ~= nil then
		state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
	else
		state.next_renewal = math.huge
	end
	state.save_requested = false
end

local function make_durable_snapshot(envelope: Envelope, info: BackendInfo?, reason: string): DurableSnapshot
	return {
		Data = copy_value(envelope.data),
		Revision = envelope.revision,
		Generation = envelope.fencing_generation,
		UpdatedAt = envelope.updated_at,
		ConfirmedAt = now_unix(),
		WriteId = envelope.write_id,
		Reason = reason,
		Tombstoned = envelope.tombstone ~= nil,
		UserIds = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {},
		Metadata = if info ~= nil then clone_metadata(info.Metadata) else {},
		BackendVersion = if info ~= nil then info.Version else nil,
		BackendCreatedAt = if info ~= nil then info.CreatedTime else nil,
		BackendUpdatedAt = if info ~= nil then info.UpdatedTime else nil,
	}
end

local function clone_durable_snapshot(snapshot: DurableSnapshot?): DurableSnapshot?
	if snapshot == nil then
		return nil
	end
	return {
		Data = copy_value(snapshot.Data),
		Revision = snapshot.Revision,
		Generation = snapshot.Generation,
		UpdatedAt = snapshot.UpdatedAt,
		ConfirmedAt = snapshot.ConfirmedAt,
		WriteId = snapshot.WriteId,
		Reason = snapshot.Reason,
		Tombstoned = snapshot.Tombstoned,
		UserIds = clone_user_ids(snapshot.UserIds),
		Metadata = clone_metadata(snapshot.Metadata),
		BackendVersion = snapshot.BackendVersion,
		BackendCreatedAt = snapshot.BackendCreatedAt,
		BackendUpdatedAt = snapshot.BackendUpdatedAt,
	}
end

local function snapshot_from_envelope(key: string, envelope: Envelope, info: BackendInfo?): Snapshot
	local session = envelope.session
	local session_active = session ~= nil and session.lease_until > now_unix()
	return {
		Data = copy_value(envelope.data),
		State = if envelope.tombstone ~= nil then "tombstoned" elseif session_active then "active" else "closed",
		Key = key,
		SchemaVersion = envelope.schema_version,
		Generation = envelope.fencing_generation,
		Revision = envelope.revision,
		CreatedAt = envelope.created_at,
		UpdatedAt = envelope.updated_at,
		Tombstoned = envelope.tombstone ~= nil,
		SessionActive = session_active,
		LeaseUntil = if session ~= nil then session.lease_until else nil,
		SessionJobId = if session ~= nil then session.job_id else nil,
		SessionPlaceId = if session ~= nil then session.place_id else nil,
		UserIds = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {},
		Metadata = if info ~= nil then clone_metadata(info.Metadata) else {},
		BackendVersion = if info ~= nil then info.Version else nil,
		BackendCreatedAt = if info ~= nil then info.CreatedTime else nil,
		BackendUpdatedAt = if info ~= nil then info.UpdatedTime else nil,
	}
end

local function validate_envelope(envelope: Envelope): (boolean, string?)
	prepared_envelope_cache[envelope] = nil
	if envelope.implementation_version > prepared_envelope_cache._sidecar_protocol.max_readable_version then
		return false, "envelope implementation version is not readable"
	end
	if envelope.sidecars ~= nil then
		if envelope.implementation_version < prepared_envelope_cache._sidecar_protocol.transaction_version then
			return false, "transaction sidecars require implementation version 3"
		end
		local sidecars_valid, sidecars_error = prepared_envelope_cache._sidecar_protocol.validate(envelope.sidecars)
		if not sidecars_valid then return false, sidecars_error end
	elseif envelope.implementation_version >= prepared_envelope_cache._sidecar_protocol.transaction_version then
		return false, "version 3 envelope is missing transaction sidecars"
	end
	local prepared = encode_envelope_for_storage(envelope)
	local valid, message = validate_serialized_size(prepared)
	if valid then
		prepared_envelope_cache[envelope] = prepared
	end
	return valid, message
end

local function decode_legacy_read(raw: unknown, decoder: LegacyDecoder?): (Envelope?, string?)
	if decoder == nil then
		return nil, "legacy payload requires a legacy_decoder"
	end
	local value, version, decoder_error = run_legacy_decoder(decoder, raw)
	if value == nil then
		return nil, decoder_error or "legacy decoder failed"
	end
	return {
		implementation_version = IMPLEMENTATION_VERSION,
		schema_version = version or 0,
		revision = 0,
		fencing_generation = 0,
		created_at = 0,
		updated_at = 0,
		data = value,
		user_ids = nil,
		tombstone = nil,
		session = nil,
		sidecars = nil,
		write_id = "legacy",
	}, nil
end

local function make_queue_envelope(
	owner: QueueOwner,
	messages: { QueueItem },
	dead_letters: { DeadLetterItem }?
): QueueEnvelope
	return {
		implementation_version = QUEUE_IMPLEMENTATION_VERSION,
		owner = owner,
		messages = messages,
		dead_letters = dead_letters or {},
	}
end

local function parse_queue_messages(raw: unknown, expected_version: number): ({ QueueItem }?, string?)
	if raw == nil then
		return {}, nil
	end
	if type(raw) ~= "table" then
		return nil, "durable queue is corrupt"
	end
	local implementation_version = get_string_field(raw, "implementation_version")
	local messages_value = get_string_field(raw, "messages")
	if implementation_version ~= expected_version or type(messages_value) ~= "table" then
		return nil, "durable queue is corrupt"
	end
	local messages = messages_value :: { [number]: unknown }
	local result: { QueueItem } = {}
	local seen_ids: { [string]: boolean } = {}
	local length = #messages
	local count = 0
	for index, item in messages do
		if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or index > length then
			return nil, "durable queue message list must be a dense array"
		end
		count += 1
		if type(item) ~= "table" then
			return nil, "durable queue contains an invalid message"
		end
		local id = get_string_field(item, "id")
		local message_type = get_string_field(item, "type")
		local attempts = get_string_field(item, "attempts")
		local total_attempts_raw = get_string_field(item, "total_attempts")
		local replay_count_raw = get_string_field(item, "replay_count")
		local sender_job_id = get_string_field(item, "sender_job_id")
		local created_at = get_string_field(item, "created_at")
		local locked_until = get_string_field(item, "locked_until")
		local total_attempts = if total_attempts_raw == nil then attempts else total_attempts_raw
		local replay_count = if replay_count_raw == nil then 0 else replay_count_raw
		if type(id) ~= "string"
			or id == ""
			or #id > 100
			or type(message_type) ~= "string"
			or message_type == ""
			or #message_type > MAX_MESSAGE_TYPE_LENGTH
			or type(attempts) ~= "number"
			or not math.isfinite(attempts)
			or math.floor(attempts) ~= attempts
			or attempts < 0
			or type(total_attempts) ~= "number"
			or not math.isfinite(total_attempts)
			or math.floor(total_attempts) ~= total_attempts
			or total_attempts < attempts
			or type(replay_count) ~= "number"
			or not math.isfinite(replay_count)
			or math.floor(replay_count) ~= replay_count
			or replay_count < 0
			or type(sender_job_id) ~= "string"
			or sender_job_id == ""
			or type(created_at) ~= "number"
			or not math.isfinite(created_at)
			or type(locked_until) ~= "number"
			or not math.isfinite(locked_until)
		then
			return nil, "durable queue contains an invalid message"
		end
		if seen_ids[id] then
			return nil, "durable queue contains a duplicate message ID"
		end
		seen_ids[id] = true
		local lock_token = get_string_field(item, "lock_token")
		if lock_token ~= nil and (type(lock_token) ~= "string" or lock_token == "" or #lock_token > 100) then
			return nil, "durable queue contains an invalid lock token"
		end
		local last_replay_token = get_string_field(item, "last_replay_token")
		if last_replay_token ~= nil and (type(last_replay_token) ~= "string" or last_replay_token == "" or #last_replay_token > 100) then
			return nil, "durable queue contains an invalid replay token"
		end
		local data = get_string_field(item, "data")
		if data ~= nil then
			local valid, message = validate_serialized_size(data)
			if not valid then
				return nil, message or "durable queue data is invalid"
			end
		end
		result[#result + 1] = ({
			id = id,
			type = message_type,
			data = copy_value(data),
			attempts = attempts,
			total_attempts = total_attempts,
			replay_count = replay_count,
			last_replay_token = last_replay_token,
			sender_job_id = sender_job_id,
			created_at = created_at,
			locked_until = locked_until,
			lock_token = lock_token,
		} :: unknown) :: QueueItem
	end
	if count ~= length then
		return nil, "durable queue message list must be a dense array"
	end
	return result, nil
end

local function parse_queue_envelope(
	raw: unknown,
	expected_owner: QueueOwner
): (QueueEnvelope?, string?, boolean?)
	if raw == nil then
		return make_queue_envelope(expected_owner, {}), nil, false
	end
	if type(raw) ~= "table" then
		return nil, "durable queue is corrupt", false
	end
	local implementation_version = get_string_field(raw, "implementation_version")
	if type(implementation_version) ~= "number" or (implementation_version ~= 2 and implementation_version ~= QUEUE_IMPLEMENTATION_VERSION) then
		return nil, "durable queue is corrupt", false
	end
	local queue_version: number = implementation_version
	local owner = get_string_field(raw, "owner")
	if type(owner) ~= "table" then
		return nil, "durable queue is corrupt: owner is missing", false
	end
	local owner_name = get_string_field(owner, "name")
	local owner_scope = get_string_field(owner, "scope")
	local owner_key = get_string_field(owner, "key")
	if type(owner_name) ~= "string"
		or type(owner_scope) ~= "string"
		or type(owner_key) ~= "string"
	then
		return nil, "durable queue is corrupt: owner identity is invalid", false
	end
	if owner_name ~= expected_owner.name
		or owner_scope ~= expected_owner.scope
		or owner_key ~= expected_owner.key
	then
		return nil, "durable queue belongs to a different record identity", true
	end
	local messages, parse_error = parse_queue_messages(raw, queue_version)
	if messages == nil then
		return nil, parse_error, false
	end
	local dead_letters: { DeadLetterItem } = {}
	local seen_ids: { [string]: boolean } = {}
	for _, item in ipairs(messages) do
		seen_ids[item.id] = true
	end
	if queue_version == QUEUE_IMPLEMENTATION_VERSION then
		local raw_dead_letters = get_string_field(raw, "dead_letters")
		if type(raw_dead_letters) ~= "table" then
			return nil, "durable queue dead-letter list is invalid", false
		end
		local dead_letter_entries = raw_dead_letters :: { [number]: unknown }
		local length = #dead_letter_entries
		local count = 0
		for index, item in dead_letter_entries do
			if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or index > length then
				return nil, "durable queue dead-letter list must be a dense array", false
			end
			count += 1
			local parsed_messages, item_error = parse_queue_messages({
				implementation_version = QUEUE_IMPLEMENTATION_VERSION,
				messages = { item },
			}, QUEUE_IMPLEMENTATION_VERSION)
			if parsed_messages == nil or parsed_messages[1] == nil then
				return nil, item_error or "durable queue contains an invalid dead letter", false
			end
			local dead_lettered_at = get_string_field(item, "dead_lettered_at")
			local last_error = get_string_field(item, "last_error")
			local terminal_lock_token = get_string_field(item, "terminal_lock_token")
			if type(dead_lettered_at) ~= "number" or not math.isfinite(dead_lettered_at) or dead_lettered_at < 0
				or type(last_error) ~= "string" or #last_error > MAX_QUEUE_ERROR_LENGTH
				or (terminal_lock_token ~= nil and (type(terminal_lock_token) ~= "string" or terminal_lock_token == "" or #terminal_lock_token > 100))
			then
				return nil, "durable queue contains an invalid dead letter", false
			end
			local parsed = parsed_messages[1]
			if seen_ids[parsed.id] then
				return nil, "durable queue contains a duplicate message ID", false
			end
			seen_ids[parsed.id] = true
			dead_letters[#dead_letters + 1] = ({
				id = parsed.id,
				type = parsed.type,
				data = parsed.data,
				attempts = parsed.attempts,
				total_attempts = parsed.total_attempts,
				replay_count = parsed.replay_count,
				last_replay_token = parsed.last_replay_token,
				sender_job_id = parsed.sender_job_id,
				created_at = parsed.created_at,
				locked_until = parsed.locked_until,
				lock_token = parsed.lock_token,
				dead_lettered_at = dead_lettered_at,
				last_error = last_error,
				terminal_lock_token = terminal_lock_token,
			} :: unknown) :: DeadLetterItem
		end
		if count ~= length then
			return nil, "durable queue dead-letter list must be a dense array", false
		end
	end
	return make_queue_envelope(expected_owner, messages, dead_letters), nil, false
end

local function parse_legacy_queue_envelope(raw: unknown): ({ QueueItem }?, string?)
	return parse_queue_messages(raw, 1)
end

local function read_queue_after_update(
	backend: Backend,
	returned_value: unknown,
	deadline: number,
	state: InternalState?,
	owner: QueueOwner
): (QueueEnvelope?, ResultCode?, string?)
	local value = returned_value
	if value == nil then
		local read_value, _, read_code, read_message = backend_get(backend, false, deadline, state)
		if read_code ~= nil then
			return nil, "unknown", "queue operation outcome could not be verified: " .. (read_message or read_code)
		end
		value = read_value
	end
	local queue, parse_message, owner_mismatch = parse_queue_envelope(value, owner)
	if queue == nil then
		return nil, if owner_mismatch then "conflict" else "corrupt", parse_message or "durable queue is corrupt"
	end
	return queue, nil, nil
end

local function queue_item_to_public(item: QueueItem): QueueMessage
	return {
		Id = item.id,
		Type = item.type,
		Data = copy_value(item.data),
		Attempts = item.attempts,
		TotalAttempts = item.total_attempts,
		ReplayCount = item.replay_count,
		SenderJobId = item.sender_job_id,
		CreatedAt = item.created_at,
	}
end

local function dead_letter_to_public(item: DeadLetterItem): DeadLetterMessage
	return {
		Id = item.id,
		Type = item.type,
		Data = copy_value(item.data),
		Attempts = item.attempts,
		TotalAttempts = item.total_attempts,
		ReplayCount = item.replay_count,
		SenderJobId = item.sender_job_id,
		CreatedAt = item.created_at,
		DeadLetteredAt = item.dead_lettered_at,
		LastError = item.last_error,
		LockToken = item.lock_token,
		LockedUntil = item.locked_until,
	}
end

local function ensure_legacy_queue_clear(
	name: string,
	scope: string,
	key: string,
	queue_store_name: string,
	mock: boolean,
	deadline: number,
	state: InternalState?
): (ResultCode?, string?)
	if state ~= nil and state.queue_legacy_checked then
		return nil, nil
	end
	local legacy_backend = make_backend(
		queue_store_name,
		scope,
		make_queue_key_legacy(name, scope, key),
		mock
	)
	local raw, _, read_code, read_message = backend_get(legacy_backend, false, deadline, state)
	if read_code ~= nil then
		return normalize_result_code(read_code) or "unknown", read_message
	end
	local messages, parse_message = parse_legacy_queue_envelope(raw)
	if messages == nil then
		return "corrupt", parse_message or "legacy durable queue is corrupt; it was left untouched"
	end
	if #messages > 0 then
		return "migration", "nonempty legacy durable queue has no verifiable owner; it was left untouched and requires manual recovery"
	end
	if state ~= nil then
		state.queue_legacy_checked = true
	end
	return nil, nil
end

local function queue_backend_for_state(state: InternalState): Backend?
	if not (state.options.durable_queue_enabled ~= false) then
		return nil
	end
	if state.queue_backend ~= nil then
		return state.queue_backend
	end
	local queue_store_name = state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME
	if #queue_store_name == 0 or #queue_store_name > 50 then
		return nil
	end
	state.queue_backend = make_backend(
		queue_store_name,
		state.scope,
		make_queue_key_v2(state.name, state.scope, state.key),
		state.backend.mock
	)
	return state.queue_backend
end

local function queue_size_error(queue: QueueEnvelope, max_bytes: number): string?
	local size_ok, size_message = validate_serialized_size(queue)
	if not size_ok then
		return size_message or "durable queue exceeds the DataStore value limit"
	end
	local encoded_ok, encoded = pcall(function()
		return HttpService:JSONEncode(queue)
	end)
	if not encoded_ok or type(encoded) ~= "string" then
		return "durable queue could not be encoded"
	end
	if #encoded > max_bytes then
		return "durable queue exceeds its configured size limit"
	end
	return nil
end

local function normalize_queue_error(message: string): string
	local printable = string.gsub(message, "[^ -~]", "?")
	return string.sub(printable, 1, MAX_QUEUE_ERROR_LENGTH)
end

local function claim_queue_message(state: InternalState): (QueueItem?, ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return nil, "invalid", "durable queue is disabled"
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return nil, normalize_result_code(migration_code) or "unknown", migration_message
	end
	local token = HttpService:GenerateGUID(false)
	local max_attempts = state.options.queue_max_attempts or DEFAULT_QUEUE_MAX_ATTEMPTS
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_messages = table.clone(queue.messages)
		local next_dead_letters = table.clone(queue.dead_letters)
		local changed = false
		local index = 1
		while index <= #next_messages do
			local item = next_messages[index]
			if item.locked_until <= transform_time and item.attempts >= max_attempts then
				table.remove(next_messages, index)
				next_dead_letters[#next_dead_letters + 1] = {
					id = item.id,
					type = item.type,
					data = copy_value(item.data),
					attempts = item.attempts,
					total_attempts = item.total_attempts,
					replay_count = item.replay_count,
					last_replay_token = item.last_replay_token,
					sender_job_id = item.sender_job_id,
					created_at = item.created_at,
					locked_until = 0,
					lock_token = nil,
					dead_lettered_at = transform_time,
					last_error = "processing lock expired after the maximum attempt count",
					terminal_lock_token = item.lock_token,
				}
				changed = true
			elseif item.locked_until <= transform_time then
				local next_item: QueueItem = {
					id = item.id,
					type = item.type,
					data = copy_value(item.data),
					attempts = item.attempts + 1,
					total_attempts = item.total_attempts + 1,
					replay_count = item.replay_count,
					last_replay_token = item.last_replay_token,
					sender_job_id = item.sender_job_id,
					created_at = item.created_at,
					locked_until = transform_time + (state.options.queue_lease_duration or DEFAULT_QUEUE_LEASE_DURATION),
					lock_token = token,
				}
				next_messages[index] = next_item
				changed = true
				local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
				local size_error = queue_size_error(next_queue, max_bytes)
				if size_error ~= nil then
					decision = "validation"
					decision_message = "queue claim was not applied: " .. size_error
					return nil, nil, nil
				end
				decision = "success"
				return next_queue, nil, nil
			else
				index += 1
			end
		end
		if changed then
			local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
			local size_error = queue_size_error(next_queue, max_bytes)
			if size_error ~= nil then
				decision = "validation"
				decision_message = "queue claim was not applied: " .. size_error
				return nil, nil, nil
			end
			decision = "success"
			return next_queue, nil, nil
		end
		return nil, nil, nil
	end, deadline, state)
	if result_code ~= nil then
		return nil, normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return nil, normalize_result_code(verify_code) or "unknown", verify_message
	end
	local verification_time = queue_now_unix(backend.mock)
	for _, item in ipairs(queue.messages) do
		if item.lock_token == token and item.locked_until > verification_time then
			return item, "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return nil, decision, decision_message or result_message
	end
	return nil, "empty", nil
end

local function acknowledge_queue_message(state: InternalState, message_id: string, lock_token: string): (ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return normalize_result_code(migration_code) or "unknown", migration_message
	end
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_messages: { QueueItem } = {}
		local found = false
		for _, item in ipairs(queue.messages) do
			if item.id == message_id and item.lock_token == lock_token and item.locked_until > transform_time then
				found = true
			else
				next_messages[#next_messages + 1] = item
			end
		end
		if not found then
			return nil, nil, nil
		end
		local next_queue = make_queue_envelope(owner, next_messages, queue.dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			return nil, nil, nil
		end
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil then
		return normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return normalize_result_code(verify_code) or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id then
			return "conflict", "durable queue message is still present and is no longer owned by this acknowledgement"
		end
	end
	for _, item in ipairs(queue.dead_letters) do
		if item.id == message_id then
			return "conflict", "durable queue message moved to the dead-letter list before acknowledgement"
		end
	end
	return "success", nil
end

local function enqueue_internal(state: InternalState, message_type: string, data: JsonValue?): (ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	if type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH then
		return "invalid", "message_type must be 1 to 100 characters"
	end
	local frozen_data: JsonValue? = nil
	if data ~= nil then
		local copied_ok, copied_or_error = pcall(function()
			return copy_value(data)
		end)
		if not copied_ok or copied_or_error == nil then
			return "validation", "queue data is invalid"
		end
		frozen_data = copied_or_error
		local valid, message = validate_serialized_size(frozen_data)
		if not valid then
			return "validation", message
		end
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return normalize_result_code(migration_code) or "unknown", migration_message
	end
	local message_id = HttpService:GenerateGUID(false)
	local created_at = queue_now_unix(backend.mock)
	local max_messages = state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil or #queue.messages >= max_messages then
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		next_messages[#next_messages + 1] = {
			id = message_id,
			type = message_type,
			data = copy_value(frozen_data),
			attempts = 0,
			total_attempts = 0,
			replay_count = 0,
			last_replay_token = nil,
			sender_job_id = server_id,
			created_at = created_at,
			locked_until = 0,
			lock_token = nil,
		}
		local next_queue = make_queue_envelope(owner, next_messages, queue.dead_letters)
		if queue_size_error(next_queue, max_bytes) ~= nil then
			return nil, nil, nil
		end
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil then
		return normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return normalize_result_code(verify_code) or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id then
			if messaging_enabled(state) then
				local published, publish_error = publish_record_message(state, "queue_hint", nil, nil, nil)
				if not published and publish_error ~= nil then
					observe(state, "queue_hint", "unknown", publish_error)
				end
			end
			return "enqueued", message_id
		end
	end
	if #queue.messages >= max_messages then
		return "validation", "durable queue is full"
	end
	local candidate = table.clone(queue.messages)
	candidate[#candidate + 1] = {
		id = message_id,
		type = message_type,
		data = copy_value(frozen_data),
		attempts = 0,
		total_attempts = 0,
		replay_count = 0,
		last_replay_token = nil,
		sender_job_id = server_id,
		created_at = created_at,
		locked_until = 0,
		lock_token = nil,
	}
	local candidate_queue = make_queue_envelope(owner, candidate, queue.dead_letters)
	local size_message = queue_size_error(candidate_queue, max_bytes)
	if size_message ~= nil then
		return "validation", size_message
	end
	return "unknown", "queue append did not appear in the verified durable state"
end

local function dead_letter_queue_message(
	state: InternalState,
	message_id: string,
	lock_token: string,
	error_message: string
): (ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return normalize_result_code(migration_code) or "unknown", migration_message
	end
	local bounded_error = normalize_queue_error(error_message)
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue, parse_error, owner_mismatch = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = if owner_mismatch then "conflict" else "corrupt"
			decision_message = parse_error
			return nil, nil, nil
		end
		for _, dead_letter in ipairs(queue.dead_letters) do
			if dead_letter.id == message_id and dead_letter.terminal_lock_token == lock_token then
				decision = "success"
				return nil, nil, nil
			end
		end
		local transform_time = queue_now_unix(backend.mock)
		local index: number? = nil
		local item: QueueItem? = nil
		for message_index, queued in ipairs(queue.messages) do
			if queued.id == message_id then
				index = message_index
				item = queued
				break
			end
		end
		if index == nil or item == nil then
			decision = "conflict"
			decision_message = "message is no longer active under this lock token"
			return nil, nil, nil
		end
		if item.lock_token ~= lock_token or item.locked_until <= transform_time then
			decision = "conflict"
			decision_message = "message lock token is stale or expired"
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		table.remove(next_messages, index)
		local next_dead_letters = table.clone(queue.dead_letters)
		next_dead_letters[#next_dead_letters + 1] = {
			id = item.id,
			type = item.type,
			data = copy_value(item.data),
			attempts = item.attempts,
			total_attempts = item.total_attempts,
			replay_count = item.replay_count,
			last_replay_token = item.last_replay_token,
			sender_job_id = item.sender_job_id,
			created_at = item.created_at,
			locked_until = 0,
			lock_token = nil,
			dead_lettered_at = transform_time,
			last_error = bounded_error,
			terminal_lock_token = lock_token,
		}
		local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			decision = "validation"
			decision_message = "dead-letter transition was not applied: " .. size_error
			return nil, nil, nil
		end
		decision = "success"
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return normalize_result_code(result_code) or "unknown", result_message
	end
	local verified_queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if verified_queue == nil then
		return normalize_result_code(verify_code) or "unknown", verify_message
	end
	for _, dead_letter in ipairs(verified_queue.dead_letters) do
		if dead_letter.id == message_id and dead_letter.terminal_lock_token == lock_token then
			return "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return decision, decision_message or result_message
	end
	return "conflict", "message could not be verified in the dead-letter list"
end

process_queue_internal = function(state: InternalState, max_messages: number): (ResultCode, string?)
	if state.retired then
		return "invalid", "record has been retired"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if not (state.options.durable_queue_enabled ~= false) then
		return "empty", "durable queue is disabled"
	end
	if state.queue_busy then
		return "busy", "durable queue is already being processed"
	end
	if state.busy then
		return "busy", "record has a durable operation in flight"
	end
	local handler = state.options.on_queue_message
	if handler == nil then
		return "invalid", "on_queue_message is not configured"
	end
	if type(max_messages) ~= "number" or not math.isfinite(max_messages) or max_messages < 1 or math.floor(max_messages) ~= max_messages then
		return "invalid", "max_messages must be a positive integer"
	end
	max_messages = math.min(max_messages, state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES)
	local max_attempts = state.options.queue_max_attempts or DEFAULT_QUEUE_MAX_ATTEMPTS
	local expected_token = state.token
	if expected_token == nil then
		return "fenced", "session token is missing"
	end
	local processed = 0
	local ownership_lost = false
	local failure_result: ResultCode? = nil
	local failure_message: string? = nil
	state.queue_busy = true
	for _ = 1, max_messages do
		if state.retired or state.state ~= "active" or state.token ~= expected_token or state.takeover_requested then
			ownership_lost = true
			break
		end
		local message, claim_result, claim_error = claim_queue_message(state)
		if claim_result == "empty" then
			break
		end
		if message == nil then
			failure_result = normalize_result_code(claim_result) or "unknown"
			failure_message = claim_error
			break
		end
		if state.retired or state.state ~= "active" or state.token ~= expected_token or state.takeover_requested then
			ownership_lost = true
			break
		end
		local lock_token = message.lock_token
		if lock_token == nil then
			failure_result = "corrupt"
			failure_message = "claimed queue message has no lock token"
			break
		end
		local handled = false
		local handler_message: string? = nil
		local handler_error: string? = nil
		local handler_completed = false
		local handler_thread: thread = coroutine.create(function()
			local ok, result, result_message = pcall(
				handler,
				message.type,
				copy_value(message.data),
				message.attempts,
				message.id,
				message.sender_job_id,
				message.created_at
			)
			if not ok then
				handler_error = tostring(result)
				return
			end
			handler_completed = true
			handled = result == true
			if result_message ~= nil and type(result_message) == "string" then
				handler_message = result_message
			end
		end)
		local handler_resumed = coroutine.resume(handler_thread)
		local attempt_failure: string? = nil
		local attempt_failure_result: ResultCode = "unknown"
		if coroutine.status(handler_thread) ~= "dead" then
			coroutine.close(handler_thread)
			attempt_failure = "queue handler must not yield"
			attempt_failure_result = "invalid"
		elseif not handler_resumed or handler_error ~= nil then
			attempt_failure = "queue handler threw: " .. (handler_error or "execution failed")
		elseif not handler_completed or not handled then
			attempt_failure = handler_message or "queue handler rejected the message"
		end
		if attempt_failure ~= nil then
			observe(state, "queue_process", attempt_failure_result, attempt_failure)
			if message.attempts >= max_attempts then
				local dead_letter_result, dead_letter_message = dead_letter_queue_message(state, message.id, lock_token, attempt_failure)
				if dead_letter_result == "success" then
					processed += 1
					observe(state, "queue_dead_letter", "success", message.id)
					continue
				end
				failure_result = normalize_result_code(dead_letter_result) or "unknown"
				failure_message = dead_letter_message
			else
				failure_result = attempt_failure_result
				failure_message = attempt_failure
			end
			break
		end
		if state.retired or state.state ~= "active" or state.token ~= expected_token or state.takeover_requested then
			ownership_lost = true
			break
		end
		local ack_result, ack_message = acknowledge_queue_message(state, message.id, lock_token)
		if ack_result ~= "success" then
			failure_result = normalize_result_code(ack_result) or "unknown"
			failure_message = ack_message
			observe(state, "queue_ack", normalize_result_code(ack_result) or "unknown", ack_message)
			break
		end
		processed += 1
	end
	state.queue_busy = false
	if ownership_lost then
		return "fenced", "record ownership changed while processing the queue"
	end
	if failure_result ~= nil then
		return failure_result, failure_message
	end
	if processed == 0 then
		return "empty", nil
	end
	return "processed", tostring(processed)
end

local function disconnect_message_subscription(state: InternalState)
	local connection = state.message_subscription
	if connection == nil then
		return
	end
	state.message_subscription = nil
	pcall(function()
		connection:Disconnect()
	end)
	if (state.state :: SessionState) == "active" then
		state.next_message_subscribe = now_local() + MESSAGE_SUBSCRIBE_RETRY
	else
		state.next_message_subscribe = math.huge
	end
end

messaging_enabled = function(state: InternalState): boolean
	return state.options.messaging_enabled ~= false
end

local function takeover_enabled(state: InternalState): boolean
	return messaging_enabled(state) and state.options.takeover_enabled ~= false
end

local function encode_message_payload(payload: { [string]: unknown }): (boolean, string?)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not ok or type(encoded) ~= "string" then
		return false, "message could not be encoded"
	end
	if #encoded > MAX_MESSAGE_BYTES then
		return false, "message exceeds the 900 character RecordStore message limit"
	end
	return true, encoded
end

publish_record_message = function(state: InternalState, kind: string, message_type: string?, data: JsonValue?, generation: number?, target_job_id: string?, target_token: string?, request_id: string?, handoff_status: HandoffStatus?, requester_job_id: string?): (boolean, string?)
	local stable_request_id = request_id or HttpService:GenerateGUID(false)
	local payload: { [string]: unknown } = {
		protocol_version = 1,
		kind = kind,
		name = state.name,
		scope = state.scope,
		key = state.key,
		sender_job_id = server_id,
		requester_job_id = requester_job_id or server_id,
		request_id = stable_request_id,
		message_type = message_type,
		generation = generation,
		target_job_id = target_job_id,
		target_token = target_token,
		handoff_status = handoff_status,
		data = copy_value(data),
	}
	local valid, message = encode_message_payload(payload)
	if not valid then
		return false, message
	end
	local ok, error_message = pcall(function()
		MessagingService:PublishAsync(state.message_topic, payload)
	end)
	if not ok then
		return false, tostring(error_message)
	end
	return true, nil
end

local function decode_message(raw: unknown): { [string]: unknown }?
	if type(raw) ~= "table" then
		return nil
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(raw)
	end)
	if not ok or type(encoded) ~= "string" then
		return nil
	end
	local decode_ok, decoded = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	if not decode_ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function cache_takeover_status(state: InternalState, request_id: string, status: HandoffStatus)
	if state.takeover_seen[request_id] == nil then
		state.takeover_seen_order[#state.takeover_seen_order + 1] = request_id
	end
	state.takeover_seen[request_id] = status
	while #state.takeover_seen_order > TAKEOVER_SEEN_CAPACITY do
		local oldest = table.remove(state.takeover_seen_order, 1)
		if oldest ~= nil then
			state.takeover_seen[oldest] = nil
		end
	end
end

local function publish_handoff_ack(state: InternalState, request_id: string, requester_job_id: string, generation: number, target_token: string, status: HandoffStatus): boolean
	local ok = publish_record_message(state, "handoff_ack", nil, nil, generation, requester_job_id, target_token, request_id, status, requester_job_id)
	if ok then
		state.handoff_ack_count += 1
	end
	return ok
end

local function handle_message(state: InternalState, message: { Data: unknown, Sent: number })
	if state.retired then
		return
	end
	local payload = decode_message(message.Data)
	if payload == nil then
		return
	end
	if payload.protocol_version ~= 1 then
		return
	end
	if payload.name ~= state.name or payload.scope ~= state.scope or payload.key ~= state.key then
		return
	end
	if payload.sender_job_id == server_id or type(payload.sender_job_id) ~= "string" then
		return
	end
	local kind = payload.kind
	if type(kind) ~= "string" or #kind > 32 then
		return
	end
	local request_id = payload.request_id
	if type(request_id) ~= "string" or request_id == "" or #request_id > 64 then
		return
	end
	local generation = payload.generation
	if generation ~= nil and (type(generation) ~= "number" or not math.isfinite(generation)) then
		return
	end
	if kind == "handoff_ack" then
		if payload.target_job_id ~= server_id or type(payload.handoff_status) ~= "string" then
			return
		end
		if state.handoff_request_id ~= request_id then
			return
		end
		local status = payload.handoff_status
		if status ~= "accepted" and status ~= "released" and status ~= "busy" and status ~= "stale" and status ~= "not_owner" and status ~= "failed" then
			return
		end
		if state.handoff_target_generation ~= nil and generation ~= state.handoff_target_generation then
			return
		end
		if state.handoff_target_token ~= nil and payload.target_token ~= state.handoff_target_token then
			return
		end
		state.handoff_status = status
		observe(state, "handoff_ack", "success", status)
		return
	end
	if kind == "takeover_request" then
		local requester_job_id = payload.requester_job_id
		if type(requester_job_id) ~= "string" or requester_job_id == server_id then
			return
		end
		if payload.target_job_id ~= server_id or type(payload.target_token) ~= "string" or type(generation) ~= "number" then
			return
		end
		local cached = state.takeover_seen[request_id]
		if cached ~= nil then
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or payload.target_token, normalize_handoff_status(cached) or "failed")
			return
		end
		if not takeover_enabled(state) then
			cache_takeover_status(state, request_id, "failed")
			publish_handoff_ack(state, request_id, requester_job_id, generation, payload.target_token, "failed")
			return
		end
		if state.state ~= "active" then
			cache_takeover_status(state, request_id, "not_owner")
			publish_handoff_ack(state, request_id, requester_job_id, generation, payload.target_token, "not_owner")
			return
		end
		if payload.target_token ~= state.token or generation ~= state.generation then
			cache_takeover_status(state, request_id, "stale")
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", "stale")
			return
		end
		if state.takeover_requested or state.busy or state.queue_busy then
			cache_takeover_status(state, request_id, "busy")
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", "busy")
			return
		end
		state.takeover_requested = true
		state.takeover_request_id = request_id
		state.takeover_requester_job_id = requester_job_id
		cache_takeover_status(state, request_id, "accepted")
		publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", "accepted")
		complete_deferred_takeover(state)
		return
	end
	if kind == "queue_hint" then
		state.queue_hint = true
		state.next_queue_poll = now_local()
		return
	end
	if kind ~= "message" or type(payload.message_type) ~= "string" or payload.message_type == "" or #payload.message_type > MAX_MESSAGE_TYPE_LENGTH then
		return
	end
	if payload.data ~= nil then
		local data_valid = validate_serialized_size(payload.data)
		if not data_valid then
			return
		end
	end
	local message_type = payload.message_type
	local sender_job_id = payload.sender_job_id
	local observer = state.options.on_message
	if observer ~= nil then
		local data = if payload.data ~= nil then copy_value(payload.data) else nil
		task.spawn(function()
			local thread = coroutine.create(function()
				observer(message_type, data, message.Sent, sender_job_id)
			end)
			local resumed = coroutine.resume(thread)
			if not resumed or coroutine.status(thread) ~= "dead" then
				coroutine.close(thread)
				state.observer_errors += 1
			end
		end)
	end
	observe(state, "message", "success", message_type)
end

local function subscribe_record(state: InternalState)
	if not messaging_enabled(state) or state.message_subscription ~= nil then
		return
	end
	local ok, connection = pcall(function()
		return MessagingService:SubscribeAsync(state.message_topic, function(message)
			handle_message(state, message)
		end)
	end)
	if not ok or connection == nil then
		state.next_message_subscribe = now_local() + MESSAGE_SUBSCRIBE_RETRY
		observe(state, "subscribe", "unknown", tostring(connection))
		return
	end
	state.message_subscription = connection
	state.next_message_subscribe = math.huge
end

local function request_takeover(state: InternalState, generation: number, target_job_id: string, target_token: string, deadline: number): (string?, HandoffStatus)
	if not takeover_enabled(state) then
		return nil, "failed"
	end
	subscribe_record(state)
	local can_receive_ack = state.message_subscription ~= nil
	local now = now_local()
	if state.handoff_request_id ~= nil
		and state.handoff_target_job_id == target_job_id
		and state.handoff_target_token == target_token
		and state.handoff_target_generation == generation
		and now < state.handoff_deadline
	then
		state.handoff_requests_suppressed += 1
		if not can_receive_ack then
			state.handoff_status = "failed"
			return state.handoff_request_id, "failed"
		end
		while now_local() < math.min(deadline, state.handoff_deadline) do
			local status = state.handoff_status
			if status ~= nil and status ~= "pending" then
				return state.handoff_request_id, normalize_handoff_status(status) or "failed"
			end
			task.wait(0.05)
		end
		return state.handoff_request_id, state.handoff_status or "pending"
	end
	local previous_target_job_id = state.handoff_target_job_id
	local previous_target_token = state.handoff_target_token
	local previous_target_generation = state.handoff_target_generation
	local same_target = previous_target_job_id == target_job_id and previous_target_token == target_token and previous_target_generation == generation
	if same_target and now - state.handoff_last_publish < HANDOFF_PUBLISH_COOLDOWN then
		state.handoff_requests_suppressed += 1
		observe(state, "takeover_suppressed", "success", "same target is inside publish cooldown; using DataStore fallback")
		return state.handoff_request_id, "failed"
	end
	local request_id = HttpService:GenerateGUID(false)
	state.handoff_request_id = request_id
	state.handoff_target_job_id = target_job_id
	state.handoff_target_token = target_token
	state.handoff_target_generation = generation
	state.handoff_status = "pending"
	state.handoff_deadline = math.min(deadline, now + (state.options.takeover_wait or DEFAULT_TAKEOVER_WAIT))
	state.handoff_published = false
	local published, publish_message = publish_record_message(state, "takeover_request", nil, nil, generation, target_job_id, target_token, request_id, nil, server_id)
	state.handoff_published = published
	if not published then
		observe(state, "takeover_publish", "unknown", publish_message)
		state.handoff_deadline = now_local()
		return request_id, "failed"
	end
	state.handoff_last_publish = now_local()
	observe(state, "takeover_publish", "success", request_id)
	if not can_receive_ack then
		state.handoff_status = "failed"
		state.handoff_deadline = now_local()
		observe(state, "takeover_fallback", "success", "messaging acknowledgment channel unavailable; using DataStore fallback")
		return request_id, "failed"
	end
	while now_local() < math.min(deadline, state.handoff_deadline) do
		local status = state.handoff_status
		if status ~= nil and status ~= "pending" then
			return request_id, normalize_handoff_status(status) or "failed"
		end
		task.wait(0.05)
	end
	return request_id, state.handoff_status or "pending"
end

local function update_state_metadata_from_info(state: InternalState, info: BackendInfo?)
	if info == nil then
		return
	end
	state.user_ids = clone_user_ids(info.UserIds)
	state.metadata = clone_metadata(info.Metadata)
end

local function save_internal(state: InternalState, reason: string?, operation_deadline: number?, retry_attempts: number?): (ResultCode, string?)
	track_external_data_mutation(state)
	if state.retired then
		return "invalid", "record has been retired"
	end
	if closing and not state.shutdown then
		return "closing", "server is shutting down"
	end
	if state.state ~= "active" then
		return if state.state == "tombstoned" then "tombstoned" else "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy or state.queue_busy then
		state.save_requested = true
		return "busy", (if state.queue_busy then "durable queue is being processed" else "record already has a durable operation in flight")
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local snapshot = copy_value(state.data)
	local captured_change_sequence = state.change_sequence
	local valid, validation_error = validate_value(snapshot, state.options.validator)
	if not valid then
		observe(state, "save", "validation", validation_error)
		return "validation", validation_error
	end
	local generation = state.generation
	local expected_revision = state.revision
	local target_revision = expected_revision + 1
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline or state.options.operation_deadline)
	if deadline == nil then
		return "invalid", deadline_error
	end
	local attempts = retry_attempts or state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	if type(attempts) ~= "number" or not math.isfinite(attempts) or attempts < 1 or attempts > MAX_RETRY_ATTEMPTS or math.floor(attempts) ~= attempts then
		return "invalid", "retry_attempts must be an integer from 1 to " .. tostring(MAX_RETRY_ATTEMPTS)
	end
	state.busy = true
	state.state = "saving"
	local last_error: string? = nil
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			disconnect_message_subscription(state)
			return "closing", "record was retired"
		end
		if now_local() >= deadline then
			break
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id and matches_session(envelope, session_token, generation) and envelope.revision == target_revision then
				if envelope.session == nil or envelope.session.lease_until <= transform_time then
					decision = "fenced"
					decision_message = "durable session lease has expired"
					return nil, nil, nil
				end
				decision = "success"
				return envelope, (if info ~= nil then info.UserIds else state.user_ids), (if info ~= nil then info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.revision ~= expected_revision then
				decision = "conflict"
				decision_message = "durable revision changed unexpectedly"
				return nil, nil, nil
			end
			local session = envelope.session
			if session == nil then
				decision = "fenced"
				decision_message = "durable session is missing"
				return nil, nil, nil
			end
			if session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			local next_envelope: Envelope = {
				implementation_version = envelope.implementation_version,
				schema_version = state.options.schema_version,
				revision = target_revision,
				sidecars = prepared_envelope_cache._sidecar_protocol.clone(envelope.sidecars),
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = snapshot,
				user_ids = clone_user_ids(state.user_ids),
				tombstone = nil,
				session = {
					token = session_token,
					generation = generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = session.acquired_at,
					lease_until = transform_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				write_id = write_id,
			}
			local envelope_valid, envelope_error = validate_envelope(next_envelope)
			if not envelope_valid then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			decision = "success"
			return next_envelope, state.user_ids, make_backend_metadata(state.metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = normalize_result_code(result_code)
			decision_message = result_message
		end
		if state.retired or (state.state :: SessionState) ~= "saving" then
			state.busy = false
			return "closing", "save was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and matches_session(returned, session_token, generation) and returned.session ~= nil and returned.session.lease_until > session_now_unix(state.backend.mock) and returned.revision == target_revision and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "conflict" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "save", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			observe(state, "save", "validation", decision_message)
			return "validation", decision_message
		end
		if result_code ~= nil and result_code ~= "unknown" then
			last_error = result_message
		elseif result == nil then
			last_error = result_message or "save response did not confirm the requested write"
		end
		local verified, envelope, info_after = verify_snapshot_write(state, write_id, session_token, generation, target_revision, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		track_external_data_mutation(state)
		state.busy = false
		state.state = "unknown"
		state.pending_operation = {
			kind = "save",
			snapshot = copy_value(snapshot),
			captured_change_sequence = captured_change_sequence,
			expected_revision = expected_revision,
			target_revision = target_revision,
			operation_id = write_id,
			session_token = session_token,
			fencing_generation = generation,
			reason = reason or "manual",
			started_at = now_local(),
			attempts = 0,
		}
		state.next_reconciliation = now_local() + 0.25
		state.last_reconciliation_category = "save_outcome_unknown"
		observe(state, "save", "unknown", last_error or "save outcome is unresolved")
		return "unknown", last_error or "save outcome is unresolved"
	end
	track_external_data_mutation(state)
	local local_changed_during_save = state.change_sequence ~= captured_change_sequence
	state.generation = confirmed.fencing_generation
	state.revision = confirmed.revision
	state.created_at = confirmed.created_at
	state.updated_at = confirmed.updated_at
	state.tombstoned = confirmed.tombstone ~= nil
	state.token = if confirmed.session ~= nil then confirmed.session.token else state.token
	state.durable_lease_until = if confirmed.session ~= nil then confirmed.session.lease_until else 0
	state.last_observed = now_unix()
	state.saved_change_sequence = math.max(state.saved_change_sequence, captured_change_sequence)
	if not local_changed_during_save then
		update_local_from_envelope(state, confirmed, confirmed_info)
		state.dirty_since_local = nil
	else
		if state.dirty_since_local == nil then
			state.dirty_since_local = now_local()
		end
		state.save_requested = true
		state.next_autosave = now_local()
	end
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, reason or "manual")
	state.pending_operation = nil
	state.next_reconciliation = math.huge
	state.last_reconciliation_category = nil
	state.last_successful_write_local = now_local()
	state.busy = false
	state.state = "active"
	state.next_autosave = now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL)
	if state.save_requested then
		state.next_autosave = now_local()
		state.save_requested = false
	end
	observe(state, "save", "saved", reason)
	complete_deferred_takeover(state)
	return "saved", nil
end

function RecordStore.read_async(name: string, scope: string, key: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, "invalid", "legacy_decoder must be a function"
	end
	local backend = make_backend(name, scope, key, false)
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	local raw, info, result_code, result_message = backend_get(backend, false, deadline)
	if result_code ~= nil then
		return nil, normalize_result_code(result_code) or "unknown", result_message
	end
	if raw == nil then
		return nil, "not_found", "record does not exist"
	end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		if parse_error == "legacy payload" and legacy_decoder ~= nil then
			local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
			if legacy_envelope == nil then
				return nil, "legacy", legacy_error
			end
			return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "read-only legacy payload"
		end
		return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "durable envelope is invalid"
	end
	if envelope == nil then
		return nil, "corrupt", "durable envelope is missing"
	end
	return snapshot_from_envelope(key, envelope, info), "success", nil
end

local function list_versions_internal(name: string, scope: string, key: string, sort_direction: Enum.SortDirection?, min_date_ms: number?, max_date_ms: number?, max_versions: number?, operation_deadline: number?, mock: boolean): ({ HistoryEntry }?, ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	if min_date_ms ~= nil and (type(min_date_ms) ~= "number" or not math.isfinite(min_date_ms) or min_date_ms <= 0 or math.floor(min_date_ms) ~= min_date_ms) then
		return nil, "invalid", "min_date_ms must be a positive integer"
	end
	if max_date_ms ~= nil and (type(max_date_ms) ~= "number" or not math.isfinite(max_date_ms) or max_date_ms <= 0 or math.floor(max_date_ms) ~= max_date_ms) then
		return nil, "invalid", "max_date_ms must be a positive integer"
	end
	if min_date_ms ~= nil and max_date_ms ~= nil and min_date_ms > max_date_ms then
		return nil, "invalid", "min_date_ms must not exceed max_date_ms"
	end
	if max_versions ~= nil and (type(max_versions) ~= "number" or not math.isfinite(max_versions) or max_versions < 1 or max_versions ~= math.floor(max_versions)) then
		return nil, "invalid", "max_versions must be a positive integer"
	end
	if sort_direction ~= nil and sort_direction ~= Enum.SortDirection.Ascending and sort_direction ~= Enum.SortDirection.Descending then
		return nil, "invalid", "sort_direction must be Ascending or Descending"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	local limit = max_versions or 100
	if mock then
		local store = get_mock_store(name, scope)
		local entry = store[key]
		if entry == nil then
			return {}, "success", nil
		end
		local entries: { HistoryEntry } = {}
		local order = table.clone(entry.VersionOrder)
		if (sort_direction or Enum.SortDirection.Descending) == Enum.SortDirection.Descending then
			local order_length = #order
			for index = 1, math.floor(order_length / 2) do
				local other_index = order_length - index + 1
				order[index], order[other_index] = order[other_index], order[index]
			end
		end
		for _, version in ipairs(order) do
			local item = entry.Versions[version]
			if item ~= nil and (min_date_ms == nil or item.CreatedTime >= min_date_ms) and (max_date_ms == nil or item.CreatedTime <= max_date_ms) then
				entries[#entries + 1] = {
					Version = item.Version,
					CreatedTime = item.CreatedTime,
					IsDeleted = item.Deleted,
				}
				if #entries >= limit then
					break
				end
			end
		end
		return entries, "success", nil
	end
	local backend = make_backend(name, scope, key, false)
	local store = backend.store
	if store == nil then
		return nil, "invalid", "backend store is missing"
	end
	if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardList) then
		return nil, "budget", "version list request deadline exceeded"
	end
	local ok, pages = pcall(function()
		return store:ListVersionsAsync(key, sort_direction or Enum.SortDirection.Descending, min_date_ms, max_date_ms, math.min(limit, 100))
	end)
	release_slot()
	if not ok then
		return nil, "unknown", tostring(pages)
	end
	local result: { HistoryEntry } = {}
	while true do
		if now_local() >= deadline then
			return result, "budget", "version list deadline exceeded"
		end
		for _, item in pages:GetCurrentPage() do
			if #result >= limit then
				break
			end
			result[#result + 1] = {
				Version = item.Version,
				CreatedTime = item.CreatedTime,
				IsDeleted = item.IsDeleted,
			}
		end
		if #result >= limit or pages.IsFinished then
			break
		end
		if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardList) then
			return result, "budget", "version pagination deadline exceeded"
		end
		local advance_ok, advance_error = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		release_slot()
		if not advance_ok then
			return result, "unknown", tostring(advance_error)
		end
	end
	return result, "success", nil
end

function RecordStore.list_versions_async(name: string, scope: string, key: string, sort_direction: Enum.SortDirection?, min_date_ms: number?, max_date_ms: number?, max_versions: number?, operation_deadline: number?): ({ HistoryEntry }?, ResultCode, string?)
	return list_versions_internal(name, scope, key, sort_direction, min_date_ms, max_date_ms, max_versions, operation_deadline, false)
end

local function get_version_internal(name: string, scope: string, key: string, version: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?, mock: boolean): (Snapshot?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, "invalid", "legacy_decoder must be a function"
	end
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	if type(version) ~= "string" or version == "" then
		return nil, "invalid", "version must be a non-empty string"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	if mock then
		local entry = get_mock_store(name, scope)[key]
		if entry == nil then
			return nil, "not_found", "record does not exist"
		end
		local item = entry.Versions[version]
		if item == nil then
			return nil, "not_found", "version does not exist"
		end
		local info: BackendInfo = {
			Version = item.Version,
			CreatedTime = item.CreatedTime,
			UpdatedTime = item.UpdatedTime,
			UserIds = clone_user_ids(item.UserIds),
			Metadata = clone_metadata(item.Metadata),
			RawMetadata = clone_metadata(item.Metadata),
		}
		local envelope, parse_error, current_format = parse_envelope(item.Value)
		if not current_format then
			if parse_error == "legacy payload" and legacy_decoder ~= nil then
				local legacy_envelope, legacy_error = decode_legacy_read(item.Value, legacy_decoder)
				if legacy_envelope == nil then
					return nil, "legacy", legacy_error
				end
				return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "historical legacy payload"
			end
			return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "historical envelope is invalid"
		end
		if envelope == nil then
			return nil, "corrupt", "historical envelope is missing"
		end
		return snapshot_from_envelope(key, envelope, info), "success", nil
	end
	local backend = make_backend(name, scope, key, false)
	local store = backend.store
	if store == nil then
		return nil, "invalid", "backend store is missing"
	end
	if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardRead) then
		return nil, "budget", "version read deadline exceeded"
	end
	local ok, raw, key_info = pcall(function()
		return store:GetVersionAsync(key, version)
	end)
	release_slot()
	if not ok then
		return nil, "unknown", tostring(raw)
	end
	local info = backend_info_from_key_info(key_info)
	if raw == nil then
		return nil, "not_found", "version does not exist"
	end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		if parse_error == "legacy payload" and legacy_decoder ~= nil then
			local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
			if legacy_envelope == nil then
				return nil, "legacy", legacy_error
			end
			return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "historical legacy payload"
		end
		return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "historical envelope is invalid"
	end
	if envelope == nil then
		return nil, "corrupt", "historical envelope is missing"
	end
	return snapshot_from_envelope(key, envelope, info), "success", nil
end

function RecordStore.get_version_async(name: string, scope: string, key: string, version: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, "invalid", "legacy_decoder must be a function"
	end
	return get_version_internal(name, scope, key, version, operation_deadline, legacy_decoder, false)
end

local function get_version_at_time_internal(name: string, scope: string, key: string, timestamp_ms: number, operation_deadline: number?, legacy_decoder: LegacyDecoder?, mock: boolean): (Snapshot?, string?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, nil, "invalid", "legacy_decoder must be a function"
	end
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, nil, "invalid", identity_message
	end
	if type(timestamp_ms) ~= "number" or not math.isfinite(timestamp_ms) or timestamp_ms <= 0 or math.floor(timestamp_ms) ~= timestamp_ms then
		return nil, nil, "invalid", "timestamp_ms must be a positive integer"
	end
	if timestamp_ms > DateTime.now().UnixTimestampMillis + 600_000 then
		return nil, nil, "invalid", "timestamp_ms cannot be more than ten minutes in the future"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, nil, "invalid", deadline_error
	end
	if mock then
		local entries, list_result, list_message = list_versions_internal(name, scope, key, Enum.SortDirection.Descending, nil, timestamp_ms, 1, operation_deadline, true)
		if list_result ~= "success" then
			return nil, nil, normalize_result_code(list_result) or "unknown", list_message
		end
		if entries == nil or #entries == 0 then
			return nil, nil, "not_found", "no version was available at the requested time"
		end
		local snapshot, result, message = get_version_internal(name, scope, key, entries[1].Version, operation_deadline, legacy_decoder, true)
		return snapshot, entries[1].Version, normalize_result_code(result) or "unknown", message
	end
	local backend = make_backend(name, scope, key, false)
	local store = backend.store
	if store == nil then
		return nil, nil, "invalid", "backend store is missing"
	end
	if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardRead) then
		return nil, nil, "budget", "historical read deadline exceeded"
	end
	local ok, raw, key_info = pcall(function()
		return store:GetVersionAtTimeAsync(key, timestamp_ms)
	end)
	release_slot()
	if not ok then
		return nil, nil, "unknown", tostring(raw)
	end
	local info = backend_info_from_key_info(key_info)
	if raw == nil then
		return nil, nil, "not_found", "no version was available at the requested time"
	end
	local version = if info ~= nil then info.Version else nil
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		if parse_error == "legacy payload" and legacy_decoder ~= nil then
			local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
			if legacy_envelope == nil then
				return nil, version, "legacy", legacy_error
			end
			return snapshot_from_envelope(key, legacy_envelope, info), version, "legacy", "historical legacy payload"
		end
		return nil, version, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "historical envelope is invalid"
	end
	if envelope == nil then
		return nil, version, "corrupt", "historical envelope is missing"
	end
	return snapshot_from_envelope(key, envelope, info), version, "success", nil
end

function RecordStore.get_version_at_time_async(name: string, scope: string, key: string, timestamp_ms: number, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, string?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, nil, "invalid", "legacy_decoder must be a function"
	end
	return get_version_at_time_internal(name, scope, key, timestamp_ms, operation_deadline, legacy_decoder, false)
end



local function data_values_equal(left: JsonValue?, right: JsonValue?, depth: number?): boolean
	local current_depth = depth or 0
	if current_depth > 64 then
		return false
	end
	if left == right then
		return true
	end
	if type(left) == "number"
		and type(right) == "number"
		and math.isnan(left)
		and math.isnan(right)
	then
		return true
	end
	if left == nil or right == nil then
		return false
	end
	local left_type = typeof(left)
	local right_type = typeof(right)
	if left_type == "buffer" or right_type == "buffer" then
		return left_type == "buffer" and right_type == "buffer" and buffer.tostring(left :: buffer) == buffer.tostring(right :: buffer)
	end
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	local left_table: any = left
	local right_table: any = right
	for key, child in left_table do
		local other = right_table[key]
		if other == nil or not data_values_equal(child, other, current_depth + 1) then
			return false
		end
	end
	for key in right_table do
		if left_table[key] == nil then
			return false
		end
	end
	return true
end

local function mark_dirty(state: InternalState)
	if state.dirty_since_local == nil then
		state.dirty_since_local = now_local()
	end
end

track_external_data_mutation = function(state: InternalState)
	if state.public_data_detached then
		return
	end
	if state.state ~= "active" and state.state ~= "saving" then
		return
	end
	local public_record = state.public_record
	local public_data: unknown = state.data
	local public_record_table: { Data: unknown }? = nil
	if type(public_record) == "table" then
		local validated_public_record = public_record :: { Data: unknown }
		public_record_table = validated_public_record
		public_data = validated_public_record.Data
	end
	local candidate = public_data :: JsonValue?
	if data_values_equal(candidate, state.public_data_source) then
		state.data = candidate
		return
	end
	local copied_ok, copied_or_error = pcall(function()
		return copy_value(candidate)
	end)
	if not copied_ok or copied_or_error == nil then
		local rejection_reason = if not copied_ok
			then string.gsub(tostring(copied_or_error), "%c", " ")
			else "Data was set to nil"
		rejection_reason = string.sub(rejection_reason, 1, 180)
		state.data = copy_value(state.public_data_source)
		if public_record_table ~= nil then
			public_record_table.Data = state.data
		end
		state.public_data_source = copy_value(state.data)
		observe(
			state,
			"external_data_mutation",
			"validation",
			"direct Data mutation produced an invalid value and was discarded: " .. rejection_reason
		)
		return
	end
	local candidate_copy = copied_or_error
	local validation_value: JsonValue? = candidate_copy
	if state.options.validator ~= nil then
		validation_value = copy_value(candidate_copy)
	end
	local valid, validation_message = validate_value(validation_value, state.options.validator)
	if not valid then
		state.data = copy_value(state.public_data_source)
		if public_record_table ~= nil then
			public_record_table.Data = state.data
		end
		state.public_data_source = copy_value(state.data)
		observe(state, "external_data_mutation", "validation", validation_message or "direct Data mutation failed validation")
		return
	end
	local old_data = state.public_data_source
	state.data = candidate
	local current_data = copy_value(state.data)
	if current_data == nil then
		state.data = copy_value(state.public_data_source)
		if public_record_table ~= nil then
			public_record_table.Data = state.data
		end
		state.public_data_source = copy_value(state.data)
		observe(state, "external_data_mutation", "validation", "direct Data mutation could not be snapshotted")
		return
	end
	if public_record_table ~= nil then
		public_record_table.Data = state.data
	end
	state.change_sequence += 1
	mark_dirty(state)
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_data, current_data, operation_id, "direct_data_mutation")
	state.save_requested = true
	state.next_autosave = now_local()
	state.last_observed = now_unix()
	state.public_data_source = current_data
end

local function sync_public(record: Record, skip_external_mutation_check: boolean?)
	local state = private[record]
	if state == nil then
		return
	end

	if not state.public_data_detached and not skip_external_mutation_check then
		track_external_data_mutation(state)
	end
	if state.state == "active" or state.state == "saving" then
		if state.public_data_detached then
			state.public_data_detached = false
			state.public_data_source = copy_value(state.data)
		end
		record.Data = state.data
	else
		if not state.public_data_detached then
			if state.data ~= nil then
				local detach_ok, detached_data = pcall(function()
					return copy_value(state.data)
				end)
				if detach_ok and detached_data ~= nil then
					state.data = detached_data
					state.public_data_source = copy_value(detached_data)
				else
					local message = "could not isolate canonical data from a retained public reference"
					state.data = nil
					state.public_data_source = nil
					state.state = "corrupt"
					state.last_error = message
					observe(state, "public_data_detach_failed", "corrupt", message)
				end
			else
				state.public_data_source = nil
			end
			state.public_data_detached = true
		end
		record.Data = if state.data ~= nil then copy_value(state.data) else nil
	end
	if (state.state :: SessionState) == "active" then
		active_records[record] = true
	else
		active_records[record] = nil
	end
	if state.state == "unknown" and state.pending_operation ~= nil and not state.retired then
		recovery_records[record] = true
	else
		recovery_records[record] = nil
	end
	record.State = state.state
	record.Key = state.key
	record.Generation = state.generation
	record.Revision = state.revision
	record.CreatedAt = state.created_at
	record.UpdatedAt = state.updated_at
	record.Tombstoned = state.tombstoned
	record.LastError = state.last_error
end

local function subscribe_changes(self: Record, observer: ChangeObserver): (ChangeSubscription?, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return nil, "invalid", "record does not exist"
	end
	if type(observer) ~= "function" then
		return nil, "invalid", "change observer must be a function"
	end
	local id = state.change_observer_next_id
	state.change_observer_next_id += 1
	state.change_observers[id] = observer
	local connected = true
	local subscription: ChangeSubscription = {
		Disconnect = function(_: ChangeSubscription)
			if not connected then
				return
			end
			connected = false
			state.change_observers[id] = nil
		end,
	}
	return subscription, "success", nil
end

local function get_last_error_info(self: Record): RecordError?
	local state = private[self]
	if state == nil then
		return nil
	end
	local info = state.last_error_info
	if info == nil then
		return nil
	end
	return {
		Code = info.Code,
		Message = info.Message,
		Retryable = info.Retryable,
		RequiresVerification = info.RequiresVerification,
		DurableOutcome = info.DurableOutcome,
		OperationId = info.OperationId,
		Generation = info.Generation,
		Revision = info.Revision,
	}
end

local function get_handoff(self: Record): HandoffResult?
	local state = private[self]
	if state == nil or state.handoff_request_id == nil or state.handoff_target_job_id == nil or state.handoff_target_generation == nil then
		return nil
	end
	return {
		RequestId = state.handoff_request_id,
		Status = state.handoff_status or "pending",
		Generation = state.handoff_target_generation,
		TargetJobId = state.handoff_target_job_id,
		Published = state.handoff_published,
		Deadline = state.handoff_deadline,
		Suppressed = state.handoff_requests_suppressed,
		Acks = state.handoff_ack_count,
	}
end

local function get_key(self: Record): string
	local state = private[self]
	return if state ~= nil then state.key else self.Key
end

local function get_state(self: Record): SessionState
	local state = private[self]
	return if state ~= nil then state.state else self.State
end

local function get_revision(self: Record): number
	local state = private[self]
	return if state ~= nil then state.revision else self.Revision
end

local function get_generation(self: Record): number
	local state = private[self]
	return if state ~= nil then state.generation else self.Generation
end

local function is_open(self: Record): boolean
	local state = private[self]
	return state ~= nil and state.state == "active" and state.token ~= nil
end

local function get_backend_info(self: Record): BackendInfoView
	local state = private[self]
	if state == nil then
		return {
			Version = nil,
			CreatedTime = self.CreatedAt,
			UpdatedTime = self.UpdatedAt,
			UserIds = {},
			Metadata = {},
		}
	end
	local last_saved = state.last_saved
	return {
		Version = if last_saved ~= nil then last_saved.BackendVersion else nil,
		CreatedTime = if last_saved ~= nil and last_saved.BackendCreatedAt ~= nil then last_saved.BackendCreatedAt else state.created_at,
		UpdatedTime = if last_saved ~= nil and last_saved.BackendUpdatedAt ~= nil then last_saved.BackendUpdatedAt else state.updated_at,
		UserIds = if last_saved ~= nil then clone_user_ids(last_saved.UserIds) else clone_user_ids(state.user_ids),
		Metadata = if last_saved ~= nil then clone_metadata(last_saved.Metadata) else clone_metadata(state.metadata),
	}
end

local function get_data(self: Record): JsonValue?
	local state = private[self]
	if state == nil then
		return nil
	end
	if not state.public_data_detached then
		track_external_data_mutation(state)
	end
	self.Data = if state.public_data_detached then copy_value(state.data) else state.data
	return copy_value(state.data)
end

local function get_last_saved(self: Record): DurableSnapshot?
	local state = private[self]
	if state == nil then
		return nil
	end
	return clone_durable_snapshot(state.last_saved)
end

local function is_dirty(self: Record): boolean
	local state = private[self]
	if state == nil then
		return false
	end
	if not state.public_data_detached then
		track_external_data_mutation(state)
	end
	self.Data = if state.public_data_detached then copy_value(state.data) else state.data
	return state.change_sequence ~= state.saved_change_sequence
end

local function can_mutate(self: Record): (boolean, string?)
	local state = private[self]
	if state == nil then
		return false, "record does not exist"
	end
	if state.state ~= "active" or state.token == nil then
		return false, "record ownership is not confirmed active"
	end
	if state.takeover_requested then
		return false, "session takeover has been requested"
	end
	if state.busy or state.queue_busy then
		return false, "record has a durable operation in flight"
	end
	return true, nil
end

local function get_durability_status(self: Record): { [string]: any }
	local state = private[self]
	if state == nil then
		return {
			ownership = "lost",
			durability = "degraded",
			unknown = true,
			last_confirmed_revision = 0,
			last_confirmed_generation = 0,
			dirty_watermark = 0,
			durable_watermark = 0,
			oldest_dirty_age = 0,
			lease_margin = 0,
			pending_operation_id = nil,
			reconciliation_category = "record_missing",
		}
	end
	local dirty = state.change_sequence ~= state.saved_change_sequence
	local pending = state.pending_operation
	local ownership = if state.state == "unknown" then "uncertain"
		elseif state.state == "active" or state.state == "saving" or state.state == "releasing" then "owned"
		else "lost"
	local durability = if state.state == "unknown" then "degraded"
		elseif state.busy then "saving"
		elseif dirty then "dirty"
		else "clean"
	return {
		ownership = ownership,
		durability = durability,
		unknown = state.state == "unknown",
		last_confirmed_revision = state.revision,
		last_confirmed_generation = state.generation,
		dirty_watermark = state.change_sequence,
		durable_watermark = state.saved_change_sequence,
		oldest_dirty_age = if dirty and state.dirty_since_local ~= nil
			then math.max(0, now_local() - state.dirty_since_local) else 0,
		last_successful_write_age = if state.last_successful_write_local ~= nil
			then math.max(0, now_local() - state.last_successful_write_local) else nil,
		lease_margin = math.max(0, state.durable_lease_until - session_now_unix(state.backend.mock)),
		pending_operation_id = if pending ~= nil then pending.operation_id else nil,
		reconciliation_category = state.last_reconciliation_category,
		reconciliation_attempts = if pending ~= nil then pending.attempts else 0,
	}
end

local function get_user_ids(self: Record): { number }
	local state = private[self]
	if state == nil then
		return {}
	end
	return clone_user_ids(state.user_ids)
end

local function set_user_ids(self: Record, user_ids: { number }): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	if type(user_ids) ~= "table" then
		return "validation", "user_ids must be an array of positive integers"
	end
	local normalized, message = normalize_user_ids(user_ids)
	if normalized == nil then
		return "validation", message
	end
	local old_user_ids = state.user_ids
	state.user_ids = normalized
	state.change_sequence += 1
	mark_dirty(state)
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_user_ids, normalized, operation_id, "user_ids")
	state.save_requested = true
	state.next_autosave = now_local()
	sync_public(self)
	return "success", nil
end

local function add_user_id(self: Record, user_id: number): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(user_id) ~= "number" or not math.isfinite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
		return "validation", "user_id must be a positive integer"
	end
	local ids = clone_user_ids(state.user_ids)
	ids[#ids + 1] = user_id
	return set_user_ids(self, ids)
end

local function remove_user_id(self: Record, user_id: number): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(user_id) ~= "number" or not math.isfinite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
		return "validation", "user_id must be a positive integer"
	end
	local ids: { number } = {}
	for _, existing in ipairs(state.user_ids) do
		if existing ~= user_id then
			ids[#ids + 1] = existing
		end
	end
	return set_user_ids(self, ids)
end

local function get_metadata(self: Record): Metadata
	local state = private[self]
	if state == nil then
		return {}
	end
	return clone_metadata(state.metadata)
end

local function set_metadata(self: Record, metadata: Metadata): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	if type(metadata) ~= "table" then
		return "validation", "metadata must be a table"
	end
	local copied = clone_metadata(metadata)
	local valid, message = validate_metadata(copied)
	if not valid then
		return "validation", message
	end
	local old_metadata = state.metadata
	state.metadata = copied
	state.change_sequence += 1
	mark_dirty(state)
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_metadata, copied, operation_id, "metadata")
	state.save_requested = true
	state.next_autosave = now_local()
	sync_public(self)
	return "success", nil
end

local function update_metadata(self: Record, callback: (Metadata) -> Metadata): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	local working = clone_metadata(state.metadata)
	local next_metadata: Metadata? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, value = pcall(callback, working)
		if not ok then
			callback_error = tostring(value)
			return
		end
		next_metadata = value
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return "invalid", "metadata update callback must not yield"
	end
	if not resumed then
		return "invalid", "metadata update callback execution failed"
	end
	if callback_error ~= nil then
		return "invalid", "metadata update callback threw: " .. callback_error
	end
	if next_metadata == nil or type(next_metadata) ~= "table" then
		return "validation", "metadata update callback must return a table"
	end
	local copied = clone_metadata(next_metadata)
	local valid, message = validate_metadata(copied)
	if not valid then
		return "validation", message
	end
	local old_metadata = state.metadata
	state.metadata = copied
	state.change_sequence += 1
	mark_dirty(state)
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_metadata, copied, operation_id, "metadata")
	state.save_requested = true
	state.next_autosave = now_local()
	sync_public(self)
	return "success", nil
end

local function touch(self: Record): (ResultCode, string?)
	local state = private[self]
	if state == nil or state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	state.save_requested = true
	state.next_autosave = now_local()
	state.last_observed = now_unix()
	observe(state, "touch", "success", nil)
	sync_public(self)
	return "success", nil
end

local function update(self: Record, callback: (JsonValue?) -> JsonValue?): (ResultCode, string?)
	local state = private[self]
	if state ~= nil then
		track_external_data_mutation(state)
	end
	if state == nil or state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	if type(callback) ~= "function" then
		return "invalid", "update callback must be a function"
	end
	local old_data = state.data
	local working = copy_value(state.data)
	local next_value: JsonValue? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, value = pcall(callback, working)
		if not ok then
			callback_error = tostring(value)
			return
		end
		next_value = value
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return "invalid", "update callback must not yield"
	end
	if not resumed then
		return "invalid", "update callback execution failed"
	end
	if callback_error ~= nil then
		return "invalid", "update callback threw: " .. callback_error
	end
	if next_value == nil then
		return "validation", "update callback returned nil"
	end
	local copy_ok, copied_or_error = pcall(function()
		return copy_value(next_value)
	end)
	if not copy_ok or copied_or_error == nil then
		return "validation", "update callback returned invalid data"
	end
	local copied = copied_or_error
	local valid, message = validate_value(copied, state.options.validator)
	if not valid then
		return "validation", message
	end
	local skip_sync_external_mutation_check = state.options.on_event == nil and next(state.change_observers) == nil
	state.data = copied
	state.public_data_source = copy_value(state.data)
	self.Data = state.data
	state.change_sequence += 1
	mark_dirty(state)
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_data, copied, operation_id, "update")
	state.save_requested = true
	state.next_autosave = now_local()
	state.last_observed = now_unix()
	observe(state, "update", "success", nil)
	sync_public(self, skip_sync_external_mutation_check)
	return "success", nil
end

local function reconcile(self: Record, template: JsonValue): (ResultCode, string?)
	local state = private[self]
	if state ~= nil then
		track_external_data_mutation(state)
	end
	if state == nil or state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record is already saving"
	end
	local old_data = state.data
	local copied = copy_value(state.data)
	if copied == nil then
		return "validation", "record data is missing"
	end
	local template_ok, template_or_error = pcall(function()
		return copy_value(template)
	end)
	if not template_ok or template_or_error == nil then
		return "validation", "template is invalid"
	end
	local template_copy = template_or_error
	local function set_table_child(
		target: JsonValue,
		key: string | number,
		value: JsonValue
	): (JsonValue, boolean)
		if type(target) ~= "table" then return target, false end
		local target_table: any = target
		if type(key) == "string" then
			for child_key in target_table do
				if type(child_key) ~= "string" then return target, false end
			end
			target_table[key] = value
			return target, true
		end
		for child_key in target_table do
			if type(child_key) ~= "number" or not math.isfinite(child_key)
				or math.floor(child_key) ~= child_key or child_key < 1 then
				return target, false
			end
		end
		target_table[key] = value
		return target, true
	end

	local function reconcile_value(target: JsonValue, target_template: JsonValue): (JsonValue, boolean)
		if type(target) ~= "table" or type(target_template) ~= "table" then return target, false end
		local result: any = target
		local template_table: any = target_template
		local changed = false
		for key, template_child in template_table do
			if type(key) ~= "string" and type(key) ~= "number" then return target, false end
			local current = result[key]
			if current == nil then
				local updated, updated_ok = set_table_child(result, key, template_child)
				if updated_ok then result = updated; changed = true end
			elseif type(current) == "table" and type(template_child) == "table" then
				local _, nested_changed = reconcile_value(current, template_child)
				if nested_changed then changed = true end
			end
		end
		return result :: JsonValue, changed
	end
	local next_value, changed = reconcile_value(copied, template_copy)
	if next_value == nil then
		return "validation", "reconciliation returned nil"
	end
	local valid, message = validate_value(next_value, state.options.validator)
	if not valid then
		return "validation", message
	end
	local skip_sync_external_mutation_check = state.options.on_event == nil and next(state.change_observers) == nil
	state.data = next_value
	state.public_data_source = copy_value(state.data)
	self.Data = state.data
	if changed == true then
		state.change_sequence += 1
	mark_dirty(state)
		local operation_id = HttpService:GenerateGUID(false)
		state.current_operation_id = operation_id
		enqueue_change_observation(state, old_data, next_value, operation_id, "reconcile")
		state.save_requested = true
		state.next_autosave = now_local()
	end
	observe(state, "reconcile", "success", nil)
	sync_public(self, skip_sync_external_mutation_check)
	return "success", nil
end

local function message(self: Record, message_type: string, data: JsonValue?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if not messaging_enabled(state) then
		return "invalid", "messaging is disabled"
	end
	if type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH then
		return "invalid", "message_type must be 1 to 100 characters"
	end
	if data ~= nil then
		local valid, validation_message = validate_serialized_size(data)
		if not valid then
			return "validation", validation_message
		end
	end
	local ok, message_error = publish_record_message(state, "message", message_type, data, nil, nil, nil)
	if not ok then
		observe(state, "message_publish", "unknown", message_error)
		return "unknown", message_error
	end
	observe(state, "message_publish", "success", message_type)
	return "success", nil
end

local function mailbox_bound_for_state(state: InternalState): (EmbeddedMailbox?, ResultCode?, string?)
	local mailbox = state.mailbox_v2
	if mailbox == nil then return nil, nil, nil end
	if type(mailbox) ~= "table" or type(mailbox.GetOwner) ~= "function"
		or type(mailbox.GetActiveRecord) ~= "function" or type(mailbox.EnqueueAsync) ~= "function"
		or type(mailbox.ProcessNextAsync) ~= "function"
	then
		return nil, "fenced", "bound V2 mailbox no longer exposes its required API"
	end
	local owner_ok, owner = pcall(function() return mailbox:GetOwner() end)
	if not owner_ok or type(owner) ~= "table" then return nil, "fenced", "bound V2 mailbox owner could not be verified" end
	if owner.store_name ~= state.name or owner.scope ~= state.scope or owner.profile_key ~= state.key then
		return nil, "fenced", "bound V2 mailbox identity changed after binding"
	end
	if #state.user_ids > 0 and owner.user_id == nil then return nil, "fenced", "bound mailbox lost the UserId required by this Record" end
	if owner.user_id ~= nil then
		if type(owner.user_id) ~= "number" or not math.isfinite(owner.user_id) or math.floor(owner.user_id) ~= owner.user_id then
			return nil, "fenced", "bound V2 mailbox UserId is invalid"
		end
		local found = false
		for _, user_id in ipairs(state.user_ids) do if user_id == owner.user_id then found = true; break end end
		if not found then return nil, "fenced", "bound V2 mailbox UserId no longer matches the active Record" end
	end
	local active_ok, active_record = pcall(function() return mailbox:GetActiveRecord() end)
	if not active_ok or active_record ~= state.public_record then
		return nil, "fenced", "bound V2 mailbox is not attached to this exact Record instance"
	end
	return mailbox, nil, nil
end

local function map_mailbox_v2_result(code: unknown): ResultCode
	if code == "success" then return "success" end
	if code == "accepted" then return "enqueued" end
	if code == "processed" or code == "dead_lettered" then return "processed" end
	if code == "duplicate" then return "duplicate" end
	if code == "capacity" then return "capacity" end
	if code == "empty" then return "empty" end
	if code == "busy" or code == "preparing" or code == "ordered" or code == "retry_scheduled" then return "busy" end
	if code == "closing" then return "closing" end
	if code == "fenced" or code == "lease_lost" then return "fenced" end
	if code == "conflict" then return "conflict" end
	if code == "corrupt" then return "corrupt" end
	if code == "invalid" then return "invalid" end
	if code == "not_found" then return "not_found" end
	if code == "retryable" then return "budget" end
	if code == "expired" or code == "discarded" then return "success" end
	return "unknown"
end

local install_mailbox_renewal_scheduler: (Record, InternalState, EmbeddedMailbox) -> (boolean, string?)
local process_queue_v2: any
local scheduler_enabled = false

local function mailbox_store_adapter(self: Record): (any?, ResultCode, string?)
	local state = private[self]
	if state == nil then return nil, "invalid", "record does not exist" end
	if state.state ~= "active" then return nil, "fenced", "mailbox adapter requires an active Record" end
	if state.takeover_requested then return nil, "closing", "session takeover has been requested" end
	local store_name = state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME
	local real_store: any = nil
	if not state.backend.mock then
		local store_ok, store_value = pcall(function()
			return DataStoreService:GetDataStore(store_name, state.scope)
		end)
		if not store_ok or store_value == nil then
			return nil, "unknown", "could not create the V2 mailbox DataStore adapter: " .. tostring(store_value)
		end
		real_store = store_value
	end
	local adapter: any = {}
	local function check_key(key: unknown)
		if type(key) ~= "string" or key == "" or #key > 50 then
			error("V2 mailbox DataStore key must be 1 to 50 bytes", 3)
		end
		if state.retired or state.state ~= "active" or state.takeover_requested then
			error("V2 mailbox operation requires the same active, non-takeover Record session", 3)
		end
	end
	function adapter:GetAsync(key: string): unknown
		check_key(key)
		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then error(deadline_error or "invalid operation deadline", 2) end
		if state.backend.mock then
			local entry = get_mock_store(store_name, state.scope)[key]
			return if entry ~= nil then copy_value(entry.Value) else nil
		end
		if not acquire_request(state, deadline, false, Enum.DataStoreRequestType.StandardRead) then
			error("V2 mailbox read request deadline exceeded", 2)
		end
		local call_ok, value = pcall(function() return real_store:GetAsync(key) end)
		release_slot()
		if not call_ok then error(tostring(value), 2) end
		return value
	end
	function adapter:GetAsyncFresh(key: string): unknown
		check_key(key)
		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then error(deadline_error or "invalid operation deadline", 2) end
		if state.backend.mock then
			local entry = get_mock_store(store_name, state.scope)[key]
			return if entry ~= nil then copy_value(entry.Value) else nil
		end
		if not acquire_request(state, deadline, false, Enum.DataStoreRequestType.StandardRead) then
			error("V2 mailbox authoritative read request deadline exceeded", 2)
		end
		local get_options = Instance.new("DataStoreGetOptions")
		get_options.UseCache = false
		local call_ok, value = pcall(function() return real_store:GetAsync(key, get_options) end)
		release_slot()
		if not call_ok then error(tostring(value), 2) end
		return value
	end
	function adapter:UpdateAsync(
		key: string,
		transform: (unknown, unknown?) -> (unknown, { number }?, { [string]: unknown }?)
	): unknown
		check_key(key)
		if type(transform) ~= "function" then error("V2 mailbox UpdateAsync transform must be a function", 2) end
		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then error(deadline_error or "invalid operation deadline", 2) end
		if state.backend.mock then
			if mock_update_failure_count > 0 then
				mock_update_failure_count -= 1
				error(mock_update_failure_message, 2)
			end
			local store = get_mock_store(store_name, state.scope)
			local entry = store[key]
			local raw = if entry ~= nil then copy_value(entry.Value) else nil
			local info: any = if entry ~= nil then {
				Version = entry.Version,
				CreatedTime = entry.CreatedTime,
				UpdatedTime = entry.UpdatedTime,
				UserIds = clone_user_ids(entry.UserIds),
				Metadata = clone_metadata(entry.Metadata),
				RawMetadata = clone_metadata(entry.Metadata),
				GetUserIds = function()
					return clone_user_ids(entry.UserIds)
				end,
				GetMetadata = function()
					return clone_metadata(entry.Metadata)
				end,
			} else nil
			local replay_count = mock_update_replay_retries
			local replay_advance = mock_update_replay_advance_seconds
			mock_update_replay_retries = 0
			mock_update_replay_advance_seconds = 0
			local next_value: unknown = nil
			local user_ids: { number }? = nil
			local metadata: { [string]: unknown }? = nil
			for _ = 0, replay_count do
				local transform_ok, value, ids, meta = pcall(transform, raw, info)
				if not transform_ok then error(tostring(value), 2) end
				next_value, user_ids, metadata = value, ids, meta
				mock_test_clock_offset += replay_advance
			end
			if next_value == nil then return copy_value(raw :: JsonValue?) end
			local normalized_ids, ids_error = normalize_user_ids(user_ids or (if entry ~= nil then entry.UserIds else {}))
			if normalized_ids == nil then error(ids_error, 2) end
			local normalized_metadata: Metadata = if metadata == nil
				then (if entry ~= nil then clone_metadata(entry.Metadata) else {})
				else metadata :: Metadata
			local metadata_ok, metadata_error = validate_metadata(normalized_metadata, true)
			if not metadata_ok then error(metadata_error, 2) end
			if type(next_value) ~= "table" and type(next_value) ~= "string"
				and type(next_value) ~= "number" and type(next_value) ~= "boolean"
			then
				error("V2 mailbox attempted to store a non-JSON value", 2)
			end
			local size_ok, size_error = validate_serialized_size(next_value :: JsonValue)
			if not size_ok then error(size_error, 2) end
			local written = mock_write_version(entry, copy_value(next_value :: JsonValue), normalized_ids, normalized_metadata, false)
			store[key] = written
			return copy_value(written.Value :: JsonValue?)
		end
		if not acquire_request(state, deadline, true, nil) then
			error("V2 mailbox update request deadline exceeded", 2)
		end
		local call_ok, value = pcall(function()
			return real_store:UpdateAsync(key, function(raw: unknown, key_info: any)
				local next_value, user_ids, metadata = transform(raw, key_info)
				if next_value == nil then return nil end
				if key_info ~= nil then
					if user_ids == nil then user_ids = key_info:GetUserIds() end
					if metadata == nil then metadata = key_info:GetMetadata() end
				end
				return next_value :: any, user_ids, metadata
			end)
		end)
		release_slot()
		if not call_ok then error(tostring(value), 2) end
		return value
	end
	return adapter, "success", nil
end

local function get_identity(self: Record): { [string]: unknown }
	local state = private[self]
	if state == nil then return {} end
	return {
		store_name = state.name,
		scope = state.scope,
		profile_key = state.key,
		user_ids = clone_user_ids(state.user_ids),
	}
end

local function get_mailbox_owner(self: Record): { [string]: unknown }
	local state = private[self]
	if state == nil then return {} end
	local owner: { [string]: unknown } = {
		store_name = state.name,
		scope = state.scope,
		profile_key = state.key,
	}
	if #state.user_ids > 0 then owner.user_id = state.user_ids[1] end
	return owner
end

local function enqueue(self: Record, message_type: string, data: JsonValue?, enqueue_options: { [string]: unknown }?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.mailbox_v2_binding then return "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.state ~= "active" then return "fenced", "record is not actively owned" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = mailbox_bound_for_state(state)
		if mailbox == nil then return normalize_result_code(bound_code) or "fenced", bound_message end
		local call_ok, result = pcall(function() return mailbox:EnqueueAsync(message_type, data, enqueue_options) end)
		if not call_ok or type(result) ~= "table" or type(result.code) ~= "string" then
			return "unknown", if call_ok then "V2 mailbox returned no structured enqueue result" else tostring(result)
		end
		local result_table: any = result
		if result_table.code == "accepted" then observe(state, "v2_enqueue", "success", message_type); return "enqueued", nil end
		if result_table.code == "duplicate" then observe(state, "v2_enqueue", "duplicate", message_type); return "duplicate", nil end
		local message = if type(result_table.error) == "string" then result_table.error else "V2 mailbox enqueue returned " .. result_table.code
		return map_mailbox_v2_result(result_table.code), message
	end
	if enqueue_options ~= nil then return "invalid", "enqueue_options require a bound V2 mailbox" end
	return enqueue_internal(state, message_type, data)
end

local function process_queue(self: Record, max_messages: number?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.mailbox_v2_binding then return "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 == nil then return process_queue_internal(state, max_messages or 1) end
	return process_queue_v2(self, state, max_messages or 1)
end

local function get_queue(self: Record): ({ QueueMessage }, ResultCode, string?)
	local state = private[self]
	if state == nil then return {}, "invalid", "record does not exist" end
	if state.mailbox_v2_binding and state.mailbox_v2 ~= nil then return {}, "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = mailbox_bound_for_state(state)
		if mailbox == nil then return {}, normalize_result_code(bound_code) or "fenced", bound_message end
		local call_ok, rows, result = pcall(function() return mailbox:GetQueueAsync() end)
		if not call_ok or type(rows) ~= "table" or type(result) ~= "table" or type(result.code) ~= "string" then
			return {}, "unknown", if call_ok then "V2 mailbox returned no structured queue result" else tostring(rows)
		end
		if result.code ~= "success" then
			local message = if type(result.error) == "string" then result.error else "V2 queue read returned " .. result.code
			return {}, map_mailbox_v2_result(result.code), message
		end
		local projected: { QueueMessage } = {}
		for _, row in ipairs(rows) do
			if type(row) ~= "table" or type(row.Id) ~= "string" or type(row.Type) ~= "string"
				or type(row.Attempts) ~= "number" or type(row.TotalAttempts) ~= "number"
				or type(row.ReplayCount) ~= "number" or type(row.CreatedAt) ~= "number"
			then return {}, "corrupt", "V2 queue contained a malformed message snapshot" end
			projected[#projected + 1] = {
				Id = row.Id, Type = row.Type, Data = copy_value(row.Data :: JsonValue?),
				Attempts = row.Attempts, TotalAttempts = row.TotalAttempts, ReplayCount = row.ReplayCount,
				SenderJobId = if type(row.SenderJobId) == "string" then row.SenderJobId else "",
				CreatedAt = row.CreatedAt,
				Priority = if type(row.Priority) == "string" then row.Priority else "normal",
				OrderingKey = if type(row.OrderingKey) == "string" then row.OrderingKey else nil,
				OrderingSequence = if type(row.OrderingSequence) == "number" then row.OrderingSequence else nil,
				AvailableAt = if type(row.AvailableAt) == "number" then row.AvailableAt else nil,
				ExpiresAt = if type(row.ExpiresAt) == "number" then row.ExpiresAt else nil,
			}
		end
		return projected, "success", nil
	end
	if state.options.durable_queue_enabled == false then
		return {}, "success", nil
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return {}, "invalid", "durable queue is disabled"
	end
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then
		return {}, "invalid", deadline_error
	end
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return {}, normalize_result_code(migration_code) or "unknown", migration_message
	end
	local raw, _, result_code, result_message = backend_get(backend, false, deadline)
	if result_code ~= nil then
		return {}, normalize_result_code(result_code) or "unknown", result_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local queue, parse_error, owner_mismatch = parse_queue_envelope(raw, owner)
	if queue == nil then
		return {}, if owner_mismatch then "conflict" else "corrupt", parse_error or "durable queue is corrupt"
	end
	local result: { QueueMessage } = {}
	for _, item in ipairs(queue.messages) do
		result[#result + 1] = queue_item_to_public(item)
	end
	return result, "success", nil
end

process_queue_v2 = function(self: Record, state: InternalState, max_messages: number): (ResultCode, string?)
	if state.state ~= "active" then return "fenced", "record is not actively owned" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if not scheduler_enabled then return "disabled", "V2 mailbox processing requires the advanced scheduler for claim renewal" end
	if state.queue_busy or state.busy then return "busy", "record already has a durable operation in flight" end
	if type(max_messages) ~= "number" or not math.isfinite(max_messages) or max_messages < 1 or math.floor(max_messages) ~= max_messages then
		return "invalid", "max_messages must be a positive integer"
	end
	local mailbox, bound_code, bound_message = mailbox_bound_for_state(state)
	if mailbox == nil then return normalize_result_code(bound_code) or "fenced", bound_message end
	if state.options.on_queue_message_async == nil and state.options.on_queue_message == nil then
		return "invalid", "on_queue_message_async or on_queue_message must be configured before processing a V2 mailbox"
	end
	if type(install_mailbox_renewal_scheduler) ~= "function" then
		return "invalid", "internal mailbox renewal scheduler is not initialized"
	end
	local configured, configure_error = install_mailbox_renewal_scheduler(self, state, mailbox)
	if not configured then return "invalid", configure_error or "failed to install V2 mailbox lease-renewal scheduling" end
	local limit = math.min(math.floor(max_messages), state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES)
	state.queue_busy = true
	local call_ok, final_code, final_message = pcall(function()
		local processed = 0
		for _ = 1, limit do
			local result = mailbox:ProcessNextAsync(function(payload: unknown, message_value: any, context: unknown)
				if type(message_value) ~= "table" or type(message_value.Type) ~= "string"
					or type(message_value.Id) ~= "string" or type(message_value.Attempts) ~= "number"
					or type(message_value.CreatedAt) ~= "number"
				then
					return false, "V2 mailbox returned a malformed message snapshot"
				end
				if state.options.on_queue_message_async ~= nil then
					local accepted, message = state.options.on_queue_message_async(
					message_value.Type, payload :: JsonValue?, message_value.Attempts, message_value.Id,
					if type(message_value.SenderJobId) == "string" then message_value.SenderJobId else "",
					message_value.CreatedAt, context
				)
				return accepted, message or (if accepted then "" else "queue handler rejected the message")
				end
				local handler = state.options.on_queue_message
				if handler == nil then return false, "on_queue_message is not configured" end
				local accepted, message = handler(
					message_value.Type, payload :: JsonValue?, message_value.Attempts, message_value.Id,
					if type(message_value.SenderJobId) == "string" then message_value.SenderJobId else "",
					message_value.CreatedAt
				)
				return accepted, message or (if accepted then "" else "queue handler rejected the message")
			end)
			if type(result) ~= "table" or type(result.code) ~= "string" then
				return "unknown" :: ResultCode, "V2 mailbox returned no structured processing result"
			end
			if result.code == "empty" then break end
			if result.code == "processed" or result.code == "duplicate" or result.code == "dead_lettered" then
				processed += 1
				continue
			end
			if result.code == "retry_scheduled" then
				return "budget" :: ResultCode, if type(result.error) == "string" then result.error else "V2 handler failed and retry was scheduled"
			end
			if result.code == "expired" or result.code == "ordered" then continue end
			return map_mailbox_v2_result(result.code), if type(result.error) == "string" then result.error else "V2 mailbox processing returned " .. result.code
		end
		if processed == 0 then return "empty" :: ResultCode, "" end
		return "processed" :: ResultCode, tostring(processed)
	end)
	state.queue_busy = false
	if not call_ok then return "unknown", tostring(final_code) end
	sync_public(self)
	return final_code :: ResultCode, final_message
end

local function bind_mailbox_v2_async(self: Record, mailbox: unknown): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.state ~= "active" then return "fenced", "V2 mailbox binding requires an active Record" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if state.mailbox_v2 ~= nil then
		if (state.mailbox_v2 :: unknown) == mailbox then return "success", nil end
		return "conflict", "this Record is already bound to a different V2 mailbox"
	end
	if state.queue_busy or state.busy or state.mailbox_v2_binding then
		return "busy", "Record has another operation in flight; V2 mailbox binding was not attempted"
	end
	if state.options.durable_queue_enabled == false then
		return "invalid", "safe V2 binding requires the legacy queue to be enabled so pending messages can be checked"
	end
	if type(mailbox) ~= "table" then
		return "invalid", "mailbox must expose the V2 owner, enqueue, processing and lease-renewal APIs"
	end
	local mailbox_api = mailbox :: { [string]: unknown }
	if type(mailbox_api.GetOwner) ~= "function"
		or type(mailbox_api.GetActiveRecord) ~= "function" or type(mailbox_api.EnqueueAsync) ~= "function"
		or type(mailbox_api.ProcessNextAsync) ~= "function" or type(mailbox_api.SetLeaseRenewalScheduler) ~= "function"
	then
		return "invalid", "mailbox must expose the V2 owner, enqueue, processing and lease-renewal APIs"
	end
	local mailbox_instance = (mailbox_api :: unknown) :: EmbeddedMailbox
	local owner_ok, owner = pcall(function() return mailbox_instance:GetOwner() end)
	local active_ok, active_record = pcall(function() return mailbox_instance:GetActiveRecord() end)
	if not owner_ok or type(owner) ~= "table" then return "invalid", "V2 mailbox owner identity could not be read" end
	if not active_ok or active_record ~= self then
		return "conflict", "V2 mailbox must be bound to this exact active Record instance"
	end
	if owner.store_name ~= state.name or owner.scope ~= state.scope or owner.profile_key ~= state.key then
		return "conflict", "V2 mailbox owner does not match this Record identity"
	end
	if #state.user_ids > 0 and owner.user_id == nil then
		return "invalid", "V2 mailbox owner must include a UserId for a UserId-associated Record"
	end
	if owner.user_id ~= nil then
		if type(owner.user_id) ~= "number" or not math.isfinite(owner.user_id) or owner.user_id < 1
			or math.floor(owner.user_id) ~= owner.user_id
		then return "invalid", "V2 mailbox owner UserId must be a positive integer" end
		local found = false
		for _, user_id in ipairs(state.user_ids) do if user_id == owner.user_id then found = true; break end end
		if not found then return "fenced", "V2 mailbox UserId does not match persisted Record UserIds" end
	end
	state.mailbox_v2_binding = true
	state.queue_busy = true
	local inspect_ok, legacy_queue, queue_code, queue_message = pcall(get_queue, self)
	state.queue_busy = false
	if not inspect_ok then state.mailbox_v2_binding = false; return "unknown", "could not inspect the legacy queue: " .. tostring(legacy_queue) end
	if queue_code ~= "success" then state.mailbox_v2_binding = false; return normalize_result_code(queue_code) or "unknown", queue_message or "could not verify the legacy queue" end
	if type(legacy_queue) ~= "table" or #legacy_queue > 0 then
		state.mailbox_v2_binding = false
		return "busy", "legacy queue contains pending messages; drain it before binding the V2 mailbox"
	end
	state.mailbox_v2 = mailbox_instance
	state.mailbox_v2_binding = false
	local configured, configure_error = install_mailbox_renewal_scheduler(self, state, mailbox_instance)
	if not configured then
		state.mailbox_v2 = nil
		return "invalid", configure_error or "failed to install V2 mailbox lease-renewal scheduling"
	end
	return "success", nil
end

local function get_dead_letters(self: Record): ({ DeadLetterMessage }, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return {}, "invalid", "record does not exist"
	end
	if state.options.durable_queue_enabled == false then
		return {}, "success", nil
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return {}, "invalid", "durable queue is disabled"
	end
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then
		return {}, "invalid", deadline_error
	end
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return {}, normalize_result_code(migration_code) or "unknown", migration_message
	end
	local raw, _, result_code, result_message = backend_get(backend, false, deadline, state)
	if result_code ~= nil then
		return {}, normalize_result_code(result_code) or "unknown", result_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local queue, parse_error, owner_mismatch = parse_queue_envelope(raw, owner)
	if queue == nil then
		return {}, if owner_mismatch then "conflict" else "corrupt", parse_error or "durable queue is corrupt"
	end
	local result: { DeadLetterMessage } = {}
	for _, item in ipairs(queue.dead_letters) do
		result[#result + 1] = dead_letter_to_public(item)
	end
	return result, "success", nil
end

local function claim_dead_letter(self: Record, message_id: string): (DeadLetterMessage?, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return nil, "invalid", "record does not exist"
	end
	if type(message_id) ~= "string" or message_id == "" or #message_id > 100 then
		return nil, "invalid", "message_id must be a non-empty string of at most 100 characters"
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return nil, "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return nil, normalize_result_code(migration_code) or "unknown", migration_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local token = HttpService:GenerateGUID(false)
	local lease_duration = state.options.queue_lease_duration or DEFAULT_QUEUE_LEASE_DURATION
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = "corrupt"
			decision_message = "durable queue is corrupt or owned by another record"
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_dead_letters = table.clone(queue.dead_letters)
		for index, item in ipairs(queue.dead_letters) do
			if item.id == message_id then
				if item.lock_token == token and item.locked_until > transform_time then
					decision = "success"
					return nil, nil, nil
				end
				if item.locked_until > transform_time then
					decision = "busy"
					decision_message = "dead letter is already claimed by another worker"
					return nil, nil, nil
				end
				local next_item: DeadLetterItem = {
					id = item.id,
					type = item.type,
					data = copy_value(item.data),
					attempts = item.attempts,
					total_attempts = item.total_attempts,
					replay_count = item.replay_count,
					last_replay_token = item.last_replay_token,
					sender_job_id = item.sender_job_id,
					created_at = item.created_at,
					locked_until = transform_time + lease_duration,
					lock_token = token,
					dead_lettered_at = item.dead_lettered_at,
					last_error = item.last_error,
					terminal_lock_token = item.terminal_lock_token,
				}
				next_dead_letters[index] = next_item
				local next_queue = make_queue_envelope(owner, queue.messages, next_dead_letters)
				local size_error = queue_size_error(next_queue, max_bytes)
				if size_error ~= nil then
					decision = "validation"
					decision_message = size_error
					return nil, nil, nil
				end
				decision = "success"
				return next_queue, nil, nil
			end
		end
		decision = "conflict"
		decision_message = "dead letter was not found"
		return nil, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return nil, normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return nil, normalize_result_code(verify_code) or "unknown", verify_message
	end
	local verification_time = queue_now_unix(backend.mock)
	for _, item in ipairs(queue.dead_letters) do
		if item.id == message_id and item.lock_token == token and item.locked_until > verification_time then
			return dead_letter_to_public(item), "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return nil, decision, decision_message or result_message
	end
	return nil, "conflict", "dead-letter claim expired or could not be verified"
end

local function replay_dead_letter(self: Record, message_id: string, lock_token: string): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(message_id) ~= "string" or message_id == "" or #message_id > 100 or type(lock_token) ~= "string" or lock_token == "" then
		return "invalid", "message_id and lock_token must be non-empty strings"
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(state.name, state.scope, state.key, state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME, state.backend.mock, deadline, state)
	if migration_code ~= nil then
		return normalize_result_code(migration_code) or "unknown", migration_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local max_messages = state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = "corrupt"
			decision_message = "durable queue is corrupt or owned by another record"
			return nil, nil, nil
		end
		for _, item in ipairs(queue.messages) do
			if item.id == message_id and item.last_replay_token == lock_token then
				decision = "success"
				return nil, nil, nil
			end
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_dead_letters: { DeadLetterItem } = {}
		local replayed: DeadLetterItem? = nil
		for _, item in ipairs(queue.dead_letters) do
			if item.id == message_id then
				if item.lock_token ~= lock_token or item.locked_until <= transform_time then
					decision = "conflict"
					decision_message = "dead-letter lock token is stale or expired"
					return nil, nil, nil
				end
				replayed = item
			else
				next_dead_letters[#next_dead_letters + 1] = item
			end
		end
		if replayed == nil then
			decision = "conflict"
			decision_message = "dead letter was not found"
			return nil, nil, nil
		end
		if #queue.messages >= max_messages then
			decision = "validation"
			decision_message = "active durable queue is full; dead letter was preserved"
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		next_messages[#next_messages + 1] = {
			id = replayed.id,
			type = replayed.type,
			data = copy_value(replayed.data),
			attempts = 0,
			total_attempts = replayed.total_attempts,
			replay_count = replayed.replay_count + 1,
			last_replay_token = lock_token,
			sender_job_id = replayed.sender_job_id,
			created_at = replayed.created_at,
			locked_until = 0,
			lock_token = nil,
		}
		local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			decision = "validation"
			decision_message = "dead-letter replay was not applied: " .. size_error
			return nil, nil, nil
		end
		decision = "success"
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return normalize_result_code(verify_code) or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id and item.last_replay_token == lock_token then
			return "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return decision, decision_message or result_message
	end
	return "conflict", "dead-letter replay could not be verified"
end

local function discard_dead_letter(self: Record, message_id: string, lock_token: string): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(message_id) ~= "string" or message_id == "" or #message_id > 100 or type(lock_token) ~= "string" or lock_token == "" then
		return "invalid", "message_id and lock_token must be non-empty strings"
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(state.name, state.scope, state.key, state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME, state.backend.mock, deadline, state)
	if migration_code ~= nil then
		return normalize_result_code(migration_code) or "unknown", migration_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = "corrupt"
			decision_message = "durable queue is corrupt or owned by another record"
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_dead_letters: { DeadLetterItem } = {}
		local found = false
		for _, item in ipairs(queue.dead_letters) do
			if item.id == message_id then
				if item.lock_token ~= lock_token or item.locked_until <= transform_time then
					decision = "conflict"
					decision_message = "dead-letter lock token is stale or expired"
					return nil, nil, nil
				end
				found = true
			else
				next_dead_letters[#next_dead_letters + 1] = item
			end
		end
		if not found then
			decision = "conflict"
			decision_message = "dead letter was not found"
			return nil, nil, nil
		end
		local next_queue = make_queue_envelope(owner, queue.messages, next_dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			decision = "validation"
			decision_message = size_error
			return nil, nil, nil
		end
		decision = "success"
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return normalize_result_code(verify_code) or "unknown", verify_message
	end
	for _, item in ipairs(queue.dead_letters) do
		if item.id == message_id then
			if decision ~= nil and decision ~= "success" then
				return decision, decision_message or result_message
			end
			return "conflict", "dead letter remains after discard verification"
		end
	end
	return "success", nil
end

local function close_record(self: Record): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = close_internal(state, false)
	sync_public(self)
	return normalize_result_code(result) or "unknown", message
end

local function delete_record(self: Record): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.retired then
		return "invalid", "record has been retired"
	end
	if closing then
		return "closing", "server is shutting down"
	end
	if state.state ~= "active" then
		return if state.state == "tombstoned" then "tombstoned" else "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		return "busy", "record has a durable operation in flight"
	end
	if state.queue_busy then
		return "busy", "durable queue is being processed"
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local generation = state.generation
	local next_generation = generation + 1
	local target_revision = state.revision + 1
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "releasing"
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	local last_error: string? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			return "closing", "record was retired"
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id
				and envelope.session == nil
				and envelope.tombstone ~= nil
				and envelope.tombstone.generation == next_generation
				and envelope.fencing_generation == next_generation
				and envelope.revision == target_revision
			then
				decision = "success"
				return envelope, envelope.user_ids, (if info ~= nil then info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.session == nil or envelope.session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			if envelope.revision ~= state.revision then
				decision = "conflict"
				decision_message = "durable revision changed unexpectedly"
				return nil, nil, nil
			end
			local next_envelope: Envelope = {
				implementation_version = envelope.implementation_version,
				schema_version = state.options.schema_version,
				revision = target_revision,
				sidecars = prepared_envelope_cache._sidecar_protocol.clone(envelope.sidecars),
				fencing_generation = next_generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = nil,
				user_ids = clone_user_ids(state.user_ids),
				tombstone = {
					deleted_at = transform_time,
					generation = next_generation,
				},
				session = nil,
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			return next_envelope, state.user_ids, make_backend_metadata(state.metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = normalize_result_code(result_code)
			decision_message = result_message
		end
		if state.retired or (state.state :: SessionState) ~= "releasing" then
			state.busy = false
			return "closing", "delete was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and returned.session == nil and returned.tombstone ~= nil and returned.fencing_generation == next_generation and returned.revision == target_revision and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "conflict" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "delete", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			return "validation", decision_message
		end
		last_error = result_message or "delete response did not confirm the requested delete"
		local verified, envelope, info_after = verify_release_write(state, write_id, next_generation, target_revision, true, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		state.busy = false
		state.state = "unknown"
		observe(state, "delete", "unknown", last_error or "delete outcome is unresolved")
		return "unknown", last_error or "delete outcome is unresolved"
	end
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "delete")
	state.saved_change_sequence = state.change_sequence
	state.data = nil
	state.public_data_source = nil
	state.token = nil
	state.durable_lease_until = 0
	state.generation = confirmed.fencing_generation
	state.revision = confirmed.revision
	state.created_at = confirmed.created_at
	state.updated_at = confirmed.updated_at
	update_state_metadata_from_info(state, confirmed_info)
	state.tombstoned = true
	state.busy = false
	state.state = "tombstoned"
	state.next_autosave = math.huge
	state.next_renewal = math.huge
	state.takeover_requested = false
	state.queue_hint = false
	disconnect_message_subscription(state)
	observe(state, "delete", "deleted", nil)
	sync_public(self)
	return "deleted", nil
end

verify_snapshot_write = function(state: InternalState, write_id: string, token: string, generation: number, revision: number, operation_deadline: number): (boolean, Envelope?, BackendInfo?)
	local deadline = math.min(operation_deadline, now_local() + 5)
	local raw, info, result_code = backend_get(state.backend, false, deadline, state)
	if result_code ~= nil then
		return false, nil, nil
	end
	local envelope = parse_envelope(raw)
	if envelope == nil then
		return false, nil, nil
	end
	if envelope.write_id ~= write_id or envelope.revision ~= revision or not matches_session(envelope, token, generation) or envelope.session == nil or envelope.session.lease_until <= session_now_unix(state.backend.mock) or not backend_metadata_matches(info, envelope) then
		return false, nil, nil
	end
	return true, envelope, info
end

verify_release_write = function(state: InternalState, write_id: string, generation: number, revision: number, tombstone: boolean, operation_deadline: number): (boolean, Envelope?, BackendInfo?)
	local deadline = math.min(operation_deadline, now_local() + 5)
	local raw, info, result_code = backend_get(state.backend, false, deadline, state)
	if result_code ~= nil then
		return false, nil, nil
	end
	local envelope = parse_envelope(raw)
	if envelope == nil or envelope.write_id ~= write_id or envelope.fencing_generation ~= generation or envelope.revision ~= revision or envelope.session ~= nil or not backend_metadata_matches(info, envelope) then
		return false, nil, nil
	end
	if tombstone and envelope.tombstone == nil then
		return false, nil, nil
	end
	if not tombstone and envelope.tombstone ~= nil then
		return false, nil, nil
	end
	return true, envelope, info
end

local function verify_open_write(state: InternalState, write_id: string, token: string, operation_deadline: number): (boolean, Envelope?, BackendInfo?)
	local deadline = math.min(operation_deadline, now_local() + 5)
	local raw, info, result_code = backend_get(state.backend, false, deadline, state)
	if result_code ~= nil then
		return false, nil, nil
	end
	local envelope = parse_envelope(raw)
	if envelope == nil or envelope.write_id ~= write_id or envelope.session == nil or envelope.session.token ~= token or envelope.session.generation ~= envelope.fencing_generation or envelope.session.lease_until <= session_now_unix(state.backend.mock) or not backend_metadata_matches(info, envelope) then
		return false, nil, nil
	end
	return true, envelope, info
end

local function open_internal(state: InternalState, default_data: JsonValue?, recreate: boolean?): (ResultCode, string?)
	local function recover_corrupt_history(
		state: InternalState,
		observed_version: string,
		corrupt_reason: string,
		deadline: number
	): (HistoryRecoveryCandidate?, ResultCode, string?)
		local remaining = math.max(0, deadline - now_local())
		if remaining <= 0 then
			return nil, "budget", "corruption recovery deadline expired before history scan"
		end
		local entries, list_result, list_message = list_versions_internal(
			state.name,
			state.scope,
			state.key,
			Enum.SortDirection.Descending,
			nil,
			nil,
			12,
			remaining,
			state.backend.mock
		)
		if list_result ~= "success" or entries == nil then
			return nil, normalize_result_code(list_result) or "unknown", list_message or "version history could not be read"
		end

		local current_index: number? = nil
		for index, entry in ipairs(entries) do
			if entry.Version == observed_version then
				current_index = index
				break
			end
		end
		if current_index == nil then
			return nil, "conflict", "current corrupt version was not present in version history; recovery was refused"
		end

		local last_rejection = "no earlier version was available"
		for index = current_index + 1, #entries do
			if now_local() >= deadline then
				return nil, "budget", "corruption recovery deadline expired while scanning history"
			end
			local entry = entries[index]
			if entry.IsDeleted then
				return nil, "tombstoned", "the newest historical version is deleted; automatic recovery was refused"
			end

			local remaining_for_read = math.max(0, deadline - now_local())
			if remaining_for_read <= 0 then
				return nil, "budget", "corruption recovery deadline expired before historical read"
			end
			local snapshot, read_result, read_message = get_version_internal(
				state.name,
				state.scope,
				state.key,
				entry.Version,
				remaining_for_read,
				state.options.legacy_decoder,
				state.backend.mock
			)
			if read_result == "future_schema" then
				return nil, "future_schema", read_message or "a historical version uses a newer schema"
			end
			if read_result == "budget" or read_result == "unknown" then
				return nil, read_result, read_message or "historical version read failed"
			end
			if snapshot == nil then
				last_rejection = read_message or "historical envelope failed validation"
				continue
			end
			if snapshot.Tombstoned then
				return nil, "tombstoned", "the newest valid historical version is deleted; automatic recovery was refused"
			end
			if snapshot.SessionActive then
				return nil, "locked", "the newest valid historical version still has a live owner lease"
			end
			if snapshot.Data == nil then
				last_rejection = "historical envelope has no player data"
				continue
			end

			local migrated, migration_error = apply_migrations(state, snapshot.SchemaVersion, snapshot.Data)
			if migrated == nil then
				if migration_error == "stored schema is newer than this server supports" then
					return nil, "future_schema", migration_error
				end
				last_rejection = migration_error or "historical schema migration failed"
				continue
			end
			local valid, validation_error = validate_value(migrated, state.options.validator)
			if not valid then
				last_rejection = validation_error or "historical player data failed validation"
				continue
			end

			local recovered_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = snapshot.Revision,
				fencing_generation = snapshot.Generation,
				created_at = snapshot.CreatedAt,
				updated_at = snapshot.UpdatedAt,
				data = migrated,
				user_ids = clone_user_ids(snapshot.UserIds),
				tombstone = nil,
				session = nil,
				sidecars = nil,
				write_id = "history-recovery-" .. HttpService:GenerateGUID(false),
			}
			local envelope_valid, envelope_error = validate_envelope(recovered_envelope)
			if not envelope_valid then
				last_rejection = envelope_error or "recovered historical envelope is invalid"
				continue
			end
			return {
				ObservedVersion = observed_version,
				SourceVersion = entry.Version,
				CorruptReason = corrupt_reason,
				Envelope = recovered_envelope,
				UserIds = clone_user_ids(snapshot.UserIds),
				Metadata = clone_metadata(snapshot.Metadata),
			}, "success", nil
		end
		return nil, "corrupt", "no safe historical version was found; current version was left untouched (current version: " .. corrupt_reason .. "; last historical rejection: " .. last_rejection .. ")"
	end
	if closing then
		return "closing", "server is shutting down"
	end
	if (state.state :: SessionState) == "active" then
		return "already_open", nil
	end
	if state.busy or state.state == "acquiring" or state.state == "releasing" then
		return "busy", "record has a durable operation in flight"
	end
	if recreate ~= nil and type(recreate) ~= "boolean" then
		return "invalid", "recreate must be a boolean"
	end
	if state.retired then
		return "invalid", "record has been retired"
	end
	local default_copy: JsonValue? = state.pending_open_default_data
	local copy_error: string? = nil
	if state.pending_open_token == nil then
		local copy_ok, copied_or_error = pcall(function()
			return copy_value(default_data)
		end)
		if copy_ok then
			default_copy = copied_or_error
		else
			copy_error = tostring(copied_or_error)
		end
		if not copy_ok then
			return "validation", copy_error or "default data is invalid"
		end
	end
	if default_copy ~= nil then
		local valid, message = validate_value(default_copy, state.options.validator)
		if not valid then
			return "validation", message
		end
	end
	local token = state.pending_open_token or HttpService:GenerateGUID(false)
	local write_id = state.pending_open_write_id or HttpService:GenerateGUID(false)
	state.pending_open_token = token
	state.pending_open_write_id = write_id
	state.pending_open_default_data = default_copy
	state.current_operation_id = write_id
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "acquiring"
	local last_error: string? = nil
	local last_result: ResultCode? = nil
	local final_decision: ResultCode? = nil
	local final_decision_message: string? = nil
	local recovery_candidate: HistoryRecoveryCandidate? = nil
	local recovery_checked = false
	local recovery_applied = false
	local created = false
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts + 1 do
		if attempt > attempts and recovery_candidate == nil then
			break
		end
		if state.retired then
			state.busy = false
			state.state = "closed"
			disconnect_message_subscription(state)
			return "closing", "record was retired"
		end
		if now_local() >= deadline then
			break
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local locked_generation: number? = nil
		local locked_job_id: string? = nil
		local locked_token: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, backend_info)
			decision = nil
			decision_message = nil
			locked_generation = nil
			locked_job_id = nil
			locked_token = nil
			created = false
			local commit_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			local recovering_history = false
			if raw ~= nil and not current_format and parse_error ~= "legacy payload" and parse_error ~= "future implementation version" and recovery_candidate ~= nil then
				if backend_info == nil or backend_info.Version ~= recovery_candidate.ObservedVersion then
					decision = "conflict"
					decision_message = "current version changed after corruption recovery was prepared"
					return nil, nil, nil
				end
				envelope = recovery_candidate.Envelope
				current_format = true
				recovering_history = true
				recovery_applied = true
			end
			if raw == nil then
				envelope = {
					implementation_version = IMPLEMENTATION_VERSION,
					schema_version = state.options.schema_version,
					revision = 0,
					fencing_generation = 0,
					created_at = commit_time,
					updated_at = commit_time,
					data = default_copy,
					user_ids = clone_user_ids(state.user_ids),
					tombstone = nil,
					session = nil,
					sidecars = nil,
					write_id = write_id,
				}
			elseif not current_format then
				if parse_error == "future implementation version" then
					decision = "future_schema"
					decision_message = parse_error
					return nil, nil, nil
				elseif parse_error ~= "legacy payload" then
					decision = "corrupt"
					decision_message = parse_error or "durable envelope is invalid"
					return nil, nil, nil
				end
				local legacy_decoder = state.options.legacy_decoder
				if legacy_decoder == nil then
					decision = "legacy"
					decision_message = "legacy payload requires a legacy_decoder"
					return nil, nil, nil
				end
				local legacy_value, legacy_version, decoder_error = run_legacy_decoder(legacy_decoder, raw)
				if legacy_value == nil then
					decision = "legacy"
					decision_message = decoder_error or "legacy decoder failed"
					return nil, nil, nil
				end
				envelope = {
					implementation_version = IMPLEMENTATION_VERSION,
					schema_version = legacy_version or 0,
					revision = 0,
					fencing_generation = 0,
					created_at = commit_time,
					updated_at = commit_time,
					data = legacy_value,
					user_ids = if backend_info ~= nil then clone_user_ids(backend_info.UserIds) else clone_user_ids(state.user_ids),
					tombstone = nil,
					session = nil,
					sidecars = nil,
					write_id = write_id,
				}
			elseif envelope == nil then
				decision = "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope == nil then
				decision = "corrupt"
				decision_message = "durable envelope is missing"
				return nil, nil, nil
			end
			if envelope.write_id == write_id
				and envelope.session ~= nil
				and envelope.session.token == token
				and envelope.session.generation == envelope.fencing_generation
				and envelope.session.job_id == server_id
			then
				if envelope.session.lease_until <= commit_time then
					decision = "fenced"
					decision_message = "confirmed session lease expired before acquisition could be verified"
					return nil, nil, nil
				end
				decision = "success"
				return envelope, envelope.user_ids, (if backend_info ~= nil then backend_info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "stored schema is newer than this server supports"
				return nil, nil, nil
			end
			local current_time = commit_time
			if envelope.session ~= nil and envelope.session.lease_until > current_time then
				decision = "locked"
				decision_message = "record is owned by another live session"
				locked_generation = envelope.fencing_generation
				locked_job_id = envelope.session.job_id
				locked_token = envelope.session.token
				return nil, nil, nil
			end
			if envelope.tombstone ~= nil and not recreate then
				decision = "tombstoned"
				decision_message = "record is tombstoned and requires deliberate recreation"
				return nil, nil, nil
			end
			local next_value = envelope.data
			if next_value == nil then
				next_value = default_copy
			end
			if next_value == nil then
				decision = "validation"
				decision_message = "default data is required for a new record"
				return nil, nil, nil
			end
			local working = copy_value(next_value)
			if working == nil then
				decision = "validation"
				decision_message = "record data could not be copied"
				return nil, nil, nil
			end
			local migrated, migration_error = apply_migrations(state, envelope.schema_version, working)
			if migrated == nil then
				decision = if migration_error == "stored schema is newer than this server supports" then "future_schema" else "migration"
				decision_message = migration_error
				return nil, nil, nil
			end
			local final_valid, final_message = validate_value(migrated, state.options.validator)
			if not final_valid then
				decision = "validation"
				decision_message = final_message
				return nil, nil, nil
			end
			local next_generation = math.max(1, envelope.fencing_generation + 1)
			created = raw == nil or envelope.tombstone ~= nil
			local is_new_record = raw == nil or envelope.tombstone ~= nil
			local initial_ids = if is_new_record then clone_user_ids(state.user_ids) elseif recovering_history and recovery_candidate ~= nil then clone_user_ids(recovery_candidate.UserIds) elseif backend_info ~= nil then clone_user_ids(backend_info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {}
			local initial_metadata = if is_new_record then clone_metadata(state.metadata) elseif recovering_history and recovery_candidate ~= nil then clone_metadata(recovery_candidate.Metadata) elseif backend_info ~= nil then clone_metadata(backend_info.Metadata) else {}
			local next_envelope: Envelope = {
				implementation_version = envelope.implementation_version,
				schema_version = state.options.schema_version,
				revision = if envelope.tombstone ~= nil then envelope.revision + 1 else envelope.revision,
				sidecars = prepared_envelope_cache._sidecar_protocol.clone(envelope.sidecars),
				fencing_generation = next_generation,
				created_at = if envelope.created_at > 0 then envelope.created_at else commit_time,
				updated_at = commit_time,
				data = migrated,
				user_ids = initial_ids,
				tombstone = nil,
				session = {
					token = token,
					generation = next_generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = commit_time,
					lease_until = commit_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				write_id = write_id,
			}
			local envelope_valid, envelope_error = validate_envelope(next_envelope)
			if not envelope_valid then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			decision = "success"
			return next_envelope, initial_ids, make_backend_metadata(initial_metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = normalize_result_code(result_code)
			decision_message = result_message
		end
		if state.retired or (state.state :: SessionState) ~= "acquiring" then
			state.busy = false
			disconnect_message_subscription(state)
			return "closing", "open was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and returned.session ~= nil and returned.session.token == token and returned.session.generation == returned.fencing_generation then
				if returned.session.lease_until > session_now_unix(state.backend.mock) then
					confirmed = returned
					confirmed_info = info
					break
				end
				final_decision = "fenced"
				final_decision_message = "confirmed session lease expired before acquisition could be verified"
				break
			end
		end
		if decision == "corrupt" and not recovery_checked then
			recovery_checked = true
			local observed_raw, observed_info, observed_read_result, observed_read_message = backend_get(
				state.backend,
				false,
				deadline,
				state
			)
			if observed_read_result ~= nil then
				if is_retryable_result(normalize_result_code(observed_read_result) or "unknown", "open") and attempt < attempts + 1 then
					recovery_checked = false
					last_result = normalize_result_code(observed_read_result)
					last_error = observed_read_message
					task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
					continue
				end
				final_decision = normalize_result_code(observed_read_result)
				final_decision_message = observed_read_message
				break
			end
			if observed_raw == nil then
				if attempt < attempts + 1 then
					continue
				end
				final_decision = "conflict"
				final_decision_message = "record changed while corruption was being inspected; retry the open"
				break
			end
			local _, observed_parse_error, observed_current_format = parse_envelope(observed_raw)
			if observed_current_format then
				if attempt < attempts + 1 then
					continue
				end
				final_decision = "conflict"
				final_decision_message = "record was repaired or replaced while corruption was being inspected"
				break
			end
			if observed_parse_error == "legacy payload" then
				final_decision = "legacy"
				final_decision_message = "record changed to a legacy payload while corruption was being inspected"
				break
			end
			if observed_info == nil or observed_info.Version == nil then
				final_decision = "corrupt"
				final_decision_message = (observed_parse_error or "durable envelope is invalid") .. "; current version metadata is unavailable, so history recovery was refused"
				break
			end
			local candidate, recovery_result, recovery_message = recover_corrupt_history(
				state,
				observed_info.Version,
				observed_parse_error or "durable envelope is invalid",
				deadline
			)
			if candidate ~= nil then
				recovery_candidate = candidate
				if attempt < attempts + 1 then
					continue
				end
				final_decision = "retry_exhausted"
				final_decision_message = "a safe historical version was found but no open attempt remained to restore it"
				break
			end
			if recovery_result == "locked" or recovery_result == "tombstoned" or recovery_result == "future_schema" or recovery_result == "conflict" then
				final_decision = recovery_result
				final_decision_message = recovery_message
				break
			end
			if is_retryable_result(normalize_result_code(recovery_result) or "unknown", "open") and attempt < attempts + 1 then
				recovery_checked = false
				last_result = normalize_result_code(recovery_result)
				last_error = recovery_message
				task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
				continue
			end
			final_decision = normalize_result_code(recovery_result)
			final_decision_message = recovery_message
			break
		end
		if decision == "locked" then
			if not takeover_enabled(state) then
				final_decision = "locked"
				final_decision_message = decision_message
				break
			end
			if locked_generation ~= nil and locked_job_id ~= nil and locked_token ~= nil then
				local _, handoff_status = request_takeover(state, locked_generation, locked_job_id, locked_token, deadline)
				if handoff_status == "released" and attempt < attempts then
					continue
				end
				if (handoff_status == "accepted" or handoff_status == "pending" or handoff_status == "failed" or handoff_status == "busy") and attempt < attempts then
					task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
					continue
				end
			end
			final_decision = "locked"
			final_decision_message = decision_message
			break
		end
		if decision == "fenced" then
			final_decision = "fenced"
			final_decision_message = decision_message or "session lease is no longer valid"
			break
		end
		if decision == "legacy" or decision == "tombstoned" or decision == "validation" or decision == "migration" or decision == "future_schema" or decision == "corrupt" or decision == "conflict" then
			final_decision = decision
			final_decision_message = decision_message
			break
		end
		if result == nil and result_code ~= nil then
			if not is_retryable_result(normalize_result_code(result_code) or "unknown", "open") then
				final_decision = normalize_result_code(result_code)
				final_decision_message = result_message
				break
			end
			last_result = normalize_result_code(result_code)
			last_error = result_message
		end
		local verified, envelope, info_after = verify_open_write(state, write_id, token, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if result == nil and decision ~= nil then
			last_error = decision_message
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed ~= nil then
		if recovery_applied and recovery_candidate ~= nil then
			warn(("[RecordStore][CorruptionRecovery] status=recovered store=%s scope=%s key=%s reason=%s sourceVersion=%s replacedVersion=%s revision=%d; corrupt version preserved in DataStore version history"):format(
				state.name,
				state.scope,
				state.key,
				recovery_candidate.CorruptReason,
				recovery_candidate.SourceVersion,
				recovery_candidate.ObservedVersion,
				confirmed.revision
				))
		end
		state.pending_open_token = nil
		state.pending_open_write_id = nil
		state.pending_open_default_data = nil
		update_local_from_envelope(state, confirmed, confirmed_info)
		state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "open")
		state.change_sequence = 0
		state.saved_change_sequence = 0
		state.dirty_since_local = nil
		state.pending_operation = nil
		state.next_reconciliation = math.huge
		state.last_reconciliation_category = nil
		state.last_successful_write_local = now_local()
		state.busy = false
		state.state = "active"
		state.next_autosave = now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL) * (0.9 + math.random() * 0.2)
		state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
		state.next_queue_poll = now_local() + (state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL) * (0.5 + math.random())
		state.queue_hint = false
		local open_result: ResultCode = if created then "created" else "loaded"
		observe(state, "open", open_result, nil)
		return open_result, nil
	end
	state.busy = false
	disconnect_message_subscription(state)
	if final_decision ~= nil then
		state.pending_open_token = nil
		state.pending_open_write_id = nil
		state.pending_open_default_data = nil
		state.state = if final_decision == "tombstoned" then "tombstoned" elseif final_decision == "future_schema" then "future" elseif final_decision == "corrupt" then "corrupt" elseif final_decision == "fenced" then "fenced" else "closed"
		observe(state, "open", final_decision, final_decision_message)
		return final_decision, final_decision_message
	end
	local unresolved_result = last_result or "unknown"
	state.state = if unresolved_result == "unknown" or unresolved_result == "retry_exhausted" then "unknown" else "closed"
	observe(state, "open", normalize_result_code(unresolved_result) or "unknown", last_error or "session acquisition was not confirmed")
	return normalize_result_code(unresolved_result) or "unknown", last_error or "session acquisition was not confirmed"
end

local function renew_internal(state: InternalState): (ResultCode, string?)
	if state.retired then
		return "invalid", "record has been retired"
	end
	if closing and not state.shutdown then
		return "closing", "server is shutting down"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy or state.queue_busy then
		return "busy", (if state.queue_busy then "durable queue is being processed" else "record is already saving")
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local generation = state.generation
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "saving"
	local last_error: string? = nil
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			return "closing", "record was retired"
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id and matches_session(envelope, session_token, generation) then
				if envelope.session == nil or envelope.session.lease_until <= transform_time then
					decision = "fenced"
					decision_message = "durable session lease has expired"
					return nil, nil, nil
				end
				return envelope, state.user_ids, state.metadata
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.session == nil then
				decision = "fenced"
				decision_message = "durable session is missing"
				return nil, nil, nil
			end
			if envelope.session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			local durable_user_ids = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {}
			local durable_metadata = if info ~= nil then clone_metadata(info.Metadata) else state.metadata
			local next_envelope: Envelope = {
				implementation_version = envelope.implementation_version,
				schema_version = envelope.schema_version,
				revision = envelope.revision,
				sidecars = prepared_envelope_cache._sidecar_protocol.clone(envelope.sidecars),
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = envelope.data,
				user_ids = durable_user_ids,
				tombstone = nil,
				session = {
					token = session_token,
					generation = generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = envelope.session.acquired_at,
					lease_until = transform_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			return next_envelope, durable_user_ids, make_backend_metadata(durable_metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = normalize_result_code(result_code)
			decision_message = result_message
		end
		if state.retired or (state.state :: SessionState) ~= "saving" then
			state.busy = false
			return "closing", "renewal was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and matches_session(returned, session_token, generation) and returned.session ~= nil and returned.session.lease_until > session_now_unix(state.backend.mock) and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" else "corrupt"
			observe(state, "renew", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			return "validation", decision_message
		end
		if result == nil then
			last_error = result_message or decision_message
		end
		local verified, envelope, info_after = verify_snapshot_write(state, write_id, token, generation, state.revision, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		track_external_data_mutation(state)
		state.busy = false
		state.state = "unknown"
		state.pending_operation = {
			kind = "renew",
			snapshot = nil,
			captured_change_sequence = state.change_sequence,
			expected_revision = state.revision,
			target_revision = state.revision,
			operation_id = write_id,
			session_token = session_token,
			fencing_generation = generation,
			reason = "renew",
			started_at = now_local(),
			attempts = 0,
		}
		state.next_reconciliation = now_local() + 0.25
		state.last_reconciliation_category = "renewal_outcome_unknown"
		observe(state, "renew", "unknown", last_error or "renewal outcome is unresolved")
		return "unknown", last_error or "renewal outcome is unresolved"
	end
	track_external_data_mutation(state)
	local was_dirty = state.change_sequence ~= state.saved_change_sequence
	state.generation = confirmed.fencing_generation
	state.revision = confirmed.revision
	state.created_at = confirmed.created_at
	state.updated_at = confirmed.updated_at
	state.tombstoned = confirmed.tombstone ~= nil
	state.token = if confirmed.session ~= nil then confirmed.session.token else state.token
	state.durable_lease_until = if confirmed.session ~= nil then confirmed.session.lease_until else 0
	state.last_observed = now_unix()
	if not was_dirty then
		state.user_ids = if confirmed_info ~= nil then clone_user_ids(confirmed_info.UserIds) elseif confirmed.user_ids ~= nil then clone_user_ids(confirmed.user_ids) else {}
		state.metadata = if confirmed_info ~= nil then clone_metadata(confirmed_info.Metadata) else state.metadata
	end
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "renew")
	state.pending_operation = nil
	state.next_reconciliation = math.huge
	state.last_reconciliation_category = nil
	state.last_successful_write_local = now_local()
	state.busy = false
	state.state = "active"
	state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
	if state.change_sequence ~= state.saved_change_sequence then
		state.next_autosave = now_local()
	end
	observe(state, "renew", "success", nil)
	complete_deferred_takeover(state)
	return "success", nil
end


local function required_recovery_lease_margin(state: InternalState): number
	return math.max(1, math.min(
		state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE,
		(state.options.lease_duration or DEFAULT_LEASE_DURATION) * 0.25
	))
end

local function reconcile_unknown_release_internal(state: InternalState): (ResultCode, string?)
	if state.retired then return "invalid", "record has been retired" end
	if closing and not state.shutdown then return "closing", "server is shutting down" end
	local pending = state.pending_operation
	if pending == nil or pending.kind ~= "release" then
		return "invalid", "record has no pending release operation"
	end
	if state.state ~= "unknown" then
		return if state.state == "closed" then "success" else "fenced",
			"record is not awaiting release reconciliation"
	end
	if state.busy or state.queue_busy then
		return "busy", "record is already processing durable work"
	end

	local function retry(category: string, message: string, wait_seconds: number?): (ResultCode, string?)
		pending.attempts += 1
		state.busy = false
		state.next_reconciliation = now_local() + (wait_seconds or math.max(0.25, retry_delay(pending.attempts)))
		state.last_reconciliation_category = category
		observe(state, "reconcile_release", "unknown", message)
		return "unknown", message
	end
	local function stop(session_state: SessionState, category: string, result: ResultCode, message: string): (ResultCode, string?)
		state.busy = false
		state.state = session_state
		state.next_reconciliation = math.huge
		state.last_reconciliation_category = category
		disconnect_message_subscription(state)
		observe(state, "reconcile_release", result, message)
		return normalize_result_code(result) or "unknown", message
	end
	local function is_confirmed_release(envelope: Envelope): boolean
		return envelope.write_id == pending.operation_id
			and envelope.revision == pending.target_revision
			and envelope.fencing_generation == pending.fencing_generation
			and envelope.session == nil
			and envelope.tombstone == nil
	end
	local function confirm_release(envelope: Envelope, info: BackendInfo?): (ResultCode, string?)
		if not backend_metadata_matches(info, envelope) then
			return stop("corrupt", "release_metadata_mismatch", "corrupt",
				"release operation matched but DataStore key metadata did not match the envelope")
		end
		state.generation = envelope.fencing_generation
		state.revision = envelope.revision
		state.created_at = envelope.created_at
		state.updated_at = envelope.updated_at
		state.tombstoned = envelope.tombstone ~= nil
		update_state_metadata_from_info(state, info)
		update_local_from_envelope(state, envelope, info)
		state.saved_change_sequence = state.change_sequence
		state.dirty_since_local = nil
		state.last_saved = make_durable_snapshot(envelope, info, "reconcile_" .. pending.reason)
		state.pending_operation = nil
		state.token = nil
		state.durable_lease_until = 0
		state.busy = false
		state.state = "closed"
		state.next_reconciliation = math.huge
		state.next_autosave = math.huge
		state.next_renewal = math.huge
		state.next_queue_poll = math.huge
		state.takeover_requested = false
		state.queue_hint = false
		state.save_requested = false
		state.last_successful_write_local = now_local()
		state.last_reconciliation_category = nil
		disconnect_message_subscription(state)
		observe(state, "reconcile_release", "success", nil)
		return "success", nil
	end

	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	state.busy = true
	local raw, info, read_result, read_message = backend_get(state.backend, false, deadline, state)
	if read_result ~= nil then
		return retry("release_authoritative_read_" .. read_result,
			read_message or "release reconciliation read failed", nil)
	end
	if raw == nil then
		return stop("fenced", "release_record_missing", "fenced",
			"durable record is missing during release reconciliation")
	end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format or envelope == nil then
		local result: ResultCode = if parse_error == "future implementation version" then "future_schema" else "corrupt"
		return stop(if result == "future_schema" then "future" else "corrupt", result, result,
			parse_error or "durable release envelope is invalid")
	end
	if envelope.schema_version > state.options.schema_version then
		return stop("future", "future_schema", "future_schema",
			"durable schema is newer than this server supports")
	end
	if is_confirmed_release(envelope) then
		return confirm_release(envelope, info)
	end
	if envelope.write_id == pending.operation_id then
		return stop("corrupt", "release_operation_identity_mismatch", "corrupt",
			"release operation ID exists with incompatible durable state")
	end
	if not matches_session(envelope, pending.session_token, pending.fencing_generation) then
		return stop("fenced", "ownership_fence_changed", "fenced",
			"durable ownership no longer matches the retained release operation")
	end
	if envelope.revision ~= pending.expected_revision then
		return stop("fenced", "revision_conflict", "fenced",
			"durable revision changed; refusing to release a newer revision")
	end
	if envelope.session == nil or envelope.session.lease_until <= session_now_unix(state.backend.mock) then
		return stop("fenced", "lease_expired", "fenced",
			"session lease expired before release could be safely retried")
	end

	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, result_info, result_code, result_message = backend_update(state.backend, function(current_raw, current_info)
		decision = nil
		decision_message = nil
		local transform_time = session_now_unix(state.backend.mock)
		local current, current_error, current_format = parse_envelope(current_raw)
		if not current_format or current == nil then
			decision = if current_error == "future implementation version" then "future_schema" else "corrupt"
			decision_message = current_error or "durable envelope is invalid"
			return nil, nil, nil
		end
		if current.schema_version > state.options.schema_version then
			decision = "future_schema"
			decision_message = "durable schema is newer than this server supports"
			return nil, nil, nil
		end
		if is_confirmed_release(current) then
			decision = "success"
			return nil, nil, nil
		end
		if current.write_id == pending.operation_id then
			decision = "corrupt"
			decision_message = "release operation ID exists with incompatible durable state"
			return nil, nil, nil
		end
		if not matches_session(current, pending.session_token, pending.fencing_generation) then
			decision = "fenced"
			decision_message = "durable ownership no longer matches the retained release operation"
			return nil, nil, nil
		end
		if current.revision ~= pending.expected_revision then
			decision = "conflict"
			decision_message = "durable revision changed during release reconciliation"
			return nil, nil, nil
		end
		local session = current.session
		if session == nil or session.lease_until <= transform_time then
			decision = "fenced"
			decision_message = "durable session is missing or expired"
			return nil, nil, nil
		end
		local user_ids = if current_info ~= nil then clone_user_ids(current_info.UserIds)
			elseif current.user_ids ~= nil then clone_user_ids(current.user_ids) else {}
		local durable_metadata = if current_info ~= nil then clone_metadata(current_info.Metadata)
			else clone_metadata(state.metadata)
		local next_envelope: Envelope = {
			implementation_version = current.implementation_version,
			schema_version = state.options.schema_version,
			revision = pending.target_revision,
			sidecars = prepared_envelope_cache._sidecar_protocol.clone(current.sidecars),
			fencing_generation = pending.fencing_generation,
			created_at = current.created_at,
			updated_at = transform_time,
			data = pending.snapshot :: JsonValue,
			user_ids = user_ids,
			tombstone = nil,
			session = nil,
			write_id = pending.operation_id,
		}
		local valid, validation_error = validate_envelope(next_envelope)
		if not valid then
			decision = "validation"
			decision_message = validation_error
			return nil, nil, nil
		end
		decision = "success"
		return next_envelope, user_ids, make_backend_metadata(durable_metadata, next_envelope)
	end, deadline, state)
	if state.retired then
		state.busy = false
		return "closing", "record was retired"
	end
	if result_code ~= nil then
		decision = normalize_result_code(result_code)
		decision_message = result_message
	end
	if result ~= nil then
		local returned = parse_envelope(result)
		if returned ~= nil and is_confirmed_release(returned) then
			return confirm_release(returned, result_info)
		end
	end
	if decision == "future_schema" then
		return stop("future", "future_schema", "future_schema", decision_message or "future schema")
	elseif decision == "corrupt" then
		return stop("corrupt", "corrupt", "corrupt", decision_message or "corrupt release envelope")
	elseif decision == "fenced" or decision == "conflict" then
		return stop("fenced", if decision == "conflict" then "revision_conflict" else "ownership_fence_changed",
			"fenced", decision_message or "release operation was fenced")
	elseif decision == "validation" then
		return stop("corrupt", "release_snapshot_invalid", "validation",
			decision_message or "release snapshot failed validation")
	end
	local verified, verified_envelope, verified_info = verify_release_write(
		state, pending.operation_id, pending.fencing_generation, pending.target_revision, false, deadline
	)
	if verified and verified_envelope ~= nil then
		return confirm_release(verified_envelope, verified_info)
	end
	return retry("release_result_unconfirmed",
		result_message or decision_message or "release outcome is unresolved", nil)
end

local function reconcile_unknown_internal(state: InternalState): (ResultCode, string?)
	if state.retired then return "invalid", "record has been retired" end
	if closing and not state.shutdown then return "closing", "server is shutting down" end
	if state.state ~= "unknown" then
		return if (state.state :: SessionState) == "active" then "success" else "fenced", "record is not awaiting reconciliation"
	end
	local pending = state.pending_operation
	if pending == nil then
		state.next_reconciliation = math.huge
		state.last_reconciliation_category = "missing_operation_identity"
		return "unknown", "unknown record has no retained logical operation"
	end
	if pending.kind == "release" then
		return reconcile_unknown_release_internal(state)
	end
	if state.busy or state.queue_busy then return "busy", "record is already processing durable work" end

	local function retry(category: string, message: string, wait_seconds: number?): (ResultCode, string?)
		pending.attempts += 1
		state.busy = false
		state.next_reconciliation = now_local() + (wait_seconds or math.max(0.25, retry_delay(pending.attempts)))
		state.last_reconciliation_category = category
		observe(state, "reconcile", "unknown", message)
		return "unknown", message
	end
	local function stop(session_state: SessionState, category: string, result: ResultCode, message: string): (ResultCode, string?)
		state.busy = false
		state.state = session_state
		state.next_reconciliation = math.huge
		state.last_reconciliation_category = category
		disconnect_message_subscription(state)
		observe(state, "reconcile", result, message)
		return normalize_result_code(result) or "unknown", message
	end
	local function confirm(envelope: Envelope, info: BackendInfo?): (ResultCode, string?)
		if not backend_metadata_matches(info, envelope) then
			return stop("corrupt", "committed_key_metadata_mismatch", "corrupt",
				"operation matched but DataStore key metadata did not match the envelope")
		end
		local lease_until = if envelope.session ~= nil then envelope.session.lease_until else 0
		local lease_remaining = lease_until - session_now_unix(state.backend.mock)
		state.generation = envelope.fencing_generation
		state.revision = envelope.revision
		state.created_at = envelope.created_at
		state.updated_at = envelope.updated_at
		state.tombstoned = envelope.tombstone ~= nil
		state.token = if envelope.session ~= nil then envelope.session.token else nil
		state.durable_lease_until = lease_until
		update_state_metadata_from_info(state, info)
		state.last_saved = make_durable_snapshot(envelope, info, "reconcile_" .. pending.reason)
		if pending.kind == "save" then
			state.saved_change_sequence = math.max(state.saved_change_sequence, pending.captured_change_sequence)
			if state.change_sequence == pending.captured_change_sequence then
				update_local_from_envelope(state, envelope, info)
				state.dirty_since_local = nil
				state.save_requested = false
			else
				if state.dirty_since_local == nil then state.dirty_since_local = now_local() end
				state.save_requested = true
			end
		end
		state.pending_operation = nil
		state.busy = false
		state.last_successful_write_local = now_local()
		state.next_reconciliation = math.huge
		if envelope.session ~= nil and lease_remaining > required_recovery_lease_margin(state) then
			state.state = "active"
			state.last_reconciliation_category = nil
			state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
			state.next_autosave = if state.change_sequence ~= state.saved_change_sequence
				then now_local()
				else now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL)
			observe(state, "reconcile", "success", nil)
			complete_deferred_takeover(state)
			return "success", nil
		end
		state.state = "fenced"
		state.last_reconciliation_category = "commit_confirmed_without_safe_lease_margin"
		disconnect_message_subscription(state)
		observe(state, "reconcile", "fenced", "operation committed without a safe remaining lease margin")
		return "fenced", "operation committed without a safe remaining lease margin"
	end

	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	state.busy = true
	local raw, info, read_result, read_message = backend_get(state.backend, false, deadline, state)
	if read_result ~= nil then return retry("authoritative_read_" .. read_result, read_message or "reconciliation read failed", nil) end
	if raw == nil then
		return stop("fenced", "durable_record_missing", "fenced", "durable profile is missing during reconciliation")
	end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format or envelope == nil then
		local result: ResultCode = if parse_error == "future implementation version" then "future_schema" else "corrupt"
		return stop(if result == "future_schema" then "future" else "corrupt", result, result,
			parse_error or "durable envelope is invalid")
	end
	if envelope.schema_version > state.options.schema_version then
		return stop("future", "future_schema", "future_schema", "durable schema is newer than this server supports")
	end
	if envelope.write_id == pending.operation_id
		and envelope.revision == pending.target_revision
		and matches_session(envelope, pending.session_token, pending.fencing_generation)
	then
		return confirm(envelope, info)
	end
	if not matches_session(envelope, pending.session_token, pending.fencing_generation) then
		return stop("fenced", "ownership_fence_changed", "fenced",
			"durable ownership no longer matches the retained logical operation")
	end
	if envelope.revision ~= pending.expected_revision then
		return stop("fenced", "revision_conflict", "fenced",
			"durable revision changed; refusing to overwrite a newer revision")
	end
	local session = envelope.session
	if session == nil then
		return stop("fenced", "durable_session_missing", "fenced", "durable session is missing")
	end
	local remaining_lease = session.lease_until - session_now_unix(state.backend.mock)
	if remaining_lease <= 0 then
		return stop("fenced", "lease_expired", "fenced", "session lease expired before recovery could safely retry")
	end
	local required_margin = required_recovery_lease_margin(state)
	if remaining_lease <= required_margin then
		return retry("lease_margin_low",
			"waiting for the existing lease to expire rather than retrying near its safety boundary",
			remaining_lease + 0.1)
	end

	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, result_info, result_code, result_message = backend_update(state.backend, function(current_raw, current_info)
		decision = nil
		decision_message = nil
		local transform_time = session_now_unix(state.backend.mock)
		local current, current_error, current_format = parse_envelope(current_raw)
		if not current_format or current == nil then
			decision = if current_error == "future implementation version" then "future_schema" else "corrupt"
			decision_message = current_error or "durable envelope is invalid"
			return nil, nil, nil
		end
		if current.schema_version > state.options.schema_version then
			decision = "future_schema"
			decision_message = "durable schema is newer than this server supports"
			return nil, nil, nil
		end
		if current.write_id == pending.operation_id
			and current.revision == pending.target_revision
			and matches_session(current, pending.session_token, pending.fencing_generation)
		then
			decision = "success"
			return current,
				(if current_info ~= nil then current_info.UserIds else current.user_ids),
				(if current_info ~= nil then current_info.RawMetadata else make_backend_metadata(state.metadata, current))
		end
		if not matches_session(current, pending.session_token, pending.fencing_generation) then
			decision = "fenced"
			decision_message = "durable ownership no longer matches the retained operation"
			return nil, nil, nil
		end
		if current.revision ~= pending.expected_revision then
			decision = "conflict"
			decision_message = "durable revision changed during reconciliation"
			return nil, nil, nil
		end
		local current_session = current.session
		if current_session == nil or current_session.lease_until <= transform_time then
			decision = "fenced"
			decision_message = "durable session is missing or expired"
			return nil, nil, nil
		end
		if current_session.lease_until <= transform_time + required_margin then
			decision = "fenced"
			decision_message = "lease safety margin is insufficient"
			return nil, nil, nil
		end
		local user_ids = if current_info ~= nil then clone_user_ids(current_info.UserIds)
			elseif current.user_ids ~= nil then clone_user_ids(current.user_ids) else {}
		local durable_metadata = if current_info ~= nil then clone_metadata(current_info.Metadata) else clone_metadata(state.metadata)
		local next_envelope: Envelope = {
			implementation_version = current.implementation_version,
			schema_version = if pending.kind == "save" then state.options.schema_version else current.schema_version,
			revision = if pending.kind == "save" then pending.target_revision else current.revision,
			sidecars = prepared_envelope_cache._sidecar_protocol.clone(current.sidecars),
			fencing_generation = pending.fencing_generation,
			created_at = current.created_at,
			updated_at = transform_time,
			data = if pending.kind == "save" then pending.snapshot else current.data,
			user_ids = user_ids,
			tombstone = nil,
			session = {
				token = pending.session_token,
				generation = pending.fencing_generation,
				job_id = server_id,
				place_id = game.PlaceId,
				acquired_at = current_session.acquired_at,
				lease_until = transform_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
			},
			write_id = pending.operation_id,
		}
		local valid, validation_error = validate_envelope(next_envelope)
		if not valid then
			decision = "validation"
			decision_message = validation_error
			return nil, nil, nil
		end
		decision = "success"
		return next_envelope, user_ids, make_backend_metadata(durable_metadata, next_envelope)
	end, deadline, state)
	if result_code ~= nil then
		decision = normalize_result_code(result_code)
		decision_message = result_message
	end
	if state.retired then
		state.busy = false
		return "closing", "record was retired"
	end
	if decision == "future_schema" then
		return stop("future", "future_schema", "future_schema", decision_message or "future schema")
	elseif decision == "corrupt" then
		return stop("corrupt", "corrupt", "corrupt", decision_message or "corrupt envelope")
	elseif decision == "fenced" or decision == "conflict" then
		if decision_message == "lease safety margin is insufficient" then
			return retry("lease_margin_low", decision_message,
				math.max(0.1, session.lease_until - session_now_unix(state.backend.mock) + 0.1))
		end
		return stop("fenced", if decision == "conflict" then "revision_conflict" else "ownership_fence_changed",
			"fenced", decision_message or "operation was fenced")
	elseif decision == "validation" then
		return stop("corrupt", "recovery_snapshot_invalid", "validation", decision_message or "recovery snapshot failed validation")
	end
	if result ~= nil then
		local returned = parse_envelope(result)
		if returned ~= nil
			and returned.write_id == pending.operation_id
			and returned.revision == pending.target_revision
			and matches_session(returned, pending.session_token, pending.fencing_generation)
		then
			return confirm(returned, result_info)
		end
	end
	return retry("retry_result_unconfirmed",
		result_message or (if result_code ~= nil then tostring(result_code) else nil)
			or decision_message or "recovery write did not confirm the retained operation",
		nil)
end

local function detach_public_data_for_release(state: InternalState): (boolean, string?)
	if state.public_data_detached then
		return true, nil
	end
	local detached_data: JsonValue? = nil
	if state.data ~= nil then
		local copy_ok, copy_or_error = pcall(function()
			return copy_value(state.data)
		end)
		if not copy_ok or copy_or_error == nil then
			local message = "could not isolate public Data before session release"
			state.data = nil
			state.public_data_source = nil
			state.public_data_detached = true
			if type(state.public_record) == "table" then
				local public_record = state.public_record :: { Data: unknown }
				public_record.Data = nil
			end
			return false, message
		end
		detached_data = copy_or_error
	end
	state.data = detached_data
	state.public_data_source = copy_value(detached_data)
	state.public_data_detached = true
	if type(state.public_record) == "table" then
		local public_record = state.public_record :: { Data: unknown }
		public_record.Data = copy_value(detached_data)
	end
	return true, nil
end

close_internal = function(state: InternalState, shutdown: boolean): (ResultCode, string?)
	if state.retired then
		return "closed", nil
	end
	if state.state == "closed" then
		return "closed", nil
	end
	if state.state == "tombstoned" then
		return "closed", nil
	end
	local wait_deadline = now_local() + (if shutdown then state.options.shutdown_deadline or DEFAULT_SHUTDOWN_DEADLINE else state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	while (state.busy or state.queue_busy) and now_local() < wait_deadline do
		task.wait(0.05)
	end
	if state.busy then
		state.state = "unknown"
		observe(state, "close", "unknown", "close deadline expired while another durable operation was in flight")
		return "unknown", "close deadline expired while another durable operation was in flight"
	end
	if state.queue_busy then
		if not shutdown then
			return "busy", "durable queue is being processed"
		end
		state.state = "unknown"
		observe(state, "close", "unknown", "close deadline expired while the durable queue was being processed")
		return "unknown", "close deadline expired while the durable queue was being processed"
	end
	if state.state ~= "active" then
		return if state.state == "fenced" then "fenced" else "unknown", "record is not actively owned"
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local generation = state.generation
	local expected_revision = state.revision
	local target_revision = expected_revision + 1
	track_external_data_mutation(state)
	local snapshot = copy_value(state.data)
	local valid, validation_error = validate_value(snapshot, state.options.validator)
	if not valid then
		observe(state, "close", "validation", validation_error)
		return "validation", validation_error
	end
	local detached, detach_error = detach_public_data_for_release(state)
	if not detached then
		state.busy = false
		state.state = "corrupt"
		state.last_error = detach_error
		observe(state, "close", "corrupt", detach_error)
		return "corrupt", detach_error
	end
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline = now_local() + (if shutdown then state.options.shutdown_deadline or DEFAULT_SHUTDOWN_DEADLINE else state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = if shutdown then state.options.shutdown_attempts or DEFAULT_SHUTDOWN_ATTEMPTS else state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "releasing"
	local last_error: string? = nil
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			return "closed", nil
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id
				and envelope.session == nil
				and envelope.tombstone == nil
				and envelope.fencing_generation == generation
				and envelope.revision == target_revision
			then
				decision = "success"
				return envelope, envelope.user_ids, (if info ~= nil then info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.session == nil or envelope.session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			if envelope.revision ~= expected_revision then
				decision = "conflict"
				decision_message = "durable revision changed unexpectedly"
				return nil, nil, nil
			end
			local next_envelope: Envelope = {
				implementation_version = envelope.implementation_version,
				schema_version = state.options.schema_version,
				revision = target_revision,
				sidecars = prepared_envelope_cache._sidecar_protocol.clone(envelope.sidecars),
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = snapshot,
				user_ids = clone_user_ids(state.user_ids),
				tombstone = nil,
				session = nil,
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			return next_envelope, state.user_ids, make_backend_metadata(state.metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = normalize_result_code(result_code)
			decision_message = result_message
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and returned.session == nil and returned.revision == target_revision and returned.fencing_generation == generation and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "conflict" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "close", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			return "validation", decision_message
		end
		last_error = result_message or decision_message
		local verified, envelope, info_after = verify_release_write(state, write_id, generation, target_revision, false, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		state.busy = false
		state.state = "unknown"
		state.pending_operation = {
			kind = "release",
			snapshot = copy_value(snapshot),
			captured_change_sequence = state.change_sequence,
			expected_revision = expected_revision,
			target_revision = target_revision,
			operation_id = write_id,
			session_token = session_token,
			fencing_generation = generation,
			reason = if shutdown then "shutdown" else "close",
			started_at = now_local(),
			attempts = 0,
		}
		state.next_reconciliation = now_local() + 0.25
		state.last_reconciliation_category = "release_outcome_unknown"
		observe(state, "close", "unknown", last_error or "release outcome is unresolved")
		return "unknown", last_error or "release outcome is unresolved"
	end
	update_local_from_envelope(state, confirmed, confirmed_info)
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "close")
	state.saved_change_sequence = state.change_sequence
	state.busy = false
	state.state = "closed"
	state.durable_lease_until = 0
	state.next_autosave = math.huge
	state.next_renewal = math.huge
	state.next_queue_poll = math.huge
	state.takeover_requested = false
	state.queue_hint = false
	disconnect_message_subscription(state)
	observe(state, "close", "closed", nil)
	return "closed", nil
end

local function complete_deferred_takeover_work(state: InternalState): { [string]: any }
	if not state.takeover_requested or state.busy or state.state ~= "active" or state.retired then
		return { code = "cancelled", message = "takeover is no longer eligible" }
	end
	local request_id = state.takeover_request_id
	local requester_job_id = state.takeover_requester_job_id
	local result, message = close_internal(state, false)
	if request_id ~= nil and requester_job_id ~= nil then
		local status: HandoffStatus = if result == "closed" then "released" else "failed"
		cache_takeover_status(state, request_id, status)
		publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", status)
	end
	state.takeover_request_id = nil
	state.takeover_requester_job_id = nil
	state.takeover_requested = false
	return { code = if result == "closed" then "success" else result, message = message }
end

complete_deferred_takeover = function(state: InternalState)
	if not state.takeover_requested or state.busy or state.state ~= "active" then
		return
	end
	task.spawn(function()
		complete_deferred_takeover_work(state)
	end)
end

local function save(self: Record, reason: string?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = save_internal(state, reason or "manual", nil, nil)
	sync_public(self)
	return normalize_result_code(result) or "unknown", message
end

local function stats(self: Record): { [string]: number | string? }
	local state = private[self]
	if state == nil then
		return {}
	end
	return {
		state = state.state,
		generation = state.generation,
		revision = state.revision,
		created_at = state.created_at,
		updated_at = state.updated_at,
		durable_lease_until = state.durable_lease_until,
		busy = if state.busy then 1 else 0,
		queue_busy = if state.queue_busy then 1 else 0,
		save_requested = if state.save_requested then 1 else 0,
		takeover_requested = if state.takeover_requested then 1 else 0,
		queue_hint = if state.queue_hint then 1 else 0,
		observer_errors = state.observer_errors,
		change_events_dropped = state.change_events_dropped,
		takeover_requests_suppressed = state.handoff_requests_suppressed,
		handoff_ack_count = state.handoff_ack_count,
		last_observed = state.last_observed,
		last_error = state.last_error,
		last_saved_revision = if state.last_saved ~= nil then state.last_saved.Revision else 0,
		last_saved_generation = if state.last_saved ~= nil then state.last_saved.Generation else 0,
		last_saved_at = if state.last_saved ~= nil then state.last_saved.ConfirmedAt else 0,
		handoff_status = state.handoff_status,
		handoff_published = if state.handoff_published then 1 else 0,
		change_sequence = state.change_sequence,
		saved_change_sequence = state.saved_change_sequence,
		dirty = if state.change_sequence ~= state.saved_change_sequence then 1 else 0,
	}
end

local function open(self: Record, default_data: JsonValue?, recreate: boolean?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = open_internal(state, default_data, recreate)
	sync_public(self)
	return normalize_result_code(result) or "unknown", message
end

local function make_record(name: string, scope: string, key: string, options: Options, mock: boolean, transact_engine: (Record, string, string, TransactionReducer, TransactionOptions?, string?, JsonValue?, { OutboxEventSpec }?) -> (JsonValue?, TransactionStatus, string?), transaction_status_engine: (Record, string, JsonValue) -> TransactionReceiptStatus): Record
	local mode = if mock then "mock" else "live"
	local id = HttpService:JSONEncode({ mode, name, scope, key })
	local existing = records[id]
	if existing ~= nil then
		local existing_state = private[existing]
		if existing_state ~= nil and existing_state.options.schema_version ~= options.schema_version then
			error("record already exists locally with a different schema version", 2)
		end
		return existing
	end
	local initial_ids = clone_user_ids(options.user_ids)
	local normalized_ids, ids_error = normalize_user_ids(initial_ids)
	if normalized_ids == nil then
		error(ids_error, 2)
	end
	local initial_user_ids = normalized_ids
	local initial_metadata = clone_metadata(options.metadata)
	local metadata_valid, metadata_error = validate_metadata(initial_metadata)
	if not metadata_valid then
		error(metadata_error, 2)
	end
	local interval = options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL
	local state: InternalState = {
		pending_transaction = nil,
		name = name,
		scope = scope,
		key = key,
		backend = make_backend(name, scope, key, mock),
		queue_backend = nil,
		queue_legacy_checked = false,
		options = options,
		change_observers = {},
		change_observer_next_id = 1,
		change_dispatch_queue = {},
		change_dispatch_head = 1,
		change_dispatch_tail = 0,
		change_dispatch_running = false,
		change_events_dropped = 0,
		takeover_seen = {},
		takeover_seen_order = {},
		takeover_request_id = nil,
		takeover_requester_job_id = nil,
		handoff_request_id = nil,
		handoff_target_job_id = nil,
		handoff_target_token = nil,
		handoff_target_generation = nil,
		handoff_status = nil,
		handoff_deadline = 0,
		handoff_published = false,
		handoff_last_publish = -math.huge,
		handoff_requests_suppressed = 0,
		handoff_ack_count = 0,
		current_operation_id = nil,
		pending_open_token = nil,
		pending_open_write_id = nil,
		pending_open_default_data = nil,
		last_error_info = nil,
		state = "closed",
		data = nil,
		public_data_source = nil,
		public_data_detached = false,
		public_record = nil,
		token = nil,
		generation = 0,
		revision = 0,
		created_at = 0,
		updated_at = 0,
		user_ids = initial_user_ids,
		metadata = initial_metadata,
		tombstoned = false,
		next_autosave = now_local() + interval,
		next_renewal = math.huge,
		next_message_subscribe = math.huge,
		next_queue_poll = math.huge,
		busy = false,
		queue_busy = false,
		mailbox_v2_binding = false,
		mailbox_v2 = nil,
		save_requested = false,
		shutdown = false,
		retired = false,
		takeover_requested = false,
		queue_hint = false,
		message_topic = make_message_topic(options.message_topic_prefix or DEFAULT_MESSAGE_TOPIC_PREFIX, name, scope, key),
		message_subscription = nil,
		last_error = nil,
		last_result = nil,
		last_observed = now_unix(),
		observer_errors = 0,
		last_saved = nil,
		change_sequence = 0,
		saved_change_sequence = 0,
		durable_lease_until = 0,
		pending_operation = nil,
		next_reconciliation = math.huge,
		last_reconciliation_category = nil,
		dirty_since_local = nil,
		last_successful_write_local = nil,
	}
	local record: Record = {
		Data = nil,
		State = "closed",
		Key = key,
		Generation = 0,
		Revision = 0,
		CreatedAt = 0,
		UpdatedAt = 0,
		Tombstoned = false,
		LastError = nil,
		Open = open,
		Get = get_data,
		GetKey = get_key,
		GetState = get_state,
		GetRevision = get_revision,
		GetGeneration = get_generation,
		IsOpen = is_open,
		GetBackendInfo = get_backend_info,
		GetLastSaved = get_last_saved,
		IsDirty = is_dirty,
		CanMutate = can_mutate,
		GetDurabilityStatus = get_durability_status,
		GetLastError = get_last_error_info,
		GetHandoff = get_handoff,
		GetIdentity = get_identity,
		SubscribeChanges = subscribe_changes,
		GetUserIds = get_user_ids,
		SetUserIds = set_user_ids,
		AddUserId = add_user_id,
		RemoveUserId = remove_user_id,
		GetMetadata = get_metadata,
		SetMetadata = set_metadata,
		UpdateMetadata = update_metadata,
		Touch = touch,
		Update = update,
		Reconcile = reconcile,
		Save = save,
		TransactAsync = function(self: Record, operation_id: string, reducer: TransactionReducer, options: TransactionOptions)
			local result, status, message = transact_engine(self, "transaction", operation_id, reducer, options, nil, nil, nil)
			sync_public(self)
			return result, status :: TransactionStatus, message
		end,
		GetTransactionStatusAsync = function(self: Record, operation_id: string, request: JsonValue): TransactionReceiptStatus
			return transaction_status_engine(self, operation_id, request)
		end,
		ApplyInboxAsync = function(self: Record, message_id: string, message_type: string, payload: JsonValue, reducer: TransactionReducer, options: TransactionOptions?)
			local result, status, message = transact_engine(self, "inbox", message_id, reducer, options, message_type, payload, nil)
			sync_public(self)
			return result, status :: TransactionStatus, message
		end,
		CommitWithOutboxAsync = function(self: Record, commit_key: string, command_type: string, command_payload: JsonValue, outbox_events: { OutboxEventSpec }, reducer: TransactionReducer, options: TransactionOptions?)
			local result, status, message = transact_engine(self, "outbox", commit_key, reducer, options, command_type, command_payload, outbox_events)
			sync_public(self)
			return result, status :: TransactionStatus, message
		end,
		GetOutboxAsync = function(self: Record, max_events: number?)
			local engine = prepared_envelope_cache._outbox_engine :: any
			if engine == nil then return {}, "invalid", "outbox API is not initialized" end
			return engine.get(self, max_events)
		end,
		DispatchOutboxAsync = function(self: Record, dispatcher: OutboxDispatcher, max_events: number?)
			local engine = prepared_envelope_cache._outbox_engine :: any
			if engine == nil then return 0, "invalid", "outbox API is not initialized" end
			return engine.dispatch(self, dispatcher, max_events)
		end,
		PruneOutboxAsync = function(self: Record, delivered_before_unix: number, max_events: number?)
			local engine = prepared_envelope_cache._outbox_engine :: any
			if engine == nil then return 0, "invalid", "outbox API is not initialized" end
			return engine.prune(self, delivered_before_unix, max_events)
		end,
		MessageAsync = message,
		GetMailboxOwner = get_mailbox_owner,
		CreateMailboxStoreAdapter = mailbox_store_adapter,
		BindMailboxV2Async = bind_mailbox_v2_async,
		EnqueueAsync = enqueue,
		ProcessQueueAsync = process_queue,
		GetQueueAsync = get_queue,
		GetDeadLettersAsync = get_dead_letters,
		ClaimDeadLetterAsync = claim_dead_letter,
		ReplayDeadLetterAsync = replay_dead_letter,
		DiscardDeadLetterAsync = discard_dead_letter,
		Close = close_record,
		Delete = delete_record,
		Stats = stats,
	}
	state.public_record = record
	private[record] = state
	records[id] = record
	sync_public(record)
	return record
end

local scheduler_governor = RecordStoreScheduler.new({
	now_ms = function() return now_local() * 1000 end,
	now_unix = now_unix,
	get_record_stats = function(record)
		if type(record) ~= "table" or type(record.Stats) ~= "function" then return {} end
		local ok, value = pcall(function() return record:Stats() end)
		return if ok and type(value) == "table" then value else {}
	end,
	get_request_budgets = function(): { read: number, write: number }?
		local read_ok, read_budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)
		end)
		local write_ok, write_budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite)
		end)
		if not read_ok or not write_ok or type(read_budget) ~= "number" or type(write_budget) ~= "number" then
			return nil
		end
		return { read = read_budget, write = write_budget }
	end,
})
local scheduler_dispatcher = RecordStoreScheduler.new_dispatcher(scheduler_governor, {
	now_ms = function() return now_local() * 1000 end,
})
local scheduler_activation = {
	requested = false,
	revision = 1,
	percent = 100,
	salt = "recordstore-scheduler-v1",
	cohort_bucket = 0,
}
local function scheduler_rollout_bucket(salt: string): number
	local identity = tostring(game.PlaceId) .. ":" .. tostring(server_id) .. ":" .. salt
	local hash = 0
	for index = 1, #identity do
		hash = (hash * 131 + string.byte(identity, index)) % 2147483647
	end
	return hash % 100
end
scheduler_activation.cohort_bucket = scheduler_rollout_bucket(scheduler_activation.salt)

local function apply_scheduler_activation()
	local cohort_included = scheduler_activation.cohort_bucket < scheduler_activation.percent
	local should_enable = scheduler_activation.requested and cohort_included
	if scheduler_enabled == should_enable then return end
	scheduler_enabled = should_enable
	if should_enable then
		scheduler_dispatcher:Kick()
	else
		scheduler_dispatcher:CancelQueued("advanced scheduler disabled or excluded by rollout")
	end
end

local scheduler_state: any = setmetatable({}, { __mode = "k" })

local function scheduler_owner_id(state: InternalState): string
	local function component(value: string): string
		return tostring(#value) .. ":" .. value
	end
	return component(state.name) .. component(state.scope) .. component(state.key)
end

local function scheduled_state_slot(state: InternalState): any
	local slot = scheduler_state[state]
	if slot == nil then
		slot = { pending = {}, jobs = {}, last_result = {} }
		scheduler_state[state] = slot
	end
	return slot
end

local function enqueue_state_work(
	record: Record,
	state: InternalState,
	kind: string,
	lane: string,
	work_class: string,
	operation_class: string,
	callback: (...any) -> any,
	schedule_options: any?
): any
	local slot = scheduled_state_slot(state)
	if slot.pending[kind] == true then return { code = "already_pending" } end
	local options: { [string]: any } = if type(schedule_options) == "table"
		then table.clone(schedule_options) :: { [string]: any}
		else {}
	local caller_on_complete = options.on_complete
	options.lane = lane
	options.work_class = work_class
	options.operation_class = operation_class
	options.on_complete = function(result)
		slot.pending[kind] = nil
		slot.jobs[kind] = nil
		slot.last_result[kind] = if type(result) == "table" then tostring(result.code or "unknown") else "unknown"
		if type(result) == "table" and result.code == "cancelled"
			and not scheduler_enabled and not closing and state.state == "active"
		then
			local retry_at = now_local()
			if kind == "lease_renewal" then
				state.next_renewal = math.min(state.next_renewal, retry_at)
			elseif kind == "autosave" then
				state.next_autosave = math.min(state.next_autosave, retry_at)
			elseif kind == "queue_poll" then
				state.next_queue_poll = math.min(state.next_queue_poll, retry_at)
			end
		end
		if kind == "lease_renewal" and type(result) == "table" and result.code == "retry_exhausted" and (state.state :: SessionState) == "active" then
			state.next_renewal = math.min(state.next_renewal, now_local())
		elseif kind == "autosave" and type(result) == "table" and result.code == "retry_exhausted" and (state.state :: SessionState) == "active" then
			state.next_autosave = math.min(state.next_autosave, now_local())
		elseif kind == "queue_poll" and type(result) == "table" and result.code == "retry_exhausted" and (state.state :: SessionState) == "active" then
			state.next_queue_poll = math.min(state.next_queue_poll, now_local())
		end
		if type(caller_on_complete) == "function" then pcall(caller_on_complete, result) end
	end
	slot.pending[kind] = true
	local result = scheduler_dispatcher:Schedule(
		scheduler_owner_id(state),
		kind .. ":" .. tostring(state.generation),
		function(batch_size: number?)
			if not scheduler_enabled then
				return { code = "cancelled", message = "advanced scheduler was disabled before work started" }
			end
			local recovering = kind == "reconciliation"
				and state.state == "unknown"
				and state.pending_operation ~= nil
			if closing or state.retired or (state.state ~= "active" and not recovering) then
				return { code = "cancelled", message = "record is no longer active" }
			end
			return callback(batch_size)
		end,
		options
	)
	if type(result) ~= "table" or result.code ~= "accepted" then
		slot.pending[kind] = nil
		slot.last_result[kind] = if type(result) == "table" then tostring(result.code) else "unknown"
		return if type(result) == "table" then result else { code = "unknown", message = "scheduler admission returned no result" }
	end
	slot.jobs[kind] = result.id
	return result
end

install_mailbox_renewal_scheduler = function(record: Record, state: InternalState, mailbox: EmbeddedMailbox): (boolean, string?)
	local set_ok, configured, configure_error = pcall(function()
		return mailbox:SetLeaseRenewalScheduler(function(
			message_id: string,
			due_in_ms: number,
			lease_remaining_ms: number,
			callback: () -> unknown,
			on_complete: (unknown) -> ()
		)
			if not scheduler_enabled then
				return { code = "disabled", message = "advanced scheduler is disabled; V2 claim renewal cannot be guaranteed" }
			end
			if type(message_id) ~= "string" or message_id == "" or #message_id > 50
				or not math.isfinite(due_in_ms) or due_in_ms < 0
				or not math.isfinite(lease_remaining_ms) or lease_remaining_ms <= 0
				or type(callback) ~= "function" or type(on_complete) ~= "function"
			then
				return { code = "invalid", message = "V2 claim renewal scheduling arguments are invalid" }
			end
			local schedule_now_ms = now_local() * 1000
			local safety_margin_ms = math.min(5000, math.floor(lease_remaining_ms / 4))
			local deadline_ms = schedule_now_ms + lease_remaining_ms - safety_margin_ms
			if deadline_ms <= schedule_now_ms then
				return { code = "expired", message = "verified mailbox lease has insufficient renewal margin" }
			end
			return enqueue_state_work(
				record,
				state,
				"mailbox_lease_renewal",
				"lease_renewal",
				"lease_renewal",
				"lease_renewal",
				function()
					local callback_ok, result = pcall(callback)
					if not callback_ok then
						return { code = "unknown", message = "V2 lease-renewal callback raised: " .. tostring(result) }
					end
					if type(result) ~= "table" then
						return { code = "unknown", message = "V2 lease-renewal callback returned no structured result" }
					end
					local result_record = result :: { [string]: any }
					if type(result_record.code) ~= "string" then
						return { code = "unknown", message = "V2 lease-renewal callback returned no structured result" }
					end
					return result_record
				end,
				{
					service_class = "critical",
					read_units = 1,
					write_units = 1,
					handler_slots = 1,
					due_at_ms = schedule_now_ms + due_in_ms,
					deadline_ms = deadline_ms,
					expires_at_ms = schedule_now_ms + lease_remaining_ms,
					max_retries = 1,
					retry_delay_ms = 10,
					retry_jitter_percent = 0,
					on_complete = on_complete,
				}
			)
		end)
	end)
	if not set_ok then return false, tostring(configured) end
	if configured ~= true then return false, tostring(configure_error or "scheduler configuration was rejected") end
	return true, nil
end

function RecordStore.configure_scheduler_policy(policy: { [string]: unknown }): (string, string?)
	if type(policy) ~= "table" then return "invalid", "scheduler policy must be a table" end
	return scheduler_dispatcher:SetPolicy(policy)
end

function RecordStore.configure_scheduler_rollout(rollout: { [string]: unknown }): (string, string?)
	if type(rollout) ~= "table" then return "invalid", "scheduler rollout must be a table" end
	local revision = rollout.revision
	if type(revision) ~= "number" or not math.isfinite(revision)
		or math.floor(revision) ~= revision or revision ~= scheduler_activation.revision + 1
	then
		return "invalid", "rollout revision must be the next positive integer"
	end
	local percent = rollout.percent
	if type(percent) ~= "number" or not math.isfinite(percent)
		or math.floor(percent) ~= percent or percent < 0 or percent > 100
	then
		return "invalid", "rollout percent must be an integer from 0 to 100"
	end
	local salt = if rollout.salt == nil then scheduler_activation.salt else rollout.salt
	if type(salt) ~= "string" or #salt < 1 or #salt > 128 then
		return "invalid", "rollout salt must be 1..128 bytes"
	end
	scheduler_activation.revision = revision
	scheduler_activation.percent = percent
	scheduler_activation.salt = salt
	scheduler_activation.cohort_bucket = scheduler_rollout_bucket(salt)
	apply_scheduler_activation()
	return "success", nil
end

function RecordStore.set_scheduler_enabled(enabled: boolean): (boolean, string?)
	if type(enabled) ~= "boolean" then return false, "enabled must be a boolean" end
	scheduler_activation.requested = enabled
	apply_scheduler_activation()
	return true, nil
end

function RecordStore.schedule_work(
	owner_id: string,
	work_id: string,
	callback: (...any) -> any,
	schedule_options: EmbeddedSchedulerScheduleOptions?
): { [string]: any }
	if closing then return { code = "closed", message = "RecordStore is shutting down" } end
	if not scheduler_enabled then return { code = "disabled", message = "advanced scheduling is disabled" } end
	if type(callback) ~= "function" then
		return { code = "invalid", message = "callback must be a function" }
	end
	if type(schedule_options) == "table"
		and (
			schedule_options.lane == "lease_renewal"
			or schedule_options.operation_class == "lease_renewal"
			or schedule_options.operation_class == "profile_release"
			or schedule_options.operation_class == "critical"
			or schedule_options.operation_class == "profile_save"
			or schedule_options.work_class == "lease_renewal"
			or schedule_options.work_class == "profile_release"
			or schedule_options.work_class == "critical"
			or schedule_options.work_class == "profile_save"
			or schedule_options.service_class == "critical"
		)
	then
		return {
			code = "invalid",
			message = "critical admission, critical/profile_save work classes, lease_renewal and profile_release are reserved for internal session work",
		}
	end
	return scheduler_dispatcher:Schedule(owner_id, work_id, function(...: any)
		if not scheduler_enabled then
			return { code = "cancelled", message = "advanced scheduling was disabled before work started" }
		end
		return callback(...)
	end, schedule_options)
end

function RecordStore.get_scheduler_snapshot(): { [string]: any }
	local governor = scheduler_governor:Stats()
	local cohort_included = scheduler_activation.cohort_bucket < scheduler_activation.percent
	return {
		enabled = scheduler_enabled,
		policy = governor.policy,
		rollout = {
			revision = scheduler_activation.revision,
			percent = scheduler_activation.percent,
			salt = scheduler_activation.salt,
			cohort_bucket = scheduler_activation.cohort_bucket,
			cohort_included = cohort_included,
			requested_enabled = scheduler_activation.requested,
		},
		governor = governor,
		dispatcher = scheduler_dispatcher:Stats(),
	}
end

function RecordStore.compare_scheduler_shadow(): any
	return scheduler_governor:ShadowDecision()
end

function RecordStore.replay_scheduler_trace(
	trace: { any },
	policy_override: { [string]: unknown }?
): { any }
	if type(trace) ~= "table" then return { code = "invalid", message = "scheduler trace must be an array" } end
	if policy_override ~= nil and type(policy_override) ~= "table" then
		return { code = "invalid", message = "replay policy override must be a table" }
	end
	if policy_override ~= nil then
		for key in pairs(policy_override) do
			if key == "revision" then
				return { code = "invalid", message = "replay policy revision is assigned internally" }
			end
		end
	end
	local replay_now_ms = now_local() * 1000
	local replay = RecordStoreScheduler.new({
		now_ms = function() return replay_now_ms end,
		advance_ms = function(milliseconds) replay_now_ms += milliseconds end,
	})
	local current_policy = scheduler_governor:Stats().policy
	local replay_policy = replay:Stats().policy
	local policy_patch = table.clone(current_policy)
	if policy_override ~= nil then
		for key, value in pairs(policy_override) do
			policy_patch[key] = value
		end
	end
	policy_patch.revision = replay_policy.revision + 1
	local policy_ok, policy_message = replay:SetPolicy(policy_patch)
	if not policy_ok then return { code = "invalid", message = policy_message } end
	return replay:Replay(trace)
end

local function run_scheduled_record_work(record: Record, state: InternalState, now: number)
	local slot = scheduled_state_slot(state)
	if state.takeover_requested then
		if not state.busy and not state.queue_busy and slot.pending.takeover ~= true then
			enqueue_state_work(record, state, "takeover", "high", "session_takeover", "profile_release", function()
				if not state.takeover_requested then return { code = "cancelled" } end
				if state.busy or state.queue_busy then return { code = "retryable", message = "record is still busy before takeover start" } end
				local result = complete_deferred_takeover_work(state)
				sync_public(record)
				return result
			end, { service_class = "critical", read_units = 1, write_units = 1, max_retries = 4, retry_delay_ms = 25 })
		end
		return
	end

	if not state.busy and not state.queue_busy and now >= state.next_renewal
		and slot.pending.lease_renewal ~= true
	then
		local remaining_ms = if state.durable_lease_until > 0
			then math.max(0, (state.durable_lease_until - now_unix()) * 1000) else nil
		local renewal_options: any = {
			service_class = "critical",
			read_units = 1,
			write_units = 1,
			handler_slots = 1,
			max_retries = 8,
			retry_delay_ms = 25,
			retry_jitter_percent = 10,
		}
		if remaining_ms ~= nil then
			local renewal_advice = scheduler_governor:LeaseRenewalAdvice()
			local renewal_tail = if renewal_advice.lease_renewal_p95_ms ~= nil
				then renewal_advice.lease_renewal_p95_ms
				else renewal_advice.update_async_p95_ms
			local observed_service_ms = math.max(
				if math.isfinite(renewal_tail) then renewal_tail else 0,
				renewal_advice.lease_renewal_ewma_ms,
				renewal_advice.update_async_ewma_ms,
				renewal_advice.service_ewma_ms
			)
			local queue_delay_ms = math.max(0, renewal_advice.oldest_eligible_age_ms)
			local safety_margin_ms = math.max(100, observed_service_ms * 2 + queue_delay_ms)
			local safe_slack_ms = math.max(0, remaining_ms - safety_margin_ms)
			renewal_options.deadline_ms = now_local() * 1000 + safe_slack_ms
		end
		local result = enqueue_state_work(record, state, "lease_renewal", "lease_renewal",
			"profile_lease_renewal", "lease_renewal", function()
				if state.busy or state.queue_busy then
					return { code = "retryable", message = "record became busy before renewal started" }
				end
				local code, message = renew_internal(state)
				sync_public(record)
				return { code = code, message = message }
			end, renewal_options)
		if type(result) == "table" and result.code == "accepted" then
			state.next_renewal = now + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
		end
	elseif not state.busy and not state.queue_busy and now >= state.next_autosave
		and slot.pending.autosave ~= true
	then
		local next_autosave = now + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL) * (0.9 + math.random() * 0.2)
		local result = enqueue_state_work(record, state, "autosave", "normal", "profile_autosave", "update_async", function()
			if state.busy or state.queue_busy then
				return { code = "retryable", message = "record became busy before autosave started" }
			end
			local code, message = save_internal(state, "autosave", nil, nil)
			sync_public(record)
			return { code = code, message = message }
		end, { service_class = "critical", read_units = 1, write_units = 1, handler_slots = 1,
			max_retries = 6, retry_delay_ms = 50, retry_jitter_percent = 10 })
		if type(result) == "table" and result.code == "accepted" then state.next_autosave = next_autosave end
	end

	if state.state == "active"
		and state.options.on_message ~= nil
		and messaging_enabled(state)
		and state.message_subscription == nil
		and now >= state.next_message_subscribe
	then
		subscribe_record(state)
	end

	if state.state == "active"
		and state.options.durable_queue_enabled ~= false
		and ((state.mailbox_v2 ~= nil and (state.options.on_queue_message_async ~= nil or state.options.on_queue_message ~= nil))
			or (state.mailbox_v2 == nil and state.options.on_queue_message ~= nil))
		and slot.pending.queue_poll ~= true
		and (state.queue_hint or now >= state.next_queue_poll)
	then
		local result = enqueue_state_work(record, state, "queue_poll", "background", "mailbox_poll", "read",
			function(batch_size: number?)
				if state.queue_busy then
					return { code = "retryable", message = "queue poll became busy before processing started" }
				end
				state.queue_hint = false
				local batch_size_value: number = if type(batch_size) == "number" then batch_size :: number else 4
				local bounded_batch_size: number = math.clamp(math.floor(batch_size_value), 1, 4)
				local code, message = process_queue(record, bounded_batch_size)
				sync_public(record)
				local processed_count: number = if code == "processed" then tonumber(message) or 0 else 0
				return {
					code = code,
					message = message,
					processed_count = if math.isfinite(processed_count) then processed_count else 0,
				}
			end,
			{ service_class = "normal", read_units = 1, write_units = 1, handler_slots = 1,
				batchable = true, batch_size = 4, batch_backlog = 4, batch_window_ms = 0,
				max_retries = 4, retry_delay_ms = 50, retry_jitter_percent = 10 })
		if type(result) == "table" and result.code == "accepted" then
			state.next_queue_poll = now + (state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL)
		end
	end
end

local function run_scheduled_recovery(record: Record, state: InternalState, now: number)
	if state.state ~= "unknown" or state.pending_operation == nil or now < state.next_reconciliation then
		return
	end
	local slot = scheduled_state_slot(state)
	if slot.pending.reconciliation == true then return end
	local operation_class = if state.pending_operation.kind == "release" then "profile_release" else "profile_save"
	local result = enqueue_state_work(
		record,
		state,
		"reconciliation",
		"high",
		"profile_reconciliation",
		operation_class,
		function()
			local outcome, message = reconcile_unknown_internal(state)
			sync_public(record)
			return { code = "completed", operation_result = outcome, message = message }
		end,
		{
			service_class = "critical",
			read_units = 1,
			write_units = 1,
			handler_slots = 1,
			max_retries = 1,
			retry_delay_ms = 250,
			retry_jitter_percent = 10,
		}
	)
	if type(result) == "table" and result.code == "accepted" then
		state.next_reconciliation = now + 0.5
	elseif type(result) ~= "table" or result.code ~= "already_pending" then
		state.next_reconciliation = now + 0.5
	end
end

local function start_scheduler()
	if scheduler_started then return end
	scheduler_started = true
	task.spawn(function()
		while not closing do
			for record in active_records do
				local state = private[record]
				if state ~= nil and (state.state :: SessionState) == "active" then
					local now = now_local()
					if scheduler_enabled then
						run_scheduled_record_work(record, state, now)
					else
						local handled_takeover = false
						if state.takeover_requested and not state.busy and not state.queue_busy then
							complete_deferred_takeover(state)
							sync_public(record)
							handled_takeover = true
						end
						if not handled_takeover and state.state == "active"
							and not state.busy and not state.queue_busy and now >= state.next_renewal
						then
							state.next_renewal = now + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
							task.spawn(function()
								renew_internal(state)
								sync_public(record)
							end)
						elseif not handled_takeover and state.state == "active"
							and not state.busy and not state.queue_busy and now >= state.next_autosave
						then
							state.next_autosave = now + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL) * (0.9 + math.random() * 0.2)
							task.spawn(function()
								save_internal(state, "autosave", nil, nil)
								sync_public(record)
							end)
						end
						if state.state == "active"
							and state.options.on_message ~= nil
							and messaging_enabled(state)
							and state.message_subscription == nil
							and now >= state.next_message_subscribe
						then subscribe_record(state) end
						if state.state == "active"
							and state.options.durable_queue_enabled ~= false
							and state.options.on_queue_message ~= nil
							and not state.queue_busy
							and (state.queue_hint or now >= state.next_queue_poll)
						then
							state.queue_hint = false
							state.next_queue_poll = now + (state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL)
							task.spawn(function()
								process_queue_internal(state, 4)
								sync_public(record)
							end)
						end
					end
				end
			end
			for record in recovery_records do
				local state = private[record]
				if state ~= nil and state.state == "unknown" and state.pending_operation ~= nil then
					local now = now_local()
					if scheduler_enabled then
						run_scheduled_recovery(record, state, now)
					elseif not recovery_in_flight and not state.busy and now >= state.next_reconciliation then
						recovery_in_flight = true
						state.next_reconciliation = now + 0.5
						task.spawn(function()
							reconcile_unknown_internal(state)
							sync_public(record)
							recovery_in_flight = false
						end)
					end
				end
			end
			if scheduler_enabled then scheduler_dispatcher:Kick() end
			task.wait(SCHEDULER_STEP)
		end
	end)
end

RecordStore.shutdown = function()
	if shutdown_started then
		return
	end
	shutdown_started = true
	closing = true
	scheduler_dispatcher:Close()
	local closing_records: { Record } = {}
	for record, state in private do
		if state.state ~= "closed" and state.state ~= "tombstoned" and state.state ~= "fenced" and state.state ~= "corrupt" and state.state ~= "future" then
			state.shutdown = true
			disconnect_message_subscription(state)
			table.insert(closing_records, record)
		end
	end
	local remaining = #closing_records
	if remaining == 0 then
		return
	end
	for _, record in ipairs(closing_records) do
		task.spawn(function()
			local state = private[record]
			if state ~= nil then
				if state.state == "unknown" and state.pending_operation ~= nil then
					reconcile_unknown_internal(state)
					sync_public(record)
				end
				close_internal(state, true)
			end
			remaining -= 1
		end)
	end
	local deadline = now_local() + DEFAULT_SHUTDOWN_DEADLINE
	while remaining > 0 and now_local() < deadline do
		task.wait(0.05)
	end
end

RecordStore._internals = {}
RecordStore._internals.transact = (function()
	local protocol = prepared_envelope_cache._sidecar_protocol
	local DEFAULT_RECEIPT_RETENTION_SECONDS = 30 * 24 * 60 * 60
	local MAX_RECEIPT_RETENTION_SECONDS = 365 * 24 * 60 * 60
	local MAX_TRANSACTION_RESULT_BYTES = 4096
	local MAX_OUTBOX_BATCH_EVENTS = 16

	local function read_receipt(envelope: Envelope, kind: string, operation_id: string): OperationReceipt?
		local sidecars = envelope.sidecars
		if sidecars == nil then return nil end
		local collection = if kind == "inbox" then sidecars.inbox_receipts else sidecars.transaction_receipts
		return collection[operation_id]
	end

	local function canonical_request(
		state: InternalState,
		kind: string,
		request: JsonValue
	): (string?, string?)
		local encoded, encode_error = protocol.canonicalize({
			store_name = state.name,
			scope = state.scope,
			profile_key = state.key,
			operation_kind = kind,
			request = request,
		})
		if encoded == nil then return nil, encode_error end
		if #encoded > 16_384 then return nil, "canonical transaction request exceeds 16384 bytes" end
		return encoded, nil
	end

	local function run_reducer(
		reducer: TransactionReducer,
		current_data: JsonValue,
		input: JsonValue?
	): (JsonValue?, JsonValue?, string?)
		local resumed_value: JsonValue? = nil
		local resumed_result: JsonValue? = nil
		local callback_error: string? = nil
		local thread = coroutine.create(function()
			local callback_ok, next_data, result = pcall(reducer, current_data, input)
			if not callback_ok then
				callback_error = tostring(next_data)
				return
			end
			resumed_value = next_data
			resumed_result = result
		end)
		local resume_ok, resume_error = coroutine.resume(thread)
		if not resume_ok then
			return nil, nil, tostring(resume_error)
		end
		if coroutine.status(thread) ~= "dead" then
			coroutine.close(thread)
			return nil, nil, "transaction reducer must not yield"
		end
		if callback_error ~= nil then return nil, nil, callback_error end
		return resumed_value, resumed_result, nil
	end

	local function prepare_outbox_events(
		state: InternalState,
		operation_id: string,
		event_specs: { OutboxEventSpec }?
	): ({ OutboxEventRecord }?, string?)
		if event_specs == nil or type(event_specs) ~= "table" then
			return nil, "outbox events must be a table"
		end
		local count = #event_specs
		if count < 1 or count > MAX_OUTBOX_BATCH_EVENTS then
			return nil, "outbox batch must contain 1 to " .. tostring(MAX_OUTBOX_BATCH_EVENTS) .. " events"
		end
		local seen = 0
		for key in pairs(event_specs) do
			if type(key) ~= "number" or not math.isfinite(key) or math.floor(key) ~= key or key < 1 or key > count then
				return nil, "outbox events must be a dense array"
			end
			seen += 1
		end
		if seen ~= count then return nil, "outbox events must be a dense array" end
		local source_identity, source_error = protocol.canonicalize({
			state.name, state.scope, state.key, operation_id,
		})
		if source_identity == nil then return nil, source_error end
		local prepared: { OutboxEventRecord } = {}
		for ordinal, raw_event in ipairs(event_specs) do
			if type(raw_event) ~= "table" then return nil, "outbox event must be a table" end
			local event = raw_event :: OutboxEventSpec
			local valid_target, target_error = validate_store_identity(
				event.target_store, event.target_scope, event.target_key
			)
			if not valid_target then return nil, "outbox destination is invalid: " .. tostring(target_error) end
			if type(event.type) ~= "string" or event.type == "" or #event.type > 100 then
				return nil, "outbox event type must be 1 to 100 characters"
			end
			if type(event.payload_version) ~= "number" or not math.isfinite(event.payload_version)
				or math.floor(event.payload_version) ~= event.payload_version or event.payload_version < 1 then
				return nil, "outbox payload_version must be a positive integer"
			end
			if event.data == nil then return nil, "outbox event data cannot be nil" end
			local payload = copy_value(event.data)
			if payload == nil then return nil, "outbox event payload is invalid" end
			local payload_ok, payload_error = validate_serialized_size(payload)
			if not payload_ok then return nil, "outbox payload is invalid: " .. tostring(payload_error) end
			if event.target_user_id ~= nil and (type(event.target_user_id) ~= "number"
				or not math.isfinite(event.target_user_id) or math.floor(event.target_user_id) ~= event.target_user_id
				or event.target_user_id < 1) then
				return nil, "outbox target_user_id must be a positive integer"
			end
			if event.correlation_id ~= nil and (type(event.correlation_id) ~= "string" or #event.correlation_id > 256) then
				return nil, "outbox correlation_id must be a string of at most 256 bytes"
			end
			if event.causation_id ~= nil and (type(event.causation_id) ~= "string" or #event.causation_id > 256) then
				return nil, "outbox causation_id must be a string of at most 256 bytes"
			end
			local request_identity, identity_error = protocol.canonicalize({
				type = event.type,
				payload_version = event.payload_version,
				payload = payload,
				destination_store_name = event.target_store,
				destination_scope = event.target_scope,
				destination_profile_key = event.target_key,
				destination_user_id = event.target_user_id,
				correlation_id = event.correlation_id,
				causation_id = event.causation_id,
			})
			if request_identity == nil or #request_identity > 16_384 then
				return nil, identity_error or "outbox request identity exceeds 16384 bytes"
			end
			local stable_source = source_identity .. ":" .. operation_id .. ":" .. tostring(ordinal)
			local stable_id = protocol.stable_event_id(stable_source, ordinal)
			prepared[#prepared + 1] = {
				id = stable_id,
				event_type = event.type,
				payload_version = event.payload_version,
				request_identity = request_identity,
				payload = payload,
				destination_store_name = event.target_store,
				destination_scope = event.target_scope,
				destination_profile_key = event.target_key,
				destination_user_id = event.target_user_id,
				correlation_id = event.correlation_id or operation_id,
				causation_id = event.causation_id or stable_id,
				created_at = 0,
				attempts = 0,
				state = "pending",
				last_error = nil,
				delivered_at = nil,
			}
		end
		return prepared, nil
	end

	return function(
		self: Record,
		kind: string,
		operation_id: string,
		reducer: TransactionReducer,
		options: TransactionOptions?,
		input_type: string?,
		input_payload: JsonValue?,
		event_specs: { OutboxEventSpec }?
	): (JsonValue?, TransactionStatus, string?)
		local state = private[self]
		if state == nil then return nil, "invalid", "record does not exist" end
		if state.options.transactional_operations_enabled ~= true then
			return nil, "disabled", "transactional operations are disabled; opt in only after all active servers run a v3-aware build"
		end
		if kind ~= "transaction" and kind ~= "inbox" and kind ~= "outbox" then
			return nil, "invalid", "transaction operation kind is invalid"
		end
		if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
			return nil, "invalid", "operation_id must be 1 to 256 bytes"
		end
		if kind == "outbox" and #operation_id > 64 then
			return nil, "invalid", "outbox commit_key must be at most 64 bytes"
		end
		if type(reducer) ~= "function" then return nil, "invalid", "reducer must be a function" end
		if options ~= nil and type(options) ~= "table" then return nil, "invalid", "transaction options must be a table" end
		if options ~= nil then
			for option_name in pairs(options) do
				if option_name ~= "request" and option_name ~= "receipt_retention_seconds" then
					return nil, "invalid", "unsupported transaction option: " .. tostring(option_name)
				end
			end
		end
		if kind == "transaction" and (options == nil or options.request == nil) then
			return nil, "invalid", "TransactAsync requires a canonical request value"
		end
		if kind ~= "transaction" and options ~= nil and options.request ~= nil then
			return nil, "invalid", "request is derived from the inbox or outbox arguments"
		end
		local retention = if options ~= nil and options.receipt_retention_seconds ~= nil
			then options.receipt_retention_seconds else DEFAULT_RECEIPT_RETENTION_SECONDS
		if type(retention) ~= "number" or not math.isfinite(retention)
			or retention < 1 or retention > MAX_RECEIPT_RETENTION_SECONDS then
			return nil, "invalid", "receipt_retention_seconds must be from 1 to 31536000"
		end
		if kind == "inbox" then
			if type(input_type) ~= "string" or input_type == "" or #input_type > 100 then
				return nil, "invalid", "inbox message_type must be 1 to 100 characters"
			end
			if input_payload == nil then return nil, "invalid", "inbox payload cannot be nil" end
			local payload_ok, payload_error = validate_serialized_size(input_payload)
			if not payload_ok then return nil, "validation", tostring(payload_error) end
		elseif kind == "outbox" then
			if type(input_type) ~= "string" or input_type == "" or #input_type > 100 then
				return nil, "invalid", "outbox command_type must be 1 to 100 characters"
			end
			if input_payload == nil then return nil, "invalid", "outbox command payload cannot be nil" end
			local payload_ok, payload_error = validate_serialized_size(input_payload)
			if not payload_ok then return nil, "validation", tostring(payload_error) end
		end

		local prepared_events: { OutboxEventRecord }? = nil
		if kind == "outbox" then
			local prepared, prepare_error = prepare_outbox_events(state, operation_id, event_specs)
			if prepared == nil then return nil, "invalid", prepare_error end
			prepared_events = prepared
		end
		local request: JsonValue
		if kind == "transaction" then
			request = { kind = kind, request = copy_value((options :: TransactionOptions).request :: JsonValue) }
		elseif kind == "inbox" then
			request = { kind = kind, message_type = input_type :: string, payload = copy_value(input_payload :: JsonValue) }
		else
			request = {
				kind = kind,
				command_type = input_type :: string,
				payload = copy_value(input_payload :: JsonValue),
				events = copy_value(prepared_events :: { OutboxEventRecord }) :: JsonValue,
			}
		end
		local request_identity, identity_error = canonical_request(state, kind, request)
		if request_identity == nil then return nil, "invalid", identity_error end
		if #request_identity > 16_384 then return nil, "invalid", "canonical request identity exceeds 16384 bytes" end

		local was_unknown = state.state == "unknown"
		if state.retired or closing or state.shutdown or state.tombstoned then
			return nil, "fenced", "record is retired, closing, or tombstoned"
		end
		if state.pending_operation ~= nil then
			return nil, "unknown", "a durable save/renew/release outcome is still unresolved"
		end
		if was_unknown then
			local pending = state.pending_transaction
			if pending == nil then return nil, "unknown", "record has an unrelated unresolved durable outcome" end
			if pending.operation_id ~= operation_id or pending.kind ~= kind then
				return nil, "unknown", "resolve the outstanding transaction before starting another operation"
			end
			if pending.request_identity ~= request_identity then
				return nil, "conflict", "operation_id was already used for a different request while its outcome was unknown"
			end
		elseif state.state ~= "active" then
			return nil, "fenced", "record must have an active session"
		end
		if state.busy or state.queue_busy then return nil, "retryable", "record is busy" end
		if state.token == nil then return nil, "fenced", "record has no active session token" end

		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then return nil, "invalid", deadline_error end
		if not was_unknown and state.change_sequence ~= state.saved_change_sequence then
			local flush_code, flush_message = save_internal(state, "transaction-prerequisite", deadline, nil)
			if flush_code ~= "saved" then
				local status: TransactionStatus = if flush_code == "unknown" then "unknown" else "retryable"
				return nil, status, flush_message or "dirty profile data could not be flushed before transaction"
			end
		end
		if state.state ~= "active" and not was_unknown then return nil, "fenced", "record is no longer active" end
		local token = state.token
		if token == nil then return nil, "fenced", "record has no active session token" end
		local generation = state.generation
		local expected_revision = state.revision
		local write_id = HttpService:GenerateGUID(false)
		local old_data = copy_value(state.data)
		state.busy = true
		state.state = "saving"
		state.current_operation_id = write_id
		local attempts = math.clamp(math.floor(state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS), 1, MAX_RETRY_ATTEMPTS)
		local confirmed: Envelope? = nil
		local confirmed_info: BackendInfo? = nil
		local final_result: JsonValue? = nil
		local final_status: TransactionStatus? = nil
		local final_message: string? = nil

		for attempt = 1, attempts do
			if now_local() >= deadline then
				final_status = "retryable"
				final_message = "transaction deadline exceeded"
				break
			end
			local decision = "not_started"
			local decision_message: string? = nil
			local decision_result: JsonValue? = nil
			local returned, info, update_code, update_message = backend_update(state.backend, function(raw, info_before)
				decision = "not_started"
				decision_message = nil
				decision_result = nil
				local transform_time = session_now_unix(state.backend.mock)
				local envelope, parse_error, current_format = parse_envelope(raw)
				if not current_format or envelope == nil then
					decision = if parse_error == "future implementation version" then "fenced" else "corrupt"
					decision_message = parse_error or "durable envelope is invalid"
					return nil, nil, nil
				end
				if envelope.tombstone ~= nil then
					decision = "fenced"
					decision_message = "profile is tombstoned"
					return nil, nil, nil
				end
				if envelope.schema_version > state.options.schema_version then
					decision = "fenced"
					decision_message = "durable schema is newer than this server supports"
					return nil, nil, nil
				end
				if envelope.schema_version ~= state.options.schema_version then
					decision = "retryable"
					decision_message = "durable schema changed; reopen the profile before transacting"
					return nil, nil, nil
				end
				if not matches_session(envelope, token :: string, generation) then
					decision = "fenced"
					decision_message = "durable session no longer matches the active fencing generation"
					return nil, nil, nil
				end
				local session = envelope.session
				if session == nil or session.lease_until <= transform_time then
					decision = "fenced"
					decision_message = "durable session lease has expired"
					return nil, nil, nil
				end
				if envelope.revision ~= expected_revision then
					local old_receipt = read_receipt(envelope, kind, operation_id)
					if old_receipt ~= nil and old_receipt.expires_at > transform_time then
						if old_receipt.request_identity ~= request_identity then
							decision = "conflict"
							decision_message = "operation_id has already been committed with a different request"
							return nil, nil, nil
						end
						decision = "duplicate"
						decision_result = if old_receipt.result_present then copy_value(old_receipt.result) else nil
							return nil, nil, nil
					end
					decision = "conflict"
					decision_message = "durable revision changed unexpectedly"
					return nil, nil, nil
				end

				local sidecars = protocol.clone(envelope.sidecars) or protocol.empty()
				local receipts = if kind == "inbox" then sidecars.inbox_receipts else sidecars.transaction_receipts
				for receipt_id, receipt in pairs(receipts) do
					if receipt.expires_at <= transform_time then receipts[receipt_id] = nil end
				end
				local previous_receipt = receipts[operation_id]
				if previous_receipt ~= nil then
					if previous_receipt.request_identity ~= request_identity then
						decision = "conflict"
						decision_message = "operation_id has already been used for a different request"
						return nil, nil, nil
					end
					decision = "duplicate"
					decision_result = if previous_receipt.result_present then copy_value(previous_receipt.result) else nil
					return nil, nil, nil
				end
			local receipt_count = 0
				for _ in pairs(receipts) do receipt_count += 1 end
				local max_receipts = if kind == "inbox" then 256 else 256
				if receipt_count >= max_receipts then
					decision = "capacity"
					decision_message = "durable receipt capacity is full; unexpired receipts are never evicted"
					return nil, nil, nil
				end

				local working_data = if envelope.data ~= nil then copy_value(envelope.data) else nil
				if working_data == nil then
					decision = "validation"
					decision_message = "profile data is missing"
					return nil, nil, nil
				end
				local next_data, reducer_result, reducer_error = run_reducer(
					reducer,
					working_data :: JsonValue,
					if kind == "transaction" then nil else copy_value(input_payload)
				)
				if reducer_error ~= nil then
					decision = "validation"
					decision_message = reducer_error
					return nil, nil, nil
				end
				if next_data == nil then
					decision = "validation"
					decision_message = "transaction reducer must return non-nil profile data"
					return nil, nil, nil
				end
				local data_valid, data_error = validate_value(next_data, state.options.validator)
				if not data_valid then
					decision = "validation"
					decision_message = data_error or "transaction data is invalid"
					return nil, nil, nil
				end
				local frozen_data = copy_value(next_data)
				if frozen_data == nil then
					decision = "validation"
					decision_message = "transaction data could not be copied"
					return nil, nil, nil
				end
				local data_ok, data_message = validate_serialized_size(frozen_data)
				if not data_ok then
					decision = "validation"
					decision_message = data_message
					return nil, nil, nil
				end
				local frozen_result: JsonValue? = nil
				local result_present = reducer_result ~= nil
				if result_present then
					frozen_result = copy_value(reducer_result)
					if frozen_result == nil then
						decision = "validation"
						decision_message = "transaction result is invalid"
						return nil, nil, nil
					end
					local result_ok, result_message = validate_serialized_size(frozen_result)
					if not result_ok then
						decision = "validation"
						decision_message = result_message or "transaction result is invalid"
						return nil, nil, nil
					end
					local result_encoded_ok, result_encoded = pcall(function()
						return HttpService:JSONEncode(frozen_result)
					end)
					if not result_encoded_ok or type(result_encoded) ~= "string" or #result_encoded > MAX_TRANSACTION_RESULT_BYTES then
						decision = "validation"
						decision_message = "transaction result exceeds the 4096-byte limit"
						return nil, nil, nil
					end
				end

				local receipt: OperationReceipt = {
					request_identity = request_identity,
					result = frozen_result,
					result_present = result_present,
					committed_revision = envelope.revision + 1,
					created_at = transform_time,
					expires_at = transform_time + retention,
				}
				receipts[operation_id] = receipt
				if kind == "outbox" then
					local events = prepared_events :: { OutboxEventRecord }
					for ordinal, prepared in ipairs(events) do
						local prior = sidecars.outbox_events[prepared.id]
						if prior ~= nil then
							decision = if prior.request_identity == prepared.request_identity then "duplicate" else "conflict"
							decision_message = if prior.request_identity == prepared.request_identity
								then "outbox event already exists after its transaction receipt expired"
								else "stable outbox event ID collides with a different request"
							return nil, nil, nil
						end
						if sidecars.outbox_events[prepared.id] == nil then
							local stored_event = copy_value(prepared) :: OutboxEventRecord
						stored_event.created_at = transform_time
						sidecars.outbox_events[prepared.id] = stored_event
						end
					end
				end
				local sidecars_valid, sidecars_error = protocol.validate(sidecars)
				if not sidecars_valid then
					decision = if string.find(sidecars_error or "", "capacity", 1, true) ~= nil
					or string.find(sidecars_error or "", "encoded-size limit", 1, true) ~= nil
					then "capacity" else "validation"
					decision_message = sidecars_error
					return nil, nil, nil
				end
				local next_envelope: Envelope = {
					implementation_version = protocol.transaction_version,
					schema_version = envelope.schema_version,
					revision = envelope.revision + 1,
					fencing_generation = envelope.fencing_generation,
					created_at = envelope.created_at,
					updated_at = transform_time,
					data = frozen_data,
					user_ids = clone_user_ids(envelope.user_ids or state.user_ids),
					tombstone = nil,
					session = {
						token = session.token,
						generation = session.generation,
						job_id = session.job_id,
						place_id = session.place_id,
						acquired_at = session.acquired_at,
						lease_until = transform_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
					},
					sidecars = sidecars,
					write_id = write_id,
				}
				local envelope_valid, envelope_error = validate_envelope(next_envelope)
				if not envelope_valid then
					decision = "validation"
					decision_message = envelope_error
					return nil, nil, nil
				end
				decision = "committed"
				return next_envelope, next_envelope.user_ids, make_backend_metadata(state.metadata, next_envelope)
			end, deadline, state)

			if update_code ~= nil and update_code ~= "unknown" then
				local mapped = normalize_result_code(update_code) or "unknown"
				if mapped == "fenced" or mapped == "future_schema" then
					final_status = "fenced"
				elseif mapped == "corrupt" then
					final_status = "corrupt"
				elseif mapped == "validation" then
					final_status = "validation"
				elseif mapped == "invalid" then
					final_status = "invalid"
				elseif mapped == "unknown" then
					final_status = "unknown"
				else
					final_status = "retryable"
				end
				final_message = update_message
				if final_status ~= nil then break end
			end
			if decision == "duplicate" or decision == "conflict" or decision == "capacity" or decision == "fenced"
				or decision == "corrupt" or decision == "retryable" or decision == "validation"
			then
				final_status = decision :: TransactionStatus
				final_result = decision_result
				final_message = decision_message
				break
			end

			local function verify_committed(candidate: unknown, candidate_info: BackendInfo?): (boolean, TransactionStatus?)
				local candidate_envelope, candidate_error, candidate_format = parse_envelope(candidate)
				if not candidate_format or candidate_envelope == nil then
					final_message = candidate_error or "transaction response was not a valid envelope"
					return false
				end
				local receipt = read_receipt(candidate_envelope, kind, operation_id)
				if receipt == nil then return false end
				if receipt.request_identity ~= request_identity then
					final_status = "conflict"
					final_message = "operation_id is bound to a different durable request"
					return false, "conflict" :: TransactionStatus
				end
				if not matches_session(candidate_envelope, token :: string, generation)
					or candidate_envelope.session == nil
					or candidate_envelope.session.lease_until <= session_now_unix(state.backend.mock)
				then
					final_status = "fenced"
					final_message = "transaction receipt exists but the active session fence no longer matches"
					return false, "fenced" :: TransactionStatus
				end
				if receipt.committed_revision > candidate_envelope.revision then
					final_status = "unknown"
					final_message = "durable transaction receipt refers to a future revision"
					return false, "unknown" :: TransactionStatus
				end
				confirmed = candidate_envelope
				confirmed_info = candidate_info
				final_result = if receipt.result_present then copy_value(receipt.result) else nil
				return true, nil
			end

			if decision == "duplicate" then
				final_status = "duplicate"
				final_result = decision_result
				final_message = nil
				break
			end
			if returned ~= nil then
				local verified, verification_status = verify_committed(returned, info)
				if verified then
					final_status = "committed"
					break
				end
				if verification_status ~= nil then
					final_status = verification_status :: TransactionStatus
					break
				end
			end

			local raw_after, info_after, read_code, read_message = backend_get(state.backend, false, deadline, state)
			if read_code == nil and raw_after ~= nil then
				local verified, verification_status = verify_committed(raw_after, info_after)
				if verified then
					final_status = "committed"
					break
				end
				if verification_status ~= nil then
					final_status = verification_status :: TransactionStatus
					break
				end
				local latest, latest_error, latest_format = parse_envelope(raw_after)
				if latest_format and latest ~= nil and latest.revision ~= expected_revision then
					final_status = "conflict"
					final_message = latest_error or "durable revision advanced without the expected transaction receipt"
					break
				end
			elseif read_code ~= nil then
				final_message = read_message or update_message or "transaction outcome remains unknown"
			end
			if attempt < attempts and now_local() < deadline then
				task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
			else
				final_status = "unknown"
				final_message = final_message or update_message or "transaction outcome remains unknown; retry only with the same operation ID and request"
			end
		end

		if confirmed ~= nil then
			local confirmed_receipt = read_receipt(confirmed, kind, operation_id)
			if confirmed_receipt == nil or confirmed_receipt.request_identity ~= request_identity then
				state.busy = false
				state.state = "unknown"
				state.pending_transaction = { operation_id = operation_id, kind = kind :: string, request_identity = request_identity }
				state.next_reconciliation = now_local() + 0.25
				return nil, "unknown", "transaction write was observed without a matching durable receipt"
			end
			update_local_from_envelope(state, confirmed, confirmed_info)
			state.saved_change_sequence = state.change_sequence
			state.dirty_since_local = nil
			state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "transaction:" .. kind)
			state.last_successful_write_local = now_local()
			state.next_autosave = now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL)
			state.pending_transaction = nil
			state.next_reconciliation = math.huge
			state.last_reconciliation_category = nil
			state.busy = false
			state.state = "active"
			state.current_operation_id = nil
			state.last_error = nil
			if kind == "inbox" or kind == "outbox" or kind == "transaction" then
				enqueue_change_observation(state, old_data, state.data, write_id, kind)
			end
			complete_deferred_takeover(state)
			return final_result, final_status or "committed", nil
		end

		if final_status == "duplicate" then
			state.busy = false
			state.state = "active"
			state.current_operation_id = nil
			state.pending_transaction = nil
			complete_deferred_takeover(state)
			return final_result, "duplicate", final_message
		end
		local status: TransactionStatus = final_status or "unknown"
		state.busy = false
		state.current_operation_id = nil
		if was_unknown or status == "unknown" then
			state.state = "unknown"
			state.pending_transaction = { operation_id = operation_id, kind = kind :: string, request_identity = request_identity }
			state.next_reconciliation = now_local() + 0.25
			state.last_reconciliation_category = "transaction_outcome_unknown"
		else
			state.state = "active"
			state.pending_transaction = nil
		end
		return nil, status, final_message
	end
end)();

(RecordStore._internals :: { [string]: any }).get_transaction_status = function(
	self: Record,
	operation_id: string,
	request: JsonValue
): TransactionReceiptStatus
	local state = private[self]
	if state == nil then return { code = "invalid", message = "record does not exist" } end
	if state.options.transactional_operations_enabled ~= true then
		return { code = "disabled", message = "transactional operations are disabled for this Record" }
	end
	if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 256 then
		return { code = "invalid", message = "operation_id must be 1 to 256 bytes" }
	end
	if request == nil then return { code = "invalid", message = "request is required for identity-bound status lookup" } end

	local copied_request = copy_value(request)
	if copied_request == nil then return { code = "invalid", message = "request could not be copied" } end
	local request_material: JsonValue = { kind = "transaction", request = copied_request }
	local protocol = prepared_envelope_cache._sidecar_protocol
	local request_identity, identity_error = protocol.canonicalize({
		store_name = state.name,
		scope = state.scope,
		profile_key = state.key,
		operation_kind = "transaction",
		request = request_material,
	})
	if request_identity == nil then return { code = "invalid", message = identity_error } end
	if #request_identity > 16_384 then
		return { code = "invalid", message = "canonical transaction request exceeds 16384 bytes" }
	end

	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then return { code = "invalid", message = deadline_error } end
	local raw, _, read_code, read_message = backend_get(state.backend, false, deadline, nil)
	if read_code ~= nil then
		local normalized = normalize_result_code(read_code)
		local code: TransactionReceiptStatusCode = if normalized == "legacy" then "legacy"
			elseif normalized == "future_schema" then "future_schema"
			elseif normalized == "corrupt" then "corrupt"
			elseif normalized == "not_found" then "not_found"
			elseif normalized == "disabled" then "disabled"
			else "unknown"
		return { code = code, message = read_message or "durable transaction receipt could not be read" }
	end
	if raw == nil then return { code = "not_found", message = "profile envelope does not exist" } end

	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		local code: TransactionReceiptStatusCode = if parse_error == "legacy payload" then "legacy"
			elseif parse_error == "future implementation version" then "future_schema"
			else "corrupt"
		return { code = code, message = parse_error or "durable profile format is unsupported" }
	end
	if envelope == nil then return { code = "corrupt", message = parse_error or "durable profile envelope is invalid" } end
	if envelope.sidecars == nil or envelope.implementation_version < protocol.transaction_version then
		return { code = "unsupported", message = "profile has no transactional receipt sidecars" }
	end

	local receipt = envelope.sidecars.transaction_receipts[operation_id]
	if receipt == nil then return { code = "not_found", message = "transaction receipt was not found" } end
	if receipt.request_identity ~= request_identity then
		return {
			code = "conflict",
			message = "operation_id is bound to a different durable request",
			committed_revision = receipt.committed_revision,
			created_at = receipt.created_at,
			expires_at = receipt.expires_at,
		}
	end
	if receipt.expires_at <= session_now_unix(state.backend.mock) then
		return {
			code = "expired",
			message = "transaction receipt is past its retention deadline",
			committed_revision = receipt.committed_revision,
			created_at = receipt.created_at,
			expires_at = receipt.expires_at,
		}
	end
	if receipt.committed_revision > envelope.revision then
		return {
			code = "unknown",
			message = "transaction receipt refers to a future profile revision",
			committed_revision = receipt.committed_revision,
			created_at = receipt.created_at,
			expires_at = receipt.expires_at,
		}
	end
	if receipt.result_present and receipt.result == nil then
		return { code = "corrupt", message = "transaction result is missing from its durable receipt" }
	end
	return {
		code = "committed",
		result = if receipt.result_present then copy_value(receipt.result) else nil,
		result_present = receipt.result_present,
		committed_revision = receipt.committed_revision,
		created_at = receipt.created_at,
		expires_at = receipt.expires_at,
	}
end

prepared_envelope_cache._outbox_engine = (function()
	local protocol = prepared_envelope_cache._sidecar_protocol
	local MAX_OUTBOX_API_BATCH = 16
	local DEFAULT_OUTBOX_API_BATCH = 8
	local DEFAULT_OUTBOX_PRUNE_BATCH = 16

	local function normalize_limit(value: number?, default_value: number): (number?, string?)
		local selected: unknown = if value == nil then default_value else value
		if type(selected) ~= "number" or not math.isfinite(selected)
			or math.floor(selected) ~= selected or selected < 1 or selected > MAX_OUTBOX_API_BATCH
		then
			return nil, "max_events must be an integer from 1 to " .. tostring(MAX_OUTBOX_API_BATCH)
		end
		return selected :: number, nil
	end

	local function parse_error_code(message: string?): ResultCode
		local detail = string.lower(message or "")
		if string.find(detail, "future") ~= nil or string.find(detail, "newer implementation") ~= nil then
			return "future_schema" :: ResultCode
		end
		if string.find(detail, "legacy") ~= nil then
			return "legacy" :: ResultCode
		end
		return "corrupt" :: ResultCode
	end

	local function sanitize_error(message: string?): string
		local safe = string.gsub(message or "destination did not confirm durable acceptance", "[^ -~]", "?")
		return string.sub(safe, 1, MAX_QUEUE_ERROR_LENGTH)
	end

	local function to_public_event(event: OutboxEventRecord): OutboxEvent?
		local payload = copy_value(event.payload)
		if payload == nil then return nil end
		return {
			EventId = event.id,
			EventType = event.event_type,
			PayloadVersion = event.payload_version,
			Payload = payload,
			DestinationStoreName = event.destination_store_name,
			DestinationScope = event.destination_scope,
			DestinationProfileKey = event.destination_profile_key,
			DestinationUserId = event.destination_user_id,
			CorrelationId = event.correlation_id,
			CausationId = event.causation_id,
			CreatedAt = event.created_at,
			Attempts = event.attempts,
			State = event.state,
			LastError = event.last_error,
			DeliveredAt = event.delivered_at,
			DestinationReceiptId = event.destination_receipt_id,
		}
	end

	local function get_entries(
		self: Record,
		max_events: number?
	): ({ OutboxEntry }, ResultCode, string?)
		local state = private[self]
		if state == nil or state.retired then
			return {}, "invalid", "record does not exist or has been retired"
		end
		local limit, limit_error = normalize_limit(max_events, DEFAULT_OUTBOX_API_BATCH)
		if limit == nil then return {}, "invalid", limit_error end
		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then return {}, "invalid", deadline_error end
		local raw, _, read_code, read_message = backend_get(state.backend, false, deadline, nil)
		if read_code ~= nil then
			return {}, normalize_result_code(read_code) or "unknown", read_message
		end
		if raw == nil then return {}, "not_found", "source profile does not exist" end

		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then return {}, parse_error_code(parse_error), parse_error end
		if envelope == nil then return {}, "corrupt", parse_error or "source profile envelope is invalid" end
		if envelope.sidecars == nil or envelope.implementation_version < protocol.transaction_version then
			return {}, "success", nil
		end

		local entries: { OutboxEntry } = {}
		for _, event in pairs(envelope.sidecars.outbox_events) do
			if event.state == "pending" or event.state == "unknown" then
				local copied = copy_value(event)
				if type(copied) ~= "table" then return {}, "corrupt", "outbox event could not be copied" end
				local stored = copied :: OutboxEventRecord
				local public = to_public_event(stored)
				if public == nil then return {}, "corrupt", "outbox payload could not be copied" end
				entries[#entries + 1] = { stored = stored, public = public }
			end
		end
		table.sort(entries, function(left, right)
			if left.stored.created_at ~= right.stored.created_at then
				return left.stored.created_at < right.stored.created_at
			end
			return left.stored.id < right.stored.id
		end)
		while #entries > limit do table.remove(entries) end
		return entries, "success", nil
	end

	local function get(self: Record, max_events: number?): ({ OutboxEvent }, ResultCode, string?)
		local entries: { OutboxEntry }, code: ResultCode, message: string? = get_entries(self, max_events)
		local result: { OutboxEvent } = {}
		for _, entry in ipairs(entries) do result[#result + 1] = entry.public end
		return result, code, message
	end

	local function read_current_event(
		state: InternalState,
		event_id: string,
		expected_request_identity: string,
		deadline: number
	): (OutboxEventRecord?, ResultCode?, string?)
		local raw, _, read_code, read_message = backend_get(state.backend, false, deadline, nil)
		if read_code ~= nil then return nil, normalize_result_code(read_code) or "unknown", read_message end
		if raw == nil then return nil, "not_found", "source profile does not exist" end
		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then return nil, parse_error_code(parse_error), parse_error end
		if envelope == nil then return nil, "corrupt", parse_error or "source profile envelope is invalid" end
		if envelope.sidecars == nil or envelope.implementation_version < protocol.transaction_version then
			return nil, "disabled", "source profile does not contain transactional sidecars"
		end
		local current = envelope.sidecars.outbox_events[event_id]
		if current == nil then return nil, "not_found", "outbox event no longer exists" end
		if current.request_identity ~= expected_request_identity then
			return nil, "conflict", "outbox event identity changed during dispatch"
		end
		return current, nil, nil
	end

	local function classify_update_result(
		state: InternalState,
		expected_event: OutboxEventRecord,
		target_state: "pending" | "unknown" | "delivered",
		receipt_id: string?,
		raw: unknown
	): (ResultCode, string?, boolean)
		if raw == nil then return "not_found", "source profile does not exist", false end
		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then
			return parse_error_code(parse_error), parse_error, false
		end
		if envelope == nil then return "corrupt", parse_error or "source profile envelope is invalid", false end
		if envelope.sidecars == nil or envelope.implementation_version < protocol.transaction_version then
			return "disabled", "source profile does not contain transactional sidecars", false
		end
		local current = envelope.sidecars.outbox_events[expected_event.id]
		if current == nil then return "not_found", "outbox event no longer exists", false end
		if current.request_identity ~= expected_event.request_identity then
			return "conflict", "outbox event identity changed during dispatch", false
		end
		if current.state == "delivered" then
			if target_state == "delivered" and current.destination_receipt_id ~= receipt_id then
				return "conflict", "event was delivered with a different destination receipt ID", false
			end
			return "success", nil, true
		end
		if current.state == "blocked" then
			return "disabled", "outbox event is blocked pending operator review", false
		end
		if current.attempts > expected_event.attempts and current.state == target_state then
			return "success", nil, false
		end
		return "unknown", "outbox attempt status was not durably confirmed", false
	end

	local function update_event(
		self: Record,
		expected_event: OutboxEventRecord,
		target_state: "pending" | "unknown" | "delivered",
		receipt_id: string?,
		reason: string?
	): (ResultCode, string?, boolean)
		local state = private[self]
		if state == nil or state.retired then return "invalid", "record does not exist or has been retired", false end
		if target_state == "delivered"
			and (type(receipt_id) ~= "string" or receipt_id == "" or #receipt_id > 256)
		then
			return "validation", "a confirmed delivery requires a non-empty destination receipt ID of at most 256 bytes", false
		end
		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then return "invalid", deadline_error, false end
		local occurred_at = session_now_unix(state.backend.mock)
		local sanitized_error = sanitize_error(reason)

		local returned_raw, _, update_code, update_message = backend_update(state.backend, function(raw, info)
			if raw == nil then return nil, nil, nil end
			local envelope, _, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then return nil, nil, nil end
			if envelope.sidecars == nil or envelope.implementation_version < protocol.transaction_version then
				return nil, nil, nil
			end
			local sidecars = protocol.clone(envelope.sidecars)
			if sidecars == nil then return nil, nil, nil end
			local current = sidecars.outbox_events[expected_event.id]
			if current == nil or current.request_identity ~= expected_event.request_identity
				or current.state == "delivered" or current.state == "blocked"
			then
				return nil, nil, nil
			end

			local updated_value = copy_value(current)
			if type(updated_value) ~= "table" then return nil, nil, nil end
			local updated = updated_value :: OutboxEventRecord
			updated.attempts += 1
			updated.state = target_state
			updated.last_error = if target_state == "delivered" then nil else sanitized_error
			updated.destination_receipt_id = if target_state == "delivered" then receipt_id else nil
			updated.delivered_at = if target_state == "delivered" then occurred_at else nil
			sidecars.outbox_events[expected_event.id] = updated

			local sidecars_valid = protocol.validate(sidecars)
			if not sidecars_valid then return nil, nil, nil end
			local raw_value = copy_value(raw)
			if type(raw_value) ~= "table" then return nil, nil, nil end
			(raw_value :: { [string]: any }).sidecars = sidecars
			local raw_valid = validate_serialized_size(raw_value)
			if not raw_valid then return nil, nil, nil end
			return {
				[prepared_envelope_cache] = true,
				raw_value = raw_value,
			}, clone_user_ids(if info ~= nil then info.UserIds else envelope.user_ids or state.user_ids),
				clone_metadata(if info ~= nil then info.RawMetadata else state.metadata)
		end, deadline, nil)

		if update_code == "unknown" then
			local current, read_code, read_message = read_current_event(
				state, expected_event.id, expected_event.request_identity, deadline
			)
			if read_code ~= nil then return "unknown", read_message or update_message or "outbox update result is unknown", false end
			if current == nil then return "unknown", update_message or "outbox update result is unknown", false end
			if current.state == "delivered" then
				if target_state == "delivered" and current.destination_receipt_id ~= receipt_id then
					return "conflict", "event was delivered with a different destination receipt ID", false
				end
				return "success", nil, true
			end
			if current.state == target_state and current.attempts > expected_event.attempts then
				return "success", nil, false
			end
			return "unknown", update_message or "outbox update result is unknown", false
		end
		if update_code ~= nil then
			return normalize_result_code(update_code) or "unknown", update_message, false
		end
		return classify_update_result(state, expected_event, target_state, receipt_id, returned_raw)
	end

	local function dispatch(
		self: Record,
		dispatcher: OutboxDispatcher,
		max_events: number?
	): (number, ResultCode, string?)
		if type(dispatcher) ~= "function" then return 0, "invalid", "dispatcher must be a function" end
		local entries: { OutboxEntry }, read_code: ResultCode, read_message: string? = get_entries(self, max_events)
		if read_code ~= "success" then return 0, read_code, read_message end
		local delivered_count = 0
		local failed_count = 0
		local ambiguous = false
		local first_error: string? = nil

		for _, entry in ipairs(entries) do
			local stored = entry.stored
			local public = entry.public
			local callback_ok, accepted, receipt_id = pcall(dispatcher, public)
			local target_state: "pending" | "unknown" | "delivered"
			local reason: string?
			if not callback_ok then
				target_state = "unknown"
				reason = tostring(accepted)
				ambiguous = true
			elseif accepted == true then
				if type(receipt_id) == "string" and receipt_id ~= "" and #receipt_id <= 256 then
					target_state = "delivered"
				else
					target_state = "unknown"
					reason = "destination acknowledged without a valid durable receipt ID"
					ambiguous = true
				end
			else
				target_state = "pending"
				reason = if type(receipt_id) == "string" then receipt_id else "destination did not confirm acceptance"
			end

			local status, status_message, confirmed = update_event(self, stored, target_state,
				if target_state == "delivered" then receipt_id else nil, reason)
			if confirmed then
				delivered_count += 1
			elseif status == "success" then
				if target_state == "pending" then failed_count += 1 end
				first_error = first_error or reason or status_message
			elseif status == "duplicate" then
				first_error = first_error or status_message or "duplicate outbox result was not confirmed"
			else
				first_error = first_error or status_message or "outbox delivery status could not be confirmed"
				if status == "unknown" then return delivered_count, "unknown", first_error end
				if status == "fenced" or status == "corrupt" or status == "future_schema"
					or status == "legacy" or status == "invalid" or status == "conflict"
					or status == "budget" or status == "busy" or status == "retry_exhausted"
					or status == "disabled" or status == "not_found"
				then
					return delivered_count, status, first_error
				end
			end
		end

		if ambiguous then return delivered_count, "unknown", first_error end
		if failed_count > 0 then return delivered_count, "retry_exhausted", first_error end
		return delivered_count, "success", nil
	end

	local function count_missing_events(
		raw: unknown,
		event_ids: { string }
	): (number?, ResultCode?, string?)
		if raw == nil then return nil, "not_found", "source profile does not exist" end
		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then return nil, parse_error_code(parse_error), parse_error end
		if envelope == nil then return nil, "corrupt", parse_error or "source profile envelope is invalid" end
		if envelope.sidecars == nil or envelope.implementation_version < protocol.transaction_version then
			return nil, "disabled", "source profile does not contain transactional sidecars"
		end
		local removed = 0
		for _, event_id in ipairs(event_ids) do
			if envelope.sidecars.outbox_events[event_id] == nil then removed += 1 end
		end
		return removed, nil, nil
	end

	local function prune(
		self: Record,
		delivered_before_unix: number,
		max_events: number?
	): (number, ResultCode, string?)
		local state = private[self]
		if state == nil or state.retired then return 0, "invalid", "record does not exist or has been retired" end
		if type(delivered_before_unix) ~= "number" or not math.isfinite(delivered_before_unix) then
			return 0, "invalid", "delivered_before_unix must be a finite Unix timestamp in seconds"
		end
		local limit_value: unknown = if max_events == nil then DEFAULT_OUTBOX_PRUNE_BATCH else max_events
		if type(limit_value) ~= "number" or not math.isfinite(limit_value)
			or math.floor(limit_value) ~= limit_value or limit_value < 1 or limit_value > MAX_OUTBOX_API_BATCH
		then
			return 0, "invalid", "max_events must be an integer from 1 to " .. tostring(MAX_OUTBOX_API_BATCH)
		end
		local limit = limit_value :: number
		local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
		if deadline == nil then return 0, "invalid", deadline_error end

		local initial_raw, _, initial_code, initial_message = backend_get(state.backend, false, deadline, nil)
		if initial_code ~= nil then
			return 0, normalize_result_code(initial_code) or "unknown", initial_message
		end
		if initial_raw == nil then return 0, "not_found", "source profile does not exist" end
		local initial_envelope, initial_error, initial_format = parse_envelope(initial_raw)
		if not initial_format then return 0, parse_error_code(initial_error), initial_error end
		if initial_envelope == nil then return 0, "corrupt", initial_error or "source profile envelope is invalid" end
		if initial_envelope.sidecars == nil
			or initial_envelope.implementation_version < protocol.transaction_version
		then
			return 0, "success", nil
		end

		local eligible: { { id: string, delivered_at: number } } = {}
		for id, event in pairs(initial_envelope.sidecars.outbox_events) do
			if event.state == "delivered" and event.delivered_at ~= nil
				and event.delivered_at < delivered_before_unix
			then
				eligible[#eligible + 1] = { id = id, delivered_at = event.delivered_at }
			end
		end
		table.sort(eligible, function(left, right)
			if left.delivered_at ~= right.delivered_at then return left.delivered_at < right.delivered_at end
			return left.id < right.id
		end)
		while #eligible > limit do table.remove(eligible) end
		if #eligible == 0 then
			return 0, "duplicate", "no delivered outbox events are eligible for the requested retention cutoff"
		end
		local candidate_ids: { string } = {}
		for _, event in ipairs(eligible) do candidate_ids[#candidate_ids + 1] = event.id end

		local returned_raw, _, update_code, update_message = backend_update(state.backend, function(raw, info)
			if raw == nil then return nil, nil, nil end
			local envelope, _, current_format = parse_envelope(raw)
			if not current_format or envelope == nil or envelope.sidecars == nil
				or envelope.implementation_version < protocol.transaction_version
			then
				return nil, nil, nil
			end
			local sidecars = protocol.clone(envelope.sidecars)
			if sidecars == nil then return nil, nil, nil end
			local removed_any = false
			for _, event_id in ipairs(candidate_ids) do
				local event = sidecars.outbox_events[event_id]
				if event ~= nil and event.state == "delivered" and event.delivered_at ~= nil
					and event.delivered_at < delivered_before_unix
				then
					sidecars.outbox_events[event_id] = nil
					removed_any = true
				end
			end
			if not removed_any then return nil, nil, nil end
			local sidecars_valid = protocol.validate(sidecars)
			if not sidecars_valid then return nil, nil, nil end
			local raw_value = copy_value(raw)
			if type(raw_value) ~= "table" then return nil, nil, nil end
			(raw_value :: { [string]: any }).sidecars = sidecars
			local raw_valid = validate_serialized_size(raw_value)
			if not raw_valid then return nil, nil, nil end
			return {
				[prepared_envelope_cache] = true,
				raw_value = raw_value,
			}, clone_user_ids(if info ~= nil then info.UserIds else envelope.user_ids or state.user_ids),
				clone_metadata(if info ~= nil then info.RawMetadata else state.metadata)
		end, deadline, nil)

		if update_code ~= nil and update_code ~= "unknown" then
			return 0, normalize_result_code(update_code) or "unknown", update_message
		end
		if update_code == "unknown" then
			local current_raw, _, read_code, read_message = backend_get(state.backend, false, deadline, nil)
			if read_code ~= nil then return 0, "unknown", read_message or update_message end
			local removed, classify_code, classify_message = count_missing_events(current_raw, candidate_ids)
			if removed == nil then return 0, "unknown", classify_message or update_message or tostring(classify_code) end
			if removed > 0 then return removed, "success", nil end
			return 0, "unknown", update_message or "outbox cleanup outcome remains unknown"
		end
		local removed, classify_code, classify_message = count_missing_events(returned_raw, candidate_ids)
		if removed == nil then return 0, (classify_code or "unknown") :: ResultCode, classify_message end
		if removed > 0 then return removed, "success", nil end
		return 0, "duplicate", "no delivered outbox events were removed"
	end

	return {
		get = get,
		dispatch = dispatch,
		prune = prune,
	}
end)()

RecordStore._internals.get_session_status_internal = function(
	name: string,
	scope: string,
	key: string,
	operation_deadline: number?,
	mock: boolean
): (SessionStatus?, ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	local backend = make_backend(name, scope, key, mock)
	local raw, _, read_result, read_message = backend_get(backend, false, deadline)
	if read_result ~= nil then
		return nil, normalize_result_code(read_result) or "unknown", read_message
	end

	local observed_at = session_now_unix(mock)
	local status: SessionStatus = {
		StoreName = name,
		Scope = scope,
		ProfileKey = key,
		Observation = "not_found",
		ObservedAt = observed_at,
		Generation = nil,
		Revision = nil,
		OwnerJobId = nil,
		OwnerPlaceId = nil,
		AcquiredAt = nil,
		LeaseUntil = nil,
		LeaseRemainingSeconds = nil,
		LeaseAppearsAvailable = true,
		IsAuthoritativeOwnershipDecision = false,
	}
	if raw == nil then
		return status, "not_found", "record does not exist"
	end

	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		local result: ResultCode = if parse_error == "legacy payload" then "legacy"
			elseif parse_error == "future implementation version" then "future_schema" else "corrupt"
		return nil, result, parse_error or "durable envelope is invalid"
	end
	if envelope == nil then
		return nil, "corrupt", parse_error or "durable envelope is missing"
	end

	status.Generation = envelope.fencing_generation
	status.Revision = envelope.revision
	if envelope.tombstone ~= nil then
		status.Observation = "tombstoned"
		status.LeaseAppearsAvailable = false
		return status, "success", nil
	end

	local session = envelope.session
	if session == nil then
		status.Observation = "no_session"
		return status, "success", nil
	end

	local remaining = session.lease_until - observed_at
	status.OwnerJobId = session.job_id
	status.OwnerPlaceId = session.place_id
	status.AcquiredAt = session.acquired_at
	status.LeaseUntil = session.lease_until
	status.LeaseRemainingSeconds = math.max(0, remaining)
	if remaining > 0 then
		status.Observation = "active_lease_observed"
		status.LeaseAppearsAvailable = false
	else
		status.Observation = "expired_lease_observed"
		status.LeaseAppearsAvailable = true
	end
	return status, "success", nil
end

RecordStore.get_session_status_async = (function()
	local helper: SessionStatusResolver = RecordStore._internals.get_session_status_internal
	return function(
		name: string,
		scope: string,
		key: string,
		operation_deadline: number?
	): (SessionStatus?, ResultCode, string?)
			return helper(name, scope, key, operation_deadline, false)
		end
end)()

RecordStore._internals.get_session_status_mock_async = (function()
	local helper: SessionStatusResolver = RecordStore._internals.get_session_status_internal
	return function(
		name: string,
		scope: string,
		key: string,
		operation_deadline: number?
	): (SessionStatus?, ResultCode, string?)
		return helper(name, scope, key, operation_deadline, true)
	end
end)()

RecordStore._internals.profile_doctor = (function()
	local function normalize_options(options: ProfileDoctorOptions?): (ProfileDoctorOptions?, string?)
		if options ~= nil and type(options) ~= "table" then
			return nil, "Profile Doctor options must be a table"
		end
		local normalized: ProfileDoctorOptions = if options == nil then {} else table.clone(options)
		local allowed = {
			operation_deadline = true,
			legacy_decoder = true,
			max_nodes = true,
			max_depth = true,
			max_changes = true,
		}
		if options ~= nil then
			for key in pairs(options) do
				if not allowed[key] then
					return nil, "unsupported Profile Doctor option: " .. tostring(key)
				end
			end
		end
		if normalized.legacy_decoder ~= nil and type(normalized.legacy_decoder) ~= "function" then
			return nil, "legacy_decoder must be a function"
		end
		if normalized.max_nodes == nil then normalized.max_nodes = 4096 end
		if normalized.max_depth == nil then normalized.max_depth = 32 end
		if normalized.max_changes == nil then normalized.max_changes = 256 end
		if type(normalized.max_nodes) ~= "number"
			or not math.isfinite(normalized.max_nodes)
			or math.floor(normalized.max_nodes) ~= normalized.max_nodes
			or normalized.max_nodes < 1
			or normalized.max_nodes > 50000
		then
			return nil, "max_nodes must be an integer from 1 to 50000"
		end
		if type(normalized.max_depth) ~= "number"
			or not math.isfinite(normalized.max_depth)
			or math.floor(normalized.max_depth) ~= normalized.max_depth
			or normalized.max_depth < 1
			or normalized.max_depth > 64
		then
			return nil, "max_depth must be an integer from 1 to 64"
		end
		if type(normalized.max_changes) ~= "number"
			or not math.isfinite(normalized.max_changes)
			or math.floor(normalized.max_changes) ~= normalized.max_changes
			or normalized.max_changes < 1
			or normalized.max_changes > 2048
		then
			return nil, "max_changes must be an integer from 1 to 2048"
		end
		return normalized, nil
	end

	local function classify_read(
		snapshot: Snapshot?,
		read_result: ResultCode,
		observed_at: number
	): ProfileDoctorClassification
		if read_result == "not_found" then return "missing" end
		if read_result == "legacy" then return "legacy" end
		if read_result == "future_schema" then return "future_schema" end
		if read_result == "corrupt" then return "corrupt" end
		if snapshot == nil then return "unreadable" end
		if snapshot.Tombstoned then return "tombstoned" end
		if snapshot.LeaseUntil ~= nil then
			return if snapshot.LeaseUntil > observed_at then "active_session" else "expired_session"
		end
		return "no_session"
	end

	local function summarize_data(data: JsonValue?, max_nodes: number, max_depth: number): (number, number, boolean, number?, boolean)
		if data == nil then
			return 0, 0, false, 0, true
		end
		local node_count = 0
		local deepest = 0
		local truncated = false
		local active_tables: { [any]: boolean } = {}
		local function visit(value: unknown, depth: number)
			if node_count >= max_nodes then
				truncated = true
				return
			end
			node_count += 1
			deepest = math.max(deepest, depth)
			if type(value) ~= "table" then return end
			local current = value :: { [any]: unknown }
			if active_tables[current] then
				truncated = true
				return
			end
			if depth >= max_depth then
				if next(current) ~= nil then truncated = true end
				return
			end
			active_tables[current] = true
			for _, child in pairs(current) do
				if node_count >= max_nodes then
					truncated = true
					break
				end
				visit(child, depth + 1)
				if truncated and node_count >= max_nodes then break end
			end
			active_tables[current] = nil
		end
		visit(data, 0)

		local encoded_bytes: number? = nil
		local size_available = false
		if not truncated then
			local encoded_ok, encoded_value = pcall(function()
				return HttpService:JSONEncode(encode_non_finite_numbers(data))
			end)
			if encoded_ok and type(encoded_value) == "string" then
				encoded_bytes = #encoded_value
				size_available = true
			end
		end
		return node_count, deepest, truncated, encoded_bytes, size_available
	end

	local function inspect(
		name: string,
		scope: string,
		key: string,
		options: ProfileDoctorOptions?,
		reader: any,
		mock: boolean
	): (ProfileInspection?, ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then return nil, "invalid", identity_message end
		local normalized, options_error = normalize_options(options)
		if normalized == nil then return nil, "invalid", options_error end
		local deadline, deadline_error = resolve_operation_deadline(normalized.operation_deadline)
		if deadline == nil then return nil, "invalid", deadline_error end

		local remaining_deadline = deadline - now_local()
		if remaining_deadline <= 0 then return nil, "budget", "Profile Doctor inspection deadline expired" end
		local snapshot, read_result, read_message = reader(
			name,
			scope,
			key,
			remaining_deadline,
			normalized.legacy_decoder
		)
		if read_result == "invalid" then return nil, "invalid", read_message end
		local code: ResultCode = (normalize_result_code(read_result) or "unknown") :: ResultCode
		local observed_at = session_now_unix(mock)
		local classification: ProfileDoctorClassification = classify_read(snapshot, code, observed_at)
		local node_count: number? = nil
		local data_depth: number? = nil
		local encoded_bytes: number? = nil
		local size_available = false
		local summary_truncated = false
		if snapshot ~= nil then
			node_count, data_depth, summary_truncated, encoded_bytes, size_available =
				summarize_data(snapshot.Data, normalized.max_nodes :: number, normalized.max_depth :: number)
		end
		local report: ProfileInspection = {
			StoreName = name,
			Scope = scope,
			ProfileKey = key,
			ObservedAt = observed_at,
			Consistency = "point_in_time_non_authoritative",
			Classification = classification,
			ReadResult = code,
			SchemaVersion = if snapshot ~= nil then snapshot.SchemaVersion else nil,
			Revision = if snapshot ~= nil then snapshot.Revision else nil,
			Generation = if snapshot ~= nil then snapshot.Generation else nil,
			CreatedAt = if snapshot ~= nil then snapshot.CreatedAt else nil,
			UpdatedAt = if snapshot ~= nil then snapshot.UpdatedAt else nil,
			Tombstoned = if snapshot ~= nil then snapshot.Tombstoned else nil,
			SessionActive = if snapshot ~= nil then
				snapshot.LeaseUntil ~= nil and snapshot.LeaseUntil > observed_at and not snapshot.Tombstoned
				else nil,
			LeaseUntil = if snapshot ~= nil then snapshot.LeaseUntil else nil,
			OwnerJobId = if snapshot ~= nil then snapshot.SessionJobId else nil,
			OwnerPlaceId = if snapshot ~= nil then snapshot.SessionPlaceId else nil,
			BackendVersion = if snapshot ~= nil then snapshot.BackendVersion else nil,
			DataNodeCount = node_count,
			DataDepth = data_depth,
			DataEncodedBytes = encoded_bytes,
			DataSizeAvailable = size_available,
			DataSummaryTruncated = summary_truncated,
		}
		return report, code, read_message
	end

	local function diff(
		name: string,
		scope: string,
		key: string,
		before_version: string,
		after_version: string,
		options: ProfileDoctorOptions?,
		version_reader: any
	): (ProfileVersionDiff?, ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then return nil, "invalid", identity_message end
		if type(before_version) ~= "string" or before_version == "" then
			return nil, "invalid", "before_version must be a non-empty string"
		end
		if type(after_version) ~= "string" or after_version == "" then
			return nil, "invalid", "after_version must be a non-empty string"
		end
		local normalized, options_error = normalize_options(options)
		if normalized == nil then return nil, "invalid", options_error end
		local deadline, deadline_error = resolve_operation_deadline(normalized.operation_deadline)
		if deadline == nil then return nil, "invalid", deadline_error end

		local before_remaining = deadline - now_local()
		if before_remaining <= 0 then return nil, "budget", "Profile Doctor diff deadline expired before first version read" end
		local before_snapshot, before_result, before_message = version_reader(
			name, scope, key, before_version, before_remaining, normalized.legacy_decoder
		)
		if before_snapshot == nil or (before_result ~= "success" and before_result ~= "legacy") then
			return nil, normalize_result_code(before_result) or "unknown", before_message
		end
		local after_remaining = deadline - now_local()
		if after_remaining <= 0 then return nil, "budget", "Profile Doctor diff deadline expired before second version read" end
		local after_snapshot, after_result, after_message = version_reader(
			name, scope, key, after_version, after_remaining, normalized.legacy_decoder
		)
		if after_snapshot == nil or (after_result ~= "success" and after_result ~= "legacy") then
			return nil, normalize_result_code(after_result) or "unknown", after_message
		end

		local changes: { ProfileDiffChange } = {}
		local visited_nodes = 0
		local truncated = false
		local node_limit = normalized.max_nodes :: number
		local depth_limit = normalized.max_depth :: number
		local change_limit = normalized.max_changes :: number

		local function child_path(parent: string, child_key: string | number): string
			if type(child_key) == "number" then
				return parent .. "[" .. tostring(child_key) .. "]"
			end
			if string.match(child_key, "^[%a_][%w_]*$") then
				return parent .. "." .. child_key
			end
			local encoded_ok, encoded_key = pcall(function()
				return HttpService:JSONEncode(child_key)
			end)
			if encoded_ok and type(encoded_key) == "string" then
				return parent .. "[" .. encoded_key .. "]"
			end
			return parent .. "[<key>]"
		end

		local function append_change(
			path: string,
			kind: "added" | "removed" | "changed",
			before_value: unknown,
			after_value: unknown,
			before_present: boolean,
			after_present: boolean
		): boolean
			if #changes >= change_limit then
				truncated = true
				return false
			end
			changes[#changes + 1] = {
				Path = string.sub(path, 1, 512),
				Kind = kind,
				BeforeType = if before_present then typeof(before_value) else nil,
				AfterType = if after_present then typeof(after_value) else nil,
			}
			return true
		end

		local function visit(
			before_value: unknown,
			after_value: unknown,
			path: string,
			depth: number,
			before_present: boolean,
			after_present: boolean
		)
			if truncated then return end
			if visited_nodes >= node_limit then
				truncated = true
				return
			end
			visited_nodes += 1
			if not before_present then
				append_change(path, "added", nil, after_value, false, true)
				return
			end
			if not after_present then
				append_change(path, "removed", before_value, nil, true, false)
				return
			end
			if before_value == after_value then return end
			if type(before_value) == "number" and type(after_value) == "number"
				and math.isnan(before_value) and math.isnan(after_value)
			then
				return
			end
			if typeof(before_value) == "buffer" or typeof(after_value) == "buffer" then
				if typeof(before_value) == "buffer" and typeof(after_value) == "buffer"
					and buffer.tostring(before_value :: buffer) == buffer.tostring(after_value :: buffer)
				then
					return
				end
				append_change(path, "changed", before_value, after_value, true, true)
				return
			end
			if type(before_value) ~= "table" or type(after_value) ~= "table" then
				append_change(path, "changed", before_value, after_value, true, true)
				return
			end
			local before_table = before_value :: { [string | number]: JsonValue }
			local after_table = after_value :: { [string | number]: JsonValue }
			if next(before_table) == nil and next(after_table) == nil then return end
			if depth >= depth_limit then
				truncated = true
				append_change(path, "changed", before_value, after_value, true, true)
				return
			end

			local key_set: { [string | number]: boolean } = {}
			for child_key in pairs(before_table) do key_set[child_key] = true end
			for child_key in pairs(after_table) do key_set[child_key] = true end
			local ordered_keys: { string | number } = {}
			for child_key in pairs(key_set) do
				ordered_keys[#ordered_keys + 1] = child_key
			end
			table.sort(ordered_keys, function(left, right)
				if type(left) ~= type(right) then return type(left) < type(right) end
				if type(left) == "number" then return (left :: number) < (right :: number) end
				return (left :: string) < (right :: string)
			end)
			for _, child_key in ipairs(ordered_keys) do
				if truncated then return end
				local before_child = before_table[child_key]
				local after_child = after_table[child_key]
				visit(
					before_child,
					after_child,
					child_path(path, child_key),
					depth + 1,
					before_child ~= nil,
					after_child ~= nil
				)
			end
		end

		visit(
			before_snapshot.Data,
			after_snapshot.Data,
			"$",
			0,
			before_snapshot.Data ~= nil,
			after_snapshot.Data ~= nil
		)
		local report: ProfileVersionDiff = {
			StoreName = name,
			Scope = scope,
			ProfileKey = key,
			BeforeVersion = before_version,
			AfterVersion = after_version,
			BeforeRevision = before_snapshot.Revision,
			AfterRevision = after_snapshot.Revision,
			BeforeSchemaVersion = before_snapshot.SchemaVersion,
			AfterSchemaVersion = after_snapshot.SchemaVersion,
			ObservedAt = now_unix(),
			Consistency = "bounded_historical_diff",
			VisitedNodes = visited_nodes,
			Truncated = truncated,
			Changes = changes,
		}
		return report, if before_result == "legacy" or after_result == "legacy" then "legacy" else "success", nil
	end

	return {
		inspect = inspect,
		diff = diff,
		summarize_data = summarize_data,
	}
end)()

RecordStore.inspect_profile_async = (function()
	local inspect = RecordStore._internals.profile_doctor.inspect
	local reader = RecordStore.read_async
	return function(
		name: string,
		scope: string,
		key: string,
		options: ProfileDoctorOptions?
	): (ProfileInspection?, ResultCode, string?)
		return inspect(name, scope, key, options, reader, false)
	end
end)()

RecordStore.diff_profile_versions_async = (function()
	local diff = RecordStore._internals.profile_doctor.diff
	local version_reader = RecordStore.get_version_async
	return function(
		name: string,
		scope: string,
		key: string,
		before_version: string,
		after_version: string,
		options: ProfileDoctorOptions?
	): (ProfileVersionDiff?, ResultCode, string?)
		return diff(name, scope, key, before_version, after_version, options, version_reader)
	end
end)()

RecordStore._internals.migration_registry = (function()
	local registries: { [string]: { [string]: MigrationRegistration } } = {}
	local summarize_profile_data = RecordStore._internals.profile_doctor.summarize_data
	local MAX_MIGRATIONS_PER_STORE = 128
	local MAX_SCHEMA_VERSION = 1_000_000

	local function valid_version(value: unknown): boolean
		return type(value) == "number"
			and math.isfinite(value)
			and math.floor(value) == value
			and value >= 0
			and value <= MAX_SCHEMA_VERSION
	end

	local function normalize_registration(value: unknown): (MigrationRegistration?, string?)
		if type(value) ~= "table" then
			return nil, "migration registration must be a table"
		end
		local raw = value :: { [string]: unknown }
		local allowed = {
			id = true,
			from_version = true,
			to_version = true,
			implementation_revision = true,
			compatible_schema_min = true,
			compatible_schema_max = true,
			transform = true,
			validator = true,
		}
		for key in pairs(raw) do
			if not allowed[key] then
				return nil, "unsupported migration registration field: " .. tostring(key)
			end
		end
		if type(raw.id) ~= "string" or raw.id == "" or #raw.id > 96 then
			return nil, "migration id must be 1 to 96 characters"
		end
		if not valid_version(raw.from_version) or not valid_version(raw.to_version) then
			return nil, "migration versions must be integers from 0 to 1000000"
		end
		local from_version = raw.from_version :: number
		local to_version = raw.to_version :: number
		if to_version <= from_version then
			return nil, "migration edges must move to a strictly newer schema version"
		end
		if type(raw.implementation_revision) ~= "string"
			or raw.implementation_revision == ""
			or #raw.implementation_revision > 128
		then
			return nil, "implementation_revision must be 1 to 128 characters"
		end
		if not valid_version(raw.compatible_schema_min)
			or not valid_version(raw.compatible_schema_max)
		then
			return nil, "compatibility bounds must be schema-version integers from 0 to 1000000"
		end
		local compatible_min = raw.compatible_schema_min :: number
		local compatible_max = raw.compatible_schema_max :: number
		if compatible_min > compatible_max
			or from_version < compatible_min
			or to_version > compatible_max
		then
			return nil, "migration versions fall outside the declared compatibility range"
		end
		if type(raw.transform) ~= "function" then
			return nil, "migration transform must be a function"
		end
		if raw.validator ~= nil and type(raw.validator) ~= "function" then
			return nil, "migration validator must be a function or nil"
		end
		return {
			id = raw.id,
			from_version = from_version,
			to_version = to_version,
			implementation_revision = raw.implementation_revision,
			compatible_schema_min = compatible_min,
			compatible_schema_max = compatible_max,
			transform = raw.transform :: Migration,
			validator = raw.validator :: Validator?,
		}, nil
	end

	local function same_registration(left: MigrationRegistration, right: MigrationRegistration): boolean
		return left.id == right.id
			and left.from_version == right.from_version
			and left.to_version == right.to_version
			and left.implementation_revision == right.implementation_revision
			and left.compatible_schema_min == right.compatible_schema_min
			and left.compatible_schema_max == right.compatible_schema_max
			and left.transform == right.transform
			and left.validator == right.validator
	end

	local function build_graph(registrations: { [string]: MigrationRegistration }): ({ [number]: { MigrationRegistration } }, { [number]: boolean })
		local graph: { [number]: { MigrationRegistration } } = {}
		local versions: { [number]: boolean } = {}
		for _, registration in pairs(registrations) do
			local outgoing = graph[registration.from_version]
			if outgoing == nil then
				outgoing = {}
				graph[registration.from_version] = outgoing
			end
			outgoing[#outgoing + 1] = registration
			versions[registration.from_version] = true
			versions[registration.to_version] = true
		end
		for _, outgoing in pairs(graph) do
			table.sort(outgoing, function(left, right)
				if left.to_version ~= right.to_version then
					return left.to_version < right.to_version
				end
				return left.id < right.id
			end)
		end
		return graph, versions
	end

	local function unique_paths(registrations: { [string]: MigrationRegistration }): (boolean, string?)
		local graph, versions = build_graph(registrations)
		local registration_count = 0
		for _ in pairs(registrations) do registration_count += 1 end
		local function count_paths(from_version: number, target_version: number, depth: number): number
			if from_version == target_version then return 1 end
			if depth > registration_count then return 0 end
			local outgoing = graph[from_version]
			if outgoing == nil then return 0 end
			local total = 0
			for _, edge in ipairs(outgoing) do
				if edge.to_version <= target_version then
					total += count_paths(edge.to_version, target_version, depth + 1)
					if total > 1 then return 2 end
				end
			end
			return total
		end
		for from_version in pairs(versions) do
			for target_version in pairs(versions) do
				if target_version > from_version and count_paths(from_version, target_version, 0) > 1 then
					return false, ("migration registry has ambiguous paths from schema %d to %d"):format(
						from_version, target_version
					)
				end
			end
		end
		return true, nil
	end

	local function register(store_name: string, value: MigrationRegistration): (ResultCode, string?)
		if type(store_name) ~= "string" or store_name == "" or #store_name > 50 then
			return "invalid", "store_name must be 1 to 50 characters"
		end
		local registration, message = normalize_registration(value)
		if registration == nil then return "invalid", message end
		local current = registries[store_name] or {}
		local existing = current[registration.id]
		if existing ~= nil then
			if same_registration(existing, registration) then
				return "duplicate", "the same migration id and implementation revision are already registered"
			end
			return "conflict", "migration id is already registered with different metadata or implementation"
		end
		local count = 0
		for _ in pairs(current) do count += 1 end
		if count >= MAX_MIGRATIONS_PER_STORE then
			return "capacity", "migration registry reached its per-store registration limit"
		end
		local candidate = table.clone(current)
		candidate[registration.id] = registration
		local paths_ok, paths_error = unique_paths(candidate)
		if not paths_ok then return "conflict", paths_error end
		registries[store_name] = candidate
		return "success", nil
	end

	local function normalize_preview_options(options: MigrationPreviewOptions?): (MigrationPreviewOptions?, string?)
		if options ~= nil and type(options) ~= "table" then
			return nil, "migration preview options must be a table"
		end
		local normalized: MigrationPreviewOptions = if options == nil then {} else table.clone(options)
		local allowed = {
			operation_deadline = true,
			legacy_decoder = true,
			max_nodes = true,
			max_depth = true,
			max_changes = true,
		}
		if options ~= nil then
			for key in pairs(options) do
				if not allowed[key] then
					return nil, "unsupported migration preview option: " .. tostring(key)
				end
			end
		end
		if normalized.legacy_decoder ~= nil and type(normalized.legacy_decoder) ~= "function" then
			return nil, "legacy_decoder must be a function"
		end
		if normalized.max_nodes == nil then normalized.max_nodes = 4096 end
		if normalized.max_depth == nil then normalized.max_depth = 32 end
		if normalized.max_changes == nil then normalized.max_changes = 256 end
		if type(normalized.max_nodes) ~= "number" or not math.isfinite(normalized.max_nodes)
			or math.floor(normalized.max_nodes) ~= normalized.max_nodes
			or normalized.max_nodes < 1 or normalized.max_nodes > 50000
		then
			return nil, "max_nodes must be an integer from 1 to 50000"
		end
		if type(normalized.max_depth) ~= "number" or not math.isfinite(normalized.max_depth)
			or math.floor(normalized.max_depth) ~= normalized.max_depth
			or normalized.max_depth < 1 or normalized.max_depth > 64
		then
			return nil, "max_depth must be an integer from 1 to 64"
		end
		if type(normalized.max_changes) ~= "number" or not math.isfinite(normalized.max_changes)
			or math.floor(normalized.max_changes) ~= normalized.max_changes
			or normalized.max_changes < 1 or normalized.max_changes > 2048
		then
			return nil, "max_changes must be an integer from 1 to 2048"
		end
		return normalized, nil
	end

	local function find_path(store_name: string, from_version: number, target_version: number): ({ MigrationRegistration }?, string?)
		if from_version == target_version then return {}, nil end
		if target_version < from_version then
			return nil, "backwards migrations are not supported"
		end
		local registrations = registries[store_name]
		if registrations == nil then
			return nil, ("no migration path is registered from schema %d to %d"):format(from_version, target_version)
		end
		local graph = build_graph(registrations)
		local path: { MigrationRegistration } = {}
		local function walk(version: number): boolean
			if version == target_version then return true end
			local outgoing = graph[version]
			if outgoing == nil then return false end
			for _, edge in ipairs(outgoing) do
				if edge.to_version <= target_version then
					path[#path + 1] = edge
					if walk(edge.to_version) then return true end
					path[#path] = nil
				end
			end
			return false
		end
		if not walk(from_version) then
			return nil, ("no migration path is registered from schema %d to %d"):format(from_version, target_version)
		end
		return table.clone(path), nil
	end

	local function summarize(
		value: JsonValue,
		max_nodes: number,
		max_depth: number
	): (number, number, boolean, number?, boolean)
		return summarize_profile_data(value, max_nodes, max_depth)
	end

	local function path_diff(
		before_value: JsonValue,
		after_value: JsonValue,
		max_nodes: number,
		max_depth: number,
		max_changes: number
	): ({ ProfileDiffChange }, number, boolean)
		local changes: { ProfileDiffChange } = {}
		local visited = 0
		local truncated = false
		local function make_child_path(parent: string, key: string | number): string
			if type(key) == "number" then return parent .. "[" .. tostring(key) .. "]" end
			if string.match(key, "^[%a_][%w_]*$") then return parent .. "." .. key end
			local ok, encoded = pcall(function() return HttpService:JSONEncode(key) end)
			return if ok and type(encoded) == "string" then parent .. "[" .. encoded .. "]" else parent .. "[<key>]"
		end
		local function append(path: string, kind: "added" | "removed" | "changed", before: unknown, after: unknown, before_present: boolean, after_present: boolean)
			if #changes >= max_changes then
				truncated = true
				return
			end
			changes[#changes + 1] = {
				Path = string.sub(path, 1, 512),
				Kind = kind,
				BeforeType = if before_present then typeof(before) else nil,
				AfterType = if after_present then typeof(after) else nil,
			}
		end
		local function visit(before: unknown, after: unknown, path: string, depth: number, before_present: boolean, after_present: boolean)
			if truncated then return end
			if visited >= max_nodes then
				truncated = true
				return
			end
			visited += 1
			if not before_present then append(path, "added", nil, after, false, true); return end
			if not after_present then append(path, "removed", before, nil, true, false); return end
			if type(before) == "table" and type(after) == "table" then
				local left = before :: { [string | number]: JsonValue }
				local right = after :: { [string | number]: JsonValue }
				if next(left) == nil and next(right) == nil then return end
				if depth >= max_depth then
					truncated = true
					append(path, "changed", before, after, true, true)
					return
				end
				local keys: { [string | number]: boolean } = {}
				for key in pairs(left) do keys[key] = true end
				for key in pairs(right) do keys[key] = true end
				local ordered: { string | number } = {}
				for key in pairs(keys) do ordered[#ordered + 1] = key end
				table.sort(ordered, function(a, b)
					if type(a) ~= type(b) then return type(a) < type(b) end
					if type(a) == "number" then return (a :: number) < (b :: number) end
					return (a :: string) < (b :: string)
				end)
				for _, key in ipairs(ordered) do
					if truncated then return end
					local left_value, right_value = left[key], right[key]
					visit(left_value, right_value, make_child_path(path, key), depth + 1, left_value ~= nil, right_value ~= nil)
				end
				return
			end
			if type(before) == "number" and type(after) == "number"
				and math.isnan(before) and math.isnan(after) then return end
			if typeof(before) == "buffer" or typeof(after) == "buffer" then
				if typeof(before) == "buffer" and typeof(after) == "buffer"
					and buffer.tostring(before :: buffer) == buffer.tostring(after :: buffer) then return end
			elseif before == after then
				return
			end
			append(path, "changed", before, after, true, true)
		end
		visit(before_value, after_value, "$", 0, true, true)
		return changes, visited, truncated
	end

	local function preview(
		store_name: string,
		scope: string,
		key: string,
		target_version: number,
		options: MigrationPreviewOptions?,
		reader: any,
		mock: boolean
	): (MigrationPreview?, ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(store_name, scope, key)
		if not valid_identity then return nil, "invalid", identity_message end
		if not valid_version(target_version) then return nil, "invalid", "target_version must be an integer from 0 to 1000000" end
		local normalized, options_error = normalize_preview_options(options)
		if normalized == nil then return nil, "invalid", options_error end
		local deadline, deadline_error = resolve_operation_deadline(normalized.operation_deadline)
		if deadline == nil then return nil, "invalid", deadline_error end
		local remaining = deadline - now_local()
		if remaining <= 0 then return nil, "budget", "migration preview deadline expired before profile read" end
		local snapshot, read_result, read_message = reader(
			store_name,
			scope,
			key,
			remaining,
			normalized.legacy_decoder
		)
		if snapshot == nil or (read_result ~= "success" and read_result ~= "legacy") then
			return nil, normalize_result_code(read_result) or "unknown", read_message
		end
		if snapshot.Tombstoned or snapshot.Data == nil then
			return nil, "tombstoned", "migration preview refuses tombstoned or data-less profiles"
		end
		local source_version = snapshot.SchemaVersion
		local path, path_error = find_path(store_name, source_version, target_version)
		if path == nil then return nil, "migration", path_error end
		local current = copy_value(snapshot.Data)
		if current == nil then return nil, "validation", "source profile data could not be copied" end
		local steps: { MigrationPreviewStep } = {}
		for _, edge in ipairs(path) do
			if now_local() >= deadline then return nil, "budget", "migration preview deadline expired during transforms" end
			local migrated, migration_error = run_migration(edge.transform, edge.from_version, current)
			if migrated == nil then return nil, "migration", migration_error end
			local valid, validation_error = validate_value(migrated, edge.validator)
			if not valid then return nil, "validation", validation_error end
			current = migrated
			steps[#steps + 1] = {
				Id = edge.id,
				FromVersion = edge.from_version,
				ToVersion = edge.to_version,
				ImplementationRevision = edge.implementation_revision,
			}
		end
		local max_nodes = normalized.max_nodes :: number
		local max_depth = normalized.max_depth :: number
		local max_changes = normalized.max_changes :: number
		local _before_nodes, _, before_truncated = summarize(snapshot.Data :: JsonValue, max_nodes, max_depth)
		local target_nodes, target_depth, target_summary_truncated, target_bytes, target_size_available =
			summarize(current, max_nodes, max_depth)
		local changes, visited, diff_truncated = path_diff(snapshot.Data :: JsonValue, current, max_nodes, max_depth, max_changes)
		local observed_at = session_now_unix(mock)
		local session_active = snapshot.LeaseUntil ~= nil and snapshot.LeaseUntil > observed_at and not snapshot.Tombstoned
		return {
			StoreName = store_name,
			Scope = scope,
			ProfileKey = key,
			ObservedAt = observed_at,
			Consistency = "read_only_non_authoritative_preview",
			SourceSchemaVersion = source_version,
			TargetSchemaVersion = target_version,
			SourceRevision = snapshot.Revision,
			SourceGeneration = snapshot.Generation,
			SessionActive = session_active,
			Steps = steps,
			Changes = changes,
			VisitedNodes = visited,
			Truncated = before_truncated or target_summary_truncated or diff_truncated,
			TargetDataNodeCount = target_nodes,
			TargetDataDepth = target_depth,
			TargetDataEncodedBytes = target_bytes,
			TargetDataSizeAvailable = target_size_available,
		}, "success", nil
	end

	return {
		register = register,
		preview = preview,
	}
end)()

RecordStore.register_migration = (function()
	local register = RecordStore._internals.migration_registry.register
	return function(store_name: string, registration: MigrationRegistration): (ResultCode, string?)
		return register(store_name, registration)
	end
end)()

RecordStore.preview_migration_async = (function()
	local preview = RecordStore._internals.migration_registry.preview
	local reader = RecordStore.read_async
	return function(
		store_name: string,
		scope: string,
		key: string,
		target_version: number,
		options: MigrationPreviewOptions?
	): (MigrationPreview?, ResultCode, string?)
		return preview(store_name, scope, key, target_version, options, reader, false)
	end
end)()

RecordStore._internals.normalize_options = function(options: Options): (Options?, string?)
	if type(options) ~= "table" then
		return nil, "options must be a table"
	end
	local copied = table.clone(options)
	if copied.autosave_interval == nil then
		copied.autosave_interval = DEFAULT_AUTOSAVE_INTERVAL
	end
	if copied.lease_duration == nil then
		copied.lease_duration = DEFAULT_LEASE_DURATION
	end
	if copied.lease_renewal == nil then
		copied.lease_renewal = DEFAULT_LEASE_RENEWAL
	end
	if copied.retry_attempts == nil then
		copied.retry_attempts = DEFAULT_RETRY_ATTEMPTS
	end
	if copied.operation_deadline == nil then
		copied.operation_deadline = DEFAULT_OPERATION_DEADLINE
	end
	if copied.shutdown_deadline == nil then
		copied.shutdown_deadline = DEFAULT_SHUTDOWN_DEADLINE
	end
	if copied.shutdown_attempts == nil then
		copied.shutdown_attempts = DEFAULT_SHUTDOWN_ATTEMPTS
	end
	if copied.budget_wait == nil then
		copied.budget_wait = DEFAULT_BUDGET_WAIT
	end
	if copied.messaging_enabled == nil then
		copied.messaging_enabled = true
	end
	if copied.takeover_enabled == nil then
		copied.takeover_enabled = true
	end
	if copied.takeover_wait == nil then
		copied.takeover_wait = DEFAULT_TAKEOVER_WAIT
	end
	if copied.message_topic_prefix == nil then
		copied.message_topic_prefix = DEFAULT_MESSAGE_TOPIC_PREFIX
	end
	if copied.durable_queue_enabled == nil then
		copied.durable_queue_enabled = true
	end
	if copied.transactional_operations_enabled == nil then
		copied.transactional_operations_enabled = false
	end
	if copied.queue_store_name == nil then
		copied.queue_store_name = DEFAULT_QUEUE_STORE_NAME
	end
	if copied.queue_poll_interval == nil then
		copied.queue_poll_interval = DEFAULT_QUEUE_POLL_INTERVAL
	end
	if copied.queue_lease_duration == nil then
		copied.queue_lease_duration = DEFAULT_QUEUE_LEASE_DURATION
	end
	if copied.queue_max_messages == nil then
		copied.queue_max_messages = DEFAULT_QUEUE_MAX_MESSAGES
	end
	if copied.queue_max_bytes == nil then
		copied.queue_max_bytes = DEFAULT_QUEUE_MAX_BYTES
	end
	if copied.queue_max_attempts == nil then
		copied.queue_max_attempts = DEFAULT_QUEUE_MAX_ATTEMPTS
	end
	local queue_poll_interval = copied.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL
	local queue_lease_duration = copied.queue_lease_duration or DEFAULT_QUEUE_LEASE_DURATION
	local queue_max_messages = copied.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES
	local queue_max_bytes = copied.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local queue_max_attempts = copied.queue_max_attempts or DEFAULT_QUEUE_MAX_ATTEMPTS
	if type(copied.messaging_enabled) ~= "boolean" then
		return nil, "messaging_enabled must be a boolean"
	end
	if type(copied.takeover_enabled) ~= "boolean" then
		return nil, "takeover_enabled must be a boolean"
	end
	if type(copied.durable_queue_enabled) ~= "boolean" then
		return nil, "durable_queue_enabled must be a boolean"
	end
	if type(copied.transactional_operations_enabled) ~= "boolean" then
		return nil, "transactional_operations_enabled must be a boolean"
	end
	if type(copied.message_topic_prefix) ~= "string" then
		return nil, "message_topic_prefix must be a string of at most 72 characters"
	end
	local topic_prefix_length = utf8.len(copied.message_topic_prefix)
	if topic_prefix_length == nil or topic_prefix_length > 72 then
		return nil, "message_topic_prefix must be valid UTF-8 and at most 72 characters"
	end
	if type(copied.queue_store_name) ~= "string" or copied.queue_store_name == "" or #copied.queue_store_name > 50 then
		return nil, "queue_store_name must be 1 to 50 characters"
	end
	if type(queue_poll_interval) ~= "number" or not math.isfinite(queue_poll_interval) or queue_poll_interval <= 0 then
		return nil, "queue_poll_interval must be a positive finite number"
	end
	if type(queue_lease_duration) ~= "number" or not math.isfinite(queue_lease_duration) or queue_lease_duration <= 0 then
		return nil, "queue_lease_duration must be a positive finite number"
	end
	if type(queue_max_messages) ~= "number" or not math.isfinite(queue_max_messages) or queue_max_messages < 1 or queue_max_messages ~= math.floor(queue_max_messages) then
		return nil, "queue_max_messages must be a positive integer"
	end
	if type(queue_max_bytes) ~= "number" or not math.isfinite(queue_max_bytes) or queue_max_bytes < 1 or queue_max_bytes > MAX_DATASTORE_BYTES then
		return nil, "queue_max_bytes must be between 1 and the DataStore value limit"
	end
	if type(queue_max_attempts) ~= "number" or not math.isfinite(queue_max_attempts) or queue_max_attempts < 1 or queue_max_attempts > MAX_QUEUE_ATTEMPTS or math.floor(queue_max_attempts) ~= queue_max_attempts then
		return nil, "queue_max_attempts must be an integer from 1 to " .. tostring(MAX_QUEUE_ATTEMPTS)
	end
	local function valid_positive_number(value: unknown): boolean
		return type(value) == "number" and math.isfinite(value) and value > 0
	end
	local function valid_nonnegative_number(value: unknown): boolean
		return type(value) == "number" and math.isfinite(value) and value >= 0
	end
	if type(copied.schema_version) ~= "number" or not math.isfinite(copied.schema_version) or copied.schema_version < 0 or math.floor(copied.schema_version) ~= copied.schema_version then
		return nil, "schema_version must be a non-negative integer"
	end
	if not valid_positive_number(copied.autosave_interval) then
		return nil, "autosave_interval must be a positive finite number"
	end
	if not valid_positive_number(copied.lease_duration) then
		return nil, "lease_duration must be a positive finite number"
	end
	if not valid_positive_number(copied.lease_renewal) then
		return nil, "lease_renewal must be a positive finite number"
	end
	if not valid_positive_number(copied.operation_deadline) then
		return nil, "operation_deadline must be a positive finite number"
	end
	local lease_duration = copied.lease_duration :: number
	local lease_renewal = copied.lease_renewal :: number
	local operation_deadline = copied.operation_deadline :: number
	if lease_duration <= lease_renewal + operation_deadline then
		return nil, "lease_duration must exceed lease_renewal plus operation_deadline"
	end
	if not valid_positive_number(copied.shutdown_deadline) then
		return nil, "shutdown_deadline must be a positive finite number"
	end
	if not valid_nonnegative_number(copied.budget_wait) then
		return nil, "budget_wait must be a finite non-negative number"
	end
	if not valid_positive_number(copied.takeover_wait) then
		return nil, "takeover_wait must be a positive finite number"
	end
	if copied.shutdown_attempts ~= nil and (type(copied.shutdown_attempts) ~= "number" or not math.isfinite(copied.shutdown_attempts) or copied.shutdown_attempts < 1 or copied.shutdown_attempts > MAX_RETRY_ATTEMPTS or math.floor(copied.shutdown_attempts) ~= copied.shutdown_attempts) then
		return nil, "shutdown_attempts must be an integer from 1 to " .. tostring(MAX_RETRY_ATTEMPTS)
	end
	if copied.retry_attempts ~= nil and (type(copied.retry_attempts) ~= "number" or not math.isfinite(copied.retry_attempts) or copied.retry_attempts < 1 or copied.retry_attempts > MAX_RETRY_ATTEMPTS or math.floor(copied.retry_attempts) ~= copied.retry_attempts) then
		return nil, "retry_attempts must be an integer from 1 to " .. tostring(MAX_RETRY_ATTEMPTS)
	end
	if copied.migrations ~= nil then
		if type(copied.migrations) ~= "table" then
			return nil, "migrations must be a table"
		end
		for version, migration in copied.migrations do
			if type(version) ~= "number" or not math.isfinite(version) or math.floor(version) ~= version or version < 0 or type(migration) ~= "function" then
				return nil, "migrations must map non-negative integer versions to functions"
			end
		end
	end
	if copied.user_ids ~= nil then
		if type(copied.user_ids) ~= "table" then
			return nil, "user_ids must be an array of positive integers"
		end
		local normalized_ids, ids_error = normalize_user_ids(copied.user_ids)
		if normalized_ids == nil then
			return nil, ids_error
		end
		copied.user_ids = normalized_ids
	end
	if copied.validator ~= nil and type(copied.validator) ~= "function" then
		return nil, "validator must be a function"
	end
	if copied.legacy_decoder ~= nil and type(copied.legacy_decoder) ~= "function" then
		return nil, "legacy_decoder must be a function"
	end
	if copied.on_event ~= nil and type(copied.on_event) ~= "function" then
		return nil, "on_event must be a function"
	end
	if copied.on_message ~= nil and type(copied.on_message) ~= "function" then
		return nil, "on_message must be a function"
	end
	if copied.on_queue_message ~= nil and type(copied.on_queue_message) ~= "function" then
		return nil, "on_queue_message must be a function"
	end
	if copied.metadata ~= nil then
		local valid, message = validate_metadata(copied.metadata)
		if not valid then
			return nil, message
		end
	end
	return copied, nil
end

RecordStore._internals.enqueue_static = (function()
local function enqueue_static(name: string, scope: string, key: string, message_type: string, data: JsonValue?, mock: boolean, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return "invalid", identity_message
	end
	if type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH then
		return "invalid", "message_type must be 1 to 100 characters"
	end
	local frozen_data: JsonValue? = nil
	if data ~= nil then
		local copied_ok, copied_or_error = pcall(function()
			return copy_value(data)
		end)
		if not copied_ok or copied_or_error == nil then
			return "validation", "queue data is invalid"
		end
		frozen_data = copied_or_error
		local valid, message = validate_serialized_size(frozen_data)
		if not valid then
			return "validation", message
		end
	end
	local queue_name = queue_store_name or DEFAULT_QUEUE_STORE_NAME
	if type(queue_name) ~= "string" or #queue_name == 0 or #queue_name > 50 then
		return "invalid", "queue_store_name must be 1 to 50 characters"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return "invalid", deadline_error
	end
	local migration_code, migration_message = ensure_legacy_queue_clear(
		name,
		scope,
		key,
		queue_name,
		mock,
		deadline,
		nil
	)
	if migration_code ~= nil then
		return normalize_result_code(migration_code) or "unknown", migration_message
	end
	local backend = make_backend(queue_name, scope, make_queue_key_v2(name, scope, key), mock)
	local owner = make_queue_owner(name, scope, key)
	local message_id = HttpService:GenerateGUID(false)
	local created_at = queue_now_unix(mock)
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil or #queue.messages >= DEFAULT_QUEUE_MAX_MESSAGES then
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		next_messages[#next_messages + 1] = {
			id = message_id,
			type = message_type,
			data = copy_value(frozen_data),
			attempts = 0,
			total_attempts = 0,
			replay_count = 0,
			last_replay_token = nil,
			sender_job_id = server_id,
			created_at = created_at,
			locked_until = 0,
			lock_token = nil,
		}
		local next_queue = make_queue_envelope(owner, next_messages, queue.dead_letters)
		if queue_size_error(next_queue, DEFAULT_QUEUE_MAX_BYTES) ~= nil then
			return nil, nil, nil
		end
		return next_queue, nil, nil
	end, deadline)
	if result_code ~= nil then
		return normalize_result_code(result_code) or "unknown", result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, nil, owner)
	if queue == nil then
		return normalize_result_code(verify_code) or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id then
			return "enqueued", message_id
		end
	end
	if #queue.messages >= DEFAULT_QUEUE_MAX_MESSAGES then
		return "validation", "durable queue is full"
	end
	local candidate = table.clone(queue.messages)
	candidate[#candidate + 1] = {
		id = message_id,
		type = message_type,
		data = copy_value(frozen_data),
		attempts = 0,
		total_attempts = 0,
		replay_count = 0,
		last_replay_token = nil,
		sender_job_id = server_id,
		created_at = created_at,
		locked_until = 0,
		lock_token = nil,
	}
	local candidate_queue = make_queue_envelope(owner, candidate, queue.dead_letters)
	local size_message = queue_size_error(candidate_queue, DEFAULT_QUEUE_MAX_BYTES)
	if size_message ~= nil then
		return "validation", size_message
	end
	return "unknown", "queue append did not appear in the verified durable state"
end

return {
	production = function(name: string, scope: string, key: string, message_type: string, data: JsonValue?, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
		return enqueue_static(name, scope, key, message_type, data, false, queue_store_name, operation_deadline)
	end,
	mock = function(name: string, scope: string, key: string, message_type: string, data: JsonValue?, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
		return enqueue_static(name, scope, key, message_type, data, true, queue_store_name, operation_deadline)
	end,
}
end)()

RecordStore.enqueue_async = (function()
	local enqueue_production = RecordStore._internals.enqueue_static.production
	return function(name: string, scope: string, key: string, message_type: string, data: JsonValue?, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
		return enqueue_production(name, scope, key, message_type, data, queue_store_name, operation_deadline)
	end
end)()

RecordStore.new = (function()
	local normalize_options = RecordStore._internals.normalize_options
	local transact_engine = RecordStore._internals.transact :: (Record, string, string, TransactionReducer, TransactionOptions?, string?, JsonValue?, { OutboxEventSpec }?) -> (JsonValue?, TransactionStatus, string?)
	local transaction_status_engine = (RecordStore._internals :: { [string]: any }).get_transaction_status :: (Record, string, JsonValue) -> TransactionReceiptStatus
	return function(name: string, scope: string, key: string, options: Options): Record
	if closing then
		error("RecordStore is shutting down", 2)
	end
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		error(identity_message, 2)
	end
	local normalized, options_message = normalize_options(options)
	if normalized == nil then
		error(options_message, 2)
	end
	local valid_options = normalized
	if valid_options == nil then
		error("normalized options are missing", 2)
	end
	local record = make_record(name, scope, key, valid_options, false, transact_engine, transaction_status_engine)
	start_scheduler()
	return record
	end
end)()

RecordStore.Mock = (function()
	local normalize_options = RecordStore._internals.normalize_options
	local transact_engine = RecordStore._internals.transact :: (Record, string, string, TransactionReducer, TransactionOptions?, string?, JsonValue?, { OutboxEventSpec }?) -> (JsonValue?, TransactionStatus, string?)
	local transaction_status_engine = (RecordStore._internals :: { [string]: any }).get_transaction_status :: (Record, string, JsonValue) -> TransactionReceiptStatus
	local enqueue_mock = RecordStore._internals.enqueue_static.mock
	local function mock_new(name: string, scope: string, key: string, options: Options): Record
		if closing then
			error("RecordStore is shutting down", 2)
		end
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			error(identity_message, 2)
		end
		local normalized, options_message = normalize_options(options)
		if normalized == nil then
			error(options_message, 2)
		end
		local valid_options = normalized
		if valid_options == nil then
			error("normalized options are missing", 2)
		end
		valid_options.messaging_enabled = false
		valid_options.takeover_enabled = false
		start_scheduler()
		return make_record(name, scope, key, valid_options, true, transact_engine, transaction_status_engine)
	end

	local function read_async_mock(name: string, scope: string, key: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
		if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
			return nil, "invalid", "legacy_decoder must be a function"
		end
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			return nil, "invalid", identity_message
		end
		local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
		if deadline == nil then
			return nil, "invalid", deadline_error
		end
		local backend = make_backend(name, scope, key, true)
		local raw, info, result_code, result_message = backend_get(backend, false, deadline)
		if result_code ~= nil then
			return nil, normalize_result_code(result_code) or "unknown", result_message
		end
		if raw == nil then
			return nil, "not_found", "record does not exist"
		end
		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then
			if parse_error == "legacy payload" and legacy_decoder ~= nil then
				local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
				if legacy_envelope == nil then
					return nil, "legacy", legacy_error
				end
				return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "read-only legacy payload"
			end
			return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "durable envelope is invalid"
		end
		if envelope == nil then
			return nil, "corrupt", "durable envelope is missing"
		end
		return snapshot_from_envelope(key, envelope, info), "success", nil
	end

	local function list_versions_mock(name: string, scope: string, key: string, sort_direction: Enum.SortDirection?, min_date_ms: number?, max_date_ms: number?, max_versions: number?, operation_deadline: number?): ({ HistoryEntry }?, ResultCode, string?)
		return list_versions_internal(name, scope, key, sort_direction, min_date_ms, max_date_ms, max_versions, operation_deadline, true)
	end

	local function get_version_mock(name: string, scope: string, key: string, version: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
		return get_version_internal(name, scope, key, version, operation_deadline, legacy_decoder, true)
	end

	local function get_version_at_time_mock(name: string, scope: string, key: string, timestamp_ms: number, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, string?, ResultCode, string?)
		return get_version_at_time_internal(name, scope, key, timestamp_ms, operation_deadline, legacy_decoder, true)
	end

	local function mock_seed_queue_value(
		name: string,
		scope: string,
		key: string,
		value: unknown,
		legacy: boolean?,
		queue_store_name: string?
	): (ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			return "invalid", identity_message
		end
		local store_name = queue_store_name or DEFAULT_QUEUE_STORE_NAME
		if type(store_name) ~= "string" or #store_name == 0 or #store_name > 50 then
			return "invalid", "queue_store_name must be 1 to 50 characters"
		end
		local queue_key = if legacy == true
			then make_queue_key_legacy(name, scope, key)
			else make_queue_key_v2(name, scope, key)
		local store = get_mock_store(store_name, scope)
		if value == nil then
			store[queue_key] = nil
			return "success", nil
		end
		local copied_ok, copied_value = pcall(function()
			return copy_value(value)
		end)
		if not copied_ok or copied_value == nil then
			return "validation", "mock queue fixture value is not valid JSON data"
		end
		store[queue_key] = mock_write_version(store[queue_key], copied_value, {}, {}, false)
		return "success", nil
	end

	local function mock_get_queue_raw(
		name: string,
		scope: string,
		key: string,
		legacy: boolean?,
		queue_store_name: string?
	): unknown
		local store_name = queue_store_name or DEFAULT_QUEUE_STORE_NAME
		local queue_key = if legacy == true
			then make_queue_key_legacy(name, scope, key)
			else make_queue_key_v2(name, scope, key)
		local store = get_mock_store(store_name, scope)
		local entry = store[queue_key]
		return if entry == nil then nil else copy_value(entry.Value)
	end

	local function mock_seed_record_raw(name: string, scope: string, key: string, value: unknown): (ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			return "invalid", identity_message
		end
		local store = get_mock_store(name, scope)
		if value == nil then
			store[key] = nil
			return "success", nil
		end
		local copied_ok, copied_or_error = pcall(function()
			return copy_value(value)
		end)
		if not copied_ok or copied_or_error == nil then
			return "validation", "mock record fixture is not valid JSON data"
		end
		local copied = copied_or_error :: JsonValue
		local valid, size_error = validate_serialized_size(copied)
		if not valid then
			return "validation", size_error
		end
		store[key] = mock_write_version(store[key], copied, {}, {}, false)
		return "success", nil
	end

	local function mock_get_record_raw(name: string, scope: string, key: string): unknown
		local store = get_mock_store(name, scope)
		local entry = store[key]
		return if entry == nil then nil else copy_value(entry.Value)
	end

	local function mock_get_record_version_raw(name: string, scope: string, key: string, version: string): unknown
		local store = get_mock_store(name, scope)
		local entry = store[key]
		if entry == nil then
			return nil
		end
		local historical = entry.Versions[version]
		return if historical == nil then nil else copy_value(historical.Value)
	end

	local function mock_set_test_clock(clock: (() -> number)?)
		if clock ~= nil and type(clock) ~= "function" then
			error("test clock must be a function or nil", 2)
		end
		mock_test_clock = clock
		mock_test_clock_offset = 0
	end

	local function mock_set_update_replay(retries: number, advance_seconds: number)
		if type(retries) ~= "number"
			or not math.isfinite(retries)
			or math.floor(retries) ~= retries
			or retries < 0
			or retries > 20
		then
			error("retries must be an integer from 0 to 20", 2)
		end
		if type(advance_seconds) ~= "number"
			or not math.isfinite(advance_seconds)
			or advance_seconds < 0
			or advance_seconds > 3600
		then
			error("advance_seconds must be from 0 to 3600", 2)
		end
		mock_update_replay_retries = retries
		mock_update_replay_advance_seconds = advance_seconds
	end

	local function mock_set_update_commit_then_failures(count: number, message: string?)
		if type(count) ~= "number" or not math.isfinite(count) or math.floor(count) ~= count or count < 0 or count > 100 then
			error("count must be an integer from 0 to 100", 2)
		end
		if message ~= nil and type(message) ~= "string" then
			error("message must be a string or nil", 2)
		end
		mock_update_commit_then_failure_count = count
		mock_update_commit_then_failure_message = message
	end

	local function mock_set_get_failures(count: number, message: string?)
		if type(count) ~= "number" or not math.isfinite(count) or math.floor(count) ~= count or count < 0 or count > 100 then
			error("count must be an integer from 0 to 100", 2)
		end
		if message ~= nil and type(message) ~= "string" then
			error("message must be a string or nil", 2)
		end
		mock_get_failure_count = count
		mock_get_failure_message = message
	end

	local function mock_set_update_failures(count: number, result: ResultCode?, message: string?)
		if type(count) ~= "number"
			or not math.isfinite(count)
			or math.floor(count) ~= count
			or count < 0
			or count > 100
		then
			error("count must be an integer from 0 to 100", 2)
		end
		local failure_code = result or "budget"
		if failure_code ~= "budget"
			and failure_code ~= "busy"
			and failure_code ~= "unknown"
			and failure_code ~= "retry_exhausted"
		then
			error("result must be a transient backend result", 2)
		end
		if message ~= nil and type(message) ~= "string" then
			error("message must be a string or nil", 2)
		end
		mock_update_failure_count = count
		mock_update_failure_code = failure_code
		mock_update_failure_message = message
	end

	local function mock_claim_queue_message(record: Record): (MockQueueClaim?, ResultCode, string?)
		local state = private[record]
		if state == nil or not state.backend.mock then
			return nil, "invalid", "queue claim requires a live mock record"
		end
		local item, result, message = claim_queue_message(state)
		if item == nil then
			return nil, normalize_result_code(result) or "unknown", message
		end
		if item.lock_token == nil then
			return nil, "corrupt", "mock queue claim has no lock token"
		end
		return ({
			Id = item.id,
			LockToken = item.lock_token,
			LockedUntil = item.locked_until,
		} :: unknown) :: MockQueueClaim, normalize_result_code(result) or "unknown", message
	end

	local function mock_dead_letter_queue_message(record: Record, message_id: string, lock_token: string, error_message: string): (ResultCode, string?)
		local state = private[record]
		if state == nil or not state.backend.mock then
			return "invalid", "dead-letter mutation requires a live mock record"
		end
		return dead_letter_queue_message(state, message_id, lock_token, error_message)
	end

	function RecordStore.get_server_id(): string
		return server_id
	end

	function RecordStore.is_shutting_down(): boolean
		return closing
	end

	local Mock = {
		new = mock_new,
		reconcile = function(record: Record): (ResultCode, string?)
			local state = private[record]
			if state == nil or not state.backend.mock then
				return "invalid", "mock reconciliation requires a live mock record"
			end
			local result, message = reconcile_unknown_internal(state)
			sync_public(record)
			return normalize_result_code(result) or "unknown", message
		end,
		renew = function(record: Record): (ResultCode, string?)
			local state = private[record]
			if state == nil or not state.backend.mock then
				return "invalid", "mock renewal requires a live mock record"
			end
			local result, message = renew_internal(state)
			sync_public(record)
			return normalize_result_code(result) or "unknown", message
		end,
		get_session_status_async = RecordStore._internals.get_session_status_mock_async,
		inspect_profile_async = (function()
			local inspect = RecordStore._internals.profile_doctor.inspect
			return function(
				name: string,
				scope: string,
				key: string,
				options: ProfileDoctorOptions?
			): (ProfileInspection?, ResultCode, string?)
				return inspect(name, scope, key, options, read_async_mock, true)
			end
		end)(),
		diff_profile_versions_async = (function()
			local diff = RecordStore._internals.profile_doctor.diff
			return function(
				name: string,
				scope: string,
				key: string,
				before_version: string,
				after_version: string,
				options: ProfileDoctorOptions?
			): (ProfileVersionDiff?, ResultCode, string?)
				return diff(name, scope, key, before_version, after_version, options, get_version_mock)
			end
		end)(),
		preview_migration_async = (function()
			local preview = RecordStore._internals.migration_registry.preview
			return function(
				store_name: string,
				scope: string,
				key: string,
				target_version: number,
				options: MigrationPreviewOptions?
			): (MigrationPreview?, ResultCode, string?)
				return preview(store_name, scope, key, target_version, options, read_async_mock, true)
			end
		end)(),
		read_async = read_async_mock,
		claim_queue_message = mock_claim_queue_message,
		dead_letter_queue_message = mock_dead_letter_queue_message,
		list_versions_async = list_versions_mock,
		get_version_async = get_version_mock,
		get_version_at_time_async = get_version_at_time_mock,
		enqueue_async = function(name: string, scope: string, key: string, message_type: string, data: JsonValue?, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
			return enqueue_mock(name, scope, key, message_type, data, queue_store_name, operation_deadline)
		end,
		seed_queue_raw = function(name: string, scope: string, key: string, value: unknown, queue_store_name: string?): (ResultCode, string?)
			return mock_seed_queue_value(name, scope, key, value, false, queue_store_name)
		end,
		seed_legacy_queue = function(name: string, scope: string, key: string, value: unknown, queue_store_name: string?): (ResultCode, string?)
			return mock_seed_queue_value(name, scope, key, value, true, queue_store_name)
		end,
		get_queue_raw = mock_get_queue_raw,
		seed_record_raw = mock_seed_record_raw,
		get_record_raw = mock_get_record_raw,
		get_record_version_raw = mock_get_record_version_raw,
		set_test_clock = mock_set_test_clock,
		set_update_replay = mock_set_update_replay,
		set_update_failures = mock_set_update_failures,
		set_update_commit_then_failures = mock_set_update_commit_then_failures,
		set_get_failures = mock_set_get_failures,
		reset = function()
			local mock_records: { { id: string, record: Record } } = {}
			for id, record in pairs(records) do
				local state = private[record]
				if state ~= nil and state.backend.mock then
					mock_records[#mock_records + 1] = {
						id = id,
						record = record,
					}
				end
			end
			for _, item in ipairs(mock_records) do
				local state = private[item.record]
				if state ~= nil then
					state.retired = true
					state.shutdown = true
					state.state = "closed"
					active_records[item.record] = nil
					recovery_records[item.record] = nil
					state.busy = false
					state.queue_busy = false
					state.takeover_requested = false
					state.next_autosave = math.huge
					state.next_renewal = math.huge
					state.next_queue_poll = math.huge
					disconnect_message_subscription(state)
					private[item.record] = nil
				end
				records[item.id] = nil
			end
			mock_database = {}
			mock_counter = 0
			mock_test_clock = nil
			mock_test_clock_offset = 0
			mock_update_replay_retries = 0
			mock_update_replay_advance_seconds = 0
			mock_update_failure_count = 0
			mock_update_failure_code = "budget"
			mock_update_failure_message = nil
			mock_update_commit_then_failure_count = 0
			mock_update_commit_then_failure_message = nil
			mock_get_failure_count = 0
			mock_get_failure_message = nil
		end,
	}

	return Mock
end)()
RecordStore.MailboxV2 = MailboxV2
RecordStore.is_retryable_result = is_retryable_result
RecordStore.get_diagnostic_code = get_diagnostic_code

game:BindToClose(RecordStore.shutdown)

table.freeze(RecordStore._internals.enqueue_static)
table.freeze(RecordStore._internals)
rawset(RecordStore, "_internals", nil)
table.freeze(RecordStore)

return RecordStore

