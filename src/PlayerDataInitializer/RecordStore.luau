--!strict
--!optimize 2
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local RecordStoreScheduler: any = require(script.Parent.RecordStoreScheduler)

local RecordStore = {}

type MetadataValue = boolean | number | string
export type Metadata = { [string]: MetadataValue }

export type JsonValue =
	boolean
| number
| string
| buffer
| { JsonValue }
| { [string]: JsonValue }

export type SessionState =
	"closed"
| "acquiring"
| "active"
| "saving"
| "releasing"
| "fenced"
| "unknown"
| "tombstoned"
| "corrupt"
| "future"

export type ResultCode =
	"success"
| "created"
| "loaded"
| "saved"
| "closed"
| "deleted"
| "enqueued"
| "processed"
| "empty"
| "locked"
| "already_open"
| "busy"
| "closing"
| "fenced"
| "unknown"
| "conflict"
| "validation"
| "migration"
| "future_schema"
| "corrupt"
| "tombstoned"
| "legacy"
| "budget"
| "retry_exhausted"
| "invalid"
| "not_found"

export type DiagnosticPhase =
	"create"
| "open"
| "normalize"
| "update"

export type Migration = (
	from_version: number,
	value: JsonValue
) -> JsonValue

export type Validator = (
	value: JsonValue
) -> (boolean, string?)

export type LegacyDecoder = (
	raw: unknown
) -> (JsonValue, number?)

export type Observer = (
	event: string,
	key: string,
	result: ResultCode,
	message: string?
) -> ()

export type ChangeEvent = {
	OperationId: string,
	Sequence: number,
	Path: { string },
	OldValue: JsonValue?,
	NewValue: JsonValue?,
	Truncated: boolean,
	Kind: string,
}

export type ChangeObserver = (event: ChangeEvent) -> ()

export type ChangeSubscription = {
	Disconnect: (self: ChangeSubscription) -> (),
}

export type HandoffStatus =
	"pending"
| "accepted"
| "released"
| "busy"
| "stale"
| "not_owner"
| "failed"

export type HandoffResult = {
	RequestId: string,
	Status: HandoffStatus,
	Generation: number,
	TargetJobId: string,
	Published: boolean,
	Deadline: number,
	Suppressed: number,
	Acks: number,
}

export type RecordError = {
	Code: ResultCode,
	Message: string?,
	Retryable: boolean,
	RequiresVerification: boolean,
	DurableOutcome: "not_submitted" | "not_committed" | "unknown" | "committed",
	OperationId: string?,
	Generation: number?,
	Revision: number?,
}


export type MessageObserver = (
	message_type: string,
	data: JsonValue?,
	sent_at: number,
	sender_job_id: string
) -> ()

export type QueueObserver = (
	message_type: string,
	data: JsonValue?,
	attempts: number,
	message_id: string,
	sender_job_id: string,
	created_at: number
) -> (boolean, string?)

export type DurableSnapshot = {
	Data: JsonValue?,
	Revision: number,
	Generation: number,
	UpdatedAt: number,
	ConfirmedAt: number,
	WriteId: string?,
	Reason: string,
	Tombstoned: boolean,
	UserIds: { number },
	Metadata: Metadata,
	BackendVersion: string?,
	BackendCreatedAt: number?,
	BackendUpdatedAt: number?,
}

export type Snapshot = {
	Data: JsonValue?,
	State: SessionState,
	Key: string,
	SchemaVersion: number,
	Generation: number,
	Revision: number,
	CreatedAt: number,
	UpdatedAt: number,
	Tombstoned: boolean,
	SessionActive: boolean,
	LeaseUntil: number?,
	SessionJobId: string?,
	SessionPlaceId: number?,
	UserIds: { number },
	Metadata: Metadata,
	BackendVersion: string?,
	BackendCreatedAt: number?,
	BackendUpdatedAt: number?,
}

export type HistoryEntry = {
	Version: string,
	CreatedTime: number,
	IsDeleted: boolean,
}

type HistoryRecoveryCandidate = {
	ObservedVersion: string,
	SourceVersion: string,
	CorruptReason: string,
	Envelope: Envelope,
	UserIds: { number },
	Metadata: Metadata,
}

export type BackendInfoView = {
	Version: string?,
	CreatedTime: number,
	UpdatedTime: number,
	UserIds: { number },
	Metadata: Metadata,
}

export type QueueMessage = {
	Id: string,
	Type: string,
	Data: JsonValue?,
	Attempts: number,
	TotalAttempts: number,
	ReplayCount: number,
	SenderJobId: string,
	CreatedAt: number,
}

export type DeadLetterMessage = QueueMessage & {
	DeadLetteredAt: number,
	LastError: string,
	LockToken: string?,
	LockedUntil: number?,
}

export type MockQueueClaim = {
	Id: string,
	LockToken: string,
	LockedUntil: number,
}

export type Options = {
	schema_version: number,
	migrations: { [number]: Migration }?,
	validator: Validator?,
	legacy_decoder: LegacyDecoder?,
	user_ids: { number }?,
	metadata: Metadata?,
	autosave_interval: number?,
	lease_duration: number?,
	lease_renewal: number?,
	retry_attempts: number?,
	operation_deadline: number?,
	shutdown_deadline: number?,
	shutdown_attempts: number?,
	budget_wait: number?,
	messaging_enabled: boolean?,
	takeover_enabled: boolean?,
	takeover_wait: number?,
	message_topic_prefix: string?,
	durable_queue_enabled: boolean?,
	queue_store_name: string?,
	queue_poll_interval: number?,
	queue_lease_duration: number?,
	queue_max_messages: number?,
	queue_max_bytes: number?,
	queue_max_attempts: number?,
	on_event: Observer?,
	on_message: MessageObserver?,
	on_queue_message: QueueObserver?,
}


type Tombstone = {
	deleted_at: number,
	generation: number,
}

type SessionEnvelope = {
	token: string,
	generation: number,
	job_id: string,
	place_id: number,
	acquired_at: number,
	lease_until: number,
}

type Envelope = {
	implementation_version: number,
	schema_version: number,
	revision: number,
	fencing_generation: number,
	created_at: number,
	updated_at: number,
	data: JsonValue?,
	user_ids: { number }?,
	tombstone: Tombstone?,
	session: SessionEnvelope?,
	write_id: string,
}

type NonFiniteNumberKind = "nan" | "positive_infinity" | "negative_infinity"

type NonFinitePathSegment =
	{ kind: "string", key: string }
	| { kind: "number", key: number }

type NonFiniteNumberMarker = {
	path: { NonFinitePathSegment },
	kind: NonFiniteNumberKind,
}

type BackendInfo = {
	Version: string?,
	CreatedTime: number,
	UpdatedTime: number,
	UserIds: { number },
	Metadata: Metadata,
	RawMetadata: Metadata,
}

type Backend = {
	name: string,
	scope: string,
	key: string,
	store: DataStore?,
	mock: boolean,
}

type UpdateTransform = (
	raw: unknown,
	info: BackendInfo?
) -> (unknown, { number }?, Metadata?)

type MockVersion = {
	Version: string,
	CreatedTime: number,
	UpdatedTime: number,
	Value: JsonValue?,
	UserIds: { number },
	Metadata: Metadata,
	Deleted: boolean,
}

type MockEntry = {
	Value: JsonValue?,
	UserIds: { number },
	Metadata: Metadata,
	Version: string,
	CreatedTime: number,
	UpdatedTime: number,
	Versions: { [string]: MockVersion },
	VersionOrder: { string },
}

type QueueItem = {
	id: string,
	type: string,
	data: JsonValue?,
	attempts: number,
	total_attempts: number,
	replay_count: number,
	last_replay_token: string?,
	sender_job_id: string,
	created_at: number,
	locked_until: number,
	lock_token: string?,
}

type DeadLetterItem = QueueItem & {
	dead_lettered_at: number,
	last_error: string,
	terminal_lock_token: string?,
}

type QueueOwner = {
	name: string,
	scope: string,
	key: string,
}

type QueueEnvelope = {
	implementation_version: number,
	owner: QueueOwner,
	messages: { QueueItem },
	dead_letters: { DeadLetterItem },
}

type InternalState = {
	change_observers: { [number]: ChangeObserver },
	change_observer_next_id: number,
	change_dispatch_queue: { ChangeEvent },
	change_dispatch_head: number,
	change_dispatch_tail: number,
	change_dispatch_running: boolean,
	change_events_dropped: number,
	takeover_seen: { [string]: HandoffStatus },
	takeover_seen_order: { string },
	takeover_request_id: string?,
	takeover_requester_job_id: string?,
	handoff_request_id: string?,
	handoff_target_job_id: string?,
	handoff_target_token: string?,
	handoff_target_generation: number?,
	handoff_status: HandoffStatus?,
	handoff_deadline: number,
	handoff_published: boolean,
	handoff_last_publish: number,
	handoff_requests_suppressed: number,
	handoff_ack_count: number,
	current_operation_id: string?,
	pending_open_token: string?,
	pending_open_write_id: string?,
	pending_open_default_data: JsonValue?,
	name: string,
	scope: string,
	key: string,
	backend: Backend,
	queue_backend: Backend?,
	queue_legacy_checked: boolean,
	options: Options,
	state: SessionState,
	data: JsonValue?,
	public_data_source: JsonValue?,
	public_record: unknown,
	token: string?,
	generation: number,
	revision: number,
	created_at: number,
	updated_at: number,
	user_ids: { number },
	metadata: Metadata,
	tombstoned: boolean,
	next_autosave: number,
	next_renewal: number,
	next_message_subscribe: number,
	next_queue_poll: number,
	busy: boolean,
	queue_busy: boolean,
	save_requested: boolean,
	shutdown: boolean,
	retired: boolean,
	takeover_requested: boolean,
	queue_hint: boolean,
	message_topic: string,
	message_subscription: RBXScriptConnection?,
	last_error: string?,
	last_error_info: RecordError?,
	last_result: ResultCode?,
	last_observed: number,
	observer_errors: number,
	last_saved: DurableSnapshot?,
	change_sequence: number,
	saved_change_sequence: number,
	durable_lease_until: number,
}

export type Record = {
	Data: JsonValue?,
	State: SessionState,
	Key: string,
	Generation: number,
	Revision: number,
	CreatedAt: number,
	UpdatedAt: number,
	Tombstoned: boolean,
	LastError: string?,
	Open: (self: Record, default_data: JsonValue?, recreate: boolean?) -> (ResultCode, string?),
	Get: (self: Record) -> JsonValue?,
	GetKey: (self: Record) -> string,
	GetState: (self: Record) -> SessionState,
	GetRevision: (self: Record) -> number,
	GetGeneration: (self: Record) -> number,
	IsOpen: (self: Record) -> boolean,
	GetBackendInfo: (self: Record) -> BackendInfoView,
	GetLastSaved: (self: Record) -> DurableSnapshot?,
	IsDirty: (self: Record) -> boolean,
	GetLastError: (self: Record) -> RecordError?,
	GetHandoff: (self: Record) -> HandoffResult?,
	SubscribeChanges: (self: Record, observer: ChangeObserver) -> (ChangeSubscription?, ResultCode, string?),
	GetUserIds: (self: Record) -> { number },
	SetUserIds: (self: Record, user_ids: { number }) -> (ResultCode, string?),
	AddUserId: (self: Record, user_id: number) -> (ResultCode, string?),
	RemoveUserId: (self: Record, user_id: number) -> (ResultCode, string?),
	GetMetadata: (self: Record) -> Metadata,
	SetMetadata: (self: Record, metadata: Metadata) -> (ResultCode, string?),
	UpdateMetadata: (self: Record, callback: (Metadata) -> Metadata) -> (ResultCode, string?),
	Touch: (self: Record) -> (ResultCode, string?),
	Update: (self: Record, callback: (JsonValue?) -> JsonValue?) -> (ResultCode, string?),
	Reconcile: (self: Record, template: JsonValue) -> (ResultCode, string?),
	Save: (self: Record, reason: string?) -> (ResultCode, string?),
	MessageAsync: (self: Record, message_type: string, data: JsonValue?) -> (ResultCode, string?),
	EnqueueAsync: (self: Record, message_type: string, data: JsonValue?) -> (ResultCode, string?),
	ProcessQueueAsync: (self: Record, max_messages: number?) -> (ResultCode, string?),
	GetQueueAsync: (self: Record) -> ({ QueueMessage }, ResultCode, string?),
	GetDeadLettersAsync: (self: Record) -> ({ DeadLetterMessage }, ResultCode, string?),
	ClaimDeadLetterAsync: (self: Record, message_id: string) -> (DeadLetterMessage?, ResultCode, string?),
	ReplayDeadLetterAsync: (self: Record, message_id: string, lock_token: string) -> (ResultCode, string?),
	DiscardDeadLetterAsync: (self: Record, message_id: string, lock_token: string) -> (ResultCode, string?),
	Close: (self: Record) -> (ResultCode, string?),
	Delete: (self: Record) -> (ResultCode, string?),
	Stats: (self: Record) -> { [string]: number | string? },
}

local IMPLEMENTATION_VERSION = 2
local QUEUE_IMPLEMENTATION_VERSION = 3
local DEFAULT_AUTOSAVE_INTERVAL = 300
local DEFAULT_LEASE_DURATION = 180
local DEFAULT_LEASE_RENEWAL = 60
local DEFAULT_RETRY_ATTEMPTS = 5
local MAX_RETRY_ATTEMPTS = 12
local DEFAULT_OPERATION_DEADLINE = 20
local DEFAULT_SHUTDOWN_DEADLINE = 25
local DEFAULT_SHUTDOWN_ATTEMPTS = 2
local DEFAULT_MAX_CONCURRENT_REQUESTS = 4
local DEFAULT_BUDGET_WAIT = 2
local MIN_RETRY_DELAY = 0.25
local MAX_RETRY_DELAY = 4
local SCHEDULER_STEP = 1
local DEFAULT_TAKEOVER_WAIT = 2
local DEFAULT_MESSAGE_TOPIC_PREFIX = "recordstore:"
local DEFAULT_QUEUE_STORE_NAME = "RecordStoreQueue"
local DEFAULT_QUEUE_POLL_INTERVAL = 10
local DEFAULT_QUEUE_LEASE_DURATION = 60
local DEFAULT_QUEUE_MAX_MESSAGES = 100
local DEFAULT_QUEUE_MAX_BYTES = 250_000
local DEFAULT_QUEUE_MAX_ATTEMPTS = 5
local MAX_QUEUE_ATTEMPTS = 12
local MAX_QUEUE_ERROR_LENGTH = 256
local MAX_MESSAGE_BYTES = 900
local CHANGE_OBSERVER_CAPACITY = 1024
local CHANGE_DISPATCH_QUEUE_CAPACITY = 4096
local TAKEOVER_SEEN_CAPACITY = 64
local HANDOFF_PUBLISH_COOLDOWN = 0.5
local INTERNAL_METADATA_WRITE_ID = "__rs:w"
local INTERNAL_METADATA_GENERATION = "__rs:g"
local INTERNAL_METADATA_REVISION = "__rs:r"
local INTERNAL_METADATA_TOKEN = "__rs:t"
local MAX_DATASTORE_BYTES = 4_194_304
local MAX_METADATA_TOTAL_BYTES = 300
local MAX_METADATA_KEY_LENGTH = 50
local MAX_METADATA_VALUE_LENGTH = 250
local MAX_MESSAGE_TYPE_LENGTH = 100
local MESSAGE_SUBSCRIBE_RETRY = 10
local QUEUE_OWNERSHIP_SAFETY_WINDOW = 5

local server_id = game.JobId
if server_id == "" then
	server_id = HttpService:GenerateGUID(false)
end

local closing = false
local scheduler_started = false
local shutdown_started = false
local active_requests = 0
local records: { [string]: Record } = {}
local private: { [Record]: InternalState } = {}
local active_records: { [Record]: boolean } = {}
local mock_database: { [string]: { [string]: MockEntry } } = {}
local mock_counter = 0
local mock_test_clock: (() -> number)? = nil
local mock_test_clock_offset = 0
local mock_update_replay_retries = 0
local mock_update_replay_advance_seconds = 0
local mock_update_failure_count = 0
local mock_update_failure_code: ResultCode = "budget"
local mock_update_failure_message: string? = nil

local close_internal: (state: InternalState, shutdown: boolean) -> (ResultCode, string?)
local complete_deferred_takeover: (state: InternalState) -> ()
local process_queue_internal: (state: InternalState, max_messages: number) -> (ResultCode, string?)
local copy_value: (value: unknown) -> JsonValue?
local track_external_data_mutation: (state: InternalState) -> ()
local messaging_enabled: (state: InternalState) -> boolean
local publish_record_message: (state: InternalState, kind: string, message_type: string?, data: JsonValue?, generation: number?, target_job_id: string?, target_token: string?, request_id: string?, handoff_status: HandoffStatus?, requester_job_id: string?) -> (boolean, string?)
local verify_snapshot_write: (state: InternalState, write_id: string, token: string, generation: number, revision: number, operation_deadline: number) -> (boolean, Envelope?, BackendInfo?)
local verify_release_write: (state: InternalState, write_id: string, generation: number, revision: number, tombstone: boolean, operation_deadline: number) -> (boolean, Envelope?, BackendInfo?)

local function now_unix(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function session_now_unix(mock: boolean): number
	if mock and mock_test_clock ~= nil then
		return mock_test_clock() + mock_test_clock_offset
	end
	return now_unix()
end

local function queue_now_unix(mock: boolean): number
	return session_now_unix(mock)
end

local function now_local(): number
	return os.clock()
end

local function resolve_operation_deadline(operation_deadline: number?): (number?, string?)
	local duration = operation_deadline
	if duration == nil then
		duration = DEFAULT_OPERATION_DEADLINE
	end
	if type(duration) ~= "number" or not math.isfinite(duration) or duration <= 0 then
		return nil, "operation_deadline must be a positive finite number"
	end
	return now_local() + duration, nil
end

local function run_validator(validator: Validator, value: JsonValue): (boolean, boolean, string?)
	local accepted = false
	local message: string? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, callback_accepted, callback_message = pcall(validator, value)
		if not ok then
			callback_error = tostring(callback_accepted)
			return
		end
		accepted = callback_accepted == true
		if callback_message ~= nil and type(callback_message) == "string" then
			message = callback_message
		end
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, false, "validator must not yield"
	end
	if not resumed then
		return false, false, "validator execution failed"
	end
	if callback_error ~= nil then
		return false, false, "validator threw: " .. callback_error
	end
	return true, accepted, message
end

local function run_migration(migration: Migration, version: number, value: JsonValue): (JsonValue?, string?)
	local next_value: JsonValue? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, callback_value = pcall(migration, version, value)
		if not ok then
			callback_error = tostring(callback_value)
			return
		end
		if callback_value == nil then
			callback_error = "migration " .. tostring(version) .. " returned nil"
			return
		end
		next_value = callback_value
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return nil, "migration " .. tostring(version) .. " must not yield"
	end
	if not resumed then
		return nil, "migration " .. tostring(version) .. " execution failed"
	end
	if callback_error ~= nil then
		return nil, "migration " .. tostring(version) .. " failed: " .. callback_error
	end
	if next_value == nil then
		return nil, "migration " .. tostring(version) .. " returned nil"
	end
	local copy_ok, copied_or_error = pcall(function()
		return copy_value(next_value)
	end)
	if not copy_ok or copied_or_error == nil then
		return nil, "migration " .. tostring(version) .. " returned invalid data"
	end
	return copied_or_error, nil
end

local function run_legacy_decoder(decoder: LegacyDecoder, raw: unknown): (JsonValue?, number?, string?)
	local decoded_value: JsonValue? = nil
	local decoded_version: number? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, value, version = pcall(decoder, raw)
		if not ok then
			callback_error = tostring(value)
			return
		end
		if value == nil then
			callback_error = "legacy decoder returned nil"
			return
		end
		if version ~= nil and (type(version) ~= "number" or not math.isfinite(version) or version < 0 or math.floor(version) ~= version) then
			callback_error = "legacy decoder returned an invalid schema version"
			return
		end
		decoded_value = value
		decoded_version = version
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return nil, nil, "legacy decoder must not yield"
	end
	if not resumed then
		return nil, nil, "legacy decoder execution failed"
	end
	if callback_error ~= nil then
		return nil, nil, callback_error
	end
	if decoded_value == nil then
		return nil, nil, "legacy decoder returned nil"
	end
	local copy_ok, copied_or_error = pcall(function()
		return copy_value(decoded_value)
	end)
	if not copy_ok or copied_or_error == nil then
		return nil, nil, "legacy decoder returned invalid data"
	end
	return copied_or_error, decoded_version, nil
end

local function clone_metadata(metadata: Metadata?): Metadata
	local result: Metadata = {}
	if metadata == nil then
		return result
	end
	for key, value in pairs(metadata) do
		result[key] = value
	end
	return result
end

local function clone_user_ids(user_ids: { number }?): { number }
	local result: { number } = {}
	if user_ids == nil then
		return result
	end
	for _, user_id in ipairs(user_ids) do
		result[#result + 1] = user_id
	end
	return result
end

local function normalize_user_ids(user_ids: { number }): ({ number }?, string?)
	local seen: { [number]: boolean } = {}
	local result: { number } = {}
	local length = #user_ids
	local numeric_count = 0
	for index, user_id in user_ids do
		if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 then
			return nil, "user_ids must be a dense array of positive integers"
		end
		numeric_count += 1
		if index > length then
			return nil, "user_ids must be a dense array of positive integers"
		end
		if type(user_id) ~= "number" or not math.isfinite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
			return nil, ("user_ids[%d] must be a positive integer"):format(index)
		end
		if not seen[user_id] then
			seen[user_id] = true
			result[#result + 1] = user_id
		end
	end
	if numeric_count ~= length then
		return nil, "user_ids must be a dense array of positive integers"
	end
	table.sort(result)
	return result, nil
end

local function validate_metadata(metadata: Metadata, allow_reserved: boolean?): (boolean, string?)
	if type(metadata) ~= "table" then
		return false, "metadata must be a table"
	end
	for key, value in pairs(metadata) do
		if type(key) ~= "string" or key == "" or #key > MAX_METADATA_KEY_LENGTH then
			return false, "metadata keys must be non-empty strings of at most 50 characters"
		end
		if not allow_reserved and string.sub(key, 1, 5) == "__rs:" then
			return false, "metadata keys beginning with __rs: are reserved by RecordStore"
		end
		if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
			return false, "metadata values must be strings, numbers, or booleans"
		end
		if type(value) == "number" then
			if not math.isfinite(value) then
				return false, ("metadata.%s must be finite"):format(key)
			end
		elseif type(value) == "string" and #value > MAX_METADATA_VALUE_LENGTH then
			return false, ("metadata.%s exceeds 250 characters"):format(key)
		end
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(metadata)
	end)
	if not ok or type(encoded) ~= "string" then
		return false, "metadata could not be encoded"
	end
	if #encoded > MAX_METADATA_TOTAL_BYTES then
		return false, "metadata exceeds the 300 character limit"
	end
	return true, nil
end

local function validate_value_shape(value: unknown, max_depth: number?, max_nodes: number?, max_string_length: number?, allow_non_finite_numbers: boolean?): (boolean, string?)
	local depth_limit = max_depth or 64
	local node_limit = max_nodes or 100000
	local string_limit = max_string_length or 4_000_000
	local node_count = 0
	local active_tables: { [table]: boolean } = {}

	local function visit(current: unknown, depth: number): (boolean, string?)
		node_count += 1
		if node_count > node_limit then
			return false, "value exceeds the maximum node count"
		end
		if depth > depth_limit then
			return false, "value exceeds the maximum nesting depth"
		end
		if current == nil then
			return true, nil
		end
		if type(current) == "number" then
			if not math.isfinite(current) and allow_non_finite_numbers ~= true then
				return false, "value contains a non-finite number"
			end
			return true, nil
		end
		if type(current) == "string" then
			if #current > string_limit then
				return false, "value contains an overlong string"
			end
			return true, nil
		end
		if type(current) == "boolean" or type(current) == "buffer" then
			return true, nil
		end
		if type(current) ~= "table" then
			return false, "value contains an unsupported type: " .. type(current)
		end
		local table_value = current :: table
		if active_tables[table_value] then
			return false, "value contains a cyclic table"
		end
		active_tables[table_value] = true
		local string_keys = 0
		local numeric_keys = 0
		local max_numeric_key = 0
		for key, child in table_value do
			if type(key) ~= "string" and type(key) ~= "number" then
				active_tables[table_value] = nil
				return false, "value contains an unsupported table key type"
			end
			if type(key) == "number" then
				if not math.isfinite(key) or math.floor(key) ~= key or key < 1 then
					active_tables[table_value] = nil
					return false, "numeric table keys must be positive integers"
				end
				numeric_keys += 1
				if key > max_numeric_key then
					max_numeric_key = key
				end
			else
				string_keys += 1
			end
			local child_ok, child_message = visit(child, depth + 1)
			if not child_ok then
				active_tables[table_value] = nil
				return false, child_message
			end
		end
		if string_keys > 0 and numeric_keys > 0 then
			active_tables[table_value] = nil
			return false, "tables cannot mix string and numeric keys"
		end
		if numeric_keys > 0 and max_numeric_key ~= numeric_keys then
			active_tables[table_value] = nil
			return false, "numeric-keyed tables must be dense arrays"
		end
		active_tables[table_value] = nil
		return true, nil
	end

	return visit(value, 0)
end

local function make_backend_metadata(metadata: Metadata, envelope: Envelope): Metadata
	local combined = clone_metadata(metadata)
	combined[INTERNAL_METADATA_WRITE_ID] = envelope.write_id
	combined[INTERNAL_METADATA_GENERATION] = tostring(envelope.fencing_generation)
	combined[INTERNAL_METADATA_REVISION] = tostring(envelope.revision)
	combined[INTERNAL_METADATA_TOKEN] = if envelope.session ~= nil then envelope.session.token else ""
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(combined)
	end)
	if ok and type(encoded) == "string" and #encoded <= MAX_METADATA_TOTAL_BYTES then
		return combined
	end
	return clone_metadata(metadata)
end

local function backend_metadata_matches(info: BackendInfo?, envelope: Envelope): boolean
	if info == nil then
		return true
	end
	local write_id = info.RawMetadata[INTERNAL_METADATA_WRITE_ID]
	if write_id == nil then
		return true
	end
	if write_id ~= envelope.write_id then
		return false
	end
	local generation = info.RawMetadata[INTERNAL_METADATA_GENERATION]
	local revision = info.RawMetadata[INTERNAL_METADATA_REVISION]
	if generation ~= nil and generation ~= tostring(envelope.fencing_generation) then
		return false
	end
	if revision ~= nil and revision ~= tostring(envelope.revision) then
		return false
	end
	if envelope.session ~= nil then
		local token = info.RawMetadata[INTERNAL_METADATA_TOKEN]
		if token ~= nil and token ~= envelope.session.token then
			return false
		end
	end
	return true
end

copy_value = function(value: unknown): JsonValue?
	if value == nil then
		return nil
	end

	local active_tables: { [table]: boolean } = {}

	local function clone(current: unknown, depth: number): JsonValue?
		if current == nil then
			return nil
		end
		if depth > 64 then
			error("value exceeds the maximum nesting depth")
		end
		if type(current) == "boolean" then
			return current
		end
		if type(current) == "number" then
			return current
		end
		if type(current) == "string" then
			return current
		end
		if typeof(current) == "buffer" then
			return buffer.fromstring(buffer.tostring(current))
		end
		if type(current) ~= "table" then
			error("value contains an unsupported type")
		end

		local table_value = current :: table
		if active_tables[table_value] then
			error("value contains a cyclic table")
		end
		active_tables[table_value] = true
		local has_string_key = false
		local has_number_key = false
		local result_dictionary: { [string]: JsonValue }? = nil
		local result_array: { JsonValue }? = nil

		for key, child in current do
			local key_type = type(key)
			if key_type == "string" then
				if has_number_key then
					active_tables[table_value] = nil
					error("value contains mixed table keys")
				end
				has_string_key = true
				local dictionary_key = key :: string
				local copied = clone(child, depth + 1)
				if copied == nil then
					active_tables[table_value] = nil
					error("value contains an invalid nil child")
				end
				if result_dictionary == nil then
					result_dictionary = {}
				end
				result_dictionary[dictionary_key] = copied
			elseif key_type == "number" then
				if has_string_key then
					active_tables[table_value] = nil
					error("value contains mixed table keys")
				end
				has_number_key = true
				local numeric_key = key :: number
				if not math.isfinite(numeric_key)
					or math.floor(numeric_key) ~= numeric_key
					or numeric_key < 1
				then
					active_tables[table_value] = nil
					error("value contains an invalid array index")
				end
				local copied = clone(child, depth + 1)
				if copied == nil then
					active_tables[table_value] = nil
					error("value contains an invalid nil child")
				end
				if result_array == nil then
					result_array = {}
				end
				result_array[numeric_key] = copied
			else
				active_tables[table_value] = nil
				error("value contains an unsupported table key")
			end
		end

		active_tables[table_value] = nil
		if has_string_key then
			return result_dictionary
		end
		if result_array ~= nil then
			return result_array
		end
		local empty_result: { JsonValue } = {}
		return empty_result
	end
	return clone(value, 1)
end
local function encode_non_finite_numbers(
	value: JsonValue
): (JsonValue, { NonFiniteNumberMarker })
	local markers: { NonFiniteNumberMarker } = {}
	local path: { NonFinitePathSegment } = {}

	local function encode(current: JsonValue, depth: number): (JsonValue, boolean)
		if depth > 64 then
			error("value exceeds the maximum nesting depth")
		end

		if type(current) == "number" then
			if math.isfinite(current) then
				return current, false
			end

			local kind: NonFiniteNumberKind
			if math.isnan(current) then
				kind = "nan"
			elseif current > 0 then
				kind = "positive_infinity"
			else
				kind = "negative_infinity"
			end

			markers[#markers + 1] = {
				path = table.clone(path),
				kind = kind,
			}
			return 0, true
		end

		if typeof(current) == "buffer" or type(current) ~= "table" then
			return current, false
		end

		local source = current :: { [string | number]: JsonValue }
		local dictionary: boolean? = nil
		local result: { [string | number]: JsonValue }? = nil

		for key, child in source do
			local key_type = type(key)
			if key_type ~= "string" and key_type ~= "number" then
				error("value contains an unsupported table key")
			end

			local is_dictionary_key = key_type == "string"
			if dictionary == nil then
				dictionary = is_dictionary_key
			elseif dictionary ~= is_dictionary_key then
				error("value contains mixed table keys")
			end

			path[#path + 1] = if is_dictionary_key
				then { kind = "string", key = key :: string }
				else { kind = "number", key = key :: number }
			local encoded_child, child_changed = encode(child, depth + 1)
			path[#path] = nil

			if child_changed then
				if result == nil then
					result = table.clone(source)
				end
				result[key] = encoded_child
			end
		end

		if result == nil then
			return current, false
		end
		return result, true
	end

	local encoded, _changed = encode(value, 1)
	return encoded, markers
end

local function restore_non_finite_numbers(
	value: JsonValue?,
	raw_markers: unknown
): (JsonValue?, string?)
	if raw_markers == nil then
		return value, nil
	end
	if value == nil or type(raw_markers) ~= "table" then
		return nil, "non-finite number metadata is invalid"
	end

	local markers = raw_markers :: { [number]: unknown }
	local count = 0
	local maximum_index = 0
	for index in markers do
		if type(index) ~= "number"
			or not math.isfinite(index)
			or math.floor(index) ~= index
			or index < 1
		then
			return nil, "non-finite number metadata must be a dense array"
		end
		count += 1
		maximum_index = math.max(maximum_index, index)
	end
	if count ~= maximum_index then
		return nil, "non-finite number metadata must be a dense array"
	end
	if count == 0 then
		return value, nil
	end
	local result: JsonValue? = value
	if result == nil then
		return nil, "stored data is missing before restoring non-finite numbers"
	end

	for index = 1, count do
		local raw_marker = markers[index]
		if type(raw_marker) ~= "table" then
			return nil, "non-finite number marker is invalid"
		end
		local marker = raw_marker :: { [string]: unknown }
		local kind = marker.kind
		local raw_path = marker.path
		if kind ~= "nan" and kind ~= "positive_infinity" and kind ~= "negative_infinity" then
			return nil, "non-finite number marker kind is invalid"
		end
		if type(raw_path) ~= "table" then
			return nil, "non-finite number marker path is invalid"
		end

		local path = raw_path :: { [number]: unknown }
		local path_count = 0
		local path_maximum = 0
		for path_index in path do
			if type(path_index) ~= "number"
				or not math.isfinite(path_index)
				or math.floor(path_index) ~= path_index
				or path_index < 1
			then
				return nil, "non-finite number marker path must be a dense array"
			end
			path_count += 1
			path_maximum = math.max(path_maximum, path_index)
		end
		if path_count ~= path_maximum or path_count > 64 then
			return nil, "non-finite number marker path is invalid"
		end

		local replacement: number
		if kind == "nan" then
			replacement = 0 / 0
		elseif kind == "positive_infinity" then
			replacement = math.huge
		else
			replacement = -math.huge
		end

		if path_count == 0 then
			if type(result) ~= "number" or result ~= 0 then
				return nil, "non-finite number marker does not match its stored placeholder"
			end
			result = replacement
			continue
		end

		local parent: JsonValue = result
		for path_index = 1, path_count do
			local raw_segment = path[path_index]
			if type(raw_segment) ~= "table" or type(parent) ~= "table" then
				return nil, "non-finite number marker path does not match stored data"
			end
			local segment = raw_segment :: { [string]: unknown }
			local segment_kind = segment.kind
			local key = segment.key
			local is_last = path_index == path_count
			local child: JsonValue?

			if segment_kind == "string" and type(key) == "string" then
				local dictionary = parent :: { [string]: JsonValue }
				child = dictionary[key]
				if child == nil then
					return nil, "non-finite number marker references a missing field"
				end
				if is_last then
					if type(child) ~= "number" or child ~= 0 then
						return nil, "non-finite number marker does not match its stored placeholder"
					end
					dictionary[key] = replacement
				else
					parent = child
				end
			elseif segment_kind == "number"
				and type(key) == "number"
				and math.isfinite(key)
				and math.floor(key) == key
				and key >= 1
			then
				local array = parent :: { [number]: JsonValue }
				child = array[key]
				if child == nil then
					return nil, "non-finite number marker references a missing array item"
				end
				if is_last then
					if type(child) ~= "number" or child ~= 0 then
						return nil, "non-finite number marker does not match its stored placeholder"
					end
					array[key] = replacement
				else
					parent = child
				end
			else
				return nil, "non-finite number marker path segment is invalid"
			end
		end
	end

	return result, nil
end

local prepared_envelope_cache: {[table]: JsonValue} = setmetatable({}, { __mode = "k" })

local function encode_envelope_for_storage(envelope: Envelope): JsonValue
	local stored: { [string]: JsonValue } = {
		implementation_version = envelope.implementation_version,
		schema_version = envelope.schema_version,
		revision = envelope.revision,
		fencing_generation = envelope.fencing_generation,
		created_at = envelope.created_at,
		updated_at = envelope.updated_at,
		write_id = envelope.write_id,
		non_finite_numbers = {},
	}

	if envelope.data ~= nil then
		local encoded_data, markers = encode_non_finite_numbers(envelope.data)
		stored.data = encoded_data
		stored.non_finite_numbers = markers :: JsonValue
	end
	if envelope.user_ids ~= nil then
		stored.user_ids = copy_value(envelope.user_ids) :: JsonValue
	end
	if envelope.tombstone ~= nil then
		stored.tombstone = copy_value(envelope.tombstone) :: JsonValue
	end
	if envelope.session ~= nil then
		stored.session = copy_value(envelope.session) :: JsonValue
	end
	return stored
end

local function encode_backend_update_value(value: unknown): unknown
	if type(value) ~= "table" then
		return value
	end
	local candidate = value :: { [string]: unknown }
	if candidate.implementation_version ~= nil
		and candidate.schema_version ~= nil
		and candidate.revision ~= nil
		and candidate.fencing_generation ~= nil
		and candidate.created_at ~= nil
		and candidate.updated_at ~= nil
		and candidate.write_id ~= nil
	then
		local envelope = value :: Envelope
		local prepared = prepared_envelope_cache[envelope]
		return if prepared ~= nil then prepared else encode_envelope_for_storage(envelope)
	end
	return value
end

local function validate_serialized_size(value: unknown): (boolean, string?)
	local shape_ok, shape_message = validate_value_shape(value)
	if not shape_ok then
		return false, shape_message
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(value)
	end)
	if not ok or type(encoded) ~= "string" then
		return false, "value is not JSON-encodable"
	end
	if #encoded > MAX_DATASTORE_BYTES then
		return false, ("serialized value exceeds the %d byte DataStore limit"):format(MAX_DATASTORE_BYTES)
	end
	return true, nil
end

local function validate_value(value: JsonValue?, validator: Validator?): (boolean, string?)
	if value == nil then
		return false, "record data cannot be nil"
	end
	local shape_ok, shape_message = validate_value_shape(value, nil, nil, nil, true)
	if not shape_ok then
		return false, shape_message
	end
	local safe_value_ok, safe_value = pcall(function()
		local encoded_value = encode_non_finite_numbers(value)
		return encoded_value
	end)
	if not safe_value_ok then
		return false, "value could not be encoded for JSON persistence"
	end
	local encoded_ok, serialized = pcall(function()
		return HttpService:JSONEncode(safe_value)
	end)
	if not encoded_ok or type(serialized) ~= "string" then
		return false, "value is not JSON-encodable"
	end
	if #serialized > MAX_DATASTORE_BYTES then
		return false, ("serialized value exceeds the %d byte DataStore limit"):format(MAX_DATASTORE_BYTES)
	end
	if validator ~= nil then
		local completed, accepted, message = run_validator(validator, value)
		if not completed then
			return false, message
		end
		if not accepted then
			return false, message or "validator rejected the value"
		end
	end
	return true, nil
end

local function validate_store_identity(name: string, scope: string, key: string): (boolean, string?)
	if type(name) ~= "string" or type(scope) ~= "string" or type(key) ~= "string" then
		return false, "store name, scope, and key must be strings"
	end
	if name == "" or #name > 50 then
		return false, "store name must be 1 to 50 characters"
	end
	if #scope > 50 then
		return false, "scope must be at most 50 characters"
	end
	if key == "" or #key > 50 then
		return false, "key must be 1 to 50 characters"
	end
	return true, nil
end

local function hash_topic(value: string): string
	local hash = 5381
	for index = 1, #value do
		hash = bit32.band(
			bit32.lshift(hash, 5)
				+ hash
				+ string.byte(value, index),
			0xffffffff
		)
	end
	return string.format("%08x", hash)
end

local function make_message_topic(prefix: string, name: string, scope: string, key: string): string
	return prefix .. hash_topic(name .. "\0" .. scope .. "\0" .. key)
end

local function make_queue_key_legacy(name: string, scope: string, key: string): string
	return "q:" .. hash_topic(name .. "\0" .. scope .. "\0" .. key)
end

local function hash_sdbm(value: string): string
	local hash = 0
	for index = 1, #value do
		local byte = string.byte(value, index)
		hash = bit32.band(
			byte
				+ bit32.lshift(hash, 6)
				+ bit32.lshift(hash, 16)
			- hash,
			0xffffffff
		)
	end
	return string.format("%08x", hash)
end

local function make_queue_key_v2(name: string, scope: string, key: string): string
	local identity = name .. "\0" .. scope .. "\0" .. key
	return "q2:" .. hash_topic(identity) .. ":" .. hash_sdbm(identity)
end

local function make_queue_owner(name: string, scope: string, key: string): QueueOwner
	return {
		name = name,
		scope = scope,
		key = key,
	}
end

local function retry_delay(attempt: number): number
	local exponential = MIN_RETRY_DELAY * (2 ^ math.max(0, attempt - 1))
	return math.min(MAX_RETRY_DELAY, exponential) + math.random() * 0.25
end

local function is_retryable_result(result: ResultCode, operation: string?): boolean
	if result == "budget"
		or result == "busy"
		or result == "unknown"
		or result == "retry_exhausted"
	then
		return true
	end

	return operation == "open" and (result == "locked" or result == "conflict")
end

local DIAGNOSTIC_PHASE_CODES: { [DiagnosticPhase]: string } = {
	create = "CREATE",
	open = "OPEN",
	normalize = "NORMALIZE",
	update = "UPDATE",
}

local function get_diagnostic_code(phase: DiagnosticPhase, result: ResultCode): string
	local result_code = string.upper((string.gsub(result, "_", "-")))
	return "RS-" .. DIAGNOSTIC_PHASE_CODES[phase] .. "-" .. result_code
end

local function observe(state: InternalState, event: string, result: ResultCode, message: string?)
	state.last_result = result
	state.last_error = message
	local retryable = is_retryable_result(result, event)
	local requires_verification = result == "unknown"
	local durable_outcome: "not_submitted" | "not_committed" | "unknown" | "committed" = "not_committed"
	if result == "saved" or result == "closed" or result == "deleted" or result == "created" or result == "loaded" or result == "success" then
		durable_outcome = "committed"
	elseif result == "unknown" or result == "retry_exhausted" then
		durable_outcome = "unknown"
	end
	state.last_error_info = {
		Code = result,
		Message = message,
		Retryable = retryable,
		RequiresVerification = requires_verification,
		DurableOutcome = durable_outcome,
		OperationId = state.current_operation_id,
		Generation = if state.generation > 0 then state.generation else nil,
		Revision = if state.revision > 0 then state.revision else nil,
	}
	local observer = state.options.on_event
	if observer == nil then
		return
	end
	local thread = coroutine.create(function()
		observer(event, state.key, result, message)
	end)
	local resumed = coroutine.resume(thread)
	if not resumed or coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		state.observer_errors += 1
	end
end

type DiffKey = {
	Key: string | number,
	PathSegment: string,
}

local function sorted_child_keys(old_value: JsonValue?, new_value: JsonValue?): { DiffKey }
	local seen_keys: { [string | number]: boolean } = {}
	local result: { DiffKey } = {}
	local function add_key(key: string | number)
		if not seen_keys[key] then
			seen_keys[key] = true
			result[#result + 1] = {
				Key = key,
				PathSegment = if type(key) == "number" then "[" .. tostring(key) .. "]" else key,
			}
		end
	end
	if old_value ~= nil and type(old_value) == "table" then
		for key in old_value do
			if type(key) == "string" or type(key) == "number" then
				add_key(key)
			end
		end
	end
	if new_value ~= nil and type(new_value) == "table" then
		for key in new_value do
			if type(key) == "string" or type(key) == "number" then
				add_key(key)
			end
		end
	end
	table.sort(result, function(left: DiffKey, right: DiffKey): boolean
		return left.PathSegment < right.PathSegment
	end)
	return result
end

local function append_change_event(events: { ChangeEvent }, path: { string }, old_value: JsonValue?, new_value: JsonValue?, operation_id: string, sequence: number, kind: string): boolean
	if #events >= CHANGE_OBSERVER_CAPACITY then
		return false
	end
	events[#events + 1] = {
		OperationId = operation_id,
		Sequence = sequence,
		Path = table.clone(path),
		OldValue = old_value,
		NewValue = new_value,
		Truncated = false,
		Kind = kind,
	}
	return true
end

local function get_table_child(value: JsonValue?, key: string | number): JsonValue?
	if value == nil or type(value) ~= "table" then
		return nil
	end
	local table_value = value :: { [string | number]: JsonValue }
	return table_value[key]
end

local function diff_change_events(events: { ChangeEvent }, old_value: JsonValue?, new_value: JsonValue?, path: { string }, operation_id: string, sequence: number, kind: string): boolean
	if old_value == new_value
		or (type(old_value) == "number"
			and type(new_value) == "number"
			and math.isnan(old_value)
			and math.isnan(new_value))
	then
		return true
	end
	if type(old_value) == "table" and type(new_value) == "table" then
		local keys = sorted_child_keys(old_value, new_value)
		for _, entry in ipairs(keys) do
			path[#path + 1] = entry.PathSegment
			local old_child = get_table_child(old_value, entry.Key)
			local new_child = get_table_child(new_value, entry.Key)
			local complete = diff_change_events(events, old_child, new_child, path, operation_id, sequence, kind)
			path[#path] = nil
			if not complete then
				return false
			end
		end
		return true
	end
	return append_change_event(events, path, old_value, new_value, operation_id, sequence, kind)
end

local function enqueue_change_observation(state: InternalState, old_value: unknown, new_value: unknown, operation_id: string, kind: string)
	if next(state.change_observers) == nil then
		return
	end
	local old_json = copy_value(old_value)
	local new_json = copy_value(new_value)
	local events: { ChangeEvent } = {}
	local complete = diff_change_events(
		events,
		old_json,
		new_json,
		{},
		operation_id,
		state.change_sequence,
		kind
	)
	if not complete then
		state.change_events_dropped += 1
		events = {}
		events[1] = {
			OperationId = operation_id,
			Sequence = state.change_sequence,
			Path = {},
			OldValue = old_json,
			NewValue = new_json,
			Truncated = true,
			Kind = kind,
		}
	end
	local queued_events = if state.change_dispatch_tail >= state.change_dispatch_head then state.change_dispatch_tail - state.change_dispatch_head + 1 else 0
	if queued_events + #events > CHANGE_DISPATCH_QUEUE_CAPACITY then
		state.change_events_dropped += #events
		state.change_dispatch_queue = {}
		state.change_dispatch_head = 1
		state.change_dispatch_tail = 1
		state.change_dispatch_queue[1] = {
			OperationId = operation_id,
			Sequence = state.change_sequence,
			Path = {},
			OldValue = old_json,
			NewValue = new_json,
			Truncated = true,
			Kind = kind,
		}
	else
		for _, event in ipairs(events) do
			state.change_dispatch_tail += 1
			state.change_dispatch_queue[state.change_dispatch_tail] = event
		end
	end
	if state.change_dispatch_running or state.change_dispatch_head > state.change_dispatch_tail then
		return
	end
	state.change_dispatch_running = true
	task.spawn(function()
		while state.change_dispatch_head <= state.change_dispatch_tail and not state.retired do
			local event = state.change_dispatch_queue[state.change_dispatch_head]
			state.change_dispatch_queue[state.change_dispatch_head] = nil
			state.change_dispatch_head += 1
			if event ~= nil then
				for _, observer in pairs(state.change_observers) do
					local thread = coroutine.create(observer)
					local ok = coroutine.resume(thread, event)
					if not ok or coroutine.status(thread) ~= "dead" then
						coroutine.close(thread)
						state.observer_errors += 1
					end
				end
			end
		end
		state.change_dispatch_queue = {}
		state.change_dispatch_head = 1
		state.change_dispatch_tail = 0
		state.change_dispatch_running = false
	end)
end

local function budget_available(request_type: Enum.DataStoreRequestType): boolean?
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(request_type)
	end)
	if not ok or type(budget) ~= "number" then
		return nil
	end
	return budget >= 1
end

local function acquire_slot(deadline: number): boolean
	while active_requests >= DEFAULT_MAX_CONCURRENT_REQUESTS and now_local() < deadline do
		task.wait(0.05)
	end
	if active_requests >= DEFAULT_MAX_CONCURRENT_REQUESTS then
		return false
	end
	active_requests += 1
	return true
end

local function release_slot()
	active_requests = math.max(0, active_requests - 1)
end

local function acquire_request(state: InternalState?, deadline: number, update: boolean, request_type: Enum.DataStoreRequestType?): boolean
	if not acquire_slot(deadline) then
		return false
	end
	local wait_seconds = if state ~= nil then state.options.budget_wait or DEFAULT_BUDGET_WAIT else DEFAULT_BUDGET_WAIT
	local wait_deadline = math.min(deadline, now_local() + wait_seconds)
	while now_local() < wait_deadline do
		if request_type ~= nil then
			local available = budget_available(request_type)
			if available ~= false then
				return true
			end
		else
			local read_available = budget_available(Enum.DataStoreRequestType.StandardRead)
			local write_available = if update then budget_available(Enum.DataStoreRequestType.StandardWrite) else true
			if read_available ~= false and write_available ~= false then
				return true
			end
		end
		task.wait(0.05)
	end
	local available = if request_type ~= nil
		then budget_available(request_type)
		else budget_available(Enum.DataStoreRequestType.StandardRead) ~= false
		and (not update or budget_available(Enum.DataStoreRequestType.StandardWrite) ~= false)
	if available == false then
		release_slot()
		return false
	end
	return true
end

local function backend_info_from_key_info(key_info: DataStoreKeyInfo?): BackendInfo?
	if key_info == nil then
		return nil
	end
	local user_ids: { number } = {}
	for _, user_id in ipairs(key_info:GetUserIds()) do
		if type(user_id) == "number" then
			user_ids[#user_ids + 1] = user_id
		end
	end
	local metadata: Metadata = {}
	local preserved_metadata: Metadata = {}
	local raw_metadata = key_info:GetMetadata()
	for key, value in pairs(raw_metadata) do
		if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
			preserved_metadata[key] = value
			if string.sub(key, 1, 5) ~= "__rs:" then
				metadata[key] = value
			end
		end
	end
	return {
		Version = key_info.Version,
		CreatedTime = key_info.CreatedTime,
		UpdatedTime = key_info.UpdatedTime,
		UserIds = user_ids,
		Metadata = metadata,
		RawMetadata = preserved_metadata,
	}
end

local function make_mock_store_id(name: string, scope: string): string
	return HttpService:JSONEncode({ name, scope })
end

local function get_mock_store(name: string, scope: string): { [string]: MockEntry }
	local store_id = make_mock_store_id(name, scope)
	local store = mock_database[store_id]
	if store == nil then
		store = {}
		mock_database[store_id] = store
	end
	return store
end

local function make_backend(name: string, scope: string, key: string, mock: boolean): Backend
	return {
		name = name,
		scope = scope,
		key = key,
		store = if mock then nil else DataStoreService:GetDataStore(name, scope),
		mock = mock,
	}
end

local function backend_get(backend: Backend, use_cache: boolean, deadline: number, request_state: InternalState?): (unknown, BackendInfo?, ResultCode?, string?)
	if backend.mock then
		local store = get_mock_store(backend.name, backend.scope)
		local entry = store[backend.key]
		if entry == nil then
			return nil, nil, nil, nil
		end
		return copy_value(entry.Value), {
			Version = entry.Version,
			CreatedTime = entry.CreatedTime,
			UpdatedTime = entry.UpdatedTime,
			UserIds = clone_user_ids(entry.UserIds),
			Metadata = clone_metadata(entry.Metadata),
			RawMetadata = clone_metadata(entry.Metadata),
		}, nil, nil
	end
	local store = backend.store
	if store == nil then
		return nil, nil, "invalid", "backend store is missing"
	end
	local options = Instance.new("DataStoreGetOptions")
	options.UseCache = use_cache
	if not acquire_request(request_state, deadline, false, Enum.DataStoreRequestType.StandardRead) then
		return nil, nil, "budget", "read request deadline exceeded"
	end
	local ok, raw, key_info = pcall(function()
		return store:GetAsync(backend.key, options)
	end)
	release_slot()
	if not ok then
		return nil, nil, "unknown", tostring(raw)
	end
	return raw, backend_info_from_key_info(key_info), nil, nil
end

local function mock_write_version(entry: MockEntry?, value: JsonValue?, user_ids: { number }, metadata: Metadata, deleted: boolean): MockEntry
	mock_counter += 1
	local now = DateTime.now().UnixTimestampMillis
	local version = ("mock-%d-%s"):format(mock_counter, HttpService:GenerateGUID(false))
	local created_time = if entry ~= nil then entry.CreatedTime else now
	local next_entry: MockEntry = if entry ~= nil
		then entry
		else {
			Value = nil,
			UserIds = {},
			Metadata = {},
			Version = "",
			CreatedTime = now,
			UpdatedTime = now,
			Versions = {},
			VersionOrder = {},
		}
	next_entry.Value = copy_value(value)
	next_entry.UserIds = clone_user_ids(user_ids)
	next_entry.Metadata = clone_metadata(metadata)
	next_entry.Version = version
	next_entry.CreatedTime = created_time
	next_entry.UpdatedTime = now
	next_entry.Versions[version] = {
		Version = version,
		CreatedTime = now,
		UpdatedTime = now,
		Value = copy_value(value),
		UserIds = clone_user_ids(user_ids),
		Metadata = clone_metadata(metadata),
		Deleted = deleted,
	}
	next_entry.VersionOrder[#next_entry.VersionOrder + 1] = version
	return next_entry
end

local function backend_update(backend: Backend, transform: UpdateTransform, deadline: number, request_state: InternalState?): (unknown, BackendInfo?, ResultCode?, string?)
	if request_state ~= nil and request_state.retired then
		return nil, nil, "invalid", "record has been retired"
	end
	if backend.mock then
		if mock_update_failure_count > 0 then
			mock_update_failure_count -= 1
			return nil, nil, mock_update_failure_code, mock_update_failure_message
		end
		local store = get_mock_store(backend.name, backend.scope)
		local entry = store[backend.key]
		local raw = if entry ~= nil then copy_value(entry.Value) else nil
		local info: BackendInfo? = if entry ~= nil
			then {
				Version = entry.Version,
				CreatedTime = entry.CreatedTime,
				UpdatedTime = entry.UpdatedTime,
				UserIds = clone_user_ids(entry.UserIds),
				Metadata = clone_metadata(entry.Metadata),
				RawMetadata = clone_metadata(entry.Metadata),
			}
			else nil
		local replay_count = mock_update_replay_retries
		local replay_advance = mock_update_replay_advance_seconds
		mock_update_replay_retries = 0
		mock_update_replay_advance_seconds = 0
		local ok = true
		local new_value: unknown = nil
		local user_ids: { number }? = nil
		local metadata: Metadata? = nil
		for _ = 0, replay_count do
			ok, new_value, user_ids, metadata = pcall(transform, raw, info)
			if not ok then
				return nil, nil, "unknown", tostring(new_value)
			end
			mock_test_clock_offset += replay_advance
		end
		if new_value == nil then
			return raw, info, nil, nil
		end
		local normalized_user_ids = user_ids or (if info ~= nil then info.UserIds else {})
		local normalized_metadata = metadata or (if info ~= nil then info.Metadata else {})
		local ids, ids_error = normalize_user_ids(normalized_user_ids)
		if ids == nil then
			return nil, nil, "validation", ids_error
		end
		local metadata_ok, metadata_error = validate_metadata(normalized_metadata, true)
		if not metadata_ok then
			return nil, nil, "validation", metadata_error
		end
		local stored_new_value = encode_backend_update_value(new_value)
		local value = copy_value(stored_new_value)
		if value == nil then
			return nil, nil, "validation", "updated value is invalid"
		end
		if request_state ~= nil and request_state.retired then
			return nil, nil, "invalid", "record has been retired"
		end
		local data_ok, data_error = validate_serialized_size(value)
		if not data_ok then
			return nil, nil, "validation", data_error
		end
		local next_entry = mock_write_version(entry, value, ids, normalized_metadata, false)
		store[backend.key] = next_entry
		return copy_value(next_entry.Value), {
			Version = next_entry.Version,
			CreatedTime = next_entry.CreatedTime,
			UpdatedTime = next_entry.UpdatedTime,
			UserIds = clone_user_ids(next_entry.UserIds),
			Metadata = clone_metadata(next_entry.Metadata),
			RawMetadata = clone_metadata(next_entry.Metadata),
		}, nil, nil
	end
	local store = backend.store
	if store == nil then
		return nil, nil, "invalid", "backend store is missing"
	end
	if not acquire_request(request_state, deadline, true, nil) then
		return nil, nil, "budget", "update request deadline exceeded"
	end
	local ok, result, key_info = pcall(function()
		return store:UpdateAsync(backend.key, function(raw, key_info)
			local info = backend_info_from_key_info(key_info)
			local new_value, user_ids, metadata = transform(raw, info)
			return encode_backend_update_value(new_value), user_ids, metadata
		end)
	end)
	release_slot()
	if not ok then
		return nil, nil, "unknown", tostring(result)
	end
	return result, backend_info_from_key_info(key_info), nil, nil
end
local function get_string_field(value: unknown, key: string): unknown
	if type(value) ~= "table" then
		return nil
	end
	return rawget(value, key)
end
local function parse_envelope(raw: unknown): (Envelope?, string?, boolean)
	if raw == nil then
		return nil, nil, true
	end
	if type(raw) ~= "table" then
		return nil, "legacy payload", false
	end
	local stored_implementation_version = get_string_field(raw, "implementation_version")
	local stored_fencing_generation = get_string_field(raw, "fencing_generation")
	local legacy_generation = get_string_field(raw, "generation")
	local legacy_payload = get_string_field(raw, "payload")
	local legacy_deleted = get_string_field(raw, "deleted")
	local legacy_format = get_string_field(raw, "format")
	local legacy_operation_id = get_string_field(raw, "last_operation_id")
	local legacy_lease = get_string_field(raw, "lease")
	if stored_implementation_version ~= nil
		and stored_fencing_generation == nil
		and legacy_generation ~= nil
		and legacy_format ~= nil
		and legacy_deleted ~= nil
		and legacy_operation_id ~= nil
	then
		if legacy_format ~= "RecordStore" then
			local format_detail = string.gsub(tostring(legacy_format), "%c", " ")
			format_detail = string.sub(format_detail, 1, 80)
			return nil, ("unsupported legacy RecordStore format: expected string RecordStore, got type=%s value=%s"):format(
				type(legacy_format),
				format_detail
			), false
		end
		if legacy_lease ~= nil then
			return nil, "legacy RecordStore envelope contains a lease; automatic migration is refused because its ownership state cannot be verified", false
		end
		if type(legacy_generation) ~= "number"
			or not math.isfinite(legacy_generation)
			or math.floor(legacy_generation) ~= legacy_generation
			or legacy_generation < 0
		then
			return nil, "invalid legacy generation", false
		end
		if type(legacy_deleted) ~= "boolean" then
			return nil, "invalid legacy deleted flag", false
		end
		if type(legacy_operation_id) ~= "string" or legacy_operation_id == "" then
			return nil, "invalid legacy last_operation_id", false
		end
		local legacy_schema_version = get_string_field(raw, "schema_version")
		local legacy_revision = get_string_field(raw, "revision")
		local legacy_created_at = get_string_field(raw, "created_at")
		local legacy_updated_at = get_string_field(raw, "updated_at")
		local legacy_user_ids = get_string_field(raw, "user_ids")
		if type(legacy_schema_version) ~= "number"
			or not math.isfinite(legacy_schema_version)
			or math.floor(legacy_schema_version) ~= legacy_schema_version
			or legacy_schema_version < 0
		then
			return nil, "invalid legacy schema version", false
		end
		if type(legacy_revision) ~= "number"
			or not math.isfinite(legacy_revision)
			or math.floor(legacy_revision) ~= legacy_revision
			or legacy_revision < 0
		then
			return nil, "invalid legacy revision", false
		end
		if type(legacy_created_at) ~= "number"
			or not math.isfinite(legacy_created_at)
			or type(legacy_updated_at) ~= "number"
			or not math.isfinite(legacy_updated_at)
			or legacy_updated_at < legacy_created_at
		then
			return nil, "invalid legacy timestamps", false
		end
		if legacy_deleted and legacy_generation < 1 then
			return nil, "deleted legacy record has no valid fencing generation", false
		end
		if not legacy_deleted and legacy_payload == nil then
			return nil, "non-deleted legacy record is missing payload", false
		end
		local canonical_legacy: { [string]: unknown } = {
			implementation_version = stored_implementation_version,
			schema_version = legacy_schema_version,
			revision = legacy_revision,
			fencing_generation = legacy_generation,
			created_at = legacy_created_at,
			updated_at = legacy_updated_at,
			data = if legacy_deleted then nil else legacy_payload,
			user_ids = legacy_user_ids,
			tombstone = if legacy_deleted then { deleted_at = legacy_updated_at, generation = legacy_generation } else nil,
			session = nil,
			write_id = legacy_operation_id,
		}
		return parse_envelope(canonical_legacy)
	end

	local implementation_version = get_string_field(raw, "implementation_version")
	local schema_version = get_string_field(raw, "schema_version")
	local revision = get_string_field(raw, "revision")
	local fencing_generation = get_string_field(raw, "fencing_generation")
	local created_at = get_string_field(raw, "created_at")
	local updated_at = get_string_field(raw, "updated_at")
	local write_id = get_string_field(raw, "write_id")
	local raw_data = get_string_field(raw, "data")
	local raw_non_finite_numbers = get_string_field(raw, "non_finite_numbers")
	local data: JsonValue? = nil

	if raw_data ~= nil then
		local copied_data = copy_value(raw_data)
		if copied_data == nil then
			return nil, "invalid stored data", false
		end
		data = copied_data
	end
	local raw_user_ids = get_string_field(raw, "user_ids")
	local raw_tombstone = get_string_field(raw, "tombstone")
	local raw_session = get_string_field(raw, "session")
	if implementation_version == nil then
		local legacy_marker = get_string_field(raw, "__recordStore")
		if legacy_marker == "RecordStore" then
			local legacy_format = get_string_field(raw, "format")
			local legacy_revision = get_string_field(raw, "revision")
			local legacy_fence = get_string_field(raw, "fence")
			local legacy_commit_id = get_string_field(raw, "commitId")
			local legacy_deleted = get_string_field(raw, "deleted")
			local legacy_schema_version = get_string_field(raw, "version")

			if legacy_format ~= 1
				or type(legacy_revision) ~= "number"
				or not math.isfinite(legacy_revision)
				or math.floor(legacy_revision) ~= legacy_revision
				or legacy_revision < 0
				or type(legacy_fence) ~= "string"
				or legacy_fence == ""
				or type(legacy_commit_id) ~= "string"
				or legacy_commit_id == ""
				or type(legacy_deleted) ~= "boolean"
				or type(legacy_schema_version) ~= "number"
				or not math.isfinite(legacy_schema_version)
				or math.floor(legacy_schema_version) ~= legacy_schema_version
				or legacy_schema_version < 0
			then
				return nil, "malformed legacy RecordStore envelope", false
			end

			if legacy_deleted then
				if raw_data ~= nil then
					return nil, "deleted legacy RecordStore envelope unexpectedly contains data", false
				end
				return {
					implementation_version = IMPLEMENTATION_VERSION,
					schema_version = legacy_schema_version,
					revision = legacy_revision,
					fencing_generation = 1,
					created_at = 0,
					updated_at = 0,
					data = nil,
					user_ids = nil,
					tombstone = {
						deleted_at = 0,
						generation = 1,
					},
					session = nil,
					write_id = legacy_commit_id,
				}, nil, true
			end

			if data == nil then
				return nil, "non-deleted legacy RecordStore envelope is missing data", false
			end

			return {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = legacy_schema_version,
				revision = legacy_revision,
				fencing_generation = 1,
				created_at = 0,
				updated_at = 0,
				data = data,
				user_ids = nil,
				tombstone = nil,
				session = nil,
				write_id = legacy_commit_id,
			}, nil, true
		end

		if schema_version ~= nil or revision ~= nil or fencing_generation ~= nil or raw_session ~= nil or write_id ~= nil then
			return nil, "malformed RecordStore envelope", false
		end
		return nil, "legacy payload", false
	end
	if type(implementation_version) ~= "number" or not math.isfinite(implementation_version) or math.floor(implementation_version) ~= implementation_version then
		return nil, "invalid implementation version", false
	end
	if implementation_version > IMPLEMENTATION_VERSION then
		return nil, "future implementation version", false
	end
	if implementation_version >= 2 and raw_non_finite_numbers == nil then
		return nil, "version 2 envelope is missing non-finite number metadata", false
	end
	if implementation_version < 1 then
		return nil, "unsupported implementation version", false
	end
	if type(schema_version) ~= "number" or not math.isfinite(schema_version) or math.floor(schema_version) ~= schema_version or schema_version < 0 then
		return nil, "invalid schema version", false
	end
	if type(revision) ~= "number" or not math.isfinite(revision) or math.floor(revision) ~= revision or revision < 0 then
		return nil, "invalid revision", false
	end
	if type(fencing_generation) ~= "number" then
		local key_names: { string } = {}
		for child_key in raw do
			if type(child_key) == "string" then
				key_names[#key_names + 1] = child_key
			end
		end
		table.sort(key_names)
		while #key_names > 24 do
			table.remove(key_names)
		end
		return nil, ("invalid fencing generation: expected number, got %s; aliases generation=%s fence=%s; envelope keys={%s}"):format(
			type(fencing_generation),
			type(get_string_field(raw, "generation")),
			type(get_string_field(raw, "fence")),
			table.concat(key_names, ",")
		), false
	end
	if not math.isfinite(fencing_generation) then
		return nil, "invalid fencing generation: number is not finite", false
	end
	if math.floor(fencing_generation) ~= fencing_generation then
		return nil, "invalid fencing generation: number is not an integer", false
	end
	if fencing_generation < 0 then
		return nil, "invalid fencing generation: number is negative", false
	end
	if type(created_at) ~= "number" or not math.isfinite(created_at) or type(updated_at) ~= "number" or not math.isfinite(updated_at) then
		return nil, "invalid timestamps", false
	end
	if updated_at < created_at then
		return nil, "updated timestamp precedes created timestamp", false
	end
	if type(write_id) ~= "string" or write_id == "" then
		return nil, "invalid write id", false
	end
	if data ~= nil then
		local ok = pcall(function()
			HttpService:JSONEncode(data)
		end)
		if not ok then
			return nil, "invalid stored data", false
		end
	end
	local ids: { number }? = nil
	if raw_user_ids ~= nil then
		if type(raw_user_ids) ~= "table" then
			return nil, "invalid user_ids", false
		end
		local candidates: { number } = {}
		for index, value in raw_user_ids do
			if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or type(value) ~= "number" then
				return nil, "invalid user_ids", false
			end
			candidates[index] = value
		end
		local normalized, ids_error = normalize_user_ids(candidates)
		if normalized == nil then
			return nil, ids_error or "invalid user_ids", false
		end
		ids = normalized
	end
	local tombstone: Tombstone? = nil
	if raw_tombstone ~= nil then
		if type(raw_tombstone) ~= "table" then
			return nil, "invalid tombstone", false
		end
		local deleted_at = get_string_field(raw_tombstone, "deleted_at")
		local generation = get_string_field(raw_tombstone, "generation")
		if type(deleted_at) ~= "number" or not math.isfinite(deleted_at) or type(generation) ~= "number" or not math.isfinite(generation) or math.floor(generation) ~= generation or generation < 1 then
			return nil, "invalid tombstone", false
		end
		tombstone = {
			deleted_at = deleted_at,
			generation = generation,
		}
	end
	local session: SessionEnvelope? = nil
	if raw_session ~= nil then
		if type(raw_session) ~= "table" then
			return nil, "invalid session", false
		end
		local token = get_string_field(raw_session, "token")
		local generation = get_string_field(raw_session, "generation")
		local job_id = get_string_field(raw_session, "job_id")
		local place_id = get_string_field(raw_session, "place_id")
		local acquired_at = get_string_field(raw_session, "acquired_at")
		local lease_until = get_string_field(raw_session, "lease_until")
		if type(token) ~= "string" or token == "" or type(generation) ~= "number" or not math.isfinite(generation) or math.floor(generation) ~= generation or generation < 1 or type(job_id) ~= "string" or job_id == "" or type(place_id) ~= "number" or not math.isfinite(place_id) or place_id < 0 or math.floor(place_id) ~= place_id or type(acquired_at) ~= "number" or not math.isfinite(acquired_at) or type(lease_until) ~= "number" or not math.isfinite(lease_until) then
			return nil, "invalid session", false
		end

		if lease_until < acquired_at then
			return nil, "session lease precedes acquisition", false
		end

		session = {
			token = token,
			generation = generation,
			job_id = job_id,
			place_id = place_id,
			acquired_at = acquired_at,
			lease_until = lease_until,
		}
	end
	if fencing_generation == 0 and (tombstone ~= nil or session ~= nil) then
		return nil, "zero fencing generation is only valid for an inactive non-tombstoned envelope", false
	end
	if tombstone ~= nil and tombstone.generation ~= fencing_generation then
		return nil, "tombstone generation does not match fencing generation", false
	end
	if tombstone == nil and data == nil then
		return nil, "non-tombstoned envelope is missing data", false
	end
	if tombstone ~= nil and (data ~= nil or session ~= nil) then
		return nil, "tombstoned envelope contains data or a session", false
	end
	if session ~= nil and session.generation ~= fencing_generation then
		return nil, "session generation does not match fencing generation", false
	end
	local restored_data = data
	if raw_non_finite_numbers ~= nil then
		if data == nil then
			if type(raw_non_finite_numbers) ~= "table" or next(raw_non_finite_numbers) ~= nil then
				return nil, "tombstoned envelope has invalid non-finite number metadata", false
			end
		else
			local decoded, decode_error = restore_non_finite_numbers(data, raw_non_finite_numbers)
			if decoded == nil then
				return nil, decode_error or "invalid non-finite number metadata", false
			end
			restored_data = decoded
		end
	end

	return {
		implementation_version = IMPLEMENTATION_VERSION,
		schema_version = schema_version,
		revision = revision,
		fencing_generation = fencing_generation,
		created_at = created_at,
		updated_at = updated_at,
		data = restored_data,
		user_ids = ids,
		tombstone = tombstone,
		session = session,
		write_id = write_id,
	}, nil, true
end

local function matches_session(envelope: Envelope, token: string, generation: number): boolean
	return envelope.session ~= nil and envelope.session.token == token and envelope.session.generation == generation and envelope.fencing_generation == generation
end

local function apply_migrations(state: InternalState, from_version: number, value: JsonValue): (JsonValue?, string?)
	if from_version > state.options.schema_version then
		return nil, "stored schema is newer than this server supports"
	end
	local current = value
	if from_version == state.options.schema_version then
		return current, nil
	end
	if state.options.migrations == nil then
		return nil, "required migration is missing"
	end
	for version = from_version, state.options.schema_version - 1 do
		local migration = state.options.migrations[version]
		if migration == nil then
			return nil, "required migration is missing at version " .. tostring(version)
		end
		local next_value, migration_error = run_migration(migration, version, current)
		if next_value == nil then
			return nil, migration_error or "migration failed"
		end
		current = next_value
	end
	return current, nil
end

local function update_local_from_envelope(state: InternalState, envelope: Envelope, info: BackendInfo?)
	state.data = copy_value(envelope.data)
	state.public_data_source = copy_value(state.data)
	if state.public_record ~= nil then
		state.public_record.Data = state.data
	end
	state.generation = envelope.fencing_generation
	state.revision = envelope.revision
	state.created_at = envelope.created_at
	state.updated_at = envelope.updated_at
	state.user_ids = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {}
	state.metadata = if info ~= nil then clone_metadata(info.Metadata) else state.metadata
	state.tombstoned = envelope.tombstone ~= nil
	state.token = if envelope.session ~= nil then envelope.session.token else nil
	state.durable_lease_until = if envelope.session ~= nil then envelope.session.lease_until else 0
	state.last_observed = now_unix()
	if envelope.session ~= nil then
		state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
	else
		state.next_renewal = math.huge
	end
	state.save_requested = false
end

local function make_durable_snapshot(envelope: Envelope, info: BackendInfo?, reason: string): DurableSnapshot
	return {
		Data = copy_value(envelope.data),
		Revision = envelope.revision,
		Generation = envelope.fencing_generation,
		UpdatedAt = envelope.updated_at,
		ConfirmedAt = now_unix(),
		WriteId = envelope.write_id,
		Reason = reason,
		Tombstoned = envelope.tombstone ~= nil,
		UserIds = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {},
		Metadata = if info ~= nil then clone_metadata(info.Metadata) else {},
		BackendVersion = if info ~= nil then info.Version else nil,
		BackendCreatedAt = if info ~= nil then info.CreatedTime else nil,
		BackendUpdatedAt = if info ~= nil then info.UpdatedTime else nil,
	}
end

local function clone_durable_snapshot(snapshot: DurableSnapshot?): DurableSnapshot?
	if snapshot == nil then
		return nil
	end
	return {
		Data = copy_value(snapshot.Data),
		Revision = snapshot.Revision,
		Generation = snapshot.Generation,
		UpdatedAt = snapshot.UpdatedAt,
		ConfirmedAt = snapshot.ConfirmedAt,
		WriteId = snapshot.WriteId,
		Reason = snapshot.Reason,
		Tombstoned = snapshot.Tombstoned,
		UserIds = clone_user_ids(snapshot.UserIds),
		Metadata = clone_metadata(snapshot.Metadata),
		BackendVersion = snapshot.BackendVersion,
		BackendCreatedAt = snapshot.BackendCreatedAt,
		BackendUpdatedAt = snapshot.BackendUpdatedAt,
	}
end

local function snapshot_from_envelope(key: string, envelope: Envelope, info: BackendInfo?): Snapshot
	local session = envelope.session
	local session_active = session ~= nil and session.lease_until > now_unix()
	return {
		Data = copy_value(envelope.data),
		State = if envelope.tombstone ~= nil then "tombstoned" elseif session_active then "active" else "closed",
		Key = key,
		SchemaVersion = envelope.schema_version,
		Generation = envelope.fencing_generation,
		Revision = envelope.revision,
		CreatedAt = envelope.created_at,
		UpdatedAt = envelope.updated_at,
		Tombstoned = envelope.tombstone ~= nil,
		SessionActive = session_active,
		LeaseUntil = if session ~= nil then session.lease_until else nil,
		SessionJobId = if session ~= nil then session.job_id else nil,
		SessionPlaceId = if session ~= nil then session.place_id else nil,
		UserIds = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {},
		Metadata = if info ~= nil then clone_metadata(info.Metadata) else {},
		BackendVersion = if info ~= nil then info.Version else nil,
		BackendCreatedAt = if info ~= nil then info.CreatedTime else nil,
		BackendUpdatedAt = if info ~= nil then info.UpdatedTime else nil,
	}
end

local function validate_envelope(envelope: Envelope): (boolean, string?)
	prepared_envelope_cache[envelope] = nil
	local prepared = encode_envelope_for_storage(envelope)
	local valid, message = validate_serialized_size(prepared)
	if valid then
		prepared_envelope_cache[envelope] = prepared
	end
	return valid, message
end

local function decode_legacy_read(raw: unknown, decoder: LegacyDecoder?): (Envelope?, string?)
	if decoder == nil then
		return nil, "legacy payload requires a legacy_decoder"
	end
	local value, version, decoder_error = run_legacy_decoder(decoder, raw)
	if value == nil then
		return nil, decoder_error or "legacy decoder failed"
	end
	return {
		implementation_version = IMPLEMENTATION_VERSION,
		schema_version = version or 0,
		revision = 0,
		fencing_generation = 0,
		created_at = 0,
		updated_at = 0,
		data = value,
		user_ids = nil,
		tombstone = nil,
		session = nil,
		write_id = "legacy",
	}, nil
end

local function make_queue_envelope(
	owner: QueueOwner,
	messages: { QueueItem },
	dead_letters: { DeadLetterItem }?
): QueueEnvelope
	return {
		implementation_version = QUEUE_IMPLEMENTATION_VERSION,
		owner = owner,
		messages = messages,
		dead_letters = dead_letters or {},
	}
end

local function parse_queue_messages(raw: unknown, expected_version: number): ({ QueueItem }?, string?)
	if raw == nil then
		return {}, nil
	end
	if type(raw) ~= "table" then
		return nil, "durable queue is corrupt"
	end
	local implementation_version = get_string_field(raw, "implementation_version")
	local messages_value = get_string_field(raw, "messages")
	if implementation_version ~= expected_version or type(messages_value) ~= "table" then
		return nil, "durable queue is corrupt"
	end
	local messages = messages_value :: { [number]: unknown }
	local result: { QueueItem } = {}
	local seen_ids: { [string]: boolean } = {}
	local length = #messages
	local count = 0
	for index, item in messages do
		if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or index > length then
			return nil, "durable queue message list must be a dense array"
		end
		count += 1
		if type(item) ~= "table" then
			return nil, "durable queue contains an invalid message"
		end
		local id = get_string_field(item, "id")
		local message_type = get_string_field(item, "type")
		local attempts = get_string_field(item, "attempts")
		local total_attempts_raw = get_string_field(item, "total_attempts")
		local replay_count_raw = get_string_field(item, "replay_count")
		local sender_job_id = get_string_field(item, "sender_job_id")
		local created_at = get_string_field(item, "created_at")
		local locked_until = get_string_field(item, "locked_until")
		local total_attempts = if total_attempts_raw == nil then attempts else total_attempts_raw
		local replay_count = if replay_count_raw == nil then 0 else replay_count_raw
		if type(id) ~= "string"
			or id == ""
			or #id > 100
			or type(message_type) ~= "string"
			or message_type == ""
			or #message_type > MAX_MESSAGE_TYPE_LENGTH
			or type(attempts) ~= "number"
			or not math.isfinite(attempts)
			or math.floor(attempts) ~= attempts
			or attempts < 0
			or type(total_attempts) ~= "number"
			or not math.isfinite(total_attempts)
			or math.floor(total_attempts) ~= total_attempts
			or total_attempts < attempts
			or type(replay_count) ~= "number"
			or not math.isfinite(replay_count)
			or math.floor(replay_count) ~= replay_count
			or replay_count < 0
			or type(sender_job_id) ~= "string"
			or sender_job_id == ""
			or type(created_at) ~= "number"
			or not math.isfinite(created_at)
			or type(locked_until) ~= "number"
			or not math.isfinite(locked_until)
		then
			return nil, "durable queue contains an invalid message"
		end
		if seen_ids[id] then
			return nil, "durable queue contains a duplicate message ID"
		end
		seen_ids[id] = true
		local lock_token = get_string_field(item, "lock_token")
		if lock_token ~= nil and (type(lock_token) ~= "string" or lock_token == "" or #lock_token > 100) then
			return nil, "durable queue contains an invalid lock token"
		end
		local last_replay_token = get_string_field(item, "last_replay_token")
		if last_replay_token ~= nil and (type(last_replay_token) ~= "string" or last_replay_token == "" or #last_replay_token > 100) then
			return nil, "durable queue contains an invalid replay token"
		end
		local data = get_string_field(item, "data")
		if data ~= nil then
			local valid, message = validate_serialized_size(data)
			if not valid then
				return nil, message or "durable queue data is invalid"
			end
		end
		result[#result + 1] = {
			id = id,
			type = message_type,
			data = copy_value(data),
			attempts = attempts,
			total_attempts = total_attempts,
			replay_count = replay_count,
			last_replay_token = last_replay_token,
			sender_job_id = sender_job_id,
			created_at = created_at,
			locked_until = locked_until,
			lock_token = lock_token,
		}
	end
	if count ~= length then
		return nil, "durable queue message list must be a dense array"
	end
	return result, nil
end

local function parse_queue_envelope(
	raw: unknown,
	expected_owner: QueueOwner
): (QueueEnvelope?, string?, boolean?)
	if raw == nil then
		return make_queue_envelope(expected_owner, {}), nil, false
	end
	if type(raw) ~= "table" then
		return nil, "durable queue is corrupt", false
	end
	local implementation_version = get_string_field(raw, "implementation_version")
	if type(implementation_version) ~= "number" or (implementation_version ~= 2 and implementation_version ~= QUEUE_IMPLEMENTATION_VERSION) then
		return nil, "durable queue is corrupt", false
	end
	local queue_version: number = implementation_version
	local owner = get_string_field(raw, "owner")
	if type(owner) ~= "table" then
		return nil, "durable queue is corrupt: owner is missing", false
	end
	local owner_name = get_string_field(owner, "name")
	local owner_scope = get_string_field(owner, "scope")
	local owner_key = get_string_field(owner, "key")
	if type(owner_name) ~= "string"
		or type(owner_scope) ~= "string"
		or type(owner_key) ~= "string"
	then
		return nil, "durable queue is corrupt: owner identity is invalid", false
	end
	if owner_name ~= expected_owner.name
		or owner_scope ~= expected_owner.scope
		or owner_key ~= expected_owner.key
	then
		return nil, "durable queue belongs to a different record identity", true
	end
	local messages, parse_error = parse_queue_messages(raw, queue_version)
	if messages == nil then
		return nil, parse_error, false
	end
	local dead_letters: { DeadLetterItem } = {}
	local seen_ids: { [string]: boolean } = {}
	for _, item in ipairs(messages) do
		seen_ids[item.id] = true
	end
	if queue_version == QUEUE_IMPLEMENTATION_VERSION then
		local raw_dead_letters = get_string_field(raw, "dead_letters")
		if type(raw_dead_letters) ~= "table" then
			return nil, "durable queue dead-letter list is invalid", false
		end
		local length = #raw_dead_letters
		local count = 0
		for index, item in raw_dead_letters do
			if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or index > length then
				return nil, "durable queue dead-letter list must be a dense array", false
			end
			count += 1
			local parsed_messages, item_error = parse_queue_messages({
				implementation_version = QUEUE_IMPLEMENTATION_VERSION,
				messages = { item },
			}, QUEUE_IMPLEMENTATION_VERSION)
			if parsed_messages == nil or parsed_messages[1] == nil then
				return nil, item_error or "durable queue contains an invalid dead letter", false
			end
			local dead_lettered_at = get_string_field(item, "dead_lettered_at")
			local last_error = get_string_field(item, "last_error")
			local terminal_lock_token = get_string_field(item, "terminal_lock_token")
			if type(dead_lettered_at) ~= "number" or not math.isfinite(dead_lettered_at) or dead_lettered_at < 0
				or type(last_error) ~= "string" or #last_error > MAX_QUEUE_ERROR_LENGTH
				or (terminal_lock_token ~= nil and (type(terminal_lock_token) ~= "string" or terminal_lock_token == "" or #terminal_lock_token > 100))
			then
				return nil, "durable queue contains an invalid dead letter", false
			end
			local parsed = parsed_messages[1]
			if seen_ids[parsed.id] then
				return nil, "durable queue contains a duplicate message ID", false
			end
			seen_ids[parsed.id] = true
			dead_letters[#dead_letters + 1] = {
				id = parsed.id,
				type = parsed.type,
				data = parsed.data,
				attempts = parsed.attempts,
				total_attempts = parsed.total_attempts,
				replay_count = parsed.replay_count,
				last_replay_token = parsed.last_replay_token,
				sender_job_id = parsed.sender_job_id,
				created_at = parsed.created_at,
				locked_until = parsed.locked_until,
				lock_token = parsed.lock_token,
				dead_lettered_at = dead_lettered_at,
				last_error = last_error,
				terminal_lock_token = terminal_lock_token,
			}
		end
		if count ~= length then
			return nil, "durable queue dead-letter list must be a dense array", false
		end
	end
	return make_queue_envelope(expected_owner, messages, dead_letters), nil, false
end

local function parse_legacy_queue_envelope(raw: unknown): ({ QueueItem }?, string?)
	return parse_queue_messages(raw, 1)
end

local function read_queue_after_update(
	backend: Backend,
	returned_value: unknown,
	deadline: number,
	state: InternalState?,
	owner: QueueOwner
): (QueueEnvelope?, ResultCode?, string?)
	local value = returned_value
	if value == nil then
		local read_value, _, read_code, read_message = backend_get(backend, false, deadline, state)
		if read_code ~= nil then
			return nil, "unknown", "queue operation outcome could not be verified: " .. (read_message or read_code)
		end
		value = read_value
	end
	local queue, parse_message, owner_mismatch = parse_queue_envelope(value, owner)
	if queue == nil then
		return nil, if owner_mismatch then "conflict" else "corrupt", parse_message or "durable queue is corrupt"
	end
	return queue, nil, nil
end

local function queue_item_to_public(item: QueueItem): QueueMessage
	return {
		Id = item.id,
		Type = item.type,
		Data = copy_value(item.data),
		Attempts = item.attempts,
		TotalAttempts = item.total_attempts,
		ReplayCount = item.replay_count,
		SenderJobId = item.sender_job_id,
		CreatedAt = item.created_at,
	}
end

local function dead_letter_to_public(item: DeadLetterItem): DeadLetterMessage
	return {
		Id = item.id,
		Type = item.type,
		Data = copy_value(item.data),
		Attempts = item.attempts,
		TotalAttempts = item.total_attempts,
		ReplayCount = item.replay_count,
		SenderJobId = item.sender_job_id,
		CreatedAt = item.created_at,
		DeadLetteredAt = item.dead_lettered_at,
		LastError = item.last_error,
		LockToken = item.lock_token,
		LockedUntil = item.locked_until,
	}
end

local function ensure_legacy_queue_clear(
	name: string,
	scope: string,
	key: string,
	queue_store_name: string,
	mock: boolean,
	deadline: number,
	state: InternalState?
): (ResultCode?, string?)
	if state ~= nil and state.queue_legacy_checked then
		return nil, nil
	end
	local legacy_backend = make_backend(
		queue_store_name,
		scope,
		make_queue_key_legacy(name, scope, key),
		mock
	)
	local raw, _, read_code, read_message = backend_get(legacy_backend, false, deadline, state)
	if read_code ~= nil then
		return read_code, read_message
	end
	local messages, parse_message = parse_legacy_queue_envelope(raw)
	if messages == nil then
		return "corrupt", parse_message or "legacy durable queue is corrupt; it was left untouched"
	end
	if #messages > 0 then
		return "migration", "nonempty legacy durable queue has no verifiable owner; it was left untouched and requires manual recovery"
	end
	if state ~= nil then
		state.queue_legacy_checked = true
	end
	return nil, nil
end

local function queue_backend_for_state(state: InternalState): Backend?
	if not (state.options.durable_queue_enabled ~= false) then
		return nil
	end
	if state.queue_backend ~= nil then
		return state.queue_backend
	end
	local queue_store_name = state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME
	if #queue_store_name == 0 or #queue_store_name > 50 then
		return nil
	end
	state.queue_backend = make_backend(
		queue_store_name,
		state.scope,
		make_queue_key_v2(state.name, state.scope, state.key),
		state.backend.mock
	)
	return state.queue_backend
end

local function queue_size_error(queue: QueueEnvelope, max_bytes: number): string?
	local size_ok, size_message = validate_serialized_size(queue)
	if not size_ok then
		return size_message or "durable queue exceeds the DataStore value limit"
	end
	local encoded_ok, encoded = pcall(function()
		return HttpService:JSONEncode(queue)
	end)
	if not encoded_ok or type(encoded) ~= "string" then
		return "durable queue could not be encoded"
	end
	if #encoded > max_bytes then
		return "durable queue exceeds its configured size limit"
	end
	return nil
end

local function normalize_queue_error(message: string): string
	local printable = string.gsub(message, "[^ -~]", "?")
	return string.sub(printable, 1, MAX_QUEUE_ERROR_LENGTH)
end

local function claim_queue_message(state: InternalState): (QueueItem?, ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return nil, "invalid", "durable queue is disabled"
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return nil, migration_code, migration_message
	end
	local token = HttpService:GenerateGUID(false)
	local max_attempts = state.options.queue_max_attempts or DEFAULT_QUEUE_MAX_ATTEMPTS
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_messages = table.clone(queue.messages)
		local next_dead_letters = table.clone(queue.dead_letters)
		local changed = false
		local index = 1
		while index <= #next_messages do
			local item = next_messages[index]
			if item.locked_until <= transform_time and item.attempts >= max_attempts then
				table.remove(next_messages, index)
				next_dead_letters[#next_dead_letters + 1] = {
					id = item.id,
					type = item.type,
					data = copy_value(item.data),
					attempts = item.attempts,
					total_attempts = item.total_attempts,
					replay_count = item.replay_count,
					last_replay_token = item.last_replay_token,
					sender_job_id = item.sender_job_id,
					created_at = item.created_at,
					locked_until = 0,
					lock_token = nil,
					dead_lettered_at = transform_time,
					last_error = "processing lock expired after the maximum attempt count",
					terminal_lock_token = item.lock_token,
				}
				changed = true
			elseif item.locked_until <= transform_time then
				local next_item: QueueItem = {
					id = item.id,
					type = item.type,
					data = copy_value(item.data),
					attempts = item.attempts + 1,
					total_attempts = item.total_attempts + 1,
					replay_count = item.replay_count,
					last_replay_token = item.last_replay_token,
					sender_job_id = item.sender_job_id,
					created_at = item.created_at,
					locked_until = transform_time + (state.options.queue_lease_duration or DEFAULT_QUEUE_LEASE_DURATION),
					lock_token = token,
				}
				next_messages[index] = next_item
				changed = true
				local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
				local size_error = queue_size_error(next_queue, max_bytes)
				if size_error ~= nil then
					decision = "validation"
					decision_message = "queue claim was not applied: " .. size_error
					return nil, nil, nil
				end
				decision = "success"
				return next_queue, nil, nil
			else
				index += 1
			end
		end
		if changed then
			local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
			local size_error = queue_size_error(next_queue, max_bytes)
			if size_error ~= nil then
				decision = "validation"
				decision_message = "queue claim was not applied: " .. size_error
				return nil, nil, nil
			end
			decision = "success"
			return next_queue, nil, nil
		end
		return nil, nil, nil
	end, deadline, state)
	if result_code ~= nil then
		return nil, result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return nil, verify_code or "unknown", verify_message
	end
	local verification_time = queue_now_unix(backend.mock)
	for _, item in ipairs(queue.messages) do
		if item.lock_token == token and item.locked_until > verification_time then
			return item, "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return nil, decision, decision_message or result_message
	end
	return nil, "empty", nil
end

local function acknowledge_queue_message(state: InternalState, message_id: string, lock_token: string): (ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return migration_code, migration_message
	end
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_messages: { QueueItem } = {}
		local found = false
		for _, item in ipairs(queue.messages) do
			if item.id == message_id and item.lock_token == lock_token and item.locked_until > transform_time then
				found = true
			else
				next_messages[#next_messages + 1] = item
			end
		end
		if not found then
			return nil, nil, nil
		end
		local next_queue = make_queue_envelope(owner, next_messages, queue.dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			return nil, nil, nil
		end
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil then
		return result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return verify_code or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id then
			return "conflict", "durable queue message is still present and is no longer owned by this acknowledgement"
		end
	end
	for _, item in ipairs(queue.dead_letters) do
		if item.id == message_id then
			return "conflict", "durable queue message moved to the dead-letter list before acknowledgement"
		end
	end
	return "success", nil
end

local function enqueue_internal(state: InternalState, message_type: string, data: JsonValue?): (ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	if type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH then
		return "invalid", "message_type must be 1 to 100 characters"
	end
	local frozen_data: JsonValue? = nil
	if data ~= nil then
		local copied_ok, copied_or_error = pcall(function()
			return copy_value(data)
		end)
		if not copied_ok or copied_or_error == nil then
			return "validation", "queue data is invalid"
		end
		frozen_data = copied_or_error
		local valid, message = validate_serialized_size(frozen_data)
		if not valid then
			return "validation", message
		end
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return migration_code, migration_message
	end
	local message_id = HttpService:GenerateGUID(false)
	local created_at = queue_now_unix(backend.mock)
	local max_messages = state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil or #queue.messages >= max_messages then
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		next_messages[#next_messages + 1] = {
			id = message_id,
			type = message_type,
			data = copy_value(frozen_data),
			attempts = 0,
			total_attempts = 0,
			replay_count = 0,
			last_replay_token = nil,
			sender_job_id = server_id,
			created_at = created_at,
			locked_until = 0,
			lock_token = nil,
		}
		local next_queue = make_queue_envelope(owner, next_messages, queue.dead_letters)
		if queue_size_error(next_queue, max_bytes) ~= nil then
			return nil, nil, nil
		end
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil then
		return result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return verify_code or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id then
			if messaging_enabled(state) then
				local published, publish_error = publish_record_message(state, "queue_hint", nil, nil, nil)
				if not published and publish_error ~= nil then
					observe(state, "queue_hint", "unknown", publish_error)
				end
			end
			return "enqueued", message_id
		end
	end
	if #queue.messages >= max_messages then
		return "validation", "durable queue is full"
	end
	local candidate = table.clone(queue.messages)
	candidate[#candidate + 1] = {
		id = message_id,
		type = message_type,
		data = copy_value(frozen_data),
		attempts = 0,
		total_attempts = 0,
		replay_count = 0,
		last_replay_token = nil,
		sender_job_id = server_id,
		created_at = created_at,
		locked_until = 0,
		lock_token = nil,
	}
	local candidate_queue = make_queue_envelope(owner, candidate, queue.dead_letters)
	local size_message = queue_size_error(candidate_queue, max_bytes)
	if size_message ~= nil then
		return "validation", size_message
	end
	return "unknown", "queue append did not appear in the verified durable state"
end

local function dead_letter_queue_message(
	state: InternalState,
	message_id: string,
	lock_token: string,
	error_message: string
): (ResultCode, string?)
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return migration_code, migration_message
	end
	local bounded_error = normalize_queue_error(error_message)
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue, parse_error, owner_mismatch = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = if owner_mismatch then "conflict" else "corrupt"
			decision_message = parse_error
			return nil, nil, nil
		end
		for _, dead_letter in ipairs(queue.dead_letters) do
			if dead_letter.id == message_id and dead_letter.terminal_lock_token == lock_token then
				decision = "success"
				return nil, nil, nil
			end
		end
		local transform_time = queue_now_unix(backend.mock)
		local index: number? = nil
		local item: QueueItem? = nil
		for message_index, queued in ipairs(queue.messages) do
			if queued.id == message_id then
				index = message_index
				item = queued
				break
			end
		end
		if index == nil or item == nil then
			decision = "conflict"
			decision_message = "message is no longer active under this lock token"
			return nil, nil, nil
		end
		if item.lock_token ~= lock_token or item.locked_until <= transform_time then
			decision = "conflict"
			decision_message = "message lock token is stale or expired"
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		table.remove(next_messages, index)
		local next_dead_letters = table.clone(queue.dead_letters)
		next_dead_letters[#next_dead_letters + 1] = {
			id = item.id,
			type = item.type,
			data = copy_value(item.data),
			attempts = item.attempts,
			total_attempts = item.total_attempts,
			replay_count = item.replay_count,
			last_replay_token = item.last_replay_token,
			sender_job_id = item.sender_job_id,
			created_at = item.created_at,
			locked_until = 0,
			lock_token = nil,
			dead_lettered_at = transform_time,
			last_error = bounded_error,
			terminal_lock_token = lock_token,
		}
		local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			decision = "validation"
			decision_message = "dead-letter transition was not applied: " .. size_error
			return nil, nil, nil
		end
		decision = "success"
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return result_code, result_message
	end
	local verified_queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if verified_queue == nil then
		return verify_code or "unknown", verify_message
	end
	for _, dead_letter in ipairs(verified_queue.dead_letters) do
		if dead_letter.id == message_id and dead_letter.terminal_lock_token == lock_token then
			return "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return decision, decision_message or result_message
	end
	return "conflict", "message could not be verified in the dead-letter list"
end

process_queue_internal = function(state: InternalState, max_messages: number): (ResultCode, string?)
	if state.retired then
		return "invalid", "record has been retired"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if not (state.options.durable_queue_enabled ~= false) then
		return "empty", "durable queue is disabled"
	end
	if state.queue_busy then
		return "busy", "durable queue is already being processed"
	end
	if state.busy then
		return "busy", "record has a durable operation in flight"
	end
	local handler = state.options.on_queue_message
	if handler == nil then
		return "invalid", "on_queue_message is not configured"
	end
	if type(max_messages) ~= "number" or not math.isfinite(max_messages) or max_messages < 1 or math.floor(max_messages) ~= max_messages then
		return "invalid", "max_messages must be a positive integer"
	end
	max_messages = math.min(max_messages, state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES)
	local max_attempts = state.options.queue_max_attempts or DEFAULT_QUEUE_MAX_ATTEMPTS
	local expected_token = state.token
	if expected_token == nil then
		return "fenced", "session token is missing"
	end
	local processed = 0
	local ownership_lost = false
	local failure_result: ResultCode? = nil
	local failure_message: string? = nil
	state.queue_busy = true
	for _ = 1, max_messages do
		if state.retired or state.state ~= "active" or state.token ~= expected_token or state.takeover_requested then
			ownership_lost = true
			break
		end
		local message, claim_result, claim_error = claim_queue_message(state)
		if claim_result == "empty" then
			break
		end
		if message == nil then
			failure_result = claim_result
			failure_message = claim_error
			break
		end
		if state.retired or state.state ~= "active" or state.token ~= expected_token or state.takeover_requested then
			ownership_lost = true
			break
		end
		local lock_token = message.lock_token
		if lock_token == nil then
			failure_result = "corrupt"
			failure_message = "claimed queue message has no lock token"
			break
		end
		local handled = false
		local handler_message: string? = nil
		local handler_error: string? = nil
		local handler_completed = false
		local handler_thread = coroutine.create(function()
			local ok, result, result_message = pcall(
				handler,
				message.type,
				copy_value(message.data),
				message.attempts,
				message.id,
				message.sender_job_id,
				message.created_at
			)
			if not ok then
				handler_error = tostring(result)
				return
			end
			handler_completed = true
			handled = result == true
			if result_message ~= nil and type(result_message) == "string" then
				handler_message = result_message
			end
		end)
		local handler_resumed = coroutine.resume(handler_thread)
		local attempt_failure: string? = nil
		local attempt_failure_result: ResultCode = "unknown"
		if coroutine.status(handler_thread) ~= "dead" then
			coroutine.close(handler_thread)
			attempt_failure = "queue handler must not yield"
			attempt_failure_result = "invalid"
		elseif not handler_resumed or handler_error ~= nil then
			attempt_failure = "queue handler threw: " .. (handler_error or "execution failed")
		elseif not handler_completed or not handled then
			attempt_failure = handler_message or "queue handler rejected the message"
		end
		if attempt_failure ~= nil then
			observe(state, "queue_process", attempt_failure_result, attempt_failure)
			if message.attempts >= max_attempts then
				local dead_letter_result, dead_letter_message = dead_letter_queue_message(state, message.id, lock_token, attempt_failure)
				if dead_letter_result == "success" then
					processed += 1
					observe(state, "queue_dead_letter", "success", message.id)
					continue
				end
				failure_result = dead_letter_result
				failure_message = dead_letter_message
			else
				failure_result = attempt_failure_result
				failure_message = attempt_failure
			end
			break
		end
		if state.retired or state.state ~= "active" or state.token ~= expected_token or state.takeover_requested then
			ownership_lost = true
			break
		end
		local ack_result, ack_message = acknowledge_queue_message(state, message.id, lock_token)
		if ack_result ~= "success" then
			failure_result = ack_result
			failure_message = ack_message
			observe(state, "queue_ack", ack_result, ack_message)
			break
		end
		processed += 1
	end
	state.queue_busy = false
	if ownership_lost then
		return "fenced", "record ownership changed while processing the queue"
	end
	if failure_result ~= nil then
		return failure_result, failure_message
	end
	if processed == 0 then
		return "empty", nil
	end
	return "processed", tostring(processed)
end

local function disconnect_message_subscription(state: InternalState)
	local connection = state.message_subscription
	if connection == nil then
		return
	end
	state.message_subscription = nil
	pcall(function()
		connection:Disconnect()
	end)
	if state.state == "active" then
		state.next_message_subscribe = now_local() + MESSAGE_SUBSCRIBE_RETRY
	else
		state.next_message_subscribe = math.huge
	end
end

messaging_enabled = function(state: InternalState): boolean
	return state.options.messaging_enabled ~= false
end

local function takeover_enabled(state: InternalState): boolean
	return messaging_enabled(state) and state.options.takeover_enabled ~= false
end

local function encode_message_payload(payload: { [string]: unknown }): (boolean, string?)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not ok or type(encoded) ~= "string" then
		return false, "message could not be encoded"
	end
	if #encoded > MAX_MESSAGE_BYTES then
		return false, "message exceeds the 900 character RecordStore message limit"
	end
	return true, encoded
end

publish_record_message = function(state: InternalState, kind: string, message_type: string?, data: JsonValue?, generation: number?, target_job_id: string?, target_token: string?, request_id: string?, handoff_status: HandoffStatus?, requester_job_id: string?): (boolean, string?)
	local stable_request_id = request_id or HttpService:GenerateGUID(false)
	local payload = {
		protocol_version = 1,
		kind = kind,
		name = state.name,
		scope = state.scope,
		key = state.key,
		sender_job_id = server_id,
		requester_job_id = requester_job_id or server_id,
		request_id = stable_request_id,
		message_type = message_type,
		generation = generation,
		target_job_id = target_job_id,
		target_token = target_token,
		handoff_status = handoff_status,
		data = copy_value(data),
	}
	local valid, message = encode_message_payload(payload)
	if not valid then
		return false, message
	end
	local ok, error_message = pcall(function()
		MessagingService:PublishAsync(state.message_topic, payload)
	end)
	if not ok then
		return false, tostring(error_message)
	end
	return true, nil
end

local function decode_message(raw: unknown): { [string]: unknown }?
	if type(raw) ~= "table" then
		return nil
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(raw)
	end)
	if not ok or type(encoded) ~= "string" then
		return nil
	end
	local decode_ok, decoded = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	if not decode_ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function cache_takeover_status(state: InternalState, request_id: string, status: HandoffStatus)
	if state.takeover_seen[request_id] == nil then
		state.takeover_seen_order[#state.takeover_seen_order + 1] = request_id
	end
	state.takeover_seen[request_id] = status
	while #state.takeover_seen_order > TAKEOVER_SEEN_CAPACITY do
		local oldest = table.remove(state.takeover_seen_order, 1)
		if oldest ~= nil then
			state.takeover_seen[oldest] = nil
		end
	end
end

local function publish_handoff_ack(state: InternalState, request_id: string, requester_job_id: string, generation: number, target_token: string, status: HandoffStatus): boolean
	local ok = publish_record_message(state, "handoff_ack", nil, nil, generation, requester_job_id, target_token, request_id, status, requester_job_id)
	if ok then
		state.handoff_ack_count += 1
	end
	return ok
end

local function handle_message(state: InternalState, message: { Data: unknown, Sent: number })
	if state.retired then
		return
	end
	local payload = decode_message(message.Data)
	if payload == nil then
		return
	end
	if payload.protocol_version ~= 1 then
		return
	end
	if payload.name ~= state.name or payload.scope ~= state.scope or payload.key ~= state.key then
		return
	end
	if payload.sender_job_id == server_id or type(payload.sender_job_id) ~= "string" then
		return
	end
	local kind = payload.kind
	if type(kind) ~= "string" or #kind > 32 then
		return
	end
	local request_id = payload.request_id
	if type(request_id) ~= "string" or request_id == "" or #request_id > 64 then
		return
	end
	local generation = payload.generation
	if generation ~= nil and (type(generation) ~= "number" or not math.isfinite(generation)) then
		return
	end
	if kind == "handoff_ack" then
		if payload.target_job_id ~= server_id or type(payload.handoff_status) ~= "string" then
			return
		end
		if state.handoff_request_id ~= request_id then
			return
		end
		local status = payload.handoff_status
		if status ~= "accepted" and status ~= "released" and status ~= "busy" and status ~= "stale" and status ~= "not_owner" and status ~= "failed" then
			return
		end
		if state.handoff_target_generation ~= nil and generation ~= state.handoff_target_generation then
			return
		end
		if state.handoff_target_token ~= nil and payload.target_token ~= state.handoff_target_token then
			return
		end
		state.handoff_status = status
		observe(state, "handoff_ack", "success", status)
		return
	end
	if kind == "takeover_request" then
		local requester_job_id = payload.requester_job_id
		if type(requester_job_id) ~= "string" or requester_job_id == server_id then
			return
		end
		if payload.target_job_id ~= server_id or type(payload.target_token) ~= "string" or type(generation) ~= "number" then
			return
		end
		local cached = state.takeover_seen[request_id]
		if cached ~= nil then
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or payload.target_token, cached)
			return
		end
		if not takeover_enabled(state) then
			cache_takeover_status(state, request_id, "failed")
			publish_handoff_ack(state, request_id, requester_job_id, generation, payload.target_token, "failed")
			return
		end
		if state.state ~= "active" then
			cache_takeover_status(state, request_id, "not_owner")
			publish_handoff_ack(state, request_id, requester_job_id, generation, payload.target_token, "not_owner")
			return
		end
		if payload.target_token ~= state.token or generation ~= state.generation then
			cache_takeover_status(state, request_id, "stale")
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", "stale")
			return
		end
		if state.takeover_requested or state.busy or state.queue_busy then
			cache_takeover_status(state, request_id, "busy")
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", "busy")
			return
		end
		state.takeover_requested = true
		state.takeover_request_id = request_id
		state.takeover_requester_job_id = requester_job_id
		cache_takeover_status(state, request_id, "accepted")
		publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", "accepted")
		complete_deferred_takeover(state)
		return
	end
	if kind == "queue_hint" then
		state.queue_hint = true
		state.next_queue_poll = now_local()
		return
	end
	if kind ~= "message" or type(payload.message_type) ~= "string" or payload.message_type == "" or #payload.message_type > MAX_MESSAGE_TYPE_LENGTH then
		return
	end
	if payload.data ~= nil then
		local data_valid = validate_serialized_size(payload.data)
		if not data_valid then
			return
		end
	end
	local message_type = payload.message_type
	local sender_job_id = payload.sender_job_id
	local observer = state.options.on_message
	if observer ~= nil then
		local data = if payload.data ~= nil then copy_value(payload.data) else nil
		task.spawn(function()
			local thread = coroutine.create(function()
				observer(message_type, data, message.Sent, sender_job_id)
			end)
			local resumed = coroutine.resume(thread)
			if not resumed or coroutine.status(thread) ~= "dead" then
				coroutine.close(thread)
				state.observer_errors += 1
			end
		end)
	end
	observe(state, "message", "success", message_type)
end

local function subscribe_record(state: InternalState)
	if not messaging_enabled(state) or state.message_subscription ~= nil then
		return
	end
	local ok, connection = pcall(function()
		return MessagingService:SubscribeAsync(state.message_topic, function(message)
			handle_message(state, message)
		end)
	end)
	if not ok or connection == nil then
		state.next_message_subscribe = now_local() + MESSAGE_SUBSCRIBE_RETRY
		observe(state, "subscribe", "unknown", tostring(connection))
		return
	end
	state.message_subscription = connection
	state.next_message_subscribe = math.huge
end

local function request_takeover(state: InternalState, generation: number, target_job_id: string, target_token: string, deadline: number): (string?, HandoffStatus)
	if not takeover_enabled(state) then
		return nil, "failed"
	end
	subscribe_record(state)
	local can_receive_ack = state.message_subscription ~= nil
	local now = now_local()
	if state.handoff_request_id ~= nil
		and state.handoff_target_job_id == target_job_id
		and state.handoff_target_token == target_token
		and state.handoff_target_generation == generation
		and now < state.handoff_deadline
	then
		state.handoff_requests_suppressed += 1
		if not can_receive_ack then
			state.handoff_status = "failed"
			return state.handoff_request_id, "failed"
		end
		while now_local() < math.min(deadline, state.handoff_deadline) do
			local status = state.handoff_status
			if status ~= nil and status ~= "pending" then
				return state.handoff_request_id, status
			end
			task.wait(0.05)
		end
		return state.handoff_request_id, state.handoff_status or "pending"
	end
	local previous_target_job_id = state.handoff_target_job_id
	local previous_target_token = state.handoff_target_token
	local previous_target_generation = state.handoff_target_generation
	local same_target = previous_target_job_id == target_job_id and previous_target_token == target_token and previous_target_generation == generation
	if same_target and now - state.handoff_last_publish < HANDOFF_PUBLISH_COOLDOWN then
		state.handoff_requests_suppressed += 1
		observe(state, "takeover_suppressed", "success", "same target is inside publish cooldown; using DataStore fallback")
		return state.handoff_request_id, "failed"
	end
	local request_id = HttpService:GenerateGUID(false)
	state.handoff_request_id = request_id
	state.handoff_target_job_id = target_job_id
	state.handoff_target_token = target_token
	state.handoff_target_generation = generation
	state.handoff_status = "pending"
	state.handoff_deadline = math.min(deadline, now + (state.options.takeover_wait or DEFAULT_TAKEOVER_WAIT))
	state.handoff_published = false
	local published, publish_message = publish_record_message(state, "takeover_request", nil, nil, generation, target_job_id, target_token, request_id, nil, server_id)
	state.handoff_published = published
	if not published then
		observe(state, "takeover_publish", "unknown", publish_message)
		state.handoff_deadline = now_local()
		return request_id, "failed"
	end
	state.handoff_last_publish = now_local()
	observe(state, "takeover_publish", "success", request_id)
	if not can_receive_ack then
		state.handoff_status = "failed"
		state.handoff_deadline = now_local()
		observe(state, "takeover_fallback", "success", "messaging acknowledgment channel unavailable; using DataStore fallback")
		return request_id, "failed"
	end
	while now_local() < math.min(deadline, state.handoff_deadline) do
		local status = state.handoff_status
		if status ~= nil and status ~= "pending" then
			return request_id, status
		end
		task.wait(0.05)
	end
	return request_id, state.handoff_status or "pending"
end

local function update_state_metadata_from_info(state: InternalState, info: BackendInfo?)
	if info == nil then
		return
	end
	state.user_ids = clone_user_ids(info.UserIds)
	state.metadata = clone_metadata(info.Metadata)
end

local function save_internal(state: InternalState, reason: string?, operation_deadline: number?, retry_attempts: number?): (ResultCode, string?)
	track_external_data_mutation(state)
	if state.retired then
		return "invalid", "record has been retired"
	end
	if closing and not state.shutdown then
		return "closing", "server is shutting down"
	end
	if state.state ~= "active" then
		return if state.state == "tombstoned" then "tombstoned" else "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy or state.queue_busy then
		state.save_requested = true
		return "busy", (if state.queue_busy then "durable queue is being processed" else "record already has a durable operation in flight")
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local snapshot = copy_value(state.data)
	local captured_change_sequence = state.change_sequence
	local valid, validation_error = validate_value(snapshot, state.options.validator)
	if not valid then
		observe(state, "save", "validation", validation_error)
		return "validation", validation_error
	end
	local generation = state.generation
	local expected_revision = state.revision
	local target_revision = expected_revision + 1
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline or state.options.operation_deadline)
	if deadline == nil then
		return "invalid", deadline_error
	end
	local attempts = retry_attempts or state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	if type(attempts) ~= "number" or not math.isfinite(attempts) or attempts < 1 or attempts > MAX_RETRY_ATTEMPTS or math.floor(attempts) ~= attempts then
		return "invalid", "retry_attempts must be an integer from 1 to " .. tostring(MAX_RETRY_ATTEMPTS)
	end
	state.busy = true
	state.state = "saving"
	local last_error: string? = nil
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			disconnect_message_subscription(state)
			return "closing", "record was retired"
		end
		if now_local() >= deadline then
			break
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id and matches_session(envelope, session_token, generation) and envelope.revision == target_revision then
				if envelope.session == nil or envelope.session.lease_until <= transform_time then
					decision = "fenced"
					decision_message = "durable session lease has expired"
					return nil, nil, nil
				end
				decision = "success"
				return envelope, (if info ~= nil then info.UserIds else state.user_ids), (if info ~= nil then info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.revision ~= expected_revision then
				decision = "conflict"
				decision_message = "durable revision changed unexpectedly"
				return nil, nil, nil
			end
			local session = envelope.session
			if session == nil then
				decision = "fenced"
				decision_message = "durable session is missing"
				return nil, nil, nil
			end
			if session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = target_revision,
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = snapshot,
				user_ids = clone_user_ids(state.user_ids),
				tombstone = nil,
				session = {
					token = session_token,
					generation = generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = session.acquired_at,
					lease_until = transform_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				write_id = write_id,
			}
			local envelope_valid, envelope_error = validate_envelope(next_envelope)
			if not envelope_valid then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			decision = "success"
			return next_envelope, state.user_ids, make_backend_metadata(state.metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if state.retired or state.state ~= "saving" then
			state.busy = false
			return "closing", "save was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and matches_session(returned, session_token, generation) and returned.session ~= nil and returned.session.lease_until > session_now_unix(state.backend.mock) and returned.revision == target_revision and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "conflict" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "save", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			observe(state, "save", "validation", decision_message)
			return "validation", decision_message
		end
		if result_code ~= nil and result_code ~= "unknown" then
			last_error = result_message
		elseif result == nil then
			last_error = result_message or "save response did not confirm the requested write"
		end
		local verified, envelope, info_after = verify_snapshot_write(state, write_id, session_token, generation, target_revision, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		state.busy = false
		state.state = "unknown"
		observe(state, "save", "unknown", last_error or "save outcome is unresolved")
		return "unknown", last_error or "save outcome is unresolved"
	end
	track_external_data_mutation(state)
	local local_changed_during_save = state.change_sequence ~= captured_change_sequence
	state.generation = confirmed.fencing_generation
	state.revision = confirmed.revision
	state.created_at = confirmed.created_at
	state.updated_at = confirmed.updated_at
	state.tombstoned = confirmed.tombstone ~= nil
	state.token = if confirmed.session ~= nil then confirmed.session.token else state.token
	state.durable_lease_until = if confirmed.session ~= nil then confirmed.session.lease_until else 0
	state.last_observed = now_unix()
	if not local_changed_during_save then
		update_local_from_envelope(state, confirmed, confirmed_info)
		state.saved_change_sequence = captured_change_sequence
	else
		state.save_requested = true
		state.next_autosave = now_local()
	end
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, reason or "manual")
	state.busy = false
	state.state = "active"
	state.next_autosave = now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL)
	if state.save_requested then
		state.next_autosave = now_local()
		state.save_requested = false
	end
	observe(state, "save", "saved", reason)
	complete_deferred_takeover(state)
	return "saved", nil
end

function RecordStore.read_async(name: string, scope: string, key: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, "invalid", "legacy_decoder must be a function"
	end
	local backend = make_backend(name, scope, key, false)
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	local raw, info, result_code, result_message = backend_get(backend, false, deadline)
	if result_code ~= nil then
		return nil, result_code, result_message
	end
	if raw == nil then
		return nil, "not_found", "record does not exist"
	end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		if parse_error == "legacy payload" and legacy_decoder ~= nil then
			local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
			if legacy_envelope == nil then
				return nil, "legacy", legacy_error
			end
			return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "read-only legacy payload"
		end
		return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "durable envelope is invalid"
	end
	if envelope == nil then
		return nil, "corrupt", "durable envelope is missing"
	end
	return snapshot_from_envelope(key, envelope, info), "success", nil
end

local function list_versions_internal(name: string, scope: string, key: string, sort_direction: Enum.SortDirection?, min_date_ms: number?, max_date_ms: number?, max_versions: number?, operation_deadline: number?, mock: boolean): ({ HistoryEntry }?, ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	if min_date_ms ~= nil and (type(min_date_ms) ~= "number" or not math.isfinite(min_date_ms) or min_date_ms <= 0 or math.floor(min_date_ms) ~= min_date_ms) then
		return nil, "invalid", "min_date_ms must be a positive integer"
	end
	if max_date_ms ~= nil and (type(max_date_ms) ~= "number" or not math.isfinite(max_date_ms) or max_date_ms <= 0 or math.floor(max_date_ms) ~= max_date_ms) then
		return nil, "invalid", "max_date_ms must be a positive integer"
	end
	if min_date_ms ~= nil and max_date_ms ~= nil and min_date_ms > max_date_ms then
		return nil, "invalid", "min_date_ms must not exceed max_date_ms"
	end
	if max_versions ~= nil and (type(max_versions) ~= "number" or not math.isfinite(max_versions) or max_versions < 1 or max_versions ~= math.floor(max_versions)) then
		return nil, "invalid", "max_versions must be a positive integer"
	end
	if sort_direction ~= nil and sort_direction ~= Enum.SortDirection.Ascending and sort_direction ~= Enum.SortDirection.Descending then
		return nil, "invalid", "sort_direction must be Ascending or Descending"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	local limit = max_versions or 100
	if mock then
		local store = get_mock_store(name, scope)
		local entry = store[key]
		if entry == nil then
			return {}, "success", nil
		end
		local entries: { HistoryEntry } = {}
		local order = table.clone(entry.VersionOrder)
		if (sort_direction or Enum.SortDirection.Descending) == Enum.SortDirection.Descending then
			local order_length = #order
			for index = 1, math.floor(order_length / 2) do
				local other_index = order_length - index + 1
				order[index], order[other_index] = order[other_index], order[index]
			end
		end
		for _, version in ipairs(order) do
			local item = entry.Versions[version]
			if item ~= nil and (min_date_ms == nil or item.CreatedTime >= min_date_ms) and (max_date_ms == nil or item.CreatedTime <= max_date_ms) then
				entries[#entries + 1] = {
					Version = item.Version,
					CreatedTime = item.CreatedTime,
					IsDeleted = item.Deleted,
				}
				if #entries >= limit then
					break
				end
			end
		end
		return entries, "success", nil
	end
	local backend = make_backend(name, scope, key, false)
	local store = backend.store
	if store == nil then
		return nil, "invalid", "backend store is missing"
	end
	if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardList) then
		return nil, "budget", "version list request deadline exceeded"
	end
	local ok, pages = pcall(function()
		return store:ListVersionsAsync(key, sort_direction or Enum.SortDirection.Descending, min_date_ms, max_date_ms, math.min(limit, 100))
	end)
	release_slot()
	if not ok then
		return nil, "unknown", tostring(pages)
	end
	local result: { HistoryEntry } = {}
	while true do
		if now_local() >= deadline then
			return result, "budget", "version list deadline exceeded"
		end
		for _, item in pages:GetCurrentPage() do
			if #result >= limit then
				break
			end
			result[#result + 1] = {
				Version = item.Version,
				CreatedTime = item.CreatedTime,
				IsDeleted = item.IsDeleted,
			}
		end
		if #result >= limit or pages.IsFinished then
			break
		end
		if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardList) then
			return result, "budget", "version pagination deadline exceeded"
		end
		local advance_ok, advance_error = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		release_slot()
		if not advance_ok then
			return result, "unknown", tostring(advance_error)
		end
	end
	return result, "success", nil
end

function RecordStore.list_versions_async(name: string, scope: string, key: string, sort_direction: Enum.SortDirection?, min_date_ms: number?, max_date_ms: number?, max_versions: number?, operation_deadline: number?): ({ HistoryEntry }?, ResultCode, string?)
	return list_versions_internal(name, scope, key, sort_direction, min_date_ms, max_date_ms, max_versions, operation_deadline, false)
end

local function get_version_internal(name: string, scope: string, key: string, version: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?, mock: boolean): (Snapshot?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, "invalid", "legacy_decoder must be a function"
	end
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, "invalid", identity_message
	end
	if type(version) ~= "string" or version == "" then
		return nil, "invalid", "version must be a non-empty string"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, "invalid", deadline_error
	end
	if mock then
		local entry = get_mock_store(name, scope)[key]
		if entry == nil then
			return nil, "not_found", "record does not exist"
		end
		local item = entry.Versions[version]
		if item == nil then
			return nil, "not_found", "version does not exist"
		end
		local info: BackendInfo = {
			Version = item.Version,
			CreatedTime = item.CreatedTime,
			UpdatedTime = item.UpdatedTime,
			UserIds = clone_user_ids(item.UserIds),
			Metadata = clone_metadata(item.Metadata),
			RawMetadata = clone_metadata(item.Metadata),
		}
		local envelope, parse_error, current_format = parse_envelope(item.Value)
		if not current_format then
			if parse_error == "legacy payload" and legacy_decoder ~= nil then
				local legacy_envelope, legacy_error = decode_legacy_read(item.Value, legacy_decoder)
				if legacy_envelope == nil then
					return nil, "legacy", legacy_error
				end
				return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "historical legacy payload"
			end
			return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "historical envelope is invalid"
		end
		if envelope == nil then
			return nil, "corrupt", "historical envelope is missing"
		end
		return snapshot_from_envelope(key, envelope, info), "success", nil
	end
	local backend = make_backend(name, scope, key, false)
	local store = backend.store
	if store == nil then
		return nil, "invalid", "backend store is missing"
	end
	if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardRead) then
		return nil, "budget", "version read deadline exceeded"
	end
	local ok, raw, key_info = pcall(function()
		return store:GetVersionAsync(key, version)
	end)
	release_slot()
	if not ok then
		return nil, "unknown", tostring(raw)
	end
	local info = backend_info_from_key_info(key_info)
	if raw == nil then
		return nil, "not_found", "version does not exist"
	end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		if parse_error == "legacy payload" and legacy_decoder ~= nil then
			local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
			if legacy_envelope == nil then
				return nil, "legacy", legacy_error
			end
			return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "historical legacy payload"
		end
		return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "historical envelope is invalid"
	end
	if envelope == nil then
		return nil, "corrupt", "historical envelope is missing"
	end
	return snapshot_from_envelope(key, envelope, info), "success", nil
end

function RecordStore.get_version_async(name: string, scope: string, key: string, version: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, "invalid", "legacy_decoder must be a function"
	end
	return get_version_internal(name, scope, key, version, operation_deadline, legacy_decoder, false)
end

local function get_version_at_time_internal(name: string, scope: string, key: string, timestamp_ms: number, operation_deadline: number?, legacy_decoder: LegacyDecoder?, mock: boolean): (Snapshot?, string?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, nil, "invalid", "legacy_decoder must be a function"
	end
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return nil, nil, "invalid", identity_message
	end
	if type(timestamp_ms) ~= "number" or not math.isfinite(timestamp_ms) or timestamp_ms <= 0 or math.floor(timestamp_ms) ~= timestamp_ms then
		return nil, nil, "invalid", "timestamp_ms must be a positive integer"
	end
	if timestamp_ms > DateTime.now().UnixTimestampMillis + 600_000 then
		return nil, nil, "invalid", "timestamp_ms cannot be more than ten minutes in the future"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return nil, nil, "invalid", deadline_error
	end
	if mock then
		local entries, list_result, list_message = list_versions_internal(name, scope, key, Enum.SortDirection.Descending, nil, timestamp_ms, 1, operation_deadline, true)
		if list_result ~= "success" then
			return nil, nil, list_result, list_message
		end
		if entries == nil or #entries == 0 then
			return nil, nil, "not_found", "no version was available at the requested time"
		end
		local snapshot, result, message = get_version_internal(name, scope, key, entries[1].Version, operation_deadline, legacy_decoder, true)
		return snapshot, entries[1].Version, result, message
	end
	local backend = make_backend(name, scope, key, false)
	local store = backend.store
	if store == nil then
		return nil, nil, "invalid", "backend store is missing"
	end
	if not acquire_request(nil, deadline, false, Enum.DataStoreRequestType.StandardRead) then
		return nil, nil, "budget", "historical read deadline exceeded"
	end
	local ok, raw, key_info = pcall(function()
		return store:GetVersionAtTimeAsync(key, timestamp_ms)
	end)
	release_slot()
	if not ok then
		return nil, nil, "unknown", tostring(raw)
	end
	local info = backend_info_from_key_info(key_info)
	if raw == nil then
		return nil, nil, "not_found", "no version was available at the requested time"
	end
	local version = if info ~= nil then info.Version else nil
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format then
		if parse_error == "legacy payload" and legacy_decoder ~= nil then
			local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
			if legacy_envelope == nil then
				return nil, version, "legacy", legacy_error
			end
			return snapshot_from_envelope(key, legacy_envelope, info), version, "legacy", "historical legacy payload"
		end
		return nil, version, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "historical envelope is invalid"
	end
	if envelope == nil then
		return nil, version, "corrupt", "historical envelope is missing"
	end
	return snapshot_from_envelope(key, envelope, info), version, "success", nil
end

function RecordStore.get_version_at_time_async(name: string, scope: string, key: string, timestamp_ms: number, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, string?, ResultCode, string?)
	if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
		return nil, nil, "invalid", "legacy_decoder must be a function"
	end
	return get_version_at_time_internal(name, scope, key, timestamp_ms, operation_deadline, legacy_decoder, false)
end



local function data_values_equal(left: JsonValue?, right: JsonValue?, depth: number?): boolean
	local current_depth = depth or 0
	if current_depth > 64 then
		return false
	end
	if left == right then
		return true
	end
	if type(left) == "number"
		and type(right) == "number"
		and math.isnan(left)
		and math.isnan(right)
	then
		return true
	end
	if left == nil or right == nil then
		return false
	end
	local left_type = typeof(left)
	local right_type = typeof(right)
	if left_type == "buffer" or right_type == "buffer" then
		return left_type == "buffer" and right_type == "buffer" and buffer.tostring(left :: buffer) == buffer.tostring(right :: buffer)
	end
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	local left_table = left :: { [string | number]: JsonValue }
	local right_table = right :: { [string | number]: JsonValue }
	for key, child in left_table do
		local other = right_table[key]
		if other == nil or not data_values_equal(child, other, current_depth + 1) then
			return false
		end
	end
	for key in right_table do
		if left_table[key] == nil then
			return false
		end
	end
	return true
end

track_external_data_mutation = function(state: InternalState)
	if state.state ~= "active" and state.state ~= "saving" then
		return
	end
	local public_record = state.public_record
	local public_data: unknown = state.data
	local public_record_table: { Data: unknown }? = nil
	if type(public_record) == "table" then
		public_record_table = public_record :: { Data: unknown }
		public_data = public_record_table.Data
	end
	local candidate = public_data :: JsonValue?
	if data_values_equal(candidate, state.public_data_source) then
		state.data = candidate
		return
	end
	local copied_ok, copied_or_error = pcall(function()
		return copy_value(candidate)
	end)
	if not copied_ok or copied_or_error == nil then
		local rejection_reason = if not copied_ok
			then string.gsub(tostring(copied_or_error), "%c", " ")
			else "Data was set to nil"
		rejection_reason = string.sub(rejection_reason, 1, 180)
		state.data = copy_value(state.public_data_source)
		if public_record_table ~= nil then
			public_record_table.Data = state.data
		end
		state.public_data_source = copy_value(state.data)
		observe(
			state,
			"external_data_mutation",
			"validation",
			"direct Data mutation produced an invalid value and was discarded: " .. rejection_reason
		)
		return
	end
	local candidate_copy = copied_or_error
	local validation_value: JsonValue? = candidate_copy
	if state.options.validator ~= nil then
		validation_value = copy_value(candidate_copy)
	end
	local valid, validation_message = validate_value(validation_value, state.options.validator)
	if not valid then
		state.data = copy_value(state.public_data_source)
		if public_record_table ~= nil then
			public_record_table.Data = state.data
		end
		state.public_data_source = copy_value(state.data)
		observe(state, "external_data_mutation", "validation", validation_message or "direct Data mutation failed validation")
		return
	end
	local old_data = state.public_data_source
	state.data = candidate
	local current_data = copy_value(state.data)
	if current_data == nil then
		state.data = copy_value(state.public_data_source)
		if public_record_table ~= nil then
			public_record_table.Data = state.data
		end
		state.public_data_source = copy_value(state.data)
		observe(state, "external_data_mutation", "validation", "direct Data mutation could not be snapshotted")
		return
	end
	if public_record_table ~= nil then
		public_record_table.Data = state.data
	end
	state.change_sequence += 1
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_data, current_data, operation_id, "direct_data_mutation")
	state.save_requested = true
	state.next_autosave = now_local()
	state.last_observed = now_unix()
	state.public_data_source = current_data
end

local function sync_public(record: Record, skip_external_mutation_check: boolean?)
	local state = private[record]
	if state == nil then
		return
	end

	if not skip_external_mutation_check then
		track_external_data_mutation(state)
	end
	if state.state == "active" then
		active_records[record] = true
	else
		active_records[record] = nil
	end
	record.Data = state.data
	record.State = state.state
	record.Key = state.key
	record.Generation = state.generation
	record.Revision = state.revision
	record.CreatedAt = state.created_at
	record.UpdatedAt = state.updated_at
	record.Tombstoned = state.tombstoned
	record.LastError = state.last_error
end

local function subscribe_changes(self: Record, observer: ChangeObserver): (ChangeSubscription?, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return nil, "invalid", "record does not exist"
	end
	if type(observer) ~= "function" then
		return nil, "invalid", "change observer must be a function"
	end
	local id = state.change_observer_next_id
	state.change_observer_next_id += 1
	state.change_observers[id] = observer
	local connected = true
	local subscription: ChangeSubscription = {
		Disconnect = function(_: ChangeSubscription)
			if not connected then
				return
			end
			connected = false
			state.change_observers[id] = nil
		end,
	}
	return subscription, "success", nil
end

local function get_last_error_info(self: Record): RecordError?
	local state = private[self]
	if state == nil then
		return nil
	end
	local info = state.last_error_info
	if info == nil then
		return nil
	end
	return {
		Code = info.Code,
		Message = info.Message,
		Retryable = info.Retryable,
		RequiresVerification = info.RequiresVerification,
		DurableOutcome = info.DurableOutcome,
		OperationId = info.OperationId,
		Generation = info.Generation,
		Revision = info.Revision,
	}
end

local function get_handoff(self: Record): HandoffResult?
	local state = private[self]
	if state == nil or state.handoff_request_id == nil or state.handoff_target_job_id == nil or state.handoff_target_generation == nil then
		return nil
	end
	return {
		RequestId = state.handoff_request_id,
		Status = state.handoff_status or "pending",
		Generation = state.handoff_target_generation,
		TargetJobId = state.handoff_target_job_id,
		Published = state.handoff_published,
		Deadline = state.handoff_deadline,
		Suppressed = state.handoff_requests_suppressed,
		Acks = state.handoff_ack_count,
	}
end

local function get_key(self: Record): string
	local state = private[self]
	return if state ~= nil then state.key else self.Key
end

local function get_state(self: Record): SessionState
	local state = private[self]
	return if state ~= nil then state.state else self.State
end

local function get_revision(self: Record): number
	local state = private[self]
	return if state ~= nil then state.revision else self.Revision
end

local function get_generation(self: Record): number
	local state = private[self]
	return if state ~= nil then state.generation else self.Generation
end

local function is_open(self: Record): boolean
	local state = private[self]
	return state ~= nil and state.state == "active" and state.token ~= nil
end

local function get_backend_info(self: Record): BackendInfoView
	local state = private[self]
	if state == nil then
		return {
			Version = nil,
			CreatedTime = self.CreatedAt,
			UpdatedTime = self.UpdatedAt,
			UserIds = {},
			Metadata = {},
		}
	end
	local last_saved = state.last_saved
	return {
		Version = if last_saved ~= nil then last_saved.BackendVersion else nil,
		CreatedTime = if last_saved ~= nil and last_saved.BackendCreatedAt ~= nil then last_saved.BackendCreatedAt else state.created_at,
		UpdatedTime = if last_saved ~= nil and last_saved.BackendUpdatedAt ~= nil then last_saved.BackendUpdatedAt else state.updated_at,
		UserIds = if last_saved ~= nil then clone_user_ids(last_saved.UserIds) else clone_user_ids(state.user_ids),
		Metadata = if last_saved ~= nil then clone_metadata(last_saved.Metadata) else clone_metadata(state.metadata),
	}
end

local function get_data(self: Record): JsonValue?
	local state = private[self]
	if state == nil then
		return nil
	end
	track_external_data_mutation(state)
	self.Data = state.data
	return copy_value(state.data)
end

local function get_last_saved(self: Record): DurableSnapshot?
	local state = private[self]
	if state == nil then
		return nil
	end
	return clone_durable_snapshot(state.last_saved)
end

local function is_dirty(self: Record): boolean
	local state = private[self]
	if state == nil then
		return false
	end
	track_external_data_mutation(state)
	self.Data = state.data
	return state.change_sequence ~= state.saved_change_sequence
end

local function get_user_ids(self: Record): { number }
	local state = private[self]
	if state == nil then
		return {}
	end
	return clone_user_ids(state.user_ids)
end

local function set_user_ids(self: Record, user_ids: { number }): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	if type(user_ids) ~= "table" then
		return "validation", "user_ids must be an array of positive integers"
	end
	local normalized, message = normalize_user_ids(user_ids)
	if normalized == nil then
		return "validation", message
	end
	local old_user_ids = state.user_ids
	state.user_ids = normalized
	state.change_sequence += 1
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_user_ids, normalized, operation_id, "user_ids")
	state.save_requested = true
	state.next_autosave = now_local()
	sync_public(self)
	return "success", nil
end

local function add_user_id(self: Record, user_id: number): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(user_id) ~= "number" or not math.isfinite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
		return "validation", "user_id must be a positive integer"
	end
	local ids = clone_user_ids(state.user_ids)
	ids[#ids + 1] = user_id
	return set_user_ids(self, ids)
end

local function remove_user_id(self: Record, user_id: number): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(user_id) ~= "number" or not math.isfinite(user_id) or user_id < 1 or math.floor(user_id) ~= user_id then
		return "validation", "user_id must be a positive integer"
	end
	local ids: { number } = {}
	for _, existing in ipairs(state.user_ids) do
		if existing ~= user_id then
			ids[#ids + 1] = existing
		end
	end
	return set_user_ids(self, ids)
end

local function get_metadata(self: Record): Metadata
	local state = private[self]
	if state == nil then
		return {}
	end
	return clone_metadata(state.metadata)
end

local function set_metadata(self: Record, metadata: Metadata): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	if type(metadata) ~= "table" then
		return "validation", "metadata must be a table"
	end
	local copied = clone_metadata(metadata)
	local valid, message = validate_metadata(copied)
	if not valid then
		return "validation", message
	end
	local old_metadata = state.metadata
	state.metadata = copied
	state.change_sequence += 1
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_metadata, copied, operation_id, "metadata")
	state.save_requested = true
	state.next_autosave = now_local()
	sync_public(self)
	return "success", nil
end

local function update_metadata(self: Record, callback: (Metadata) -> Metadata): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	local working = clone_metadata(state.metadata)
	local next_metadata: Metadata? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, value = pcall(callback, working)
		if not ok then
			callback_error = tostring(value)
			return
		end
		next_metadata = value
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return "invalid", "metadata update callback must not yield"
	end
	if not resumed then
		return "invalid", "metadata update callback execution failed"
	end
	if callback_error ~= nil then
		return "invalid", "metadata update callback threw: " .. callback_error
	end
	if next_metadata == nil or type(next_metadata) ~= "table" then
		return "validation", "metadata update callback must return a table"
	end
	local copied = clone_metadata(next_metadata)
	local valid, message = validate_metadata(copied)
	if not valid then
		return "validation", message
	end
	local old_metadata = state.metadata
	state.metadata = copied
	state.change_sequence += 1
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_metadata, copied, operation_id, "metadata")
	state.save_requested = true
	state.next_autosave = now_local()
	sync_public(self)
	return "success", nil
end

local function touch(self: Record): (ResultCode, string?)
	local state = private[self]
	if state == nil or state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	state.save_requested = true
	state.next_autosave = now_local()
	state.last_observed = now_unix()
	observe(state, "touch", "success", nil)
	sync_public(self)
	return "success", nil
end

local function update(self: Record, callback: (JsonValue?) -> JsonValue?): (ResultCode, string?)
	local state = private[self]
	if state ~= nil then
		track_external_data_mutation(state)
	end
	if state == nil or state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record has a durable operation in flight"
	end
	if type(callback) ~= "function" then
		return "invalid", "update callback must be a function"
	end
	local old_data = state.data
	local working = copy_value(state.data)
	local next_value: JsonValue? = nil
	local callback_error: string? = nil
	local thread = coroutine.create(function()
		local ok, value = pcall(callback, working)
		if not ok then
			callback_error = tostring(value)
			return
		end
		next_value = value
	end)
	local resumed = coroutine.resume(thread)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return "invalid", "update callback must not yield"
	end
	if not resumed then
		return "invalid", "update callback execution failed"
	end
	if callback_error ~= nil then
		return "invalid", "update callback threw: " .. callback_error
	end
	if next_value == nil then
		return "validation", "update callback returned nil"
	end
	local copy_ok, copied_or_error = pcall(function()
		return copy_value(next_value)
	end)
	if not copy_ok or copied_or_error == nil then
		return "validation", "update callback returned invalid data"
	end
	local copied = copied_or_error
	local valid, message = validate_value(copied, state.options.validator)
	if not valid then
		return "validation", message
	end
	local skip_sync_external_mutation_check = state.options.on_event == nil and next(state.change_observers) == nil
	state.data = copied
	state.public_data_source = copy_value(state.data)
	self.Data = state.data
	state.change_sequence += 1
	local operation_id = HttpService:GenerateGUID(false)
	state.current_operation_id = operation_id
	enqueue_change_observation(state, old_data, copied, operation_id, "update")
	state.save_requested = true
	state.next_autosave = now_local()
	state.last_observed = now_unix()
	observe(state, "update", "success", nil)
	sync_public(self, skip_sync_external_mutation_check)
	return "success", nil
end

local function reconcile(self: Record, template: JsonValue): (ResultCode, string?)
	local state = private[self]
	if state ~= nil then
		track_external_data_mutation(state)
	end
	if state == nil or state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		state.save_requested = true
		return "busy", "record is already saving"
	end
	local old_data = state.data
	local copied = copy_value(state.data)
	if copied == nil then
		return "validation", "record data is missing"
	end
	local template_ok, template_or_error = pcall(function()
		return copy_value(template)
	end)
	if not template_ok or template_or_error == nil then
		return "validation", "template is invalid"
	end
	local template_copy = template_or_error
	local function set_table_child(
		target: JsonValue,
		key: string | number,
		value: JsonValue
	): (JsonValue, boolean)
		if type(target) ~= "table" then
			return target, false
		end
		if type(key) == "string" then
			for child_key in target do
				if type(child_key) ~= "string" then
					return target, false
				end
			end
			local target_table = target :: { [string]: JsonValue }
			target_table[key] = value
			return target, true
		end
		for child_key in target do
			if type(child_key) ~= "number"
				or not math.isfinite(child_key)
				or math.floor(child_key) ~= child_key
				or child_key < 1
			then
				return target, false
			end
		end
		local target_table = target :: { [number]: JsonValue }
		target_table[key] = value
		return target, true
	end

	local function reconcile_value(target: JsonValue, target_template: JsonValue): (JsonValue, boolean)
		if type(target) ~= "table" or type(target_template) ~= "table" then
			return target, false
		end
		local result = target
		local changed = false
		for key, template_child in target_template do
			if type(key) ~= "string" and type(key) ~= "number" then
				return target, false
			end
			local current = get_table_child(result, key)
			if current == nil then
				local updated, updated_ok = set_table_child(result, key, template_child)
				if updated_ok then
					result = updated
					changed = true
				end
			elseif type(current) == "table" and type(template_child) == "table" then
				local _, nested_changed = reconcile_value(current, template_child)
				if nested_changed then
					changed = true
				end
			end
		end
		return result, changed
	end

	local next_value, changed = reconcile_value(copied, template_copy)
	if next_value == nil then
		return "validation", "reconciliation returned nil"
	end
	local valid, message = validate_value(next_value, state.options.validator)
	if not valid then
		return "validation", message
	end
	local skip_sync_external_mutation_check = state.options.on_event == nil and next(state.change_observers) == nil
	state.data = next_value
	state.public_data_source = copy_value(state.data)
	self.Data = state.data
	if changed == true then
		state.change_sequence += 1
		local operation_id = HttpService:GenerateGUID(false)
		state.current_operation_id = operation_id
		enqueue_change_observation(state, old_data, next_value, operation_id, "reconcile")
		state.save_requested = true
		state.next_autosave = now_local()
	end
	observe(state, "reconcile", "success", nil)
	sync_public(self, skip_sync_external_mutation_check)
	return "success", nil
end

local function message(self: Record, message_type: string, data: JsonValue?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if not messaging_enabled(state) then
		return "invalid", "messaging is disabled"
	end
	if type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH then
		return "invalid", "message_type must be 1 to 100 characters"
	end
	if data ~= nil then
		local valid, validation_message = validate_serialized_size(data)
		if not valid then
			return "validation", validation_message
		end
	end
	local ok, message_error = publish_record_message(state, "message", message_type, data, nil, nil, nil)
	if not ok then
		observe(state, "message_publish", "unknown", message_error)
		return "unknown", message_error
	end
	observe(state, "message_publish", "success", message_type)
	return "success", nil
end

local function enqueue(self: Record, message_type: string, data: JsonValue?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	return enqueue_internal(state, message_type, data)
end

local function process_queue(self: Record, max_messages: number?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	return process_queue_internal(state, max_messages or 1)
end

local function get_queue(self: Record): ({ QueueMessage }, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return {}, "invalid", "record does not exist"
	end
	if state.options.durable_queue_enabled == false then
		return {}, "success", nil
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return {}, "invalid", "durable queue is disabled"
	end
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then
		return {}, "invalid", deadline_error
	end
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return {}, migration_code, migration_message
	end
	local raw, _, result_code, result_message = backend_get(backend, false, deadline)
	if result_code ~= nil then
		return {}, result_code, result_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local queue, parse_error, owner_mismatch = parse_queue_envelope(raw, owner)
	if queue == nil then
		return {}, if owner_mismatch then "conflict" else "corrupt", parse_error or "durable queue is corrupt"
	end
	local result: { QueueMessage } = {}
	for _, item in ipairs(queue.messages) do
		result[#result + 1] = queue_item_to_public(item)
	end
	return result, "success", nil
end

local function get_dead_letters(self: Record): ({ DeadLetterMessage }, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return {}, "invalid", "record does not exist"
	end
	if state.options.durable_queue_enabled == false then
		return {}, "success", nil
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return {}, "invalid", "durable queue is disabled"
	end
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then
		return {}, "invalid", deadline_error
	end
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return {}, migration_code, migration_message
	end
	local raw, _, result_code, result_message = backend_get(backend, false, deadline, state)
	if result_code ~= nil then
		return {}, result_code, result_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local queue, parse_error, owner_mismatch = parse_queue_envelope(raw, owner)
	if queue == nil then
		return {}, if owner_mismatch then "conflict" else "corrupt", parse_error or "durable queue is corrupt"
	end
	local result: { DeadLetterMessage } = {}
	for _, item in ipairs(queue.dead_letters) do
		result[#result + 1] = dead_letter_to_public(item)
	end
	return result, "success", nil
end

local function claim_dead_letter(self: Record, message_id: string): (DeadLetterMessage?, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return nil, "invalid", "record does not exist"
	end
	if type(message_id) ~= "string" or message_id == "" or #message_id > 100 then
		return nil, "invalid", "message_id must be a non-empty string of at most 100 characters"
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return nil, "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(
		state.name,
		state.scope,
		state.key,
		state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME,
		state.backend.mock,
		deadline,
		state
	)
	if migration_code ~= nil then
		return nil, migration_code, migration_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local token = HttpService:GenerateGUID(false)
	local lease_duration = state.options.queue_lease_duration or DEFAULT_QUEUE_LEASE_DURATION
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = "corrupt"
			decision_message = "durable queue is corrupt or owned by another record"
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_dead_letters = table.clone(queue.dead_letters)
		for index, item in ipairs(queue.dead_letters) do
			if item.id == message_id then
				if item.lock_token == token and item.locked_until > transform_time then
					decision = "success"
					return nil, nil, nil
				end
				if item.locked_until > transform_time then
					decision = "busy"
					decision_message = "dead letter is already claimed by another worker"
					return nil, nil, nil
				end
				local next_item: DeadLetterItem = {
					id = item.id,
					type = item.type,
					data = copy_value(item.data),
					attempts = item.attempts,
					total_attempts = item.total_attempts,
					replay_count = item.replay_count,
					last_replay_token = item.last_replay_token,
					sender_job_id = item.sender_job_id,
					created_at = item.created_at,
					locked_until = transform_time + lease_duration,
					lock_token = token,
					dead_lettered_at = item.dead_lettered_at,
					last_error = item.last_error,
					terminal_lock_token = item.terminal_lock_token,
				}
				next_dead_letters[index] = next_item
				local next_queue = make_queue_envelope(owner, queue.messages, next_dead_letters)
				local size_error = queue_size_error(next_queue, max_bytes)
				if size_error ~= nil then
					decision = "validation"
					decision_message = size_error
					return nil, nil, nil
				end
				decision = "success"
				return next_queue, nil, nil
			end
		end
		decision = "conflict"
		decision_message = "dead letter was not found"
		return nil, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return nil, result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return nil, verify_code or "unknown", verify_message
	end
	local verification_time = queue_now_unix(backend.mock)
	for _, item in ipairs(queue.dead_letters) do
		if item.id == message_id and item.lock_token == token and item.locked_until > verification_time then
			return dead_letter_to_public(item), "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return nil, decision, decision_message or result_message
	end
	return nil, "conflict", "dead-letter claim expired or could not be verified"
end

local function replay_dead_letter(self: Record, message_id: string, lock_token: string): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(message_id) ~= "string" or message_id == "" or #message_id > 100 or type(lock_token) ~= "string" or lock_token == "" then
		return "invalid", "message_id and lock_token must be non-empty strings"
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(state.name, state.scope, state.key, state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME, state.backend.mock, deadline, state)
	if migration_code ~= nil then
		return migration_code, migration_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local max_messages = state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = "corrupt"
			decision_message = "durable queue is corrupt or owned by another record"
			return nil, nil, nil
		end
		for _, item in ipairs(queue.messages) do
			if item.id == message_id and item.last_replay_token == lock_token then
				decision = "success"
				return nil, nil, nil
			end
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_dead_letters: { DeadLetterItem } = {}
		local replayed: DeadLetterItem? = nil
		for _, item in ipairs(queue.dead_letters) do
			if item.id == message_id then
				if item.lock_token ~= lock_token or item.locked_until <= transform_time then
					decision = "conflict"
					decision_message = "dead-letter lock token is stale or expired"
					return nil, nil, nil
				end
				replayed = item
			else
				next_dead_letters[#next_dead_letters + 1] = item
			end
		end
		if replayed == nil then
			decision = "conflict"
			decision_message = "dead letter was not found"
			return nil, nil, nil
		end
		if #queue.messages >= max_messages then
			decision = "validation"
			decision_message = "active durable queue is full; dead letter was preserved"
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		next_messages[#next_messages + 1] = {
			id = replayed.id,
			type = replayed.type,
			data = copy_value(replayed.data),
			attempts = 0,
			total_attempts = replayed.total_attempts,
			replay_count = replayed.replay_count + 1,
			last_replay_token = lock_token,
			sender_job_id = replayed.sender_job_id,
			created_at = replayed.created_at,
			locked_until = 0,
			lock_token = nil,
		}
		local next_queue = make_queue_envelope(owner, next_messages, next_dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			decision = "validation"
			decision_message = "dead-letter replay was not applied: " .. size_error
			return nil, nil, nil
		end
		decision = "success"
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return verify_code or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id and item.last_replay_token == lock_token then
			return "success", nil
		end
	end
	if decision ~= nil and decision ~= "success" then
		return decision, decision_message or result_message
	end
	return "conflict", "dead-letter replay could not be verified"
end

local function discard_dead_letter(self: Record, message_id: string, lock_token: string): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if type(message_id) ~= "string" or message_id == "" or #message_id > 100 or type(lock_token) ~= "string" or lock_token == "" then
		return "invalid", "message_id and lock_token must be non-empty strings"
	end
	local backend = queue_backend_for_state(state)
	if backend == nil then
		return "invalid", "durable queue is disabled"
	end
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local migration_code, migration_message = ensure_legacy_queue_clear(state.name, state.scope, state.key, state.options.queue_store_name or DEFAULT_QUEUE_STORE_NAME, state.backend.mock, deadline, state)
	if migration_code ~= nil then
		return migration_code, migration_message
	end
	local owner = make_queue_owner(state.name, state.scope, state.key)
	local max_bytes = state.options.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local decision: ResultCode? = nil
	local decision_message: string? = nil
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		decision = nil
		decision_message = nil
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil then
			decision = "corrupt"
			decision_message = "durable queue is corrupt or owned by another record"
			return nil, nil, nil
		end
		local transform_time = queue_now_unix(backend.mock)
		local next_dead_letters: { DeadLetterItem } = {}
		local found = false
		for _, item in ipairs(queue.dead_letters) do
			if item.id == message_id then
				if item.lock_token ~= lock_token or item.locked_until <= transform_time then
					decision = "conflict"
					decision_message = "dead-letter lock token is stale or expired"
					return nil, nil, nil
				end
				found = true
			else
				next_dead_letters[#next_dead_letters + 1] = item
			end
		end
		if not found then
			decision = "conflict"
			decision_message = "dead letter was not found"
			return nil, nil, nil
		end
		local next_queue = make_queue_envelope(owner, queue.messages, next_dead_letters)
		local size_error = queue_size_error(next_queue, max_bytes)
		if size_error ~= nil then
			decision = "validation"
			decision_message = size_error
			return nil, nil, nil
		end
		decision = "success"
		return next_queue, nil, nil
	end, deadline, state)
	if result_code ~= nil and result_code ~= "unknown" then
		return result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, state, owner)
	if queue == nil then
		return verify_code or "unknown", verify_message
	end
	for _, item in ipairs(queue.dead_letters) do
		if item.id == message_id then
			if decision ~= nil and decision ~= "success" then
				return decision, decision_message or result_message
			end
			return "conflict", "dead letter remains after discard verification"
		end
	end
	return "success", nil
end

local function close_record(self: Record): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = close_internal(state, false)
	sync_public(self)
	return result, message
end

local function delete_record(self: Record): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	if state.retired then
		return "invalid", "record has been retired"
	end
	if closing then
		return "closing", "server is shutting down"
	end
	if state.state ~= "active" then
		return if state.state == "tombstoned" then "tombstoned" else "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy then
		return "busy", "record has a durable operation in flight"
	end
	if state.queue_busy then
		return "busy", "durable queue is being processed"
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local generation = state.generation
	local next_generation = generation + 1
	local target_revision = state.revision + 1
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "releasing"
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	local last_error: string? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			return "closing", "record was retired"
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id
				and envelope.session == nil
				and envelope.tombstone ~= nil
				and envelope.tombstone.generation == next_generation
				and envelope.fencing_generation == next_generation
				and envelope.revision == target_revision
			then
				decision = "success"
				return envelope, envelope.user_ids, (if info ~= nil then info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.session == nil or envelope.session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			if envelope.revision ~= state.revision then
				decision = "conflict"
				decision_message = "durable revision changed unexpectedly"
				return nil, nil, nil
			end
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = target_revision,
				fencing_generation = next_generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = nil,
				user_ids = clone_user_ids(state.user_ids),
				tombstone = {
					deleted_at = transform_time,
					generation = next_generation,
				},
				session = nil,
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			return next_envelope, state.user_ids, make_backend_metadata(state.metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if state.retired or state.state ~= "releasing" then
			state.busy = false
			return "closing", "delete was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and returned.session == nil and returned.tombstone ~= nil and returned.fencing_generation == next_generation and returned.revision == target_revision and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "conflict" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "delete", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			return "validation", decision_message
		end
		last_error = result_message or "delete response did not confirm the requested delete"
		local verified, envelope, info_after = verify_release_write(state, write_id, next_generation, target_revision, true, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		state.busy = false
		state.state = "unknown"
		observe(state, "delete", "unknown", last_error or "delete outcome is unresolved")
		return "unknown", last_error or "delete outcome is unresolved"
	end
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "delete")
	state.saved_change_sequence = state.change_sequence
	state.data = nil
	state.public_data_source = nil
	state.token = nil
	state.durable_lease_until = 0
	state.generation = confirmed.fencing_generation
	state.revision = confirmed.revision
	state.created_at = confirmed.created_at
	state.updated_at = confirmed.updated_at
	update_state_metadata_from_info(state, confirmed_info)
	state.tombstoned = true
	state.busy = false
	state.state = "tombstoned"
	state.next_autosave = math.huge
	state.next_renewal = math.huge
	state.takeover_requested = false
	state.queue_hint = false
	disconnect_message_subscription(state)
	observe(state, "delete", "deleted", nil)
	sync_public(self)
	return "deleted", nil
end

verify_snapshot_write = function(state: InternalState, write_id: string, token: string, generation: number, revision: number, operation_deadline: number): (boolean, Envelope?, BackendInfo?)
	local deadline = math.min(operation_deadline, now_local() + 5)
	local raw, info, result_code = backend_get(state.backend, false, deadline, state)
	if result_code ~= nil then
		return false, nil, nil
	end
	local envelope = parse_envelope(raw)
	if envelope == nil then
		return false, nil, nil
	end
	if envelope.write_id ~= write_id or envelope.revision ~= revision or not matches_session(envelope, token, generation) or envelope.session == nil or envelope.session.lease_until <= session_now_unix(state.backend.mock) or not backend_metadata_matches(info, envelope) then
		return false, nil, nil
	end
	return true, envelope, info
end

verify_release_write = function(state: InternalState, write_id: string, generation: number, revision: number, tombstone: boolean, operation_deadline: number): (boolean, Envelope?, BackendInfo?)
	local deadline = math.min(operation_deadline, now_local() + 5)
	local raw, info, result_code = backend_get(state.backend, false, deadline, state)
	if result_code ~= nil then
		return false, nil, nil
	end
	local envelope = parse_envelope(raw)
	if envelope == nil or envelope.write_id ~= write_id or envelope.fencing_generation ~= generation or envelope.revision ~= revision or envelope.session ~= nil or not backend_metadata_matches(info, envelope) then
		return false, nil, nil
	end
	if tombstone and envelope.tombstone == nil then
		return false, nil, nil
	end
	if not tombstone and envelope.tombstone ~= nil then
		return false, nil, nil
	end
	return true, envelope, info
end

local function verify_open_write(state: InternalState, write_id: string, token: string, operation_deadline: number): (boolean, Envelope?, BackendInfo?)
	local deadline = math.min(operation_deadline, now_local() + 5)
	local raw, info, result_code = backend_get(state.backend, false, deadline, state)
	if result_code ~= nil then
		return false, nil, nil
	end
	local envelope = parse_envelope(raw)
	if envelope == nil or envelope.write_id ~= write_id or envelope.session == nil or envelope.session.token ~= token or envelope.session.generation ~= envelope.fencing_generation or envelope.session.lease_until <= session_now_unix(state.backend.mock) or not backend_metadata_matches(info, envelope) then
		return false, nil, nil
	end
	return true, envelope, info
end

local function open_internal(state: InternalState, default_data: JsonValue?, recreate: boolean?): (ResultCode, string?)
	local function recover_corrupt_history(
		state: InternalState,
		observed_version: string,
		corrupt_reason: string,
		deadline: number
	): (HistoryRecoveryCandidate?, ResultCode, string?)
		local remaining = math.max(0, deadline - now_local())
		if remaining <= 0 then
			return nil, "budget", "corruption recovery deadline expired before history scan"
		end
		local entries, list_result, list_message = list_versions_internal(
			state.name,
			state.scope,
			state.key,
			Enum.SortDirection.Descending,
			nil,
			nil,
			12,
			remaining,
			state.backend.mock
		)
		if list_result ~= "success" or entries == nil then
			return nil, list_result, list_message or "version history could not be read"
		end

		local current_index: number? = nil
		for index, entry in ipairs(entries) do
			if entry.Version == observed_version then
				current_index = index
				break
			end
		end
		if current_index == nil then
			return nil, "conflict", "current corrupt version was not present in version history; recovery was refused"
		end

		local last_rejection = "no earlier version was available"
		for index = current_index + 1, #entries do
			if now_local() >= deadline then
				return nil, "budget", "corruption recovery deadline expired while scanning history"
			end
			local entry = entries[index]
			if entry.IsDeleted then
				return nil, "tombstoned", "the newest historical version is deleted; automatic recovery was refused"
			end

			local remaining_for_read = math.max(0, deadline - now_local())
			if remaining_for_read <= 0 then
				return nil, "budget", "corruption recovery deadline expired before historical read"
			end
			local snapshot, read_result, read_message = get_version_internal(
				state.name,
				state.scope,
				state.key,
				entry.Version,
				remaining_for_read,
				state.options.legacy_decoder,
				state.backend.mock
			)
			if read_result == "future_schema" then
				return nil, "future_schema", read_message or "a historical version uses a newer schema"
			end
			if read_result == "budget" or read_result == "unknown" then
				return nil, read_result, read_message or "historical version read failed"
			end
			if snapshot == nil then
				last_rejection = read_message or "historical envelope failed validation"
				continue
			end
			if snapshot.Tombstoned then
				return nil, "tombstoned", "the newest valid historical version is deleted; automatic recovery was refused"
			end
			if snapshot.SessionActive then
				return nil, "locked", "the newest valid historical version still has a live owner lease"
			end
			if snapshot.Data == nil then
				last_rejection = "historical envelope has no player data"
				continue
			end

			local migrated, migration_error = apply_migrations(state, snapshot.SchemaVersion, snapshot.Data)
			if migrated == nil then
				if migration_error == "stored schema is newer than this server supports" then
					return nil, "future_schema", migration_error
				end
				last_rejection = migration_error or "historical schema migration failed"
				continue
			end
			local valid, validation_error = validate_value(migrated, state.options.validator)
			if not valid then
				last_rejection = validation_error or "historical player data failed validation"
				continue
			end

			local recovered_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = snapshot.Revision,
				fencing_generation = snapshot.Generation,
				created_at = snapshot.CreatedAt,
				updated_at = snapshot.UpdatedAt,
				data = migrated,
				user_ids = clone_user_ids(snapshot.UserIds),
				tombstone = nil,
				session = nil,
				write_id = "history-recovery-" .. HttpService:GenerateGUID(false),
			}
			local envelope_valid, envelope_error = validate_envelope(recovered_envelope)
			if not envelope_valid then
				last_rejection = envelope_error or "recovered historical envelope is invalid"
				continue
			end
			return {
				ObservedVersion = observed_version,
				SourceVersion = entry.Version,
				CorruptReason = corrupt_reason,
				Envelope = recovered_envelope,
				UserIds = clone_user_ids(snapshot.UserIds),
				Metadata = clone_metadata(snapshot.Metadata),
			}, "success", nil
		end
		return nil, "corrupt", "no safe historical version was found; current version was left untouched (current version: " .. corrupt_reason .. "; last historical rejection: " .. last_rejection .. ")"
	end
	if closing then
		return "closing", "server is shutting down"
	end
	if state.state == "active" then
		return "already_open", nil
	end
	if state.busy or state.state == "acquiring" or state.state == "releasing" then
		return "busy", "record has a durable operation in flight"
	end
	if recreate ~= nil and type(recreate) ~= "boolean" then
		return "invalid", "recreate must be a boolean"
	end
	if state.retired then
		return "invalid", "record has been retired"
	end
	local default_copy: JsonValue? = state.pending_open_default_data
	local copy_error: string? = nil
	if state.pending_open_token == nil then
		local copy_ok, copied_or_error = pcall(function()
			return copy_value(default_data)
		end)
		if copy_ok then
			default_copy = copied_or_error
		else
			copy_error = tostring(copied_or_error)
		end
		if not copy_ok then
			return "validation", copy_error or "default data is invalid"
		end
	end
	if default_copy ~= nil then
		local valid, message = validate_value(default_copy, state.options.validator)
		if not valid then
			return "validation", message
		end
	end
	local token = state.pending_open_token or HttpService:GenerateGUID(false)
	local write_id = state.pending_open_write_id or HttpService:GenerateGUID(false)
	state.pending_open_token = token
	state.pending_open_write_id = write_id
	state.pending_open_default_data = default_copy
	state.current_operation_id = write_id
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "acquiring"
	local last_error: string? = nil
	local last_result: ResultCode? = nil
	local final_decision: ResultCode? = nil
	local final_decision_message: string? = nil
	local recovery_candidate: HistoryRecoveryCandidate? = nil
	local recovery_checked = false
	local recovery_applied = false
	local created = false
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts + 1 do
		if attempt > attempts and recovery_candidate == nil then
			break
		end
		if state.retired then
			state.busy = false
			state.state = "closed"
			disconnect_message_subscription(state)
			return "closing", "record was retired"
		end
		if now_local() >= deadline then
			break
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local locked_generation: number? = nil
		local locked_job_id: string? = nil
		local locked_token: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, backend_info)
			decision = nil
			decision_message = nil
			locked_generation = nil
			locked_job_id = nil
			locked_token = nil
			created = false
			local commit_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			local recovering_history = false
			if raw ~= nil and not current_format and parse_error ~= "legacy payload" and parse_error ~= "future implementation version" and recovery_candidate ~= nil then
				if backend_info == nil or backend_info.Version ~= recovery_candidate.ObservedVersion then
					decision = "conflict"
					decision_message = "current version changed after corruption recovery was prepared"
					return nil, nil, nil
				end
				envelope = recovery_candidate.Envelope
				current_format = true
				recovering_history = true
				recovery_applied = true
			end
			if raw == nil then
				envelope = {
					implementation_version = IMPLEMENTATION_VERSION,
					schema_version = state.options.schema_version,
					revision = 0,
					fencing_generation = 0,
					created_at = commit_time,
					updated_at = commit_time,
					data = default_copy,
					user_ids = clone_user_ids(state.user_ids),
					tombstone = nil,
					session = nil,
					write_id = write_id,
				}
			elseif not current_format then
				if parse_error == "future implementation version" then
					decision = "future_schema"
					decision_message = parse_error
					return nil, nil, nil
				elseif parse_error ~= "legacy payload" then
					decision = "corrupt"
					decision_message = parse_error or "durable envelope is invalid"
					return nil, nil, nil
				end
				local legacy_decoder = state.options.legacy_decoder
				if legacy_decoder == nil then
					decision = "legacy"
					decision_message = "legacy payload requires a legacy_decoder"
					return nil, nil, nil
				end
				local legacy_value, legacy_version, decoder_error = run_legacy_decoder(legacy_decoder, raw)
				if legacy_value == nil then
					decision = "legacy"
					decision_message = decoder_error or "legacy decoder failed"
					return nil, nil, nil
				end
				envelope = {
					implementation_version = IMPLEMENTATION_VERSION,
					schema_version = legacy_version or 0,
					revision = 0,
					fencing_generation = 0,
					created_at = commit_time,
					updated_at = commit_time,
					data = legacy_value,
					user_ids = if backend_info ~= nil then clone_user_ids(backend_info.UserIds) else clone_user_ids(state.user_ids),
					tombstone = nil,
					session = nil,
					write_id = write_id,
				}
			elseif envelope == nil then
				decision = "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope == nil then
				decision = "corrupt"
				decision_message = "durable envelope is missing"
				return nil, nil, nil
			end
			if envelope.write_id == write_id
				and envelope.session ~= nil
				and envelope.session.token == token
				and envelope.session.generation == envelope.fencing_generation
				and envelope.session.job_id == server_id
			then
				if envelope.session.lease_until <= commit_time then
					decision = "fenced"
					decision_message = "confirmed session lease expired before acquisition could be verified"
					return nil, nil, nil
				end
				decision = "success"
				return envelope, envelope.user_ids, (if backend_info ~= nil then backend_info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "stored schema is newer than this server supports"
				return nil, nil, nil
			end
			local current_time = commit_time
			if envelope.session ~= nil and envelope.session.lease_until > current_time then
				decision = "locked"
				decision_message = "record is owned by another live session"
				locked_generation = envelope.fencing_generation
				locked_job_id = envelope.session.job_id
				locked_token = envelope.session.token
				return nil, nil, nil
			end
			if envelope.tombstone ~= nil and not recreate then
				decision = "tombstoned"
				decision_message = "record is tombstoned and requires deliberate recreation"
				return nil, nil, nil
			end
			local next_value = envelope.data
			if next_value == nil then
				next_value = default_copy
			end
			if next_value == nil then
				decision = "validation"
				decision_message = "default data is required for a new record"
				return nil, nil, nil
			end
			local working = copy_value(next_value)
			if working == nil then
				decision = "validation"
				decision_message = "record data could not be copied"
				return nil, nil, nil
			end
			local migrated, migration_error = apply_migrations(state, envelope.schema_version, working)
			if migrated == nil then
				decision = if migration_error == "stored schema is newer than this server supports" then "future_schema" else "migration"
				decision_message = migration_error
				return nil, nil, nil
			end
			local final_valid, final_message = validate_value(migrated, state.options.validator)
			if not final_valid then
				decision = "validation"
				decision_message = final_message
				return nil, nil, nil
			end
			local next_generation = math.max(1, envelope.fencing_generation + 1)
			created = raw == nil or envelope.tombstone ~= nil
			local is_new_record = raw == nil or envelope.tombstone ~= nil
			local initial_ids = if is_new_record then clone_user_ids(state.user_ids) elseif recovering_history and recovery_candidate ~= nil then clone_user_ids(recovery_candidate.UserIds) elseif backend_info ~= nil then clone_user_ids(backend_info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {}
			local initial_metadata = if is_new_record then clone_metadata(state.metadata) elseif recovering_history and recovery_candidate ~= nil then clone_metadata(recovery_candidate.Metadata) elseif backend_info ~= nil then clone_metadata(backend_info.Metadata) else {}
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = if envelope.tombstone ~= nil then envelope.revision + 1 else envelope.revision,
				fencing_generation = next_generation,
				created_at = if envelope.created_at > 0 then envelope.created_at else commit_time,
				updated_at = commit_time,
				data = migrated,
				user_ids = initial_ids,
				tombstone = nil,
				session = {
					token = token,
					generation = next_generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = commit_time,
					lease_until = commit_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				write_id = write_id,
			}
			local envelope_valid, envelope_error = validate_envelope(next_envelope)
			if not envelope_valid then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			decision = "success"
			return next_envelope, initial_ids, make_backend_metadata(initial_metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if state.retired or state.state ~= "acquiring" then
			state.busy = false
			disconnect_message_subscription(state)
			return "closing", "open was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and returned.session ~= nil and returned.session.token == token and returned.session.generation == returned.fencing_generation then
				if returned.session.lease_until > session_now_unix(state.backend.mock) then
					confirmed = returned
					confirmed_info = info
					break
				end
				final_decision = "fenced"
				final_decision_message = "confirmed session lease expired before acquisition could be verified"
				break
			end
		end
		if decision == "corrupt" and not recovery_checked then
			recovery_checked = true
			local observed_raw, observed_info, observed_read_result, observed_read_message = backend_get(
				state.backend,
				false,
				deadline,
				state
			)
			if observed_read_result ~= nil then
				if is_retryable_result(observed_read_result, "open") and attempt < attempts + 1 then
					recovery_checked = false
					last_result = observed_read_result
					last_error = observed_read_message
					task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
					continue
				end
				final_decision = observed_read_result
				final_decision_message = observed_read_message
				break
			end
			if observed_raw == nil then
				if attempt < attempts + 1 then
					continue
				end
				final_decision = "conflict"
				final_decision_message = "record changed while corruption was being inspected; retry the open"
				break
			end
			local _, observed_parse_error, observed_current_format = parse_envelope(observed_raw)
			if observed_current_format then
				if attempt < attempts + 1 then
					continue
				end
				final_decision = "conflict"
				final_decision_message = "record was repaired or replaced while corruption was being inspected"
				break
			end
			if observed_parse_error == "legacy payload" then
				final_decision = "legacy"
				final_decision_message = "record changed to a legacy payload while corruption was being inspected"
				break
			end
			if observed_info == nil or observed_info.Version == nil then
				final_decision = "corrupt"
				final_decision_message = (observed_parse_error or "durable envelope is invalid") .. "; current version metadata is unavailable, so history recovery was refused"
				break
			end
			local candidate, recovery_result, recovery_message = recover_corrupt_history(
				state,
				observed_info.Version,
				observed_parse_error or "durable envelope is invalid",
				deadline
			)
			if candidate ~= nil then
				recovery_candidate = candidate
				if attempt < attempts + 1 then
					continue
				end
				final_decision = "retry_exhausted"
				final_decision_message = "a safe historical version was found but no open attempt remained to restore it"
				break
			end
			if recovery_result == "locked" or recovery_result == "tombstoned" or recovery_result == "future_schema" or recovery_result == "conflict" then
				final_decision = recovery_result
				final_decision_message = recovery_message
				break
			end
			if is_retryable_result(recovery_result, "open") and attempt < attempts + 1 then
				recovery_checked = false
				last_result = recovery_result
				last_error = recovery_message
				task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
				continue
			end
			final_decision = recovery_result
			final_decision_message = recovery_message
			break
		end
		if decision == "locked" then
			if not takeover_enabled(state) then
				final_decision = "locked"
				final_decision_message = decision_message
				break
			end
			if locked_generation ~= nil and locked_job_id ~= nil and locked_token ~= nil then
				local _, handoff_status = request_takeover(state, locked_generation, locked_job_id, locked_token, deadline)
				if handoff_status == "released" and attempt < attempts then
					continue
				end
				if (handoff_status == "accepted" or handoff_status == "pending" or handoff_status == "failed" or handoff_status == "busy") and attempt < attempts then
					task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
					continue
				end
			end
			final_decision = "locked"
			final_decision_message = decision_message
			break
		end
		if decision == "fenced" then
			final_decision = "fenced"
			final_decision_message = decision_message or "session lease is no longer valid"
			break
		end
		if decision == "legacy" or decision == "tombstoned" or decision == "validation" or decision == "migration" or decision == "future_schema" or decision == "corrupt" or decision == "conflict" then
			final_decision = decision
			final_decision_message = decision_message
			break
		end
		if result == nil and result_code ~= nil then
			if not is_retryable_result(result_code, "open") then
				final_decision = result_code
				final_decision_message = result_message
				break
			end
			last_result = result_code
			last_error = result_message
		end
		local verified, envelope, info_after = verify_open_write(state, write_id, token, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if result == nil and decision ~= nil then
			last_error = decision_message
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed ~= nil then
		if recovery_applied and recovery_candidate ~= nil then
			warn(("[RecordStore][CorruptionRecovery] status=recovered store=%s scope=%s key=%s reason=%s sourceVersion=%s replacedVersion=%s revision=%d; corrupt version preserved in DataStore version history"):format(
				state.name,
				state.scope,
				state.key,
				recovery_candidate.CorruptReason,
				recovery_candidate.SourceVersion,
				recovery_candidate.ObservedVersion,
				confirmed.revision
				))
		end
		state.pending_open_token = nil
		state.pending_open_write_id = nil
		state.pending_open_default_data = nil
		update_local_from_envelope(state, confirmed, confirmed_info)
		state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "open")
		state.change_sequence = 0
		state.saved_change_sequence = 0
		state.busy = false
		state.state = "active"
		state.next_autosave = now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL) * (0.9 + math.random() * 0.2)
		state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
		state.next_queue_poll = now_local() + (state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL) * (0.5 + math.random())
		state.queue_hint = false
		local open_result: ResultCode = if created then "created" else "loaded"
		observe(state, "open", open_result, nil)
		return open_result, nil
	end
	state.busy = false
	disconnect_message_subscription(state)
	if final_decision ~= nil then
		state.pending_open_token = nil
		state.pending_open_write_id = nil
		state.pending_open_default_data = nil
		state.state = if final_decision == "tombstoned" then "tombstoned" elseif final_decision == "future_schema" then "future" elseif final_decision == "corrupt" then "corrupt" elseif final_decision == "fenced" then "fenced" else "closed"
		observe(state, "open", final_decision, final_decision_message)
		return final_decision, final_decision_message
	end
	local unresolved_result = last_result or "unknown"
	state.state = if unresolved_result == "unknown" or unresolved_result == "retry_exhausted" then "unknown" else "closed"
	observe(state, "open", unresolved_result, last_error or "session acquisition was not confirmed")
	return unresolved_result, last_error or "session acquisition was not confirmed"
end

local function renew_internal(state: InternalState): (ResultCode, string?)
	if state.retired then
		return "invalid", "record has been retired"
	end
	if closing and not state.shutdown then
		return "closing", "server is shutting down"
	end
	if state.state ~= "active" then
		return "fenced", "record is not actively owned"
	end
	if state.takeover_requested then
		return "closing", "session takeover has been requested"
	end
	if state.busy or state.queue_busy then
		return "busy", (if state.queue_busy then "durable queue is being processed" else "record is already saving")
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local generation = state.generation
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline = now_local() + (state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "saving"
	local last_error: string? = nil
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			return "closing", "record was retired"
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id and matches_session(envelope, session_token, generation) then
				if envelope.session == nil or envelope.session.lease_until <= transform_time then
					decision = "fenced"
					decision_message = "durable session lease has expired"
					return nil, nil, nil
				end
				return envelope, state.user_ids, state.metadata
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.session == nil then
				decision = "fenced"
				decision_message = "durable session is missing"
				return nil, nil, nil
			end
			if envelope.session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			local durable_user_ids = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else {}
			local durable_metadata = if info ~= nil then clone_metadata(info.Metadata) else state.metadata
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = envelope.schema_version,
				revision = envelope.revision,
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = envelope.data,
				user_ids = durable_user_ids,
				tombstone = nil,
				session = {
					token = session_token,
					generation = generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = envelope.session.acquired_at,
					lease_until = transform_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			return next_envelope, durable_user_ids, make_backend_metadata(durable_metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if state.retired or state.state ~= "saving" then
			state.busy = false
			return "closing", "renewal was invalidated before its result could be applied"
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and matches_session(returned, session_token, generation) and returned.session ~= nil and returned.session.lease_until > session_now_unix(state.backend.mock) and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" else "corrupt"
			observe(state, "renew", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			return "validation", decision_message
		end
		if result == nil then
			last_error = result_message or decision_message
		end
		local verified, envelope, info_after = verify_snapshot_write(state, write_id, token, generation, state.revision, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		state.busy = false
		state.state = "unknown"
		observe(state, "renew", "unknown", last_error or "renewal outcome is unresolved")
		return "unknown", last_error or "renewal outcome is unresolved"
	end
	local was_dirty = state.change_sequence ~= state.saved_change_sequence
	state.generation = confirmed.fencing_generation
	state.revision = confirmed.revision
	state.created_at = confirmed.created_at
	state.updated_at = confirmed.updated_at
	state.tombstoned = confirmed.tombstone ~= nil
	state.token = if confirmed.session ~= nil then confirmed.session.token else state.token
	state.durable_lease_until = if confirmed.session ~= nil then confirmed.session.lease_until else 0
	state.last_observed = now_unix()
	if not was_dirty then
		state.user_ids = if confirmed_info ~= nil then clone_user_ids(confirmed_info.UserIds) elseif confirmed.user_ids ~= nil then clone_user_ids(confirmed.user_ids) else {}
		state.metadata = if confirmed_info ~= nil then clone_metadata(confirmed_info.Metadata) else state.metadata
	end
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "renew")
	state.busy = false
	state.state = "active"
	state.next_renewal = now_local() + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
	observe(state, "renew", "success", nil)
	complete_deferred_takeover(state)
	return "success", nil
end

close_internal = function(state: InternalState, shutdown: boolean): (ResultCode, string?)
	if state.retired then
		return "closed", nil
	end
	if state.state == "closed" then
		return "closed", nil
	end
	if state.state == "tombstoned" then
		return "closed", nil
	end
	local wait_deadline = now_local() + (if shutdown then state.options.shutdown_deadline or DEFAULT_SHUTDOWN_DEADLINE else state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	while (state.busy or state.queue_busy) and now_local() < wait_deadline do
		task.wait(0.05)
	end
	if state.busy then
		state.state = "unknown"
		observe(state, "close", "unknown", "close deadline expired while another durable operation was in flight")
		return "unknown", "close deadline expired while another durable operation was in flight"
	end
	if state.queue_busy then
		if not shutdown then
			return "busy", "durable queue is being processed"
		end
		state.state = "unknown"
		observe(state, "close", "unknown", "close deadline expired while the durable queue was being processed")
		return "unknown", "close deadline expired while the durable queue was being processed"
	end
	if state.state ~= "active" then
		return if state.state == "fenced" then "fenced" else "unknown", "record is not actively owned"
	end
	local token = state.token
	if token == nil then
		return "fenced", "session token is missing"
	end
	local session_token: string = token
	local generation = state.generation
	local expected_revision = state.revision
	local target_revision = expected_revision + 1
	track_external_data_mutation(state)
	local snapshot = copy_value(state.data)
	local valid, validation_error = validate_value(snapshot, state.options.validator)
	if not valid then
		observe(state, "close", "validation", validation_error)
		return "validation", validation_error
	end
	local write_id = HttpService:GenerateGUID(false)
	state.current_operation_id = write_id
	local deadline = now_local() + (if shutdown then state.options.shutdown_deadline or DEFAULT_SHUTDOWN_DEADLINE else state.options.operation_deadline or DEFAULT_OPERATION_DEADLINE)
	local attempts = if shutdown then state.options.shutdown_attempts or DEFAULT_SHUTDOWN_ATTEMPTS else state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.busy = true
	state.state = "releasing"
	local last_error: string? = nil
	local confirmed: Envelope? = nil
	local confirmed_info: BackendInfo? = nil
	for attempt = 1, attempts do
		if state.retired then
			state.busy = false
			state.state = "closed"
			return "closed", nil
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local transform_time = session_now_unix(state.backend.mock)
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id
				and envelope.session == nil
				and envelope.tombstone == nil
				and envelope.fencing_generation == generation
				and envelope.revision == target_revision
			then
				decision = "success"
				return envelope, envelope.user_ids, (if info ~= nil then info.RawMetadata else make_backend_metadata(state.metadata, envelope))
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token, generation) then
				decision = "fenced"
				decision_message = "durable ownership no longer matches this session"
				return nil, nil, nil
			end
			if envelope.session == nil or envelope.session.lease_until <= transform_time then
				decision = "fenced"
				decision_message = "durable session lease has expired"
				return nil, nil, nil
			end
			if envelope.revision ~= expected_revision then
				decision = "conflict"
				decision_message = "durable revision changed unexpectedly"
				return nil, nil, nil
			end
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = target_revision,
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transform_time,
				data = snapshot,
				user_ids = clone_user_ids(state.user_ids),
				tombstone = nil,
				session = nil,
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error
				return nil, nil, nil
			end
			return next_envelope, state.user_ids, make_backend_metadata(state.metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id and returned.session == nil and returned.revision == target_revision and returned.fencing_generation == generation and backend_metadata_matches(info, returned) then
				confirmed = returned
				confirmed_info = info
				break
			end
		end
		if decision == "fenced" or decision == "future_schema" or decision == "conflict" or decision == "corrupt" then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "close", decision, decision_message)
			return decision, decision_message
		end
		if decision == "validation" then
			state.busy = false
			state.state = "active"
			return "validation", decision_message
		end
		last_error = result_message or decision_message
		local verified, envelope, info_after = verify_release_write(state, write_id, generation, target_revision, false, deadline)
		if verified then
			confirmed = envelope
			confirmed_info = info_after
			break
		end
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	if confirmed == nil then
		state.busy = false
		state.state = "unknown"
		observe(state, "close", "unknown", last_error or "release outcome is unresolved")
		return "unknown", last_error or "release outcome is unresolved"
	end
	update_local_from_envelope(state, confirmed, confirmed_info)
	state.last_saved = make_durable_snapshot(confirmed, confirmed_info, "close")
	state.saved_change_sequence = state.change_sequence
	state.busy = false
	state.state = "closed"
	state.durable_lease_until = 0
	state.next_autosave = math.huge
	state.next_renewal = math.huge
	state.next_queue_poll = math.huge
	state.takeover_requested = false
	state.queue_hint = false
	disconnect_message_subscription(state)
	observe(state, "close", "closed", nil)
	return "closed", nil
end

local function complete_deferred_takeover_work(state: InternalState): { [string]: any }
	if not state.takeover_requested or state.busy or state.state ~= "active" or state.retired then
		return { code = "cancelled", message = "takeover is no longer eligible" }
	end
	local request_id = state.takeover_request_id
	local requester_job_id = state.takeover_requester_job_id
	local result, message = close_internal(state, false)
	if request_id ~= nil and requester_job_id ~= nil then
		local status: HandoffStatus = if result == "closed" then "released" else "failed"
		cache_takeover_status(state, request_id, status)
		publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", status)
	end
	state.takeover_request_id = nil
	state.takeover_requester_job_id = nil
	state.takeover_requested = false
	return { code = if result == "closed" then "success" else result, message = message }
end

complete_deferred_takeover = function(state: InternalState)
	if not state.takeover_requested or state.busy or state.state ~= "active" then
		return
	end
	task.spawn(function()
		complete_deferred_takeover_work(state)
	end)
end

local function save(self: Record, reason: string?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = save_internal(state, reason or "manual", nil, nil)
	sync_public(self)
	return result, message
end

local function stats(self: Record): { [string]: number | string? }
	local state = private[self]
	if state == nil then
		return {}
	end
	return {
		state = state.state,
		generation = state.generation,
		revision = state.revision,
		created_at = state.created_at,
		updated_at = state.updated_at,
		durable_lease_until = state.durable_lease_until,
		busy = if state.busy then 1 else 0,
		queue_busy = if state.queue_busy then 1 else 0,
		save_requested = if state.save_requested then 1 else 0,
		takeover_requested = if state.takeover_requested then 1 else 0,
		queue_hint = if state.queue_hint then 1 else 0,
		observer_errors = state.observer_errors,
		change_events_dropped = state.change_events_dropped,
		takeover_requests_suppressed = state.handoff_requests_suppressed,
		handoff_ack_count = state.handoff_ack_count,
		last_observed = state.last_observed,
		last_error = state.last_error,
		last_saved_revision = if state.last_saved ~= nil then state.last_saved.Revision else 0,
		last_saved_generation = if state.last_saved ~= nil then state.last_saved.Generation else 0,
		last_saved_at = if state.last_saved ~= nil then state.last_saved.ConfirmedAt else 0,
		handoff_status = state.handoff_status,
		handoff_published = if state.handoff_published then 1 else 0,
		change_sequence = state.change_sequence,
		saved_change_sequence = state.saved_change_sequence,
		dirty = if state.change_sequence ~= state.saved_change_sequence then 1 else 0,
	}
end

local function open(self: Record, default_data: JsonValue?, recreate: boolean?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = open_internal(state, default_data, recreate)
	sync_public(self)
	return result, message
end

local function make_record(name: string, scope: string, key: string, options: Options, mock: boolean): Record
	local mode = if mock then "mock" else "live"
	local id = HttpService:JSONEncode({ mode, name, scope, key })
	local existing = records[id]
	if existing ~= nil then
		local existing_state = private[existing]
		if existing_state ~= nil and existing_state.options.schema_version ~= options.schema_version then
			error("record already exists locally with a different schema version", 2)
		end
		return existing
	end
	local initial_ids = clone_user_ids(options.user_ids)
	local normalized_ids, ids_error = normalize_user_ids(initial_ids)
	if normalized_ids == nil then
		error(ids_error, 2)
	end
	local initial_user_ids = normalized_ids
	local initial_metadata = clone_metadata(options.metadata)
	local metadata_valid, metadata_error = validate_metadata(initial_metadata)
	if not metadata_valid then
		error(metadata_error, 2)
	end
	local interval = options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL
	local state: InternalState = {
		name = name,
		scope = scope,
		key = key,
		backend = make_backend(name, scope, key, mock),
		queue_backend = nil,
		queue_legacy_checked = false,
		options = options,
		change_observers = {},
		change_observer_next_id = 1,
		change_dispatch_queue = {},
		change_dispatch_head = 1,
		change_dispatch_tail = 0,
		change_dispatch_running = false,
		change_events_dropped = 0,
		takeover_seen = {},
		takeover_seen_order = {},
		takeover_request_id = nil,
		takeover_requester_job_id = nil,
		handoff_request_id = nil,
		handoff_target_job_id = nil,
		handoff_target_token = nil,
		handoff_target_generation = nil,
		handoff_status = nil,
		handoff_deadline = 0,
		handoff_published = false,
		handoff_last_publish = -math.huge,
		handoff_requests_suppressed = 0,
		handoff_ack_count = 0,
		current_operation_id = nil,
		pending_open_token = nil,
		pending_open_write_id = nil,
		pending_open_default_data = nil,
		last_error_info = nil,
		state = "closed",
		data = nil,
		public_data_source = nil,
		public_record = nil,
		token = nil,
		generation = 0,
		revision = 0,
		created_at = 0,
		updated_at = 0,
		user_ids = initial_user_ids,
		metadata = initial_metadata,
		tombstoned = false,
		next_autosave = now_local() + interval,
		next_renewal = math.huge,
		next_message_subscribe = math.huge,
		next_queue_poll = math.huge,
		busy = false,
		queue_busy = false,
		save_requested = false,
		shutdown = false,
		retired = false,
		takeover_requested = false,
		queue_hint = false,
		message_topic = make_message_topic(options.message_topic_prefix or DEFAULT_MESSAGE_TOPIC_PREFIX, name, scope, key),
		message_subscription = nil,
		last_error = nil,
		last_result = nil,
		last_observed = now_unix(),
		observer_errors = 0,
		last_saved = nil,
		change_sequence = 0,
		saved_change_sequence = 0,
		durable_lease_until = 0,
	}
	local record: Record = {
		Data = nil,
		State = "closed",
		Key = key,
		Generation = 0,
		Revision = 0,
		CreatedAt = 0,
		UpdatedAt = 0,
		Tombstoned = false,
		LastError = nil,
		Open = open,
		Get = get_data,
		GetKey = get_key,
		GetState = get_state,
		GetRevision = get_revision,
		GetGeneration = get_generation,
		IsOpen = is_open,
		GetBackendInfo = get_backend_info,
		GetLastSaved = get_last_saved,
		IsDirty = is_dirty,
		GetLastError = get_last_error_info,
		GetHandoff = get_handoff,
		SubscribeChanges = subscribe_changes,
		GetUserIds = get_user_ids,
		SetUserIds = set_user_ids,
		AddUserId = add_user_id,
		RemoveUserId = remove_user_id,
		GetMetadata = get_metadata,
		SetMetadata = set_metadata,
		UpdateMetadata = update_metadata,
		Touch = touch,
		Update = update,
		Reconcile = reconcile,
		Save = save,
		MessageAsync = message,
		EnqueueAsync = enqueue,
		ProcessQueueAsync = process_queue,
		GetQueueAsync = get_queue,
		GetDeadLettersAsync = get_dead_letters,
		ClaimDeadLetterAsync = claim_dead_letter,
		ReplayDeadLetterAsync = replay_dead_letter,
		DiscardDeadLetterAsync = discard_dead_letter,
		Close = close_record,
		Delete = delete_record,
		Stats = stats,
	}
	state.public_record = record
	private[record] = state
	records[id] = record
	sync_public(record)
	return record
end

local scheduler_governor = RecordStoreScheduler.new({
	now_ms = function() return now_local() * 1000 end,
	now_unix = now_unix,
	get_record_stats = function(record)
		if type(record) ~= "table" or type(record.Stats) ~= "function" then return {} end
		local ok, value = pcall(function() return record:Stats() end)
		return if ok and type(value) == "table" then value else {}
	end,
	get_request_budgets = function()
		local read_ok, read_budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardRead)
		end)
		local write_ok, write_budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.StandardWrite)
		end)
		if not read_ok or not write_ok or type(read_budget) ~= "number" or type(write_budget) ~= "number" then
			return nil
		end
		return { read = read_budget, write = write_budget }
	end,
})
local scheduler_dispatcher: any = RecordStoreScheduler.new_dispatcher(scheduler_governor, {
	now_ms = function() return now_local() * 1000 end,
})
local scheduler_enabled = false
local scheduler_state: { [InternalState]: any } = setmetatable({}, { __mode = "k" })

local function scheduler_owner_id(state: InternalState): string
	local function component(value: string): string
		return tostring(#value) .. ":" .. value
	end
	return component(state.name) .. component(state.scope) .. component(state.key)
end

local function scheduled_state_slot(state: InternalState): any
	local slot = scheduler_state[state]
	if slot == nil then
		slot = { pending = {}, jobs = {}, last_result = {} }
		scheduler_state[state] = slot
	end
	return slot
end

local function enqueue_state_work(
	record: Record,
	state: InternalState,
	kind: string,
	lane: string,
	work_class: string,
	operation_class: string,
	callback: (...any) -> any,
	schedule_options: any?
): any
	local slot = scheduled_state_slot(state)
	if slot.pending[kind] == true then return { code = "already_pending" } end
	local options = if schedule_options == nil then {} else table.clone(schedule_options)
	options.lane = lane
	options.work_class = work_class
	options.operation_class = operation_class
	options.on_complete = function(result)
		slot.pending[kind] = nil
		slot.jobs[kind] = nil
		slot.last_result[kind] = if type(result) == "table" then tostring(result.code or "unknown") else "unknown"
		if kind == "lease_renewal" and type(result) == "table" and result.code == "retry_exhausted" and state.state == "active" then
			state.next_renewal = math.min(state.next_renewal, now_local())
		elseif kind == "autosave" and type(result) == "table" and result.code == "retry_exhausted" and state.state == "active" then
			state.next_autosave = math.min(state.next_autosave, now_local())
		elseif kind == "queue_poll" and type(result) == "table" and result.code == "retry_exhausted" and state.state == "active" then
			state.next_queue_poll = math.min(state.next_queue_poll, now_local())
		end
	end
	-- Set pending before enqueue: the dispatcher is allowed to start synchronously.
	slot.pending[kind] = true
	local result = scheduler_dispatcher:Schedule(
		scheduler_owner_id(state),
		kind .. ":" .. tostring(state.generation),
		function(batch_size: number?)
			if not scheduler_enabled then
				return { code = "cancelled", message = "advanced scheduler was disabled before work started" }
			end
			if closing or state.retired or state.state ~= "active" then
				return { code = "cancelled", message = "record is no longer active" }
			end
			return callback(batch_size)
		end,
		options
	)
	if type(result) ~= "table" or result.code ~= "accepted" then
		slot.pending[kind] = nil
		slot.last_result[kind] = if type(result) == "table" then tostring(result.code) else "unknown"
		return if type(result) == "table" then result else { code = "unknown", message = "scheduler admission returned no result" }
	end
	slot.jobs[kind] = result.id
	return result
end

-- Scheduling never replaces the durable request gate or session fencing.
-- It is disabled until the caller explicitly enables the new selector.
function RecordStore.configure_scheduler_policy(policy: { [string]: unknown }): (string, string?)
	if type(policy) ~= "table" then return "invalid", "scheduler policy must be a table" end
	return scheduler_dispatcher:SetPolicy(policy)
end

function RecordStore.set_scheduler_enabled(enabled: boolean): (boolean, string?)
	if type(enabled) ~= "boolean" then return false, "enabled must be a boolean" end
	scheduler_enabled = enabled
	if enabled then
		scheduler_dispatcher:Kick()
	else
		-- Cancel queued work immediately so a future-due callback cannot retain
		-- capacity or its closure until a timer fires. In-flight callbacks are not
		-- preempted; the wrapper still cancels work that has not started yet.
		scheduler_dispatcher:CancelQueued("advanced scheduler disabled before work started")
	end
	return true, nil
end

function RecordStore.schedule_work(
	owner_id: string,
	work_id: string,
	callback: (...any) -> any,
	schedule_options: { [string]: unknown }?
): { [string]: any }
	if closing then return { code = "closed", message = "RecordStore is shutting down" } end
	if not scheduler_enabled then return { code = "disabled", message = "advanced scheduling is disabled" } end
	if type(schedule_options) == "table"
		and (schedule_options.lane == "lease_renewal" or schedule_options.operation_class == "lease_renewal")
	then
		return { code = "invalid", message = "lease_renewal lane and operation class are reserved for internal session renewal" }
	end
	return scheduler_dispatcher:Schedule(owner_id, work_id, function(batch_size: number?)
		if not scheduler_enabled then
			return { code = "cancelled", message = "advanced scheduling was disabled before work started" }
		end
		return callback(batch_size)
	end, schedule_options)
end

function RecordStore.get_scheduler_snapshot(): { [string]: any }
	local governor = scheduler_governor:Stats()
	return {
		enabled = scheduler_enabled,
		policy = governor.policy,
		governor = governor,
		dispatcher = scheduler_dispatcher:Stats(),
	}
end

function RecordStore.compare_scheduler_shadow(): any
	return scheduler_governor:ShadowDecision()
end

function RecordStore.replay_scheduler_trace(trace: { any }): { any }
	if type(trace) ~= "table" then return { code = "invalid", message = "scheduler trace must be an array" } end
	-- Replay runs against an isolated governor and virtual clock. It must never
	-- enqueue, dequeue or complete work in the live server scheduler.
	local replay_now_ms = now_local() * 1000
	local replay = RecordStoreScheduler.new({
		now_ms = function() return replay_now_ms end,
		advance_ms = function(milliseconds) replay_now_ms += milliseconds end,
	})
	local current_policy = scheduler_governor:Stats().policy
	local replay_policy = replay:Stats().policy
	local policy_patch = table.clone(current_policy)
	policy_patch.revision = replay_policy.revision + 1
	local policy_ok, policy_message = replay:SetPolicy(policy_patch)
	if not policy_ok then return { code = "invalid", message = policy_message } end
	return replay:Replay(trace)
end

local function run_scheduled_record_work(record: Record, state: InternalState, now: number)
	local slot = scheduled_state_slot(state)
	if state.takeover_requested then
		if not state.busy and not state.queue_busy and slot.pending.takeover ~= true then
			enqueue_state_work(record, state, "takeover", "high", "session_takeover", "profile_release", function()
				if not state.takeover_requested then return { code = "cancelled" } end
				if state.busy or state.queue_busy then return { code = "retryable", message = "record is still busy before takeover start" } end
				local result = complete_deferred_takeover_work(state)
				sync_public(record)
				return result
			end, { service_class = "critical", read_units = 1, write_units = 1, max_retries = 4, retry_delay_ms = 25 })
		end
		return
	end

	if not state.busy and not state.queue_busy and now >= state.next_renewal
		and slot.pending.lease_renewal ~= true
	then
		local remaining_ms = if state.durable_lease_until > 0
			then math.max(0, (state.durable_lease_until - now_unix()) * 1000) else nil
		local renewal_options: any = {
			service_class = "critical",
			read_units = 1,
			write_units = 1,
			handler_slots = 1,
			max_retries = 8,
			retry_delay_ms = 25,
			retry_jitter_percent = 10,
		}
		if remaining_ms ~= nil then
			local scheduler_stats = scheduler_governor:Stats()
			local latency = scheduler_stats.latency_ewma or {}
			local tails = scheduler_stats.latency_percentiles_by_operation or {}
			local renewal_tail = if tails.lease_renewal ~= nil then tails.lease_renewal.p95_ms
				elseif tails.update_async ~= nil then tails.update_async.p95_ms
				else nil
			local observed_service_ms = math.max(
				if finite(renewal_tail) then renewal_tail else 0,
				latency.lease_renewal or 0,
				latency.update_async or 0,
				latency.service or 0
			)
			-- Reserve a conservative service-time and current queue-delay margin from
			-- the remaining durable lease. The deadline is advisory; the lease-token
			-- check in renew_internal remains the ownership authority.
			local queue_delay_ms = math.max(0, scheduler_stats.scheduler.oldest_eligible_age_ms or 0)
			local safety_margin_ms = math.max(100, observed_service_ms * 2 + queue_delay_ms)
			local safe_slack_ms = math.max(0, remaining_ms - safety_margin_ms)
			renewal_options.deadline_ms = now_local() * 1000 + safe_slack_ms
		end
		local result = enqueue_state_work(record, state, "lease_renewal", "lease_renewal",
			"profile_lease_renewal", "lease_renewal", function()
				if state.busy or state.queue_busy then
					return { code = "retryable", message = "record became busy before renewal started" }
				end
				local code, message = renew_internal(state)
				sync_public(record)
				-- Do not retry a result returned by the persistence operation. In particular,
				-- an unknown outcome may already have committed.
				return { code = code, message = message }
			end, renewal_options)
		if type(result) == "table" and result.code == "accepted" then
			state.next_renewal = now + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
		end
	elseif not state.busy and not state.queue_busy and now >= state.next_autosave
		and slot.pending.autosave ~= true
	then
		local next_autosave = now + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL) * (0.9 + math.random() * 0.2)
		local result = enqueue_state_work(record, state, "autosave", "normal", "profile_autosave", "update_async", function()
			if state.busy or state.queue_busy then
				return { code = "retryable", message = "record became busy before autosave started" }
			end
			local code, message = save_internal(state, "autosave", nil, nil)
			sync_public(record)
			return { code = code, message = message }
		end, { service_class = "critical", read_units = 1, write_units = 1, handler_slots = 1,
			max_retries = 6, retry_delay_ms = 50, retry_jitter_percent = 10 })
		if type(result) == "table" and result.code == "accepted" then state.next_autosave = next_autosave end
	end

	if state.state == "active"
		and state.options.on_message ~= nil
		and messaging_enabled(state)
		and state.message_subscription == nil
		and now >= state.next_message_subscribe
	then
		subscribe_record(state)
	end

	if state.state == "active"
		and state.options.durable_queue_enabled ~= false
		and state.options.on_queue_message ~= nil
		and slot.pending.queue_poll ~= true
		and (state.queue_hint or now >= state.next_queue_poll)
	then
		local result = enqueue_state_work(record, state, "queue_poll", "background", "mailbox_poll", "read",
			function(batch_size: number?)
				if state.queue_busy then
					return { code = "retryable", message = "queue poll became busy before processing started" }
				end
				state.queue_hint = false
				local bounded_batch_size = if type(batch_size) == "number" then math.clamp(math.floor(batch_size), 1, 4) else 4
				local code, message = process_queue_internal(state, bounded_batch_size)
				sync_public(record)
				local processed_count = if code == "processed" then tonumber(message) else 0
				return {
					code = code,
					message = message,
					processed_count = if finite(processed_count) then processed_count else 0,
				}
			end,
			{ service_class = "normal", read_units = 1, write_units = 1, handler_slots = 1,
				batchable = true, batch_size = 4, batch_backlog = 4, batch_window_ms = 0,
				max_retries = 4, retry_delay_ms = 50, retry_jitter_percent = 10 })
		if type(result) == "table" and result.code == "accepted" then
			state.next_queue_poll = now + (state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL)
		end
	end
end

local function start_scheduler()
	if scheduler_started then return end
	scheduler_started = true
	task.spawn(function()
		while not closing do
			for record in active_records do
				local state = private[record]
				if state ~= nil and state.state == "active" then
					local now = now_local()
					if scheduler_enabled then
						run_scheduled_record_work(record, state, now)
					else
						local handled_takeover = false
						if state.takeover_requested and not state.busy and not state.queue_busy then
							complete_deferred_takeover(state)
							sync_public(record)
							handled_takeover = true
						end
						if not handled_takeover and state.state == "active"
							and not state.busy and not state.queue_busy and now >= state.next_renewal
						then
							state.next_renewal = now + (state.options.lease_renewal or DEFAULT_LEASE_RENEWAL)
							task.spawn(function()
								renew_internal(state)
								sync_public(record)
							end)
						elseif not handled_takeover and state.state == "active"
							and not state.busy and not state.queue_busy and now >= state.next_autosave
						then
							state.next_autosave = now + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL) * (0.9 + math.random() * 0.2)
							task.spawn(function()
								save_internal(state, "autosave", nil, nil)
								sync_public(record)
							end)
						end
						if state.state == "active"
							and state.options.on_message ~= nil
							and messaging_enabled(state)
							and state.message_subscription == nil
							and now >= state.next_message_subscribe
						then subscribe_record(state) end
						if state.state == "active"
							and state.options.durable_queue_enabled ~= false
							and state.options.on_queue_message ~= nil
							and not state.queue_busy
							and (state.queue_hint or now >= state.next_queue_poll)
						then
							state.queue_hint = false
							state.next_queue_poll = now + (state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL)
							task.spawn(function()
								process_queue_internal(state, 4)
								sync_public(record)
							end)
						end
					end
				end
			end
			if scheduler_enabled then scheduler_dispatcher:Kick() end
			task.wait(SCHEDULER_STEP)
		end
	end)
end

local function shutdown()
	if shutdown_started then
		return
	end
	shutdown_started = true
	closing = true
	-- Cancel timers and notify queued work before record release begins. In-flight
	-- persistence callbacks are not preempted and still release their reservations.
	scheduler_dispatcher:Close()
	local closing_records: { Record } = {}
	for record, state in private do
		if state.state ~= "closed" and state.state ~= "tombstoned" and state.state ~= "fenced" and state.state ~= "corrupt" and state.state ~= "future" then
			state.shutdown = true
			disconnect_message_subscription(state)
			table.insert(closing_records, record)
		end
	end
	local remaining = #closing_records
	if remaining == 0 then
		return
	end
	for _, record in ipairs(closing_records) do
		task.spawn(function()
			local state = private[record]
			if state ~= nil then
				close_internal(state, true)
			end
			remaining -= 1
		end)
	end
	local deadline = now_local() + DEFAULT_SHUTDOWN_DEADLINE
	while remaining > 0 and now_local() < deadline do
		task.wait(0.05)
	end
end

local function normalize_options(options: Options): (Options?, string?)
	if type(options) ~= "table" then
		return nil, "options must be a table"
	end
	local copied = table.clone(options)
	if copied.autosave_interval == nil then
		copied.autosave_interval = DEFAULT_AUTOSAVE_INTERVAL
	end
	if copied.lease_duration == nil then
		copied.lease_duration = DEFAULT_LEASE_DURATION
	end
	if copied.lease_renewal == nil then
		copied.lease_renewal = DEFAULT_LEASE_RENEWAL
	end
	if copied.retry_attempts == nil then
		copied.retry_attempts = DEFAULT_RETRY_ATTEMPTS
	end
	if copied.operation_deadline == nil then
		copied.operation_deadline = DEFAULT_OPERATION_DEADLINE
	end
	if copied.shutdown_deadline == nil then
		copied.shutdown_deadline = DEFAULT_SHUTDOWN_DEADLINE
	end
	if copied.shutdown_attempts == nil then
		copied.shutdown_attempts = DEFAULT_SHUTDOWN_ATTEMPTS
	end
	if copied.budget_wait == nil then
		copied.budget_wait = DEFAULT_BUDGET_WAIT
	end
	if copied.messaging_enabled == nil then
		copied.messaging_enabled = true
	end
	if copied.takeover_enabled == nil then
		copied.takeover_enabled = true
	end
	if copied.takeover_wait == nil then
		copied.takeover_wait = DEFAULT_TAKEOVER_WAIT
	end
	if copied.message_topic_prefix == nil then
		copied.message_topic_prefix = DEFAULT_MESSAGE_TOPIC_PREFIX
	end
	if copied.durable_queue_enabled == nil then
		copied.durable_queue_enabled = true
	end
	if copied.queue_store_name == nil then
		copied.queue_store_name = DEFAULT_QUEUE_STORE_NAME
	end
	if copied.queue_poll_interval == nil then
		copied.queue_poll_interval = DEFAULT_QUEUE_POLL_INTERVAL
	end
	if copied.queue_lease_duration == nil then
		copied.queue_lease_duration = DEFAULT_QUEUE_LEASE_DURATION
	end
	if copied.queue_max_messages == nil then
		copied.queue_max_messages = DEFAULT_QUEUE_MAX_MESSAGES
	end
	if copied.queue_max_bytes == nil then
		copied.queue_max_bytes = DEFAULT_QUEUE_MAX_BYTES
	end
	if copied.queue_max_attempts == nil then
		copied.queue_max_attempts = DEFAULT_QUEUE_MAX_ATTEMPTS
	end
	local queue_poll_interval = copied.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL
	local queue_lease_duration = copied.queue_lease_duration or DEFAULT_QUEUE_LEASE_DURATION
	local queue_max_messages = copied.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES
	local queue_max_bytes = copied.queue_max_bytes or DEFAULT_QUEUE_MAX_BYTES
	local queue_max_attempts = copied.queue_max_attempts or DEFAULT_QUEUE_MAX_ATTEMPTS
	if type(copied.messaging_enabled) ~= "boolean" then
		return nil, "messaging_enabled must be a boolean"
	end
	if type(copied.takeover_enabled) ~= "boolean" then
		return nil, "takeover_enabled must be a boolean"
	end
	if type(copied.durable_queue_enabled) ~= "boolean" then
		return nil, "durable_queue_enabled must be a boolean"
	end
	if type(copied.message_topic_prefix) ~= "string" then
		return nil, "message_topic_prefix must be a string of at most 72 characters"
	end
	local topic_prefix_length = utf8.len(copied.message_topic_prefix)
	if topic_prefix_length == nil or topic_prefix_length > 72 then
		return nil, "message_topic_prefix must be valid UTF-8 and at most 72 characters"
	end
	if type(copied.queue_store_name) ~= "string" or copied.queue_store_name == "" or #copied.queue_store_name > 50 then
		return nil, "queue_store_name must be 1 to 50 characters"
	end
	if type(queue_poll_interval) ~= "number" or not math.isfinite(queue_poll_interval) or queue_poll_interval <= 0 then
		return nil, "queue_poll_interval must be a positive finite number"
	end
	if type(queue_lease_duration) ~= "number" or not math.isfinite(queue_lease_duration) or queue_lease_duration <= 0 then
		return nil, "queue_lease_duration must be a positive finite number"
	end
	if type(queue_max_messages) ~= "number" or not math.isfinite(queue_max_messages) or queue_max_messages < 1 or queue_max_messages ~= math.floor(queue_max_messages) then
		return nil, "queue_max_messages must be a positive integer"
	end
	if type(queue_max_bytes) ~= "number" or not math.isfinite(queue_max_bytes) or queue_max_bytes < 1 or queue_max_bytes > MAX_DATASTORE_BYTES then
		return nil, "queue_max_bytes must be between 1 and the DataStore value limit"
	end
	if type(queue_max_attempts) ~= "number" or not math.isfinite(queue_max_attempts) or queue_max_attempts < 1 or queue_max_attempts > MAX_QUEUE_ATTEMPTS or math.floor(queue_max_attempts) ~= queue_max_attempts then
		return nil, "queue_max_attempts must be an integer from 1 to " .. tostring(MAX_QUEUE_ATTEMPTS)
	end
	local function valid_positive_number(value: unknown): boolean
		return type(value) == "number" and math.isfinite(value) and value > 0
	end
	local function valid_nonnegative_number(value: unknown): boolean
		return type(value) == "number" and math.isfinite(value) and value >= 0
	end
	if type(copied.schema_version) ~= "number" or not math.isfinite(copied.schema_version) or copied.schema_version < 0 or math.floor(copied.schema_version) ~= copied.schema_version then
		return nil, "schema_version must be a non-negative integer"
	end
	if not valid_positive_number(copied.autosave_interval) then
		return nil, "autosave_interval must be a positive finite number"
	end
	if not valid_positive_number(copied.lease_duration) then
		return nil, "lease_duration must be a positive finite number"
	end
	if not valid_positive_number(copied.lease_renewal) then
		return nil, "lease_renewal must be a positive finite number"
	end
	if not valid_positive_number(copied.operation_deadline) then
		return nil, "operation_deadline must be a positive finite number"
	end
	if copied.lease_duration <= copied.lease_renewal + copied.operation_deadline then
		return nil, "lease_duration must exceed lease_renewal plus operation_deadline"
	end
	if not valid_positive_number(copied.shutdown_deadline) then
		return nil, "shutdown_deadline must be a positive finite number"
	end
	if not valid_nonnegative_number(copied.budget_wait) then
		return nil, "budget_wait must be a finite non-negative number"
	end
	if not valid_positive_number(copied.takeover_wait) then
		return nil, "takeover_wait must be a positive finite number"
	end
	if copied.shutdown_attempts ~= nil and (type(copied.shutdown_attempts) ~= "number" or not math.isfinite(copied.shutdown_attempts) or copied.shutdown_attempts < 1 or copied.shutdown_attempts > MAX_RETRY_ATTEMPTS or math.floor(copied.shutdown_attempts) ~= copied.shutdown_attempts) then
		return nil, "shutdown_attempts must be an integer from 1 to " .. tostring(MAX_RETRY_ATTEMPTS)
	end
	if copied.retry_attempts ~= nil and (type(copied.retry_attempts) ~= "number" or not math.isfinite(copied.retry_attempts) or copied.retry_attempts < 1 or copied.retry_attempts > MAX_RETRY_ATTEMPTS or math.floor(copied.retry_attempts) ~= copied.retry_attempts) then
		return nil, "retry_attempts must be an integer from 1 to " .. tostring(MAX_RETRY_ATTEMPTS)
	end
	if copied.migrations ~= nil then
		if type(copied.migrations) ~= "table" then
			return nil, "migrations must be a table"
		end
		for version, migration in copied.migrations do
			if type(version) ~= "number" or not math.isfinite(version) or math.floor(version) ~= version or version < 0 or type(migration) ~= "function" then
				return nil, "migrations must map non-negative integer versions to functions"
			end
		end
	end
	if copied.user_ids ~= nil then
		if type(copied.user_ids) ~= "table" then
			return nil, "user_ids must be an array of positive integers"
		end
		local normalized_ids, ids_error = normalize_user_ids(copied.user_ids)
		if normalized_ids == nil then
			return nil, ids_error
		end
		copied.user_ids = normalized_ids
	end
	if copied.validator ~= nil and type(copied.validator) ~= "function" then
		return nil, "validator must be a function"
	end
	if copied.legacy_decoder ~= nil and type(copied.legacy_decoder) ~= "function" then
		return nil, "legacy_decoder must be a function"
	end
	if copied.on_event ~= nil and type(copied.on_event) ~= "function" then
		return nil, "on_event must be a function"
	end
	if copied.on_message ~= nil and type(copied.on_message) ~= "function" then
		return nil, "on_message must be a function"
	end
	if copied.on_queue_message ~= nil and type(copied.on_queue_message) ~= "function" then
		return nil, "on_queue_message must be a function"
	end
	if copied.metadata ~= nil then
		local valid, message = validate_metadata(copied.metadata)
		if not valid then
			return nil, message
		end
	end
	return copied, nil
end

local function enqueue_static(name: string, scope: string, key: string, message_type: string, data: JsonValue?, mock: boolean, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		return "invalid", identity_message
	end
	if type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH then
		return "invalid", "message_type must be 1 to 100 characters"
	end
	local frozen_data: JsonValue? = nil
	if data ~= nil then
		local copied_ok, copied_or_error = pcall(function()
			return copy_value(data)
		end)
		if not copied_ok or copied_or_error == nil then
			return "validation", "queue data is invalid"
		end
		frozen_data = copied_or_error
		local valid, message = validate_serialized_size(frozen_data)
		if not valid then
			return "validation", message
		end
	end
	local queue_name = queue_store_name or DEFAULT_QUEUE_STORE_NAME
	if type(queue_name) ~= "string" or #queue_name == 0 or #queue_name > 50 then
		return "invalid", "queue_store_name must be 1 to 50 characters"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then
		return "invalid", deadline_error
	end
	local migration_code, migration_message = ensure_legacy_queue_clear(
		name,
		scope,
		key,
		queue_name,
		mock,
		deadline,
		nil
	)
	if migration_code ~= nil then
		return migration_code, migration_message
	end
	local backend = make_backend(queue_name, scope, make_queue_key_v2(name, scope, key), mock)
	local owner = make_queue_owner(name, scope, key)
	local message_id = HttpService:GenerateGUID(false)
	local created_at = queue_now_unix(mock)
	local result, _, result_code, result_message = backend_update(backend, function(raw)
		local queue = parse_queue_envelope(raw, owner)
		if queue == nil or #queue.messages >= DEFAULT_QUEUE_MAX_MESSAGES then
			return nil, nil, nil
		end
		local next_messages = table.clone(queue.messages)
		next_messages[#next_messages + 1] = {
			id = message_id,
			type = message_type,
			data = copy_value(frozen_data),
			attempts = 0,
			total_attempts = 0,
			replay_count = 0,
			last_replay_token = nil,
			sender_job_id = server_id,
			created_at = created_at,
			locked_until = 0,
			lock_token = nil,
		}
		local next_queue = make_queue_envelope(owner, next_messages, queue.dead_letters)
		if queue_size_error(next_queue, DEFAULT_QUEUE_MAX_BYTES) ~= nil then
			return nil, nil, nil
		end
		return next_queue, nil, nil
	end, deadline)
	if result_code ~= nil then
		return result_code, result_message
	end
	local queue, verify_code, verify_message = read_queue_after_update(backend, result, deadline, nil, owner)
	if queue == nil then
		return verify_code or "unknown", verify_message
	end
	for _, item in ipairs(queue.messages) do
		if item.id == message_id then
			return "enqueued", message_id
		end
	end
	if #queue.messages >= DEFAULT_QUEUE_MAX_MESSAGES then
		return "validation", "durable queue is full"
	end
	local candidate = table.clone(queue.messages)
	candidate[#candidate + 1] = {
		id = message_id,
		type = message_type,
		data = copy_value(frozen_data),
		attempts = 0,
		total_attempts = 0,
		replay_count = 0,
		last_replay_token = nil,
		sender_job_id = server_id,
		created_at = created_at,
		locked_until = 0,
		lock_token = nil,
	}
	local candidate_queue = make_queue_envelope(owner, candidate, queue.dead_letters)
	local size_message = queue_size_error(candidate_queue, DEFAULT_QUEUE_MAX_BYTES)
	if size_message ~= nil then
		return "validation", size_message
	end
	return "unknown", "queue append did not appear in the verified durable state"
end

function RecordStore.enqueue_async(name: string, scope: string, key: string, message_type: string, data: JsonValue?, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
	return enqueue_static(name, scope, key, message_type, data, false, queue_store_name, operation_deadline)
end

function RecordStore.new(name: string, scope: string, key: string, options: Options): Record
	if closing then
		error("RecordStore is shutting down", 2)
	end
	local valid_identity, identity_message = validate_store_identity(name, scope, key)
	if not valid_identity then
		error(identity_message, 2)
	end
	local normalized, options_message = normalize_options(options)
	if normalized == nil then
		error(options_message, 2)
	end
	local valid_options = normalized
	if valid_options == nil then
		error("normalized options are missing", 2)
	end
	local record = make_record(name, scope, key, valid_options, false)
	start_scheduler()
	return record
end

RecordStore.Mock = (function()
	local function mock_new(name: string, scope: string, key: string, options: Options): Record
		if closing then
			error("RecordStore is shutting down", 2)
		end
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			error(identity_message, 2)
		end
		local normalized, options_message = normalize_options(options)
		if normalized == nil then
			error(options_message, 2)
		end
		local valid_options = normalized
		if valid_options == nil then
			error("normalized options are missing", 2)
		end
		valid_options.messaging_enabled = false
		valid_options.takeover_enabled = false
		start_scheduler()
		return make_record(name, scope, key, valid_options, true)
	end

	local function read_async_mock(name: string, scope: string, key: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
		if legacy_decoder ~= nil and type(legacy_decoder) ~= "function" then
			return nil, "invalid", "legacy_decoder must be a function"
		end
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			return nil, "invalid", identity_message
		end
		local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
		if deadline == nil then
			return nil, "invalid", deadline_error
		end
		local backend = make_backend(name, scope, key, true)
		local raw, info, result_code, result_message = backend_get(backend, false, deadline)
		if result_code ~= nil then
			return nil, result_code, result_message
		end
		if raw == nil then
			return nil, "not_found", "record does not exist"
		end
		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then
			if parse_error == "legacy payload" and legacy_decoder ~= nil then
				local legacy_envelope, legacy_error = decode_legacy_read(raw, legacy_decoder)
				if legacy_envelope == nil then
					return nil, "legacy", legacy_error
				end
				return snapshot_from_envelope(key, legacy_envelope, info), "legacy", "read-only legacy payload"
			end
			return nil, (if parse_error == "legacy payload" then "legacy" elseif parse_error == "future implementation version" then "future_schema" else "corrupt"), parse_error or "durable envelope is invalid"
		end
		if envelope == nil then
			return nil, "corrupt", "durable envelope is missing"
		end
		return snapshot_from_envelope(key, envelope, info), "success", nil
	end

	local function list_versions_mock(name: string, scope: string, key: string, sort_direction: Enum.SortDirection?, min_date_ms: number?, max_date_ms: number?, max_versions: number?, operation_deadline: number?): ({ HistoryEntry }?, ResultCode, string?)
		return list_versions_internal(name, scope, key, sort_direction, min_date_ms, max_date_ms, max_versions, operation_deadline, true)
	end

	local function get_version_mock(name: string, scope: string, key: string, version: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
		return get_version_internal(name, scope, key, version, operation_deadline, legacy_decoder, true)
	end

	local function get_version_at_time_mock(name: string, scope: string, key: string, timestamp_ms: number, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, string?, ResultCode, string?)
		return get_version_at_time_internal(name, scope, key, timestamp_ms, operation_deadline, legacy_decoder, true)
	end

	local function mock_seed_queue_value(
		name: string,
		scope: string,
		key: string,
		value: unknown,
		legacy: boolean?,
		queue_store_name: string?
	): (ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			return "invalid", identity_message
		end
		local store_name = queue_store_name or DEFAULT_QUEUE_STORE_NAME
		if type(store_name) ~= "string" or #store_name == 0 or #store_name > 50 then
			return "invalid", "queue_store_name must be 1 to 50 characters"
		end
		local queue_key = if legacy == true
			then make_queue_key_legacy(name, scope, key)
			else make_queue_key_v2(name, scope, key)
		local store = get_mock_store(store_name, scope)
		if value == nil then
			store[queue_key] = nil
			return "success", nil
		end
		local copied_ok, copied_value = pcall(function()
			return copy_value(value)
		end)
		if not copied_ok or copied_value == nil then
			return "validation", "mock queue fixture value is not valid JSON data"
		end
		store[queue_key] = mock_write_version(store[queue_key], copied_value, {}, {}, false)
		return "success", nil
	end

	local function mock_get_queue_raw(
		name: string,
		scope: string,
		key: string,
		legacy: boolean?,
		queue_store_name: string?
	): unknown
		local store_name = queue_store_name or DEFAULT_QUEUE_STORE_NAME
		local queue_key = if legacy == true
			then make_queue_key_legacy(name, scope, key)
			else make_queue_key_v2(name, scope, key)
		local store = get_mock_store(store_name, scope)
		local entry = store[queue_key]
		return if entry == nil then nil else copy_value(entry.Value)
	end

	local function mock_seed_record_raw(name: string, scope: string, key: string, value: unknown): (ResultCode, string?)
		local valid_identity, identity_message = validate_store_identity(name, scope, key)
		if not valid_identity then
			return "invalid", identity_message
		end
		local store = get_mock_store(name, scope)
		if value == nil then
			store[key] = nil
			return "success", nil
		end
		local copied_ok, copied_or_error = pcall(function()
			return copy_value(value)
		end)
		if not copied_ok or copied_or_error == nil then
			return "validation", "mock record fixture is not valid JSON data"
		end
		local copied = copied_or_error :: JsonValue
		local valid, size_error = validate_serialized_size(copied)
		if not valid then
			return "validation", size_error
		end
		store[key] = mock_write_version(store[key], copied, {}, {}, false)
		return "success", nil
	end

	local function mock_get_record_raw(name: string, scope: string, key: string): unknown
		local store = get_mock_store(name, scope)
		local entry = store[key]
		return if entry == nil then nil else copy_value(entry.Value)
	end

	local function mock_get_record_version_raw(name: string, scope: string, key: string, version: string): unknown
		local store = get_mock_store(name, scope)
		local entry = store[key]
		if entry == nil then
			return nil
		end
		local historical = entry.Versions[version]
		return if historical == nil then nil else copy_value(historical.Value)
	end

	local function mock_set_test_clock(clock: (() -> number)?)
		if clock ~= nil and type(clock) ~= "function" then
			error("test clock must be a function or nil", 2)
		end
		mock_test_clock = clock
		mock_test_clock_offset = 0
	end

	local function mock_set_update_replay(retries: number, advance_seconds: number)
		if type(retries) ~= "number"
			or not math.isfinite(retries)
			or math.floor(retries) ~= retries
			or retries < 0
			or retries > 20
		then
			error("retries must be an integer from 0 to 20", 2)
		end
		if type(advance_seconds) ~= "number"
			or not math.isfinite(advance_seconds)
			or advance_seconds < 0
			or advance_seconds > 3600
		then
			error("advance_seconds must be from 0 to 3600", 2)
		end
		mock_update_replay_retries = retries
		mock_update_replay_advance_seconds = advance_seconds
	end

	local function mock_set_update_failures(count: number, result: ResultCode?, message: string?)
		if type(count) ~= "number"
			or not math.isfinite(count)
			or math.floor(count) ~= count
			or count < 0
			or count > 100
		then
			error("count must be an integer from 0 to 100", 2)
		end
		local failure_code = result or "budget"
		if failure_code ~= "budget"
			and failure_code ~= "busy"
			and failure_code ~= "unknown"
			and failure_code ~= "retry_exhausted"
		then
			error("result must be a transient backend result", 2)
		end
		if message ~= nil and type(message) ~= "string" then
			error("message must be a string or nil", 2)
		end
		mock_update_failure_count = count
		mock_update_failure_code = failure_code
		mock_update_failure_message = message
	end

	local function mock_claim_queue_message(record: Record): (MockQueueClaim?, ResultCode, string?)
		local state = private[record]
		if state == nil or not state.backend.mock then
			return nil, "invalid", "queue claim requires a live mock record"
		end
		local item, result, message = claim_queue_message(state)
		if item == nil then
			return nil, result, message
		end
		if item.lock_token == nil then
			return nil, "corrupt", "mock queue claim has no lock token"
		end
		return {
			Id = item.id,
			LockToken = item.lock_token,
			LockedUntil = item.locked_until,
		}, result, message
	end

	local function mock_dead_letter_queue_message(record: Record, message_id: string, lock_token: string, error_message: string): (ResultCode, string?)
		local state = private[record]
		if state == nil or not state.backend.mock then
			return "invalid", "dead-letter mutation requires a live mock record"
		end
		return dead_letter_queue_message(state, message_id, lock_token, error_message)
	end

	function RecordStore.get_server_id(): string
		return server_id
	end

	function RecordStore.is_shutting_down(): boolean
		return closing
	end

	local Mock = {
		new = mock_new,
		renew = function(record: Record): (ResultCode, string?)
			local state = private[record]
			if state == nil or not state.backend.mock then
				return "invalid", "mock renewal requires a live mock record"
			end
			local result, message = renew_internal(state)
			sync_public(record)
			return result, message
		end,
		read_async = read_async_mock,
		claim_queue_message = mock_claim_queue_message,
		dead_letter_queue_message = mock_dead_letter_queue_message,
		list_versions_async = list_versions_mock,
		get_version_async = get_version_mock,
		get_version_at_time_async = get_version_at_time_mock,
		enqueue_async = function(name: string, scope: string, key: string, message_type: string, data: JsonValue?, queue_store_name: string?, operation_deadline: number?): (ResultCode, string?)
			return enqueue_static(name, scope, key, message_type, data, true, queue_store_name, operation_deadline)
		end,
		seed_queue_raw = function(name: string, scope: string, key: string, value: unknown, queue_store_name: string?): (ResultCode, string?)
			return mock_seed_queue_value(name, scope, key, value, false, queue_store_name)
		end,
		seed_legacy_queue = function(name: string, scope: string, key: string, value: unknown, queue_store_name: string?): (ResultCode, string?)
			return mock_seed_queue_value(name, scope, key, value, true, queue_store_name)
		end,
		get_queue_raw = mock_get_queue_raw,
		seed_record_raw = mock_seed_record_raw,
		get_record_raw = mock_get_record_raw,
		get_record_version_raw = mock_get_record_version_raw,
		set_test_clock = mock_set_test_clock,
		set_update_replay = mock_set_update_replay,
		set_update_failures = mock_set_update_failures,
		reset = function()
			local mock_records: { { id: string, record: Record } } = {}
			for id, record in pairs(records) do
				local state = private[record]
				if state ~= nil and state.backend.mock then
					mock_records[#mock_records + 1] = {
						id = id,
						record = record,
					}
				end
			end
			for _, item in ipairs(mock_records) do
				local state = private[item.record]
				if state ~= nil then
					state.retired = true
					state.shutdown = true
					state.state = "closed"
					active_records[item.record] = nil
					state.busy = false
					state.queue_busy = false
					state.takeover_requested = false
					state.next_autosave = math.huge
					state.next_renewal = math.huge
					state.next_queue_poll = math.huge
					disconnect_message_subscription(state)
					private[item.record] = nil
				end
				records[item.id] = nil
			end
			mock_database = {}
			mock_counter = 0
			mock_test_clock = nil
			mock_test_clock_offset = 0
			mock_update_replay_retries = 0
			mock_update_replay_advance_seconds = 0
			mock_update_failure_count = 0
			mock_update_failure_code = "budget"
			mock_update_failure_message = nil
		end,
	}

	return Mock
end)()
RecordStore.is_retryable_result = is_retryable_result
RecordStore.get_diagnostic_code = get_diagnostic_code
RecordStore.shutdown = shutdown

game:BindToClose(shutdown)

table.freeze(RecordStore)

return RecordStore

