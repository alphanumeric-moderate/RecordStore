--!nocheck

local Shim = require("./alyanum_shim")
local AlyaNumValue, AlyaNum, Formatter = Shim.load_alyanum_value()
local serde = require("@lune/serde")

local high = AlyaNum.new(10):pow(1000)
local payload = AlyaNumValue.encode(high)
local envelope = serde.decode("json", payload)
assert(envelope.schema == "AlyaNumValue" and envelope.version == 1)
assert(envelope.value.kind == "number")
local restored = AlyaNumValue.decode(payload)
assert(AlyaNum.toString(restored) == AlyaNum.toString(high))

local special = AlyaNumValue.normalize(math.huge)
assert(AlyaNumValue.format(special) == "Infinity")
assert(AlyaNumValue.format(AlyaNumValue.normalize(-math.huge)) == "-Infinity")
assert(AlyaNumValue.format(AlyaNumValue.normalize(0 / 0)) == "NaN")

local old_value = serde.encode("json", {
	schema = "InfiniteMathValue",
	version = 1,
	value = { kind = "number", first = 1, second = 12 },
})
local migrated = AlyaNumValue.normalize(old_value)
local migrated_envelope = serde.decode("json", migrated)
assert(migrated_envelope.schema == "AlyaNumValue")
assert(AlyaNumValue.format(migrated) == "1T")

local old_integer = '{"schema":"CodeNum","version":2,"value":{"kind":"integer","sign":1,"digits":"123456789012345678901234567890"}}'
local converted = AlyaNumValue.normalize(old_integer)
assert(serde.decode("json", converted).schema == "AlyaNumValue")

local old_hyper = '{"schema":"CodeNum","version":2,"value":{"kind":"hyper","base":{"kind":"finite","value":10},"arrows":{"kind":"integer","sign":1,"digits":"100"},"height":{"kind":"finite","value":10}}}'
assert(AlyaNumValue.normalize(old_hyper) == old_hyper)
assert(string.find(AlyaNumValue.format(old_hyper), "↑{100}", 1, true) ~= nil)

local future = '{"schema":"AlyaNumValue","version":99,"value":{}}'
assert(AlyaNumValue.is_unsupported_version(future))
assert(not AlyaNumValue.is_serialized(future))
assert(not pcall(function() AlyaNumValue.normalize(future) end))

print("[AlyaNumValue] persistence and legacy conversion regressions passed")
