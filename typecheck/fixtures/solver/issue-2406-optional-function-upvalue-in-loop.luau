--!strict

local function repro(g: (() -> ())?): ()
    (function()
        for i = 0, 1 do
            if g then
                g()
            end
        end
    end)()
end
