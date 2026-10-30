--!nocheck

local Shim = require("./alyanum_shim")
local AlyaNum, Formatter = Shim.load_alyanum()

assert(Formatter.format(999) == "999")
assert(Formatter.format(1_000) == "1K")
assert(Formatter.format(1_250) == "1.25K")
assert(Formatter.format(999_999) == "1M")
assert(Formatter.format(1_000_000_000_000) == "1T")
assert(Formatter.format(-1_500_000_000) == "-1.5B")
assert(Formatter.format(math.huge) == "Infinity")
assert(Formatter.format(-math.huge) == "-Infinity")
assert(Formatter.format(0 / 0) == "NaN")
assert(Formatter.format(1_200_000, { decimals = 3, trim_trailing_zeros = false }) == "1.200M")
assert(Formatter.format(1_200_000, { decimals = 3 }) == "1.2M")
assert(Formatter.format(1, { decimals = 3, trim_trailing_zeros = false }) == "1.000")

-- Formatter calls must neither depend on nor overwrite another caller's precision.
AlyaNum.changeDecimalPoints(4)
local external_before = AlyaNum.toString(AlyaNum.new(1_234.567))
assert(external_before == "1.2346K")
assert(Formatter.format(1_234.567) == "1.23K")
assert(Formatter.format(1_234.567, { decimals = 6 }) == "1.234567K")
assert(Formatter.format(-1_234.567, { decimals = 1 }) == "-1.2K")
assert(Formatter.format(1_999, { decimals = 0 }) == "2K")
assert(Formatter.format(999_999, { decimals = 2 }) == "1M")
assert(Formatter.format(1_234.5, { decimals = 4, trim_trailing_zeros = false }) == "1.2345K")
assert(AlyaNum.toString(AlyaNum.new(1_234.567)) == external_before,
	"formatter changed the caller's AlyaNum precision")
AlyaNum.changeDefaultAbbreviation("scientific")
assert(Formatter.format(1_234.567, { decimals = 3 }) == "1.235e3")
assert(AlyaNum.toString(AlyaNum.new(1_234.567)) == "1.2345e3")
AlyaNum.changeDefaultAbbreviation("suffix")
AlyaNum.changeDecimalPoints(2)

local large = AlyaNum.new(10):pow(1000)
assert(AlyaNum.toNumber(large) == math.huge, "large AlyaNum should overflow only when converted to native")
assert(Formatter.format(large) ~= "", "large AlyaNum did not format")
assert(not pcall(function() AlyaNum.new(math.huge) end),
	"AlyaNum must not receive IEEE infinity as an ordinary value")

print("[AlyaNum] arithmetic, range, and display regressions passed")
