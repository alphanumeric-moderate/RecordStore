--!strict
local SHA256 = {}

local MODULUS = 4294967296
local MAX_INPUT_BYTES = 16777216

local INITIAL = {
	0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
	0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

local ROUND = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
	0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
	0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
	0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
	0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
	0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add32(...: number): number
	local result = 0
	for index = 1, select("#", ...) do
		result = (result + (select(index, ...) :: number)) % MODULUS
	end
	return result
end

local function word_at(data: string, offset: number): number
	local a, b, c, d = string.byte(data, offset, offset + 3)
	return (a :: number) * 16777216 + (b :: number) * 65536 + (c :: number) * 256 + (d :: number)
end

local function append_u64(length_bits: number): string
	local high = math.floor(length_bits / MODULUS)
	local low = length_bits % MODULUS
	return string.char(
		math.floor(high / 16777216) % 256,
		math.floor(high / 65536) % 256,
		math.floor(high / 256) % 256,
		high % 256,
		math.floor(low / 16777216) % 256,
		math.floor(low / 65536) % 256,
		math.floor(low / 256) % 256,
		low % 256
	)
end

function SHA256.digest(input: string): string
	if type(input) ~= "string" then error("SHA-256 input must be a string", 2) end
	local length = #input
	if length > MAX_INPUT_BYTES then error("SHA-256 input exceeds the 16 MiB limit", 2) end
	local padding_count = (56 - ((length + 1) % 64)) % 64
	local data = input .. string.char(0x80) .. string.rep("\0", padding_count) .. append_u64(length * 8)
	local state = table.clone(INITIAL)
	local schedule: { [number]: number } = table.create(64, 0)

	for block_offset = 1, #data, 64 do
		for index = 0, 15 do
			schedule[index] = word_at(data, block_offset + index * 4)
		end
		for index = 16, 63 do
			local x = schedule[index - 15]
			local y = schedule[index - 2]
			local sigma0 = bit32.bxor(bit32.rrotate(x, 7), bit32.rrotate(x, 18), bit32.rshift(x, 3))
			local sigma1 = bit32.bxor(bit32.rrotate(y, 17), bit32.rrotate(y, 19), bit32.rshift(y, 10))
			schedule[index] = add32(schedule[index - 16], sigma0, schedule[index - 7], sigma1)
		end

		local a, b, c, d = state[1], state[2], state[3], state[4]
		local e, f, g, h = state[5], state[6], state[7], state[8]
		for index = 0, 63 do
			local upper_e = bit32.bxor(bit32.rrotate(e, 6), bit32.rrotate(e, 11), bit32.rrotate(e, 25))
			local choose = bit32.bxor(bit32.band(e, f), bit32.band(bit32.bnot(e), g))
			local temp1 = add32(h, upper_e, choose, ROUND[index + 1], schedule[index])
			local upper_a = bit32.bxor(bit32.rrotate(a, 2), bit32.rrotate(a, 13), bit32.rrotate(a, 22))
			local majority = bit32.bxor(bit32.band(a, b), bit32.band(a, c), bit32.band(b, c))
			local temp2 = add32(upper_a, majority)
			h = g
			g = f
			f = e
			e = add32(d, temp1)
			d = c
			c = b
			b = a
			a = add32(temp1, temp2)
		end
		state[1] = add32(state[1], a)
		state[2] = add32(state[2], b)
		state[3] = add32(state[3], c)
		state[4] = add32(state[4], d)
		state[5] = add32(state[5], e)
		state[6] = add32(state[6], f)
		state[7] = add32(state[7], g)
		state[8] = add32(state[8], h)
	end

	local hex = table.create(8)
	for index, value in ipairs(state) do
		hex[index] = string.format("%08x", value)
	end
	return table.concat(hex)
end

return table.freeze(SHA256)
