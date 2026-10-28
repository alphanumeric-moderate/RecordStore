--!nocheck
local Shim = require("./RobloxShim")
local RunnerModule = require(
	game:GetService("ServerScriptService"):WaitForChild("PlayerDataInitializer"):WaitForChild("PurchaseAuthorityMigrationRunner")
)

local function expect(value, message)
	assert(value, message)
end

local function clone(value, depth)
	depth = depth or 0
	assert(depth <= 32, "migration fixture exceeded clone depth")
	if type(value) ~= "table" then return value end
	local result = {}
	for key, child in pairs(value) do result[key] = clone(child, depth + 1) end
	return result
end

local function make_checkpoint_store()
	local store = {
		values = {},
		update_calls = 0,
		lose_next_update_response = false,
		fail_next_read = false,
	}
	function store:GetAsyncFresh(key)
		if self.fail_next_read then
			self.fail_next_read = false
			return nil, "injected uncached checkpoint read failure"
		end
		return clone(self.values[key]), nil
	end
	function store:UpdateAsync(key, transform)
		self.update_calls += 1
		local changed = transform(clone(self.values[key]))
		if changed ~= nil then self.values[key] = clone(changed) end
		if self.lose_next_update_response then
			self.lose_next_update_response = false
			return nil, "injected response loss after checkpoint commit"
		end
		return clone(self.values[key]), nil
	end
	return store
end

local function make_source(pages, revision, calls)
	local source = {}
	local inventory_count = 0
	for _, source_page in pairs(pages) do inventory_count += #source_page.items end
	local ordered_purchases = {}
	local first_cursor = if pages["<initial>"] ~= nil then "<initial>" else next(pages)
	local cursor_key = first_cursor
	local visited_pages = {}
	while cursor_key ~= nil and not visited_pages[cursor_key] do
		local source_page = pages[cursor_key]
		if source_page == nil then break end
		visited_pages[cursor_key] = true
		for _, item in ipairs(source_page.items) do ordered_purchases[#ordered_purchases + 1] = clone(item) end
		if source_page.done then break end
		cursor_key = source_page.next_cursor
	end
	source.inventory_count = inventory_count
	local inventory_digest, digest_error = RunnerModule.ComputeInventoryDigest(ordered_purchases)
	assert(inventory_digest ~= nil, digest_error or "could not compute fixture inventory digest")
	source.inventory_digest = inventory_digest
	source.source_revision = revision
	function source:read_page(cursor, maximum)
		calls.count += 1
		calls.last_cursor = cursor
		calls.last_maximum = maximum
		local page = pages[cursor == nil and "<initial>" or cursor]
		if page == nil then return nil, "no fixture page for cursor " .. tostring(cursor) end
		return {
			items = clone(page.items),
			next_cursor = page.next_cursor,
			done = page.done,
			source_revision = revision,
		}, nil
	end
	return source
end

local function make_processor(results)
	local processor = { calls = 0, batches = {} }
	function processor:BackfillExternalAuthorityAsync(purchases, maximum)
		self.calls += 1
		self.batches[#self.batches + 1] = { items = clone(purchases), maximum = maximum }
		local queued = results and table.remove(results, 1)
		if queued ~= nil then return clone(queued) end
		return {
			code = "complete",
			processed_count = #purchases,
			backfilled_count = #purchases,
			duplicate_count = 0,
			failed_index = nil,
			message = nil,
		}
	end
	return processor
end

local function purchase(id, product_id)
	return {
		PurchaseId = id,
		PlayerId = 123,
		ProductId = product_id or 1001,
	}
end

local function page(items, next_cursor, done)
	return { items = items, next_cursor = next_cursor, done = done }
end

local function new_runner(job_id, source, processor, checkpoint_store, revision, initial_cursor, expected_count_override, verifier_override, expected_digest_override)
	return RunnerModule.new({
		job_id = job_id,
		source_revision = revision or source.source_revision or "snapshot-v1",
		source = source,
		processor = processor,
		checkpoint_store = checkpoint_store,
		checkpoint_key = "pm:" .. job_id,
		initial_cursor = initial_cursor,
		page_size = 16,
		inventory_manifest_id = "manifest:" .. (revision or source.source_revision or "snapshot-v1"),
		expected_purchase_count = if expected_count_override == nil then source.inventory_count else expected_count_override,
		expected_inventory_digest = expected_digest_override or source.inventory_digest,
		verify_complete_inventory = verifier_override or function(manifest_id, source_revision, expected_count, observed_count, expected_digest, observed_digest)
			return manifest_id == "manifest:" .. source.source_revision
				and source_revision == source.source_revision
				and expected_count == source.inventory_count
				and observed_count == source.inventory_count
				and expected_digest == source.inventory_digest
				and observed_digest == source.inventory_digest,
				"fixture inventory manifest mismatch"
		end,
	})
end

-- Bounded multi-page import, with an UpdateAsync response lost after commit.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	backing.lose_next_update_response = true
	local source = make_source({
		["<initial>"] = page({ purchase("historical-001"), purchase("historical-002", 1002) }, "page-2", false),
		["page-2"] = page({ purchase("historical-003") }, "page-3", false),
		["page-3"] = page({}, nil, true),
	}, "snapshot-v1", calls)
	local processor = make_processor()
	local runner = new_runner("historical-import-main", source, processor, backing)

	local first = runner:RunBatchAsync(2)
	expect(first.code == "incomplete" and first.done == false,
		"two-page migration batch did not pause as incomplete: " .. tostring(first.message))
	expect(first.pages_processed == 2 and first.purchases_processed == 3,
		"migration batch page/purchase counters did not reconcile")
	expect(first.backfilled_count == 3 and first.duplicate_count == 0,
		"migration batch backfill counters are incorrect")
	expect(first.cursor == "page-3", "migration cursor did not checkpoint the last committed page")
	expect(processor.calls == 2 and processor.batches[1].maximum == 2,
		"processor did not receive bounded source pages")

	local recovered = runner:GetStatusAsync()
	expect(recovered.code == "pending" and recovered.cursor == "page-3"
		and recovered.pages_processed == 2,
		"lost checkpoint response was not reconciled from the uncached durable checkpoint")
	local second = runner:RunBatchAsync(1)
	expect(second.code == "completed" and second.done == true and second.cursor == nil,
		"final empty terminal page did not complete the migration")
	expect(second.pages_processed == 3 and second.purchases_processed == 3,
		"final migration counters changed during terminal-page checkpoint")
	local already_complete = runner:RunBatchAsync(1)
	expect(already_complete.code == "completed" and calls.count == 3,
		"completed migration reread source pages unexpectedly")
end

-- A terminal page cannot commit unless its full row count matches the declared manifest.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("manifest-short-001") }, nil, true),
	}, "snapshot-short", calls)
	local processor = make_processor()
	local runner = new_runner("historical-import-short-manifest", source, processor, backing, nil, nil, 2)
	local result = runner:RunBatchAsync(1)
	expect(result.code == "incomplete_inventory" and result.done == false and result.cursor == nil,
		"terminal page with fewer rows than the manifest was accepted")
	expect(processor.calls == 0 and calls.count == 1,
		"runner imported a terminal page before inventory-count reconciliation")
	local checkpoint, read_error = backing:GetAsyncFresh("pm:historical-import-short-manifest")
	expect(checkpoint == nil and read_error == nil,
		"incomplete inventory manifest created a terminal checkpoint")
end

-- A same-count but wrong content digest must block before importing the terminal page.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("manifest-digest-001") }, nil, true),
	}, "snapshot-digest", calls)
	local processor = make_processor()
	local runner = new_runner(
		"historical-import-digest-mismatch",
		source,
		processor,
		backing,
		"snapshot-digest",
		nil,
		nil,
		nil,
		"0000000000000000000000000000000000000000000000000000000000000000"
	)
	local result = runner:RunBatchAsync(1)
	expect(result.code == "incomplete_inventory"
		and string.find(result.message or "", "inventory digest") ~= nil,
		"terminal page with a same-count digest mismatch was accepted")
	expect(processor.calls == 0 and calls.count == 1,
		"PurchaseIds were imported before terminal digest verification")
end

-- An external manifest verifier can block a terminal page even when row counts match.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("manifest-rejected-001") }, nil, true),
	}, "snapshot-rejected", calls)
	local processor = make_processor()
	local runner = new_runner("historical-import-rejected-manifest", source, processor, backing, nil, nil, nil,
		function() return false, "external manifest digest mismatch" end)
	local result = runner:RunBatchAsync(1)
	expect(result.code == "incomplete_inventory" and string.find(result.message or "", "digest mismatch") ~= nil,
		"external inventory verifier rejection was ignored")
	expect(processor.calls == 0 and calls.count == 1,
		"PurchaseIds were imported before independent manifest verification")
end

-- A partial/unknown batch must leave the durable cursor and counters unchanged,
-- then retry the exact same page and source PurchaseIds.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("partial-001"), purchase("partial-002") }, "page-2", false),
		["page-2"] = page({}, nil, true),
	}, "snapshot-partial", calls)
	local processor = make_processor({
		{
			code = "partial",
			processed_count = 1,
			backfilled_count = 1,
			duplicate_count = 0,
			failed_index = 2,
			message = "injected second PurchaseId failure",
		},
		nil,
	})
	local runner = new_runner("historical-import-partial", source, processor, backing, "snapshot-partial")
	local failed = runner:RunBatchAsync(1)
	expect(failed.code == "partial" and failed.cursor == nil and failed.pages_processed == 0,
		"partial external backfill advanced the checkpoint cursor")
	local checkpoint, read_error = backing:GetAsyncFresh("pm:historical-import-partial")
	expect(checkpoint == nil and read_error == nil,
		"partial external backfill persisted a checkpoint before completing the source page")
	local retry = runner:RunBatchAsync(1)
	expect(retry.code == "incomplete" and retry.cursor == "page-2" and retry.purchases_processed == 2,
		"retry did not reconcile the full original batch: " .. tostring(retry.message))
	expect(calls.count == 2 and processor.calls == 2,
		"partial page retry did not reread the same durable source cursor")
end

-- A changing source revision and a non-advancing cursor both fail closed.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local revision_source = make_source({
		["<initial>"] = page({ purchase("revision-001") }, "page-2", true),
	}, "snapshot-changed", calls)
	local runner = new_runner("historical-import-revision", revision_source, make_processor(), backing, "snapshot-expected")
	local changed = runner:RunBatchAsync(1)
	expect(changed.code == "conflict" and changed.cursor == nil and changed.pages_processed == 0,
		"historical source revision change advanced the migration checkpoint")

	local same_cursor_calls = { count = 0 }
	local same_cursor_source = make_source({
		["fixed"] = page({ purchase("cursor-001") }, "fixed", false),
	}, "snapshot-cursor", same_cursor_calls)
	local same_cursor_runner = new_runner(
		"historical-import-stalled-cursor", same_cursor_source, make_processor(),
		make_checkpoint_store(), "snapshot-cursor", "fixed"
	)
	local stalled = same_cursor_runner:RunBatchAsync(1)
	expect(stalled.code == "conflict" and stalled.cursor == "fixed" and stalled.pages_processed == 0,
		"non-advancing historical source cursor was accepted")
end

-- Import duplicates remain an idempotent completion, and malformed batch limits
-- are structured outcomes rather than thrown validation errors.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("duplicate-001"), purchase("duplicate-002") }, nil, true),
	}, "snapshot-duplicates", calls)
	local processor = make_processor({
		{
			code = "duplicate",
			processed_count = 2,
			backfilled_count = 0,
			duplicate_count = 2,
			failed_index = nil,
			message = nil,
		},
	})
	local runner = new_runner("historical-import-duplicates", source, processor, backing, "snapshot-duplicates")
	local bad_limit = runner:RunBatchAsync(0)
	expect(bad_limit.code == "invalid", "invalid page limit did not return a structured invalid result")
	local result = runner:RunBatchAsync(1)
	expect(result.code == "completed" and result.backfilled_count == 0
		and result.duplicate_count == 2 and result.purchases_processed == 2,
		"duplicate-only import did not complete with reconciled counters")
end

-- A completed checkpoint cannot retain a continuation cursor.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("terminal-cursor-001") }, nil, true),
	}, "snapshot-terminal-cursor", calls)
	local job_id = "historical-import-terminal-cursor"
	backing.values["pm:" .. job_id] = {
		version = 4,
		digest_algorithm = "sha256-chain-v1",
		job_id = job_id,
		source_revision = source.source_revision,
		revision = 1,
		cursor = "after-terminal-page",
		done = true,
		inventory_manifest_id = "manifest:" .. source.source_revision,
		expected_purchase_count = source.inventory_count,
		expected_inventory_digest = source.inventory_digest,
		inventory_digest = source.inventory_digest,
		inventory_verified = true,
		pages_processed = 1,
		purchases_processed = source.inventory_count,
		backfilled_count = source.inventory_count,
		duplicate_count = 0,
		last_purchase_id = "terminal-cursor-001",
		last_player_id = 123,
		last_product_id = 1001,
	}
	local processor = make_processor()
	local runner = new_runner(job_id, source, processor, backing)
	local status = runner:GetStatusAsync()
	expect(status.code == "unknown" and status.done == false,
		"runner accepted a completed migration checkpoint that retained a continuation cursor")
	local result = runner:RunBatchAsync(1)
	expect(result.code == "unknown" and calls.count == 0 and processor.calls == 0,
		"runner read or imported source purchases after rejecting an inconsistent terminal checkpoint")
end

-- A persisted checkpoint must have a positive revision; revision zero is only the in-memory empty state.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("revision-zero-001") }, nil, true),
	}, "snapshot-revision-zero", calls)
	local job_id = "historical-import-revision-zero"
	backing.values["pm:" .. job_id] = {
		version = 4,
		digest_algorithm = "sha256-chain-v1",
		job_id = job_id,
		source_revision = source.source_revision,
		revision = 0,
		cursor = nil,
		done = true,
		inventory_manifest_id = "manifest:" .. source.source_revision,
		expected_purchase_count = source.inventory_count,
		expected_inventory_digest = source.inventory_digest,
		inventory_digest = source.inventory_digest,
		inventory_verified = true,
		pages_processed = 0,
		purchases_processed = source.inventory_count,
		backfilled_count = source.inventory_count,
		duplicate_count = 0,
		last_purchase_id = "revision-zero-001",
		last_player_id = 123,
		last_product_id = 1001,
	}
	local runner = new_runner(job_id, source, make_processor(), backing)
	local status = runner:GetStatusAsync()
	expect(status.code == "unknown" and status.done == false,
		"runner accepted a completed durable checkpoint with revision zero")
	local result = runner:RunBatchAsync(1)
	expect(result.code == "unknown" and calls.count == 0,
		"runner read historical purchases after rejecting a revision-zero checkpoint")
end

-- Corrupt durable checkpoints are surfaced as unknown and never silently reset
-- the cursor to the beginning of an existing migration.
do
	local backing = make_checkpoint_store()
	backing.values["pm:historical-import-corrupt"] = {
		version = 1,
		job_id = "some-other-job",
		source_revision = "snapshot-corrupt",
		revision = 9,
		cursor = "after-page-9",
		done = false,
		pages_processed = 9,
		purchases_processed = 9,
		backfilled_count = 9,
		duplicate_count = 0,
	}
	local calls = { count = 0 }
	local source = make_source({
		["<initial>"] = page({ purchase("should-not-import") }, nil, true),
	}, "snapshot-corrupt", calls)
	local runner = new_runner("historical-import-corrupt", source, make_processor(), backing, "snapshot-corrupt")
	local status = runner:GetStatusAsync()
	expect(status.code == "unknown" and status.done == false,
		"corrupt or mismatched checkpoint was silently accepted")
	local run = runner:RunBatchAsync(1)
	expect(run.code == "unknown" and calls.count == 0,
		"runner read source data after rejecting a mismatched durable checkpoint")
end


-- Unsorted rows within a page are rejected before any import or checkpoint write.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("z-order-001"), purchase("a-order-001") }, nil, true),
	}, "snapshot-unsorted-page", calls)
	local processor = make_processor()
	local runner = new_runner("historical-import-unsorted-page", source, processor, backing)
	local result = runner:RunBatchAsync(1)
	expect(result.code == "invalid" and result.purchases_processed == 0,
		"out-of-order purchases within a page were accepted")
	expect(processor.calls == 0 and backing.values["pm:historical-import-unsorted-page"] == nil,
		"unsorted page caused an import or checkpoint write")
end

-- The last verified row survives checkpoints so resumed pages preserve global ordering.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("purchase-z") }, "page-2", false),
		["page-2"] = page({ purchase("purchase-a") }, nil, true),
	}, "snapshot-cross-page-order", calls)
	local processor = make_processor()
	local runner = new_runner("historical-import-cross-page-order", source, processor, backing)
	local first = runner:RunBatchAsync(1)
	expect(first.code == "incomplete" and first.cursor == "page-2",
		"first page did not produce a resumable checkpoint")
	local saved = backing.values["pm:historical-import-cross-page-order"]
	expect(saved ~= nil and saved.last_purchase_id == "purchase-z"
		and saved.last_player_id == 123 and saved.last_product_id == 1001,
		"checkpoint did not persist the last verified ordering tuple")
	local second = runner:RunBatchAsync(1)
	expect(second.code == "invalid" and second.cursor == "page-2" and second.purchases_processed == 1,
		"descending order across pages was accepted or advanced the cursor")
	expect(processor.calls == 1,
		"out-of-order resumed page was imported before rejection")
end

-- ProductId is the final deterministic tie-break when PurchaseId and PlayerId match.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("same-purchase", 1002), purchase("same-purchase", 1001) }, nil, true),
	}, "snapshot-unsorted-tiebreak", calls)
	local processor = make_processor()
	local runner = new_runner("historical-import-unsorted-tiebreak", source, processor, backing)
	local result = runner:RunBatchAsync(1)
	expect(result.code == "invalid" and processor.calls == 0,
		"descending ProductId tie-break order was accepted")
end



-- Empty and control-character continuation cursors are not valid advancing tokens.
do
	for index, invalid_cursor in ipairs({ "", "bad\ncursor" }) do
		local calls = { count = 0 }
		local backing = make_checkpoint_store()
		local job_id = "historical-import-invalid-cursor-" .. tostring(index)
		local source = make_source({
			["<initial>"] = page({ purchase("invalid-cursor-purchase-" .. tostring(index)) }, invalid_cursor, false),
		}, "snapshot-invalid-cursor-" .. tostring(index), calls)
		local processor = make_processor()
		local runner = new_runner(job_id, source, processor, backing)
		local result = runner:RunBatchAsync(1)
		expect(result.code == "conflict" and result.pages_processed == 0 and result.cursor == nil,
			"malformed continuation cursor was accepted")
		expect(processor.calls == 0 and backing.values["pm:" .. job_id] == nil,
			"malformed cursor caused an import or checkpoint write")
	end
end

-- Version-3 checkpoints lack a verified last-row tuple and must not be silently resumed.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("legacy-v3-purchase") }, nil, true),
	}, "snapshot-legacy-v3", calls)
	local job_id = "historical-import-legacy-v3"
	backing.values["pm:" .. job_id] = {
		version = 3,
		digest_algorithm = "sha256-chain-v1",
		job_id = job_id,
		source_revision = source.source_revision,
		revision = 1,
		cursor = "legacy-v3-cursor",
		done = false,
		inventory_manifest_id = "manifest:" .. source.source_revision,
		expected_purchase_count = source.inventory_count,
		expected_inventory_digest = source.inventory_digest,
		inventory_digest = source.inventory_digest,
		inventory_verified = false,
		pages_processed = 1,
		purchases_processed = source.inventory_count,
		backfilled_count = source.inventory_count,
		duplicate_count = 0,
	}
	local processor = make_processor()
	local runner = new_runner(job_id, source, processor, backing)
	local status = runner:GetStatusAsync()
	expect(status.code == "unknown" and status.done == false,
		"version-3 checkpoint without the ordering tuple was accepted")
	local result = runner:RunBatchAsync(1)
	expect(result.code == "unknown" and calls.count == 0 and processor.calls == 0,
		"runner restarted source processing after rejecting a version-3 checkpoint")
end

-- A concurrent runner that advances the checkpoint wins over this runner's stale compare-and-set.
do
	local calls = { count = 0 }
	local backing = make_checkpoint_store()
	local source = make_source({
		["<initial>"] = page({ purchase("concurrent-001"), purchase("concurrent-002", 1002) }, "page-2", false),
		["page-2"] = page({ purchase("concurrent-003") }, "page-3", false),
		["page-3"] = page({ purchase("concurrent-004") }, nil, true),
	}, "snapshot-concurrent-checkpoint", calls)
	local job_id = "historical-import-concurrent-checkpoint"
	local checkpoint_key = "pm:" .. job_id
	local competing_digest, digest_error = RunnerModule.ComputeInventoryDigest({
		purchase("concurrent-001"),
		purchase("concurrent-002", 1002),
		purchase("concurrent-003"),
	})
	expect(competing_digest ~= nil, digest_error or "could not compute concurrent checkpoint digest")
	local competing_checkpoint = {
		version = 4,
		digest_algorithm = "sha256-chain-v1",
		job_id = job_id,
		source_revision = source.source_revision,
		revision = 2,
		cursor = "page-3",
		done = false,
		inventory_manifest_id = "manifest:" .. source.source_revision,
		expected_purchase_count = source.inventory_count,
		expected_inventory_digest = source.inventory_digest,
		inventory_digest = competing_digest,
		inventory_verified = false,
		pages_processed = 2,
		purchases_processed = 3,
		backfilled_count = 3,
		duplicate_count = 0,
		last_purchase_id = "concurrent-003",
		last_player_id = 123,
		last_product_id = 1001,
	}
	local original_update = backing.UpdateAsync
	local inject_competitor = true
	backing.UpdateAsync = function(self, key, transform)
		if inject_competitor and key == checkpoint_key then
			inject_competitor = false
			self.values[key] = clone(competing_checkpoint)
		end
		return original_update(self, key, transform)
	end

	local processor = make_processor()
	local runner = new_runner(job_id, source, processor, backing)
	local result = runner:RunBatchAsync(1)
	expect(result.code == "incomplete" and result.cursor == "page-3"
		and result.pages_processed == 2 and result.purchases_processed == 3,
		"stale runner did not observe the newer committed checkpoint")
	local durable = backing.values[checkpoint_key]
	expect(durable ~= nil and durable.revision == 2 and durable.cursor == "page-3"
		and durable.purchases_processed == 3 and durable.inventory_digest == competing_digest,
		"stale compare-and-set overwrote or regressed the competing runner's checkpoint")
	expect(processor.calls == 1,
		"stale runner read or imported another page after losing its checkpoint compare-and-set")
end


for index, code in { "complete", "duplicate", false, 42, "unknown", "conflict" } do
	local source = make_source({
		["<initial>"] = page({ purchase("unreconciled-001") }, nil, true),
	}, "snapshot-unreconciled", { count = 0 })
	local processor = make_processor({ {
		code = code, processed_count = 0, backfilled_count = 0, duplicate_count = 0,
		message = "keep diagnostic",
	} })
	local runner = new_runner("unreconciled-" .. index, source, processor, make_checkpoint_store(), "snapshot-unreconciled")
	local outcome = runner:RunBatchAsync(1)
	local expected = if code == "unknown" or code == "conflict" then code else "unreconciled"
	expect(outcome.code == expected and outcome.cursor == nil and outcome.pages_processed == 0
		and outcome.message == "keep diagnostic", "unreconciled processor result was reported as success")
end
