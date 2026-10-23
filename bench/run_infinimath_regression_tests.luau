--!nonstrict
-- InfiniteMath Revised arithmetic/range regression suite under Lune.
local Shim = require("./infinimath_shim")
local InfiniteMath = Shim.load_infinitemath()

local native_range = InfiniteMath.new(1e308)
local above_native = InfiniteMath.new("1,1000")
local very_large = InfiniteMath.new("1,1000000000000")
local beyond_previous_limit = InfiniteMath.new({ 1, 1e100 })
local maximum_supported_exponent = InfiniteMath.new({ 1, 1e308 })

assert(native_range.first ~= 0, "native finite input was not represented")
assert(above_native.second == 1000, "explicit exponent input was truncated")
assert(very_large.second == 1e12, "large exponent input was truncated")
assert(beyond_previous_limit.second == 1e100, "large numeric exponent input was truncated")
assert(maximum_supported_exponent.second == 1e308, "maximum finite exponent was not represented")

local multiplied = above_native * InfiniteMath.new(2)
assert(multiplied.second == 1000, "large-range multiplication changed exponent")
assert(math.abs(multiplied.first - 2) < 1e-12, "large-range multiplication changed mantissa")

local divided = multiplied / InfiniteMath.new(2)
assert(divided.second == above_native.second, "large-range division changed exponent")
assert(math.abs(divided.first - above_native.first) < 1e-12, "large-range division changed mantissa")

local powered = InfiniteMath.new(10) ^ 1000
assert(powered.second == 1000, "power operation did not exceed native-number range")

local as_int = InfiniteMath.Int.FromRawBytes("le", { 1, 0, 0, 0 }, false)
local int_value = as_int:ToNumber()
assert(int_value.first == 1 and int_value.second == 0, "InfiniteMath.Int raw-byte conversion failed")

local canonical_a = InfiniteMath.new({ first = 10, second = 0 })
local canonical_b = InfiniteMath.new({ 1, 1 })
assert(canonical_a == canonical_b, "equivalent non-canonical representations compared unequal")
local large_minus_small = InfiniteMath.new(1) - above_native
assert(large_minus_small.first < 0 and large_minus_small.second == 1000, "subtraction with a much larger right operand lost the negative sign")
local nan = InfiniteMath.new(-1) ^ 0.5
assert(not (nan == nan), "NaN compared equal to itself")
local one = InfiniteMath.new(1)
assert(not (nan < one) and not (nan <= one) and not (one < nan) and not (one <= nan), "NaN comparisons must all be false")
local tiny = InfiniteMath.new("1,-1000")
assert(tiny:ScientificNotation(nil, false) == "1e-1000", "negative exponent notation is malformed")
assert(tostring(tiny) == "1e-1000", "tiny values underflowed to zero when formatted")
assert(tostring(InfiniteMath.new(5e-324)) ~= "0", "native subnormal input underflowed during normalization")
assert(tostring(InfiniteMath.new("1,-2")) == "0.01", "negative exponent decimal formatting failed")
assert(tostring(InfiniteMath.new("1,-10")) == "1e-10", "small decimal was formatted as zero or malformed text")
assert(tostring(InfiniteMath.new(-1.239)) == "-1.24", "negative suffix formatting rounded in the wrong direction")
assert(InfiniteMath.new(-1.239):ScientificNotation(nil, false) == "-1.24e+0", "negative scientific formatting rounded in the wrong direction")
local tiny_encoding = InfiniteMath.new({ 1, -1e308 }):ConvertForLeaderboards()
local huge_encoding = InfiniteMath.new({ 1, 1e308 }):ConvertForLeaderboards()
assert(tiny_encoding < 0 and huge_encoding > 0, "leaderboard exponent clamp lost the sign of a tiny positive value")
assert(not pcall(function() return InfiniteMath:ConvertFromLeaderboards(math.huge) end), "non-finite leaderboard encoding was accepted")
assert(not pcall(function() return InfiniteMath.new({ 1, 0.5 }):ConvertForLeaderboards() end), "fractional exponent was accepted by integer leaderboard encoding")
assert(not pcall(function() return InfiniteMath.new(1) / InfiniteMath.new(0) end), "division by zero was not rejected clearly")
assert(not pcall(function() return InfiniteMath.new({ 1, 1e308 }) * InfiniteMath.new({ 1, 1e308 }) end), "exponent overflow was not rejected")
assert(not pcall(function() return InfiniteMath.new({ first = 1, second = math.huge }) end), "non-finite table exponent was accepted")
local wide_int = InfiniteMath.Int.FromRawBytes("le", { 1, 0, 0, 0, 1, 0, 0, 0 }, false)
assert(math.abs(wide_int:ToNumber():Reverse() - 4294967297) < 1e-4, "InfiniteMath.Int conversion ignored lower limbs")
local negative_int = InfiniteMath.Int.FromRawBytes("le", { 127, 255 }, true)
local negative_bytes = negative_int:ToRawBytes("le", nil, true)
assert(#negative_bytes == 2 and negative_bytes[1] == 127 and negative_bytes[2] == 255, "negative signed integer did not preserve its two's-complement width")

print("[InfiniteMath] Lune arithmetic and upper-range regression tests passed")
