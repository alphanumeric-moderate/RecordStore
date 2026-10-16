--!strict
-- Requires CodeNum 0.2.0-preview.1 in ReplicatedStorage.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CodeNum = require(ReplicatedStorage:WaitForChild("CodeNum"))
local CodeNumValue = require(ServerScriptService:WaitForChild("CodeNumValue"))
local integer = CodeNum.integer("123456789012345678901234567890123456789")
local backing = CodeNumValue.new("Cash", integer)
assert(CodeNum.equals(CodeNumValue.get(backing), integer), "exact integer round-trip failed")
local symbolic = CodeNum.boogolplex()
CodeNumValue.set(backing, symbolic)
assert(CodeNum.equals(CodeNumValue.get(backing), symbolic), "symbolic hyperoperation round-trip failed")
assert(backing.Value == CodeNum.encode(symbolic), "backing differs from CodeNum's native encoder")
assert(CodeNumValue.format(integer) == "123.45No", "custom integer suffix formatting failed")
local previous = backing.Value
assert(not pcall(function() CodeNumValue.set(backing, {}) end), "plain table was accepted")
assert(backing.Value == previous, "invalid assignment changed last valid serialized value")
backing:Destroy()
print("[CodeNumValue] regression tests passed")
