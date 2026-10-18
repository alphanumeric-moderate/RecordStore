--!nocheck
-- Deterministic regression checks for RecordStoreV2Simulator primitives.
-- This validates the simulator contract, not the production mailbox protocol.
local Simulator = require("../src/PlayerDataInitializer/RecordStoreV2Simulator")

local simulator = Simulator.new({ now_ms = 1000 })
local store = simulator:Store("profiles")

local initial = store:UpdateAsync("player-1", function()
	return { balance = 5 }
end)
assert(initial.balance == 5, "initial UpdateAsync did not persist its transform")

-- UpdateAsync transforms must be safe to replay and must not accumulate stale state.
local transform_calls = 0
simulator:SetTransformReplayCount(2)
local replayed = store:UpdateAsync("player-1", function(current)
	transform_calls += 1
	return { balance = current.balance + 10 }
end)
assert(transform_calls == 3, "configured transform replay count was not honored")
assert(replayed.balance == 15, "transform replay incorrectly applied the mutation more than once")
simulator:SetTransformReplayCount(0)

-- Returning nil cancels the write and preserves the durable value.
local cancelled = store:UpdateAsync("player-1", function()
	return nil
end)
assert(cancelled.balance == 15, "nil transform result did not cancel the write")

-- Pre-commit errors leave the value unchanged.
simulator:ScheduleFault("update", "profiles", "player-1", "fail_before_commit")
local before_ok = pcall(function()
	store:UpdateAsync("player-1", function()
		return { balance = 99 }
	end)
end)
assert(not before_ok, "pre-commit failure did not surface an error")
assert(store:GetAsync("player-1").balance == 15, "pre-commit failure changed stored data")

-- Commit-then-error models an ambiguous response: the write persists despite the error.
simulator:ScheduleFault("update", "profiles", "player-1", "commit_then_error")
local after_ok = pcall(function()
	store:UpdateAsync("player-1", function(current)
		return { balance = current.balance + 5 }
	end)
end)
assert(not after_ok, "commit-then-error fault did not surface an error")
assert(store:GetAsync("player-1").balance == 20, "commit-then-error did not preserve the committed value")

-- Reads return copies so callers cannot mutate storage through a retrieved snapshot.
local read = store:GetAsync("player-1")
read.balance = -1
assert(store:GetAsync("player-1").balance == 20, "GetAsync leaked a mutable reference into storage")

-- Failed reads and deletes must be observable without corrupting stored state.
simulator:ScheduleFault("get", "profiles", "player-1", "fail_before_commit")
local read_ok = pcall(function()
	store:GetAsync("player-1")
end)
assert(not read_ok, "injected GetAsync failure did not surface an error")
simulator:ScheduleFault("remove", "profiles", "player-1", "fail_before_commit")
local remove_before_ok = pcall(function()
	store:RemoveAsync("player-1")
end)
assert(not remove_before_ok, "pre-commit RemoveAsync failure did not surface an error")
assert(store:GetAsync("player-1").balance == 20, "pre-commit delete failure removed the value")

-- A lost RemoveAsync response means deletion occurred even though the call failed.
simulator:ScheduleFault("remove", "profiles", "player-1", "commit_then_error")
local remove_after_ok = pcall(function()
	store:RemoveAsync("player-1")
end)
assert(not remove_after_ok, "commit-then-error RemoveAsync fault did not surface an error")
assert(store:GetAsync("player-1") == nil, "commit-then-error RemoveAsync did not delete the value")

-- Budget and advisory-hint controls are deterministic, bounded test primitives.
simulator:SetBudget("write", 2)
assert(simulator:ConsumeBudget("write", 1), "first budget unit was rejected")
assert(simulator:ConsumeBudget("write", 1), "second budget unit was rejected")
assert(not simulator:ConsumeBudget("write", 1), "exhausted budget was not rejected")

local hints = Simulator.new({ now_ms = 5000 })
hints:SetHintPolicy({ drop_first = 1, duplicate_count = 1, delay_ms = 50, reverse = true })
assert(hints:PublishHint("shard:0", { owner = "first" }), "first hint was not queued")
assert(hints:PublishHint("shard:0", { owner = "second" }), "second hint was not queued")
local received = {}
local function receive(payload)
	table.insert(received, payload.owner)
end
hints:Advance(49)
assert(hints:DeliverHints(receive) == 0 and #received == 0, "delayed hints arrived before their deadline")
hints:Advance(1)
assert(hints:DeliverHints(receive) == 1, "drop/duplicate policy reported an incorrect delivery count")
assert(#received == 2 and received[1] == "first" and received[2] == "first",
	"reverse/drop/duplicate policy produced an unexpected delivery sequence")

-- Crash discards server-local state; restart must begin from explicitly reloaded state.
local running = hints:RestartServer("job-1", { pending_local = "not durable" })
assert(running.local_state.pending_local == "not durable", "server state did not initialize")
hints:CrashServer("job-1")
assert(hints.servers["job-1"] == nil, "crash retained server-local state")
local restarted = hints:RestartServer("job-1", { loaded_from_store = true })
assert(restarted.local_state.pending_local == nil and restarted.local_state.loaded_from_store == true,
	"restart leaked pre-crash state instead of using reloaded state")

-- Fault scripts are ordered contracts: a mismatched operation must fail before consuming the script.
local scripted = Simulator.new()
local scripted_store = scripted:Store("script-store")
scripted:SetFaultScript({
	{
		operation = "update",
		store_name = "script-store",
		key = "script-key",
		mode = "commit_then_error",
		message = "scripted ambiguous commit",
	},
})
local unexpected_read_ok = pcall(function()
	scripted_store:GetAsync("script-key")
end)
assert(not unexpected_read_ok, "fault script silently ignored an unexpected storage operation")
assert(scripted:Snapshot().fault_script_cursor == 1, "fault script mismatch consumed the expected entry")
local scripted_update_ok = pcall(function()
	scripted_store:UpdateAsync("script-key", function()
		return { committed = true }
	end)
end)
assert(not scripted_update_ok, "scripted commit-then-error fault was not applied")
assert(scripted_store:GetAsync("script-key").committed == true, "scripted ambiguous update did not commit before surfacing the error")
local scripted_snapshot = scripted:Snapshot()
assert(scripted_snapshot.fault_script_cursor == 2 and scripted_snapshot.next_event == #scripted:Trace() + 1,
	"simulator snapshot omitted fault-script progress or trace sequence")
scripted_snapshot.fault_script[1].mode = "fail_before_commit"
scripted_snapshot.hint_policy.reverse = true
assert(scripted:Snapshot().fault_script[1].mode == "commit_then_error", "snapshot fault script shares references with live simulator")
assert(scripted:Snapshot().hint_policy.reverse == false, "snapshot hint policy shares references with live simulator")

-- Event sequence numbers, traces, and snapshots are monotonic and isolated copies.
store:UpdateAsync("snapshot-key", function()
	return { nested = { value = 1 } }
end)
local snapshot = simulator:Snapshot()
snapshot.stores.profiles["snapshot-key"].nested.value = 99
assert(store:GetAsync("snapshot-key").nested.value == 1, "snapshot leaked mutable references into simulator storage")
local trace = simulator:Trace()
trace[1].kind = "corrupted"
assert(simulator:Trace()[1].kind ~= "corrupted", "Trace returned mutable references into simulator events")

print("[PASS] RecordStoreV2Simulator storage faults, transform replay, budgets, advisory hints, and restart primitives.")
