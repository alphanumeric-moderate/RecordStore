--!strict

local var: number? = nil
local function repro(): ()
    for _ = 1, 1 do
        if var then
            math.sin(var)
        end
    end
end
