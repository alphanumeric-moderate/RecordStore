--!nocheck
-- Adversarial safety probes for PR #37 scheduler admission and input validation.
-- Findings intentionally fail this workflow until the scheduler protects these invariants.

local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")
local findings = {}

local function report(name, ok, detail)
	if not ok then
		table.insert(findings, name .. ": " .. detail)
	end
end

local function dimensions(bytes, handlers)
	return {
		read_units = 0,
		write_units = 0,
		estimated_bytes = bytes,
		handler_slots = handlers,
	}
end

-- Noncritical estimated bytes must not consume the entire shared budget needed
-- by critical profile persistence.
do
	local governor = Scheduler.new()
	local byte_cap = 16_777_216
	local noncritical = governor:Admit(
		"maintenance", "read", 1, false, false, dimensions(byte_cap, 1)
	)
	report("byte-reserve fixture", noncritical.code == "admitted",
		"could not admit noncritical byte-saturation fixture: " .. tostring(noncritical.code))
	if noncritical.code == "admitted" then
		local critical = governor:Admit(
			"profile_save", "update_async", 1, true, false,
			{ read_units = 1, write_units = 1, estimated_bytes = 16_384, handler_slots = 1 }
		)
		report("critical byte reserve", critical.code == "admitted",
			"noncritical work consumed the entire estimated-byte budget and blocked critical profile-save admission; got "
				.. tostring(critical.code) .. ": " .. tostring(critical.message))
		governor:Release(noncritical)
		if critical.code == "admitted" then governor:Release(critical) end
	end
end

-- A caller-supplied handler-slot estimate must not consume all slots needed by
-- critical work. This is independently bounded from the dispatched item count.
do
	local governor = Scheduler.new()
	local noncritical = governor:Admit(
		"maintenance", "read", 1, false, false, dimensions(16_384, 16)
	)
	report("handler-slot fixture", noncritical.code == "admitted",
		"could not admit noncritical handler-slot fixture: " .. tostring(noncritical.code))
	if noncritical.code == "admitted" then
		local critical = governor:Admit(
			"profile_save", "update_async", 1, true, false,
			{ read_units = 1, write_units = 1, estimated_bytes = 16_384, handler_slots = 1 }
		)
		report("critical handler-slot reserve", critical.code == "admitted",
			"noncritical work consumed all handler slots and blocked critical profile-save admission; got "
				.. tostring(critical.code) .. ": " .. tostring(critical.message))
		governor:Release(noncritical)
		if critical.code == "admitted" then governor:Release(critical) end
	end
end

-- Optional fields default only when absent; malformed false values should not
-- silently turn into a valid default lane.
do
	local governor = Scheduler.new()
	local result = governor:Enqueue({
		id = "malformed-false-lane",
		owner_id = "security-probe",
		lane = false,
	})
	report("lane validation", result.code == "invalid",
		"lane=false was silently normalized instead of rejected; got " .. tostring(result.code))
	if result.code == "accepted" then
		local item = governor:TakeNext()
		if item ~= nil then governor:MarkCompleted(item.id, "cancelled") end
	end
end

if #findings > 0 then
	for _, finding in ipairs(findings) do
		warn("[SAFETY FINDING] " .. finding)
	end
	error(("scheduler safety probes found %d issue(s)"):format(#findings))
end

print("[PASS] Scheduler critical-resource reserves and strict option validation.")
