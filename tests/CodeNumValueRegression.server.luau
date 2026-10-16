--!strict
-- Requires CodeNum 0.2.0-preview.1 in ReplicatedStorage.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CodeNum = require(ReplicatedStorage:WaitForChild("CodeNum"))
local CodeNumValue = require(ServerScriptService:WaitForChild("CodeNumValue"))
local integer = CodeNum.integer("123456789012345678901234567890123456789")
local backing = CodeNumValue.new("Cash", integer)
assert(CodeNum.equals(CodeNumValue.get(backing), integer), "exact integer round-trip failed")
assert(CodeNumValue.is_serialized(backing.Value), "encoded backing value was not recognized")
assert(not CodeNum.equals({}, 1), "equals must reject unsupported inputs without throwing")
local incremented = CodeNum.add(integer, CodeNum.integer("1"))
assert(
    CodeNum.toString(incremented) == "123456789012345678901234567890123456790",
    "large exact integer addition failed"
)
local symbolic = CodeNum.boogolplex()
CodeNumValue.set(backing, symbolic)
assert(CodeNum.equals(CodeNumValue.get(backing), symbolic), "symbolic hyperoperation round-trip failed")
assert(backing.Value == CodeNum.encode(symbolic), "backing differs from CodeNum's native encoder")
assert(CodeNumValue.format(integer) == "123.45Ud", "custom integer suffix formatting failed")
local previous = backing.Value
assert(not pcall(function() CodeNumValue.set(backing, {}) end), "plain table was accepted")
assert(backing.Value == previous, "invalid assignment changed last valid serialized value")
assert(not CodeNumValue.is_serialized('{"schema":"CodeNum","version":999}'), "future codec version was accepted")
assert(not CodeNumValue.is_value({}), "unsupported table input was accepted")
backing:Destroy()
print("[CodeNumValue] regression tests passed")
