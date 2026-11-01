--!strict

local part: Part = workspace.TypecheckPart
local position: Vector3 = part.Position
assert(position.Magnitude >= 0)
