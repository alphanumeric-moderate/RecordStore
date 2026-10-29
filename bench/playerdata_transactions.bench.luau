--!nocheck
-- CodSpeed CPU-simulation benchmark for the opt-in PlayerDataCore transaction wrapper.
local create_harness = require("./playerdata_set_harness")

local ITERATIONS = 1000
local harness = create_harness(true, nil, { TransactionalOperationsEnabled = true })
local controller = harness.controller
local player = harness.player
local record_options = harness.get_record_options()

assert(record_options.transactional_operations_enabled == true,
	"PlayerData transaction benchmark requires the opt-in transaction surface")

local function increment_kills(current)
	if type(current) ~= "table" then
		error("transaction benchmark received invalid PlayerData")
	end
	local data = table.clone(current)
	data.kills = (data.kills :: number) + 1
	return data, { kills = data.kills }
end

for index = 1, ITERATIONS do
	local operation_id = "playerdata-bench-increment:" .. tostring(index)
	local request = { kind = "bench-increment-kills", amount = 1, sequence = index }
	local result, status, message = controller.Transact(player, operation_id, request, increment_kills)
	if status ~= "committed" or type(result) ~= "table" then
		error(message or ("transaction benchmark operation %d failed: %s"):format(index, tostring(status)))
	end
end

local status, status_error = controller.GetStatus(player)
assert(status ~= nil, status_error)
assert(status.pending_change_count == 0, "transaction benchmark created pending duplicate mutations")
assert(controller:Shutdown(), "PlayerData transaction benchmark shutdown failed")

print(("[PlayerData transaction] completed %d opt-in transactions"):format(ITERATIONS))
