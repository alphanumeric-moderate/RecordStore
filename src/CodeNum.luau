--!nonstrict
-- CodeNum 0.2.0-preview.1
-- Standalone high-range numeric representation for Roblox Luau.
--
-- finite     native binary64 values; NaN and infinities use special nodes
-- integer    exact signed decimal integer outside the safe native range
-- scientific approximate binary64 significand + exact decimal exponent
-- hyper      Knuth up-arrow expression, kept symbolic when too large
-- expression unevaluated binary operation
-- call       unevaluated unary function

local HttpService = game:GetService("HttpService")

local CodeNum = {
    VERSION = "0.2.0-preview.1",
    FORMAT_VERSION = 2,
}

local MT = { __index = CodeNum }
local KIND_FINITE = "finite"
local KIND_INTEGER = "integer"
local KIND_SCIENTIFIC = "scientific"
local KIND_SPECIAL = "special"
local KIND_HYPER = "hyper"
local KIND_EXPRESSION = "expression"
local KIND_CALL = "call"

local MAX_SAFE_INTEGER = 9007199254740991
local MAX_CODEC_DEPTH = 128
local MAX_CODEC_NODES = 8192
local MAX_DISPLAY_DEPTH = 48
local MAX_DISPLAY_NODES = 2048
local LIMB_BASE = 10000000
local LIMB_WIDTH = 7
-- Bound quadratic limb multiplication; larger products stay symbolic.
local MAX_EXACT_MULTIPLICATION_DIGITS = 4096
local LOG10_MAX_DOUBLE = 308.25471555991675

local ZERO
local ONE
local TWO
local TEN

local PRIMITIVE_KIND = {
    [KIND_FINITE] = true,
    [KIND_INTEGER] = true,
    [KIND_SCIENTIFIC] = true,
}

local EXPRESSION_OP = {
    add = true,
    sub = true,
    mul = true,
    div = true,
    pow = true,
}

local DISPLAY_SYMBOL = {
    add = "+",
    sub = "−",
    mul = "×",
    div = "÷",
    pow = "^",
}

local function isFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function make(node)
    return table.freeze(setmetatable(node, MT))
end

local function specialNode(name)
    return make({ kind = KIND_SPECIAL, name = name })
end

local function finiteNode(value)
    if value ~= value then
        return specialNode("nan")
    elseif value == math.huge then
        return specialNode("+infinity")
    elseif value == -math.huge then
        return specialNode("-infinity")
    end
    if value == 0 then value = 0 end
    return make({ kind = KIND_FINITE, value = value })
end

local function normalizeUnsignedDigits(digits)
    if type(digits) ~= "string" or not string.match(digits, "^%d+$") then
        error("integer digits must contain decimal digits only", 3)
    end
    digits = string.gsub(digits, "^0+", "")
    return digits == "" and "0" or digits
end

local function normalizeSignedInteger(value)
    if type(value) == "number" then
        if not isFiniteNumber(value)
            or value % 1 ~= 0
            or math.abs(value) > MAX_SAFE_INTEGER
        then
            error("numeric integer input must be a safe integer; use a decimal string for larger integers", 3)
        end
        value = string.format("%.0f", value)
    end
    if type(value) ~= "string" or not string.match(value, "^[+-]?%d+$") then
        error("integer input must be a signed decimal integer string", 3)
    end

    local sign = 1
    local first = string.sub(value, 1, 1)
    if first == "-" then
        sign = -1
        value = string.sub(value, 2)
    elseif first == "+" then
        value = string.sub(value, 2)
    end

    local digits = normalizeUnsignedDigits(value)
    if digits == "0" then return 0, "0" end
    return sign, digits
end

local function compareUnsigned(left, right)
    if #left ~= #right then return #left > #right and 1 or -1 end
    if left == right then return 0 end
    return left > right and 1 or -1
end

local function compareSignedText(left, right)
    local leftSign, leftDigits = normalizeSignedInteger(left)
    local rightSign, rightDigits = normalizeSignedInteger(right)
    if leftSign ~= rightSign then return leftSign > rightSign and 1 or -1 end
    if leftSign == 0 then return 0 end
    local result = compareUnsigned(leftDigits, rightDigits)
    return leftSign < 0 and -result or result
end

-- Decimal text is converted into base-10^7 limbs for exact integer work.
-- Intermediate products remain below binary64's exact-integer limit.
local function digitsToLimbs(digits)
    local limbs = {}
    local finish = #digits
    while finish > 0 do
        local start = math.max(1, finish - LIMB_WIDTH + 1)
        limbs[#limbs + 1] = tonumber(string.sub(digits, start, finish))
        finish = start - 1
    end
    return limbs
end

local function limbsToDigits(limbs)
    local count = #limbs
    while count > 1 and limbs[count] == 0 do count -= 1 end
    local out = { tostring(limbs[count]) }
    for i = count - 1, 1, -1 do
        out[#out + 1] = string.format("%0" .. LIMB_WIDTH .. "d", limbs[i])
    end
    return table.concat(out)
end

local function addUnsigned(left, right)
    local a, b = digitsToLimbs(left), digitsToLimbs(right)
    local count = math.max(#a, #b)
    local out = table.create(count + 1, 0)
    local carry = 0
    for i = 1, count do
        local sum = (a[i] or 0) + (b[i] or 0) + carry
        if sum >= LIMB_BASE then
            sum -= LIMB_BASE
            carry = 1
        else
            carry = 0
        end
        out[i] = sum
    end
    if carry > 0 then out[count + 1] = carry end
    return limbsToDigits(out)
end

-- Requires left >= right.
local function subtractUnsigned(left, right)
    local a, b = digitsToLimbs(left), digitsToLimbs(right)
    local out = table.create(#a, 0)
    local borrow = 0
    for i = 1, #a do
        local value = a[i] - (b[i] or 0) - borrow
        if value < 0 then
            value += LIMB_BASE
            borrow = 1
        else
            borrow = 0
        end
        out[i] = value
    end
    return normalizeUnsignedDigits(limbsToDigits(out))
end

local function multiplyUnsigned(left, right)
    if left == "0" or right == "0" then return "0" end
    local a, b = digitsToLimbs(left), digitsToLimbs(right)
    local out = table.create(#a + #b, 0)

    for i = 1, #a do
        local carry = 0
        for j = 1, #b do
            local index = i + j - 1
            local current = out[index] + a[i] * b[j] + carry
            out[index] = current % LIMB_BASE
            carry = math.floor(current / LIMB_BASE)
        end
        local index = i + #b
        while carry > 0 do
            local current = (out[index] or 0) + carry
            out[index] = current % LIMB_BASE
            carry = math.floor(current / LIMB_BASE)
            index += 1
        end
    end
    return limbsToDigits(out)
end

local function addSignedIntegerStrings(left, right)
    local leftSign, leftDigits = normalizeSignedInteger(left)
    local rightSign, rightDigits = normalizeSignedInteger(right)
    if leftSign == 0 then
        return rightSign == 0 and "0" or (rightSign < 0 and "-" or "") .. rightDigits
    elseif rightSign == 0 then
        return (leftSign < 0 and "-" or "") .. leftDigits
    elseif leftSign == rightSign then
        return (leftSign < 0 and "-" or "") .. addUnsigned(leftDigits, rightDigits)
    end
    local comparison = compareUnsigned(leftDigits, rightDigits)
    if comparison == 0 then return "0" end
    if comparison > 0 then
        return (leftSign < 0 and "-" or "") .. subtractUnsigned(leftDigits, rightDigits)
    end
    return (rightSign < 0 and "-" or "") .. subtractUnsigned(rightDigits, leftDigits)
end

local function negateIntegerString(value)
    local sign, digits = normalizeSignedInteger(value)
    if sign == 0 then return "0" end
    return (sign > 0 and "-" or "") .. digits
end

local function integerNodeNormalized(sign, digits)
    if digits == "0" or sign == 0 then return finiteNode(0) end
    local normalizedSign = sign < 0 and -1 or 1
    if #digits <= 16 then
        local native = tonumber((normalizedSign < 0 and "-" or "") .. digits)
        if native and math.abs(native) <= MAX_SAFE_INTEGER then return finiteNode(native) end
    end
    return make({ kind = KIND_INTEGER, sign = normalizedSign, digits = digits })
end

local function integerNode(sign, digits)
    return integerNodeNormalized(sign, normalizeUnsignedDigits(digits))
end

local function sciNode(sign, mantissa, exponent)
    if not isFiniteNumber(mantissa) or mantissa <= 0 then
        error("scientific mantissa must be finite and positive", 3)
    end
    local exponentSign, exponentDigits = normalizeSignedInteger(exponent)
    local exponentText = (exponentSign < 0 and "-" or "") .. exponentDigits
    local mantissaText, shiftText = string.match(
        string.format("%.17e", mantissa),
        "^([%d%.]+)e([+-]?%d+)$"
    )
    mantissa = tonumber(mantissaText)
    exponentText = addSignedIntegerStrings(exponentText, shiftText)

    if compareSignedText(exponentText, "-308") >= 0
        and compareSignedText(exponentText, "308") <= 0
    then
        local numericExponent = tonumber(exponentText)
        local value = mantissa * math.pow(10, numericExponent)
        if isFiniteNumber(value) and value ~= 0 then
            return finiteNode((sign < 0 and -1 or 1) * value)
        end
    end
    return make({
        kind = KIND_SCIENTIFIC,
        sign = sign < 0 and -1 or 1,
        mantissa = mantissa,
        exponent = exponentText,
    })
end

local function isCodeNum(value)
    return type(value) == "table" and getmetatable(value) == MT
end

local function numberNode(value)
    if isCodeNum(value) then
        return value
    elseif type(value) == "number" then
        return finiteNode(value)
    elseif type(value) == "string" then
        return CodeNum.fromString(value)
    end
    error("CodeNum.new expects a number, numeric string, or CodeNum value", 3)
end

local function sameTree(left, right, depth)
    if left == right then return true end
    if depth > MAX_CODEC_DEPTH or left.kind ~= right.kind then return false end
    if left.kind == KIND_FINITE then
        return left.value == right.value
    elseif left.kind == KIND_INTEGER then
        return left.sign == right.sign and left.digits == right.digits
    elseif left.kind == KIND_SCIENTIFIC then
        return left.sign == right.sign and left.mantissa == right.mantissa and left.exponent == right.exponent
    elseif left.kind == KIND_SPECIAL then
        return left.name == right.name
    elseif left.kind == KIND_HYPER then
        return sameTree(left.base, right.base, depth + 1)
            and sameTree(left.arrows, right.arrows, depth + 1)
            and sameTree(left.height, right.height, depth + 1)
    elseif left.kind == KIND_EXPRESSION then
        return left.op == right.op
            and sameTree(left.left, right.left, depth + 1)
            and sameTree(left.right, right.right, depth + 1)
    elseif left.kind == KIND_CALL then
        return left.op == right.op and sameTree(left.value, right.value, depth + 1)
    end
    return false
end

local function nativeInteger(value)
    if value.kind == KIND_FINITE then
        if value.value % 1 == 0 and math.abs(value.value) <= MAX_SAFE_INTEGER then
            return value.value
        end
    elseif value.kind == KIND_INTEGER and #value.digits <= 15 then
        local parsed = tonumber((value.sign < 0 and "-" or "") .. value.digits)
        if parsed and math.abs(parsed) <= MAX_SAFE_INTEGER then return parsed end
    end
    return nil
end

local knownPositive

local function knownInteger(value, depth)
    depth = depth or 0
    if depth > MAX_CODEC_DEPTH then
        return false
    end
    if value.kind == KIND_FINITE then
        return value.value % 1 == 0
    elseif value.kind == KIND_INTEGER then
        return true
    elseif value.kind == KIND_SCIENTIFIC then
        -- Retained nonnegative-exponent scientific nodes are outside the native
        -- finite range; multiplying their binary significand by 10^exponent
        -- clears its binary denominator and gives an integer.
        return compareSignedText(value.exponent, "0") >= 0
    elseif value.kind == KIND_HYPER then
        return knownInteger(value.base, depth + 1)
            and knownInteger(value.arrows, depth + 1)
            and knownInteger(value.height, depth + 1)
            and value.base.kind ~= KIND_SPECIAL
            and value.arrows.kind ~= KIND_SPECIAL
            and value.height.kind ~= KIND_SPECIAL
    elseif value.kind == KIND_EXPRESSION then
        if value.op == "add" or value.op == "sub" or value.op == "mul" then
            return knownInteger(value.left, depth + 1)
                and knownInteger(value.right, depth + 1)
        elseif value.op == "pow" then
            return knownInteger(value.left, depth + 1)
                and knownInteger(value.right, depth + 1)
                and knownPositive(value.left, depth + 1)
                and knownPositive(value.right, depth + 1)
        end
    end
    return false
end

local function specialSign(value, depth)
    depth = depth or 0
    if depth > MAX_CODEC_DEPTH then
        return nil
    end
    if value.kind == KIND_SPECIAL then
        if value.name == "+infinity" then return 1 end
        if value.name == "-infinity" then return -1 end
        return nil
    elseif value.kind == KIND_FINITE then
        return value.value > 0 and 1 or (value.value < 0 and -1 or 0)
    elseif value.kind == KIND_INTEGER or value.kind == KIND_SCIENTIFIC then
        return value.sign
    elseif value.kind == KIND_HYPER then
        return 1
    elseif value.kind == KIND_EXPRESSION and value.op == "pow" then
        if knownPositive(value.left, depth + 1) then return 1 end
    end
    return nil
end

knownPositive = function(value, depth)
    depth = depth or 0
    if depth > MAX_CODEC_DEPTH then
        return false
    end
    return specialSign(value, depth + 1) == 1
end

local function knownAtLeastTwo(value)
    if value.kind == KIND_FINITE then
        return value.value >= 2
    elseif value.kind == KIND_INTEGER then
        return value.sign > 0 and compareUnsigned(value.digits, "2") >= 0
    elseif value.kind == KIND_SCIENTIFIC then
        return value.sign > 0 and compareSignedText(value.exponent, "0") >= 0
    elseif value.kind == KIND_HYPER then
        return true
    end
    return false
end

local function knownNonZero(value)
    if value.kind == KIND_FINITE then
        return value.value ~= 0
    elseif value.kind == KIND_INTEGER or value.kind == KIND_SCIENTIFIC or value.kind == KIND_HYPER then
        return true
    elseif value.kind == KIND_EXPRESSION and value.op == "pow" then
        return knownPositive(value.left)
    end
    return false
end

local function knownFinite(value)
    return value.kind == KIND_FINITE
        or value.kind == KIND_INTEGER
        or value.kind == KIND_SCIENTIFIC
        or value.kind == KIND_HYPER
end

local function safePow(base, exponent)
    if base == 0 then
        if exponent < 0 then return nil end
        return exponent == 0 and 1 or 0
    elseif base < 0 then
        if exponent % 1 ~= 0 then return nil end
    elseif base > 1 then
        if exponent * math.log10(base) > LOG10_MAX_DOUBLE then return nil end
    elseif base > 0 and base < 1 then
        if exponent * math.log10(base) < -323.5 then return nil end
    end
    local result = math.pow(base, exponent)
    if isFiniteNumber(result) then return result end
    return nil
end

local function evalSmallHyper(base, arrows, height, depth)
    if depth > 16 or base < 2 or base % 1 ~= 0
        or arrows < 1 or arrows % 1 ~= 0
        or height < 1 or height % 1 ~= 0
    then
        return nil
    end
    if arrows == 1 then
        return safePow(base, height)
    elseif height == 1 then
        return base
    elseif arrows > 3 or height > 6 then
        return nil
    end

    local result = base
    for _ = 2, height do
        if arrows == 2 then
            result = safePow(base, result)
        else
            result = evalSmallHyper(base, arrows - 1, result, depth + 1)
        end
        if result == nil then return nil end
    end
    return result
end

local function nativeValue(value)
    if value.kind == KIND_FINITE then
        return value.value
    elseif value.kind == KIND_INTEGER then
        return nativeInteger(value)
    elseif value.kind == KIND_SCIENTIFIC then
        -- 10^-324 underflows before multiplication on binary64 even though
        -- some mantissas (for example 5e-324) round to a non-zero subnormal.
        if value.exponent == "-324" then
            local result = tonumber(string.format("%.17ge%s", value.mantissa, value.exponent))
            if result ~= nil and isFiniteNumber(result) then
                return value.sign * result
            end
        elseif compareSignedText(value.exponent, "-308") >= 0
            and compareSignedText(value.exponent, "308") <= 0
        then
            local result = value.sign * value.mantissa * math.pow(10, tonumber(value.exponent))
            if isFiniteNumber(result) then return result end
        end
    elseif value.kind == KIND_HYPER then
        local base = nativeInteger(value.base)
        local arrows = nativeInteger(value.arrows)
        local height = nativeInteger(value.height)
        if base and arrows and height then return evalSmallHyper(base, arrows, height, 0) end
    end
    return nil
end

local function integerText(value)
    if value.kind == KIND_INTEGER then
        return (value.sign < 0 and "-" or "") .. value.digits
    elseif value.kind == KIND_FINITE and value.value % 1 == 0
        and math.abs(value.value) <= MAX_SAFE_INTEGER
    then
        return string.format("%.0f", value.value)
    end
    return nil
end

local function compareIntegerToFinite(integer, finiteValue)
    local absolute = math.abs(finiteValue)
    local integerDigits = integer.digits
    if absolute % 1 == 0 then
        return compareUnsigned(integerDigits, string.format("%.0f", absolute))
    end
    local wholeDigits = string.format("%.0f", math.floor(absolute))
    local comparison = compareUnsigned(integerDigits, wholeDigits)
    if comparison ~= 0 then return comparison end
    return -1
end

local function finiteParts(value)
    local text = string.format("%.17e", math.abs(value))
    local mantissaText, exponentText = string.match(text, "^([%d%.]+)e([+-]?%d+)$")
    return exponentText, tonumber(mantissaText)
end

local function compareIntegerToScientific(integer, scientific)
    local integerExponent = tostring(#integer.digits - 1)
    local exponentComparison = compareSignedText(integerExponent, scientific.exponent)
    if exponentComparison ~= 0 then return exponentComparison end

    -- The scientific significand is a binary64 approximation. Compare its
    -- round-trip decimal digits before considering lower-order integer digits.
    local text = string.format("%.17e", scientific.mantissa)
    local significand = string.gsub(string.match(text, "^([%d%.]+)e"), "%.", "")
    local count = math.min(#integer.digits, #significand)
    local leftPrefix = string.sub(integer.digits, 1, count)
    local rightPrefix = string.sub(significand, 1, count)
    local comparison = compareUnsigned(leftPrefix, rightPrefix)
    if comparison ~= 0 then return comparison end

    if #integer.digits > #significand then
        for i = #significand + 1, #integer.digits do
            if string.sub(integer.digits, i, i) ~= "0" then return 1 end
        end
    elseif #significand > #integer.digits then
        for i = #integer.digits + 1, #significand do
            if string.sub(significand, i, i) ~= "0" then return -1 end
        end
    end
    return 0
end

local function compareAbsolutePrimitive(left, right)
    if left.kind == KIND_FINITE and right.kind == KIND_FINITE then
        local a, b = math.abs(left.value), math.abs(right.value)
        if a == b then return 0 end
        return a > b and 1 or -1
    elseif left.kind == KIND_INTEGER and right.kind == KIND_INTEGER then
        return compareUnsigned(left.digits, right.digits)
    elseif left.kind == KIND_SCIENTIFIC and right.kind == KIND_SCIENTIFIC then
        local exponentComparison = compareSignedText(left.exponent, right.exponent)
        if exponentComparison ~= 0 then return exponentComparison end
        if left.mantissa == right.mantissa then return 0 end
        return left.mantissa > right.mantissa and 1 or -1
    elseif left.kind == KIND_INTEGER and right.kind == KIND_SCIENTIFIC then
        return compareIntegerToScientific(left, right)
    elseif left.kind == KIND_SCIENTIFIC and right.kind == KIND_INTEGER then
        return -compareIntegerToScientific(right, left)
    elseif left.kind == KIND_INTEGER and right.kind == KIND_FINITE then
        return compareIntegerToFinite(left, right.value)
    elseif left.kind == KIND_FINITE and right.kind == KIND_INTEGER then
        return -compareIntegerToFinite(right, left.value)
    elseif left.kind == KIND_FINITE and right.kind == KIND_SCIENTIFIC then
        local exponent, mantissa = finiteParts(left.value)
        local exponentComparison = compareSignedText(exponent, right.exponent)
        if exponentComparison ~= 0 then return exponentComparison end
        if mantissa == right.mantissa then return 0 end
        return mantissa > right.mantissa and 1 or -1
    elseif left.kind == KIND_SCIENTIFIC and right.kind == KIND_FINITE then
        return -compareAbsolutePrimitive(right, left)
    end
    error("unsupported primitive magnitude comparison", 3)
end

local function compareValueToSmallInteger(value, target)
    local native = nativeValue(value)
    if native and native % 1 == 0 then
        if native == target then return 0 end
        return native > target and 1 or -1
    end
    local ok, result = pcall(CodeNum.compare, value, finiteNode(target))
    if ok then return result end
    return nil
end

local hyperAboveNativeRange

hyperAboveNativeRange = function(value, depth)
    depth = depth or 0
    if depth > MAX_CODEC_DEPTH then
        return false
    end
    local base = nativeValue(value.base)
    local baseVsTwo = compareValueToSmallInteger(value.base, 2)
    local baseVsThree = compareValueToSmallInteger(value.base, 3)
    local baseVsFour = compareValueToSmallInteger(value.base, 4)
    local baseVsFive = compareValueToSmallInteger(value.base, 5)
    local baseVs144 = compareValueToSmallInteger(value.base, 144)
    local rankVsOne = compareValueToSmallInteger(value.arrows, 1)
    local rankVsTwo = compareValueToSmallInteger(value.arrows, 2)
    local rankVsThree = compareValueToSmallInteger(value.arrows, 3)
    local rankVsFour = compareValueToSmallInteger(value.arrows, 4)
    local heightVsTwo = compareValueToSmallInteger(value.height, 2)
    local heightVsThree = compareValueToSmallInteger(value.height, 3)
    local heightVsFour = compareValueToSmallInteger(value.height, 4)
    local heightVsFive = compareValueToSmallInteger(value.height, 5)

    if not baseVsTwo or baseVsTwo < 0 then return false end
    if rankVsOne == 0 then
        if heightVsTwo and heightVsTwo >= 0 then
            if value.base.kind == KIND_INTEGER and #value.base.digits >= 156 then return true end
            if value.base.kind == KIND_SCIENTIFIC and compareSignedText(value.base.exponent, "154") > 0 then
                return true
            end
            if value.base.kind == KIND_HYPER and hyperAboveNativeRange(value.base, depth + 1) then return true end
        end
        if sameTree(value.base, value.height, 0) and baseVs144 and baseVs144 >= 0 then return true end
        if not base or base <= 1 then return false end
        local minimumHeight = math.ceil(LOG10_MAX_DOUBLE / math.log10(base))
        local heightVsMinimum = compareValueToSmallInteger(value.height, minimumHeight)
        return heightVsMinimum ~= nil and heightVsMinimum >= 0
    end

    if not rankVsTwo or rankVsTwo < 0 then return false end
    if heightVsTwo == 0 then
        if rankVsFour and rankVsFour >= 0 and baseVsThree and baseVsThree >= 0 then return true end
        if rankVsThree == 0 and baseVsFour and baseVsFour >= 0 then return true end
        if rankVsTwo == 0 and baseVs144 and baseVs144 >= 0 then return true end
    end
    if heightVsFive and heightVsFive >= 0 then return true end
    if rankVsThree and rankVsThree >= 0 and heightVsFour and heightVsFour >= 0 then return true end
    if rankVsFour and rankVsFour >= 0 and heightVsThree and heightVsThree >= 0 then return true end
    if rankVsThree and rankVsThree >= 0 and heightVsThree and heightVsThree >= 0 and baseVsThree and baseVsThree >= 0 then
        return true
    end
    if heightVsFour and heightVsFour >= 0 and baseVsThree and baseVsThree >= 0 then return true end
    if heightVsThree and heightVsThree >= 0 and baseVsFive and baseVsFive >= 0 then return true end
    return false
end

local function compareInternal(left, right, depth)
    if depth > MAX_CODEC_DEPTH then error("CodeNum comparison depth exceeded", 3) end
    if (left.kind == KIND_SPECIAL and left.name == "nan")
        or (right.kind == KIND_SPECIAL and right.name == "nan")
    then
        error("NaN is unordered and cannot be compared", 3)
    end
    if sameTree(left, right, depth) then return 0 end

    local leftSign, rightSign = specialSign(left), specialSign(right)
    if leftSign == nil or rightSign == nil then
        error("CodeNum cannot prove an ordering for these symbolic values", 3)
    elseif leftSign ~= rightSign then
        return leftSign > rightSign and 1 or -1
    elseif leftSign == 0 then
        return 0
    end

    if left.kind == KIND_SPECIAL or right.kind == KIND_SPECIAL then
        if left.kind == KIND_SPECIAL and left.name == "+infinity" then return 1 end
        if left.kind == KIND_SPECIAL and left.name == "-infinity" then return -1 end
        if right.kind == KIND_SPECIAL and right.name == "+infinity" then return -1 end
        if right.kind == KIND_SPECIAL and right.name == "-infinity" then return 1 end
    end

    if PRIMITIVE_KIND[left.kind] and PRIMITIVE_KIND[right.kind] then
        local magnitude = compareAbsolutePrimitive(left, right)
        return leftSign < 0 and -magnitude or magnitude
    end

    if left.kind == KIND_HYPER and right.kind == KIND_HYPER then
        if sameTree(left.base, right.base, depth + 1)
            and sameTree(left.height, right.height, depth + 1)
            and knownInteger(left.base)
            and knownAtLeastTwo(left.base)
        then
            local height = nativeInteger(left.height)
            if height and height >= 3 then
                return compareInternal(left.arrows, right.arrows, depth + 1)
            end
        end
        if sameTree(left.base, right.base, depth + 1)
            and sameTree(left.arrows, right.arrows, depth + 1)
        then
            return compareInternal(left.height, right.height, depth + 1)
        end
    end

    if left.kind == KIND_HYPER and right.kind ~= KIND_HYPER and hyperAboveNativeRange(left) then
        if right.kind == KIND_FINITE then return 1 end
        if right.kind == KIND_INTEGER and #right.digits <= 308 then return 1 end
        if right.kind == KIND_SCIENTIFIC and compareSignedText(right.exponent, "0") < 0 then return 1 end
    elseif right.kind == KIND_HYPER and left.kind ~= KIND_HYPER and hyperAboveNativeRange(right) then
        if left.kind == KIND_FINITE then return -1 end
        if left.kind == KIND_INTEGER and #left.digits <= 308 then return -1 end
        if left.kind == KIND_SCIENTIFIC and compareSignedText(left.exponent, "0") < 0 then return -1 end
    end
    error("CodeNum cannot prove an ordering for these symbolic values", 3)
end

local function expression(op, left, right)
    left, right = numberNode(left), numberNode(right)
    if op == "add" then
        if left.kind == KIND_FINITE and left.value == 0 then return right end
        if right.kind == KIND_FINITE and right.value == 0 then return left end
    elseif op == "sub" then
        if right.kind == KIND_FINITE and right.value == 0 then return left end
        if sameTree(left, right, 0) and knownNonZero(left) then return ZERO end
    elseif op == "mul" then
        if left.kind == KIND_FINITE and left.value == 0 and knownFinite(right) then return ZERO end
        if right.kind == KIND_FINITE and right.value == 0 and knownFinite(left) then return ZERO end
        if left.kind == KIND_FINITE and left.value == 1 then return right end
        if right.kind == KIND_FINITE and right.value == 1 then return left end
    elseif op == "div" then
        if right.kind == KIND_FINITE and right.value == 1 then return left end
        if sameTree(left, right, 0) and knownNonZero(left) then return ONE end
    elseif op == "pow" then
        if right.kind == KIND_FINITE and right.value == 0 then return ONE end
        if right.kind == KIND_FINITE and right.value == 1 then return left end
    end
    return make({ kind = KIND_EXPRESSION, op = op, left = left, right = right })
end

local function callExpression(op, value)
    return make({ kind = KIND_CALL, op = op, value = numberNode(value) })
end

local function asSignedIntegerNode(value)
    local text = integerText(value)
    if text then return CodeNum.integer(text) end
    return nil
end

local function add(left, right)
    left, right = numberNode(left), numberNode(right)
    if (left.kind == KIND_SPECIAL and left.name == "nan")
        or (right.kind == KIND_SPECIAL and right.name == "nan")
    then
        return specialNode("nan")
    end

    if left.kind == KIND_SPECIAL or right.kind == KIND_SPECIAL then
        if left.kind == KIND_SPECIAL and right.kind == KIND_SPECIAL then
            if left.name ~= right.name then return specialNode("nan") end
            return left
        end
        if left.kind == KIND_SPECIAL then
            if knownFinite(right) then return left end
            return expression("add", left, right)
        end
        if knownFinite(left) then return right end
        return expression("add", left, right)
    end

    local leftInteger, rightInteger = asSignedIntegerNode(left), asSignedIntegerNode(right)
    if leftInteger and rightInteger then
        return CodeNum.integer(addSignedIntegerStrings(integerText(leftInteger), integerText(rightInteger)))
    end

    if left.kind == KIND_FINITE and right.kind == KIND_FINITE then
        local result = left.value + right.value
        if isFiniteNumber(result) then return finiteNode(result) end
        local leftExponent, leftMantissa = finiteParts(left.value)
        local rightExponent, rightMantissa = finiteParts(right.value)
        local leftOrder, rightOrder = tonumber(leftExponent), tonumber(rightExponent)
        local topOrder = math.max(leftOrder, rightOrder)
        local leftTerm = (left.value < 0 and -leftMantissa or leftMantissa) * math.pow(10, leftOrder - topOrder)
        local rightTerm = (right.value < 0 and -rightMantissa or rightMantissa) * math.pow(10, rightOrder - topOrder)
        local scaled = leftTerm + rightTerm
        if scaled == 0 then return ZERO end
        return sciNode(scaled < 0 and -1 or 1, math.abs(scaled), tostring(topOrder))
    end

    if left.kind == KIND_SCIENTIFIC and right.kind == KIND_SCIENTIFIC and left.exponent == right.exponent then
        local result = left.sign * left.mantissa + right.sign * right.mantissa
        if result == 0 then return ZERO end
        return sciNode(result < 0 and -1 or 1, math.abs(result), left.exponent)
    end
    return expression("add", left, right)
end

local function negate(value)
    value = numberNode(value)
    if value.kind == KIND_FINITE then
        return finiteNode(-value.value)
    elseif value.kind == KIND_INTEGER then
        return integerNode(-value.sign, value.digits)
    elseif value.kind == KIND_SCIENTIFIC then
        return make({ kind = KIND_SCIENTIFIC, sign = -value.sign, mantissa = value.mantissa, exponent = value.exponent })
    elseif value.kind == KIND_SPECIAL then
        if value.name == "+infinity" then return specialNode("-infinity") end
        if value.name == "-infinity" then return specialNode("+infinity") end
        return value
    end
    return expression("mul", finiteNode(-1), value)
end

local function subtract(left, right)
    left, right = numberNode(left), numberNode(right)
    local leftInteger, rightInteger = asSignedIntegerNode(left), asSignedIntegerNode(right)
    if leftInteger and rightInteger then
        return CodeNum.integer(addSignedIntegerStrings(
            integerText(leftInteger),
            negateIntegerString(integerText(rightInteger))
        ))
    end
    if left.kind == KIND_FINITE and right.kind == KIND_FINITE then
        local result = left.value - right.value
        if isFiniteNumber(result) then return finiteNode(result) end
    end
    return add(left, negate(right))
end

local function scientificApproximation(value)
    if value.kind == KIND_SCIENTIFIC then
        return value.sign, value.mantissa, value.exponent
    elseif value.kind == KIND_INTEGER then
        local prefix = string.sub(value.digits, 1, math.min(15, #value.digits))
        return value.sign, tonumber(prefix) / math.pow(10, #prefix - 1), tostring(#value.digits - 1)
    elseif value.kind == KIND_FINITE and value.value ~= 0 then
        local exponent, mantissa = finiteParts(value.value)
        return value.value < 0 and -1 or 1, mantissa, exponent
    end
    return nil
end

local function multiply(left, right)
    left, right = numberNode(left), numberNode(right)
    if (left.kind == KIND_SPECIAL and left.name == "nan")
        or (right.kind == KIND_SPECIAL and right.name == "nan")
    then
        return specialNode("nan")
    end

    local leftZero = left.kind == KIND_FINITE and left.value == 0
    local rightZero = right.kind == KIND_FINITE and right.value == 0
    local leftInfinity = left.kind == KIND_SPECIAL and string.find(left.name, "infinity", 1, true) ~= nil
    local rightInfinity = right.kind == KIND_SPECIAL and string.find(right.name, "infinity", 1, true) ~= nil
    if (leftZero and rightInfinity) or (rightZero and leftInfinity) then
        return specialNode("nan")
    elseif leftZero and knownFinite(right) then
        return ZERO
    elseif rightZero and knownFinite(left) then
        return ZERO
    end

    if left.kind == KIND_SPECIAL or right.kind == KIND_SPECIAL then
        local leftSign, rightSign = specialSign(left), specialSign(right)
        if leftSign == nil or rightSign == nil then return expression("mul", left, right) end
        return specialNode(leftSign * rightSign < 0 and "-infinity" or "+infinity")
    end

    local leftInteger, rightInteger = asSignedIntegerNode(left), asSignedIntegerNode(right)
    if leftInteger and rightInteger then
        local leftSign, leftDigits = normalizeSignedInteger(integerText(leftInteger))
        local rightSign, rightDigits = normalizeSignedInteger(integerText(rightInteger))
        if #leftDigits + #rightDigits > MAX_EXACT_MULTIPLICATION_DIGITS then
            return expression("mul", left, right)
        end
        return integerNode(leftSign * rightSign, multiplyUnsigned(leftDigits, rightDigits))
    end

    if left.kind == KIND_FINITE and right.kind == KIND_FINITE then
        local result = left.value * right.value
        if isFiniteNumber(result) and (result ~= 0 or left.value == 0 or right.value == 0) then
            return finiteNode(result)
        end
        local leftSign, leftMantissa, leftExponent = scientificApproximation(left)
        local rightSign, rightMantissa, rightExponent = scientificApproximation(right)
        return sciNode(
            leftSign * rightSign,
            leftMantissa * rightMantissa,
            addSignedIntegerStrings(leftExponent, rightExponent)
        )
    end

    local leftSign, leftMantissa, leftExponent = scientificApproximation(left)
    local rightSign, rightMantissa, rightExponent = scientificApproximation(right)
    if leftSign and rightSign then
        return sciNode(
            leftSign * rightSign,
            leftMantissa * rightMantissa,
            addSignedIntegerStrings(leftExponent, rightExponent)
        )
    end
    return expression("mul", left, right)
end

local function divide(left, right)
    left, right = numberNode(left), numberNode(right)
    if (left.kind == KIND_SPECIAL and left.name == "nan")
        or (right.kind == KIND_SPECIAL and right.name == "nan")
    then
        return specialNode("nan")
    end

    if right.kind == KIND_FINITE and right.value == 1 then return left end
    if right.kind == KIND_FINITE and right.value == -1 then return negate(left) end
    if left.kind == KIND_FINITE and left.value == 0 and knownNonZero(right) then return ZERO end

    if right.kind == KIND_FINITE and right.value == 0 then
        if left.kind == KIND_FINITE and left.value == 0 then return specialNode("nan") end
        local sign = specialSign(left)
        if sign == nil then return expression("div", left, right) end
        return specialNode(sign < 0 and "-infinity" or "+infinity")
    end

    if left.kind == KIND_SPECIAL or right.kind == KIND_SPECIAL then
        if left.kind == KIND_SPECIAL and right.kind == KIND_SPECIAL then return specialNode("nan") end
        if left.kind == KIND_SPECIAL then
            local leftSign, rightSign = specialSign(left), specialSign(right)
            if leftSign == nil or rightSign == nil then return expression("div", left, right) end
            return specialNode(leftSign * rightSign < 0 and "-infinity" or "+infinity")
        end
        if knownFinite(left) then return ZERO end
        return expression("div", left, right)
    end

    if left.kind == KIND_FINITE and right.kind == KIND_FINITE then
        local result = left.value / right.value
        if isFiniteNumber(result) and (result ~= 0 or left.value == 0) then return finiteNode(result) end
        local leftSign, leftMantissa, leftExponent = scientificApproximation(left)
        local rightSign, rightMantissa, rightExponent = scientificApproximation(right)
        if leftSign and rightSign then
            return sciNode(
                leftSign * rightSign,
                leftMantissa / rightMantissa,
                addSignedIntegerStrings(leftExponent, negateIntegerString(rightExponent))
            )
        end
        return finiteNode(result)
    end

    if sameTree(left, right, 0) and knownNonZero(left) then return ONE end
    local leftSign, leftMantissa, leftExponent = scientificApproximation(left)
    local rightSign, rightMantissa, rightExponent = scientificApproximation(right)
    if leftSign and rightSign then
        return sciNode(
            leftSign * rightSign,
            leftMantissa / rightMantissa,
            addSignedIntegerStrings(leftExponent, negateIntegerString(rightExponent))
        )
    end
    return expression("div", left, right)
end

local function hyper(base, arrows, height)
    base, arrows, height = numberNode(base), numberNode(arrows), numberNode(height)
    if not knownInteger(arrows) or not knownPositive(arrows) then
        error("hyperoperation rank must be a known positive integer", 2)
    end
    if not knownInteger(height) or not knownPositive(height) then
        error("hyperoperation height must be a known positive integer", 2)
    end
    if not knownInteger(base) or not knownAtLeastTwo(base) then
        error("CodeNum.hyper requires a known integer base of at least 2", 2)
    end

    if sameTree(height, ONE, 0) then return base end
    local nativeBase, nativeArrows, nativeHeight = nativeInteger(base), nativeInteger(arrows), nativeInteger(height)

    if sameTree(base, TWO, 0) and sameTree(height, TWO, 0) then return finiteNode(4) end

    if nativeArrows == 1 and nativeHeight and nativeHeight >= 2
        and base.kind == KIND_INTEGER
        and #base.digits * nativeHeight <= 4096
    then
        local result, factor, remaining = ONE, base, nativeHeight
        while remaining > 0 do
            if remaining % 2 == 1 then result = multiply(result, factor) end
            remaining = math.floor(remaining / 2)
            if remaining > 0 then factor = multiply(factor, factor) end
        end
        return result
    end

    if nativeArrows and nativeArrows > 1 and nativeArrows <= 16 and sameTree(height, TWO, 0) then
        return hyper(base, CodeNum.integer(nativeArrows - 1), base)
    end

    if nativeBase and nativeArrows and nativeHeight then
        local result = evalSmallHyper(nativeBase, nativeArrows, nativeHeight, 0)
        if result ~= nil then return finiteNode(result) end
    end
    return make({ kind = KIND_HYPER, base = base, arrows = arrows, height = height })
end

local function power(base, exponent)
    base, exponent = numberNode(base), numberNode(exponent)
    local baseNative, exponentNative = nativeValue(base), nativeValue(exponent)
    if exponent.kind == KIND_FINITE and exponent.value == 0 then return ONE end
    if (base.kind == KIND_SPECIAL and base.name == "nan")
        or (exponent.kind == KIND_SPECIAL and exponent.name == "nan")
    then
        return specialNode("nan")
    end

    if base.kind == KIND_SPECIAL and string.find(base.name, "infinity", 1, true) then
        if exponent.kind == KIND_SPECIAL and string.find(exponent.name, "infinity", 1, true) then
            if exponent.name == "-infinity" and base.name == "+infinity" then return ZERO end
            if exponent.name == "+infinity" and base.name == "+infinity" then return specialNode("+infinity") end
            return specialNode("nan")
        end
        if exponentNative ~= nil then
            if exponentNative < 0 then
                if base.name == "-infinity" and exponentNative % 1 ~= 0 then return specialNode("nan") end
                return ZERO
            end
            if base.name == "+infinity" then return specialNode("+infinity") end
            if exponentNative % 1 ~= 0 then return specialNode("nan") end
            return specialNode(math.abs(exponentNative) % 2 == 1 and "-infinity" or "+infinity")
        end
        return expression("pow", base, exponent)
    end

    if exponent.kind == KIND_SPECIAL and string.find(exponent.name, "infinity", 1, true) then
        if baseNative == 1 then return ONE end
        if baseNative == 0 then
            return exponent.name == "+infinity" and ZERO or specialNode("+infinity")
        end
        if baseNative and baseNative > 0 then
            local grows = (baseNative > 1) == (exponent.name == "+infinity")
            return grows and specialNode("+infinity") or ZERO
        end
        if baseNative and baseNative < 0 then return specialNode("nan") end
        if knownAtLeastTwo(base) then
            return exponent.name == "+infinity" and specialNode("+infinity") or ZERO
        end
        return expression("pow", base, exponent)
    end

    if baseNative ~= nil and exponentNative ~= nil then
        local result = math.pow(baseNative, exponentNative)
        if result ~= result then return specialNode("nan") end
        if isFiniteNumber(result) then
            if result ~= 0 or baseNative == 0 then return finiteNode(result) end
        end
        if baseNative == 0 and exponentNative < 0 then return specialNode("+infinity") end

        if exponentNative > 0 and exponentNative % 1 == 0 and knownInteger(base) then
            local positiveBase = CodeNum.abs(base)
            local magnitude = hyper(positiveBase, ONE, exponent)
            if baseNative < 0 and exponentNative % 2 ~= 0 then return negate(magnitude) end
            return magnitude
        end

        if baseNative > 0 and baseNative ~= 1 then
            local logarithm = exponentNative * math.log10(baseNative)
            if isFiniteNumber(logarithm) then
                local wholeExponent = math.floor(logarithm)
                local mantissa = math.pow(10, logarithm - wholeExponent)
                return sciNode(1, mantissa, string.format("%.0f", wholeExponent))
            end
        elseif baseNative < 0 and exponentNative % 1 == 0 then
            local logarithm = exponentNative * math.log10(math.abs(baseNative))
            if isFiniteNumber(logarithm) then
                local wholeExponent = math.floor(logarithm)
                local mantissa = math.pow(10, logarithm - wholeExponent)
                local sign = exponentNative % 2 == 1 and -1 or 1
                return sciNode(sign, mantissa, string.format("%.0f", wholeExponent))
            end
        end
    end

    if knownInteger(base) and knownAtLeastTwo(base) and knownInteger(exponent) and knownPositive(exponent) then
        return hyper(base, ONE, exponent)
    end
    return expression("pow", base, exponent)
end

function CodeNum.new(value)
    return numberNode(value)
end

function CodeNum.integer(value)
    local sign, digits = normalizeSignedInteger(value)
    return integerNodeNormalized(sign, digits)
end

function CodeNum.scientific(mantissa, exponent, sign)
    if type(mantissa) ~= "number" or not isFiniteNumber(mantissa) then
        error("mantissa must be a finite number", 2)
    end
    if type(exponent) ~= "number" and type(exponent) ~= "string" then
        error("exponent must be an integer or signed decimal integer string", 2)
    end
    normalizeSignedInteger(exponent)
    local direction = sign or (mantissa < 0 and -1 or 1)
    if direction ~= -1 and direction ~= 1 then error("scientific sign must be -1 or 1", 2) end
    if mantissa == 0 then return ZERO end
    return sciNode(direction, math.abs(mantissa), exponent)
end

function CodeNum.fromString(value)
    if type(value) ~= "string" then error("CodeNum.fromString expects a string", 2) end
    value = string.gsub(value, "^%s*(.-)%s*$", "%1")
    if value == "NaN" or value == "nan" then return specialNode("nan") end
    if value == "Inf" or value == "+Inf" or value == "Infinity" or value == "+Infinity" then
        return specialNode("+infinity")
    end
    if value == "-Inf" or value == "-Infinity" then return specialNode("-infinity") end
    if string.match(value, "^[+-]?%d+$") then return CodeNum.integer(value) end

    local mantissaText, exponentText = string.match(value, "^([+-]?[%d%.]+)[eE]([+-]?%d+)$")
    if mantissaText and exponentText then
        local mantissa = tonumber(mantissaText)
        if not mantissa or not isFiniteNumber(mantissa) then error("invalid scientific notation", 2) end
        if mantissa == 0 then return ZERO end
        return sciNode(mantissa < 0 and -1 or 1, math.abs(mantissa), exponentText)
    end
    local parsed = tonumber(value)
    if parsed ~= nil then return finiteNode(parsed) end
    error("invalid CodeNum string: " .. value, 2)
end

function CodeNum.hyper(base, arrows, height)
    return hyper(base, arrows, height)
end
function CodeNum.pow(base, exponent)
    return power(base, exponent)
end
function CodeNum.add(left, right)
    return add(left, right)
end
function CodeNum.sub(left, right)
    return subtract(left, right)
end
function CodeNum.mul(left, right)
    return multiply(left, right)
end
function CodeNum.div(left, right)
    return divide(left, right)
end
function CodeNum.neg(value)
    return negate(value)
end

function CodeNum.abs(value)
    value = numberNode(value)
    if value.kind == KIND_SPECIAL and value.name == "nan" then return value end
    local sign = specialSign(value)
    if sign == nil then return callExpression("abs", value) end
    return sign < 0 and negate(value) or value
end

function CodeNum.compare(left, right)
    return compareInternal(numberNode(left), numberNode(right), 0)
end

-- Keep input conversion inside pcall. In the previous implementation,
-- numberNode(left/right) ran before pcall and invalid arguments still threw.
function CodeNum.equals(left, right)
    local ok, result = pcall(function()
        return compareInternal(numberNode(left), numberNode(right), 0)
    end)
    return ok and result == 0
end

function CodeNum.min(left, right)
    left, right = numberNode(left), numberNode(right)
    return CodeNum.compare(left, right) <= 0 and left or right
end
function CodeNum.max(left, right)
    left, right = numberNode(left), numberNode(right)
    return CodeNum.compare(left, right) >= 0 and left or right
end
function CodeNum.isInteger(value)
    return knownInteger(numberNode(value))
end
function CodeNum.isFinite(value)
    return knownFinite(numberNode(value))
end

function CodeNum.tryToNumber(value)
    local node = numberNode(value)
    if node.kind == KIND_FINITE then return node.value end
    if node.kind == KIND_SPECIAL then
        if node.name == "nan" then return 0 / 0 end
        return node.name == "+infinity" and math.huge or -math.huge
    end
    local native = nativeValue(node)
    if native ~= nil then return native end

    if node.kind == KIND_INTEGER then
        local parsed = tonumber((node.sign < 0 and "-" or "") .. node.digits)
        if parsed and isFiniteNumber(parsed) then return parsed end
        return node.sign < 0 and -math.huge or math.huge
    elseif node.kind == KIND_SCIENTIFIC then
        local exponentComparison = compareSignedText(node.exponent, "-324")
        if exponentComparison < 0 then return node.sign < 0 and -0.0 or 0 end
        local exponent = tonumber(node.exponent)
        if exponent and exponent <= 308 then
            local result = node.sign * node.mantissa * math.pow(10, exponent)
            if isFiniteNumber(result) then return result end
        end
        return node.sign < 0 and -math.huge or math.huge
    elseif node.kind == KIND_HYPER then
        if hyperAboveNativeRange(node) then return math.huge end
        return nil
    end
    return nil
end

function CodeNum.toNumber(value)
    local result = CodeNum.tryToNumber(value)
    if result == nil then error("CodeNum.toNumber cannot coerce this symbolic expression; use toString or encode", 2) end
    return result
end

function CodeNum.log10(value)
    value = numberNode(value)
    if value.kind == KIND_SPECIAL then
        if value.name == "nan" or value.name == "-infinity" then return specialNode("nan") end
        return specialNode("+infinity")
    end
    if value.kind == KIND_FINITE then
        if value.value < 0 then return specialNode("nan") end
        if value.value == 0 then return specialNode("-infinity") end
        return finiteNode(math.log10(value.value))
    elseif value.kind == KIND_INTEGER then
        if value.sign < 0 then return specialNode("nan") end
        local prefix = string.sub(value.digits, 1, math.min(17, #value.digits))
        local leading = tonumber(prefix) / math.pow(10, #prefix - 1)
        return finiteNode((#value.digits - 1) + math.log10(leading))
    elseif value.kind == KIND_SCIENTIFIC then
        if value.sign < 0 then return specialNode("nan") end
        local exponent = nativeInteger(CodeNum.integer(value.exponent))
        if exponent then return finiteNode(exponent + math.log10(value.mantissa)) end
        return add(CodeNum.integer(value.exponent), finiteNode(math.log10(value.mantissa)))
    elseif value.kind == KIND_HYPER then
        local rank = nativeInteger(value.arrows)
        local base = nativeValue(value.base)
        local height = nativeValue(value.height)
        if rank == 1 and base and base > 0 and height then return finiteNode(height * math.log10(base)) end
    end
    return callExpression("log10", value)
end

function CodeNum.floor(value)
    value = numberNode(value)
    if value.kind == KIND_SPECIAL then return value end
    if value.kind == KIND_FINITE then return finiteNode(math.floor(value.value)) end
    if value.kind == KIND_INTEGER or value.kind == KIND_HYPER then return value end
    if value.kind == KIND_SCIENTIFIC then
        if compareSignedText(value.exponent, "0") >= 0 then return value end
        return finiteNode(value.sign < 0 and -1 or 0)
    end
    error("floor is not defined for this symbolic expression", 2)
end

function CodeNum.ceil(value)
    value = numberNode(value)
    if value.kind == KIND_SPECIAL then return value end
    if value.kind == KIND_FINITE then return finiteNode(math.ceil(value.value)) end
    if value.kind == KIND_INTEGER or value.kind == KIND_HYPER then return value end
    if value.kind == KIND_SCIENTIFIC then
        if compareSignedText(value.exponent, "0") >= 0 then return value end
        return finiteNode(value.sign > 0 and 1 or 0)
    end
    error("ceil is not defined for this symbolic expression", 2)
end

function CodeNum.round(value)
    value = numberNode(value)
    if value.kind == KIND_SPECIAL then return value end
    if value.kind == KIND_FINITE then
        local n = value.value
        return finiteNode(n >= 0 and math.floor(n + 0.5) or math.ceil(n - 0.5))
    end
    if value.kind == KIND_INTEGER or value.kind == KIND_HYPER then return value end
    if value.kind == KIND_SCIENTIFIC then
        if compareSignedText(value.exponent, "0") >= 0 then return value end
        return ZERO
    end
    error("round is not defined for this symbolic expression", 2)
end

local function display(node, depth, budget)
    if depth > MAX_DISPLAY_DEPTH then return "<depth-limit>" end
    budget.count += 1
    if budget.count > MAX_DISPLAY_NODES then return "<node-limit>" end
    if node.kind == KIND_FINITE then
        return string.format("%.17g", node.value)
    elseif node.kind == KIND_INTEGER then
        return (node.sign < 0 and "-" or "") .. node.digits
    elseif node.kind == KIND_SCIENTIFIC then
        return (node.sign < 0 and "-" or "") .. string.format("%.17g", node.mantissa) .. "e" .. node.exponent
    elseif node.kind == KIND_SPECIAL then
        if node.name == "nan" then return "NaN" end
        return node.name == "+infinity" and "+Infinity" or "-Infinity"
    elseif node.kind == KIND_HYPER then
        return display(node.base, depth + 1, budget)
            .. " ↑^" .. display(node.arrows, depth + 1, budget)
            .. " " .. display(node.height, depth + 1, budget)
    elseif node.kind == KIND_CALL then
        return node.op .. "(" .. display(node.value, depth + 1, budget) .. ")"
    end
    return "(" .. display(node.left, depth + 1, budget)
        .. " " .. (DISPLAY_SYMBOL[node.op] or node.op) .. " "
        .. display(node.right, depth + 1, budget) .. ")"
end

function CodeNum.toString(value)
    return display(numberNode(value), 0, { count = 0 })
end

local function toData(node, depth, budget)
    if depth > MAX_CODEC_DEPTH then error("CodeNum serialization depth limit exceeded", 3) end
    budget.count += 1
    if budget.count > MAX_CODEC_NODES then error("CodeNum serialization node limit exceeded", 3) end
    if node.kind == KIND_FINITE then
        return { kind = KIND_FINITE, value = node.value }
    elseif node.kind == KIND_INTEGER then
        return { kind = KIND_INTEGER, sign = node.sign, digits = node.digits }
    elseif node.kind == KIND_SCIENTIFIC then
        return { kind = KIND_SCIENTIFIC, sign = node.sign, mantissa = node.mantissa, exponent = node.exponent }
    elseif node.kind == KIND_SPECIAL then
        return { kind = KIND_SPECIAL, name = node.name }
    elseif node.kind == KIND_HYPER then
        return {
            kind = KIND_HYPER,
            base = toData(node.base, depth + 1, budget),
            arrows = toData(node.arrows, depth + 1, budget),
            height = toData(node.height, depth + 1, budget),
        }
    elseif node.kind == KIND_CALL then
        return { kind = KIND_CALL, op = node.op, value = toData(node.value, depth + 1, budget) }
    end
    return {
        kind = KIND_EXPRESSION,
        op = node.op,
        left = toData(node.left, depth + 1, budget),
        right = toData(node.right, depth + 1, budget),
    }
end

local function fromData(data, depth, budget)
    if depth > MAX_CODEC_DEPTH then error("CodeNum decoding depth limit exceeded", 3) end
    budget.count += 1
    if budget.count > MAX_CODEC_NODES then error("CodeNum decoding node limit exceeded", 3) end
    if type(data) ~= "table" or type(data.kind) ~= "string" then error("invalid CodeNum node", 3) end

    if data.kind == KIND_FINITE then
        if not isFiniteNumber(data.value) then error("invalid finite CodeNum payload", 3) end
        return finiteNode(data.value)
    elseif data.kind == KIND_INTEGER then
        if data.sign ~= -1 and data.sign ~= 1 then error("invalid integer sign", 3) end
        if type(data.digits) ~= "string" or normalizeUnsignedDigits(data.digits) ~= data.digits or data.digits == "0" then
            error("invalid integer digits", 3)
        end
        return integerNodeNormalized(data.sign, data.digits)
    elseif data.kind == KIND_SCIENTIFIC then
        if (data.sign ~= -1 and data.sign ~= 1)
            or not isFiniteNumber(data.mantissa)
            or data.mantissa < 1
            or data.mantissa >= 10
        then
            error("invalid scientific CodeNum payload", 3)
        end
        local exponentSign, exponentDigits = normalizeSignedInteger(data.exponent)
        local exponent = (exponentSign < 0 and "-" or "") .. exponentDigits
        return sciNode(data.sign, data.mantissa, exponent)
    elseif data.kind == KIND_SPECIAL then
        if data.name == "nan" or data.name == "+infinity" or data.name == "-infinity" then
            return specialNode(data.name)
        end
        error("invalid CodeNum special value", 3)
    elseif data.kind == KIND_HYPER then
        return hyper(
            fromData(data.base, depth + 1, budget),
            fromData(data.arrows, depth + 1, budget),
            fromData(data.height, depth + 1, budget)
        )
    elseif data.kind == KIND_EXPRESSION then
        if not EXPRESSION_OP[data.op] then error("invalid symbolic operation", 3) end
        return expression(
            data.op,
            fromData(data.left, depth + 1, budget),
            fromData(data.right, depth + 1, budget)
        )
    elseif data.kind == KIND_CALL then
        if data.op ~= "abs" and data.op ~= "log10" then error("invalid symbolic function", 3) end
        return callExpression(data.op, fromData(data.value, depth + 1, budget))
    end
    error("unknown CodeNum node kind", 3)
end

function CodeNum.encode(value)
    local payload = toData(numberNode(value), 0, { count = 0 })
    return HttpService:JSONEncode({ schema = "CodeNum", version = CodeNum.FORMAT_VERSION, value = payload })
end

function CodeNum.decode(serialized)
    if type(serialized) ~= "string" then error("CodeNum.decode expects a JSON string", 2) end
    local envelope = HttpService:JSONDecode(serialized)
    if type(envelope) ~= "table" or envelope.schema ~= "CodeNum" or envelope.version ~= CodeNum.FORMAT_VERSION then
        error("unsupported CodeNum serialized format", 2)
    end
    return fromData(envelope.value, 0, { count = 0 })
end

function CodeNum.googol()
    return sciNode(1, 1, "100")
end
function CodeNum.googolplex()
    return hyper(TEN, ONE, CodeNum.googol())
end
function CodeNum.boogol()
    return hyper(TEN, CodeNum.integer("100"), TEN)
end
function CodeNum.boogolplex()
    return hyper(TEN, CodeNum.boogol(), TEN)
end
function CodeNum.boogolduplex()
    return hyper(TEN, CodeNum.boogolplex(), TEN)
end

CodeNum.plus = CodeNum.add
CodeNum.minus = CodeNum.sub
CodeNum.times = CodeNum.mul
CodeNum.divide = CodeNum.div
CodeNum.stringify = CodeNum.toString
CodeNum.serialize = CodeNum.encode
CodeNum.deserialize = CodeNum.decode

MT.__add = function(left, right) return add(left, right) end
MT.__sub = function(left, right) return subtract(left, right) end
MT.__mul = function(left, right) return multiply(left, right) end
MT.__div = function(left, right) return divide(left, right) end
MT.__pow = function(left, right) return power(left, right) end
MT.__unm = function(value) return negate(value) end
MT.__eq = function(left, right) return CodeNum.equals(left, right) end
MT.__lt = function(left, right) return CodeNum.compare(left, right) < 0 end
MT.__le = function(left, right) return CodeNum.compare(left, right) <= 0 end
MT.__tostring = function(value) return CodeNum.toString(value) end
MT.__concat = function(left, right)
    local leftText = isCodeNum(left) and CodeNum.toString(left) or tostring(left)
    local rightText = isCodeNum(right) and CodeNum.toString(right) or tostring(right)
    return leftText .. rightText
end

ZERO = finiteNode(0)
ONE = finiteNode(1)
TWO = finiteNode(2)
TEN = finiteNode(10)
CodeNum.ZERO = ZERO
CodeNum.ONE = ONE
CodeNum.TWO = TWO
CodeNum.TEN = TEN

-- Freezing MT protects the methods without blocking table.freeze on CodeNum nodes.
table.freeze(MT)
return table.freeze(CodeNum)
