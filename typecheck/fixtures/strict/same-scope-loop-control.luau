--!strict

local function inspect(value: number?): ()
    for _ = 1, 1 do
        if value then
            math.sin(value)
        end
    end
end

inspect(nil)
