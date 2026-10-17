--!nocheck
-- Tests in-flight read coalescing only: completed values are never cached.
-- Uses Lune task scheduling; this validates local concurrency, not Roblox DataStore latency.
local Shim = require("./RobloxShim")
local task = require("@lune/task")
local RecordStore = Shim.load_isolated("v2-read-coalescer")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })

local function wait_until(predicate, timeout_seconds, message)
	local deadline = os.clock() + timeout_seconds
	while not predicate() and os.clock() < deadline do
		task.wait(0.005)
	end
	assert(predicate(), message)
end

local fetch_calls = 0
local service = V2.ReadCoalescer.new(function(key)
	fetch_calls += 1
	task.wait(0.08)
	return { key = key, nested = { original = true } }, nil
end, {
	max_entries = 4,
	max_waiters_per_key = 4,
	max_total_waiters = 8,
	waiter_timeout_seconds = 0.5,
})

local results = {}
task.spawn(function()
	results.first = table.pack(service:GetAsync("same-key", "owner-A"))
end)
task.wait(0.01)
task.spawn(function()
	results.second = table.pack(service:GetAsync("same-key", "owner-A"))
end)
wait_until(function() return results.first ~= nil and results.second ~= nil end, 1, "singleflight callers did not finish")
assert(fetch_calls == 1, "overlapping reads were not coalesced into one fetch")
assert(results.first[3] == "fetch", "leader did not report fetch source")
assert(results.second[3] == "coalesced", "overlapping waiter did not report coalesced source")
assert(results.first[1].key == "same-key" and results.second[1].key == "same-key", "coalesced values differ")
results.first[1].nested.original = false
assert(results.second[1].nested.original == true, "coalesced callers share a mutable result table")

local fresh, fresh_error, fresh_source = service:GetAsync("same-key", "owner-A")
assert(fresh_error == nil and fresh_source == "fetch", "a completed read was served from a retained cache")
assert(fetch_calls == 2, "completed values were retained instead of fetching afresh")
assert(service:Stats().completed_cache_entries == 0 and service:Stats().entries == 0,
	"read coalescer retained completed/in-flight entries")

local timeout_fetch_calls = 0
local timeout_service = V2.ReadCoalescer.new(function(key)
	timeout_fetch_calls += 1
	task.wait(0.16)
	return { key = key }, nil
end, {
	max_entries = 2,
	max_waiters_per_key = 2,
	max_total_waiters = 4,
	waiter_timeout_seconds = 0.035,
})
local timeout_results = {}
task.spawn(function()
	timeout_results.leader = table.pack(timeout_service:GetAsync("slow-key", "owner-B"))
end)
task.wait(0.01)
task.spawn(function()
	timeout_results.waiter = table.pack(timeout_service:GetAsync("slow-key", "owner-B"))
end)
wait_until(function() return timeout_results.waiter ~= nil end, 0.12, "waiter did not respect its deadline")
assert(timeout_results.waiter[1] == nil and timeout_results.waiter[3] == "timeout",
	"waiter deadline did not return a typed timeout")
wait_until(function() return timeout_results.leader ~= nil end, 1, "leader fetch did not complete after waiter timeout")
assert(timeout_fetch_calls == 1, "waiter timeout started a duplicate fetch")
assert(timeout_service:Stats().waiters == 0 and timeout_service:Stats().timeouts == 1,
	"timed-out waiter remained registered")

local bounded_fetch_calls = 0
local bounded = V2.ReadCoalescer.new(function(key)
	bounded_fetch_calls += 1
	task.wait(0.12)
	return { key = key }, nil
end, {
	max_entries = 1,
	max_waiters_per_key = 1,
	max_total_waiters = 1,
	waiter_timeout_seconds = 0.4,
})
local bounded_results = {}
task.spawn(function()
	bounded_results.leader = table.pack(bounded:GetAsync("capacity-key", "owner-C"))
end)
task.wait(0.01)
task.spawn(function()
	bounded_results.waiter = table.pack(bounded:GetAsync("capacity-key", "owner-C"))
end)
task.wait(0.01)
local over_waiter, over_waiter_error, over_waiter_code = bounded:GetAsync("capacity-key", "owner-C")
assert(over_waiter == nil and over_waiter_code == "capacity",
	"excess per-key waiters were not bounded")
local over_key, over_key_error, over_key_code = bounded:GetAsync("other-key", "owner-C")
assert(over_key == nil and over_key_code == "capacity",
	"excess simultaneous in-flight keys were not bounded")
wait_until(function() return bounded_results.leader ~= nil and bounded_results.waiter ~= nil end,
	1, "bounded in-flight callers did not finish")
assert(bounded_fetch_calls == 1, "capacity rejection triggered an extra fetch")
assert(bounded:Stats().entries == 0 and bounded:Stats().waiters == 0,
	"bounded coalescer leaked in-flight state")

print("[PASS] Read coalescer singleflight, independent result clones, no post-completion cache, waiter deadlines and bounded state.")
Shim.close()
