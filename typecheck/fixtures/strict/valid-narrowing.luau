--!strict

local function normalize(value: number?): number
    if value == nil then
        return 0
    end

    return math.floor(value)
end

local function identity<T>(value: T): T
    return value
end

local count: number = identity(normalize(12.8))
assert(count == 12)
