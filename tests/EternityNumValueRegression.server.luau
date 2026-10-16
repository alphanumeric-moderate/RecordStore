--!strict
-- Run this server Script in Roblox Studio through tests.project.json.

local ServerScriptService = game:GetService("ServerScriptService")
local EternityNumValue = require(ServerScriptService:WaitForChild("EternityNumValue"))

local original = { 1, 1, 11 }
local backing = EternityNumValue.new("Cash", original)
assert(EternityNumValue.equals(EternityNumValue.get(backing), original), "StringValue backing failed")

EternityNumValue.set(backing, { 1, 2, 15 })
assert(
	EternityNumValue.equals(EternityNumValue.get(backing), { 1, 2, 15 }),
	"set/get changed the tuple"
)
assert(not pcall(function()
	EternityNumValue.set(backing, { 1, 0, math.huge })
end), "non-finite components must be rejected")
assert(
	EternityNumValue.equals(EternityNumValue.get(backing), { 1, 2, 15 }),
	"invalid assignment changed the last valid value"
)

backing:Destroy()
print("[EternityNumValue] regression tests passed")
