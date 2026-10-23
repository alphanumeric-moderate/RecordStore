--!nonstrict
-- InfiniteMath Revised arithmetic/range regression suite under Lune.
local Shim = require("./infinimath_shim")
local InfiniteMath = Shim.load_infinitemath()

local native_range = InfiniteMath.new(1e308)
local above_native = InfiniteMath.new("1,1000")
local very_large = InfiniteMath.new("1,1000000000000")
local beyond_previous_limit = InfiniteMath.new({ 1, 1e100 })

assert(native_range.first ~= 0, "native finite input was not represented")
assert(above_native.second == 1000, "explicit exponent input was truncated")
assert(very_large.second == 1e12, "large exponent input was truncated")
assert(beyond_previous_limit.second == 1e100, "large numeric exponent input was truncated")

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

print("[InfiniteMath] Lune arithmetic and upper-range regression tests passed")
