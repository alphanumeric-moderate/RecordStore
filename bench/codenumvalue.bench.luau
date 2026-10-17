--!nocheck
-- Profile adapter formatting/normalization cost under the Lune runtime.
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
        assert(name == "HttpService", "unexpected core service: " .. tostring(name))
        return HttpService
    end,
}
local CodeNum = load_module("src/CodeNum.luau", "CodeNum", { game = base_game })
local NumberFormatter = load_module("src/PlayerDataInitializer/NumberFormatter.luau", "NumberFormatter", { game = base_game })

local codeNumModule = {
    __mockInstance = true,
    ClassName = "ModuleScript",
}
function codeNumModule:IsA(className)
    return className == "ModuleScript"
end

local ReplicatedStorage = {
    FindFirstChild = function(_self, name)
        return if name == "CodeNum" then codeNumModule else nil
    end,
}
local services = { HttpService = HttpService, ReplicatedStorage = ReplicatedStorage }
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
        return instance
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
        if module == codeNumModule then return CodeNum end
        if module == NumberFormatter then return NumberFormatter end
        error("unexpected module passed to mocked require")
    end,
})

local exact = CodeNum.integer("123456789012345678901234567890123456789")
local scientific = CodeNum.scientific(1.25, "1000")
local exact_payload = CodeNum.encode(exact)
local scientific_payload = CodeNum.encode(scientific)
local iterations = 500

for _ = 1, iterations do
    assert(CodeNumValue.format(exact) == "123.45Ud", "exact integer formatting changed")
    assert(CodeNumValue.format(exact_payload) == "123.45Ud", "serialized integer formatting changed")
    assert(CodeNumValue.format(scientific) == "1.25e+1000", "scientific fallback formatting changed")
    assert(CodeNumValue.format(scientific_payload) == "1.25e+1000", "serialized scientific formatting changed")
end
