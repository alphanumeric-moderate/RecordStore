--!strict

local parent: Folder = script.Parent
local children: { Instance } = parent:GetChildren()
assert(#children >= 0)
