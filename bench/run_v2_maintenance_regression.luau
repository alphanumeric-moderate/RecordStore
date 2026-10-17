--!nocheck
-- Tests bounded payload assessments and versioned codec fallback contracts.
-- A post-decode byte check cannot prevent a malicious codec from allocating first; codecs
-- must also honor the supplied maximum-output hint.
local Shim = require("./RobloxShim")
local serde = require("@lune/serde")
local RecordStore = Shim.load_isolated("v2-maintenance")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })
local maintenance = V2.Maintenance

local invalid_limit = maintenance.AssessPayload({ value = "x" }, -1)
assert(invalid_limit.code == "invalid", "negative payload limit was accepted")
local fractional_limit = maintenance.AssessPayload({ value = "x" }, 1.5)
assert(fractional_limit.code == "invalid", "fractional payload limit was accepted")
local beyond_platform_limit = maintenance.AssessPayload({ value = "x" }, 3_800_001)
assert(beyond_platform_limit.code == "invalid", "payload limit above the hard bound was accepted")

local value = { a = 1, b = "two" }
local codec = {
	id = "regression-codec",
	revision = "r1",
	encode = function(input, _maximum_bytes)
		assert(input.a == 1 and input.b == "two", "encoder did not receive a clone of the input")
		return "z"
	end,
	decode = function(encoded, revision, maximum_output_bytes)
		assert(encoded == "z" and revision == "r1", "decoder received invalid codec identity")
		assert(maximum_output_bytes >= 1, "decoder did not receive the output bound")
		return { a = 1, b = "two" }
	end,
}
local encoded = maintenance.SelectEncoding(value, codec, {
	maximum_bytes = 64,
	compression_threshold_bytes = 0,
})
assert(encoded.code ~= "invalid" and encoded.encoding == "codec" and encoded.payload == "z",
	"valid smaller codec output was not selected")

local registry = { [codec.id] = codec }
local decoded, decode_error = maintenance.DecodeEncoding(encoded, registry, { maximum_decoded_bytes = 64 })
assert(decode_error == nil and decoded.a == 1 and decoded.b == "two",
	"valid encoded payload did not round-trip")
decoded.a = 9
assert(value.a == 1, "decoded value shared storage with the original input")

local wrong_revision = {
	encoding = "codec",
	payload = "z",
	codec_id = codec.id,
	codec_revision = "r0",
}
local wrong_value, wrong_error = maintenance.DecodeEncoding(wrong_revision, registry, { maximum_decoded_bytes = 64 })
assert(wrong_value == nil and wrong_error ~= nil, "unknown codec revision was accepted")

local bad_decoder = {
	id = "oversized-decoder",
	revision = "r1",
	decode = function(_encoded, _revision, _maximum_bytes)
		return { payload = string.rep("x", 200) }
	end,
}
local oversize_result, oversize_error = maintenance.DecodeEncoding({
	encoding = "codec",
	payload = "compressed",
	codec_id = bad_decoder.id,
	codec_revision = bad_decoder.revision,
}, { [bad_decoder.id] = bad_decoder }, { maximum_decoded_bytes = 64 })
assert(oversize_result == nil and string.find(oversize_error, "exceeds", 1, true) ~= nil,
	"oversized decoded output escaped the post-decode bound")

local large_encoded = {
	id = "large-encoder",
	revision = "r1",
	encode = function(_input, _maximum_bytes) return string.rep("x", 100) end,
	decode = function() return value end,
}
local oversized_encoding = maintenance.SelectEncoding(value, large_encoded, {
	maximum_bytes = 32,
	compression_threshold_bytes = 0,
})
assert(oversized_encoding.code == "capacity",
	"encoded payload above maximum_bytes was returned as a valid encoding")

local non_roundtrip = {
	id = "bad-roundtrip",
	revision = "r1",
	encode = function() return "bad" end,
	decode = function() return { a = "different" } end,
}
local roundtrip_result = maintenance.SelectEncoding(value, non_roundtrip, {
	maximum_bytes = 64,
	compression_threshold_bytes = 0,
})
assert(roundtrip_result.code == "invalid", "codec round-trip mismatch was accepted")

local raw = maintenance.SelectEncoding({ small = true }, nil, {
	maximum_bytes = 64,
	compression_threshold_bytes = 0,
})
assert(raw.encoding == "raw", "raw fallback was not retained when no codec was supplied")
local raw_decode, raw_error = maintenance.DecodeEncoding({
	encoding = "raw",
	payload = { small = true },
}, {}, { maximum_decoded_bytes = 64 })
assert(raw_error == nil and raw_decode.small == true, "bounded raw payload did not decode")
local oversized_raw, oversized_raw_error = maintenance.DecodeEncoding({
	encoding = "raw",
	payload = { huge = string.rep("y", 100) },
}, {}, { maximum_decoded_bytes = 32 })
assert(oversized_raw == nil and oversized_raw_error ~= nil, "oversized raw payload escaped the decode bound")

print("[PASS] Payload limits, codec revision, raw fallback, round-trip and decoded-output bound.")
Shim.close()
