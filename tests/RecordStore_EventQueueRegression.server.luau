--!strict
-- Focused change-event and durable-queue interleaving regressions.
-- Mock-only: no live DataStore records are read or written.

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)

RecordStore.Mock.reset()
do
	local function make_wide(value: number)
		local wide = {}
		for index = 1, 1100 do
			wide[("key-%04d"):format(index)] = value
		end
		return { Wide = wide }
	end

	local record = RecordStore.Mock.new(
		"RecordStore_ChangeEventTruncationRegression",
		"global",
		"wide-change",
		{ schema_version = 1 }
	)
	local open_result, open_message = record:Open(make_wide(0))
	assert(open_result == "created" or open_result == "loaded", open_message)

	local events = {}
	local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(event)
		events[#events + 1] = event
		if event.Truncated then
			local old_value = event.OldValue :: { [string]: RecordStore.JsonValue }
			local new_value = event.NewValue :: { [string]: RecordStore.JsonValue }
			local old_wide = old_value["Wide"] :: { [string]: RecordStore.JsonValue }
			local new_wide = new_value["Wide"] :: { [string]: RecordStore.JsonValue }
			old_wide["key-0001"] = -1
			new_wide["key-0001"] = -1
		end
	end)
	assert(subscription ~= nil and subscribe_result == "success", subscribe_message)

	local update_result, update_message = record:Update(function(_data)
		return make_wide(1)
	end)
	assert(update_result == "success", update_message)
	task.wait()
	assert(#events == 1, ("overflow must collapse into one event, got %d"):format(#events))
	assert(events[1].Truncated, "change-event cap must report a truncated full-record snapshot")
	assert(#events[1].Path == 0, "truncated full-record event must use the root path")

	local current = record:Get() :: { [string]: RecordStore.JsonValue }
	local current_wide = current["Wide"] :: { [string]: RecordStore.JsonValue }
	assert(current_wide["key-0001"] == 1, "mutating truncated event snapshots changed canonical record data")
	subscription:Disconnect()
	assert(record:Close() == "closed", "truncation regression record did not close")
	local reopen_result, reopen_message = record:Open(make_wide(0))
	assert(reopen_result == "loaded", reopen_message)
	local persisted = record:Get() :: { [string]: RecordStore.JsonValue }
	local persisted_wide = persisted["Wide"] :: { [string]: RecordStore.JsonValue }
	assert(persisted_wide["key-0001"] == 1, "truncated event payload mutation changed persisted data")
	assert(record:Close() == "closed", "reopened truncation regression record did not close")
end

RecordStore.Mock.reset()
do
	local record = RecordStore.Mock.new(
		"RS_SubscriberIsolation",
		"global",
		"subscriber-isolation",
		{ schema_version = 1 }
	)
	local open_result, open_message = record:Open({ Value = 0 })
	assert(open_result == "created" or open_result == "loaded", open_message)

	local callback_count = 0
	local sibling_value: number? = nil
	local sibling_path: string? = nil
	local sibling_kind: string? = nil
	local function observer(event: RecordStore.ChangeEvent)
		callback_count += 1
		if callback_count == 1 then
			local new_value = event.NewValue :: { [string]: RecordStore.JsonValue }
			local nested = new_value["Nested"] :: { [string]: RecordStore.JsonValue }
			nested["Count"] = -1
			event.Path[1] = "tampered"
			event.Kind = "tampered"
		else
			local new_value = event.NewValue :: { [string]: RecordStore.JsonValue }
			local nested = new_value["Nested"] :: { [string]: RecordStore.JsonValue }
			sibling_value = nested["Count"] :: number
			sibling_path = event.Path[1]
			sibling_kind = event.Kind
		end
	end
	local first, first_result, first_message = record:SubscribeChanges(observer)
	local second, second_result, second_message = record:SubscribeChanges(observer)
	assert(first ~= nil and first_result == "success", first_message)
	assert(second ~= nil and second_result == "success", second_message)

	local update_result, update_message = record:Update(function(_data)
		return { Value = { Nested = { Count = 10 } } }
	end)
	assert(update_result == "success", update_message)
	task.wait()
	assert(callback_count == 2, "expected both subscribers to receive the event")
	assert(sibling_value == 10, "one subscriber's mutation leaked into another subscriber's payload")
	assert(sibling_path == "Value", "one subscriber's path mutation leaked into another subscriber's payload")
	assert(sibling_kind == "update", "one subscriber's event mutation leaked into another subscriber's payload")
	local canonical = record:Get() :: { [string]: RecordStore.JsonValue }
	local canonical_value = canonical["Value"] :: { [string]: RecordStore.JsonValue }
	local canonical_nested = canonical_value["Nested"] :: { [string]: RecordStore.JsonValue }
	assert(canonical_nested["Count"] == 10, "subscriber payload mutation changed canonical record data")
	first:Disconnect()
	second:Disconnect()
	assert(record:Close() == "closed", "subscriber-isolation regression record did not close")
end

RecordStore.Mock.reset()
do
	local record = RecordStore.Mock.new(
		"RecordStore_ChangeEventSparseDiffOrderRegression",
		"global",
		"sparse-diff-order",
		{ schema_version = 1 }
	)
	local initial_data = {
		Archive = {
			["item-0001"] = { Count = 1, Stats = { Power = 10, Defense = 5 } },
			["item-0002"] = { Count = 2, Stats = { Power = 20, Defense = 10 } },
		},
		Removed = { Nested = { Value = 9 } },
		Revision = 0,
		StableNaN = 0 / 0,
		Unchanged = { Nested = { Value = 42 } },
	}
	local open_result, open_message = record:Open(initial_data)
	assert(open_result == "created" or open_result == "loaded", open_message)

	local events: { RecordStore.ChangeEvent } = {}
	local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(event)
		events[#events + 1] = event
	end)
	assert(subscription ~= nil and subscribe_result == "success", subscribe_message)

	local update_result, update_message = record:Update(function(data)
		local current = data :: { [string]: RecordStore.JsonValue }
		local next_data = table.clone(current)
		local archive = table.clone(current["Archive"] :: { [string]: RecordStore.JsonValue })
		local target = table.clone(archive["item-0002"] :: { [string]: RecordStore.JsonValue })
		target["Count"] = (target["Count"] :: number) + 1
		archive["item-0002"] = target
		next_data["Archive"] = archive
		next_data["Removed"] = nil
		next_data["Added"] = { Nested = { Value = 29 } }
		next_data["Revision"] = (next_data["Revision"] :: number) + 1
		return next_data
	end)
	assert(update_result == "success", update_message)
	task.wait()

	local expected_paths = { "Added", "Archive.item-0002.Count", "Removed", "Revision" }
	assert(#events == #expected_paths, ("expected %d changed-leaf events, got %d"):format(#expected_paths, #events))
	for index, expected_path in ipairs(expected_paths) do
		assert(
			table.concat(events[index].Path, ".") == expected_path,
			("event %d path/order changed: expected %s, got %s"):format(
				index,
				expected_path,
				table.concat(events[index].Path, ".")
			)
		)
		assert(not events[index].Truncated, "small sparse update unexpectedly emitted a truncated event")
	end

	local added = events[1].NewValue :: { [string]: RecordStore.JsonValue }
	local added_nested = added["Nested"] :: { [string]: RecordStore.JsonValue }
	assert(added_nested["Value"] == 29, "added subtree payload changed")
	assert(events[2].OldValue == 2 and events[2].NewValue == 3, "changed scalar payloads changed")
	local removed = events[3].OldValue :: { [string]: RecordStore.JsonValue }
	local removed_nested = removed["Nested"] :: { [string]: RecordStore.JsonValue }
	assert(removed_nested["Value"] == 9 and events[3].NewValue == nil, "removed subtree payload changed")
	assert(events[4].OldValue == 0 and events[4].NewValue == 1, "revision payload changed")

	local canonical = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(math.isnan(canonical["StableNaN"] :: number), "unchanged NaN was not preserved")
	local unchanged = canonical["Unchanged"] :: { [string]: RecordStore.JsonValue }
	local unchanged_nested = unchanged["Nested"] :: { [string]: RecordStore.JsonValue }
	assert(unchanged_nested["Value"] == 42, "unchanged nested data was modified")
	subscription:Disconnect()
	assert(record:Close() == "closed", "sparse diff order regression record did not close")
end

RecordStore.Mock.reset()
do
	local record: RecordStore.Record? = nil
	local flood_started = false
	local update_failures = 0
	local truncated_events = 0
	record = RecordStore.Mock.new(
		"RecordStore_ChangeDispatchOverflowRegression",
		"global",
		"dispatch-overflow",
		{ schema_version = 1 }
	)
	local open_result, open_message = record:Open({ Value = 0 })
	assert(open_result == "created" or open_result == "loaded", open_message)
	local subscription, subscribe_result, subscribe_message = record:SubscribeChanges(function(event)
		if event.Truncated then
			truncated_events += 1
			local snapshot = event.NewValue :: { [string]: RecordStore.JsonValue }
			snapshot["Value"] = -1
			return
		end
		if flood_started or record == nil then
			return
		end
		flood_started = true
		for _ = 1, 4100 do
			local result = record:Update(function(data)
				local current = data :: { [string]: RecordStore.JsonValue }
				return { Value = (current["Value"] :: number) + 1 }
			end)
			if result ~= "success" then
				update_failures += 1
			end
		end
	end)
	assert(subscription ~= nil and subscribe_result == "success", subscribe_message)
	local update_result, update_message = record:Update(function(data)
		local current = data :: { [string]: RecordStore.JsonValue }
		return { Value = (current["Value"] :: number) + 1 }
	end)
	assert(update_result == "success", update_message)
	task.wait()
	assert(flood_started, "change observer did not trigger the dispatch-queue flood")
	assert(update_failures == 0, ("dispatch overflow flood rejected %d local updates"):format(update_failures))
	assert(truncated_events >= 1, "dispatch queue overflow did not emit a truncated snapshot")
	local current = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(current["Value"] == 4101, "mutating the dispatch-overflow snapshot changed canonical data")
	subscription:Disconnect()
	assert(record:Close() == "closed", "dispatch-overflow regression record did not close")
end

RecordStore.Mock.reset()
do
	local record: RecordStore.Record? = nil
	local update_result: string? = nil
	local nested_save_result: string? = nil
	record = RecordStore.Mock.new(
		"RecordStore_QueueMutationInterleavingRegression",
		"global",
		"queue-handler-update",
		{
			schema_version = 1,
			on_queue_message = function(message_type)
				if message_type ~= "mutate" or record == nil then
					return false, "unexpected queue message"
				end
				update_result = record:Update(function(data)
					local next_data = data :: { [string]: RecordStore.JsonValue }
					next_data["Processed"] = (next_data["Processed"] :: number) + 1
					return next_data
				end)
				nested_save_result = record:Save()
				return update_result == "success", "record update was rejected"
			end,
		}
	)
	local open_result, open_message = record:Open({ Processed = 0 })
	assert(open_result == "created" or open_result == "loaded", open_message)
	local enqueue_result, enqueue_message = record:EnqueueAsync("mutate", { value = 1 })
	assert(enqueue_result == "enqueued", enqueue_message)
	local process_result, process_message = record:ProcessQueueAsync(1)
	assert(process_result == "processed", process_message)
	assert(update_result == "success", "local mutation from a queue handler must remain supported")
	assert(nested_save_result == "busy", "durable save during queue processing must be rejected as busy")
	local data = record:Get() :: { [string]: RecordStore.JsonValue }
	assert(data["Processed"] == 1, "successful queue handler mutation was not retained")
	local save_result, save_message = record:Save()
	assert(save_result == "saved", save_message)
	assert(record:Close() == "closed", "queue-interleaving regression record did not close")
end


RecordStore.Mock.reset()

print("[PASS] Change-event truncation payload isolation and durable-queue handler interleaving.")
