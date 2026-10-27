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
expect(SHA256.digest(binary) == "0e1a47eda13788d5ca8f5d9960df6e9f8b92501607c35b7e6513bd51f48eec73",
	"SHA-256 did not preserve embedded NUL and high-bit bytes")

-- Independently calculated with Python hashlib.sha256(b"a" * length).
-- Exercise both sides of the padding and compression-block boundaries.
local boundary_vectors = {
	{ 55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
	{ 56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
	{ 57, "f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6" },
	{ 63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34" },
	{ 64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
	{ 65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0" },
	{ 119, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb" },
	{ 120, "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c" },
	{ 127, "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a" },
	{ 128, "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e" },
}
for _, vector in ipairs(boundary_vectors) do
	expect(SHA256.digest(string.rep("a", vector[1])) == vector[2],
		"SHA-256 padding/block boundary failed at " .. tostring(vector[1]) .. " bytes")
end

local bytes = {}
for byte = 0, 255 do table.insert(bytes, string.char(byte)) end
expect(SHA256.digest(table.concat(bytes)) == "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880",
	"SHA-256 failed the full byte-range reference vector")
-- Hashing another message must not retain the previous message's state.
expect(SHA256.digest("abc") == vectors[2].digest, "SHA-256 retained state between calls")

for _, invalid in { false, 42, {}, function() end } do
	expect(not pcall(SHA256.digest, invalid), "SHA-256 accepted input of type " .. type(invalid))
end
expect(not pcall(SHA256.digest, nil), "SHA-256 accepted nil input")
local oversized_ok, oversized_error = pcall(SHA256.digest, string.rep("x", 16777217))
expect(not oversized_ok and string.find(tostring(oversized_error), "16 MiB limit", 1, true) ~= nil,
	"SHA-256 did not reject an input one byte over its size limit")

print("[SHA256] known-answer, binary, padding/block boundaries, independent calls and input-limit regressions passed")
