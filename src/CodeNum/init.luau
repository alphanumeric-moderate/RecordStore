--!strict
--!optimize 2

export type Wide = {
	_codeNum: "wide",
	m: number,
	e: number,
	expSign: number,
	expLength: number,
}

export type Value = number | Wide

export type Register = {
	_codeNum: "register",
}

type RegisterState = {
	kind: number,
	n: number,
	m: number,
	e: number,
	expSign: number,
	expLength: number,
	expData: buffer?,
}

export type Operand = Value | Register

local CodeNum = {}
local WIDE_BUFFERS: {[Wide]: buffer} = setmetatable({}, { __mode = "k" })
local WIDE_VALUES: {[Wide]: boolean} = setmetatable({}, { __mode = "k" })
local REGISTER_STATES: {[Register]: RegisterState} = setmetatable({}, { __mode = "k" })

local BASE = 67108864
local BASE_BYTES = 4
local MAX_LIMBS = 41
local BUFFER_BYTES = MAX_LIMBS * BASE_BYTES
local MAX_SAFE_INTEGER = 9007199254740991
local MAX_EXPONENT_TEXT = "1" .. string.rep("0", 308)
local MAX_EXPONENT_NUMBER = 1e308
local MAX_EXP_DATA = buffer.create(BUFFER_BYTES)
local MAX_EXP_LENGTH = 0
local SMALL_ALIGNMENT_LIMIT = 18
local MAX_PARSE_DIGITS = 4096

@native
local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

@native
local function isInteger(value: number): boolean
	return isFinite(value) and math.floor(value) == value
end

@native
local function isWide(value: Operand): boolean
	return type(value) == "table" and WIDE_VALUES[value :: Wide] == true
end

@native
local function isRegister(value: Operand): boolean
	return type(value) == "table" and REGISTER_STATES[value :: Register] ~= nil
end

@native
local function registerState(register: Register): RegisterState
	local state = REGISTER_STATES[register]
	if state == nil then
		error("CodeNum: invalid register", 3)
	end
	return state
end

local function newBuffer(): buffer
	return buffer.create(BUFFER_BYTES)
end

@native
local function readLimb(data: buffer, index: number): number
	return buffer.readu32(data, index * BASE_BYTES)
end

@native
local function writeLimb(data: buffer, index: number, value: number)
	buffer.writeu32(data, index * BASE_BYTES, value)
end

@native
local function trimLength(data: buffer, length: number): number
	while length > 1 and readLimb(data, length - 1) == 0 do
		length -= 1
	end
	return length
end

@native
local function writeSmallMagnitude(data: buffer, value: number): (number, number)
	local remaining = math.abs(value)
	local length = 0

	repeat
		local limb = remaining % BASE
		remaining = math.floor(remaining / BASE)
		writeLimb(data, length, limb)
		length += 1
	until remaining == 0 or length == MAX_LIMBS

	if remaining ~= 0 then
		error("CodeNum: exponent exceeds internal capacity", 3)
	end

	return if value < 0 then -1 else if value > 0 then 1 else 0, length
end

@native
local function smallMagnitudeLength(value: number): number
	local magnitude = math.abs(value)
	if magnitude >= BASE * BASE then
		return 3
	elseif magnitude >= BASE then
		return 2
	end
	return 1
end

@native
local function magnitudeLimb(isBig: number, small: number, length: number, data: buffer?, index: number): number
	if isBig == 1 then
		return if index < length then readLimb(data :: buffer, index) else 0
	end

	local magnitude = math.abs(small)
	if index == 0 then
		return magnitude % BASE
	elseif index == 1 then
		return math.floor(magnitude / BASE) % BASE
	elseif index == 2 then
		return math.floor(magnitude / (BASE * BASE))
	end
	return 0
end

@native
local function addMagnitudeParts(
	out: buffer,
	aIsBig: number,
	aSmall: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bLength: number,
	bData: buffer?
): number
	local aCount = if aIsBig == 1 then aLength else smallMagnitudeLength(aSmall)
	local bCount = if bIsBig == 1 then bLength else smallMagnitudeLength(bSmall)
	local length = math.max(aCount, bCount)
	local carry = 0

	for index = 0, length - 1 do
		local av = magnitudeLimb(aIsBig, aSmall, aLength, aData, index)
		local bv = magnitudeLimb(bIsBig, bSmall, bLength, bData, index)
		local sum = av + bv + carry
		if sum >= BASE then
			sum -= BASE
			carry = 1
		else
			carry = 0
		end
		writeLimb(out, index, sum)
	end

	if carry ~= 0 then
		if length >= MAX_LIMBS then
			error("CodeNum: exponent exceeds internal capacity", 3)
		end
		writeLimb(out, length, carry)
		length += 1
	end

	return length
end

@native
local function subtractMagnitudeParts(
	out: buffer,
	aIsBig: number,
	aSmall: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bLength: number,
	bData: buffer?
): number
	local aCount = if aIsBig == 1 then aLength else smallMagnitudeLength(aSmall)
	local bCount = if bIsBig == 1 then bLength else smallMagnitudeLength(bSmall)
	local borrow = 0

	for index = 0, aCount - 1 do
		local av = magnitudeLimb(aIsBig, aSmall, aLength, aData, index)
		local bv = magnitudeLimb(bIsBig, bSmall, bLength, bData, index)
		local difference = av - bv - borrow
		if difference < 0 then
			difference += BASE
			borrow = 1
		else
			borrow = 0
		end
		writeLimb(out, index, difference)
	end

	if borrow ~= 0 then
		error("CodeNum: internal exponent subtraction underflow", 3)
	end

	return trimLength(out, aCount)
end

@native
local function multiplyMagnitudeSmall(data: buffer, length: number, multiplier: number)
	local carry = 0

	for index = 0, length - 1 do
		local product = readLimb(data, index) * multiplier + carry
		local limb = product % BASE
		carry = math.floor(product / BASE)
		writeLimb(data, index, limb)
	end

	while carry > 0 do
		if length >= MAX_LIMBS then
			error("CodeNum: exponent exceeds internal capacity", 3)
		end

		local limb = carry % BASE
		carry = math.floor(carry / BASE)
		writeLimb(data, length, limb)
		length += 1
	end

	return length
end

local function addMagnitudeSmall(data: buffer, length: number, addend: number)
	local carry = addend
	local index = 0

	while carry > 0 do
		if index >= MAX_LIMBS then
			error("CodeNum: exponent exceeds internal capacity", 3)
		end

		local current = if index < length then readLimb(data, index) else 0
		local sum = current + carry
		local limb = sum % BASE
		carry = math.floor(sum / BASE)
		writeLimb(data, index, limb)

		if index >= length then
			length = index + 1
		end

		index += 1
	end

	return length
end

@native
local function compareMagnitude(a: buffer, aLength: number, b: buffer, bLength: number): number
	if aLength ~= bLength then
		return if aLength < bLength then -1 else 1
	end

	for index = aLength - 1, 0, -1 do
		local av = readLimb(a, index)
		local bv = readLimb(b, index)
		if av ~= bv then
			return if av < bv then -1 else 1
		end
	end

	return 0
end

@native
local function divideMagnitudeSmall(data: buffer, length: number, divisor: number): (number, number)
	local remainder = 0

	for index = length - 1, 0, -1 do
		local current = remainder * BASE + readLimb(data, index)
		local quotient = math.floor(current / divisor)
		remainder = current - quotient * divisor
		writeLimb(data, index, quotient)
	end

	return trimLength(data, length), remainder
end

local function bigFromDecimal(text: string, outputData: buffer?): (number, number, buffer)
	local sign = 1
	local digits = text
	local first = string.sub(digits, 1, 1)

	if first == "-" then
		sign = -1
		digits = string.sub(digits, 2)
	elseif first == "+" then
		digits = string.sub(digits, 2)
	end

	if digits == "" then
		error("CodeNum: invalid decimal exponent", 3)
	end
	digits = string.gsub(digits, "^0+", "")
	if digits == "" then
		local zeroData = outputData or newBuffer()
		return 0, 1, zeroData
	end

	if #digits > 309 then
		error("CodeNum: exponent exceeds 10^308", 3)
	end

	if string.find(digits, "[^0-9]") then
		error("CodeNum: invalid decimal exponent", 3)
	end

	local data = outputData or newBuffer()
	local length = 1

	for index = 1, #digits do
		length = multiplyMagnitudeSmall(data, length, 10)
		length = addMagnitudeSmall(data, length, tonumber(string.sub(digits, index, index)) :: number)
	end

	return sign, trimLength(data, length), data
end

local maxExponentSign: number
maxExponentSign, MAX_EXP_LENGTH = bigFromDecimal(MAX_EXPONENT_TEXT, MAX_EXP_DATA)
if maxExponentSign ~= 1 then
	error("CodeNum: invalid maximum exponent constant")
end

local function bigToString(sign: number, length: number, source: buffer): string
	local data = newBuffer()
	buffer.copy(data, 0, source, 0, length * BASE_BYTES)
	local digits = table.create(320)
	local count = 0

	while not (length == 1 and readLimb(data, 0) == 0) do
		local remainder: number
		length, remainder = divideMagnitudeSmall(data, length, 10)
		count += 1
		digits[count] = string.char(48 + remainder)
	end

	if count == 0 then
		return "0"
	end

	local result = table.create(count + 1)
	if sign < 0 then
		result[1] = "-"
		for index = 1, count do
			result[index + 1] = digits[count - index + 1]
		end
	else
		for index = 1, count do
			result[index] = digits[count - index + 1]
		end
	end

	return table.concat(result)
end

@native
local function bigToSmall(sign: number, length: number, data: buffer): number?
	local value = 0

	for index = length - 1, 0, -1 do
		local limb = readLimb(data, index)
		if value > (MAX_SAFE_INTEGER - limb) / BASE then
			return nil
		end
		value = value * BASE + limb
	end

	return value * sign
end

@native
local function compareMagnitudeToSmall(data: buffer, length: number, small: number): number
	local magnitude = math.abs(small)
	local limb0 = magnitude % BASE
	local remaining = math.floor(magnitude / BASE)
	local limb1 = remaining % BASE
	local limb2 = math.floor(remaining / BASE)
	local smallLength = if limb2 > 0 then 3 else if limb1 > 0 then 2 else 1

	if length ~= smallLength then
		return if length < smallLength then -1 else 1
	end

	for index = smallLength - 1, 0, -1 do
		local smallLimb = if index == 0 then limb0 else if index == 1 then limb1 else limb2
		local bigLimb = readLimb(data, index)
		if bigLimb ~= smallLimb then
			return if bigLimb < smallLimb then -1 else 1
		end
	end

	return 0
end

@native
local function exponentMagnitudeCompare(
	aIsBig: number,
	aSmall: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bLength: number,
	bData: buffer?
): number
	if aIsBig == 0 and bIsBig == 0 then
		local aa = math.abs(aSmall)
		local bb = math.abs(bSmall)
		return if aa < bb then -1 else if aa > bb then 1 else 0
	elseif aIsBig == 1 and bIsBig == 1 then
		return compareMagnitude(aData :: buffer, aLength, bData :: buffer, bLength)
	elseif aIsBig == 1 then
		return compareMagnitudeToSmall(aData :: buffer, aLength, bSmall)
	end

	return -compareMagnitudeToSmall(bData :: buffer, bLength, aSmall)
end

@native
local function exponentCompare(
	aIsBig: number,
	aSmall: number,
	aSign: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bSign: number,
	bLength: number,
	bData: buffer?
): number
	local resolvedASign = if aIsBig == 1 then aSign else if aSmall < 0 then -1 else if aSmall > 0 then 1 else 0
	local resolvedBSign = if bIsBig == 1 then bSign else if bSmall < 0 then -1 else if bSmall > 0 then 1 else 0

	if resolvedASign ~= resolvedBSign then
		return if resolvedASign < resolvedBSign then -1 else 1
	end
	if resolvedASign == 0 then
		return 0
	end

	local result = exponentMagnitudeCompare(
		aIsBig,
		aSmall,
		aLength,
		aData,
		bIsBig,
		bSmall,
		bLength,
		bData
	)
	return if resolvedASign < 0 then -result else result
end

@native
local function exponentAdd(
	aIsBig: number,
	aSmall: number,
	aSign: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bSign: number,
	bLength: number,
	bData: buffer?,
	outData: buffer?
): (number, number, number, number, buffer?)
	if bIsBig == 0 and bSmall == 0 then
		return aIsBig, aSmall, aSign, aLength, aData
	elseif aIsBig == 0 and aSmall == 0 then
		return bIsBig, bSmall, bSign, bLength, bData
	end

	if aIsBig == 0 and bIsBig == 0 then
		local samePositiveSign = aSmall > 0 and bSmall > 0
		local sameNegativeSign = aSmall < 0 and bSmall < 0
		if samePositiveSign and aSmall <= MAX_SAFE_INTEGER - bSmall then
			return 0, aSmall + bSmall, 0, 0, nil
		elseif sameNegativeSign and -aSmall <= MAX_SAFE_INTEGER + bSmall then
			return 0, aSmall + bSmall, 0, 0, nil
		elseif not samePositiveSign and not sameNegativeSign then
			return 0, aSmall + bSmall, 0, 0, nil
		end
	end

	local aResolvedSign = if aIsBig == 1 then aSign else if aSmall < 0 then -1 else if aSmall > 0 then 1 else 0
	local bResolvedSign = if bIsBig == 1 then bSign else if bSmall < 0 then -1 else if bSmall > 0 then 1 else 0
	local out = outData or newBuffer()
	local resultSign: number
	local resultLength: number

	if aResolvedSign == 0 then
		resultSign = bResolvedSign
		if bIsBig == 1 then
			resultLength = bLength
			if out ~= bData then
				buffer.copy(out, 0, bData :: buffer, 0, bLength * BASE_BYTES)
			end
		else
			_, resultLength = writeSmallMagnitude(out, bSmall)
		end
	elseif bResolvedSign == 0 then
		resultSign = aResolvedSign
		if aIsBig == 1 then
			resultLength = aLength
			if out ~= aData then
				buffer.copy(out, 0, aData :: buffer, 0, aLength * BASE_BYTES)
			end
		else
			_, resultLength = writeSmallMagnitude(out, aSmall)
		end
	elseif aResolvedSign == bResolvedSign then
		resultSign = aResolvedSign
		resultLength = addMagnitudeParts(
			out, aIsBig, aSmall, aLength, aData, bIsBig, bSmall, bLength, bData
		)
	else
		local magnitudeComparison = exponentMagnitudeCompare(
			aIsBig, aSmall, aLength, aData, bIsBig, bSmall, bLength, bData
		)
		if magnitudeComparison == 0 then
			return 0, 0, 0, 0, nil
		elseif magnitudeComparison > 0 then
			resultSign = aResolvedSign
			resultLength = subtractMagnitudeParts(
				out, aIsBig, aSmall, aLength, aData, bIsBig, bSmall, bLength, bData
			)
		else
			resultSign = bResolvedSign
			resultLength = subtractMagnitudeParts(
				out, bIsBig, bSmall, bLength, bData, aIsBig, aSmall, aLength, aData
			)
		end
	end

	resultLength = trimLength(out, resultLength)
	if resultLength <= 3 then
		local smallResult = bigToSmall(resultSign, resultLength, out)
		if smallResult ~= nil then
			return 0, smallResult, 0, 0, nil
		end
	end

	return 1, 0, resultSign, resultLength, out
end

@native
local function exponentAddSmall(
	isBig: number,
	small: number,
	sign: number,
	length: number,
	data: buffer?,
	delta: number,
	outData: buffer?
): (number, number, number, number, buffer?)
	return exponentAdd(isBig, small, sign, length, data, 0, delta, 0, 0, nil, outData)
end

@native
local function magnitudeDifferenceSmall(
	aIsBig: number,
	aSmall: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bLength: number,
	bData: buffer?
): number?
	local aCount = if aIsBig == 1 then aLength else smallMagnitudeLength(aSmall)
	local bCount = if bIsBig == 1 then bLength else smallMagnitudeLength(bSmall)
	local length = math.max(aCount, bCount)
	local borrow = 0
	local lowDifference = 0

	for index = 0, length - 1 do
		local av = magnitudeLimb(aIsBig, aSmall, aLength, aData, index)
		local bv = magnitudeLimb(bIsBig, bSmall, bLength, bData, index)
		local difference = av - bv - borrow
		if difference < 0 then
			difference += BASE
			borrow = 1
		else
			borrow = 0
		end
		if index == 0 then
			lowDifference = difference
		elseif difference ~= 0 then
			return nil
		end
	end

	if borrow ~= 0 or lowDifference > SMALL_ALIGNMENT_LIMIT then
		return nil
	end
	return lowDifference
end

@native
local function magnitudeSumSmall(
	aIsBig: number,
	aSmall: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bLength: number,
	bData: buffer?
): number?
	local aCount = if aIsBig == 1 then aLength else smallMagnitudeLength(aSmall)
	local bCount = if bIsBig == 1 then bLength else smallMagnitudeLength(bSmall)
	local length = math.max(aCount, bCount)
	local carry = 0
	local lowSum = 0

	for index = 0, length - 1 do
		local sum = magnitudeLimb(aIsBig, aSmall, aLength, aData, index)
			+ magnitudeLimb(bIsBig, bSmall, bLength, bData, index) + carry
		local limb = sum % BASE
		carry = math.floor(sum / BASE)
		if index == 0 then
			lowSum = limb
		elseif limb ~= 0 then
			return nil
		end
	end

	if carry ~= 0 or lowSum > SMALL_ALIGNMENT_LIMIT then
		return nil
	end
	return lowSum
end

@native
local function exponentAlignment(
	aIsBig: number,
	aSmall: number,
	aSign: number,
	aLength: number,
	aData: buffer?,
	bIsBig: number,
	bSmall: number,
	bSign: number,
	bLength: number,
	bData: buffer?
): (number, number?)
	local aResolvedSign = if aIsBig == 1 then aSign else if aSmall < 0 then -1 else if aSmall > 0 then 1 else 0
	local bResolvedSign = if bIsBig == 1 then bSign else if bSmall < 0 then -1 else if bSmall > 0 then 1 else 0

	if aResolvedSign == 0 then
		if bResolvedSign == 0 then
			return 0, 0
		end
		local gap = if bIsBig == 0 and math.abs(bSmall) <= SMALL_ALIGNMENT_LIMIT then math.abs(bSmall) else nil
		return if bResolvedSign > 0 then -1 else 1, gap
	elseif bResolvedSign == 0 then
		local gap = if aIsBig == 0 and math.abs(aSmall) <= SMALL_ALIGNMENT_LIMIT then math.abs(aSmall) else nil
		return if aResolvedSign > 0 then 1 else -1, gap
	elseif aResolvedSign ~= bResolvedSign then
		return if aResolvedSign > 0 then 1 else -1,
			magnitudeSumSmall(aIsBig, aSmall, aLength, aData, bIsBig, bSmall, bLength, bData)
	end

	local magnitudeComparison = exponentMagnitudeCompare(
		aIsBig, aSmall, aLength, aData, bIsBig, bSmall, bLength, bData
	)
	if magnitudeComparison == 0 then
		return 0, 0
	end

	local gap = if magnitudeComparison > 0
		then magnitudeDifferenceSmall(aIsBig, aSmall, aLength, aData, bIsBig, bSmall, bLength, bData)
		else magnitudeDifferenceSmall(bIsBig, bSmall, bLength, bData, aIsBig, aSmall, aLength, aData)
	local order = if aResolvedSign < 0 then -magnitudeComparison else magnitudeComparison
	return order, gap
end

@native
local function checkExponent(
	isBig: number,
	small: number,
	sign: number,
	length: number,
	data: buffer?
)
	if isBig == 0 then
		if math.abs(small) > MAX_EXPONENT_NUMBER then
			error("CodeNum: value exceeds the configured 10^(10^308) range", 3)
		end
		return
	end

	local comparison = compareMagnitude(data :: buffer, length, MAX_EXP_DATA, MAX_EXP_LENGTH)
	if comparison > 0 then
		error("CodeNum: value exceeds the configured 10^(10^308) range", 3)
	end
end

local function exponentToString(
	isBig: number,
	small: number,
	sign: number,
	length: number,
	data: buffer?
): string
	if isBig == 0 then
		return string.format("%.0f", small)
	end
	return bigToString(sign, length, data :: buffer)
end

local function exponentToNumber(
	isBig: number,
	small: number,
	sign: number,
	length: number,
	data: buffer?
): number?
	if isBig == 0 then
		return small
	end
	return tonumber(bigToString(sign, length, data :: buffer))
end

local function shortestNumberString(value: number): string
	for precision = 1, 17 do
		local candidate = string.format("%." .. tostring(precision) .. "g", value)
		if tonumber(candidate) == value then
			return candidate
		end
	end
	return string.format("%.17g", value)
end

local function formatWideMantissa(
	mantissa: number,
	significantDigits: number,
	shortest: boolean
): (string, number)
	if shortest then
		return shortestNumberString(mantissa), 0
	end

	local format = "%." .. tostring(significantDigits) .. "g"
	local formatted = string.format(format, mantissa)
	local rounded = tonumber(formatted) :: number

	if math.abs(rounded) >= 10 then
		return string.format(format, rounded / 10), 1
	end

	return formatted, 0
end

local function makeWide(
	mantissa: number,
	exponentIsBig: number,
	exponentSmall: number,
	exponentSign: number,
	exponentLength: number,
	exponentData: buffer?
): Wide
	local wide: Wide = {
		_codeNum = "wide",
		m = mantissa,
		e = if exponentIsBig == 0 then exponentSmall else 0,
		expSign = exponentSign,
		expLength = exponentLength,
	}

	if exponentIsBig == 1 then
		local copy = newBuffer()
		buffer.copy(copy, 0, exponentData :: buffer, 0, exponentLength * BASE_BYTES)
		WIDE_BUFFERS[wide] = copy
	end

	WIDE_VALUES[wide] = true
	return table.freeze(wide)
end

@native
local function tryNative(mantissa: number, exponent: number): number?
	if exponent >= -308 and exponent <= 308 then
		local result = mantissa * 10 ^ exponent
		if isFinite(result) and result ~= 0 then
			return result
		end
	elseif exponent >= -324 and exponent < -308 then
		local result = mantissa * (10 ^ (exponent + 16)) * 1e-16
		if result ~= 0 then
			return result
		end
	end
	return nil
end

@native
local function normalizeMantissa(mantissa: number): (number, number)
	local shift = 0
	local magnitude = math.abs(mantissa)

	if magnitude == 0 then
		return 0, 0
	end

	if magnitude >= 10 and magnitude < 100 then
		mantissa /= 10
		shift = 1
	elseif magnitude < 1 and magnitude >= 0.1 then
		mantissa *= 10
		shift = -1
	else
		while magnitude >= 10 do
			mantissa /= 10
			magnitude /= 10
			shift += 1
		end

		while magnitude < 1 do
			mantissa *= 10
			magnitude *= 10
			shift -= 1
		end
	end

	return mantissa, shift
end

@native
local function registerScratch(register: Register): buffer
	local data = registerState(register).expData
	if data == nil then
		error("CodeNum: register exponent buffer invariant violated", 3)
	end
	return data :: buffer
end

@native
local function writeRegisterNative(register: Register, value: number)
	local state = registerState(register)
	state.kind = 0
	state.n = value
	state.m = 0
	state.e = 0
	state.expSign = 0
	state.expLength = 0
end

@native
local function writeRegisterWide(
	register: Register,
	mantissa: number,
	exponentSmall: number,
	exponentSign: number,
	exponentLength: number,
	exponentData: buffer?
)
	local state = registerState(register)
	state.kind = 1
	state.n = 0
	state.m = mantissa
	state.e = exponentSmall
	state.expSign = exponentSign
	state.expLength = exponentLength

	if exponentLength > 0 then
		local target = state.expData
		if target == nil then
			error("CodeNum: register exponent buffer invariant violated", 3)
		end
		local destinationBuffer = target :: buffer
		local source = exponentData :: buffer
		if destinationBuffer ~= source then
			buffer.copy(destinationBuffer, 0, source, 0, exponentLength * BASE_BYTES)
		end
	end
end

@native
local function makeValue(
	mantissa: number,
	exponentIsBig: number,
	exponentSmall: number,
	exponentSign: number,
	exponentLength: number,
	exponentData: buffer?,
	destination: Register?
): Value
	if mantissa == 0 then
		local zero = if 1 / mantissa == -math.huge then -0.0 else 0
		if destination ~= nil then
			writeRegisterNative(destination, zero)
		end
		return zero
	end
	if not isFinite(mantissa) then
		error("CodeNum: mantissa must be finite", 3)
	end

	local normalizedMantissa, shift = normalizeMantissa(mantissa)
	local scratch: buffer? = if destination ~= nil then registerScratch(destination) else nil
	local normalizedExponentIsBig, normalizedExponentSmall, normalizedExponentSign, normalizedExponentLength, normalizedExponentData = exponentAddSmall(
		exponentIsBig,
		exponentSmall,
		exponentSign,
		exponentLength,
		exponentData,
		shift,
		scratch
	)

	checkExponent(normalizedExponentIsBig, normalizedExponentSmall, normalizedExponentSign, normalizedExponentLength, normalizedExponentData)

	if math.abs(normalizedMantissa) > 1 then
		local atMaximum = if normalizedExponentIsBig == 0
			then normalizedExponentSmall == MAX_EXPONENT_NUMBER
			else compareMagnitude(normalizedExponentData :: buffer, normalizedExponentLength, MAX_EXP_DATA, MAX_EXP_LENGTH) == 0
				and normalizedExponentSign > 0
		if atMaximum then
			error("CodeNum: value exceeds the configured 10^(10^308) range", 3)
		end
	end

	if normalizedExponentIsBig == 0 then
		local native = tryNative(normalizedMantissa, normalizedExponentSmall)
		if native ~= nil then
			if destination ~= nil then
				writeRegisterNative(destination, native)
			end
			return native
		end
		if destination ~= nil then
			writeRegisterWide(destination, normalizedMantissa, normalizedExponentSmall, 0, 0, nil)
			return 0
		end
		return makeWide(normalizedMantissa, 0, normalizedExponentSmall, 0, 0, nil)
	end

	if destination ~= nil then
		writeRegisterWide(destination, normalizedMantissa, 0, normalizedExponentSign, normalizedExponentLength, normalizedExponentData)
		return 0
	end
	return makeWide(normalizedMantissa, 1, 0, normalizedExponentSign, normalizedExponentLength, normalizedExponentData)
end

@native
local function numberToParts(value: number): (number, number)
	if value == 0 then
		return value, 0
	end

	local magnitude = math.abs(value)
	local exponent = math.floor(math.log10(magnitude))
	local mantissa: number

	if exponent >= -308 then
		mantissa = magnitude / (10 ^ exponent)
	else
		mantissa = (magnitude * 1e308) / (10 ^ (exponent + 308))
	end

	if mantissa >= 10 then
		mantissa /= 10
		exponent += 1
	elseif mantissa < 1 then
		mantissa *= 10
		exponent -= 1
	end

	return if value < 0 then -mantissa else mantissa, exponent
end

@native
local function getWideParts(value: Operand): (number, number, number, number, number, buffer?)
	if isRegister(value) then
		local register = registerState(value :: Register)
		if register.kind == 0 then
			error("CodeNum: expected an extended operand", 3)
		end
		return register.m, if register.expLength == 0 then 0 else 1, register.e, register.expSign, register.expLength, register.expData
	end

	local wide = value :: Wide
	return wide.m, if wide.expLength == 0 then 0 else 1, wide.e, wide.expSign, wide.expLength, WIDE_BUFFERS[wide]
end

@native
local function getParts(value: Operand): (number, number, number, number, number, buffer?)
	if type(value) == "number" then
		local mantissa, exponent = numberToParts(value)
		return mantissa, 0, exponent, 0, 0, nil
	end
	if isRegister(value) and registerState(value :: Register).kind == 0 then
		local mantissa, exponent = numberToParts(registerState(value :: Register).n)
		return mantissa, 0, exponent, 0, 0, nil
	end
	return getWideParts(value)
end

@native
local function negateExponent(isBig: number, small: number, sign: number): (number, number, number)
	if isBig == 1 then
		return 1, 0, -sign
	end
	return 0, -small, 0
end

local function registerValue(register: Register): Value
	local state = registerState(register)
	if state.kind == 0 then
		return state.n
	end
	if state.expLength == 0 then
		return makeWide(state.m, 0, state.e, 0, 0, nil)
	end
	return makeWide(state.m, 1, 0, state.expSign, state.expLength, state.expData)
end

@native
local function getNative(value: Operand): (boolean, number)
	if type(value) == "number" then
		return true, value
	end
	if isRegister(value) then
		local register = registerState(value :: Register)
		if register.kind == 0 then
			return true, register.n
		end
	end
	return false, 0
end

@native
local function operandSign(value: Operand): number
	local native, numberValue = getNative(value)
	if native then
		if numberValue == 0 then
			return if 1 / numberValue == -math.huge then -1 else 1
		end
		return if numberValue < 0 then -1 else 1
	end
	local mantissa = if isRegister(value) then registerState(value :: Register).m else (value :: Wide).m
	return if mantissa < 0 then -1 else 1
end

@native
local function addScientificParts(
	am: number,
	aBig: number,
	ae: number,
	as: number,
	al: number,
	ad: buffer?,
	bm: number,
	bBig: number,
	be: number,
	bs: number,
	bl: number,
	bd: buffer?,
	subtractB: boolean,
	destination: Register?,
	knownExponentOrder: number?,
	knownExponentGap: number?,
	hasKnownAlignment: boolean
): Value
	if subtractB then
		bm = -bm
	end

	if am == 0 then
		if bm == 0 then
			local zero = am + bm
			if destination ~= nil then
				writeRegisterNative(destination, zero)
			end
			return zero
		end
		return makeValue(bm, bBig, be, bs, bl, bd, destination)
	elseif bm == 0 then
		return makeValue(am, aBig, ae, as, al, ad, destination)
	end

	local exponentComparison: number
	local difference: number?
	if hasKnownAlignment then
		exponentComparison = knownExponentOrder :: number
		difference = knownExponentGap
	else
		exponentComparison, difference = exponentAlignment(
			aBig, ae, as, al, ad, bBig, be, bs, bl, bd
		)
	end
	local dominantMantissa = am
	local dominantBig = aBig
	local dominantExponent = ae
	local dominantSign = as
	local dominantLength = al
	local dominantData = ad
	local smallerMantissa = bm
	local smallerBig = bBig
	local smallerExponent = be
	local smallerSign = bs
	local smallerLength = bl
	local smallerData = bd

	if exponentComparison < 0 then
		dominantMantissa, smallerMantissa = smallerMantissa, dominantMantissa
		dominantBig, smallerBig = smallerBig, dominantBig
		dominantExponent, smallerExponent = smallerExponent, dominantExponent
		dominantSign, smallerSign = smallerSign, dominantSign
		dominantLength, smallerLength = smallerLength, dominantLength
		dominantData, smallerData = smallerData, dominantData
	end

	if difference == nil or difference > SMALL_ALIGNMENT_LIMIT then
		return makeValue(dominantMantissa, dominantBig, dominantExponent, dominantSign, dominantLength, dominantData, destination)
	end

	local resultMantissa = dominantMantissa + smallerMantissa * 10 ^ (-difference)
	if resultMantissa == 0 then
		if destination ~= nil then
			writeRegisterNative(destination, 0)
		end
		return 0
	end

	return makeValue(resultMantissa, dominantBig, dominantExponent, dominantSign, dominantLength, dominantData, destination)
end

@native
local function finishWideOperand(
	wideValue: Operand,
	mantissa: number,
	isBig: number,
	small: number,
	sign: number,
	length: number,
	data: buffer?,
	flipSign: boolean,
	destination: Register?
): Value
	if destination == nil and not flipSign and not isRegister(wideValue) then
		return wideValue :: Wide
	end
	return makeValue(if flipSign then -mantissa else mantissa, isBig, small, sign, length, data, destination)
end

@native
local function addNativeWide(
	nativeValue: number,
	wideValue: Operand,
	nativeIsLeft: boolean,
	subtractB: boolean,
	destination: Register?
): Value
	if not isFinite(nativeValue) then
		local special = if nativeValue ~= nativeValue then 0 / 0
			else if nativeIsLeft or not subtractB then nativeValue else -nativeValue
		if destination ~= nil then
			writeRegisterNative(destination, special)
		end
		return special
	end

	local wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData = getWideParts(wideValue)
	if nativeValue == 0 then
		local flipSign = nativeIsLeft and subtractB
		return finishWideOperand(
			wideValue, wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
			flipSign, destination
		)
	end

	local nativeMantissa, nativeExponent = numberToParts(nativeValue)
	local exponentOrder, exponentGap = exponentAlignment(
		0, nativeExponent, 0, 0, nil,
		wideBig, wideExponent, wideSign, wideLength, wideData
	)
	if exponentGap == nil or exponentGap > SMALL_ALIGNMENT_LIMIT then
		if exponentOrder > 0 then
			local result = if nativeIsLeft or not subtractB then nativeValue else -nativeValue
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		return finishWideOperand(
			wideValue, wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
			(nativeIsLeft and subtractB), destination
		)
	end

	if nativeIsLeft then
		return addScientificParts(
			nativeMantissa, 0, nativeExponent, 0, 0, nil,
			wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
			subtractB, destination, exponentOrder, exponentGap, true
		)
	end

	return addScientificParts(
		wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
		nativeMantissa, 0, nativeExponent, 0, 0, nil,
		subtractB, destination, -exponentOrder, exponentGap, true
	)
end

@native
local function addInternal(a: Operand, b: Operand, subtractB: boolean, destination: Register?): Value
	if type(a) == "number" and type(b) == "number" then
		local result = if subtractB then a - b else a + b
		if not isFinite(a) or not isFinite(b) or isFinite(result) then
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		local am, ae = numberToParts(a)
		local bm, be = numberToParts(b)
		return addScientificParts(am, 0, ae, 0, 0, nil, bm, 0, be, 0, 0, nil, subtractB, destination, nil, nil, false)
	end

	local nativeA, valueA = getNative(a)
	local nativeB, valueB = getNative(b)
	local specialA = nativeA and not isFinite(valueA)
	local specialB = nativeB and not isFinite(valueB)
	if specialA or specialB then
		local specialResult: number
		if (specialA and valueA ~= valueA) or (specialB and valueB ~= valueB) then
			specialResult = 0 / 0
		elseif specialA and specialB then
			specialResult = if subtractB then valueA - valueB else valueA + valueB
		elseif specialA then
			specialResult = valueA
		else
			specialResult = if subtractB then -valueB else valueB
		end
		if destination ~= nil then
			writeRegisterNative(destination, specialResult)
		end
		return specialResult
	end

	if nativeA and nativeB then
		local result = if subtractB then valueA - valueB else valueA + valueB
		if isFinite(result) then
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		local am, ae = numberToParts(valueA)
		local bm, be = numberToParts(valueB)
		return addScientificParts(
			am, 0, ae, 0, 0, nil,
			bm, 0, be, 0, 0, nil,
			subtractB, destination, nil, nil, false
		)
	elseif nativeA then
		return addNativeWide(valueA, b, true, subtractB, destination)
	elseif nativeB then
		return addNativeWide(valueB, a, false, subtractB, destination)
	end

	local am, aBig, ae, as, al, ad = getWideParts(a)
	local bm, bBig, be, bs, bl, bd = getWideParts(b)
	return addScientificParts(am, aBig, ae, as, al, ad, bm, bBig, be, bs, bl, bd, subtractB, destination, nil, nil, false)
end

@native
local function multiplyExponentByInteger(
	isBig: number,
	small: number,
	sign: number,
	length: number,
	data: buffer?,
	factor: number
): (number, number, number, number, buffer?)
	if isBig == 0 and math.abs(small) <= math.floor(MAX_SAFE_INTEGER / math.max(1, math.abs(factor))) then
		return 0, small * factor, 0, 0, nil
	end

	local resultSign: number
	local sourceLength: number

	local out = newBuffer()
	if isBig == 1 then
		resultSign = sign
		sourceLength = length
		buffer.copy(out, 0, data :: buffer, 0, length * BASE_BYTES)
	else
		resultSign, sourceLength = writeSmallMagnitude(out, small)
	end

	local absoluteFactor = math.abs(factor)
	local resultLength = multiplyMagnitudeSmall(out, sourceLength, absoluteFactor)
	resultSign *= if factor < 0 then -1 else 1

	if resultLength <= 3 then
		local smallResult = bigToSmall(resultSign, resultLength, out)
		if smallResult ~= nil then
			return 0, smallResult, 0, 0, nil
		end
	end

	return 1, 0, resultSign, resultLength, out
end

@native
local function multiplyScientificParts(
	am: number,
	aBig: number,
	ae: number,
	as: number,
	al: number,
	ad: buffer?,
	bm: number,
	bBig: number,
	be: number,
	bs: number,
	bl: number,
	bd: buffer?,
	divide: boolean,
	destination: Register?
): Value
	if divide then
		if bm == 0 then
			local result = am / bm
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		if am == 0 then
			local negativeZero = ((1 / am) == -math.huge) ~= (bm < 0)
			local zero = if negativeZero then -0.0 else 0
			if destination ~= nil then
				writeRegisterNative(destination, zero)
			end
			return zero
		end
		local bIsBig, bSmall, bSign = negateExponent(bBig, be, bs)
		local scratch: buffer? = if destination ~= nil then registerScratch(destination) else nil
		local exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData = exponentAdd(
			aBig, ae, as, al, ad, bIsBig, bSmall, bSign, bl, bd, scratch
		)
		return makeValue(am / bm, exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData, destination)
	end

	local scratch: buffer? = if destination ~= nil then registerScratch(destination) else nil
	local exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData = exponentAdd(
		aBig, ae, as, al, ad, bBig, be, bs, bl, bd, scratch
	)
	return makeValue(am * bm, exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData, destination)
end

@native
local function multiplyNativeWide(
	nativeValue: number,
	wideValue: Operand,
	nativeIsLeft: boolean,
	divide: boolean,
	destination: Register?
): Value
	local wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData = getWideParts(wideValue)
	if isFinite(nativeValue) then
		local wideNegative = wideMantissa < 0
		local nativeNegative = nativeValue < 0 or (nativeValue == 0 and 1 / nativeValue == -math.huge)
		local flipSign = nativeNegative
		if nativeValue == 0 then
			local negative = nativeNegative ~= wideNegative
			local result: number
			if divide and not nativeIsLeft then
				result = if negative then -math.huge else math.huge
			else
				result = if negative then -0.0 else 0
			end
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		if nativeValue == 1 or nativeValue == -1 then
			if not divide or not nativeIsLeft then
				return finishWideOperand(
					wideValue, wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
					flipSign, destination
				)
			end
		end
	end
	if not isFinite(nativeValue) then
		local sign = (if nativeValue < 0 then -1 else 1) * (if wideMantissa < 0 then -1 else 1)
		local special: number
		if nativeValue ~= nativeValue then
			special = 0 / 0
		elseif divide and not nativeIsLeft then
			special = if sign < 0 then -0.0 else 0
		elseif divide then
			special = if sign < 0 then -math.huge else math.huge
		else
			special = if sign < 0 then -math.huge else math.huge
		end
		if destination ~= nil then
			writeRegisterNative(destination, special)
		end
		return special
	end

	local nativeMantissa, nativeExponent = numberToParts(nativeValue)
	if nativeIsLeft then
		return multiplyScientificParts(
			nativeMantissa, 0, nativeExponent, 0, 0, nil,
			wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
			divide, destination
		)
	end

	return multiplyScientificParts(
		wideMantissa, wideBig, wideExponent, wideSign, wideLength, wideData,
		nativeMantissa, 0, nativeExponent, 0, 0, nil,
		divide, destination
	)
end

@native
local function multiplyInternal(a: Operand, b: Operand, divide: boolean, destination: Register?): Value
	if type(a) == "number" and type(b) == "number" then
		local result = if divide then a / b else a * b
		if not isFinite(a) or not isFinite(b) or (isFinite(result) and (result ~= 0 or a == 0 or b == 0)) then
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		local am, ae = numberToParts(a)
		local bm, be = numberToParts(b)
		return multiplyScientificParts(am, 0, ae, 0, 0, nil, bm, 0, be, 0, 0, nil, divide, destination)
	end

	local nativeA, valueA = getNative(a)
	local nativeB, valueB = getNative(b)
	local specialA = nativeA and not isFinite(valueA)
	local specialB = nativeB and not isFinite(valueB)
	if specialA or specialB then
		local specialResult: number
		local sign = operandSign(a) * operandSign(b)
		if (specialA and valueA ~= valueA) or (specialB and valueB ~= valueB) then
			specialResult = 0 / 0
		elseif divide and specialA and specialB then
			specialResult = 0 / 0
		elseif divide and specialB then
			specialResult = if sign < 0 then -0.0 else 0
		elseif divide then
			specialResult = if sign < 0 then -math.huge else math.huge
		elseif (nativeA and valueA == 0) or (nativeB and valueB == 0) then
			specialResult = 0 / 0
		else
			specialResult = if sign < 0 then -math.huge else math.huge
		end
		if destination ~= nil then
			writeRegisterNative(destination, specialResult)
		end
		return specialResult
	end

	if nativeA and nativeB then
		local result = if divide then valueA / valueB else valueA * valueB
		local directResult = if divide
			then valueB == 0 or (isFinite(result) and (result ~= 0 or valueA == 0))
			else isFinite(result) and (result ~= 0 or valueA == 0 or valueB == 0)
		if directResult then
			if destination ~= nil then
				writeRegisterNative(destination, result)
			end
			return result
		end
		local am, ae = numberToParts(valueA)
		local bm, be = numberToParts(valueB)
		return multiplyScientificParts(
			am, 0, ae, 0, 0, nil,
			bm, 0, be, 0, 0, nil,
			divide, destination
		)
	elseif nativeA then
		return multiplyNativeWide(valueA, b, true, divide, destination)
	elseif nativeB then
		return multiplyNativeWide(valueB, a, false, divide, destination)
	end

	local am, aBig, ae, as, al, ad = getWideParts(a)
	local bm, bBig, be, bs, bl, bd = getWideParts(b)
	return multiplyScientificParts(am, aBig, ae, as, al, ad, bm, bBig, be, bs, bl, bd, divide, destination)
end

@native
local function compareInternal(a: Operand, b: Operand): number?
	local nativeA, valueA = getNative(a)
	local nativeB, valueB = getNative(b)

	if nativeA and nativeB then
		if valueA ~= valueA or valueB ~= valueB then
			return nil
		end
		return if valueA < valueB then -1 else if valueA > valueB then 1 else 0
	end

	if nativeA and not isFinite(valueA) then
		if valueA ~= valueA then
			return nil
		end
		return if valueA < 0 then -1 else 1
	end
	if nativeB and not isFinite(valueB) then
		if valueB ~= valueB then
			return nil
		end
		return if valueB < 0 then 1 else -1
	end

	local am, aBig, ae, as, al, ad = getParts(a)
	local bm, bBig, be, bs, bl, bd = getParts(b)
	if am == 0 then
		return if bm < 0 then 1 else if bm > 0 then -1 else 0
	elseif bm == 0 then
		return if am < 0 then -1 else 1
	end
	if am < 0 and bm >= 0 then
		return -1
	elseif am >= 0 and bm < 0 then
		return 1
	end

	local exponentComparison = exponentCompare(aBig, ae, as, al, ad, bBig, be, bs, bl, bd)
	local magnitudeComparison: number
	if exponentComparison == 0 then
		local aa = math.abs(am)
		local bb = math.abs(bm)
		magnitudeComparison = if aa < bb then -1 else if aa > bb then 1 else 0
	else
		magnitudeComparison = exponentComparison
	end

	return if am < 0 then -magnitudeComparison else magnitudeComparison
end

local function parseDecimal(text: string): (number, number, string)
	local signText, integerPart, fractionalPart, exponentText = string.match(
		text,
		"^([%+%-]?)(%d*)%.?(%d*)[eE]([%+%-]?%d+)$"
	)

	if integerPart == nil then
		signText, integerPart, fractionalPart = string.match(text, "^([%+%-]?)(%d*)%.?(%d*)$")
		exponentText = "0"
	end

	if integerPart == nil or fractionalPart == nil or (integerPart == "" and fractionalPart == "") or exponentText == nil then
		error("CodeNum: invalid numeric string", 3)
	end

	local digits = integerPart .. fractionalPart
	if #digits > MAX_PARSE_DIGITS then
		error("CodeNum: numeric strings are limited to 4096 mantissa digits", 3)
	end

	local firstNonZero = string.find(digits, "[^0]")
	if firstNonZero == nil then
		return 0, 0, "0"
	end

	local significant = string.sub(digits, firstNonZero)
	local baseExponent = #integerPart - firstNonZero
	local mantissa = tonumber(significant .. "e-" .. tostring(#significant - 1))
	if mantissa == nil or not isFinite(mantissa) or mantissa == 0 then
		error("CodeNum: could not parse numeric mantissa", 3)
	end
	if signText == "-" then
		mantissa = -mantissa
	end

	return mantissa, baseExponent, exponentText
end

local function parseExponent(text: string): (number, number, number, number, buffer?)
	local sign, length, data = bigFromDecimal(text)
	local small = bigToSmall(sign, length, data)
	if small ~= nil then
		return 0, small, 0, 0, nil
	end
	return 1, 0, sign, length, data
end

@native
local function assertValidValue(value: Operand)
	if type(value) == "number" then
		return
	end

	if isWide(value) or isRegister(value) then
		return
	end

	error("CodeNum: expected a native number, Wide value, or CodeNum register", 3)
end

function CodeNum.new(value: number): Value
	if type(value) ~= "number" then
		error("CodeNum.new expects a Luau number", 2)
	end
	return value
end

function CodeNum.fromScientific(mantissa: number, exponent: number | string): Value
	if not isFinite(mantissa) then
		error("CodeNum.fromScientific expects a finite mantissa", 2)
	end
	if type(exponent) ~= "number" and type(exponent) ~= "string" then
		error("CodeNum.fromScientific exponent must be a number or decimal integer string", 2)
	end

	local isBig: number
	local small: number
	local sign: number
	local length: number
	local data: buffer?

	if type(exponent) == "number" then
		if not isInteger(exponent) or math.abs(exponent) > MAX_SAFE_INTEGER then
			error("CodeNum: numeric exponents must be exact safe integers; use a decimal string for larger exponents", 2)
		end
		isBig, small, sign, length, data = 0, exponent, 0, 0, nil
	else
		isBig, small, sign, length, data = parseExponent(exponent)
	end

	if mantissa == 0 then
		return 0
	end

	return makeValue(mantissa, isBig, small, sign, length, data, nil)
end

function CodeNum.parse(text: string): Value
	if type(text) ~= "string" then
		error("CodeNum.parse expects a string", 2)
	end

	local normalized = string.match(text, "^%s*(.-)%s*$") or text
	if normalized == "nan" or normalized == "NaN" then
		return 0 / 0
	elseif normalized == "inf" or normalized == "+inf" or normalized == "infinity" or normalized == "+infinity" or normalized == "Infinity" then
		return math.huge
	elseif normalized == "-inf" or normalized == "-infinity" or normalized == "-Infinity" then
		return -math.huge
	end

	local mantissa, baseExponent, explicitExponent = parseDecimal(normalized)
	if mantissa == 0 then
		return 0
	end

	local isBig, small, sign, length, data = parseExponent(explicitExponent)
	local exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData = exponentAddSmall(isBig, small, sign, length, data, baseExponent)
	return makeValue(mantissa, exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData, nil)
end

@native
function CodeNum.add(a: Operand, b: Operand): Value
	if type(a) == "number" and type(b) == "number" then
		local result = a + b
		if not isFinite(a) or not isFinite(b) or isFinite(result) then
			return result
		end
	else
		assertValidValue(a)
		assertValidValue(b)
	end
	return addInternal(a, b, false, nil)
end

@native
function CodeNum.sub(a: Operand, b: Operand): Value
	if type(a) == "number" and type(b) == "number" then
		local result = a - b
		if not isFinite(a) or not isFinite(b) or isFinite(result) then
			return result
		end
	else
		assertValidValue(a)
		assertValidValue(b)
	end
	return addInternal(a, b, true, nil)
end

@native
function CodeNum.mul(a: Operand, b: Operand): Value
	if type(a) == "number" and type(b) == "number" then
		local result = a * b
		if not isFinite(a) or not isFinite(b)
			or (isFinite(result) and (result ~= 0 or a == 0 or b == 0))
		then
			return result
		end
	else
		assertValidValue(a)
		assertValidValue(b)
	end
	return multiplyInternal(a, b, false, nil)
end

@native
function CodeNum.div(a: Operand, b: Operand): Value
	if type(a) == "number" and type(b) == "number" then
		local result = a / b
		if not isFinite(a) or not isFinite(b) or b == 0
			or (isFinite(result) and (result ~= 0 or a == 0))
		then
			return result
		end
	else
		assertValidValue(a)
		assertValidValue(b)
	end
	return multiplyInternal(a, b, true, nil)
end

@native
function CodeNum.pow(value: Operand, power: number): Value
	assertValidValue(value)
	if not isFinite(power) then
		error("CodeNum.pow expects a finite exponent", 2)
	end
	local native, nativeValue = getNative(value)
	if native then
		local result = nativeValue ^ power
		if not isFinite(nativeValue) or (isFinite(result) and (result ~= 0 or nativeValue == 0)) then
			return result
		end
	end

	local mantissa, isBig, small, sign, length, data = getParts(value)
	if mantissa == 0 then
		return 0 ^ power
	end
	if mantissa < 0 and not isInteger(power) then
		return 0 / 0
	end
	if mantissa < 0 and math.abs(power) > 1000000 then
		error("CodeNum.pow integer exponent is limited to 1,000,000", 2)
	end
	if power == 0 then
		return 1
	end

	if isInteger(power) then
		if math.abs(power) > 1000000 then
			error("CodeNum.pow integer exponent is limited to 1,000,000", 2)
		end
		local exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData = multiplyExponentByInteger(isBig, small, sign, length, data, power)
		local negativeResult = mantissa < 0 and math.abs(power) % 2 == 1
		local directMantissa = math.abs(mantissa) ^ power
		if isFinite(directMantissa) and directMantissa > 0 then
			return makeValue(
				if negativeResult then -directMantissa else directMantissa,
				exponentIsBig,
				exponentSmall,
				exponentSign,
				exponentLength,
				exponentData,
				nil
			)
		end

		local logarithm = math.log10(math.abs(mantissa)) * power
		local adjustment = math.floor(logarithm)
		local normalizedMantissa = 10 ^ (logarithm - adjustment)
		if negativeResult then
			normalizedMantissa = -normalizedMantissa
		end
		local combinedIsBig, combinedSmall, combinedSign, combinedLength, combinedData = exponentAddSmall(
			exponentIsBig,
			exponentSmall,
			exponentSign,
			exponentLength,
			exponentData,
			adjustment
		)
		return makeValue(normalizedMantissa, combinedIsBig, combinedSmall, combinedSign, combinedLength, combinedData, nil)
	end

	if isBig == 1 then
		error("CodeNum.pow with a fractional exponent is unsupported for huge exact exponents", 2)
	end

	local logarithm = (small + math.log10(math.abs(mantissa))) * power
	if not isFinite(logarithm) or math.abs(logarithm) > MAX_SAFE_INTEGER then
		error("CodeNum.pow result requires an exact huge exponent; use an integer power", 2)
	end
	local resultExponent = math.floor(logarithm)
	local resultMantissa = 10 ^ (logarithm - resultExponent)
	if mantissa < 0 then
		resultMantissa = -resultMantissa
	end
	return makeValue(resultMantissa, 0, resultExponent, 0, 0, nil, nil)
end

@native
function CodeNum.compare(a: Operand, b: Operand): number?
	assertValidValue(a)
	assertValidValue(b)
	return compareInternal(a, b)
end

@native
function CodeNum.abs(value: Operand): Value
	assertValidValue(value)
	if type(value) == "number" then
		return math.abs(value)
	end
	if isRegister(value) then
		local register = registerState(value :: Register)
		if register.kind == 0 then
			return math.abs(register.n)
		end
	end
	local mantissa, isBig, small, sign, length, data = getParts(value)
	return makeValue(math.abs(mantissa), isBig, small, sign, length, data, nil)
end

@native
function CodeNum.log10(value: Operand): number
	assertValidValue(value)
	local native, nativeValue = getNative(value)
	if native then
		return math.log10(nativeValue)
	end
	local comparison = compareInternal(value, 0)
	if comparison == nil or comparison < 0 then
		return 0 / 0
	elseif comparison == 0 then
		return -math.huge
	end

	local mantissa, isBig, small, sign, length, data = getParts(value)
	local exponent = exponentToNumber(isBig, small, sign, length, data)
	return (exponent :: number) + math.log10(mantissa)
end

function CodeNum.toNumber(value: Operand): number
	assertValidValue(value)
	if type(value) == "number" then
		return value
	end
	if isRegister(value) then
		local register = registerState(value :: Register)
		if register.kind == 0 then
			return register.n
		end
	end
	local mantissa, isBig, small, sign, length, data = getParts(value)
	local exponent = exponentToNumber(isBig, small, sign, length, data)
	if exponent == nil then
		return if sign < 0 then 0 else math.huge
	end
	if exponent > 308 then
		return if mantissa < 0 then -math.huge else math.huge
	elseif exponent < -324 then
		return if mantissa < 0 then -0.0 else 0
	end
	local native = tryNative(mantissa, exponent)
	if native ~= nil then
		return native
	end
	return if exponent >= 0 then (if mantissa < 0 then -math.huge else math.huge)
		else (if mantissa < 0 then -0.0 else 0)
end

function CodeNum.toString(value: Operand, significantDigits: number?): string
	assertValidValue(value)
	if isRegister(value) then
		local register = registerState(value :: Register)
		if register.kind == 0 then
			return CodeNum.toString(register.n, significantDigits)
		end
	end
	local shortest = significantDigits == nil
	local digits = significantDigits or 17
	if not isInteger(digits) or digits < 1 or digits > 17 then
		error("CodeNum.toString significantDigits must be an integer from 1 to 17", 2)
	end

	if type(value) == "number" then
		if value ~= value then
			return "NaN"
		elseif value == math.huge then
			return "Infinity"
		elseif value == -math.huge then
			return "-Infinity"
		end
		return if shortest then shortestNumberString(value)
			else string.format("%." .. tostring(digits) .. "g", value)
	end

	local mantissa, isBig, small, sign, length, data = getParts(value)
	local mantissaText, exponentShift = formatWideMantissa(mantissa, digits, shortest)
	local exponentIsBig, exponentSmall, exponentSign, exponentLength, exponentData = exponentAddSmall(
		isBig,
		small,
		sign,
		length,
		data,
		exponentShift
	)
	local exponentText = exponentToString(
		exponentIsBig,
		exponentSmall,
		exponentSign,
		exponentLength,
		exponentData
	)
	return mantissaText .. "e" .. exponentText
end

function CodeNum.encode(value: Operand): string
	assertValidValue(value)
	if isRegister(value) then
		return CodeNum.encode(registerValue(value :: Register))
	end
	if type(value) == "number" then
		if value ~= value then
			return "CN1|N|nan"
		elseif value == math.huge then
			return "CN1|N|inf"
		elseif value == -math.huge then
			return "CN1|N|-inf"
		end
		return "CN1|N|" .. string.format("%.17g", value)
	end

	local mantissa, isBig, small, sign, length, data = getParts(value)
	local exponentText = exponentToString(isBig, small, sign, length, data)
	return "CN1|W|" .. string.format("%.17g", mantissa) .. "|" .. exponentText
end

function CodeNum.decode(text: string): Value
	if type(text) ~= "string" then
		error("CodeNum.decode expects a string", 2)
	end

	local nativePayload = string.match(text, "^CN1|N|([^|]+)$")
	if nativePayload ~= nil then
		if nativePayload == "nan" then
			return 0 / 0
		elseif nativePayload == "inf" then
			return math.huge
		elseif nativePayload == "-inf" then
			return -math.huge
		end
		local native = tonumber(nativePayload)
		if native == nil or not isFinite(native) then
			error("CodeNum.decode received an invalid native number", 2)
		end
		return native
	end

	local mantissaText, exponentText = string.match(text, "^CN1|W|([^|]+)|([^|]+)$")
	if mantissaText == nil or exponentText == nil then
		error("CodeNum.decode received an invalid payload", 2)
	end

	local mantissa = tonumber(mantissaText)
	if mantissa == nil then
		error("CodeNum.decode received an invalid wide mantissa", 2)
	end
	return CodeNum.fromScientific(mantissa, exponentText)
end

function CodeNum.createRegister(): Register
	local register: Register = table.freeze({ _codeNum = "register" })
	REGISTER_STATES[register] = {
		kind = 0,
		n = 0,
		m = 0,
		e = 0,
		expSign = 0,
		expLength = 0,
		expData = newBuffer(),
	}
	return register
end

function CodeNum.readRegister(register: Register): Value
	if not isRegister(register) then
		error("CodeNum.readRegister expects a CodeNum register", 2)
	end
	return registerValue(register)
end

@native
function CodeNum.addInto(register: Register, a: Operand, b: Operand): Register
	if not isRegister(register) then
		error("CodeNum.addInto expects a CodeNum register", 2)
	end
	assertValidValue(a)
	assertValidValue(b)
	addInternal(a, b, false, register)
	return register
end

@native
function CodeNum.subInto(register: Register, a: Operand, b: Operand): Register
	if not isRegister(register) then
		error("CodeNum.subInto expects a CodeNum register", 2)
	end
	assertValidValue(a)
	assertValidValue(b)
	addInternal(a, b, true, register)
	return register
end

@native
function CodeNum.mulInto(register: Register, a: Operand, b: Operand): Register
	if not isRegister(register) then
		error("CodeNum.mulInto expects a CodeNum register", 2)
	end
	assertValidValue(a)
	assertValidValue(b)
	multiplyInternal(a, b, false, register)
	return register
end

@native
function CodeNum.divInto(register: Register, a: Operand, b: Operand): Register
	if not isRegister(register) then
		error("CodeNum.divInto expects a CodeNum register", 2)
	end
	assertValidValue(a)
	assertValidValue(b)
	multiplyInternal(a, b, true, register)
	return register
end

@native
function CodeNum.isWide(value: Operand): boolean
	if isRegister(value) then
		return registerState(value :: Register).kind == 1
	end
	return isWide(value)
end

@native
function CodeNum.isFinite(value: Operand): boolean
	if type(value) == "number" then
		return isFinite(value)
	end
	assertValidValue(value)
	if isRegister(value) then
		local register = registerState(value :: Register)
		return if register.kind == 0 then isFinite(register.n) else true
	end
	return true
end

@native
function CodeNum.sign(value: Operand): number?
	assertValidValue(value)
	if type(value) == "number" then
		if value ~= value then
			return nil
		end
		return if value < 0 then -1 else if value > 0 then 1 else 0
	end
	if isRegister(value) then
		local register = registerState(value :: Register)
		if register.kind == 0 then
			local native = register.n
			if native ~= native then
				return nil
			end
			return if native < 0 then -1 else if native > 0 then 1 else 0
		end
	end
	local mantissa = if isRegister(value) then registerState(value :: Register).m else (value :: Wide).m
	return if mantissa < 0 then -1 else 1
end

CodeNum.MAX_EXPONENT = MAX_EXPONENT_TEXT
CodeNum.MAX_EXPONENT_LIMBS = MAX_LIMBS
CodeNum.VERSION = "0.5.0"

return CodeNum
