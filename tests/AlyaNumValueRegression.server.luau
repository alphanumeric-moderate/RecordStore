--!strict

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AlyaNum = require(ReplicatedStorage:WaitForChild("AlyaNum"))
local initializer = ServerScriptService:WaitForChild("PlayerDataInitializer")
local AlyaNumValue = require(initializer:WaitForChild("AlyaNumValue"))

local large = AlyaNum.new(10):pow(1000)
local payload = AlyaNumValue.encode(large)
local envelope = HttpService:JSONDecode(payload)
assert(envelope.schema == "AlyaNumValue" and envelope.version == 1,
	"new values must use the AlyaNumValue codec")
assert(envelope.value.kind == "number", "finite values must use the numeric codec")
assert(type(envelope.value.value) == "table", "AlyaNum base representation was not serialized")

local restored = AlyaNumValue.decode(payload)
assert(AlyaNum.toString(restored) == AlyaNum.toString(large),
	"AlyaNum payload round-trip changed the value")

local backing = AlyaNumValue.new("Cash", large)
assert(backing.Name == "Cash", "new() did not set the backing name")
assert(AlyaNumValue.is_serialized(backing.Value), "canonical payload was rejected")
assert(AlyaNum.toString(AlyaNumValue.get(backing)) == AlyaNum.toString(large),
	"StringValue round-trip changed the large number")

local scaled = AlyaNum.new(10):pow(500)
AlyaNumValue.set(backing, scaled)
assert(AlyaNum.toString(AlyaNumValue.get(backing)) == AlyaNum.toString(scaled),
	"set()/get() failed for a high-range number")

local positive_payload = AlyaNumValue.normalize(math.huge)
local positive_envelope = HttpService:JSONDecode(positive_payload)
assert(positive_envelope.value.kind == "special" and positive_envelope.value.name == "+infinity",
	"positive infinity was not stored as an explicit special value")
assert(AlyaNumValue.format(positive_payload) == "Infinity",
	"positive infinity display text is incorrect")

local negative_payload = AlyaNumValue.normalize(-math.huge)
assert(AlyaNumValue.format(negative_payload) == "-Infinity",
	"negative infinity display text is incorrect")

local nan_payload = AlyaNumValue.normalize(0 / 0)
assert(AlyaNumValue.format(nan_payload) == "NaN", "NaN special-value round-trip failed")
assert(AlyaNumValue.is_value(nan_payload), "NaN payload was rejected")

local legacy_infinitemath = HttpService:JSONEncode({
	schema = "InfiniteMathValue",
	version = 1,
	value = { kind = "number", first = 1, second = 12 },
})
local migrated = AlyaNumValue.normalize(legacy_infinitemath)
local migrated_envelope = HttpService:JSONDecode(migrated)
assert(migrated_envelope.schema == "AlyaNumValue",
	"legacy InfiniteMathValue payload was not migrated to AlyaNumValue")
assert(AlyaNumValue.format(migrated) == "1T",
	"legacy InfiniteMathValue exponent was not preserved")

local legacy_special = HttpService:JSONEncode({
	schema = "InfiniteMathValue",
	version = 1,
	value = { kind = "special", name = "-infinity" },
})
assert(AlyaNumValue.format(legacy_special) == "-Infinity",
	"legacy InfiniteMathValue special value was not migrated")

local legacy_integer = '{"schema":"CodeNum","version":2,"value":{"kind":"integer","sign":1,"digits":"123456789012345678901234567890"}}'
local converted_integer = AlyaNumValue.normalize(legacy_integer)
local converted_envelope = HttpService:JSONDecode(converted_integer)
assert(converted_envelope.schema == "AlyaNumValue",
	"convertible CodeNum payload was not migrated")
local converted_number = AlyaNumValue.decode(converted_integer)
assert(math.abs(AlyaNum.toNumber(converted_number) / 1e29 - 1.23456789012345) < 1e-12,
	"legacy integer magnitude was not preserved")

local legacy_symbolic = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
assert(AlyaNumValue.normalize(legacy_symbolic) == legacy_symbolic,
	"unrepresentable legacy symbolic data must remain verbatim")
assert(string.find(AlyaNumValue.format(legacy_symbolic), "↑{100}", 1, true) ~= nil,
	"legacy symbolic fallback did not preserve the full arrow count")

local future_payload = '{"schema":"AlyaNumValue","version":99,"value":{"kind":"number","value":{}}}'
assert(not AlyaNumValue.is_serialized(future_payload), "future codec version was accepted")
assert(AlyaNumValue.is_unsupported_version(future_payload),
	"future codec version was not identified for safe handling")
assert(not AlyaNumValue.is_value({}), "unsupported input table was accepted")
assert(not AlyaNumValue.is_value(string.rep("9", 200_000)), "oversized input was accepted")

local previous = backing.Value
assert(not pcall(function() AlyaNumValue.set(backing, {}) end), "invalid assignment was accepted")
assert(backing.Value == previous, "invalid assignment changed the previous valid payload")
assert(not pcall(function() AlyaNumValue.get({}) end), "non-StringValue backing instance was accepted")

backing:Destroy()
print("[AlyaNumValue] persistence and legacy compatibility regressions passed")
