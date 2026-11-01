--!strict

local function outer(foo: { value: boolean }?)
    local function inner()
        for index = 1, 20 do
            if foo and foo.value then
            end
        end
    end
    inner()
end
