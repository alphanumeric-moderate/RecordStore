--!nocheck
-- Manual Roblox Studio comparison harness.
-- Place CodeNum and AptInt under ReplicatedStorage before running this Script.
-- Inputs are constructed before timing; only raw arithmetic calls are measured.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CodeNum = require(ReplicatedStorage:WaitForChild("CodeNum"))
local AptInt = require(ReplicatedStorage:WaitForChild("AptInt"):WaitForChild("AptInt"))

local DIGIT_SIZES = { 50, 100, 250, 500, 1000, 1500, 2000 }
local WARMUP_ITERATIONS = 3
local SAMPLE_ITERATIONS = 9
local OPERATIONS_PER_SAMPLE = 5

local function median(values)
	table.sort(values)
	return values[math.ceil(#values / 2)]
end

local function measure(operation)
	for _ = 1, WARMUP_ITERATIONS do
		operation()
	end
	local samples = table.create(SAMPLE_ITERATIONS)
	for sample = 1, SAMPLE_ITERATIONS do
		local started = os.clock()
		for _ = 1, OPERATIONS_PER_SAMPLE do
			operation()
		end
		samples[sample] = (os.clock() - started) / OPERATIONS_PER_SAMPLE
	end
	return median(samples)
end

print("CodeNum vs AptInt | same decimal integer operands | median seconds/op")
print("Enable native code generation in Studio to measure the --!native request.")

for _, digits in DIGIT_SIZES do
	local leftText = string.rep("9", digits)
	local rightText = string.rep("7", digits)
	local leftCodeNum = CodeNum.fromInteger(leftText)
	local rightCodeNum = CodeNum.fromInteger(rightText)
	local leftAptInt = AptInt.new(leftText)
	local rightAptInt = AptInt.new(rightText)

	local codeProduct = CodeNum.mul(leftCodeNum, rightCodeNum, digits * 2)
	local aptProduct = leftAptInt:MultiplyRaw(rightAptInt)
	local codeQuotient = CodeNum.div(codeProduct, rightCodeNum, digits)
	local aptQuotient = aptProduct:DivideRaw(rightAptInt)

	assert(CodeNum.compare(codeQuotient, leftCodeNum) == 0, "CodeNum preflight division failed")
	assert(aptQuotient:EqualsRaw(leftAptInt), "AptInt preflight division failed")

	local codeMulTime = measure(function()
		CodeNum.mul(leftCodeNum, rightCodeNum, digits * 2)
	end)
	local aptMulTime = measure(function()
		leftAptInt:MultiplyRaw(rightAptInt)
	end)
	local codeDivTime = measure(function()
		CodeNum.div(codeProduct, rightCodeNum, digits)
	end)
	local aptDivTime = measure(function()
		aptProduct:DivideRaw(rightAptInt)
	end)

	print(string.format(
		"%d digits | multiply CodeNum %.9f AptInt %.9f ratio %.3fx | divide CodeNum %.9f AptInt %.9f ratio %.3fx",
		digits,
		codeMulTime,
		aptMulTime,
		aptMulTime / codeMulTime,
		codeDivTime,
		aptDivTime,
		aptDivTime / codeDivTime
	))
end
