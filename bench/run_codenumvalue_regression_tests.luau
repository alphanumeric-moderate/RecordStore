--!nocheck
-- Exercises CodeNumValue under Lune with small shims for Roblox APIs.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local builtin_typeof = typeof

local HttpService = {
    JSONEncode = function(_self, value)
        return serde.encode("json", value)
    end,
    JSONDecode = function(_self, value)
        return serde.decode("json", value)
    end,
}

local function load_module(path, name, environment)
    return luau.load(fs.readFile(path), {
        debugName = name,
        environment = environment or {},
    })()
end

local base_game = {
    GetService = function(_self, name)
        assert(name == "HttpService", "unexpected CodeNum service: " .. tostring(name))
        return HttpService
    end,
}

local CodeNum = load_module("src/CodeNum.luau", "CodeNum", {
    game = base_game,
})
local NumberFormatter = load_module("src/PlayerDataInitializer/NumberFormatter.luau", "NumberFormatter", {
    game = base_game,
})

local codeNumModule = {
    __mockInstance = true,
    ClassName = "ModuleScript",
}
function codeNumModule:IsA(className)
    return className == "ModuleScript"
end

local ReplicatedStorage = {
    FindFirstChild = function(_self, name)
        if name == "CodeNum" then
            return codeNumModule
        end
        return nil
    end,
}

local services = {
    HttpService = HttpService,
    ReplicatedStorage = ReplicatedStorage,
}
local game = {
    GetService = function(_self, name)
        local service = services[name]
        assert(service ~= nil, "unexpected CodeNumValue service: " .. tostring(name))
        return service
    end,
}

local Instance = {
    new = function(className)
        local instance = {
            __mockInstance = true,
            ClassName = className,
            Name = "",
            Value = "",
        }
        function instance:IsA(expectedClass)
            return self.ClassName == expectedClass
        end
        function instance:Destroy()
            self.Destroyed = true
        end
        return instance
    end,
}

local api_calls = { encode = 0, decode = 0 }
local CodeNumAPI = {
    encode = function(value)
        api_calls.encode += 1
        return CodeNum.encode(value)
    end,
    decode = function(value)
        api_calls.decode += 1
        return CodeNum.decode(value)
    end,
    toString = function(value)
        return CodeNum.toString(value)
    end,
}

local CodeNumValue = load_module("src/PlayerDataInitializer/CodeNumValue.luau", "CodeNumValue", {
    game = game,
    script = { Parent = { NumberFormatter = NumberFormatter } },
    Instance = Instance,
    typeof = function(value)
        if type(value) == "table" and rawget(value, "__mockInstance") == true then
            return "Instance"
        end
        return builtin_typeof(value)
    end,
    require = function(module)
        if module == codeNumModule then
            return CodeNumAPI
        elseif module == NumberFormatter then
            return NumberFormatter
        end
        error("unexpected module passed to mocked require")
    end,
})

local exact = CodeNum.integer("123456789012345678901234567890123456789")
local backing = CodeNumValue.new("Cash", exact)
assert(backing.Name == "Cash", "new() did not set the name")
assert(CodeNum.equals(CodeNumValue.get(backing), exact), "exact integer get() round-trip failed")
assert(CodeNumValue.is_serialized(backing.Value), "is_serialized() rejected a valid payload")
api_calls.encode = 0
api_calls.decode = 0
assert(CodeNumValue.normalize(backing.Value) == backing.Value, "canonical payload was unexpectedly changed")
assert(api_calls.encode == 1 and api_calls.decode == 1, "canonical normalization did redundant codec passes")
local noncanonical_payload = "  " .. backing.Value .. "\n"
assert(CodeNumValue.normalize(noncanonical_payload) == backing.Value, "noncanonical JSON was not canonicalized")
assert(CodeNumValue.normalize_serialized("not-json") == nil, "invalid serialized input was accepted by the fast path")
assert(CodeNumValue.format(exact) == "123.45Ud", "format() failed for exact large integers")

local symbolic = CodeNum.boogolplex()
CodeNumValue.set(backing, symbolic)
assert(CodeNum.equals(CodeNumValue.get(backing), symbolic), "symbolic set()/get() round-trip failed")
assert(CodeNumValue.format(symbolic) == CodeNum.toString(symbolic), "symbolic display fallback failed")

assert(CodeNumValue.normalize("123") == CodeNum.encode("123"), "numeric string normalization failed")
assert(not CodeNumValue.is_serialized('{"schema":"CodeNum","version":999}'), "unsupported codec version was accepted")
assert(not CodeNumValue.is_value({}), "unsupported table was accepted")
assert(not CodeNumValue.is_value(string.rep("9", 200_000)), "oversized decimal input was accepted")

local previous = backing.Value
assert(not pcall(function()
    CodeNumValue.set(backing, {})
end), "invalid assignment was accepted")
assert(backing.Value == previous, "invalid assignment changed the valid stored value")

assert(not pcall(function()
    CodeNumValue.get({})
end), "non-instance backing value was accepted")
backing:Destroy()

print("[CodeNumValue] Lune adapter regression tests passed")
