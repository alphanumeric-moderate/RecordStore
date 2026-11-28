--!strict

type Payload = {
	kind: string,
	value: number,
}

type Message = {
	sequence: number,
	event_id: string,
	payload: Payload,
	payload_digest: string,
	payload_bytes: number,
	created_at: number,
	producer_id: string?,
	producer_sequence: number?,
}

type Segment = {
	messages: { Message },
}

type PreparedEvent = {
	event_id: string,
	producer_id: string?,
	producer_sequence: number?,
}

type SegmentIndexes = {
	by_event_id: { [string]: Message },
	by_producer_sequence: { [string]: { [number]: Message } },
}

type Scenario = "new-events" | "tail-duplicates" | "producer-retries" | "mixed-retries"

type Summary = {
	scenario: Scenario,
	band: string,
	cases: number,
	index_wins: number,
	ratios: { number },
}

local CURRENT_THRESHOLD = 256
local SAMPLE_COUNT = 7
local BATCH_REPETITIONS = 24
local SEGMENT_SIZES = { 16, 32, 48, 64 }
local BATCH_SIZES = { 4, 8, 16, 32 }
local SCENARIOS: { Scenario } = {
	"new-events",
	"tail-duplicates",
	"producer-retries",
	"mixed-retries",
}

local function expect(condition: boolean, message: string)
	if not condition then
		error(message, 2)
	end
end

local function median(values: { number }): number
	local sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.ceil(#sorted / 2)]
end

local function find_event(segment: Segment, event_id: string): Message?
	for _, message in ipairs(segment.messages) do
		if message.event_id == event_id then
			return message
		end
	end
	return nil
end

local function find_producer_event(segment: Segment, producer_id: string, producer_sequence: number): Message?
	for _, message in ipairs(segment.messages) do
		if message.producer_id == producer_id and message.producer_sequence == producer_sequence then
			return message
		end
	end
	return nil
end

local function build_segment_indexes(segment: Segment): SegmentIndexes
	local indexes: SegmentIndexes = {
		by_event_id = {},
		by_producer_sequence = {},
	}
	for index = 1, #segment.messages do
		local message = segment.messages[index]
		if indexes.by_event_id[message.event_id] == nil then
			indexes.by_event_id[message.event_id] = message
		end
		local producer_id = message.producer_id
		local producer_sequence = message.producer_sequence
		if producer_id ~= nil and producer_sequence ~= nil then
			local producer_sequences = indexes.by_producer_sequence[producer_id]
			if producer_sequences == nil then
				producer_sequences = {}
				indexes.by_producer_sequence[producer_id] = producer_sequences
			end
			if producer_sequences[producer_sequence] == nil then
				producer_sequences[producer_sequence] = message
			end
		end
	end
	return indexes
end

local function find_segment_event(
	segment: Segment,
	event_id: string,
	producer_id: string?,
	producer_sequence: number?,
	indexes: SegmentIndexes?
): Message?
	if indexes ~= nil then
		local existing = indexes.by_event_id[event_id]
		if existing ~= nil or producer_id == nil or producer_sequence == nil then
			return existing
		end
		local producer_sequences = indexes.by_producer_sequence[producer_id]
		return if producer_sequences ~= nil then producer_sequences[producer_sequence] else nil
	end
	local existing = find_event(segment, event_id)
	if existing == nil and producer_id ~= nil and producer_sequence ~= nil then
		existing = find_producer_event(segment, producer_id, producer_sequence)
	end
	return existing
end

local function create_segment(message_count: number): Segment
	local messages: { Message } = table.create(message_count)
	for index = 1, message_count do
		local producer_id = "producer-" .. tostring((index - 1) % 4 + 1)
		local producer_sequence = math.floor((index - 1) / 4) + 1
		messages[index] = {
			sequence = index,
			event_id = "stored-event-" .. tostring(index),
			payload = { kind = "bench.event", value = index },
			payload_digest = "digest-" .. tostring(index),
			payload_bytes = 96,
			created_at = 1_800_000_000 + index,
			producer_id = producer_id,
			producer_sequence = producer_sequence,
		}
	end
	return { messages = messages }
end

local function append_new_event(batch: { PreparedEvent }, prefix: string, index: number)
	batch[#batch + 1] = {
		event_id = prefix .. "-" .. tostring(index),
	}
end

local function create_batch(segment: Segment, batch_size: number, scenario: Scenario): { PreparedEvent }
	local batch: { PreparedEvent } = table.create(batch_size)
	local matched_count = math.min(batch_size, #segment.messages)
	local tail_offset = 0
	local producer_offset = 0

	for index = 1, batch_size do
		if scenario == "new-events" then
			append_new_event(batch, "new-event", index)
		elseif scenario == "tail-duplicates" then
			if index <= matched_count then
				local message = segment.messages[#segment.messages - matched_count + index]
				batch[index] = { event_id = message.event_id }
			else
				append_new_event(batch, "tail-new-event", index)
			end
		elseif scenario == "producer-retries" then
			if index <= matched_count then
				local message = segment.messages[#segment.messages - matched_count + index]
				local producer_id = message.producer_id
				local producer_sequence = message.producer_sequence
				expect(producer_id ~= nil and producer_sequence ~= nil, "fixture message lacks producer identity")
				batch[index] = {
					event_id = "retry-event-" .. tostring(index),
					producer_id = producer_id,
					producer_sequence = producer_sequence,
				}
			else
				append_new_event(batch, "producer-new-event", index)
			end
		else
			local kind = (index - 1) % 4
			if kind == 0 and tail_offset < matched_count then
				tail_offset += 1
				local message = segment.messages[#segment.messages - tail_offset + 1]
				batch[index] = { event_id = message.event_id }
			elseif kind == 1 and producer_offset < matched_count then
				producer_offset += 1
				local message = segment.messages[#segment.messages - producer_offset + 1]
				local producer_id = message.producer_id
				local producer_sequence = message.producer_sequence
				expect(producer_id ~= nil and producer_sequence ~= nil, "fixture message lacks producer identity")
				batch[index] = {
					event_id = "mixed-retry-event-" .. tostring(index),
					producer_id = producer_id,
					producer_sequence = producer_sequence,
				}
			else
				append_new_event(batch, "mixed-new-event", index)
			end
		end
	end
	return batch
end

local function scan_batch(segment: Segment, batch: { PreparedEvent }): number
	local checksum = 0
	for _, event in ipairs(batch) do
		local existing = find_segment_event(
			segment,
			event.event_id,
			event.producer_id,
			event.producer_sequence,
			nil
		)
		if existing ~= nil then
			checksum += existing.sequence
		end
	end
	return checksum
end

local function indexed_batch(segment: Segment, batch: { PreparedEvent }): number
	local indexes = build_segment_indexes(segment)
	local checksum = 0
	for _, event in ipairs(batch) do
		local existing = find_segment_event(
			segment,
			event.event_id,
			event.producer_id,
			event.producer_sequence,
			indexes
		)
		if existing ~= nil then
			checksum += existing.sequence
		end
	end
	return checksum
end

local function measure_scan(segment: Segment, batch: { PreparedEvent }): (number, number)
	local started = os.clock()
	local checksum = 0
	for _ = 1, BATCH_REPETITIONS do
		checksum += scan_batch(segment, batch)
	end
	return (os.clock() - started) * 1_000_000 / BATCH_REPETITIONS, checksum
end

local function measure_indexed(segment: Segment, batch: { PreparedEvent }): (number, number)
	local started = os.clock()
	local checksum = 0
	for _ = 1, BATCH_REPETITIONS do
		checksum += indexed_batch(segment, batch)
	end
	return (os.clock() - started) * 1_000_000 / BATCH_REPETITIONS, checksum
end

local function threshold_band(product: number): string
	if product < CURRENT_THRESHOLD then
		return "below"
	elseif product == CURRENT_THRESHOLD then
		return "at"
	end
	return "above"
end

local summaries: { [string]: Summary } = {}
local case_count = 0

for _, segment_size in ipairs(SEGMENT_SIZES) do
	for _, batch_size in ipairs(BATCH_SIZES) do
		local segment = create_segment(segment_size)
		local product = segment_size * batch_size
		for _, scenario in ipairs(SCENARIOS) do
			local batch = create_batch(segment, batch_size, scenario)
			local scan_warmup = scan_batch(segment, batch)
			local index_warmup = indexed_batch(segment, batch)
			expect(scan_warmup == index_warmup, "scan and indexed lookup disagree during warmup")

			local scan_samples: { number } = table.create(SAMPLE_COUNT)
			local index_samples: { number } = table.create(SAMPLE_COUNT)
			for sample = 1, SAMPLE_COUNT do
				local scan_elapsed: number
				local index_elapsed: number
				local scan_checksum: number
				local index_checksum: number
				if sample % 2 == 1 then
					scan_elapsed, scan_checksum = measure_scan(segment, batch)
					index_elapsed, index_checksum = measure_indexed(segment, batch)
				else
					index_elapsed, index_checksum = measure_indexed(segment, batch)
					scan_elapsed, scan_checksum = measure_scan(segment, batch)
				end
				expect(scan_checksum == index_checksum, "scan and indexed lookup disagree during a timed sample")
				scan_samples[sample] = scan_elapsed
				index_samples[sample] = index_elapsed
			end

			local scan_median = median(scan_samples)
			local index_median = median(index_samples)
			local ratio = index_median / math.max(scan_median, 0.000001)
			local band = threshold_band(product)
			local summary_key = scenario .. "-" .. band
			local summary = summaries[summary_key]
			if summary == nil then
				summary = {
					scenario = scenario,
					band = band,
					cases = 0,
					index_wins = 0,
					ratios = {},
				}
				summaries[summary_key] = summary
			end
			summary.cases += 1
			if ratio < 1 then
				summary.index_wins += 1
			end
			summary.ratios[#summary.ratios + 1] = ratio
			case_count += 1

			print(string.format(
				"[durable-stream-index-break-even] scenario=%s segment=%d batch=%d product=%d scan_us=%.3f indexed_us=%.3f indexed_over_scan=%.3f",
				scenario,
				segment_size,
				batch_size,
				product,
				scan_median,
				index_median,
				ratio
			))
		end
	end
end

for _, summary in summaries do
	print(string.format(
		"[durable-stream-index-summary] scenario=%s threshold_band=%s cases=%d indexed_wins=%d median_indexed_over_scan=%.3f",
		summary.scenario,
		summary.band,
		summary.cases,
		summary.index_wins,
		median(summary.ratios)
	))
end

expect(case_count == #SEGMENT_SIZES * #BATCH_SIZES * #SCENARIOS, "break-even matrix was incomplete")
print(string.format(
	"[durable-stream-index-break-even] complete cases=%d samples_per_case=%d repetitions_per_sample=%d",
	case_count,
	SAMPLE_COUNT,
	BATCH_REPETITIONS
))
