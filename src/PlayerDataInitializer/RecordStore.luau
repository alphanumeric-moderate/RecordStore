--!strict
--!optimize 2
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")

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
| "duplicate"
| "capacity"
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

export type DurabilityRiskEvent = {
	Transition: "entered" | "changed" | "recovered",
	Reason: "dirty_age_exceeded" | "write_outcome_uncertain" | "recovered",
	State: SessionState,
	Dirty: boolean,
	DirtyGeneration: number,
	DurableGeneration: number,
	KnownRevision: number,
	LastConfirmedDurableRevision: number,
	DirtyAgeSeconds: number?,
	MaxDirtyAgeSeconds: number,
	LastConfirmedSaveUnix: number,
	WriteOutcomeUncertain: boolean,
	ObservedAtUnix: number,
}

export type DurabilityRiskObserver = (event: DurabilityRiskEvent) -> ()

export type DurabilityStatus = {
	state: SessionState,
	dirty: boolean,
	dirty_generation: number,
	durable_generation: number,
	known_revision: number,
	last_confirmed_durable_revision: number,
	dirty_age_seconds: number?,
	dirty_age_available: boolean,
	dirty_age_exceeded: boolean?,
	age_basis: "clean" | "tracked_dirty_generation" | "unavailable",
	max_dirty_age_seconds: number,
	last_confirmed_save_unix: number,
	write_outcome_uncertain: boolean,
	retry_category: string?,
	in_flight_operations: number,
	durability_risk_active: boolean,
	durability_risk_reason: string?,
	observed_at_unix: number,
}

export type SessionWaitOutcome =
	"no_known_competing_session"
	| "competing_session_observed"
	| "wait_retry_scheduled"
	| "cancellation_requested"
	| "ownership_acquired"
	| "ownership_fenced_or_lost"
	| "session_status_unavailable"

export type SessionWaitResult = {
	Outcome: SessionWaitOutcome,
	Attempt: number,
	ObservedAtUnix: number,
	SessionJobId: string?,
	LeaseUntilUnix: number?,
	RetryAfterSeconds: number?,
	RetryScheduled: boolean,
	ReadResult: ResultCode?,
	Message: string?,
}

export type SessionWaitOptions = {
	max_wait_seconds: number?,
	max_attempts: number?,
	retry_interval_seconds: number?,
	max_retry_interval_seconds: number?,
	recreate: boolean?,
	cancelled: (() -> boolean)?,
	on_status: ((SessionWaitResult) -> ())?,
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

type ReadFlightWaiter = {
	event: any,
	active: boolean,
	timed_out: boolean,
}
type ReadFlight = {
	waiters: { ReadFlightWaiter },
	done: boolean,
	snapshot: Snapshot?,
	code: ResultCode,
	message: string?,
}
local in_flight_reads: { [string]: ReadFlight } = {}
local MAX_IN_FLIGHT_READ_KEYS = 256
local MAX_IN_FLIGHT_READ_WAITERS = 64

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


export type RuntimeOptions = {
	revision: number?,
	runtime_profile: string?,
	max_dirty_age_seconds: number?,
	server_role: string?,
	degraded_mode: string?,
	circuit_threshold: number?,
	circuit_cooldown_seconds: number?,
	adaptive_runtime_enabled: boolean?,
	adaptive_sample_interval: number?,
	adaptive_min_queue_poll_interval: number?,
	adaptive_max_queue_poll_interval: number?,
	adaptive_min_concurrent_requests: number?,
	adaptive_max_concurrent_requests: number?,
	adaptive_read_budget_floor: number?,
	adaptive_write_budget_floor: number?,
	adaptive_queue_budget_share: number?,
	adaptive_hysteresis_seconds: number?,
	runtime_policy_refresh_interval: number?,
	critical_request_reserve: number?,
	runtime_policy_provider: (() -> { [string]: unknown })?,
}

type RuntimePolicy = {
	revision: number,
	runtime_profile: string,
	max_dirty_age_seconds: number,
	server_role: string,
	degraded_mode: string,
	circuit_threshold: number,
	circuit_cooldown_seconds: number,
	adaptive_runtime_enabled: boolean,
	adaptive_sample_interval: number,
	adaptive_min_queue_poll_interval: number,
	adaptive_max_queue_poll_interval: number,
	adaptive_min_concurrent_requests: number,
	adaptive_max_concurrent_requests: number,
	adaptive_read_budget_floor: number,
	adaptive_write_budget_floor: number,
	adaptive_queue_budget_share: number,
	adaptive_hysteresis_seconds: number,
	runtime_policy_refresh_interval: number,
	critical_request_reserve: number,
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

export type TransactionTransform = (value: JsonValue?) -> JsonValue
export type OutboxEventInput = {
	EventId: string,
	DestinationStoreName: string,
	DestinationScope: string,
	DestinationProfileKey: string,
	MessageType: string,
	Data: JsonValue?,
}
export type OutboxEvent = OutboxEventInput & {
	OperationId: string,
	State: "pending" | "dispatched",
	CreatedAt: number,
	DispatchedAt: number?,
	Attempts: number,
	LastError: string?,
	DestinationReceiptId: string?,
}
export type OutboxDispatcher = (event: OutboxEvent) -> (boolean, string?)

type InboxReceiptRecord = {
	operation_id: string,
	request_fingerprint: string,
	request_material: string?,
	write_id: string,
	revision: number,
	committed_at: number,
}
type OutboxEntryRecord = {
	event_id: string,
	operation_id: string,
	destination_store_name: string,
	destination_scope: string,
	destination_profile_key: string,
	message_type: string,
	payload: JsonValue?,
	state: "pending" | "dispatched",
	created_at: number,
	dispatched_at: number?,
	attempts: number,
	last_error: string?,
	destination_receipt_id: string?,
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
	inbox_receipts: { [string]: InboxReceiptRecord }?,
	outbox: { [string]: OutboxEntryRecord }?,
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
	durability_risk_observers: { [number]: DurabilityRiskObserver },
	durability_risk_observer_next_id: number,
	durability_risk_observer_errors: number,
	durability_risk_active: boolean,
	durability_risk_reason: string?,
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
	mailbox_v2_binding: boolean,
	save_requested: boolean,
	shutdown: boolean,
	retired: boolean,
	takeover_requested: boolean,
	queue_hint: boolean,
	mailbox_v2: any?,
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
	dirty_since_unix: number,
	durable_lease_until: number,
}

export type RecordIdentity = {
	store_name: string,
	scope: string,
	profile_key: string,
	user_ids: { number },
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
	GetIdentity: (self: Record) -> RecordIdentity,
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
	GetDurabilityStatus: (self: Record) -> (DurabilityStatus?, ResultCode, string?),
	SubscribeDurabilityRisk: (self: Record, observer: DurabilityRiskObserver) -> (ChangeSubscription?, ResultCode, string?),
	WaitForSessionAsync: (self: Record, default_data: JsonValue?, wait_options: SessionWaitOptions?) -> (SessionWaitResult, ResultCode, string?),
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
	TransactAsync: (self: Record, operation_id: string, request_fingerprint: string, transform: TransactionTransform, request_material: string?) -> (ResultCode, string?),
	ApplyInboxAsync: (self: Record, operation_id: string, request_fingerprint: string, transform: TransactionTransform, request_material: string?) -> (ResultCode, string?),
	CommitWithOutboxAsync: (self: Record, operation_id: string, request_fingerprint: string, transform: TransactionTransform, events: { OutboxEventInput }, request_material: string?) -> (ResultCode, string?),
	GetOutboxAsync: (self: Record, max_items: number?) -> ({ OutboxEvent }, ResultCode, string?),
	DispatchOutboxAsync: (self: Record, dispatcher: OutboxDispatcher, max_items: number?) -> (number, ResultCode, string?),
	DispatchOutboxBatchAsync: (self: Record, dispatcher: OutboxDispatcher, max_items: number?) -> (number, ResultCode, string?),
	PruneTransactionReceiptsAsync: (self: Record, committed_before_ms: number, max_items: number?) -> (number, ResultCode, string?),
	PruneOutboxAsync: (self: Record, dispatched_before_ms: number, max_items: number?) -> (number, ResultCode, string?),
	MessageAsync: (self: Record, message_type: string, data: JsonValue?) -> (ResultCode, string?),
	BindMailboxV2Async: (self: Record, mailbox: unknown) -> (ResultCode, string?),
	EnqueueAsync: (self: Record, message_type: string, data: JsonValue?, enqueue_options: { [string]: unknown }?) -> (ResultCode, string?),
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
local MAX_INBOX_RECEIPTS = 128
local MAX_REQUEST_MATERIAL_BYTES = 16_384
local MAX_OUTBOX_EVENTS = 32
local MAX_OUTBOX_EVENTS_PER_COMMIT = 8
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
local DURABILITY_RISK_OBSERVER_CAPACITY = 32
local DEFAULT_MAX_DIRTY_AGE_SECONDS = 300
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
local mock_update_response_lost_count = 0
local mock_update_response_lost_message: string? = nil

local runtime_options: RuntimePolicy = {
	revision = 1,
	runtime_profile = "balanced",
	max_dirty_age_seconds = DEFAULT_MAX_DIRTY_AGE_SECONDS,
	server_role = "standard",
	degraded_mode = "normal",
	circuit_threshold = 5,
	circuit_cooldown_seconds = 15,
	adaptive_runtime_enabled = false,
	adaptive_sample_interval = 5,
	adaptive_min_queue_poll_interval = 3,
	adaptive_max_queue_poll_interval = 30,
	adaptive_min_concurrent_requests = 1,
	adaptive_max_concurrent_requests = DEFAULT_MAX_CONCURRENT_REQUESTS,
	adaptive_read_budget_floor = 1,
	adaptive_write_budget_floor = 1,
	adaptive_queue_budget_share = 0.2,
	adaptive_hysteresis_seconds = 15,
	runtime_policy_refresh_interval = 30,
	critical_request_reserve = 1,
}
local runtime_policy_provider: (() -> { [string]: unknown })? = nil
local runtime_effective_concurrent_requests = DEFAULT_MAX_CONCURRENT_REQUESTS
local runtime_next_policy_refresh = 0
local runtime_next_budget_sample = 0
local runtime_refresh_in_flight = false
local runtime_budget_read: number? = nil
local runtime_budget_write: number? = nil
local runtime_next_growth_at = 0
local runtime_queue_tokens = DEFAULT_MAX_CONCURRENT_REQUESTS * 0.2
local runtime_queue_tokens_updated = 0
local runtime_external_in_flight: { [string]: number } = {
	interactive = 0, messaging = 0, migration = 0, maintenance = 0, tracing = 0,
}
local runtime_breakers: { [string]: { failures: number, open_until: number, probe_in_flight: boolean } } = {
	read = { failures = 0, open_until = 0, probe_in_flight = false },
	write = { failures = 0, open_until = 0, probe_in_flight = false },
	service = { failures = 0, open_until = 0, probe_in_flight = false },
}
local runtime_metrics = {
	reads = 0,
	writes = 0,
	service_calls = 0,
	failures = 0,
	throttles = 0,
	budget_rejections = 0,
	queue_admitted = 0,
	queue_rejected = 0,
	no_op_saves = 0,
	read_latency_ewma_ms = 0,
	write_latency_ewma_ms = 0,
	service_latency_ewma_ms = 0,
	last_error = "",
	last_policy_error = "",
}

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


local function mark_dirty(state: InternalState)
	if state.change_sequence == state.saved_change_sequence then
		state.dirty_since_unix = session_now_unix(state.backend.mock)
	end
	state.change_sequence += 1
end

local function mark_saved(state: InternalState, sequence: number)
	state.saved_change_sequence = sequence
	if state.change_sequence == sequence then
		state.dirty_since_unix = 0
	end
end

local function valid_runtime_policy(candidate: RuntimePolicy): (boolean, string?)
	if candidate.runtime_profile ~= "balanced" and candidate.runtime_profile ~= "latency"
		and candidate.runtime_profile ~= "throughput" and candidate.runtime_profile ~= "conservative"
	then
		return false, "runtime_profile must be balanced, latency, throughput or conservative"
	end
	if type(candidate.server_role) ~= "string" or candidate.server_role == "" or #candidate.server_role > 64 then
		return false, "server_role must be 1 to 64 characters"
	end
	if type(candidate.adaptive_runtime_enabled) ~= "boolean" then return false, "adaptive_runtime_enabled must be boolean" end
	if candidate.degraded_mode ~= "normal" and candidate.degraded_mode ~= "reject_noncritical" and candidate.degraded_mode ~= "read_only" then
		return false, "degraded_mode must be normal, reject_noncritical or read_only"
	end
	if type(candidate.circuit_threshold) ~= "number" or not math.isfinite(candidate.circuit_threshold)
		or candidate.circuit_threshold < 1 or candidate.circuit_threshold > 100
		or math.floor(candidate.circuit_threshold) ~= candidate.circuit_threshold
	then return false, "circuit_threshold must be an integer from 1 to 100" end
	if type(candidate.circuit_cooldown_seconds) ~= "number" or not math.isfinite(candidate.circuit_cooldown_seconds)
		or candidate.circuit_cooldown_seconds < 1 or candidate.circuit_cooldown_seconds > 300
	then return false, "circuit_cooldown_seconds must be between 1 and 300" end
	local numeric_values = {
		candidate.revision, candidate.max_dirty_age_seconds, candidate.adaptive_sample_interval,
		candidate.adaptive_min_queue_poll_interval, candidate.adaptive_max_queue_poll_interval,
		candidate.adaptive_min_concurrent_requests, candidate.adaptive_max_concurrent_requests,
		candidate.adaptive_read_budget_floor, candidate.adaptive_write_budget_floor,
		candidate.adaptive_queue_budget_share, candidate.adaptive_hysteresis_seconds,
		candidate.runtime_policy_refresh_interval, candidate.critical_request_reserve,
	}
	for _, value in ipairs(numeric_values) do
		if type(value) ~= "number" or not math.isfinite(value) then return false, "runtime numeric fields must be finite" end
	end
	if candidate.revision < 1 or math.floor(candidate.revision) ~= candidate.revision then return false, "revision must be a positive integer" end
	if candidate.max_dirty_age_seconds < 1 or candidate.max_dirty_age_seconds > 86400 then
		return false, "max_dirty_age_seconds must be between 1 and 86400 seconds"
	end
	if candidate.adaptive_sample_interval < 1 or candidate.adaptive_sample_interval > 60 then return false, "adaptive_sample_interval must be 1 to 60 seconds" end
	if candidate.adaptive_min_queue_poll_interval < 0.25 or candidate.adaptive_max_queue_poll_interval > 300
		or candidate.adaptive_min_queue_poll_interval > candidate.adaptive_max_queue_poll_interval
	then
		return false, "queue poll interval bounds must be ordered and between 0.25 and 300 seconds"
	end
	if candidate.adaptive_min_concurrent_requests < 1 or candidate.adaptive_max_concurrent_requests > 64
		or math.floor(candidate.adaptive_min_concurrent_requests) ~= candidate.adaptive_min_concurrent_requests
		or math.floor(candidate.adaptive_max_concurrent_requests) ~= candidate.adaptive_max_concurrent_requests
		or candidate.adaptive_min_concurrent_requests > candidate.adaptive_max_concurrent_requests
	then
		return false, "concurrency limits must be ordered integers between 1 and 64"
	end
	if candidate.critical_request_reserve < 0 or math.floor(candidate.critical_request_reserve) ~= candidate.critical_request_reserve
		or candidate.adaptive_min_concurrent_requests + candidate.critical_request_reserve > candidate.adaptive_max_concurrent_requests
	then
		return false, "critical_request_reserve must be a non-negative integer that fits below maximum concurrency"
	end
	if candidate.adaptive_read_budget_floor < 0 or candidate.adaptive_write_budget_floor < 0
		or math.floor(candidate.adaptive_read_budget_floor) ~= candidate.adaptive_read_budget_floor
		or math.floor(candidate.adaptive_write_budget_floor) ~= candidate.adaptive_write_budget_floor
	then
		return false, "read/write budget floors must be non-negative integers"
	end
	if candidate.adaptive_queue_budget_share < 0 or candidate.adaptive_queue_budget_share > 1 then return false, "adaptive_queue_budget_share must be between 0 and 1" end
	if candidate.adaptive_hysteresis_seconds < 1 or candidate.adaptive_hysteresis_seconds > 300 then return false, "adaptive_hysteresis_seconds must be 1 to 300 seconds" end
	if candidate.runtime_policy_refresh_interval < 5 or candidate.runtime_policy_refresh_interval > 3600 then return false, "runtime_policy_refresh_interval must be 5 to 3600 seconds" end
	return true, nil
end

local RUNTIME_POLICY_FIELDS: { [string]: boolean } = {
	revision = true, runtime_profile = true, max_dirty_age_seconds = true, server_role = true, degraded_mode = true,
	circuit_threshold = true, circuit_cooldown_seconds = true, adaptive_runtime_enabled = true,
	adaptive_sample_interval = true, adaptive_min_queue_poll_interval = true,
	adaptive_max_queue_poll_interval = true, adaptive_min_concurrent_requests = true,
	adaptive_max_concurrent_requests = true, adaptive_read_budget_floor = true,
	adaptive_write_budget_floor = true, adaptive_queue_budget_share = true,
	adaptive_hysteresis_seconds = true, runtime_policy_refresh_interval = true,
	critical_request_reserve = true,
}

local RUNTIME_PROFILE_DEFAULTS: { [string]: { [string]: unknown } } = {
	balanced = {
		adaptive_sample_interval = 5, adaptive_min_queue_poll_interval = 3,
		adaptive_max_queue_poll_interval = 30, adaptive_min_concurrent_requests = 1,
		adaptive_max_concurrent_requests = DEFAULT_MAX_CONCURRENT_REQUESTS,
		adaptive_read_budget_floor = 1, adaptive_write_budget_floor = 1,
		adaptive_queue_budget_share = 0.2, adaptive_hysteresis_seconds = 15,
		critical_request_reserve = 1,
	},
	latency = {
		adaptive_sample_interval = 2, adaptive_min_queue_poll_interval = 0.5,
		adaptive_max_queue_poll_interval = 15, adaptive_min_concurrent_requests = 2,
		adaptive_max_concurrent_requests = 12, adaptive_read_budget_floor = 1,
		adaptive_write_budget_floor = 1, adaptive_queue_budget_share = 0.3,
		adaptive_hysteresis_seconds = 5, critical_request_reserve = 2,
	},
	throughput = {
		adaptive_sample_interval = 10, adaptive_min_queue_poll_interval = 5,
		adaptive_max_queue_poll_interval = 45, adaptive_min_concurrent_requests = 4,
		adaptive_max_concurrent_requests = 48, adaptive_read_budget_floor = 2,
		adaptive_write_budget_floor = 2, adaptive_queue_budget_share = 0.25,
		adaptive_hysteresis_seconds = 30, critical_request_reserve = 2,
	},
	conservative = {
		adaptive_sample_interval = 5, adaptive_min_queue_poll_interval = 5,
		adaptive_max_queue_poll_interval = 60, adaptive_min_concurrent_requests = 1,
		adaptive_max_concurrent_requests = 16, adaptive_read_budget_floor = 3,
		adaptive_write_budget_floor = 3, adaptive_queue_budget_share = 0.1,
		adaptive_hysteresis_seconds = 30, critical_request_reserve = 2,
	},
}

local function merge_runtime_policy(patch: { [string]: unknown }, base: RuntimePolicy, from_provider: boolean): (RuntimePolicy?, string?)
	local candidate = table.clone(base)
	for key, value in pairs(patch) do
		if key == "runtime_policy_provider" then
			if from_provider then return nil, "runtime provider may not replace itself" end
			continue
		end
		if not RUNTIME_POLICY_FIELDS[key] then return nil, "unsupported runtime policy field: " .. tostring(key) end
		if key == "revision" then
			if type(value) ~= "number" then return nil, "revision must be numeric" end
			candidate.revision = value
		elseif key == "runtime_profile" then
			if type(value) ~= "string" then return nil, "runtime_profile must be a string" end
			candidate.runtime_profile = value
		elseif key == "max_dirty_age_seconds" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.max_dirty_age_seconds = value
		elseif key == "server_role" then
			if type(value) ~= "string" then return nil, "server_role must be a string" end
			candidate.server_role = value
		elseif key == "degraded_mode" then
			if type(value) ~= "string" then return nil, "degraded_mode must be a string" end
			candidate.degraded_mode = value
		elseif key == "circuit_threshold" then
			if type(value) ~= "number" then return nil, "circuit_threshold must be numeric" end
			candidate.circuit_threshold = value
		elseif key == "circuit_cooldown_seconds" then
			if type(value) ~= "number" then return nil, "circuit_cooldown_seconds must be numeric" end
			candidate.circuit_cooldown_seconds = value
		elseif key == "adaptive_runtime_enabled" then
			if type(value) ~= "boolean" then return nil, "adaptive_runtime_enabled must be boolean" end
			candidate.adaptive_runtime_enabled = value
		elseif key == "adaptive_sample_interval" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_sample_interval = value
		elseif key == "adaptive_min_queue_poll_interval" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_min_queue_poll_interval = value
		elseif key == "adaptive_max_queue_poll_interval" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_max_queue_poll_interval = value
		elseif key == "adaptive_min_concurrent_requests" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_min_concurrent_requests = value
		elseif key == "adaptive_max_concurrent_requests" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_max_concurrent_requests = value
		elseif key == "adaptive_read_budget_floor" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_read_budget_floor = value
		elseif key == "adaptive_write_budget_floor" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_write_budget_floor = value
		elseif key == "adaptive_queue_budget_share" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_queue_budget_share = value
		elseif key == "adaptive_hysteresis_seconds" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.adaptive_hysteresis_seconds = value
		elseif key == "runtime_policy_refresh_interval" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.runtime_policy_refresh_interval = value
		elseif key == "critical_request_reserve" then
			if type(value) ~= "number" then return nil, key .. " must be numeric" end
			candidate.critical_request_reserve = value
		end
	end
	if candidate.runtime_profile ~= base.runtime_profile then
		local profile_defaults = RUNTIME_PROFILE_DEFAULTS[candidate.runtime_profile]
		if profile_defaults == nil then return nil, "unsupported runtime_profile" end
		for field, value in pairs(profile_defaults) do
			if patch[field] == nil then (candidate :: any)[field] = value end
		end
	end
	if from_provider and candidate.revision <= base.revision then return nil, "runtime policy revision must increase" end
	local valid, message = valid_runtime_policy(candidate)
	if not valid then return nil, message end
	return candidate, nil
end

local function apply_runtime_policy(patch: { [string]: unknown }, from_provider: boolean): (boolean, string?)
	local candidate, message = merge_runtime_policy(patch, runtime_options, from_provider)
	if candidate == nil then
		runtime_metrics.last_policy_error = tostring(message)
		return false, message
	end
	runtime_options = candidate
	runtime_effective_concurrent_requests = math.clamp(
		runtime_effective_concurrent_requests,
		runtime_options.adaptive_min_concurrent_requests + runtime_options.critical_request_reserve,
		runtime_options.adaptive_max_concurrent_requests
	)
	runtime_queue_tokens = math.max(1, runtime_options.adaptive_max_concurrent_requests * runtime_options.adaptive_queue_budget_share * 16)
	runtime_metrics.last_policy_error = ""
	return true, nil
end

local function request_is_critical(state: InternalState?): boolean
	return state ~= nil and (state.state == "saving" or state.state == "releasing" or state.shutdown)
end

local function request_budget(request_type: Enum.DataStoreRequestType): number?
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(request_type)
	end)
	if not ok or type(budget) ~= "number" or not math.isfinite(budget) then return nil end
	if request_type == Enum.DataStoreRequestType.StandardRead then
		runtime_budget_read = budget
	elseif request_type == Enum.DataStoreRequestType.StandardWrite then
		runtime_budget_write = budget
	end
	return budget
end

local function consume_runtime_queue_token(): boolean
	local now = now_local()
	local elapsed = math.max(0, now - runtime_queue_tokens_updated)
	local rate = runtime_options.adaptive_max_concurrent_requests * runtime_options.adaptive_queue_budget_share * 8
	local capacity = math.max(1, rate * 2)
	runtime_queue_tokens = math.min(capacity, runtime_queue_tokens + elapsed * rate)
	runtime_queue_tokens_updated = now
	if runtime_options.adaptive_queue_budget_share == 0 or runtime_queue_tokens < 1 then
		runtime_metrics.queue_rejected += 1
		return false
	end
	runtime_queue_tokens -= 1
	runtime_metrics.queue_admitted += 1
	return true
end

local function observe_runtime_request(kind: string, success: boolean, message: string?, duration_ms: number)
	if kind == "read" then
		runtime_metrics.reads += 1
		runtime_metrics.read_latency_ewma_ms = if runtime_metrics.read_latency_ewma_ms == 0 then duration_ms else runtime_metrics.read_latency_ewma_ms * 0.8 + duration_ms * 0.2
	elseif kind == "service" then
		runtime_metrics.service_calls += 1
		runtime_metrics.service_latency_ewma_ms = if runtime_metrics.service_latency_ewma_ms == 0 then duration_ms else runtime_metrics.service_latency_ewma_ms * 0.8 + duration_ms * 0.2
	else
		runtime_metrics.writes += 1
		runtime_metrics.write_latency_ewma_ms = if runtime_metrics.write_latency_ewma_ms == 0 then duration_ms else runtime_metrics.write_latency_ewma_ms * 0.8 + duration_ms * 0.2
	end
	runtime_breaker_complete(kind, success)
	if success then
		if runtime_options.adaptive_runtime_enabled and now_local() >= runtime_next_growth_at
			and runtime_effective_concurrent_requests < runtime_options.adaptive_max_concurrent_requests
		then
			runtime_effective_concurrent_requests += 1
			runtime_next_growth_at = now_local() + runtime_options.adaptive_hysteresis_seconds
		end
		return
	end
	runtime_metrics.failures += 1
	runtime_metrics.last_error = string.sub(string.gsub(tostring(message or "unknown request error"), "%c", " "), 1, 200)
	local normalized = string.lower(tostring(message or ""))
	local throttled = string.find(normalized, "thrott", 1, true) ~= nil
		or string.find(normalized, "request limit", 1, true) ~= nil
		or string.find(normalized, "rate limit", 1, true) ~= nil
		or string.find(normalized, "429", 1, true) ~= nil
	if throttled then
		runtime_metrics.throttles += 1
		if runtime_options.adaptive_runtime_enabled then
			runtime_effective_concurrent_requests = math.max(
				runtime_options.adaptive_min_concurrent_requests + runtime_options.critical_request_reserve,
				runtime_effective_concurrent_requests - 1
			)
			runtime_next_growth_at = now_local() + runtime_options.adaptive_hysteresis_seconds
		end
	end
end

local function refresh_runtime_policy(now: number)
	if runtime_policy_provider == nil or runtime_refresh_in_flight or now < runtime_next_policy_refresh then return end
	runtime_next_policy_refresh = now + runtime_options.runtime_policy_refresh_interval
	runtime_refresh_in_flight = true
	local provider = runtime_policy_provider
	task.spawn(function()
		local ok, result = pcall(provider)
		if ok and type(result) == "table" then
			apply_runtime_policy(result, true)
		else
			runtime_metrics.last_policy_error = string.sub(string.gsub(tostring(result or "runtime policy provider failed"), "%c", " "), 1, 200)
		end
		runtime_refresh_in_flight = false
	end)
end

local function effective_queue_poll_interval(requested: number): number
	if not runtime_options.adaptive_runtime_enabled then return requested end
	local interval = math.clamp(requested, runtime_options.adaptive_min_queue_poll_interval, runtime_options.adaptive_max_queue_poll_interval)
	if (runtime_budget_read ~= nil and runtime_budget_read < runtime_options.adaptive_read_budget_floor)
		or (runtime_budget_write ~= nil and runtime_budget_write < runtime_options.adaptive_write_budget_floor)
	then
		return runtime_options.adaptive_max_queue_poll_interval
	end
	if runtime_effective_concurrent_requests < runtime_options.adaptive_max_concurrent_requests then
		return math.min(runtime_options.adaptive_max_queue_poll_interval, interval * 1.5)
	end
	return interval
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
	if envelope.inbox_receipts ~= nil then
		stored.inbox_receipts = copy_value(envelope.inbox_receipts :: JsonValue) :: JsonValue
	end
	if envelope.outbox ~= nil then
		stored.outbox = copy_value(envelope.outbox :: JsonValue) :: JsonValue
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


local function runtime_breaker_admit(kind: string): (boolean, string?)
	local breaker = runtime_breakers[kind]
	if breaker == nil then return true, nil end
	local now = now_local()
	if breaker.open_until > now then
		return false, ("shared %s circuit is open for %.2f more seconds"):format(kind, breaker.open_until - now)
	end
	if breaker.failures >= runtime_options.circuit_threshold then
		if breaker.probe_in_flight then
			return false, ("shared %s circuit is waiting for its half-open probe"):format(kind)
		end
		breaker.probe_in_flight = true
	end
	return true, nil
end

local function runtime_breaker_cancel_probe(kind: string)
	local breaker = runtime_breakers[kind]
	if breaker ~= nil and breaker.failures >= runtime_options.circuit_threshold then
		breaker.probe_in_flight = false
	end
end

local function runtime_breaker_complete(kind: string, success: boolean)
	local breaker = runtime_breakers[kind]
	if breaker == nil then return end
	if success then
		breaker.failures = 0
		breaker.open_until = 0
		breaker.probe_in_flight = false
		return
	end
	breaker.failures += 1
	breaker.probe_in_flight = false
	if breaker.failures >= runtime_options.circuit_threshold then
		breaker.open_until = now_local() + runtime_options.circuit_cooldown_seconds
	end
end

local function runtime_degraded_reject(state: InternalState?, update: boolean): boolean
	local mode = runtime_options.degraded_mode
	if mode == "normal" then return false end
	local critical = request_is_critical(state)
	if mode == "reject_noncritical" then return not critical end
	if mode == "read_only" then return update and not critical end
	return false
end

local function budget_available(request_type: Enum.DataStoreRequestType): boolean?
	local budget = request_budget(request_type)
	return if budget == nil then nil else budget >= 1
end

local function acquire_slot(deadline: number, critical: boolean): boolean
	local limit = runtime_effective_concurrent_requests
	if not critical then limit = math.max(1, limit - runtime_options.critical_request_reserve) end
	while active_requests >= limit and now_local() < deadline do
		task.wait(0.05)
		limit = runtime_effective_concurrent_requests
		if not critical then limit = math.max(1, limit - runtime_options.critical_request_reserve) end
	end
	if active_requests >= limit then return false end
	active_requests += 1
	return true
end

local function release_slot()
	active_requests = math.max(0, active_requests - 1)
end

local function acquire_request(state: InternalState?, deadline: number, update: boolean, request_type: Enum.DataStoreRequestType?): boolean
	local critical = request_is_critical(state)
	if runtime_degraded_reject(state, update) then
		runtime_metrics.budget_rejections += 1
		return false
	end
	local circuit_kind = if update then "write" else "read"
	local circuit_ok = runtime_breaker_admit(circuit_kind)
	if not circuit_ok then
		runtime_metrics.budget_rejections += 1
		return false
	end
	if runtime_options.adaptive_runtime_enabled then
		local read_budget = if request_type == nil or request_type == Enum.DataStoreRequestType.StandardRead
			then request_budget(Enum.DataStoreRequestType.StandardRead) else nil
		local write_budget = if update and (request_type == nil or request_type == Enum.DataStoreRequestType.StandardWrite)
			then request_budget(Enum.DataStoreRequestType.StandardWrite) else nil
		if not critical and ((read_budget ~= nil and read_budget < runtime_options.adaptive_read_budget_floor)
			or (write_budget ~= nil and write_budget < runtime_options.adaptive_write_budget_floor))
		then
			runtime_metrics.budget_rejections += 1
			return false
		end
		if state ~= nil and state.queue_busy and not consume_runtime_queue_token() then return false end
	end
	if not acquire_slot(deadline, critical) then
		runtime_breaker_cancel_probe(circuit_kind)
		return false
	end
	local wait_seconds = if state ~= nil then state.options.budget_wait or DEFAULT_BUDGET_WAIT else DEFAULT_BUDGET_WAIT
	local wait_deadline = math.min(deadline, now_local() + wait_seconds)
	while now_local() < wait_deadline do
		if request_type ~= nil then
			local available = budget_available(request_type)
			if available ~= false then return true end
		else
			local read_available = budget_available(Enum.DataStoreRequestType.StandardRead)
			local write_available = if update then budget_available(Enum.DataStoreRequestType.StandardWrite) else true
			if read_available ~= false and write_available ~= false then return true end
		end
		task.wait(0.05)
	end
	local available = if request_type ~= nil
		then budget_available(request_type)
		else budget_available(Enum.DataStoreRequestType.StandardRead) ~= false
		and (not update or budget_available(Enum.DataStoreRequestType.StandardWrite) ~= false)
	if available == false then
		release_slot()
		runtime_breaker_cancel_probe(circuit_kind)
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
	local started_at = now_local()
	local ok, raw, key_info = pcall(function()
		return store:GetAsync(backend.key, options)
	end)
	release_slot()
	observe_runtime_request("read", ok, if ok then nil else tostring(raw), (now_local() - started_at) * 1000)
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
		if mock_update_response_lost_count > 0 then
			mock_update_response_lost_count -= 1
			return nil, nil, "unknown", mock_update_response_lost_message or "injected response loss after UpdateAsync committed"
		end
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
	local started_at = now_local()
	local ok, result, key_info = pcall(function()
		return store:UpdateAsync(backend.key, function(raw, key_info)
			local info = backend_info_from_key_info(key_info)
			local new_value, user_ids, metadata = transform(raw, info)
			return encode_backend_update_value(new_value), user_ids, metadata
		end)
	end)
	release_slot()
	observe_runtime_request("write", ok, if ok then nil else tostring(result), (now_local() - started_at) * 1000)
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
	local raw_inbox_receipts = get_string_field(raw, "inbox_receipts")
	local raw_outbox = get_string_field(raw, "outbox")
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
	local inbox_receipts: { [string]: InboxReceiptRecord } = {}
	if raw_inbox_receipts ~= nil then
		if type(raw_inbox_receipts) ~= "table" then
			return nil, "invalid inbox_receipts sidecar", false
		end
		local receipt_count = 0
		for operation_id, raw_receipt in raw_inbox_receipts :: { [string]: unknown } do
			receipt_count += 1
			if receipt_count > MAX_INBOX_RECEIPTS or type(operation_id) ~= "string" or operation_id == "" or #operation_id > 128 then
				return nil, "inbox receipt count or operation_id exceeds its bound", false
			end
			if type(raw_receipt) ~= "table" then
				return nil, "invalid inbox receipt entry", false
			end
			local raw_operation = get_string_field(raw_receipt, "operation_id")
			local fingerprint = get_string_field(raw_receipt, "request_fingerprint")
			local receipt_material = (raw_receipt :: { [string]: unknown }).request_material
			if receipt_material ~= nil and (type(receipt_material) ~= "string" or #receipt_material > MAX_REQUEST_MATERIAL_BYTES) then
				return nil, "invalid inbox receipt request_material", false
			end
			local receipt_write_id = get_string_field(raw_receipt, "write_id")
			local receipt_revision = get_string_field(raw_receipt, "revision")
			local committed_at = get_string_field(raw_receipt, "committed_at")
			if raw_operation ~= operation_id
				or type(fingerprint) ~= "string" or fingerprint == "" or #fingerprint > 256
				or type(receipt_write_id) ~= "string" or receipt_write_id == "" or #receipt_write_id > 128
				or type(receipt_revision) ~= "number" or not math.isfinite(receipt_revision) or math.floor(receipt_revision) ~= receipt_revision or receipt_revision < 1
				or type(committed_at) ~= "number" or not math.isfinite(committed_at)
			then
				return nil, "invalid inbox receipt fields", false
			end
			inbox_receipts[operation_id] = {
				operation_id = operation_id,
				request_fingerprint = fingerprint,
				request_material = receipt_material :: string?,
				write_id = receipt_write_id,
				revision = receipt_revision,
				committed_at = committed_at,
			}
		end
	end
	local outbox: { [string]: OutboxEntryRecord } = {}
	if raw_outbox ~= nil then
		if type(raw_outbox) ~= "table" then
			return nil, "invalid outbox sidecar", false
		end
		local outbox_count = 0
		for event_id, raw_event in raw_outbox :: { [string]: unknown } do
			outbox_count += 1
			if outbox_count > MAX_OUTBOX_EVENTS or type(event_id) ~= "string" or event_id == "" or #event_id > 128 then
				return nil, "outbox count or event_id exceeds its bound", false
			end
			if type(raw_event) ~= "table" then
				return nil, "invalid outbox entry", false
			end
			local stored_event_id = get_string_field(raw_event, "event_id")
			local operation_id = get_string_field(raw_event, "operation_id")
			local destination_store = get_string_field(raw_event, "destination_store_name")
			local destination_scope = get_string_field(raw_event, "destination_scope")
			local destination_key = get_string_field(raw_event, "destination_profile_key")
			local message_type = get_string_field(raw_event, "message_type")
			local raw_payload = get_string_field(raw_event, "payload")
			local status = get_string_field(raw_event, "state")
			local created_at = get_string_field(raw_event, "created_at")
			local dispatched_at = get_string_field(raw_event, "dispatched_at")
			local attempts = get_string_field(raw_event, "attempts")
			local last_error = get_string_field(raw_event, "last_error")
			local receipt_id = get_string_field(raw_event, "destination_receipt_id")
			if stored_event_id ~= event_id
				or type(operation_id) ~= "string" or operation_id == "" or #operation_id > 128
				or type(destination_store) ~= "string" or destination_store == "" or #destination_store > 50
				or type(destination_scope) ~= "string" or destination_scope == "" or #destination_scope > 50
				or type(destination_key) ~= "string" or destination_key == "" or #destination_key > 50
				or type(message_type) ~= "string" or message_type == "" or #message_type > MAX_MESSAGE_TYPE_LENGTH
				or (status ~= "pending" and status ~= "dispatched")
				or type(created_at) ~= "number" or not math.isfinite(created_at)
				or (dispatched_at ~= nil and (type(dispatched_at) ~= "number" or not math.isfinite(dispatched_at)))
				or type(attempts) ~= "number" or not math.isfinite(attempts) or math.floor(attempts) ~= attempts or attempts < 0
				or (last_error ~= nil and (type(last_error) ~= "string" or #last_error > MAX_QUEUE_ERROR_LENGTH))
				or (receipt_id ~= nil and (type(receipt_id) ~= "string" or #receipt_id > 256))
			then
				return nil, "invalid outbox entry fields", false
			end
			local payload: JsonValue? = nil
			if raw_payload ~= nil then
				local copied_payload = copy_value(raw_payload :: JsonValue)
				if copied_payload == nil then
					return nil, "invalid outbox payload", false
				end
				payload = copied_payload
			end
			outbox[event_id] = {
				event_id = event_id,
				operation_id = operation_id,
				destination_store_name = destination_store,
				destination_scope = destination_scope,
				destination_profile_key = destination_key,
				message_type = message_type,
				payload = payload,
				state = status :: "pending" | "dispatched",
				created_at = created_at,
				dispatched_at = dispatched_at :: number?,
				attempts = attempts,
				last_error = last_error :: string?,
				destination_receipt_id = receipt_id :: string?,
			}
		end
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
		inbox_receipts = inbox_receipts,
		outbox = outbox,
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
	if reason == "autosave" and state.change_sequence == state.saved_change_sequence
		and not state.save_requested and state.last_saved ~= nil
	then
		state.next_autosave = now_local() + (state.options.autosave_interval or DEFAULT_AUTOSAVE_INTERVAL)
		runtime_metrics.no_op_saves += 1
		return "saved", nil
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
				inbox_receipts = envelope.inbox_receipts or {},
				outbox = envelope.outbox or {},
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
		mark_saved(state, captured_change_sequence)
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

local function read_async_uncached(name: string, scope: string, key: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
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

local function clone_read_snapshot(snapshot: Snapshot?): Snapshot?
	if snapshot == nil then return nil end
	local result = table.clone(snapshot)
	result.Data = copy_value(snapshot.Data)
	result.UserIds = clone_user_ids(snapshot.UserIds)
	result.Metadata = clone_metadata(snapshot.Metadata)
	return result
end

function RecordStore.read_async(name: string, scope: string, key: string, operation_deadline: number?, legacy_decoder: LegacyDecoder?): (Snapshot?, ResultCode, string?)
	-- Legacy decoders are application callbacks; do not coalesce across different callback identities.
	if legacy_decoder ~= nil then
		return read_async_uncached(name, scope, key, operation_deadline, legacy_decoder)
	end
	local valid_identity = validate_store_identity(name, scope, key)
	if not valid_identity then
		return read_async_uncached(name, scope, key, operation_deadline, nil)
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then return nil, "invalid", deadline_error end
	local identity = tostring(#name) .. ":" .. name .. tostring(#scope) .. ":" .. scope .. tostring(#key) .. ":" .. key
	local current = in_flight_reads[identity]
	if current ~= nil and not current.done then
		if #current.waiters >= MAX_IN_FLIGHT_READ_WAITERS then
			return read_async_uncached(name, scope, key, operation_deadline, nil)
		end
		local event_ok, event = pcall(function() return Instance.new("BindableEvent") end)
		if not event_ok or event == nil then
			-- Coalescing is an optimization only. If waiter signaling is unavailable, perform a normal read.
			return read_async_uncached(name, scope, key, operation_deadline, nil)
		end
		local waiter: ReadFlightWaiter = { event = event, active = true, timed_out = false }
		table.insert(current.waiters, waiter)
		local remaining = math.max(0, (deadline :: number) - now_local())
		task.delay(remaining, function()
			if waiter.active then
				waiter.active = false
				waiter.timed_out = true
				pcall(function() event:Fire() end)
			end
		end)
		event.Event:Wait()
		if waiter.timed_out then
			pcall(function() event:Destroy() end)
			return nil, "budget", "coalesced read waiter exceeded its local operation deadline"
		end
		pcall(function() event:Destroy() end)
		return clone_read_snapshot(current.snapshot), current.code, current.message
	end

	local flight_count = 0
	for _ in pairs(in_flight_reads) do flight_count += 1 end
	if flight_count >= MAX_IN_FLIGHT_READ_KEYS then
		return read_async_uncached(name, scope, key, operation_deadline, nil)
	end
	local flight: ReadFlight = { waiters = {}, done = false, snapshot = nil, code = "unknown", message = "read did not produce a result" }
	in_flight_reads[identity] = flight
	local call_ok, snapshot_or_error, code_or_nil, message_or_nil = pcall(function()
		return read_async_uncached(name, scope, key, operation_deadline, nil)
	end)
	local snapshot: Snapshot? = nil
	local code: ResultCode = "unknown"
	local message: string? = nil
	if call_ok then
		snapshot = snapshot_or_error :: Snapshot?
		code = code_or_nil :: ResultCode
		message = message_or_nil :: string?
	else
		message = tostring(snapshot_or_error)
	end
	flight.snapshot = clone_read_snapshot(snapshot)
	flight.code = code
	flight.message = message
	flight.done = true
	if in_flight_reads[identity] == flight then in_flight_reads[identity] = nil end
	for _, waiter in ipairs(flight.waiters) do
		if waiter.active then
			waiter.active = false
			pcall(function() waiter.event:Fire() end)
		end
	end
	table.clear(flight.waiters)
	return snapshot, code, message
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
	mark_dirty(state)
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

local function get_identity(self: Record): RecordIdentity
	local state = private[self]
	if state == nil then
		return { store_name = "", scope = "", profile_key = self.Key, user_ids = {} }
	end
	return {
		store_name = state.name,
		scope = state.scope,
		profile_key = state.key,
		user_ids = clone_user_ids(state.user_ids),
	}
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
	mark_dirty(state)
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
	mark_dirty(state)
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
	mark_dirty(state)
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
	mark_dirty(state)
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
		mark_dirty(state)
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

local function clone_inbox_receipts(source: { [string]: InboxReceiptRecord }?): { [string]: InboxReceiptRecord }
	local result: { [string]: InboxReceiptRecord } = {}
	for operation_id, receipt in source or {} do
		result[operation_id] = {
			operation_id = receipt.operation_id,
			request_fingerprint = receipt.request_fingerprint,
			request_material = receipt.request_material,
			write_id = receipt.write_id,
			revision = receipt.revision,
			committed_at = receipt.committed_at,
		}
	end
	return result
end

local function clone_outbox_entries(source: { [string]: OutboxEntryRecord }?): { [string]: OutboxEntryRecord }
	local result: { [string]: OutboxEntryRecord } = {}
	for event_id, event in source or {} do
		result[event_id] = {
			event_id = event.event_id,
			operation_id = event.operation_id,
			destination_store_name = event.destination_store_name,
			destination_scope = event.destination_scope,
			destination_profile_key = event.destination_profile_key,
			message_type = event.message_type,
			payload = if event.payload ~= nil then copy_value(event.payload) else nil,
			state = event.state,
			created_at = event.created_at,
			dispatched_at = event.dispatched_at,
			attempts = event.attempts,
			last_error = event.last_error,
			destination_receipt_id = event.destination_receipt_id,
		}
	end
	return result
end

local function outbox_to_public(event: OutboxEntryRecord): OutboxEvent
	return {
		EventId = event.event_id,
		OperationId = event.operation_id,
		DestinationStoreName = event.destination_store_name,
		DestinationScope = event.destination_scope,
		DestinationProfileKey = event.destination_profile_key,
		MessageType = event.message_type,
		Data = if event.payload ~= nil then copy_value(event.payload) else nil,
		State = event.state,
		CreatedAt = event.created_at,
		DispatchedAt = event.dispatched_at,
		Attempts = event.attempts,
		LastError = event.last_error,
		DestinationReceiptId = event.destination_receipt_id,
	}
end

local function validate_operation_identity(operation_id: string, request_fingerprint: string, request_material: string?): string?
	if type(operation_id) ~= "string" or operation_id == "" or #operation_id > 128 then
		return "operation_id must be 1 to 128 bytes"
	end
	if type(request_fingerprint) ~= "string" or request_fingerprint == "" or #request_fingerprint > 256 then
		return "request_fingerprint must be 1 to 256 bytes"
	end
	if request_material ~= nil and (type(request_material) ~= "string" or #request_material > MAX_REQUEST_MATERIAL_BYTES) then
		return "request_material exceeds its 16384-byte bound"
	end
	return nil
end

local function prepare_outbox_inputs(
	operation_id: string,
	events: { OutboxEventInput },
	created_at: number
): ({ OutboxEntryRecord }?, string?)
	if type(events) ~= "table" or #events > MAX_OUTBOX_EVENTS_PER_COMMIT then
		return nil, "one transaction may contain at most " .. tostring(MAX_OUTBOX_EVENTS_PER_COMMIT) .. " outbox events"
	end
	local prepared: { OutboxEntryRecord } = {}
	local seen: { [string]: boolean } = {}
	for index, event in events do
		if type(index) ~= "number" or not math.isfinite(index) or math.floor(index) ~= index or index < 1 or index > #events then
			return nil, "outbox events must be a dense array"
		end
		if type(event) ~= "table"
			or type(event.EventId) ~= "string" or event.EventId == "" or #event.EventId > 128
			or seen[event.EventId] == true
			or type(event.DestinationStoreName) ~= "string" or event.DestinationStoreName == "" or #event.DestinationStoreName > 50
			or type(event.DestinationScope) ~= "string" or event.DestinationScope == "" or #event.DestinationScope > 50
			or type(event.DestinationProfileKey) ~= "string" or event.DestinationProfileKey == "" or #event.DestinationProfileKey > 50
			or type(event.MessageType) ~= "string" or event.MessageType == "" or #event.MessageType > MAX_MESSAGE_TYPE_LENGTH
		then
			return nil, "invalid or duplicate outbox event input at index " .. tostring(index)
		end
		seen[event.EventId] = true
		local payload: JsonValue? = nil
		if event.Data ~= nil then
			local copied_ok, copied = pcall(function()
				return copy_value(event.Data :: JsonValue)
			end)
			if not copied_ok or copied == nil then
				return nil, "outbox payload is not a valid JSON value"
			end
			payload = copied
		end
		table.insert(prepared, {
			event_id = event.EventId,
			operation_id = operation_id,
			destination_store_name = event.DestinationStoreName,
			destination_scope = event.DestinationScope,
			destination_profile_key = event.DestinationProfileKey,
			message_type = event.MessageType,
			payload = payload,
			state = "pending",
			created_at = created_at,
			dispatched_at = nil,
			attempts = 0,
			last_error = nil,
			destination_receipt_id = nil,
		})
	end
	return prepared, nil
end

local function validate_envelope_for_transaction(envelope: Envelope): (boolean, string?)
	local encoded_ok, stored_or_error = pcall(function()
		return encode_envelope_for_storage(envelope)
	end)
	if not encoded_ok then
		return false, tostring(stored_or_error)
	end
	return validate_serialized_size(stored_or_error :: JsonValue)
end

local function transaction_internal(
	state: InternalState,
	operation_id: string,
	request_fingerprint: string,
	transform: TransactionTransform,
	outbox_inputs: { OutboxEventInput }?,
	request_material: string?
): (ResultCode, string?)
	local identity_error = validate_operation_identity(operation_id, request_fingerprint, request_material)
	if identity_error ~= nil then
		return "invalid", identity_error
	end
	if type(transform) ~= "function" then
		return "invalid", "transaction transform must be a function"
	end
	track_external_data_mutation(state)
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
	if state.busy or state.queue_busy then
		return "busy", "record has another durable operation in flight"
	end
	if state.change_sequence ~= state.saved_change_sequence then
		return "busy", "save local profile changes before starting an atomic transaction"
	end
	local session_token = state.token
	if session_token == nil then
		return "fenced", "session token is missing"
	end
	if state.data == nil then
		return "invalid", "record has no active profile data"
	end
	local base_data = copy_value(state.data)
	if base_data == nil then
		return "validation", "profile data could not be copied"
	end
	local callback_ok, transformed_value = pcall(transform, copy_value(base_data))
	if not callback_ok then
		return "validation", "transaction transform failed: " .. string.sub(tostring(transformed_value), 1, MAX_QUEUE_ERROR_LENGTH)
	end
	if transformed_value == nil then
		return "validation", "transaction transform must return a non-nil JSON value"
	end
	local data_ok, next_data = pcall(function()
		return copy_value(transformed_value)
	end)
	if not data_ok or next_data == nil then
		return "validation", "transaction transform returned an invalid JSON value"
	end
	local valid_data, data_error = validate_value(next_data, state.options.validator)
	if not valid_data then
		return "validation", data_error
	end

	local generation = state.generation
	local expected_revision = state.revision
	local write_id = HttpService:GenerateGUID(false)
	local operation_time = now_unix()
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then
		return "invalid", deadline_error
	end
	local prepared_events, events_error = prepare_outbox_inputs(operation_id, outbox_inputs or {}, operation_time)
	if prepared_events == nil then
		return "validation", events_error
	end
	state.current_operation_id = write_id
	state.busy = true
	state.state = "saving"
	local attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	local last_error: string? = nil
	for attempt = 1, attempts do
		if state.retired or state.state ~= "saving" then
			state.busy = false
			return "closing", "transaction was invalidated before completion"
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local transaction_time = session_now_unix(state.backend.mock)
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if not matches_session(envelope, session_token :: string, generation)
				or envelope.session == nil or envelope.session.lease_until <= transaction_time
			then
				decision = "fenced"
				decision_message = "durable profile session fence is no longer valid"
				return nil, nil, nil
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			local receipts = envelope.inbox_receipts or {}
			local existing_receipt = receipts[operation_id]
			if existing_receipt ~= nil then
				if existing_receipt.request_fingerprint ~= request_fingerprint then
					decision = "conflict"
					decision_message = "operation_id is already bound to a different request_fingerprint"
					return nil, nil, nil
				end
				if request_material ~= nil and existing_receipt.request_material ~= nil
					and existing_receipt.request_material ~= request_material
				then
					decision = "conflict"
					decision_message = "operation_id fingerprint matched but exact request material differed"
					return nil, nil, nil
				end
				if existing_receipt.write_id == write_id then
					decision = "success"
					return envelope, (info ~= nil and info.UserIds or envelope.user_ids or state.user_ids),
						make_backend_metadata(if info ~= nil then info.RawMetadata else state.metadata, envelope)
				end
				decision = "duplicate"
				decision_message = "operation was already committed"
				return nil, nil, nil
			end
			if envelope.revision ~= expected_revision then
				decision = "conflict"
				decision_message = "durable revision changed before transaction commit"
				return nil, nil, nil
			end
			local receipts_copy = clone_inbox_receipts(envelope.inbox_receipts)
			if (function()
				local count = 0
				for _ in receipts_copy do count += 1 end
				return count
			end)() >= MAX_INBOX_RECEIPTS then
				decision = "capacity"
				decision_message = "inbox receipt capacity reached; prune only after the caller's deduplication window"
				return nil, nil, nil
			end
			local outbox_copy = clone_outbox_entries(envelope.outbox)
			local outbox_count = 0
			for _ in outbox_copy do outbox_count += 1 end
			if outbox_count + #prepared_events > MAX_OUTBOX_EVENTS then
				decision = "capacity"
				decision_message = "outbox capacity reached; dispatch and prune verified terminal events before retry"
				return nil, nil, nil
			end
			for _, event in prepared_events do
				if outbox_copy[event.event_id] ~= nil then
					decision = "conflict"
					decision_message = "outbox event_id is already present: " .. event.event_id
					return nil, nil, nil
				end
				outbox_copy[event.event_id] = event
			end
			local durable_ids = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else clone_user_ids(state.user_ids)
			local durable_metadata = if info ~= nil then clone_metadata(info.RawMetadata) else clone_metadata(state.metadata)
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = state.options.schema_version,
				revision = envelope.revision + 1,
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transaction_time,
				data = next_data :: JsonValue,
				user_ids = durable_ids,
				tombstone = nil,
				session = {
					token = session_token :: string,
					generation = generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = envelope.session.acquired_at,
					lease_until = transaction_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				inbox_receipts = receipts_copy,
				outbox = outbox_copy,
				write_id = write_id,
			}
			local envelope_valid, envelope_error = validate_envelope_for_transaction(next_envelope)
			if not envelope_valid then
				decision = "validation"
				decision_message = envelope_error or "transaction envelope failed validation"
				return nil, nil, nil
			end
			receipts_copy[operation_id] = {
				operation_id = operation_id,
				request_fingerprint = request_fingerprint,
				request_material = request_material,
				write_id = write_id,
				revision = next_envelope.revision,
				committed_at = operation_time,
			}
			-- Refresh the encoded size after the receipt is part of the same atomic write.
			local final_valid, final_error = validate_envelope_for_transaction(next_envelope)
			if not final_valid then
				decision = "validation"
				decision_message = final_error or "transaction receipt envelope failed validation"
				return nil, nil, nil
			end
			decision = "success"
			return next_envelope, durable_ids, make_backend_metadata(durable_metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if decision == "duplicate" or decision == "conflict" or decision == "capacity" or decision == "validation"
			or decision == "fenced" or decision == "future_schema" or decision == "corrupt"
		then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			observe(state, "transaction", decision, decision_message)
			return decision, decision_message
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			local receipt = if returned ~= nil and returned.inbox_receipts ~= nil then returned.inbox_receipts[operation_id] else nil
			if returned ~= nil and receipt ~= nil
				and returned.write_id == write_id
				and receipt.write_id == write_id
				and receipt.request_fingerprint == request_fingerprint
				and returned.revision == receipt.revision
				and matches_session(returned, session_token :: string, generation)
				and backend_metadata_matches(info, returned)
			then
				update_local_from_envelope(state, returned, info)
				mark_saved(state, state.change_sequence)
				state.last_saved = make_durable_snapshot(returned, info, "transaction")
				state.last_observed = now_unix()
				state.busy = false
				state.state = "active"
				observe(state, "transaction", "success", operation_id)
				sync_public(state.public_record)
				return "success", nil
			end
		end
		last_error = result_message or decision_message
		if attempt < attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	state.busy = false
	state.state = "unknown"
	observe(state, "transaction", "unknown", last_error or "transaction commit outcome is unresolved")
	return "unknown", last_error or "transaction commit outcome is unresolved"
end

local function update_profile_sidecars(
	state: InternalState,
	reason: string,
	mutate: (
		{ [string]: InboxReceiptRecord },
		{ [string]: OutboxEntryRecord },
		number
	) -> ({ [string]: InboxReceiptRecord }?, { [string]: OutboxEntryRecord }?, ResultCode?, string?, number?)
): (number, ResultCode, string?)
	track_external_data_mutation(state)
	if state.retired then return 0, "invalid", "record has been retired" end
	if closing then return 0, "closing", "server is shutting down" end
	if state.state ~= "active" then return 0, if state.state == "tombstoned" then "tombstoned" else "fenced", "record is not actively owned" end
	if state.takeover_requested then return 0, "closing", "session takeover has been requested" end
	if state.busy or state.queue_busy then return 0, "busy", "record has another durable operation in flight" end
	local session_token = state.token
	if session_token == nil then return 0, "fenced", "session token is missing" end
	local generation = state.generation
	local expected_revision = state.revision
	local write_id = HttpService:GenerateGUID(false)
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then return 0, "invalid", deadline_error end
	local max_attempts = state.options.retry_attempts or DEFAULT_RETRY_ATTEMPTS
	state.current_operation_id = write_id
	state.busy = true
	state.state = "saving"
	local affected_count = 0
	local last_error: string? = nil
	for attempt = 1, max_attempts do
		if state.retired or state.state ~= "saving" then
			state.busy = false
			return affected_count, "closing", "sidecar update was invalidated"
		end
		local decision: ResultCode? = nil
		local decision_message: string? = nil
		local transaction_time = session_now_unix(state.backend.mock)
		local result, info, result_code, result_message = backend_update(state.backend, function(raw, info)
			decision = nil
			decision_message = nil
			local envelope, parse_error, current_format = parse_envelope(raw)
			if not current_format or envelope == nil then
				decision = if parse_error == "future implementation version" then "future_schema" else "corrupt"
				decision_message = parse_error or "durable envelope is invalid"
				return nil, nil, nil
			end
			if envelope.write_id == write_id and matches_session(envelope, session_token :: string, generation) then
				decision = "success"
				return envelope, (info ~= nil and info.UserIds or envelope.user_ids or state.user_ids),
					make_backend_metadata(if info ~= nil then info.RawMetadata else state.metadata, envelope)
			end
			if not matches_session(envelope, session_token :: string, generation)
				or envelope.session == nil or envelope.session.lease_until <= transaction_time
			then
				decision = "fenced"
				decision_message = "durable profile session fence is no longer valid"
				return nil, nil, nil
			end
			if envelope.schema_version > state.options.schema_version then
				decision = "future_schema"
				decision_message = "durable schema is newer than this server supports"
				return nil, nil, nil
			end
			if envelope.revision ~= expected_revision then
				decision = "conflict"
				decision_message = "durable revision changed before sidecar update"
				return nil, nil, nil
			end
			local next_receipts, next_outbox, mutate_code, mutate_message, count = mutate(
				clone_inbox_receipts(envelope.inbox_receipts),
				clone_outbox_entries(envelope.outbox),
				transaction_time
			)
			if mutate_code ~= nil then
				decision = mutate_code
				decision_message = mutate_message
				affected_count = count or affected_count
				return nil, nil, nil
			end
			if next_receipts == nil or next_outbox == nil then
				decision = "validation"
				decision_message = "sidecar mutator returned incomplete maps"
				return nil, nil, nil
			end
			affected_count = count or affected_count
			local durable_ids = if info ~= nil then clone_user_ids(info.UserIds) elseif envelope.user_ids ~= nil then clone_user_ids(envelope.user_ids) else clone_user_ids(state.user_ids)
			local durable_metadata = if info ~= nil then clone_metadata(info.RawMetadata) else clone_metadata(state.metadata)
			local next_envelope: Envelope = {
				implementation_version = IMPLEMENTATION_VERSION,
				schema_version = envelope.schema_version,
				revision = envelope.revision + 1,
				fencing_generation = generation,
				created_at = envelope.created_at,
				updated_at = transaction_time,
				data = envelope.data,
				user_ids = durable_ids,
				tombstone = nil,
				session = {
					token = session_token :: string,
					generation = generation,
					job_id = server_id,
					place_id = game.PlaceId,
					acquired_at = envelope.session.acquired_at,
					lease_until = transaction_time + (state.options.lease_duration or DEFAULT_LEASE_DURATION),
				},
				inbox_receipts = next_receipts,
				outbox = next_outbox,
				write_id = write_id,
			}
			local valid_envelope, envelope_error = validate_envelope_for_transaction(next_envelope)
			if not valid_envelope then
				decision = "validation"
				decision_message = envelope_error or "sidecar envelope failed validation"
				return nil, nil, nil
			end
			decision = "success"
			return next_envelope, durable_ids, make_backend_metadata(durable_metadata, next_envelope)
		end, deadline, state)
		if result_code ~= nil then
			decision = result_code
			decision_message = result_message
		end
		if decision == "duplicate" or decision == "not_found" or decision == "capacity"
			or decision == "validation" or decision == "conflict" or decision == "fenced"
			or decision == "future_schema" or decision == "corrupt"
		then
			state.busy = false
			state.state = if decision == "fenced" then "fenced" elseif decision == "future_schema" then "future" elseif decision == "corrupt" then "corrupt" else "active"
			return affected_count, decision, decision_message
		end
		if result ~= nil then
			local returned = parse_envelope(result)
			if returned ~= nil and returned.write_id == write_id
				and returned.revision == expected_revision + 1
				and matches_session(returned, session_token :: string, generation)
				and backend_metadata_matches(info, returned)
			then
				state.revision = returned.revision
				state.updated_at = returned.updated_at
				state.durable_lease_until = if returned.session ~= nil then returned.session.lease_until else 0
				update_state_metadata_from_info(state, info)
				state.last_saved = make_durable_snapshot(returned, info, reason)
				state.last_observed = now_unix()
				if state.change_sequence ~= state.saved_change_sequence then
					state.save_requested = true
					state.next_autosave = now_local()
				end
				state.busy = false
				state.state = "active"
				sync_public(state.public_record)
				return affected_count, "success", nil
			end
		end
		last_error = result_message or decision_message
		if attempt < max_attempts then
			task.wait(math.min(retry_delay(attempt), math.max(0, deadline - now_local())))
		end
	end
	state.busy = false
	state.state = "unknown"
	observe(state, reason, "unknown", last_error or "sidecar update outcome is unresolved")
	return affected_count, "unknown", last_error or "sidecar update outcome is unresolved"
end

local function transaction(self: Record, operation_id: string, request_fingerprint: string, transform: TransactionTransform, request_material: string?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	return transaction_internal(state, operation_id, request_fingerprint, transform, nil, request_material)
end

local function apply_inbox(self: Record, operation_id: string, request_fingerprint: string, transform: TransactionTransform, request_material: string?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	return transaction_internal(state, operation_id, request_fingerprint, transform, nil, request_material)
end

local function commit_with_outbox(self: Record, operation_id: string, request_fingerprint: string, transform: TransactionTransform, events: { OutboxEventInput }, request_material: string?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	return transaction_internal(state, operation_id, request_fingerprint, transform, events, request_material)
end

local function get_outbox(self: Record, max_items: number?): ({ OutboxEvent }, ResultCode, string?)
	local state = private[self]
	if state == nil then return {}, "invalid", "record does not exist" end
	if state.state ~= "active" or state.token == nil then return {}, "fenced", "record is not actively owned" end
	local limit = max_items or MAX_OUTBOX_EVENTS
	if not math.isfinite(limit) or math.floor(limit) ~= limit or limit < 1 or limit > MAX_OUTBOX_EVENTS then
		return {}, "invalid", "max_items must be an integer from 1 to " .. tostring(MAX_OUTBOX_EVENTS)
	end
	local deadline, deadline_error = resolve_operation_deadline(state.options.operation_deadline)
	if deadline == nil then return {}, "invalid", deadline_error end
	local raw, info, read_code, read_message = backend_get(state.backend, false, deadline, state)
	if read_code ~= nil then return {}, read_code, read_message end
	local envelope, parse_error, current_format = parse_envelope(raw)
	if not current_format or envelope == nil then return {}, "corrupt", parse_error or "durable envelope is invalid" end
	if not matches_session(envelope, state.token, state.generation)
		or envelope.session == nil or envelope.session.lease_until <= session_now_unix(state.backend.mock)
	then
		return {}, "fenced", "durable profile session fence is no longer valid"
	end
	local result: { OutboxEvent } = {}
	for _, event in envelope.outbox or {} do
		if event.state == "pending" then
			table.insert(result, outbox_to_public(event))
		end
	end
	table.sort(result, function(left, right)
		if left.CreatedAt ~= right.CreatedAt then return left.CreatedAt < right.CreatedAt end
		return left.EventId < right.EventId
	end)
	while #result > limit do table.remove(result) end
	return result, "success", nil
end

local function set_outbox_result(
	state: InternalState,
	event_id: string,
	accepted: boolean,
	destination_receipt_id: string?,
	reason: string?
): (ResultCode, string?)
	if type(event_id) ~= "string" or event_id == "" or #event_id > 128 then return "invalid", "invalid event_id" end
	if destination_receipt_id ~= nil and (type(destination_receipt_id) ~= "string" or #destination_receipt_id > 256) then
		return "invalid", "destination receipt ID exceeds 256 bytes"
	end
	local _, code, message = update_profile_sidecars(state, "outbox_dispatch", function(receipts, outbox, transaction_time)
		local event = outbox[event_id]
		if event == nil then return nil, nil, "not_found", "outbox event does not exist", 0 end
		if event.state == "dispatched" then return nil, nil, "duplicate", "outbox event was already dispatched", 0 end
		local updated = clone_outbox_entries(outbox)
		local current = updated[event_id]
		current.attempts += 1
		if accepted then
			current.state = "dispatched"
			current.dispatched_at = transaction_time
			current.last_error = nil
			current.destination_receipt_id = destination_receipt_id
		else
			current.state = "pending"
			current.dispatched_at = nil
			current.last_error = string.sub(string.gsub(reason or "destination did not confirm acceptance", "[^ -~]", "?"), 1, MAX_QUEUE_ERROR_LENGTH)
		end
		return receipts, updated, nil, nil, 1
	end)
	return code, message
end

local function dispatch_outbox(self: Record, dispatcher: OutboxDispatcher, max_items: number?): (number, ResultCode, string?)
	if type(dispatcher) ~= "function" then return 0, "invalid", "dispatcher must be a function" end
	local state = private[self]
	if state == nil then return 0, "invalid", "record does not exist" end
	local events, read_code, read_message = get_outbox(self, max_items)
	if read_code ~= "success" then return 0, read_code, read_message end
	local dispatched = 0
	local first_error: string? = nil
	for _, event in events do
		-- The destination must deduplicate by EventId. Source cleanup can fail after delivery,
		-- so dispatch is at-least-once and an unknown source result causes the same EventId to retry.
		local call_ok, accepted, receipt_id = pcall(dispatcher, event)
		local confirmed = call_ok and accepted == true
		local reason = if not call_ok then tostring(accepted) elseif accepted ~= true then tostring(receipt_id or "destination did not confirm acceptance") else nil
		local code, message = set_outbox_result(private[self], event.EventId, confirmed, if type(receipt_id) == "string" then receipt_id else nil, reason)
		if code == "success" or (confirmed and code == "duplicate") then
			if confirmed then dispatched += 1 else first_error = first_error or reason end
		else
			first_error = first_error or message or "outbox status could not be updated"
			if code == "fenced" or code == "unknown" or code == "conflict" or code == "corrupt" then
				return dispatched, code, first_error
			end
		end
	end
	return dispatched, "success", first_error
end


local function dispatch_outbox_batch(self: Record, dispatcher: OutboxDispatcher, max_items: number?): (number, ResultCode, string?)
	if type(dispatcher) ~= "function" then return 0, "invalid", "dispatcher must be a function" end
	local state = private[self]
	if state == nil then return 0, "invalid", "record does not exist" end
	local events, read_code, read_message = get_outbox(self, max_items)
	if read_code ~= "success" then return 0, read_code, read_message end
	if #events == 0 then return 0, "success", nil end

	local outcomes: { [string]: { accepted: boolean, receipt_id: string?, reason: string? } } = {}
	local first_error: string? = nil
	for _, event in events do
		-- Destination IDs are stable. If the source commit below is ambiguous, the same IDs are retried.
		local call_ok, accepted, receipt_id = pcall(dispatcher, event)
		local confirmed = call_ok and accepted == true
		local reason = if not call_ok then tostring(accepted)
			elseif accepted ~= true then tostring(receipt_id or "destination did not confirm acceptance")
			else nil
		outcomes[event.EventId] = {
			accepted = confirmed,
			receipt_id = if type(receipt_id) == "string" then receipt_id else nil,
			reason = reason,
		}
		if not confirmed then first_error = first_error or reason end
	end

	local count, code, message = update_profile_sidecars(state, "outbox_dispatch_batch", function(receipts, outbox, transaction_time)
		local updated = clone_outbox_entries(outbox)
		local changed = 0
		local newly_dispatched = 0
		for _, event in events do
			local current = updated[event.EventId]
			local outcome = outcomes[event.EventId]
			if current == nil then
				return nil, nil, "not_found", "outbox event disappeared before batch result commit", 0
			end
			if current.state == "dispatched" then
				continue
			end
			current.attempts += 1
			changed += 1
			if outcome.accepted then
				current.state = "dispatched"
				current.dispatched_at = transaction_time
				current.last_error = nil
				current.destination_receipt_id = outcome.receipt_id
				newly_dispatched += 1
			else
				current.state = "pending"
				current.dispatched_at = nil
				current.last_error = string.sub(string.gsub(outcome.reason or "destination acceptance remains unconfirmed", "[^ -~]", "?"), 1, MAX_QUEUE_ERROR_LENGTH)
			end
		end
		if changed == 0 then return nil, nil, "duplicate", "all selected outbox entries were already dispatched", 0 end
		return receipts, updated, nil, nil, newly_dispatched
	end)
	if code == "success" then return count, code, first_error end
	return 0, code, message or first_error
end

local function prune_transaction_receipts(self: Record, committed_before_ms: number, max_items: number?): (number, ResultCode, string?)
	local state = private[self]
	if state == nil then return 0, "invalid", "record does not exist" end
	if not math.isfinite(committed_before_ms) then return 0, "invalid", "committed_before_ms must be finite" end
	local cutoff_unix = committed_before_ms / 1000
	local limit = max_items or 16
	if not math.isfinite(limit) or math.floor(limit) ~= limit or limit < 1 or limit > 32 then
		return 0, "invalid", "max_items must be an integer from 1 to 32"
	end
	return update_profile_sidecars(state, "receipt_prune", function(receipts, outbox, _now)
		local keys: { string } = {}
		for operation_id, receipt in receipts do
			if receipt.committed_at < cutoff_unix then table.insert(keys, operation_id) end
		end
		table.sort(keys)
		local remove_count = math.min(limit, #keys)
		for index = 1, remove_count do receipts[keys[index]] = nil end
		if remove_count == 0 then return nil, nil, "duplicate", "no receipts are eligible for the requested retention cutoff", 0 end
		return receipts, outbox, nil, nil, remove_count
	end)
end

local function prune_outbox(self: Record, dispatched_before_ms: number, max_items: number?): (number, ResultCode, string?)
	local state = private[self]
	if state == nil then return 0, "invalid", "record does not exist" end
	if not math.isfinite(dispatched_before_ms) then return 0, "invalid", "dispatched_before_ms must be finite" end
	local cutoff_unix = dispatched_before_ms / 1000
	local limit = max_items or 16
	if not math.isfinite(limit) or math.floor(limit) ~= limit or limit < 1 or limit > 32 then
		return 0, "invalid", "max_items must be an integer from 1 to 32"
	end
	return update_profile_sidecars(state, "outbox_prune", function(receipts, outbox, _now)
		local keys: { string } = {}
		for event_id, event in outbox do
			-- Do not delete legacy dispatched rows that lack a verifiable dispatch time.
			if event.state == "dispatched" and event.dispatched_at ~= nil and event.dispatched_at < cutoff_unix then table.insert(keys, event_id) end
		end
		table.sort(keys)
		local remove_count = math.min(limit, #keys)
		for index = 1, remove_count do outbox[keys[index]] = nil end
		if remove_count == 0 then return nil, nil, "duplicate", "no dispatched outbox events are eligible for the requested retention cutoff", 0 end
		return receipts, outbox, nil, nil, remove_count
	end)
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


local function bound_mailbox_for_state(state: InternalState): (any?, ResultCode?, string?)
	local mailbox = state.mailbox_v2
	if mailbox == nil then return nil, nil, nil end
	if type(mailbox) ~= "table"
		or type((mailbox :: any).GetOwner) ~= "function"
		or type((mailbox :: any).EnqueueAsync) ~= "function"
	then
		return nil, "fenced", "bound V2 mailbox no longer exposes its required API"
	end
	local owner_ok, owner = pcall(function() return (mailbox :: any):GetOwner() end)
	if not owner_ok or type(owner) ~= "table" then
		return nil, "fenced", "bound V2 mailbox owner could not be verified"
	end
	local owner_fields = owner :: { [string]: unknown }
	if owner_fields.store_name ~= state.name or owner_fields.scope ~= state.scope or owner_fields.profile_key ~= state.key then
		return nil, "fenced", "bound V2 mailbox identity changed after binding"
	end
	if #state.user_ids > 0 and owner_fields.user_id == nil then
		return nil, "fenced", "bound mailbox lost the UserId required for this Record"
	end
	if owner_fields.user_id ~= nil then
		if type(owner_fields.user_id) ~= "number" or not math.isfinite(owner_fields.user_id)
			or math.floor(owner_fields.user_id) ~= owner_fields.user_id
		then
			return nil, "fenced", "bound V2 mailbox UserId is not a finite integer"
		end
		local found = false
		for _, user_id in ipairs(state.user_ids) do
			if user_id == owner_fields.user_id then found = true; break end
		end
		if not found then return nil, "fenced", "bound V2 mailbox UserId no longer matches persisted Record UserIds" end
	end
	if type((mailbox :: any).GetActiveRecord) == "function" then
		local active_ok, active_record = pcall(function() return (mailbox :: any):GetActiveRecord() end)
		if not active_ok then return nil, "fenced", "bound mailbox active Record could not be verified" end
		if active_record ~= nil and active_record ~= state.public_record then
			return nil, "conflict", "bound V2 mailbox is attached to a different Record instance"
		end
	end
	return mailbox, nil, nil
end

local function map_v2_result_code(code: unknown): ResultCode
	if code == "success" then return "success" end
	if code == "accepted" then return "enqueued" end
	if code == "processed" or code == "dead_lettered" then return "processed" end
	if code == "duplicate" then return "duplicate" end
	if code == "capacity" then return "capacity" end
	if code == "empty" then return "empty" end
	if code == "busy" or code == "preparing" then return "busy" end
	if code == "closing" then return "closing" end
	if code == "fenced" then return "fenced" end
	if code == "conflict" then return "conflict" end
	if code == "corrupt" then return "corrupt" end
	if code == "invalid" then return "invalid" end
	if code == "not_found" then return "not_found" end
	if code == "retryable" then return "budget" end
	if code == "discarded" then return "success" end
	return "unknown"
end

local function v2_result_message(result: any, fallback: string): string
	if type(result) == "table" and type(result.error) == "string" and result.error ~= "" then
		return result.error
	end
	if type(result) == "table" and type(result.message) == "table" and type(result.message.LastError) == "string" then
		return result.message.LastError
	end
	return fallback
end

local function bind_mailbox_v2(self: Record, mailbox: unknown): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.state ~= "active" then return "fenced", "V2 mailbox binding requires an active Record" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if state.mailbox_v2 ~= nil and state.mailbox_v2 ~= mailbox then
		return "conflict", "this Record is already bound to a different V2 mailbox"
	end
	if type(mailbox) ~= "table" or type((mailbox :: any).GetOwner) ~= "function"
		or type((mailbox :: any).EnqueueAsync) ~= "function"
	then
		return "invalid", "mailbox must expose GetOwner and EnqueueAsync"
	end
	local ok, owner = pcall(function() return (mailbox :: any):GetOwner() end)
	if not ok or type(owner) ~= "table" then return "invalid", "mailbox owner identity could not be read" end
	if type((mailbox :: any).GetActiveRecord) ~= "function" then
		return "invalid", "V2 mailbox must expose GetActiveRecord and bind processing to this Record"
	end
	local active_ok, active_record = pcall(function() return (mailbox :: any):GetActiveRecord() end)
	if not active_ok then return "invalid", "mailbox active Record binding could not be inspected" end
	if active_record ~= self then
		return "conflict", "V2 mailbox must be bound to this exact active Record instance"
	end
	local owner_fields = owner :: { [string]: unknown }
	if owner_fields.store_name ~= state.name or owner_fields.scope ~= state.scope or owner_fields.profile_key ~= state.key then
		return "conflict", "mailbox owner does not match this Record identity"
	end
	if #state.user_ids > 0 and owner_fields.user_id == nil then
		return "invalid", "mailbox owner must include a UserId for a UserId-associated Record"
	end
	if owner_fields.user_id ~= nil then
		if type(owner_fields.user_id) ~= "number" or not math.isfinite(owner_fields.user_id)
			or math.floor(owner_fields.user_id) ~= owner_fields.user_id
		then
			return "invalid", "mailbox owner UserId must be a finite integer"
		end
		local found = false
		for _, user_id in ipairs(state.user_ids) do if user_id == owner_fields.user_id then found = true; break end end
		if not found then return "fenced", "mailbox UserId does not match the Record's persisted UserIds" end
	end
	state.mailbox_v2 = mailbox
	return "success", nil
end

local function enqueue(self: Record, message_type: string, data: JsonValue?, enqueue_options: { [string]: unknown }?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.mailbox_v2_binding then return "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.state ~= "active" then return "fenced", "record is not actively owned" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
		if mailbox == nil then return bound_code or "fenced", bound_message end
		local call_ok, result = pcall(function()
			return mailbox:EnqueueAsync(message_type, data, enqueue_options)
		end)
		if not call_ok then
			local error_message = tostring(result)
			observe(state, "v2_enqueue", "unknown", error_message)
			return "unknown", error_message
		end
		if type(result) ~= "table" then return "unknown", "V2 mailbox returned no structured result" end
		if result.code == "accepted" then observe(state, "v2_enqueue", "success", message_type); return "enqueued", nil end
		if result.code == "duplicate" then observe(state, "v2_enqueue", "duplicate", message_type); return "duplicate", nil end
		if result.code == "capacity" then return "capacity", v2_result_message(result, "V2 mailbox capacity was reached") end
		if result.code == "conflict" then return "conflict", v2_result_message(result, "V2 idempotency conflict") end
		if result.code == "invalid" then return "invalid", v2_result_message(result, "V2 enqueue options are invalid") end
		if result.code == "corrupt" then return "corrupt", v2_result_message(result, "V2 mailbox record is corrupt") end
		if result.code == "not_found" then return "not_found", v2_result_message(result, "V2 message was not found") end
		if result.code == "fenced" then return "fenced", v2_result_message(result, "V2 operation was fenced") end
		if result.code == "busy" or result.code == "preparing" or result.code == "retry_scheduled" then
			return "busy", v2_result_message(result, "V2 mailbox operation is still in progress")
		end
		if result.code == "retryable" then return "budget", v2_result_message(result, "V2 mailbox request was throttled") end
		if result.code == "unknown" then return "unknown", v2_result_message(result, "V2 mailbox outcome is unknown") end
		return "unknown", "unmapped V2 mailbox result: " .. tostring(result.code)
	end
	if enqueue_options ~= nil then
		return "invalid", "enqueue_options require an explicitly bound V2 mailbox"
	end
	return enqueue_internal(state, message_type, data)
end

local function process_queue(self: Record, max_messages: number?): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.mailbox_v2_binding then return "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 == nil then return process_queue_internal(state, max_messages or 1) end
	local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
	if mailbox == nil then return bound_code or "fenced", bound_message end
	if state.state ~= "active" then return "fenced", "record is not actively owned" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if state.queue_busy or state.busy then return "busy", "record already has a durable operation in flight" end
	local handler = state.options.on_queue_message
	if handler == nil then return "invalid", "on_queue_message is not configured" end
	local limit = max_messages or 1
	if type(limit) ~= "number" or not math.isfinite(limit) or limit < 1 or math.floor(limit) ~= limit then
		return "invalid", "max_messages must be a positive integer"
	end
	limit = math.min(limit, state.options.queue_max_messages or DEFAULT_QUEUE_MAX_MESSAGES)
	state.queue_busy = true
	local call_ok, result_code, result_message = pcall(function()
		local processed = 0
		for _ = 1, limit do
			local handler_failure_code: ResultCode? = nil
			local handler_failure_message: string? = nil
			local function dispatch_v2(payload: unknown, message_value: unknown): (boolean, string?)
				if type(message_value) ~= "table" then
					handler_failure_code = "corrupt"
					handler_failure_message = "V2 mailbox returned a malformed message snapshot"
					return false, handler_failure_message
				end
				local message = message_value :: { [string]: unknown }
				if type(message.Type) ~= "string" or type(message.Id) ~= "string"
					or type(message.Attempts) ~= "number" or type(message.CreatedAt) ~= "number"
				then
					handler_failure_code = "corrupt"
					handler_failure_message = "V2 mailbox message omitted required handler fields"
					return false, handler_failure_message
				end
				local handler_completed = false
				local handler_handled = false
				local callback_error: string? = nil
				local callback_message: string? = nil
				local handler_thread = coroutine.create(function()
					local callback_ok, callback_result, callback_result_message = pcall(
						handler,
						message.Type :: string,
						copy_value(payload :: JsonValue?),
						message.Attempts :: number,
						message.Id :: string,
						(if type(message.SenderJobId) == "string" then message.SenderJobId else ""),
						message.CreatedAt :: number
					)
					if not callback_ok then
						callback_error = tostring(callback_result)
						return
					end
					handler_completed = true
					handler_handled = callback_result == true
					if type(callback_result_message) == "string" then callback_message = callback_result_message end
				end)
				local resumed, resume_error = coroutine.resume(handler_thread)
				if coroutine.status(handler_thread) ~= "dead" then
					coroutine.close(handler_thread)
					handler_failure_code = "invalid"
					handler_failure_message = "queue handler must not yield"
					return false, handler_failure_message
				end
				if not resumed or callback_error ~= nil then
					handler_failure_code = "invalid"
					handler_failure_message = "queue handler threw: " .. (callback_error or tostring(resume_error or "execution failed"))
					return false, handler_failure_message
				end
				if not handler_completed or not handler_handled then
					handler_failure_code = "unknown"
					handler_failure_message = callback_message or "queue handler rejected the message"
					return false, handler_failure_message
				end
				return true, nil
			end
			local mailbox_call_ok, result = pcall(function()
				return mailbox:ProcessNextAsync(dispatch_v2)
			end)
			if not mailbox_call_ok then return "unknown" :: ResultCode, tostring(result) end
			if type(result) ~= "table" or type(result.code) ~= "string" then
				return "unknown" :: ResultCode, "V2 mailbox returned no structured processing result"
			end
			if result.code == "empty" then break end
			if result.code == "processed" or result.code == "duplicate" or result.code == "dead_lettered" then
				processed += 1
				continue
			end
			if result.code == "retry_scheduled" then
				return handler_failure_code or "unknown", handler_failure_message or v2_result_message(result, "V2 queue handler failed and the message was rescheduled")
			end
			return map_v2_result_code(result.code), v2_result_message(result, "V2 queue processing returned " .. result.code)
		end
		if processed == 0 then return "empty" :: ResultCode, nil end
		return "processed" :: ResultCode, tostring(processed)
	end)
	state.queue_busy = false
	if not call_ok then return "unknown", tostring(result_code) end
	return result_code :: ResultCode, result_message
end

local function get_queue(self: Record): ({ QueueMessage }, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return {}, "invalid", "record does not exist"
	end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
		if mailbox == nil then return {}, bound_code or "fenced", bound_message end
		local call_ok, rows, result = pcall(function()
			return mailbox:GetQueueAsync()
		end)
		if not call_ok then return {}, "unknown", tostring(rows) end
		if type(rows) ~= "table" or type(result) ~= "table" or type(result.code) ~= "string" then
			return {}, "unknown", "V2 mailbox returned no structured queue result"
		end
		if result.code ~= "success" then
			return {}, map_v2_result_code(result.code), v2_result_message(result, "V2 queue read failed")
		end
		local projected: { QueueMessage } = {}
		for _, row_value in ipairs(rows) do
			if type(row_value) ~= "table" or type(row_value.Id) ~= "string" or type(row_value.Type) ~= "string"
				or type(row_value.Attempts) ~= "number" or type(row_value.TotalAttempts) ~= "number"
				or type(row_value.ReplayCount) ~= "number" or type(row_value.CreatedAt) ~= "number"
			then
				return {}, "corrupt", "V2 queue contained a malformed public message snapshot"
			end
			projected[#projected + 1] = {
				Id = row_value.Id,
				Type = row_value.Type,
				Data = copy_value(row_value.Data :: JsonValue?),
				Attempts = row_value.Attempts,
				TotalAttempts = row_value.TotalAttempts,
				ReplayCount = row_value.ReplayCount,
				SenderJobId = if type(row_value.SenderJobId) == "string" then row_value.SenderJobId else "",
				CreatedAt = row_value.CreatedAt,
			}
		end
		return projected, "success", nil
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


local function bind_mailbox_v2_async(self: Record, mailbox: unknown): (ResultCode, string?)
	local state = private[self]
	if state == nil then return "invalid", "record does not exist" end
	if state.state ~= "active" then return "fenced", "V2 mailbox binding requires an active Record" end
	if state.takeover_requested then return "closing", "session takeover has been requested" end
	if state.mailbox_v2 ~= nil then return bind_mailbox_v2(self, mailbox) end
	if type(mailbox) ~= "table"
		or type((mailbox :: any).GetOwner) ~= "function"
		or type((mailbox :: any).GetActiveRecord) ~= "function"
		or type((mailbox :: any).EnqueueAsync) ~= "function"
	then
		return "invalid", "mailbox must expose GetOwner, GetActiveRecord and EnqueueAsync"
	end
	local active_ok, active_record = pcall(function() return (mailbox :: any):GetActiveRecord() end)
	if not active_ok then return "invalid", "mailbox active Record binding could not be inspected" end
	if active_record ~= self then
		return "conflict", "V2 mailbox must be bound to this exact active Record instance"
	end
	if state.mailbox_v2_binding or state.queue_busy or state.busy then
		return "busy", "Record has another operation in flight; V2 mailbox binding was not attempted"
	end
	if state.options.durable_queue_enabled == false then
		return "invalid", "safe V2 binding requires the legacy queue to be enabled so pending messages can be checked"
	end
	state.mailbox_v2_binding = true
	state.queue_busy = true
	local call_ok, legacy_queue, queue_code, queue_message = pcall(function()
		return get_queue(self)
	end)
	state.queue_busy = false
	state.mailbox_v2_binding = false
	if not call_ok then return "unknown", "could not inspect the legacy queue before V2 binding: " .. tostring(legacy_queue) end
	if queue_code ~= "success" then
		return queue_code or "unknown", queue_message or "could not verify the legacy queue before V2 binding"
	end
	if #legacy_queue > 0 then
		return "busy", "legacy queue contains pending messages; drain it before binding the V2 mailbox"
	end
	return bind_mailbox_v2(self, mailbox)
end

local function get_dead_letters(self: Record): ({ DeadLetterMessage }, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return {}, "invalid", "record does not exist"
	end
	if state.mailbox_v2_binding then return {}, "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
		if mailbox == nil then return {}, bound_code or "fenced", bound_message end
		local result_rows: { DeadLetterMessage } = {}
		local cursor: string? = nil
		local page_count = 0
		while page_count < 10 do
			local call_ok, page, next_cursor, result = pcall(function()
				return mailbox:GetDeadLettersAsync(cursor, 100)
			end)
			if not call_ok then return {}, "unknown", tostring(page) end
			if type(page) ~= "table" or type(result) ~= "table" or type(result.code) ~= "string" then
				return {}, "unknown", "V2 mailbox returned no structured dead-letter result"
			end
			if result.code ~= "success" then
				return {}, map_v2_result_code(result.code), v2_result_message(result, "V2 dead-letter read failed")
			end
			for _, row_value in ipairs(page) do
				if type(row_value) ~= "table" or type(row_value.Id) ~= "string" or type(row_value.Type) ~= "string"
					or type(row_value.Attempts) ~= "number" or type(row_value.TotalAttempts) ~= "number"
					or type(row_value.ReplayCount) ~= "number" or type(row_value.CreatedAt) ~= "number"
				then
					return {}, "corrupt", "V2 dead-letter list contained a malformed public message snapshot"
				end
				result_rows[#result_rows + 1] = {
					Id = row_value.Id,
					Type = row_value.Type,
					Data = copy_value(row_value.Data :: JsonValue?),
					Attempts = row_value.Attempts,
					TotalAttempts = row_value.TotalAttempts,
					ReplayCount = row_value.ReplayCount,
					SenderJobId = if type(row_value.SenderJobId) == "string" then row_value.SenderJobId else "",
					CreatedAt = row_value.CreatedAt,
					DeadLetteredAt = if type(row_value.DeadLetteredAt) == "number" then row_value.DeadLetteredAt else row_value.CreatedAt,
					LastError = if type(row_value.LastError) == "string" then row_value.LastError else "",
					LockToken = nil,
					LockedUntil = nil,
				}
			end
			page_count += 1
			if next_cursor == nil then return result_rows, "success", nil end
			if type(next_cursor) ~= "string" then return {}, "corrupt", "V2 dead-letter cursor was malformed" end
			cursor = next_cursor
		end
		return {}, "capacity", "V2 dead-letter projection exceeded 1000 entries; use the V2 cursor API for bounded pagination"
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
	if state.mailbox_v2_binding then return nil, "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
		if mailbox == nil then return nil, bound_code or "fenced", bound_message end
		return nil, "invalid", "V2 dead-letter claims use generation-aware V2 APIs; use MailboxV2 directly"
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
	if state.mailbox_v2_binding then return "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
		if mailbox == nil then return bound_code or "fenced", bound_message end
		return "invalid", "V2 replay requires a stable operation_id; use MailboxV2.ReplayDeadLetterAsync"
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
	if state.mailbox_v2_binding then return "busy", "V2 mailbox binding is checking the legacy queue" end
	if state.mailbox_v2 ~= nil then
		local mailbox, bound_code, bound_message = bound_mailbox_for_state(state)
		if mailbox == nil then return bound_code or "fenced", bound_message end
		return "invalid", "V2 discard requires expected_replay_count; use MailboxV2.DiscardDeadLetterAsync"
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
	evaluate_durability_risk(self, state)
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
			for _, event in envelope.outbox or {} do
				if event.state == "pending" then
					decision = "conflict"
					decision_message = "record cannot be deleted while a durable outbox event is pending"
					return nil, nil, nil
				end
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
				inbox_receipts = envelope.inbox_receipts or {},
				outbox = envelope.outbox or {},
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
	mark_saved(state, state.change_sequence)
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
				inbox_receipts = {},
				outbox = {},
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
				if type(raw) == "table" and (get_string_field(raw, "inbox_receipts") ~= nil or get_string_field(raw, "outbox") ~= nil) then
					decision = "corrupt"
					decision_message = "automatic recovery is blocked because the current envelope contains transaction sidecars that could not be validated"
					return nil, nil, nil
				end
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
				inbox_receipts = if envelope ~= nil then envelope.inbox_receipts or {} else {},
				outbox = if envelope ~= nil then envelope.outbox or {} else {},
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
		state.dirty_since_unix = 0
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
				inbox_receipts = envelope.inbox_receipts or {},
				outbox = envelope.outbox or {},
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
				inbox_receipts = envelope.inbox_receipts or {},
				outbox = envelope.outbox or {},
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
	mark_saved(state, state.change_sequence)
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

complete_deferred_takeover = function(state: InternalState)
	if not state.takeover_requested or state.busy or state.state ~= "active" then
		return
	end
	task.spawn(function()
		if state.retired then
			return
		end
		local request_id = state.takeover_request_id
		local requester_job_id = state.takeover_requester_job_id
		local result = close_internal(state, false)
		if request_id ~= nil and requester_job_id ~= nil then
			local status: HandoffStatus = if result == "closed" then "released" else "failed"
			cache_takeover_status(state, request_id, status)
			publish_handoff_ack(state, request_id, requester_job_id, state.generation, state.token or "", status)
		end
		state.takeover_request_id = nil
		state.takeover_requester_job_id = nil
		state.takeover_requested = false
	end)
end

local function save(self: Record, reason: string?): (ResultCode, string?)
	local state = private[self]
	if state == nil then
		return "invalid", "record does not exist"
	end
	local result, message = save_internal(state, reason or "manual", nil, nil)
	evaluate_durability_risk(self, state)
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
		dirty_since_unix = state.dirty_since_unix,
		dirty_age_seconds = if state.change_sequence ~= state.saved_change_sequence and state.dirty_since_unix > 0 then math.max(0, session_now_unix(state.backend.mock) - state.dirty_since_unix) else 0,
		dirty = if state.change_sequence ~= state.saved_change_sequence then 1 else 0,
		durability_risk_active = if state.durability_risk_active then 1 else 0,
		durability_risk_reason = state.durability_risk_reason,
		durability_risk_observer_errors = state.durability_risk_observer_errors,
	}
end


local function durability_status_for_state(state: InternalState): DurabilityStatus
	local observed_at = session_now_unix(state.backend.mock)
	local dirty = state.change_sequence ~= state.saved_change_sequence
	local dirty_since = state.dirty_since_unix
	local age_available = not dirty or (type(dirty_since) == "number" and dirty_since > 0)
	local dirty_age = if not dirty then 0 else if age_available then math.max(0, observed_at - dirty_since) else nil
	local dirty_age_exceeded = if not dirty then false else if dirty_age ~= nil then dirty_age > runtime_options.max_dirty_age_seconds else nil
	local last_error = state.last_error_info
	local uncertain = state.state == "unknown"
		or (last_error ~= nil and last_error.DurableOutcome == "unknown" and state.last_result == "unknown")
	return {
		state = state.state,
		dirty = dirty,
		dirty_generation = state.change_sequence,
		durable_generation = state.saved_change_sequence,
		known_revision = state.revision,
		last_confirmed_durable_revision = if state.last_saved ~= nil then state.last_saved.Revision else 0,
		dirty_age_seconds = dirty_age,
		dirty_age_available = age_available,
		dirty_age_exceeded = dirty_age_exceeded,
		age_basis = if not dirty then "clean" else if age_available then "tracked_dirty_generation" else "unavailable",
		max_dirty_age_seconds = runtime_options.max_dirty_age_seconds,
		last_confirmed_save_unix = if state.last_saved ~= nil then state.last_saved.ConfirmedAt else 0,
		write_outcome_uncertain = uncertain,
		retry_category = if last_error ~= nil then last_error.Code else state.last_result,
		in_flight_operations = (if state.busy then 1 else 0) + (if state.queue_busy then 1 else 0),
		durability_risk_active = state.durability_risk_active,
		durability_risk_reason = state.durability_risk_reason,
		observed_at_unix = observed_at,
	}
end

local function dispatch_durability_risk(state: InternalState, transition: "entered" | "changed" | "recovered", reason: "dirty_age_exceeded" | "write_outcome_uncertain" | "recovered")
	if next(state.durability_risk_observers) == nil then return end
	local status = durability_status_for_state(state)
	local event: DurabilityRiskEvent = {
		Transition = transition,
		Reason = reason,
		State = state.state,
		Dirty = status.dirty,
		DirtyGeneration = state.change_sequence,
		DurableGeneration = state.saved_change_sequence,
		KnownRevision = state.revision,
		LastConfirmedDurableRevision = status.last_confirmed_durable_revision,
		DirtyAgeSeconds = status.dirty_age_seconds,
		MaxDirtyAgeSeconds = status.max_dirty_age_seconds,
		LastConfirmedSaveUnix = status.last_confirmed_save_unix,
		WriteOutcomeUncertain = status.write_outcome_uncertain,
		ObservedAtUnix = status.observed_at_unix,
	}
	local observers: { DurabilityRiskObserver } = {}
	for _, observer in pairs(state.durability_risk_observers) do table.insert(observers, observer) end
	task.spawn(function()
		for _, observer in ipairs(observers) do
			local ok = pcall(observer, event)
			if not ok then state.durability_risk_observer_errors += 1 end
		end
	end)
end

local function evaluate_durability_risk(_record: Record, state: InternalState)
	local status = durability_status_for_state(state)
	local next_reason: ("dirty_age_exceeded" | "write_outcome_uncertain")? = nil
	if status.write_outcome_uncertain then
		next_reason = "write_outcome_uncertain"
	elseif status.dirty_age_exceeded == true then
		next_reason = "dirty_age_exceeded"
	end
	if next_reason == nil then
		if state.durability_risk_active then
			state.durability_risk_active = false
			state.durability_risk_reason = nil
			dispatch_durability_risk(state, "recovered", "recovered")
		end
		return
	end
	if not state.durability_risk_active then
		state.durability_risk_active = true
		state.durability_risk_reason = next_reason
		dispatch_durability_risk(state, "entered", next_reason)
	elseif state.durability_risk_reason ~= next_reason then
		state.durability_risk_reason = next_reason
		dispatch_durability_risk(state, "changed", next_reason)
	end
end

local function get_durability_status(self: Record): (DurabilityStatus?, ResultCode, string?)
	local state = private[self]
	if state == nil then return nil, "invalid", "record does not exist" end
	track_external_data_mutation(state)
	evaluate_durability_risk(self, state)
	return durability_status_for_state(state), "success", nil
end

local function subscribe_durability_risk(self: Record, observer: DurabilityRiskObserver): (ChangeSubscription?, ResultCode, string?)
	local state = private[self]
	if state == nil then return nil, "invalid", "record does not exist" end
	if type(observer) ~= "function" then return nil, "invalid", "durability-risk observer must be a function" end
	local count = 0
	for _ in pairs(state.durability_risk_observers) do count += 1 end
	if count >= DURABILITY_RISK_OBSERVER_CAPACITY then
		return nil, "capacity", "durability-risk observer capacity reached"
	end
	local id = state.durability_risk_observer_next_id
	state.durability_risk_observer_next_id += 1
	state.durability_risk_observers[id] = observer
	local connected = true
	local subscription: ChangeSubscription = {
		Disconnect = function(_: ChangeSubscription)
			if not connected then return end
			connected = false
			state.durability_risk_observers[id] = nil
		end,
	}
	evaluate_durability_risk(self, state)
	return subscription, "success", nil
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


local function wait_for_session_async(self: Record, default_data: JsonValue?, wait_options: SessionWaitOptions?): (SessionWaitResult, ResultCode, string?)
	local state = private[self]
	if state == nil then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "record does not exist",
		}, "invalid", "record does not exist"
	end
	if wait_options ~= nil and type(wait_options) ~= "table" then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "wait_options must be a table",
		}, "invalid", "wait_options must be a table"
	end
	local options = wait_options or {}
	local max_wait = if options.max_wait_seconds == nil then DEFAULT_OPERATION_DEADLINE else options.max_wait_seconds
	local max_attempts = if options.max_attempts == nil then 8 else options.max_attempts
	local retry_interval = if options.retry_interval_seconds == nil then MIN_RETRY_DELAY else options.retry_interval_seconds
	local max_retry_interval = if options.max_retry_interval_seconds == nil then MAX_RETRY_DELAY else options.max_retry_interval_seconds
	if type(max_wait) ~= "number" or not math.isfinite(max_wait) or max_wait <= 0 or max_wait > 1200 then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "max_wait_seconds must be between 0 and 1200",
		}, "invalid", "max_wait_seconds must be between 0 and 1200"
	end
	if type(max_attempts) ~= "number" or not math.isfinite(max_attempts) or math.floor(max_attempts) ~= max_attempts or max_attempts < 1 or max_attempts > 32 then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "max_attempts must be an integer from 1 to 32",
		}, "invalid", "max_attempts must be an integer from 1 to 32"
	end
	if type(retry_interval) ~= "number" or not math.isfinite(retry_interval) or retry_interval <= 0 or retry_interval > 30
		or type(max_retry_interval) ~= "number" or not math.isfinite(max_retry_interval) or max_retry_interval < retry_interval or max_retry_interval > 30
	then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "retry intervals must be positive, ordered and at most 30 seconds",
		}, "invalid", "retry intervals must be positive, ordered and at most 30 seconds"
	end
	if options.cancelled ~= nil and type(options.cancelled) ~= "function" then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "cancelled must be a function",
		}, "invalid", "cancelled must be a function"
	end
	if options.on_status ~= nil and type(options.on_status) ~= "function" then
		return {
			Outcome = "session_status_unavailable", Attempt = 0, ObservedAtUnix = now_unix(),
			SessionJobId = nil, LeaseUntilUnix = nil, RetryAfterSeconds = nil, RetryScheduled = false,
			ReadResult = "invalid", Message = "on_status must be a function",
		}, "invalid", "on_status must be a function"
	end

	local deadline = now_local() + max_wait
	local last_outcome: SessionWaitOutcome = "no_known_competing_session"
	local last_job_id: string? = nil
	local last_lease_until: number? = nil
	local last_code: ResultCode? = nil
	local last_message: string? = nil

	local function make_result(
		outcome: SessionWaitOutcome,
		attempt: number,
		job_id: string?,
		lease_until: number?,
		retry_after: number?,
		retry_scheduled: boolean,
		read_result: ResultCode?,
		message: string?
	): SessionWaitResult
		return {
			Outcome = outcome,
			Attempt = attempt,
			ObservedAtUnix = session_now_unix(state.backend.mock),
			SessionJobId = job_id,
			LeaseUntilUnix = lease_until,
			RetryAfterSeconds = retry_after,
			RetryScheduled = retry_scheduled,
			ReadResult = read_result,
			Message = message,
		}
	end

	local function report(
		outcome: SessionWaitOutcome,
		attempt: number,
		job_id: string?,
		lease_until: number?,
		retry_after: number?,
		retry_scheduled: boolean,
		read_result: ResultCode?,
		message: string?
	): SessionWaitResult
		local result = make_result(outcome, attempt, job_id, lease_until, retry_after, retry_scheduled, read_result, message)
		if options.on_status ~= nil then pcall(options.on_status, result) end
		return result
	end

	local function cancellation_requested(): (boolean, string?)
		if state.takeover_requested then return true, nil end
		if options.cancelled == nil then return false, nil end
		local ok, value = pcall(options.cancelled)
		if not ok then return false, "cancellation callback failed: " .. tostring(value) end
		return value == true, nil
	end

	local function observe_competitor(attempt: number): (SessionWaitOutcome, string?, number?, ResultCode?, string?)
		local raw, _, read_code, read_message = backend_get(state.backend, false, deadline, state)
		if read_code ~= nil then
			return "session_status_unavailable", nil, nil, read_code, read_message
		end
		if raw == nil then
			return "no_known_competing_session", nil, nil, nil, nil
		end
		local envelope, parse_error, current_format = parse_envelope(raw)
		if not current_format then
			local code: ResultCode = if parse_error == "future implementation version" then "future_schema" elseif parse_error == "legacy payload" then "legacy" else "corrupt"
			return "session_status_unavailable", nil, nil, code, parse_error or "stored record envelope is invalid"
		end
		if envelope == nil then
			return "session_status_unavailable", nil, nil, "corrupt", parse_error or "stored record envelope is missing"
		end
		if envelope.tombstone ~= nil then
			return "ownership_fenced_or_lost", nil, nil, "tombstoned", "record is tombstoned"
		end
		local session = envelope.session
		if session == nil or session.lease_until <= session_now_unix(state.backend.mock) then
			return "no_known_competing_session", nil, nil, nil, nil
		end
		if state.state == "active" and state.token == session.token
			and state.generation == session.generation and session.job_id == server_id
		then
			return "ownership_acquired", session.job_id, session.lease_until, nil, nil
		end
		return "competing_session_observed", session.job_id, session.lease_until, "locked", "a live session lease was observed; this read does not authorize ownership"
	end

	for attempt = 1, max_attempts do
		local cancelled, cancellation_error = cancellation_requested()
		if cancellation_error ~= nil then
			local result = report("session_status_unavailable", attempt, last_job_id, last_lease_until, nil, false, "invalid", cancellation_error)
			return result, "invalid", cancellation_error
		end
		if cancelled then
			local result = report("cancellation_requested", attempt, last_job_id, last_lease_until, nil, false, "closing", "session wait was cancelled or takeover was requested")
			return result, "closing", result.Message
		end
		if now_local() >= deadline then break end
		if state.state == "active" and state.token ~= nil then
			if state.durable_lease_until > session_now_unix(state.backend.mock) then
				local result = report("ownership_acquired", attempt, server_id, state.durable_lease_until, nil, false, "success", nil)
				return result, "success", nil
			end
			if not state.busy then
				local result = report("ownership_fenced_or_lost", attempt, server_id, state.durable_lease_until, nil, false, "fenced", "the last confirmed local lease has expired")
				return result, "fenced", result.Message
			end
		end
		if state.state == "fenced" or state.state == "tombstoned" then
			local code: ResultCode = if state.state == "tombstoned" then "tombstoned" else "fenced"
			local result = report("ownership_fenced_or_lost", attempt, nil, nil, nil, false, code, "local Record is not eligible to acquire ownership")
			return result, code, result.Message
		end
		if state.state == "unknown" then
			local result = report("session_status_unavailable", attempt, nil, nil, nil, false, "unknown", "prior open/save outcome is unresolved; do not blindly retry acquisition")
			return result, "unknown", result.Message
		end

		local open_code: ResultCode
		local open_message: string?
		if state.busy or state.queue_busy then
			open_code, open_message = "busy", "another Record operation is in flight"
		else
			open_code, open_message = open(self, default_data, options.recreate)
		end
		last_code, last_message = open_code, open_message
		if open_code == "created" or open_code == "loaded" or open_code == "already_open" then
			if state.state == "active" and state.token ~= nil and state.durable_lease_until > session_now_unix(state.backend.mock) then
				local result = report("ownership_acquired", attempt, server_id, state.durable_lease_until, nil, false, "success", nil)
				return result, "success", nil
			end
			local result = report("session_status_unavailable", attempt, nil, nil, nil, false, "unknown", "Open reported success without a confirmed live local lease")
			return result, "unknown", result.Message
		end
		if open_code == "fenced" or open_code == "tombstoned" then
			local outcome: SessionWaitOutcome = "ownership_fenced_or_lost"
			local result = report(outcome, attempt, nil, nil, nil, false, open_code, open_message)
			return result, open_code, open_message
		end
		if open_code == "unknown" or open_code == "retry_exhausted" then
			local result = report("session_status_unavailable", attempt, nil, nil, nil, false, open_code, open_message)
			return result, open_code, open_message
		end

		local can_retry = open_code == "locked" or open_code == "busy" or open_code == "budget" or is_retryable_result(open_code, "open")
		if not can_retry then
			local result = report("session_status_unavailable", attempt, nil, nil, nil, false, open_code, open_message)
			return result, open_code, open_message
		end
		local observed_outcome: SessionWaitOutcome
		local observed_job_id: string? = nil
		local observed_lease_until: number? = nil
		local observed_code: ResultCode? = nil
		local observed_message: string? = nil
		observed_outcome, observed_job_id, observed_lease_until, observed_code, observed_message = observe_competitor(attempt)
		if observed_outcome == "ownership_acquired" then
			local result = report("ownership_acquired", attempt, observed_job_id, observed_lease_until, nil, false, "success", nil)
			return result, "success", nil
		end
		if observed_outcome == "ownership_fenced_or_lost" then
			local result = report(observed_outcome, attempt, nil, nil, nil, false, observed_code, observed_message)
			return result, observed_code or "tombstoned", observed_message
		end
		if observed_outcome == "session_status_unavailable" then
			local result = report(observed_outcome, attempt, nil, nil, nil, false, observed_code, observed_message)
			return result, observed_code or "unknown", observed_message
		end
		last_outcome, last_job_id, last_lease_until = observed_outcome, observed_job_id, observed_lease_until
		last_code = if observed_outcome == "competing_session_observed" then "locked" else "retry_exhausted"
		last_message = if observed_outcome == "competing_session_observed" then observed_message else "no competing live session was observed; acquisition will be retried"
		if observed_outcome == "competing_session_observed" then
			report(observed_outcome, attempt, observed_job_id, observed_lease_until, nil, false, "locked", observed_message)
		end
		local remaining = math.max(0, deadline - now_local())
		if attempt >= max_attempts or remaining <= 0 then break end
		local backoff = math.min(max_retry_interval, retry_interval * (2 ^ math.min(attempt - 1, 8)))
		if observed_lease_until ~= nil then
			local lease_remaining = math.max(0, observed_lease_until - session_now_unix(state.backend.mock))
			if lease_remaining > 0 then backoff = math.min(backoff, math.max(retry_interval, lease_remaining)) end
		end
		local delay = math.min(backoff, remaining)
		report("wait_retry_scheduled", attempt, observed_job_id, observed_lease_until, delay, true, observed_code, observed_message)
		task.wait(delay)
	end
	local timed_out_code: ResultCode = if now_local() >= deadline then "budget" else (last_code or "retry_exhausted")
	local timed_out_message = if now_local() >= deadline then "session wait deadline expired" else (last_message or "session wait attempt limit reached")
	local final_outcome: SessionWaitOutcome = if last_outcome == "competing_session_observed" then "competing_session_observed" else "no_known_competing_session"
	local result = report(final_outcome, max_attempts, last_job_id, last_lease_until, nil, false, timed_out_code, timed_out_message)
	return result, timed_out_code, timed_out_message
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
		durability_risk_observers = {},
		durability_risk_observer_next_id = 1,
		durability_risk_observer_errors = 0,
		durability_risk_active = false,
		durability_risk_reason = nil,
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
		mailbox_v2_binding = false,
		save_requested = false,
		shutdown = false,
		retired = false,
		takeover_requested = false,
		queue_hint = false,
		mailbox_v2 = nil,
		message_topic = make_message_topic(options.message_topic_prefix or DEFAULT_MESSAGE_TOPIC_PREFIX, name, scope, key),
		message_subscription = nil,
		last_error = nil,
		last_result = nil,
		last_observed = now_unix(),
		observer_errors = 0,
		last_saved = nil,
		change_sequence = 0,
		saved_change_sequence = 0,
		dirty_since_unix = 0,
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
		GetIdentity = get_identity,
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
		GetDurabilityStatus = get_durability_status,
		SubscribeDurabilityRisk = subscribe_durability_risk,
		WaitForSessionAsync = wait_for_session_async,
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
		TransactAsync = transaction,
		ApplyInboxAsync = apply_inbox,
		CommitWithOutboxAsync = commit_with_outbox,
		GetOutboxAsync = get_outbox,
		DispatchOutboxAsync = dispatch_outbox,
		DispatchOutboxBatchAsync = dispatch_outbox_batch,
		PruneTransactionReceiptsAsync = prune_transaction_receipts,
		PruneOutboxAsync = prune_outbox,
		MessageAsync = message,
		BindMailboxV2Async = bind_mailbox_v2_async,
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

local function start_scheduler()
	if scheduler_started then
		return
	end
	scheduler_started = true
	task.spawn(function()
		while not closing do
			local scheduler_now = now_local()
			refresh_runtime_policy(scheduler_now)
			if scheduler_now >= runtime_next_budget_sample then
				request_budget(Enum.DataStoreRequestType.StandardRead)
				request_budget(Enum.DataStoreRequestType.StandardWrite)
				runtime_next_budget_sample = scheduler_now + runtime_options.adaptive_sample_interval
			end
			for record in active_records do
				local state = private[record]
				if state ~= nil then
					evaluate_durability_risk(record, state)
					if state.state == "active" then
					local handled_takeover = false
					if state.takeover_requested and not state.busy and not state.queue_busy then
						complete_deferred_takeover(state)
						sync_public(record)
						handled_takeover = true
					end
					local now = now_local()
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
					then
						subscribe_record(state)
					end
					if state.state == "active"
						and state.options.durable_queue_enabled ~= false
						and state.options.on_queue_message ~= nil
						and not state.queue_busy
						and (state.queue_hint or now >= state.next_queue_poll)
					then
						state.queue_hint = false
						state.next_queue_poll = now + effective_queue_poll_interval(state.options.queue_poll_interval or DEFAULT_QUEUE_POLL_INTERVAL)
						task.spawn(function()
							process_queue_internal(state, 4)
							sync_public(record)
						end)
					end
					end
				end
			end
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


local function runtime_class_limit(work_class: string): number
	local maximum = runtime_effective_concurrent_requests
	local foreground_limit = math.max(1, maximum - runtime_options.critical_request_reserve)
	if work_class == "interactive" then return foreground_limit end
	if work_class == "messaging" then
		local desired = math.max(1, math.floor(maximum * runtime_options.adaptive_queue_budget_share * 8))
		return math.min(foreground_limit, desired)
	end
	if work_class == "migration" then return math.max(1, math.floor(maximum * 0.25)) end
	if work_class == "maintenance" or work_class == "tracing" then return 1 end
	return foreground_limit
end

function RecordStore.configure_runtime(config: RuntimeOptions): (ResultCode, string?)
	if type(config) ~= "table" then return "invalid", "runtime config must be a table" end
	if scheduler_started or next(records) ~= nil then
		return "busy", "configure_runtime must be called before the first RecordStore record is created"
	end
	local policy_patch: { [string]: unknown } = {}
	local provider: (() -> { [string]: unknown })? = nil
	for key, value in pairs(config :: { [string]: unknown }) do
		if key == "runtime_policy_provider" then
			if value ~= nil and type(value) ~= "function" then return "invalid", "runtime_policy_provider must be a function" end
			provider = value :: (() -> { [string]: unknown })?
		else
			policy_patch[key] = value
		end
	end
	local candidate, message = merge_runtime_policy(policy_patch, runtime_options, false)
	if candidate == nil then return "invalid", message end
	runtime_options = candidate
	runtime_policy_provider = provider
	runtime_effective_concurrent_requests = runtime_options.adaptive_max_concurrent_requests
	runtime_next_policy_refresh = now_local() + runtime_options.runtime_policy_refresh_interval
	runtime_next_budget_sample = now_local()
	runtime_queue_tokens = math.max(1, runtime_options.adaptive_max_concurrent_requests * runtime_options.adaptive_queue_budget_share * 16)
	runtime_queue_tokens_updated = now_local()
	runtime_metrics.last_policy_error = ""
	return "success", nil
end

function RecordStore.get_runtime_stats(): { [string]: unknown }
	return {
		policy = table.clone(runtime_options),
		effective_concurrent_requests = runtime_effective_concurrent_requests,
		active_requests = active_requests,
		read_budget = runtime_budget_read,
		write_budget = runtime_budget_write,
		queue_tokens = runtime_queue_tokens,
		metrics = table.clone(runtime_metrics),
		next_policy_refresh = runtime_next_policy_refresh,
		policy_provider_configured = runtime_policy_provider ~= nil,
		degraded_mode = runtime_options.degraded_mode,
		circuits = {
			read = table.clone(runtime_breakers.read),
			write = table.clone(runtime_breakers.write),
			service = table.clone(runtime_breakers.service),
		},
		work_class_in_flight = table.clone(runtime_external_in_flight),
		work_class_limits = {
			interactive = runtime_class_limit("interactive"), messaging = runtime_class_limit("messaging"),
			migration = runtime_class_limit("migration"), maintenance = runtime_class_limit("maintenance"), tracing = runtime_class_limit("tracing"),
		},
		next_budget_sample = runtime_next_budget_sample,
	}
end

function RecordStore.get_health_snapshot(max_records: number?): { [string]: unknown }
	local limit = max_records or 512
	if type(limit) ~= "number" or not math.isfinite(limit) or math.floor(limit) ~= limit or limit < 1 or limit > 4096 then
		return { code = "invalid", message = "max_records must be an integer from 1 to 4096" }
	end
	local scanned, truncated = 0, false
	local dirty_records, aged_dirty_records, uncertain_writes, risk_active_records = 0, 0, 0, 0
	local oldest_dirty_age_seconds, latest_confirmed_save_unix = 0, 0
	for record in active_records do
		if scanned >= limit then truncated = true; break end
		local state = private[record]
		if state ~= nil then
			scanned += 1
			local status = durability_status_for_state(state)
			if status.dirty then dirty_records += 1 end
			if status.dirty_age_exceeded == true then aged_dirty_records += 1 end
			if status.write_outcome_uncertain then uncertain_writes += 1 end
			if state.durability_risk_active then risk_active_records += 1 end
			if status.dirty_age_seconds ~= nil then oldest_dirty_age_seconds = math.max(oldest_dirty_age_seconds, status.dirty_age_seconds) end
			latest_confirmed_save_unix = math.max(latest_confirmed_save_unix, status.last_confirmed_save_unix)
		end
	end
	local known_risk = aged_dirty_records > 0 or uncertain_writes > 0
	return {
		code = "success",
		scope = "server_local_bounded_observation",
		state = if closing then "closing" elseif known_risk then "degraded" else "no_observed_durability_risk",
		state_semantics = "no_observed_durability_risk is not a claim that experience-wide storage is healthy",
		observed_at_unix = now_unix(),
		max_dirty_age_seconds = runtime_options.max_dirty_age_seconds,
		max_records = limit,
		records_scanned = scanned,
		truncated = truncated,
		dirty_records = dirty_records,
		aged_dirty_records = aged_dirty_records,
		uncertain_writes = uncertain_writes,
		risk_active_records = risk_active_records,
		oldest_observed_dirty_age_seconds = oldest_dirty_age_seconds,
		latest_confirmed_save_unix = latest_confirmed_save_unix,
		active_requests = active_requests,
		read_budget = runtime_budget_read,
		write_budget = runtime_budget_write,
		configured_degraded_mode = runtime_options.degraded_mode,
	}
end

function RecordStore.run_runtime_request(
	kind: string,
	callback: () -> unknown,
	operation_deadline: number?,
	work_class: string?
): (unknown, ResultCode?, string?)
	if kind ~= "read" and kind ~= "write" and kind ~= "update" and kind ~= "service" then
		return nil, "invalid", "kind must be read, write, update or service"
	end
	if type(callback) ~= "function" then return nil, "invalid", "callback must be a function" end
	local class = work_class or "interactive"
	if class ~= "interactive" and class ~= "messaging" and class ~= "migration"
		and class ~= "maintenance" and class ~= "tracing"
	then
		return nil, "invalid", "unsupported external work class"
	end
	local deadline, deadline_error = resolve_operation_deadline(operation_deadline)
	if deadline == nil then return nil, "invalid", deadline_error end
	local class_limit = runtime_class_limit(class)
	if runtime_external_in_flight[class] >= class_limit then
		runtime_metrics.budget_rejections += 1
		return nil, "budget", "shared runtime governor reached the " .. class .. " work-class concurrency cap"
	end
	if runtime_options.adaptive_runtime_enabled and class == "messaging" and not consume_runtime_queue_token() then
		runtime_metrics.budget_rejections += 1
		return nil, "budget", "shared runtime governor rejected messaging work under its bounded retry/wake budget"
	end
	if kind == "service" then
		if runtime_degraded_reject(nil, true) then
			runtime_metrics.budget_rejections += 1
			return nil, "budget", "shared runtime governor rejected external service work in degraded mode"
		end
		local breaker_ok = runtime_breaker_admit("service")
		if not breaker_ok then
			runtime_metrics.budget_rejections += 1
			return nil, "budget", "shared runtime service circuit is open"
		end
		if not acquire_slot(deadline :: number, false) then
			runtime_breaker_cancel_probe("service")
			runtime_metrics.budget_rejections += 1
			return nil, "budget", "shared runtime service concurrency reserve is exhausted"
		end
		runtime_external_in_flight[class] += 1
		local service_started = now_local()
		local service_ok, service_result = pcall(callback)
		release_slot()
		runtime_external_in_flight[class] = math.max(0, runtime_external_in_flight[class] - 1)
		observe_runtime_request("service", service_ok, if service_ok then nil else tostring(service_result), (now_local() - service_started) * 1000)
		if not service_ok then return nil, "unknown", tostring(service_result) end
		return service_result, nil, nil
	end
	if runtime_options.adaptive_runtime_enabled and class == "maintenance"
		and active_requests >= math.max(1, runtime_effective_concurrent_requests - runtime_options.critical_request_reserve - 1)
	then
		runtime_metrics.budget_rejections += 1
		return nil, "budget", "shared runtime governor deferred maintenance to preserve foreground headroom"
	end
	runtime_external_in_flight[class] += 1
	local request_type = if kind == "read" then Enum.DataStoreRequestType.StandardRead
		elseif kind == "write" then Enum.DataStoreRequestType.StandardWrite else nil
	local acquired = acquire_request(nil, deadline :: number, kind ~= "read", request_type)
	if not acquired then
		runtime_external_in_flight[class] = math.max(0, runtime_external_in_flight[class] - 1)
		runtime_metrics.budget_rejections += 1
		return nil, "budget", "shared runtime request admission was unavailable before the operation deadline"
	end
	local started_at = now_local()
	local ok, result = pcall(callback)
	release_slot()
	runtime_external_in_flight[class] = math.max(0, runtime_external_in_flight[class] - 1)
	observe_runtime_request(if kind == "read" then "read" else "write", ok, if ok then nil else tostring(result), (now_local() - started_at) * 1000)
	if not ok then return nil, "unknown", tostring(result) end
	return result, nil, nil
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

	local function mock_set_update_response_losses(count: number, message: string?)
		if type(count) ~= "number"
			or not math.isfinite(count)
			or math.floor(count) ~= count
			or count < 0
			or count > 100
		then
			error("count must be an integer from 0 to 100", 2)
		end
		if message ~= nil and type(message) ~= "string" then
			error("message must be a string or nil", 2)
		end
		mock_update_response_lost_count = count
		mock_update_response_lost_message = message
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
		check_durability_risks = function()
			local checked = 0
			for record in active_records do
				local state = private[record]
				if state ~= nil and state.backend.mock then
					evaluate_durability_risk(record, state)
					checked += 1
				end
			end
			return checked
		end,
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
		set_update_response_losses = mock_set_update_response_losses,
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
			mock_update_response_lost_count = 0
			mock_update_response_lost_message = nil
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

