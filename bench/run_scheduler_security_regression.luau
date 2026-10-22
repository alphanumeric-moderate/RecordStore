--!nocheck
-- Adversarial test for PR #37's shared scheduler admission reserves.
-- This intentionally fails when accepted noncritical work can exhaust the byte
-- budget needed by internal critical persistence work.

local Scheduler = require("../src/PlayerDataInitializer/RecordStoreScheduler")

local governor = Scheduler.new()
local byte_cap = 16_777_216

local noncritical = governor:Admit(
	"maintenance",
	"read",
	1,
	false,
	false,
	{
		read_units = 0,
		write_units = 0,
		estimated_bytes = byte_cap,
		handler_slots = 1,
	}
)
assert(noncritical.code == "admitted",
	"test precondition failed: noncritical byte-saturation fixture was not admitted")

local critical = governor:Admit(
	"profile_save",
	"update_async",
	1,
	true,
	false,
	{
		read_units = 1,
		write_units = 1,
		estimated_bytes = 16_384,
		handler_slots = 1,
	}
)

governor:Release(noncritical)

assert(critical.code == "admitted",
	"SAFETY FINDING: noncritical work exhausted the entire estimated-byte budget and blocked critical profile-save admission; got "
		.. tostring(critical.code)
		.. ": "
		.. tostring(critical.message))

governor:Release(critical)
print("[PASS] Noncritical byte saturation preserves critical persistence admission.")
