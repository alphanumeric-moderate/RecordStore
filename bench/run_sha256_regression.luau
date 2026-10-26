--!nocheck
local Shim = require("./RobloxShim")
local initializer = Shim.environment.game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer")
local SHA256 = Shim.environment.require(initializer:WaitForChild("RecordStoreSHA256"))

local function expect(value, message)
	if not value then error(message, 2) end
end

local vectors = {
	{
		input = "",
		digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	},
	{
		input = "abc",
		digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	},
	{
		input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
		digest = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
	},
	{
		input = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"
			.. "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
		digest = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
	},
}

for index, vector in ipairs(vectors) do
	local observed = SHA256.digest(vector.input)
	expect(observed == vector.digest,
		"SHA-256 known-answer vector " .. tostring(index) .. " failed: " .. observed)
end

local binary = string.char(0, 1, 127, 128, 255, 0, 42)
expect(SHA256.digest(binary) == SHA256.digest(binary),
	"SHA-256 changed across identical binary inputs")
expect(not pcall(SHA256.digest, 42), "SHA-256 accepted a non-string input")

print("[SHA256] standard empty, short, multi-block, long-padding, binary and type-validation vectors passed")
