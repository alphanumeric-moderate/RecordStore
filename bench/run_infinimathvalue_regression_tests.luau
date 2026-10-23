--!nonstrict
-- InfiniteMathValue persistence/formatting adapter regressions under Lune.
local Shim = require("./infinimath_shim")
local InfiniteMathValue, InfiniteMath = Shim.load_infinitemath_value()
local serde = require("@lune/serde")

local initial = InfiniteMath.new("1,1000000000000")
local maximum = InfiniteMath.new({ 1, 1e308 })
local maximum_payload = InfiniteMathValue.encode(maximum)
local maximum_restored = InfiniteMathValue.decode(maximum_payload)
assert(maximum_restored.first == maximum.first and maximum_restored.second == 1e308,
	"maximum finite exponent was not preserved by JSON serialization")
local backing = InfiniteMathValue.new("Cash", initial)
assert(backing.Name == "Cash", "new() did not set the backing name")
assert(InfiniteMathValue.is_serialized(backing.Value), "canonical payload was rejected")
local decoded = InfiniteMathValue.get(backing)
assert(decoded.second == initial.second, "get() lost the large exponent")
assert(decoded.first == initial.first, "get() changed the mantissa")

local scaled = decoded * 10
InfiniteMathValue.set(backing, scaled)
local restored = InfiniteMathValue.get(backing)
assert(restored.second == scaled.second, "set()/get() lost the exponent")
assert(restored.first == scaled.first, "set()/get() lost the mantissa")
assert(type(InfiniteMathValue.format(backing.Value)) == "string", "format() did not return text")
assert(InfiniteMathValue.format(InfiniteMath.new("1,6"), { decimals = 3, trim_trailing_zeros = false }) == "1.000M",
	"format() did not honor trim_trailing_zeros=false")

local legacy_integer = '{"schema":"CodeNum","version":2,"value":{"kind":"integer","sign":1,"digits":"123456789012345678901234567890"}}'
local migrated = InfiniteMathValue.normalize(legacy_integer)
local migrated_envelope = serde.decode("json", migrated)
assert(migrated_envelope.schema == "InfiniteMathValue", "convertible CodeNum payload was not migrated")
local migrated_number = InfiniteMathValue.decode(migrated)
assert(migrated_number.second == 29, "legacy integer magnitude was not preserved")

local legacy_unrepresentable = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
assert(InfiniteMathValue.is_serialized(legacy_unrepresentable), "unrepresentable legacy data was rejected")
assert(InfiniteMathValue.normalize(legacy_unrepresentable) == legacy_unrepresentable,
	"unrepresentable legacy data was not preserved verbatim")
assert(InfiniteMathValue.format(legacy_unrepresentable) ~= "", "legacy symbolic fallback was not displayable")
assert(string.find(InfiniteMathValue.format(legacy_unrepresentable), "↑{100}", 1, true) ~= nil,
	"legacy hyperoperation arrow count was misleadingly truncated")

local nan_payload = InfiniteMathValue.normalize(0 / 0)
assert(InfiniteMathValue.format(nan_payload) == "NaN", "NaN special-value round-trip failed")
assert(not InfiniteMathValue.is_serialized('{"schema":"InfiniteMathValue","version":99,"value":{}}'),
	"future codec version was accepted")
assert(not InfiniteMathValue.is_value({}), "unsupported input table was accepted")
assert(not InfiniteMathValue.is_value(string.rep("9", 200_000)), "oversized input was accepted")

local previous = backing.Value
assert(not pcall(function() InfiniteMathValue.set(backing, {}) end), "invalid assignment was accepted")
assert(backing.Value == previous, "invalid assignment changed the existing backing value")
assert(not pcall(function() InfiniteMathValue.get({}) end), "non-StringValue backing instance was accepted")
backing:Destroy()

print("[InfiniteMathValue] Lune adapter regression tests passed")
