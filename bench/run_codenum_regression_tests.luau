--!nocheck
-- Executes CodeNum codec/arithmetic regressions using Lune's Luau VM and JSON backend.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local HttpService = {
    JSONEncode = function(_self, value)
        return serde.encode("json", value)
    end,
    JSONDecode = function(_self, value)
        return serde.decode("json", value)
    end,
}

local game = {
    GetService = function(_self, name)
        assert(name == "HttpService", "unexpected service: " .. tostring(name))
        return HttpService
    end,
}

local chunk = luau.load(fs.readFile("src/CodeNum.luau"), {
    debugName = "CodeNum",
    environment = { game = game },
})
local CodeNum = chunk()

assert(CodeNum.VERSION == "0.2.0-preview.1", "CodeNum version changed")
assert(CodeNum.FORMAT_VERSION == 2, "CodeNum codec version changed")

local exact_left = CodeNum.integer("123456789012345678901234567890123456789")
local exact_right = CodeNum.integer("1")
local exact_sum = CodeNum.add(exact_left, exact_right)
assert(
    CodeNum.toString(exact_sum) == "123456789012345678901234567890123456790",
    "exact large-integer addition failed"
)

local product = CodeNum.mul(
    CodeNum.integer("99999999999999999"),
    CodeNum.integer("2")
)
assert(CodeNum.toString(product) == "199999999999999998", "exact integer multiplication failed")
assert(
    CodeNum.compare(CodeNum.integer("100000000000000000000"), CodeNum.integer("99999999999999999999")) == 1,
    "large integer comparison failed"
)

for _, value in {
    exact_left,
    CodeNum.integer("-123456789012345678901234567890123456789"),
    CodeNum.scientific(1.25, "1000"),
    CodeNum.scientific(1.25, "-1000", -1),
    CodeNum.new(math.huge),
    CodeNum.new(-math.huge),
    CodeNum.new(0 / 0),
    CodeNum.boogolplex(),
} do
    local encoded = CodeNum.encode(value)
    local decoded = CodeNum.decode(encoded)
    if value.kind == "special" and value.name == "nan" then
        assert(decoded.kind == "special" and decoded.name == "nan", "NaN codec round-trip failed")
        assert(not CodeNum.equals(value, decoded), "NaN must remain unordered")
    else
        assert(CodeNum.equals(value, decoded), "encode/decode round-trip failed for " .. CodeNum.toString(value))
    end
end

assert(CodeNum.tryToNumber(CodeNum.new(math.huge)) == math.huge, "positive infinity conversion failed")
assert(CodeNum.tryToNumber(CodeNum.new(-math.huge)) == -math.huge, "negative infinity conversion failed")
assert(CodeNum.equals({}, 1) == false, "equals should reject invalid inputs without throwing")
assert(not pcall(function() CodeNum.decode('{"schema":"CodeNum","version":999,"value":{}}') end),
    "future codec version was accepted")
assert(not pcall(function() CodeNum.decode("not-json") end), "invalid JSON was accepted")

local huge_digits = string.rep("9", 3000)
local bounded_product = CodeNum.mul(CodeNum.integer(huge_digits), CodeNum.integer(huge_digits))
assert(bounded_product.kind == "expression", "oversized quadratic multiplication was not preserved symbolically")
assert(string.find(CodeNum.toString(bounded_product), "×", 1, true), "symbolic multiplication display failed")

print("[CodeNum] Luau regression tests passed")
