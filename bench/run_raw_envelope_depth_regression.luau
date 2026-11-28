--!strict

type JsonValue = boolean | number | string | buffer | { JsonValue } | { [string]: JsonValue }

type QuarantineFenceStatus = {
	Exists: boolean,
	Quarantined: boolean,
	Phase: string?,
	QuarantineId: string?,
	StoreName: string?,
	Scope: string?,
	ProfileKey: string?,
	SourceGeneration: number?,
	SourceRevision: number?,
	OperatorId: string?,
	Reason: string?,
	CreatedAt: number?,
	UpdatedAt: number?,
	ResolutionId: string?,
	ResolutionOperatorId: string?,
	ResolutionReason: string?,
	ResolutionAt: number?,
	Version: string?,
	CurrentGeneration: number?,
	CurrentRevision: number?,
	CurrentWriteId: string?,
}

type OutboxEventSpec = {
	target_store: string,
	target_scope: string,
	target_key: string,
	type: string,
	payload_version: number,
	data: JsonValue,
	target_user_id: number?,
	correlation_id: string?,
	causation_id: string?,
}

type OutboxEvent = {
	EventId: string,
	EventType: string,
	PayloadVersion: number,
	Payload: JsonValue,
	DestinationStoreName: string,
	DestinationScope: string,
	DestinationProfileKey: string,
	DestinationUserId: number?,
	CorrelationId: string?,
	CausationId: string?,
	CreatedAt: number,
	Attempts: number,
	State: "pending" | "delivered" | "unknown" | "blocked",
	LastError: string?,
	DeliveredAt: number?,
	DestinationReceiptId: string?,
}

type ProfileRecord = {
	Open: (self: ProfileRecord, default_data: JsonValue?, recreate: boolean?) -> (string, string?),
	GetGeneration: (self: ProfileRecord) -> number,
	GetRevision: (self: ProfileRecord) -> number,
	CommitWithOutboxAsync: (
		self: ProfileRecord,
		commit_key: string,
		command_type: string,
		command_payload: JsonValue,
		outbox_events: { OutboxEventSpec },
		reducer: (JsonValue?, JsonValue?) -> (JsonValue?, JsonValue?),
		options: { request: JsonValue?, receipt_retention_seconds: number? }?
	) -> (JsonValue?, string, string?),
	DispatchOutboxAsync: (
		self: ProfileRecord,
		dispatcher: (OutboxEvent) -> (boolean, string?),
		max_events: number?
	) -> (number, string, string?),
	PruneOutboxAsync: (
		self: ProfileRecord,
		delivered_before_unix: number,
		max_events: number?
	) -> (number, string, string?),
}

type MockApi = {
	new: (
		name: string,
		scope: string,
		key: string,
		options: { schema_version: number, transactional_operations_enabled: boolean? }
	) -> unknown,
	set_test_clock: (clock: (() -> number)?) -> (),
	reset: () -> (),
	quarantine_profile_writes_async: (
		name: string,
		scope: string,
		key: string,
		quarantine_id: string,
		operator_id: string,
		reason: string,
		expected_generation: number,
		expected_revision: number,
		operation_deadline: number?
	) -> (QuarantineFenceStatus?, string, string?),
	mark_quarantine_release_pending_async: (
		name: string,
		scope: string,
		key: string,
		quarantine_id: string,
		resolution_id: string,
		operator_id: string,
		reason: string,
		expected_revision: number?,
		operation_deadline: number?
	) -> (QuarantineFenceStatus?, string, string?),
	release_quarantine_fence_async: (
		name: string,
		scope: string,
		key: string,
		quarantine_id: string,
		resolution_id: string,
		operation_deadline: number?
	) -> (QuarantineFenceStatus?, string, string?),
	get_record_raw: (name: string, scope: string, key: string) -> unknown,
}

local function expect(condition: boolean, message: string)
	if not condition then error(message, 2) end
end

local function checked_table(value: unknown, label: string): { [string]: unknown }
	expect(type(value) == "table", label .. " must be a table")
	return value :: { [string]: unknown }
end

local function checked_function(value: unknown, label: string)
	expect(type(value) == "function", label .. " must be a function")
end

local shim = checked_table(require("./RobloxShim"), "RobloxShim")
local load_value = shim.load
local close_value = shim.close
checked_function(load_value, "RobloxShim.load")
checked_function(close_value, "RobloxShim.close")
local load_store = load_value :: () -> unknown
local close_shim = close_value :: () -> ()
local store = checked_table(load_store(), "RecordStore")
local mock = checked_table(store.Mock, "RecordStore.Mock")

for _, method_name in {
	"new",
	"set_test_clock",
	"reset",
	"quarantine_profile_writes_async",
	"mark_quarantine_release_pending_async",
	"release_quarantine_fence_async",
	"get_record_raw",
} do
	checked_function(mock[method_name], "RecordStore.Mock." .. method_name)
end

local api = mock :: MockApi
local MOCK_NOW = 1_800_000_000
api.reset()
api.set_test_clock(function()
	return MOCK_NOW
end)

local deep_data: JsonValue = "leaf-at-depth-64"
for _ = 1, 64 do
	local parent: { [string]: JsonValue } = { child = deep_data }
	deep_data = parent
end

local function open_record(name: string, key: string, transactional: boolean): ProfileRecord
	local options = {
		schema_version = 1,
		transactional_operations_enabled = transactional,
	}
	local raw_record = checked_table(api.new(name, "global", key, options), name .. " mock record")
	for _, method_name in {
		"Open",
		"GetGeneration",
		"GetRevision",
		"CommitWithOutboxAsync",
		"DispatchOutboxAsync",
		"PruneOutboxAsync",
	} do
		checked_function(raw_record[method_name], name .. "." .. method_name)
	end
	local record = raw_record :: ProfileRecord
	local opened, message = record:Open(deep_data)
	expect(opened == "created" or opened == "loaded",
		name .. " failed to open: status=" .. tostring(opened) .. " message=" .. tostring(message))
	return record
end

local quarantine_record = open_record("RawEnvelopeDepthQuarantine", "profile", false)
local quarantine_id = "depth64-quarantine"
local resolution_id = "depth64-resolution"
local fence, fence_code, fence_message = api.quarantine_profile_writes_async(
	"RawEnvelopeDepthQuarantine",
	"global",
	"profile",
	quarantine_id,
	"depth64-operator",
	"verify envelope copy depth",
	quarantine_record:GetGeneration(),
	quarantine_record:GetRevision(),
	nil
)
expect(fence_code == "success" and fence ~= nil,
	"64-edge quarantine installation failed: " .. tostring(fence_message))
local installed_fence = fence :: QuarantineFenceStatus
expect(installed_fence.Quarantined and installed_fence.Phase == "quarantined",
	"64-edge quarantine installation did not persist the quarantined phase")
local raw_fence = checked_table(
	api.get_record_raw("RawEnvelopeDepthQuarantine", "global", "profile"),
	"durable quarantined raw envelope"
)
local raw_marker = checked_table(raw_fence.__recordstore_quarantine_fence_v1, "durable quarantine marker")
expect(raw_fence.implementation_version == 2147483646,
	"quarantine write did not preserve its future implementation sentinel")
expect(raw_marker.quarantine_id == quarantine_id and raw_marker.phase == "quarantined",
	"quarantine write did not persist its marker identity and phase")
expect(type(installed_fence.SourceRevision) == "number",
	"quarantine status omitted its source revision")
local source_revision = installed_fence.SourceRevision :: number

local pending, pending_code, pending_message = api.mark_quarantine_release_pending_async(
	"RawEnvelopeDepthQuarantine",
	"global",
	"profile",
	quarantine_id,
	resolution_id,
	"depth64-operator",
	"begin 64-edge release",
	source_revision,
	nil
)
expect(pending_code == "success" and pending ~= nil,
	"64-edge release-pending transition failed: " .. tostring(pending_message))
local pending_fence = pending :: QuarantineFenceStatus
expect(pending_fence.Quarantined and pending_fence.Phase == "release_pending",
	"64-edge release-pending transition did not persist its phase")

local released, release_code, release_message = api.release_quarantine_fence_async(
	"RawEnvelopeDepthQuarantine",
	"global",
	"profile",
	quarantine_id,
	resolution_id,
	nil
)
expect(release_code == "success" and released ~= nil,
	"64-edge quarantine release failed: " .. tostring(release_message))
local released_fence = released :: QuarantineFenceStatus
expect(not released_fence.Quarantined, "64-edge quarantine release left the profile fenced")

local outbox_record = open_record("RawEnvelopeDepthOutbox", "profile", true)
local event_specs: { OutboxEventSpec } = {
	{
		target_store = "RawEnvelopeDepthDestination",
		target_scope = "global",
		target_key = "target",
		type = "depth64-event",
		payload_version = 1,
		data = { value = 1 },
	},
}
local committed, commit_status, commit_message = outbox_record:CommitWithOutboxAsync(
	"depth64-commit",
	"depth64-command",
	{ kind = "depth64" },
	event_specs,
	function(current_data: JsonValue?, _request: JsonValue?): (JsonValue?, JsonValue?)
		return current_data, { applied = true }
	end,
	nil
)
expect(commit_status == "committed" and committed ~= nil,
	"64-edge outbox transaction did not commit: " .. tostring(commit_message))

local delivered_count, dispatch_status, dispatch_message = outbox_record:DispatchOutboxAsync(
	function(event: OutboxEvent): (boolean, string?)
		return true, "durable-receipt:" .. event.EventId
	end,
	1
)
expect(delivered_count == 1 and dispatch_status == "success",
	"64-edge outbox event-state update failed: " .. tostring(dispatch_message))

local removed_count, prune_status, prune_message = outbox_record:PruneOutboxAsync(MOCK_NOW + 1, 1)
expect(removed_count == 1 and prune_status == "success",
	"64-edge outbox retention prune failed: " .. tostring(prune_message))

api.reset()
print("[raw-envelope-depth] 64-edge quarantine and outbox mutations passed.")
close_shim()
