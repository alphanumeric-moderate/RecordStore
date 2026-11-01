--!strict

local function add(value: number): number
    return value + 1
end

local result: number = add("one")
assert(result == 2)
