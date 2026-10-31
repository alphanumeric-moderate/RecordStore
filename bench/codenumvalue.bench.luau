--!nocheck
-- CodSpeed scenario: CodeNumValue normalization, persistence, and display formatting.
local Shim = require("./codenum_shim")
local CodeNumValue, CodeNum = Shim.load_codenum_value()
local large = CodeNum.fromScientific(1.25, "1000")
local payload = CodeNumValue.encode(large)
for _ = 1, 500 do
	local normalized = CodeNumValue.normalize(payload)
	local decoded = CodeNumValue.decode(normalized)
	assert(CodeNum.compare(decoded, large) == 0, "CodeNumValue codec round-trip changed the value")
	local formatted = CodeNumValue.format(normalized)
	assert(type(formatted) == "string" and #formatted > 0,
		"CodeNumValue formatting returned an empty string")
end
