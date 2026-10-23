--!strict
-- Verifies InfiniteMath-backed player values in a Roblox/Rojo test place.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local InfiniteMath = require(ReplicatedStorage.InfiniteMath)
local InfiniteMathValue = require(ServerScriptService.InfiniteMathValue)

local high = InfiniteMath.new({ 1, 1e100 })
local serialized = InfiniteMathValue.encode(high)
local envelope = HttpService:JSONDecode(serialized)
assert(envelope.schema == "InfiniteMathValue" and envelope.version == 1,
	"new values must use the InfiniteMathValue codec")
assert(envelope.value.second == 1e100, "high exponent was not serialized")

local backing = InfiniteMathValue.new("Cash", high)
local restored = InfiniteMathValue.get(backing)
assert(restored.first == high.first and restored.second == high.second,
	"StringValue round-trip changed the high-range number")
assert(InfiniteMathValue.is_serialized(backing.Value), "canonical payload was rejected")
assert(InfiniteMathValue.format(backing.Value) ~= "", "high-range value did not format")

local moderate = InfiniteMath.new("1,1000")
InfiniteMathValue.set(backing, moderate)
restored = InfiniteMathValue.get(backing)
assert(restored.first == moderate.first and restored.second == moderate.second,
	"set()/get() failed for a value above the native numeric range")

local legacy_integer = '{"schema":"CodeNum","version":2,"value":{"kind":"integer","sign":1,"digits":"123456789012345678901234567890"}}'
local migrated = InfiniteMathValue.normalize(legacy_integer)
local migrated_envelope = HttpService:JSONDecode(migrated)
assert(migrated_envelope.schema == "InfiniteMathValue", "convertible CodeNum payload was not migrated")
assert(InfiniteMathValue.decode(migrated).second == 29, "legacy integer magnitude was not preserved")

local legacy_symbolic = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
assert(InfiniteMathValue.normalize(legacy_symbolic) == legacy_symbolic,
	"unrepresentable legacy symbolic data must be preserved verbatim")
assert(InfiniteMathValue.format(legacy_symbolic) ~= "", "legacy symbolic value did not format")

local previous = backing.Value
assert(not pcall(function() InfiniteMathValue.set(backing, {}) end), "invalid value was accepted")
assert(backing.Value == previous, "invalid assignment changed the previous valid payload")
assert(not InfiniteMathValue.is_serialized('{"schema":"InfiniteMathValue","version":99,"value":{}}'),
	"future codec version was accepted")
assert(not InfiniteMathValue.is_value({}), "unsupported input table was accepted")
backing:Destroy()

print("[InfiniteMathValue] high-range persistence regression passed")
