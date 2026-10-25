--!strict
local MigrationRunner = {}

export type HistoricalPurchase = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
}

export type BackfillResult = {
	code: string,
	processed_count: number,
	backfilled_count: number,
	duplicate_count: number,
	failed_index: number?,
	message: string?,
}

export type Processor = {
	BackfillExternalAuthorityAsync: (self: Processor, purchases: { HistoricalPurchase }, max_items: number?) -> BackfillResult,
}

export type SourcePage = {
	items: { HistoricalPurchase },
	next_cursor: string?,
	done: boolean,
	source_revision: string,
}

export type Source = {
	read_page: (self: Source, cursor: string?, maximum: number) -> (SourcePage?, string?),
}

export type CheckpointStore = {
	GetAsyncFresh: (self: CheckpointStore, key: string) -> (unknown, string?),
	UpdateAsync: (self: CheckpointStore, key: string, transform: (unknown) -> unknown?) -> (unknown, string?),
}

export type Config = {
	job_id: string,
	source_revision: string,
	source: Source,
	processor: Processor,
	checkpoint_store: CheckpointStore,
	checkpoint_key: string,
	initial_cursor: string?,
	page_size: number?,
	inventory_manifest_id: string,
	expected_purchase_count: number,
	verify_complete_inventory: (string, string, number, number) -> (boolean, string?),
}

export type RunResult = {
	code: string,
	job_id: string,
	pages_processed: number,
	purchases_processed: number,
	backfilled_count: number,
	duplicate_count: number,
	cursor: string?,
	done: boolean,
	inventory_manifest_id: string,
	expected_purchase_count: number,
	inventory_verified: boolean,
	message: string?,
}

type Checkpoint = {
	version: number,
	job_id: string,
	source_revision: string,
	revision: number,
	cursor: string?,
	done: boolean,
	inventory_manifest_id: string,
	expected_purchase_count: number,
	inventory_verified: boolean,
	pages_processed: number,
	purchases_processed: number,
	backfilled_count: number,
	duplicate_count: number,
}

type NormalizedConfig = {
	job_id: string,
	source_revision: string,
	source: Source,
	processor: Processor,
	checkpoint_store: CheckpointStore,
	checkpoint_key: string,
	initial_cursor: string?,
	page_size: number,
	inventory_manifest_id: string,
	expected_purchase_count: number,
	verify_complete_inventory: (string, string, number, number) -> (boolean, string?),
}

local MAX_PAGE_SIZE = 16
local MAX_PAGES_PER_BATCH = 8
local MAX_CURSOR_BYTES = 512

local function valid_text(value: unknown, maximum: number): boolean
	return type(value) == "string" and value ~= "" and #value <= maximum
end

local function valid_cursor(value: unknown): boolean
	return value == nil or (type(value) == "string" and #value <= MAX_CURSOR_BYTES)
end

local function nonnegative_integer(value: unknown): boolean
	return type(value) == "number" and math.isfinite(value) and value >= 0 and math.floor(value) == value
end

local function copy_checkpoint(value: Checkpoint): Checkpoint
	return {
		version = value.version,
		job_id = value.job_id,
		source_revision = value.source_revision,
		revision = value.revision,
		cursor = value.cursor,
		done = value.done,
		inventory_manifest_id = value.inventory_manifest_id,
		expected_purchase_count = value.expected_purchase_count,
		inventory_verified = value.inventory_verified,
		pages_processed = value.pages_processed,
		purchases_processed = value.purchases_processed,
		backfilled_count = value.backfilled_count,
		duplicate_count = value.duplicate_count,
	}
end

local function valid_checkpoint(raw: unknown, config: NormalizedConfig): (Checkpoint?, string?)
	if type(raw) ~= "table" then return nil, "checkpoint row is not a table" end
	local value = raw :: { [string]: unknown }
	for key in pairs(value) do
		if key ~= "version" and key ~= "job_id" and key ~= "source_revision"
			and key ~= "revision" and key ~= "cursor" and key ~= "done"
			and key ~= "inventory_manifest_id" and key ~= "expected_purchase_count" and key ~= "inventory_verified"
			and key ~= "pages_processed" and key ~= "purchases_processed"
			and key ~= "backfilled_count" and key ~= "duplicate_count"
		then
			return nil, "checkpoint contains an unsupported field"
		end
	end
	if value.version ~= 1 or value.job_id ~= config.job_id
		or value.source_revision ~= config.source_revision
		or value.inventory_manifest_id ~= config.inventory_manifest_id
		or value.expected_purchase_count ~= config.expected_purchase_count
		or type(value.inventory_verified) ~= "boolean"
		or value.inventory_verified ~= value.done
		or (value.done and value.purchases_processed ~= config.expected_purchase_count)
		or not nonnegative_integer(value.revision)
		or not valid_cursor(value.cursor) or type(value.done) ~= "boolean"
		or not nonnegative_integer(value.pages_processed)
		or not nonnegative_integer(value.purchases_processed)
		or not nonnegative_integer(value.backfilled_count)
		or not nonnegative_integer(value.duplicate_count)
	then
		return nil, "checkpoint identity, revision, cursor or counters failed validation"
	end
	if (value.backfilled_count :: number) + (value.duplicate_count :: number)
		~= value.purchases_processed
	then
		return nil, "checkpoint counters do not reconcile"
	end
	return {
		version = 1,
		job_id = value.job_id :: string,
		source_revision = value.source_revision :: string,
		revision = value.revision :: number,
		cursor = value.cursor :: string?,
		done = value.done :: boolean,
		inventory_manifest_id = value.inventory_manifest_id :: string,
		expected_purchase_count = value.expected_purchase_count :: number,
		inventory_verified = value.inventory_verified :: boolean,
		pages_processed = value.pages_processed :: number,
		purchases_processed = value.purchases_processed :: number,
		backfilled_count = value.backfilled_count :: number,
		duplicate_count = value.duplicate_count :: number,
	}, nil
end

local function same_checkpoint(left: Checkpoint?, right: Checkpoint): boolean
	return left ~= nil
		and left.version == right.version
		and left.job_id == right.job_id
		and left.source_revision == right.source_revision
		and left.revision == right.revision
		and left.cursor == right.cursor
		and left.done == right.done
		and left.inventory_manifest_id == right.inventory_manifest_id
		and left.expected_purchase_count == right.expected_purchase_count
		and left.inventory_verified == right.inventory_verified
		and left.pages_processed == right.pages_processed
		and left.purchases_processed == right.purchases_processed
		and left.backfilled_count == right.backfilled_count
		and left.duplicate_count == right.duplicate_count
end

local function normalize_config(value: unknown): NormalizedConfig
	if type(value) ~= "table" then error("config must be a table", 3) end
	local fields = value :: { [string]: unknown }
	for key in pairs(fields) do
		if key ~= "job_id" and key ~= "source_revision" and key ~= "source"
			and key ~= "processor" and key ~= "checkpoint_store" and key ~= "checkpoint_key"
			and key ~= "initial_cursor" and key ~= "page_size"
			and key ~= "inventory_manifest_id" and key ~= "expected_purchase_count" and key ~= "verify_complete_inventory"
		then
			error("unsupported purchase migration runner option: " .. tostring(key), 3)
		end
	end
	if not valid_text(fields.job_id, 96) then error("job_id must be 1 to 96 bytes", 3) end
	if not valid_text(fields.source_revision, 128) then error("source_revision must be 1 to 128 bytes", 3) end
	if type(fields.source) ~= "table"
		or type((fields.source :: { [string]: unknown }).read_page) ~= "function"
	then
		error("source must implement read_page(cursor, maximum) over a stable historical snapshot", 3)
	end
	if type(fields.processor) ~= "table"
		or type((fields.processor :: { [string]: unknown }).BackfillExternalAuthorityAsync) ~= "function"
	then
		error("processor must implement BackfillExternalAuthorityAsync", 3)
	end
	if type(fields.checkpoint_store) ~= "table"
		or type((fields.checkpoint_store :: { [string]: unknown }).GetAsyncFresh) ~= "function"
		or type((fields.checkpoint_store :: { [string]: unknown }).UpdateAsync) ~= "function"
	then
		error("checkpoint_store must implement uncached GetAsyncFresh and atomic UpdateAsync", 3)
	end
	if not valid_text(fields.checkpoint_key, 50) then error("checkpoint_key must be 1 to 50 bytes", 3) end
	if not valid_text(fields.inventory_manifest_id, 128) then error("inventory_manifest_id must be 1 to 128 bytes", 3) end
	if not nonnegative_integer(fields.expected_purchase_count) then error("expected_purchase_count must be a non-negative integer", 3) end
	if type(fields.verify_complete_inventory) ~= "function" then error("verify_complete_inventory must verify an immutable inventory manifest", 3) end
	if not valid_cursor(fields.initial_cursor) then error("initial_cursor exceeds the 512-byte cursor limit", 3) end
	local page_size = if fields.page_size == nil then 16 else fields.page_size
	if type(page_size) ~= "number" or not math.isfinite(page_size)
		or math.floor(page_size) ~= page_size or page_size < 1 or page_size > MAX_PAGE_SIZE
	then
		error("page_size must be an integer from 1 to 16", 3)
	end
	return table.freeze({
		job_id = fields.job_id :: string,
		source_revision = fields.source_revision :: string,
		source = fields.source :: Source,
		processor = fields.processor :: Processor,
		checkpoint_store = fields.checkpoint_store :: CheckpointStore,
		checkpoint_key = fields.checkpoint_key :: string,
		initial_cursor = fields.initial_cursor :: string?,
		page_size = page_size :: number,
		inventory_manifest_id = fields.inventory_manifest_id :: string,
		expected_purchase_count = fields.expected_purchase_count :: number,
		verify_complete_inventory = fields.verify_complete_inventory :: (string, string, number, number) -> (boolean, string?),
	})
end

function MigrationRunner.new(config: Config)
	local normalized = normalize_config(config)

	local function read_checkpoint(): (Checkpoint?, string?)
		local ok, raw, read_error = pcall(function()
			return normalized.checkpoint_store:GetAsyncFresh(normalized.checkpoint_key)
		end)
		if not ok then return nil, "uncached checkpoint read raised: " .. tostring(raw) end
		if read_error ~= nil then return nil, tostring(read_error) end
		if raw == nil then
			return {
				version = 1,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,								job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,job_id = normalized.job_id,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,inventory_manifest_id = normalized.inventory_manifest_id,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,expected_purchase_count = normalized.expected_purchase_count,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,inventory_verified = false,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,source_revision = normalized.source_revision,

				cursor = normalized.initial_cursor,
				done = false,
				pages_processed = 0,
				purchases_processed = 0,
				backfilled_count = 0,
				duplicate_count = 0,
			}, nil
		end
		return valid_checkpoint(raw, normalized)
	end

	local function persist_checkpoint(expected_revision: number, target: Checkpoint): (string, string?)
		local call_ok, _, update_error = pcall(function()
			return normalized.checkpoint_store:UpdateAsync(normalized.checkpoint_key, function(raw)
				if raw == nil then
					if expected_revision ~= 0 then return nil end
					return copy_checkpoint(target)
				end
				local current = valid_checkpoint(raw, normalized)
				if current == nil then return nil end
				if same_checkpoint(current, target) then return nil end
				if current.revision ~= expected_revision then return nil end
				return copy_checkpoint(target)
			end)
		end)
		local readback, read_error = read_checkpoint()
		if readback ~= nil and same_checkpoint(readback, target) then
			return "committed", nil
		end
		if readback ~= nil and readback.revision > target.revision
			and readback.job_id == target.job_id and readback.source_revision == target.source_revision
		then
			return "advanced", nil
		end
		if not call_ok or update_error ~= nil or read_error ~= nil then
			return "unknown", tostring(update_error or read_error or "checkpoint update outcome is unresolved")
		end
		if readback ~= nil and readback.revision ~= expected_revision then
			return "conflict", "checkpoint revision changed before the migration cursor was committed"
		end
		return "unknown", "durable checkpoint was not confirmed by an uncached read"
	end

	local function result(code: string, checkpoint: Checkpoint, message: string?): RunResult
		return {
			code = code,
			job_id = normalized.job_id,
			pages_processed = checkpoint.pages_processed,
			purchases_processed = checkpoint.purchases_processed,
			backfilled_count = checkpoint.backfilled_count,
			duplicate_count = checkpoint.duplicate_count,
			cursor = checkpoint.cursor,
			done = checkpoint.done,
			inventory_manifest_id = checkpoint.inventory_manifest_id,
			expected_purchase_count = checkpoint.expected_purchase_count,
			inventory_verified = checkpoint.inventory_verified,
			message = message,
		}
	end

	local runner = {}

	function runner:GetStatusAsync(): RunResult
		local checkpoint, read_error = read_checkpoint()
		if checkpoint == nil then
			return {
				code = "unknown",
				job_id = normalized.job_id,
				pages_processed = 0,
				purchases_processed = 0,
				backfilled_count = 0,
				duplicate_count = 0,
				cursor = normalized.initial_cursor,
				done = false,
				inventory_manifest_id = normalized.inventory_manifest_id,
				expected_purchase_count = normalized.expected_purchase_count,
				inventory_verified = false,
				message = read_error or "migration checkpoint is unavailable",
			}
		end
		return result(if checkpoint.done then "completed" else "pending", checkpoint, nil)
	end

	function runner:RunBatchAsync(max_pages: number?)
		local page_limit = if max_pages == nil then 1 else max_pages
		if type(page_limit) ~= "number" or not math.isfinite(page_limit)
			or math.floor(page_limit) ~= page_limit or page_limit < 1 or page_limit > MAX_PAGES_PER_BATCH
		then
			local checkpoint = read_checkpoint()
			local safe_checkpoint = checkpoint or {
				version = 1,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,								job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,job_id = normalized.job_id,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,inventory_manifest_id = normalized.inventory_manifest_id,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,expected_purchase_count = normalized.expected_purchase_count,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,inventory_verified = false,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,source_revision = normalized.source_revision,

				cursor = normalized.initial_cursor,
				done = false,
				pages_processed = 0,
				purchases_processed = 0,
				backfilled_count = 0,
				duplicate_count = 0,
			}
			return result("invalid", safe_checkpoint, "max_pages must be an integer from 1 to 8")
		end
		local completed_this_batch = 0
		while completed_this_batch < page_limit do
			local checkpoint, checkpoint_error = read_checkpoint()
			if checkpoint == nil then
				local empty: Checkpoint = {
					version = 1,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = 0,										job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = 0,job_id = normalized.job_id,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = 0,inventory_manifest_id = normalized.inventory_manifest_id,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = 0,expected_purchase_count = normalized.expected_purchase_count,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = 0,inventory_verified = false,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = 0,source_revision = normalized.source_revision,

					cursor = normalized.initial_cursor,
					done = false,
					pages_processed = 0,
					purchases_processed = 0,
					backfilled_count = 0,
					duplicate_count = 0,
				}
				return result("unknown", empty, checkpoint_error or "migration checkpoint is unavailable")
			end
			if checkpoint.done then return result("completed", checkpoint, nil) end
			local source_ok, raw_page, source_error = pcall(function()
				return normalized.source:read_page(checkpoint.cursor, normalized.page_size)
			end)
			if not source_ok then
				return result("unknown", checkpoint, "historical source read raised: " .. tostring(raw_page))
			end
			if source_error ~= nil then
				return result("retryable", checkpoint, tostring(source_error))
			end
			if type(raw_page) ~= "table" then
				return result("invalid", checkpoint, "historical source returned no page table")
			end
			local page_fields = raw_page :: { [string]: unknown }
			for key in pairs(page_fields) do
				if key ~= "items" and key ~= "next_cursor" and key ~= "done" and key ~= "source_revision" then
					return result("invalid", checkpoint, "historical source page contains an unsupported field")
				end
			end
			if page_fields.source_revision ~= normalized.source_revision
				or type(page_fields.done) ~= "boolean"
				or not valid_cursor(page_fields.next_cursor)
				or type(page_fields.items) ~= "table"
			then
				return result("conflict", checkpoint, "historical source page revision, cursor or item list is malformed")
			end
			local items = page_fields.items :: { HistoricalPurchase }
			local item_count = #items
			if item_count > normalized.page_size then
				return result("invalid", checkpoint, "historical source returned more items than the requested page bound")
			end
			local dense = 0
			for index in pairs(items) do
				if type(index) ~= "number" or not math.isfinite(index)
					or math.floor(index) ~= index or index < 1 or index > item_count
				then
					return result("invalid", checkpoint, "historical source page items are not a dense array")
				end
				dense += 1
			end
			if dense ~= item_count then
				return result("invalid", checkpoint, "historical source page items are not a dense array")
			end
			local next_cursor = page_fields.next_cursor :: string?
			local done = page_fields.done :: boolean
			local proposed_purchase_count = checkpoint.purchases_processed + item_count
			if proposed_purchase_count > normalized.expected_purchase_count then
				return result("incomplete_inventory", checkpoint, "historical source exceeded the declared PurchaseId manifest count; cursor was not advanced")
			end
			if done then
				if proposed_purchase_count ~= normalized.expected_purchase_count then
					return result("incomplete_inventory", checkpoint, "terminal source page does not reconcile to the declared PurchaseId manifest count; terminal cursor was not advanced")
				end
				local verify_ok, verified, verify_error = pcall(
					normalized.verify_complete_inventory,
					normalized.inventory_manifest_id,
					normalized.source_revision,
					normalized.expected_purchase_count,
					proposed_purchase_count
				)
				if not verify_ok or verified ~= true then
					return result("incomplete_inventory", checkpoint,
						"independent inventory manifest verification did not confirm completeness: " .. tostring(verify_error or verified or "verifier rejected manifest"))
				end
			end
			if done and next_cursor ~= nil then
				return result("conflict", checkpoint, "terminal historical source page must not include a continuation cursor")
			end
			if not done and (next_cursor == nil or next_cursor == checkpoint.cursor) then
				return result("conflict", checkpoint, "historical source cursor did not advance")
			end
			if item_count > 0 then
				local backfill_ok, backfill = pcall(function()
					return normalized.processor:BackfillExternalAuthorityAsync(items, item_count)
				end)
				if not backfill_ok or type(backfill) ~= "table" then
					return result("unknown", checkpoint, "external PurchaseId import raised or returned no result: " .. tostring(backfill))
				end
				local backfill_result = backfill :: BackfillResult
				local processed_count = backfill_result.processed_count
				local backfilled_count = backfill_result.backfilled_count
				local duplicate_count = backfill_result.duplicate_count
				if not nonnegative_integer(processed_count)
					or not nonnegative_integer(backfilled_count)
					or not nonnegative_integer(duplicate_count)
					or processed_count ~= item_count
					or backfilled_count + duplicate_count ~= processed_count
					or backfill_result.failed_index ~= nil
					or (backfill_result.code ~= "complete" and backfill_result.code ~= "duplicate")
				then
					return result(backfill_result.code or "unknown", checkpoint,
						backfill_result.message or "historical PurchaseId batch result did not reconcile; cursor was not advanced")
				end
				local next_checkpoint: Checkpoint = {
					version = 1,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,										job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,job_id = normalized.job_id,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,inventory_manifest_id = normalized.inventory_manifest_id,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,expected_purchase_count = normalized.expected_purchase_count,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,inventory_verified = done,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,source_revision = normalized.source_revision,

					cursor = next_cursor,
					done = done,
					pages_processed = checkpoint.pages_processed + 1,
					purchases_processed = checkpoint.purchases_processed + backfill_result.processed_count,
					backfilled_count = checkpoint.backfilled_count + backfill_result.backfilled_count,
					duplicate_count = checkpoint.duplicate_count + backfill_result.duplicate_count,
				}
				local save_code, save_error = persist_checkpoint(checkpoint.revision, next_checkpoint)
				if save_code ~= "committed" and save_code ~= "duplicate" and save_code ~= "advanced" then
					return result(save_code, checkpoint, save_error)
				end
			else
				local next_checkpoint: Checkpoint = {
					version = 1,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,										job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,job_id = normalized.job_id,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,inventory_manifest_id = normalized.inventory_manifest_id,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,expected_purchase_count = normalized.expected_purchase_count,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,inventory_verified = done,
					job_id = normalized.job_id,
					source_revision = normalized.source_revision,
					revision = checkpoint.revision + 1,source_revision = normalized.source_revision,

					cursor = next_cursor,
					done = done,
					pages_processed = checkpoint.pages_processed + 1,
					purchases_processed = checkpoint.purchases_processed,
					backfilled_count = checkpoint.backfilled_count,
					duplicate_count = checkpoint.duplicate_count,
				}
				local save_code, save_error = persist_checkpoint(checkpoint.revision, next_checkpoint)
				if save_code ~= "committed" and save_code ~= "duplicate" and save_code ~= "advanced" then
					return result(save_code, checkpoint, save_error)
				end
			end
			completed_this_batch += 1
		end
		local checkpoint, checkpoint_error = read_checkpoint()
		if checkpoint == nil then
			local empty: Checkpoint = {
				version = 1,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,								job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,job_id = normalized.job_id,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,inventory_manifest_id = normalized.inventory_manifest_id,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,expected_purchase_count = normalized.expected_purchase_count,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,inventory_verified = false,
				job_id = normalized.job_id,
				source_revision = normalized.source_revision,
				revision = 0,source_revision = normalized.source_revision,

				cursor = normalized.initial_cursor,
				done = false,
				pages_processed = 0,
				purchases_processed = 0,
				backfilled_count = 0,
				duplicate_count = 0,
			}
			return result("unknown", empty, checkpoint_error or "migration checkpoint is unavailable")
		end
		return result(if checkpoint.done then "completed" else "incomplete", checkpoint, nil)
	end

	return table.freeze(runner)
end

return table.freeze({
	new = MigrationRunner.new,
})
