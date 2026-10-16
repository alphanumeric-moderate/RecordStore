--!nocheck
-- CodSpeed scenario: exact decimal arithmetic, versioned codec round-trips, and symbolic values.
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
    debugName = "CodeNumBenchmark",
    environment = { game = game },
})
local CodeNum = chunk()

local seed = CodeNum.integer("12345678901234567890123456789012345678901234567890")
local multiplier = CodeNum.integer("987654321987654321")
local iterations = 300

for index = 1, iterations do
    local input = CodeNum.add(seed, CodeNum.integer(tostring(index)))
    local product = CodeNum.mul(input, multiplier)
    local serialized = CodeNum.encode(product)
    local restored = CodeNum.decode(serialized)
    assert(CodeNum.equals(product, restored), "CodeNum benchmark correctness guard failed")
end

local symbolic = CodeNum.boogolplex()
assert(CodeNum.equals(symbolic, CodeNum.decode(CodeNum.encode(symbolic))), "symbolic codec guard failed")
print(("[CodeNum] completed %d exact arithmetic and codec iterations"):format(iterations))
