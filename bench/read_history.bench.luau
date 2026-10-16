--!nocheck
-- Benchmark: read-only access paths (read_async, list_versions_async, get_version_async)
-- over a record with a long version history.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()

local STORE = "Bench_History"
local SCOPE = "global"
local KEY = "history-player"
local VERSIONS = 60
local READS = 30

RecordStore.Mock.reset()
local record = RecordStore.Mock.new(STORE, SCOPE, KEY, { schema_version = 1 })
assert(record:Open({ Coins = 0, Log = {} }) == "created")
for i = 1, VERSIONS do
	assert(record:Update(function(data)
		local next_data = table.clone(data)
		next_data.Coins = i
		next_data.Log = table.clone(data.Log)
		table.insert(next_data.Log, "event-" .. i)
		return next_data
	end) == "success")
	assert(record:Save() == "saved")
end
assert(record:Close() == "closed")

for _ = 1, READS do
	local snapshot, result, message = RecordStore.Mock.read_async(STORE, SCOPE, KEY)
	assert(result == "success", message)
	assert(snapshot.Data.Coins == VERSIONS, "read_async returned stale data")
end

local entries, list_result, list_message = RecordStore.Mock.list_versions_async(STORE, SCOPE, KEY, nil, nil, nil, 100)
assert(list_result == "success", list_message)
assert(#entries > VERSIONS, "expected the full version history")
for i = 1, math.min(#entries, READS) do
	local snapshot, result, message = RecordStore.Mock.get_version_async(STORE, SCOPE, KEY, entries[i].Version)
	assert(snapshot ~= nil or result ~= "success", message)
end
RecordStore.Mock.reset()
Shim.close()
