--!nocheck
-- Verifies projection idempotency, pure UpdateAsync transforms, response-loss recovery,
-- and unique-key reservation outcomes with deterministic storage.
local Shim = require("./RobloxShim")
local RecordStore = Shim.load_isolated("projection-regression")
local MailboxV2 = require("../src/PlayerDataInitializer/RecordStoreMailboxV2")
local V2Module = require("../src/PlayerDataInitializer/RecordStoreV2")
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 64, "fixture exceeds maximum depth")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[clone(key, depth + 1)] = clone(child, depth + 1) end
	return result
end

local function new_store()
	local values = {}
	local store = { replay_next = false, fail_after_next = false, update_calls = 0, values = values }
	function store:GetAsync(key)
		return clone(values[key])
	end
	function store:UpdateAsync(key, transform)
		self.update_calls += 1
		local old = clone(values[key])
		local next_value
		if self.replay_next then
			self.replay_next = false
			local first = transform(clone(old))
			local second = transform(clone(old))
			assert(V2.canonical(first) == V2.canonical(second),
				"UpdateAsync transform returned different values when replayed against the same input")
			next_value = second
		else
			next_value = transform(old)
		end
		if next_value ~= nil then values[key] = clone(next_value) end
		if self.fail_after_next then
			self.fail_after_next = false
			error("injected commit-then-response-loss")
		end
		return clone(values[key])
	end
	function store:Seed(key, value)
		values[key] = clone(value)
	end
	return store
end

local store = new_store()
local projections = V2.Projections.new(store)
local registered, register_error = projections:Register("player_balance_v1", 1, function(current, event)
	local changed = table.clone(current)
	changed.coins = (changed.coins or 0) + event.delta
	return changed
end, { consistency = "eventual" })
assert(registered, tostring(register_error))
local changed_projection_revision = projections:Register("player_balance_v1", 1, function(current)
	return current
end, { consistency = "eventual" })
assert(changed_projection_revision == false,
	"projection implementation changed without incrementing its declared version")

store.replay_next = true
local first = projections:ApplyAsync("player_balance_v1", {
	event_id = "projection-event-1",
	entity_id = "player-1",
	source_revision = 1,
	delta = 5,
})
assert(first.code == "committed", "projection did not commit after transform replay: " .. tostring(first.message))
assert(first.row.value.coins == 5 and first.row.source_revision == 1,
	"projection committed an incorrect value or source revision")

local duplicate = projections:ApplyAsync("player_balance_v1", {
	event_id = "projection-event-1",
	entity_id = "player-1",
	source_revision = 1,
	delta = 5,
})
assert(duplicate.code == "duplicate", "projection did not deduplicate a repeated event")
assert(duplicate.row.value.coins == 5, "duplicate projection event applied its value twice")

local stale = projections:ApplyAsync("player_balance_v1", {
	event_id = "projection-event-stale",
	entity_id = "player-1",
	source_revision = 1,
	delta = 100,
})
assert(stale.code == "stale", "projection accepted a stale source revision")
assert(stale.row.value.coins == 5, "stale projection event changed the materialized value")

store.fail_after_next = true
local ambiguous = projections:ApplyAsync("player_balance_v1", {
	event_id = "projection-event-2",
	entity_id = "player-1",
	source_revision = 2,
	delta = 3,
})
assert(ambiguous.code == "committed" and ambiguous.reconciled == true,
	"projection did not reconcile commit-then-response-loss: " .. tostring(ambiguous.message))
assert(ambiguous.row.value.coins == 8 and ambiguous.row.source_revision == 2,
	"projection response-loss recovery returned the wrong durable state")

local reservation_store = new_store()
local reservations = V2.Projections.new(reservation_store)
reservation_store.replay_next = true
reservation_store.fail_after_next = true
local reserved = reservations:ReserveUnique("username", "Barcode", "player-1", "reserve-op-1")
assert(reserved.code == "committed" and reserved.reconciled == true,
	"unique reservation did not reconcile a committed write with a lost response")
local duplicate_reservation = reservations:ReserveUnique("username", "Barcode", "player-1", "reserve-op-2")
assert(duplicate_reservation.code == "duplicate", "same entity did not receive duplicate reservation outcome")
local conflict_reservation = reservations:ReserveUnique("username", "Barcode", "player-2", "reserve-op-3")
assert(conflict_reservation.code == "conflict", "unique reservation allowed a second entity to claim the same value")
local subject_bound_reservations = V2.Projections.new(reservation_store, {
	is_erased = function(_user_id) return false end,
})
local changed_subject_reservation = subject_bound_reservations:ReserveUnique(
	"username", "Barcode", "player-1", "reserve-op-4", { 987654321 }
)
assert(changed_subject_reservation.code == "conflict",
	"unique reservation allowed its subject association to change after creation")

local tuple_key_store = new_store()
local tuple_key_projections = V2.Projections.new(tuple_key_store)
local function identity_projector(current, event)
	local changed = table.clone(current)
	changed.value = event.event_id
	return changed
end
assert(tuple_key_projections:Register("a:b", 1, identity_projector))
assert(tuple_key_projections:Register("a", 1, identity_projector))
local tuple_left = tuple_key_projections:ApplyAsync("a:b", {
	event_id = "tuple-left", entity_id = "c", source_revision = 1,
})
local tuple_right = tuple_key_projections:ApplyAsync("a", {
	event_id = "tuple-right", entity_id = "b:c", source_revision = 1,
})
assert(tuple_left.code == "committed" and tuple_right.code == "committed",
	"projection tuple key encoding collided on delimiter-containing identities")

local protected_store = new_store()
local protected_projections = V2.Projections.new(protected_store)
assert(protected_projections:Register("subject_projection_v1", 1, function(current) return current end))
local missing_erasure_gate = protected_projections:ApplyAsync("subject_projection_v1", {
	event_id = "projection-erasure-gate",
	entity_id = "player-erased",
	source_revision = 1,
	subject_user_ids = { 987654321 },
})
assert(missing_erasure_gate.code == "unsupported",
	"subject-bound projection bypassed the required authoritative erasure adapter")
local missing_unique_erasure_gate = protected_projections:ReserveUnique(
	"subject-username", "ErasedName", "player-erased", "reserve-erased", { 987654321 }
)
assert(missing_unique_erasure_gate.code == "unsupported",
	"subject-bound unique reservation bypassed the required authoritative erasure adapter")
local erased_projections = V2.Projections.new(protected_store, {
	is_erased = function(_user_id) return true end,
})
assert(erased_projections:Register("subject_projection_v1", 1, function(current) return current end))
local erased_event = erased_projections:ApplyAsync("subject_projection_v1", {
	event_id = "projection-erased-event",
	entity_id = "player-erased",
	source_revision = 1,
	subject_user_ids = { 987654321 },
})
assert(erased_event.code == "erased", "projection recreated data for a durably erased subject")
local subject_read_store = new_store()
local live_subject_projection = V2.Projections.new(subject_read_store, {
	is_erased = function(_user_id) return false end,
})
assert(live_subject_projection:Register("subject_read_v1", 1, function(current, event)
	local changed = table.clone(current)
	changed.subject = event.subject_user_ids[1]
	return changed
end))
local subject_row = live_subject_projection:ApplyAsync("subject_read_v1", {
	event_id = "subject-read-seed",
	entity_id = "subject-entity",
	source_revision = 1,
	subject_user_ids = { 987654321 },
})
assert(subject_row.code == "committed", "could not seed subject-bound projection row")
local erased_subject_projection = V2.Projections.new(subject_read_store, {
	is_erased = function(_user_id) return true end,
})
assert(erased_subject_projection:Register("subject_read_v1", 1, function(current, event)
	local changed = table.clone(current)
	changed.subject = event.subject_user_ids[1]
	return changed
end))
local erased_read = erased_subject_projection:GetAsync("subject_read_v1", "subject-entity")
assert(erased_read.code == "erased", "projection read returned data for a subject marked erased")

local mutable_subjects = { 987654321 }
local snapshot_store = new_store()
local snapshot_reservations = V2.Projections.new(snapshot_store, {
	is_erased = function(user_id)
		assert(user_id == 987654321, "erasure verifier received a changed subject ID")
		mutable_subjects[1] = 123
		return false
	end,
})
local snapshot_reservation = snapshot_reservations:ReserveUnique(
	"subject-username", "SnapshotName", "player-snapshot", "reserve-snapshot", mutable_subjects
)
assert(snapshot_reservation.code == "committed", "subject-bound reservation failed after erasure verification")
assert(snapshot_reservation.reservation.subject_user_ids[1] == 987654321,
	"subject list changed between erasure verification and reservation persistence")

local rebuild_store = new_store()
local rebuild_projection = V2.Projections.new(rebuild_store)
assert(rebuild_projection:Register("rebuild_projection_v1", 1, function(current) return current end))
local caller_cursor = { page = 1 }
local empty_rebuild = rebuild_projection:RebuildAsync("rebuild_projection_v1", function(received_cursor)
	received_cursor.page = 99
	return {}, nil, true
end, caller_cursor, 1)
assert(empty_rebuild.code == "committed" and caller_cursor.page == 1,
	"projection rebuild exposed its caller-owned cursor to fetch_page")
local sparse_rebuild = rebuild_projection:RebuildAsync("rebuild_projection_v1", function()
	return { [1] = { event_id = "rebuild-1", entity_id = "entity-1", source_revision = 1 }, [3] = {} }, nil, true
end, nil, 1)
assert(sparse_rebuild.code == "invalid", "projection rebuild accepted a sparse page and could skip events")

local corrupt_store = new_store()
local corrupt_projection = V2.Projections.new(corrupt_store)
assert(corrupt_projection:Register("player_balance_v1", 1, function(current) return current end))
local seed_corrupt_row = corrupt_projection:ApplyAsync("player_balance_v1", {
	event_id = "projection-seed-corrupt-row",
	entity_id = "player-bad",
	source_revision = 1,
})
assert(seed_corrupt_row.code == "committed", "could not seed the projection row for corruption testing")
local corrupt_key = nil
for key, row in pairs(corrupt_store.values) do
	if type(row) == "table" and row.entity_id == "player-bad" then corrupt_key = key; break end
end
assert(corrupt_key ~= nil, "projection seed row was not discoverable in the fake store")
corrupt_store.values[corrupt_key].source_revision = "invalid"
local corrupt = corrupt_projection:ApplyAsync("player_balance_v1", {
	event_id = "projection-corrupt-row",
	entity_id = "player-bad",
	source_revision = 2,
})
assert(corrupt.code == "corrupt", "projection did not fail closed on a malformed durable row")
local corrupt_read = corrupt_projection:GetAsync("player_balance_v1", "player-bad")
assert(corrupt_read.code == "corrupt", "projection read returned a malformed durable row as success")

print("[PASS] Projection transform purity, event idempotency, stale revisions, ambiguous writes and unique-key reservations.")
Shim.close()
