--!strict
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CodeNum = require(ReplicatedStorage:WaitForChild("CodeNum"))
local CodeNumValue = require(ServerScriptService:WaitForChild("CodeNumValue"))

local large = CodeNum.fromScientific(1.25, "1000")
local backing = CodeNumValue.new("Cash", large)
assert(backing:IsA("StringValue"))
assert(CodeNum.compare(CodeNumValue.get(backing), large) == 0)
assert(CodeNumValue.is_serialized(backing.Value))
assert(CodeNumValue.format(backing.Value) == "1.25e1000")
CodeNumValue.set(backing, CodeNum.mul(large, 2))
assert(CodeNum.compare(CodeNumValue.get(backing), CodeNum.mul(large, 2)) == 0)

local stored = HttpService:JSONDecode(backing.Value)
assert(stored.schema == "CodeNumValue" and stored.version == 1)

local legacy = HttpService:JSONEncode({
	schema = "InfiniteMathValue",
	version = 1,
	value = { kind = "number", first = 1.25, second = 12 },
})
local migrated = CodeNumValue.normalize(legacy)
assert(HttpService:JSONDecode(migrated).schema == "CodeNumValue")
assert(CodeNum.compare(CodeNumValue.decode(migrated), 1.25e12) == 0)

print("[CodeNumValue] Roblox StringValue adapter regressions passed")
