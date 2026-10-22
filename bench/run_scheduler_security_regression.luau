--!nocheck
-- Adversarial scheduling resource and public-option validation regressions.
-- These tests must reject noncritical reserve exhaustion and malformed false values.

local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")
local task = require("@lune/task")
local now_ms = 1_800_000_000_000
local findings = {}

local function report(name, ok, detail)
	if not ok then table.insert(findings, name .. ": " .. detail) end
end

local function new_governor()
	return Scheduler.new({ now_ms = function() return now_ms end })
end

local function dimensions(bytes, handlers)
	return {
		read_units = 0,
		write_units = 0,
		estimated_bytes = bytes,
		handler_slots = handlers,
	}
end

local function wait_for_callback(callback_ran)
	for _ = 1, 100 do
		if callback_ran() then return end
		task.wait(0.001)
	end
end

-- Noncritical estimated-byte admissions must preserve a bounded critical reserve.
do
	local governor = new_governor()
	local policy = governor:Stats().policy
	local byte_capacity = policy.max_estimated_bytes_in_flight
	local byte_reserve = 4_194_304
	report("byte reserve default", policy.estimated_bytes_critical_reserve == byte_reserve,
		"expected a 4 MiB configured estimated-byte reserve; found "
			.. tostring(policy.estimated_bytes_critical_reserve))

	local noncritical_limit = byte_capacity - byte_reserve
	local overflow = governor:Admit(
		"maintenance", "tracing", 1, false, false,
		dimensions(noncritical_limit + 1, 1)
	)
	report("byte reserve boundary", overflow.code == "backpressure",
		"noncritical admission crossed the protected byte-reserve boundary; got "
			.. tostring(overflow.code) .. ": " .. tostring(overflow.message))
	if overflow.code == "admitted" then governor:Release(overflow) end

	local noncritical = governor:Admit(
		"maintenance", "tracing", 1, false, false,
		dimensions(noncritical_limit, 1)
	)
	report("byte reserve exact limit", noncritical.code == "admitted",
		"noncritical work could not use capacity up to the protected reserve; got "
			.. tostring(noncritical.code) .. ": " .. tostring(noncritical.message))
	local critical = governor:Admit(
		"profile_save", "update_async", 1, true, false,
		{ read_units = 1, write_units = 1, estimated_bytes = 16_384, handler_slots = 1 }
	)
	report("critical byte admission", critical.code == "admitted",
		"critical profile-save could not use its reserved estimated-byte headroom; got "
			.. tostring(critical.code) .. ": " .. tostring(critical.message))
	if noncritical.code == "admitted" then governor:Release(noncritical) end
	if critical.code == "admitted" then governor:Release(critical) end
	report("byte ticket accounting", governor:Stats().estimated_bytes_in_flight == 0,
		"estimated-byte usage remained after releasing all valid reservations")
end

-- Noncritical handler-slot admissions must leave at least one slot for critical work.
do
	local governor = new_governor()
	local policy = governor:Stats().policy
	local slot_capacity = policy.max_handler_slots_in_flight
	local slot_reserve = 1
	report("handler reserve default", policy.handler_slots_critical_reserve == slot_reserve,
		"expected one reserved critical handler slot; found "
			.. tostring(policy.handler_slots_critical_reserve))

	local overflow = governor:Admit(
		"maintenance", "tracing", 1, false, false,
		dimensions(16_384, slot_capacity)
	)
	report("handler-slot reserve boundary", overflow.code == "backpressure",
		"noncritical admission consumed critical handler headroom; got "
			.. tostring(overflow.code) .. ": " .. tostring(overflow.message))
	if overflow.code == "admitted" then governor:Release(overflow) end

	local noncritical = governor:Admit(
		"maintenance", "tracing", 1, false, false,
		dimensions(16_384, slot_capacity - slot_reserve)
	)
	report("handler-slot exact limit", noncritical.code == "admitted",
		"noncritical work could not use handler slots up to the reserve boundary; got "
			.. tostring(noncritical.code) .. ": " .. tostring(noncritical.message))
	local critical = governor:Admit(
		"profile_save", "update_async", 1, true, false,
		{ read_units = 1, write_units = 1, estimated_bytes = 16_384, handler_slots = slot_reserve }
	)
	report("critical handler-slot admission", critical.code == "admitted",
		"critical profile-save could not use its reserved handler slot; got "
			.. tostring(critical.code) .. ": " .. tostring(critical.message))
	if noncritical.code == "admitted" then governor:Release(noncritical) end
	if critical.code == "admitted" then governor:Release(critical) end
	report("handler ticket accounting", governor:Stats().handler_slots_in_flight == 0,
		"handler-slot usage remained after releasing all valid reservations")
end

-- Reserve configuration must reject negative, fractional and out-of-range values.
do
	local governor = new_governor()
	local policy = governor:Stats().policy
	local revision = policy.revision + 1
	local invalid_patches = {
		{ estimated_bytes_critical_reserve = -1 },
		{ estimated_bytes_critical_reserve = 1.5 },
		{ estimated_bytes_critical_reserve = policy.max_estimated_bytes_in_flight },
		{ handler_slots_critical_reserve = -1 },
		{ handler_slots_critical_reserve = 0.5 },
		{ handler_slots_critical_reserve = policy.max_handler_slots_in_flight },
	}
	for index, fields in ipairs(invalid_patches) do
		fields.revision = revision
		local accepted = governor:SetPolicy(fields)
		report("reserve policy validation " .. index, not accepted,
			"invalid reserve policy patch was accepted: " .. tostring(index))
	end

	for index, fields in ipairs({
		{ max_estimated_bytes_in_flight = false },
		{ max_handler_slots_in_flight = false },
	}) do
		fields.revision = revision
		local ok, accepted = pcall(function() return governor:SetPolicy(fields) end)
		report("malformed capacity policy " .. index, ok and accepted == false,
			"malformed capacity patch threw or was accepted instead of returning false")
	end
end

-- The queue protection control is itself validated and cannot be truthy-coerced.
do
	local governor = new_governor()
	local item = {
		id = "malformed-critical-queue-protection",
		owner_id = "security-probe",
		lane = "normal",
	}
	local result = governor:Enqueue(item, "true")
	report("critical queue protection type", result.code == "invalid",
		"non-boolean queue protection was accepted; got " .. tostring(result.code))
end

-- Nil means omitted. Explicit false lane/dependency/work-class values are malformed.
do
	local governor = new_governor()
	local result = governor:Enqueue({
		id = "malformed-false-lane",
		owner_id = "security-probe",
		lane = false,
	})
	report("governor lane validation", result.code == "invalid",
		"lane=false was silently normalized instead of rejected; got " .. tostring(result.code))
	if result.code == "accepted" then
		local item = governor:TakeNext()
		if item ~= nil then governor:MarkCompleted(item.id, "cancelled") end
	end

	local false_dependencies = governor:Enqueue({
		id = "malformed-false-dependencies",
		owner_id = "security-probe",
		dependencies = false,
	})
	report("dependency validation", false_dependencies.code == "invalid",
		"dependencies=false was silently normalized instead of rejected; got " .. tostring(false_dependencies.code))
	if false_dependencies.code == "accepted" then
		local item = governor:TakeNext()
		if item ~= nil then governor:MarkCompleted(item.id, "cancelled") end
	end
end

-- Exercise dispatcher Schedule, not only the governor's lower-level API.
do
	local cases = {
		{ name = "dispatcher lane validation", options = { lane = false } },
		{ name = "dispatcher work-class validation", options = { work_class = false } },
		{ name = "dispatcher operation-class validation", options = { work_class = "valid", operation_class = false } },
		{ name = "dispatcher dependency validation", options = { dependencies = false } },
	}
	for index, test_case in ipairs(cases) do
		local dispatcher = Scheduler.new_dispatcher(new_governor(), {
			now_ms = function() return now_ms end,
		})
		local callback_ran = false
		local result = dispatcher:Schedule(
			"security-probe",
			"malformed-option-" .. index,
			function()
				callback_ran = true
				return { code = "success" }
			end,
			test_case.options
		)
		if result.code == "accepted" then wait_for_callback(function() return callback_ran end) end
		dispatcher:Close()
		report(test_case.name, result.code == "invalid",
			"malformed option was accepted or defaulted; got " .. tostring(result.code))
		report(test_case.name .. " callback safety", not callback_ran,
			"callback executed despite malformed scheduler options")
	end
end


-- Direct governor admission is also a trust boundary: explicit false/invalid fields
-- must not be converted to defaults that reduce accounting or bypass read-only mode.
do
	local function admission_result(name, invoke)
		local governor = new_governor()
		local ok, result = pcall(invoke, governor)
		report(name, ok and type(result) == "table" and result.code == "invalid",
			"invalid explicit admission input was not rejected; "
				.. tostring(if ok and type(result) == "table" then result.code else result))
	end

	admission_result("false work class", function(governor)
		return governor:Admit(false, "tracing", 1, false, false, dimensions(1024, 1))
	end)
	admission_result("false request kind", function(governor)
		return governor:Admit("maintenance", false, 1, false, false, dimensions(1024, 1))
	end)
	admission_result("false cost", function(governor)
		return governor:Admit("maintenance", "tracing", false, false, false, dimensions(1024, 1))
	end)
	admission_result("false dimensions table", function(governor)
		return governor:Admit("maintenance", "tracing", 1, false, false, false)
	end)

	admission_result("partial dimensions table", function(governor)
		return governor:Admit("maintenance", "update_async", 1, false, false, {
			estimated_bytes = 1024,
			handler_slots = 1,
		})
	end)
	admission_result("false mutating type", function(governor)
		return governor:Admit("maintenance", "tracing", 1, "false", false, dimensions(1024, 1))
	end)
	admission_result("false critical override type", function(governor)
		return governor:Admit("maintenance", "tracing", 1, false, "true", dimensions(1024, 1))
	end)

	for _, field in ipairs({ "read_units", "write_units", "estimated_bytes", "handler_slots" }) do
		admission_result("false admission dimension " .. field, function(governor)
			local values = dimensions(1024, 1)
			values[field] = false
			return governor:Admit("maintenance", "tracing", 1, false, false, values)
		end)
	end

	local read_only = new_governor()
	local policy = read_only:Stats().policy
	local changed = read_only:SetPolicy({ revision = policy.revision + 1, mode = "read_only" })
	report("read-only policy fixture", changed,
		"could not configure read-only governor policy")
	if changed then
		local result = read_only:Admit("interactive", "read", 1, nil, nil, dimensions(1024, 1))
		report("implicit mutation fail-closed", result.code == "read_only",
			"omitting mutating admitted work under read_only mode; got "
				.. tostring(result.code) .. ": " .. tostring(result.message))
	end
end



-- Arbitrary nested payloads must not cause unbounded deep-copy work at scheduler boundaries.
do
	local payload = {}
	for index = 1, 5000 do payload[index] = index end

	local governor = new_governor()
	local enqueue_result = governor:Enqueue({
		id = "oversized-scheduler-payload",
		owner_id = "security-probe",
		payload = payload,
	})
	report("bounded enqueue copy", enqueue_result.code == "invalid",
		"oversized arbitrary payload was deep-copied into the scheduler; got "
			.. tostring(enqueue_result.code))
	if enqueue_result.code == "accepted" then
		local queued = governor:CancelQueued("oversized-scheduler-payload")
		if queued ~= nil then governor:MarkCompleted(queued.id, "cancelled") end
	end

	local due_governor = new_governor()
	local due_ok = due_governor:ScheduleDue("oversized-due-payload", now_ms, payload)
	report("bounded due-payload copy", due_ok == false,
		"oversized due-event payload was deep-copied into scheduler state")
	if due_ok then due_governor:PopDue(1) end
end


-- Malformed callback result tables must not interrupt retry or terminal bookkeeping.
do
	local governor = Scheduler.new()
	local dispatcher = Scheduler.new_dispatcher(governor)
	local attempts = 0
	local retry_job = dispatcher:Schedule(
		"security-probe",
		"cyclic-retry-result",
		function()
			attempts += 1
			if attempts == 1 then
				local result = { code = "retryable", retry_class = "transient" }
				result.self = result
				return result
			end
			return { code = "success" }
		end,
		{ max_retries = 1, retry_delay_ms = 10 }
	)
	if retry_job.code == "accepted" then
		for _ = 1, 200 do
			local snapshot = governor:Stats()
			if attempts >= 2 and snapshot.queue_items == 0
				and snapshot.active_reservation_tickets == 0
			then
				break
			end
			task.wait(0.001)
		end
	end
	local retry_snapshot = governor:Stats()
	local retry_dispatcher_snapshot = dispatcher:Stats()
	report("cyclic retry-result safety", retry_job.code == "accepted" and attempts == 2,
		"cyclic retry result prevented the bounded retry from finishing; attempts=" .. tostring(attempts))
	report("cyclic retry accounting",
		retry_snapshot.queue_items == 0 and retry_snapshot.active_reservation_tickets == 0
			and retry_snapshot.in_flight == 0 and retry_dispatcher_snapshot.in_flight == 0,
		"cyclic retry result left queued work, reservations, or in-flight counters allocated")
	dispatcher:Close()
end

do
	local governor = Scheduler.new()
	local dispatcher = Scheduler.new_dispatcher(governor)
	local completion_code = nil
	local completion_job = dispatcher:Schedule(
		"security-probe",
		"cyclic-completion-result",
		function()
			local result = { code = "success" }
			result.self = result
			return result
		end,
		{
			on_complete = function(result)
				completion_code = result.code
			end,
		}
	)
	if completion_job.code == "accepted" then
		for _ = 1, 100 do
			local snapshot = governor:Stats()
			if snapshot.queue_items == 0 and snapshot.active_reservation_tickets == 0 then break end
			task.wait(0.001)
		end
	end
	local completion_snapshot = governor:Stats()
	local dispatcher_snapshot = dispatcher:Stats()
	report("cyclic completion-result safety", completion_job.code == "accepted"
		and completion_code == "invalid_result",
		"cyclic callback result did not degrade safely for on_complete; code="
			.. tostring(completion_code))
	report("cyclic completion accounting",
		completion_snapshot.queue_items == 0 and completion_snapshot.active_reservation_tickets == 0
			and completion_snapshot.in_flight == 0 and dispatcher_snapshot.in_flight == 0,
		"cyclic completion result prevented terminal state and counter cleanup")
	dispatcher:Close()
end

if #findings > 0 then
	for _, finding in ipairs(findings) do
		warn("[SAFETY FINDING] " .. finding)
	end
	error(("scheduler safety probes found %d issue(s)"):format(#findings))
end

print("[PASS] Scheduler reserve boundaries, policy validation, and malformed-option rejection.")
