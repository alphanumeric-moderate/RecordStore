--!strict
-- Focused change-event and durable-queue interleaving regressions.
-- Mock-only: no live DataStore records are read or written.

local ServerScriptService = game:GetService("ServerScriptService")
local RecordStore = require(ServerScriptService.RecordStore)
local MailboxV2 = RecordStore.MailboxV2
local serde = require("@lune/serde")

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


RecordStore.Mock.reset()
do
	local record: RecordStore.Record? = nil
	local handler_started = false
	local release_handler = false
	local handler_finished = false
	local process_finished = false
	local handler_update_result: RecordStore.ResultCode? = nil
	local nested_save_result: RecordStore.ResultCode? = nil
	local interleaved_update_result: RecordStore.ResultCode? = nil
	local process_result: RecordStore.ResultCode? = nil
	local process_message: string? = nil

	record = RecordStore.Mock.new(
		"RecordStore_V2QueueMutationInterleavingRegression",
		"global",
		"v2-queue-handler-update",
		{
			schema_version = 1,
			durable_queue_enabled = true,
			queue_store_name = "RecordStore_V2QueueMutationInterleavingQueue",
			autosave_interval = 1000,
			lease_duration = 180,
			lease_renewal = 60,
			on_queue_message_async = function(message_type)
				if message_type ~= "mutate" or record == nil then
					return false, "unexpected V2 queue message"
				end
				local active_record = record
				handler_update_result = active_record:Update(function(data)
					local next_data = data :: { [string]: RecordStore.JsonValue }
					next_data["Processed"] = (next_data["Processed"] :: number) + 1
					return next_data
				end)
				nested_save_result = active_record:Save()
				handler_started = true
				while not release_handler do
					task.wait()
				end
				handler_finished = true
				return handler_update_result == "success", "V2 handler mutation was rejected"
			end,
		}
	)
	local active_record = record
	local open_result, open_message = active_record:Open({ Processed = 0, Interleaved = 0 })
	assert(open_result == "created" or open_result == "loaded", open_message)

	local adapter, adapter_result, adapter_message = active_record:CreateMailboxStoreAdapter()
	assert(adapter_result == "success" and type(adapter) == "table", adapter_message)
	local mailbox = MailboxV2.new(adapter, active_record:GetMailboxOwner(), {
		active_record = active_record,
		encode = function(value) return serde.encode("json", value) end,
		activation_guard = function() return true end,
		strict_ordering_enabled = true,
		lease_ms = 10000,
		lease_renewal_horizon_ms = 2000,
	})
	local scheduler_enabled, scheduler_message = RecordStore.set_scheduler_enabled(true)
	assert(scheduler_enabled, scheduler_message)
	local bind_result, bind_message = active_record:BindMailboxV2Async(mailbox)
	assert(bind_result == "success", bind_message)
	local enqueue_result, enqueue_message = active_record:EnqueueAsync("mutate", { value = 1 }, {
		idempotency_key = "v2-queue-interleave",
		ordering_key = "v2-profile",
		priority = "high",
	})
	assert(enqueue_result == "enqueued", enqueue_message)

	task.spawn(function()
		process_result, process_message = active_record:ProcessQueueAsync(1)
		process_finished = true
	end)
	for _ = 1, 100 do
		if handler_started then
			break
		end
		task.wait()
	end
	assert(handler_started, "V2 handler did not reach its yield point")
	assert(handler_update_result == "success", "V2 handler's synchronous Record update was rejected")
	assert(nested_save_result == "busy", "Save during V2 queue processing was not rejected as busy")

	interleaved_update_result = active_record:Update(function(data)
		local next_data = data :: { [string]: RecordStore.JsonValue }
		next_data["Interleaved"] = (next_data["Interleaved"] :: number) + 1
		return next_data
	end)
	assert(interleaved_update_result == "success", "concurrent local update was rejected while the V2 handler yielded")
	release_handler = true
	for _ = 1, 100 do
		if process_finished then
			break
		end
		task.wait()
	end
	assert(process_finished, "V2 queue processing did not resume after the handler was released")
	assert(handler_finished, "V2 handler did not finish after its yield")
	assert(process_result == "processed", process_message)
	local data = active_record:Get() :: { [string]: RecordStore.JsonValue }
	assert(data["Processed"] == 1 and data["Interleaved"] == 1, "V2 interleaved mutations were not retained")
	local save_result, save_message = active_record:Save()
	assert(save_result == "saved", save_message)
	local scheduler_disabled, disable_message = RecordStore.set_scheduler_enabled(false)
	assert(scheduler_disabled, disable_message)
	assert(active_record:Close() == "closed", "V2 queue interleaving record did not close")
end

RecordStore.Mock.reset()

print("[PASS] Change-event truncation payload isolation and durable-queue handler interleaving.")
