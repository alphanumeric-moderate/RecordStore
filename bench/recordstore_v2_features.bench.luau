--!nocheck
-- Successful-path benchmark of opt-in v2 services only; no injected failures or safety scenarios.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local Shim = require("./RobloxShim")
local RecordStore = Shim.load()
local MailboxV2 = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreMailboxV2.luau"), { debugName = "RecordStoreMailboxV2", environment = Shim.environment })()
local V2Module = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreV2.luau"), { debugName = "RecordStoreV2", environment = Shim.environment })()
local Simulator = luau.load(fs.readFile("src/PlayerDataInitializer/RecordStoreV2Simulator.luau"), { debugName = "RecordStoreV2Simulator", environment = Shim.environment })()
local V2 = V2Module.new(RecordStore, MailboxV2, { allow_unattested_activation = true })

local function expect(result, ...)
	for _, wanted in ipairs({ ... }) do if result.code == wanted then return end end
	error("unexpected result: " .. tostring(result.code) .. " / " .. tostring(result.message))
end

local function run_transactions_and_workflows()
	RecordStore.Mock.reset()
	local source = RecordStore.Mock.new("V2_FeatureBench", "global", "source", { schema_version = 1 })
	local target = RecordStore.Mock.new("V2_FeatureBench", "global", "target", { schema_version = 1 })
	local source_code = source:Open({ Balance = 100000, Coins = 0, __recordstore_v2_application_schema_version = 0 })
	local target_code = target:Open({ Balance = 0, Coins = 0, __recordstore_v2_application_schema_version = 0 })
	assert(source_code == "created" or source_code == "loaded")
	assert(target_code == "created" or target_code == "loaded")

	local messages = {}
	for index = 1, 8 do
		messages[index] = { message_id = "event-" .. index, message_type = "credit", payload_version = 1, payload = { coins = index } }
	end
	expect(V2.Inbox.ApplyBatch(source, "bench-inbox-batch", messages, function(data, payload)
		local changed = table.clone(data)
		changed.Coins += payload.coins
		return changed
	end), "committed")
	expect(V2.Inbox.ApplyBatch(source, "bench-inbox-batch", messages, function(data, payload)
		local changed = table.clone(data)
		changed.Coins += payload.coins
		return changed
	end), "duplicate")

	expect(V2.Transactions.Run(source, "bench-transaction", { kind = "increment", amount = 3 }, function(data, request)
		local changed = table.clone(data)
		changed.Coins += request.amount
		return changed
	end), "committed")
	expect(V2.Transactions.CommitWithOutbox(source, "bench-outbox", { kind = "queue", amount = 1 }, function(data)
		return table.clone(data)
	end, {
		{
			EventId = "bench-outbox-event",
			DestinationStoreName = "V2_FeatureBench",
			DestinationScope = "global",
			DestinationProfileKey = "target",
			MessageType = "bench",
			Data = { amount = 1 },
		},
	}), "committed")
	local destination_store = MailboxV2.MockStore()
	local destination = MailboxV2.new(destination_store, {
		store_name = "V2_FeatureBench",
		scope = "global",
		profile_key = "target",
	}, {
		allow_unattested_activation = true,
		guid = function() return "bench-destination-guid" end,
		encode = function(value) return serde.encode("json", value) end,
	})
	local dispatch = V2.Outbox.DispatchBatches(source, function(event)
		local accepted = destination:EnqueueAsync(event.MessageType, event.Data, {
			idempotency_key = event.EventId,
		})
		return accepted.code == "accepted" or accepted.code == "duplicate", accepted.message_id
	end, 8, 4)
	expect(dispatch, "committed")

	local bridge_mailbox = MailboxV2.new(MailboxV2.MockStore(), {
		store_name = "V2_FeatureBench",
		scope = "global",
		profile_key = "target",
	}, {
		active_record = target,
		allow_unattested_activation = true,
		encode = function(value) return serde.encode("json", value) end,
	})
	local bind_code, bind_message = target:BindMailboxV2Async(bridge_mailbox)
	assert(bind_code == "success", tostring(bind_code) .. " " .. tostring(bind_message))
	local bridge_code = target:EnqueueAsync("bench-bridge", { amount = 2 }, {
		idempotency_key = "bench-bridge-idempotency",
	})
	assert(bridge_code == "enqueued")
	assert(target:EnqueueAsync("bench-bridge", { amount = 2 }, {
		idempotency_key = "bench-bridge-idempotency",
	}) == "duplicate")

	local migrations = V2.Migrations.new()
	assert(migrations:Register("V2_FeatureBench", 0, 1, "bench-migration-0-1", "rev1", function(data)
		local changed = table.clone(data)
		changed.MigrationMarker = true
		return changed
	end, function(data) return type(data.MigrationMarker) == "boolean" end))
	assert(migrations:Preview(source, "V2_FeatureBench", 1).preview_only)
	expect(migrations:MigrateAsync(source, "V2_FeatureBench", 1), "committed")
	assert(V2.ProfileDoctor.Inspect(source).code == "success")
	local preview = V2.ProfileDoctor.PreviewRepair(source, {
		id = "bench-repair", revision = "rev1",
		preview = function(data) local changed = table.clone(data); changed.RepairPreview = true; return changed end,
		validate = function(data) return type(data.RepairPreview) == "boolean" end,
	})
	assert(preview.code == "success" and preview.preview_only)

	local receipt = V2.ReceiptProcessor.new({
		products = { [123] = { revision = "catalog-1", grant = function(data)
			local changed = table.clone(data)
			changed.Coins += 50
			return changed
		end } },
		get_record = function() return source end,
		purchase_granted = "PurchaseGranted",
		not_processed_yet = "NotProcessedYet",
	})
	assert(receipt:CreateHandler()({ PurchaseId = "bench-purchase", PlayerId = 1, ProductId = 123 }) == "PurchaseGranted")

	local saga_store = MailboxV2.MockStore()
	local transfers = V2.Sagas.new(saga_store)
	expect(transfers:TransferAsync("bench-transfer", source, target, 25, { sender_id = "source", recipient_id = "target" }), "settled")
	assert(V2.ProfileDoctor.Inspect(target).code == "success")
	source:Close()
	target:Close()
	RecordStore.Mock.reset()
end

local function run_governor_trace_projection()
	local now = 1000
	local governor = V2.RuntimeGovernor.new({ now_ms = function() return now end, advance_ms = function(ms) now += ms end })
	for index = 1, 256 do
		local lane = if index % 11 == 0 then "high" elseif index % 4 == 0 then "background" else "normal"
		assert(governor:Enqueue({ id = "task-" .. index, owner_id = "owner-" .. (index % 29), lane = lane, cost = 1, deadline_ms = now + 30000 + index }).code == "accepted")
	end
	local taken = 0
	for _ = 1, 256 do if governor:TakeNext() then taken += 1 end end
	assert(taken == 256)

	local tracer = V2.Tracing.new({ max_events = 512, success_sample_every = 1 })
	for index = 1, 256 do tracer:Emit({ operation_id = "op-" .. (index % 16), correlation_id = "corr-" .. (index % 7), component = "bench", operation = "projection", result = if index % 97 == 0 then "unknown" else "success", duration_ms = index % 81, revision = index }) end
	assert(#tracer:GetOperationTrace("op-1").events > 0)

	local store = MailboxV2.MockStore()
	local projections = V2.Projections.new(store)
	assert(projections:Register("membership", 1, function(current, event)
		local changed = table.clone(current)
		changed.group_id = event.group_id
		return changed
	end))
	for index = 1, 192 do
		local result = projections:ApplyAsync("membership", { event_id = "membership-" .. index, entity_id = "member-" .. (index % 48), source_revision = math.floor((index - 1) / 48) + 1, group_id = "guild-" .. (index % 13) })
		assert(result.code == "committed" or result.code == "stale")
	end
	assert(projections:GetAsync("membership", "member-1").code == "success")
end

local function run_erasure_compaction_and_simulator_construction()
	local store = MailboxV2.MockStore()
	local deleted = {}
	local erasure = V2.Erasure.new(store, {
		{
			name = "profile-data",
			templates = { { name = "PlayerRecords", scope = "global", key = "user-{user_id}" } },
			templates_verified = true,
			inventory_verified = true,
			history_inventory_verified = true,
			inventory = function(user_id)
				return { {
					store_name = "PlayerRecords",
					scope = "global",
					key = "user-" .. tostring(user_id),
					exists = true,
					generation = 7,
				} }
			end,
			fence_user = function() return true end,
			dependencies_clear = function() return true end,
			redact_or_delete_if_generation = function(item, user_id, erasure_id)
				deleted[user_id .. ":" .. item.key] = erasure_id
				return "deleted"
			end,
			clear_history_if_generation = function() return true end,
		},
	}, { verify_templates = function() return true end })
	expect(erasure:PlanAsync(13579, "bench-erasure"), "success")
	expect(erasure:ExecuteAsync(13579, "bench-erasure", 8), "committed")

	local rows = { "a", "b", "c" }
	local compactor = V2.Maintenance.NewCompactor({
		next_page = function(cursor, limit)
			local offset = cursor or 0
			local result = {}
			for index = offset + 1, math.min(#rows, offset + limit) do table.insert(result, { id = rows[index], generation = 1 }) end
			local next_cursor = if offset + #result >= #rows then nil else offset + #result
			return result, next_cursor, next_cursor == nil
		end,
		inspect = function(item) return { eligible = true, dependencies_clear = true, generation = item.generation } end,
		delete_if_generation = function(item, generation) assert(generation == 1); return "deleted" end,
		persist_progress = function() return true end,
	})
	expect(compactor:RunStep(8, 100), "completed")

	-- Compile and construct only; the simulator's fault APIs are not invoked in the feature phase.
	local simulator = Simulator.new()
	assert(type(simulator.Store("syntax-check").UpdateAsync) == "function")
end

for _ = 1, 2 do
	run_transactions_and_workflows()
	run_governor_trace_projection()
	run_erasure_compaction_and_simulator_construction()
end

print("[PASS] RecordStoreV2 successful-path feature benchmark.")
Shim.close()
