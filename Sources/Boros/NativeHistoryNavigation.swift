import Foundation
import CoreFoundation

enum NativeHistoryNavigationError: Error {
    case scope, snapshotLimit, sourceMismatch, invalidQuery, invalidCursor, invalidRegion, invalidPlan, invalidExtraction, outputBound
}

/// One complete, immutable project snapshot. Navigation is lexical and derived;
/// only the original hits can become final-answer evidence. IDs in model JSON
/// are ordinal projections; original IDs and calendar locators remain private.
final class NativeHistoryNavigation {
    static let version = "native-history-navigation-v1"
    static let maximumRecords = 20_000
    static let maximumSourceBytes = 32 * 1_048_576
    struct Block {
        let id: String
        let regionID: String
        let sourceIDs: [String]
        let hostSourceIDs: [String]
        let hits: [MemoryHit]
        let byteCount: Int
        let modelRecords: [[String: Any]]
    }
    struct Page {
        let blockIDs: [String]
        let nextCursor: String?
        let coverage: String
        let object: [String: Any]
    }
    private struct Source {
        let id: String
        let reference: MemorySourceReference
        let text: String
        let hits: [MemoryHit]
        let object: [String: Any]
    }
    private struct Node { let children: [String]; let blockIDs: [String] }
    private struct Cursor { let operation: String; let binding: String; let offset: Int }
    let projectID: String
    let sourceFrontier: Int
    let sourceDigest: String
    private(set) var blocks: [String: Block] = [:]
    private(set) var orderedBlockIDs: [String] = []
    private var sources: [String: Source] = [:]
    private var sourceBlocks: [String: String] = [:]
    private var nodes: [String: Node] = [:]
    private var cursors: [String: Cursor] = [:]
    private var frequencies: [String: [String: Int]] = [:]
    private var documentFrequency: [String: Int] = [:]
    private var blockOrder: [String: Int] = [:]
    private let lease: EpisodeLease
    let rootRegionID = "h000000"

    static func load(store: MemoryStore, projectID: String, excludingEventID: String,
                     lease: EpisodeLease) throws -> NativeHistoryNavigation {
        let episode = try lease.checkActive(projectID: projectID)
        guard case .chat(_, _, let acceptedHumanID) = episode.origin,
              episodeIdentifierEqual(acceptedHumanID, excludingEventID) else { throw NativeHistoryNavigationError.scope }
        return try MeteredRetrieval.operation(lease: lease) {
            let frontier = try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 1) {
                try store.sourceFrontier(projectID: projectID)
            }
            var references: [MemorySourceReference] = [], after = 0, bytes = 0
            let exclusions = ExactSourceIDs([excludingEventID])
            while true {
                let page = try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 256) {
                    try store.sourceManifest(projectID: projectID, afterSequence: after, throughSequence: frontier,
                        limit: 256, excludingSourceIDs: exclusions)
                }
                for reference in page {
                    guard episodeIdentifierEqual(reference.projectID, projectID), reference.sequence > after,
                          reference.sequence <= frontier, !exclusions.contains(reference.eventID),
                          reference.byteCount >= 0, reference.byteCount <= MemoryStore.maximumPayloadBytes else {
                        throw NativeHistoryNavigationError.sourceMismatch
                    }
                    after = reference.sequence
                    guard references.count < maximumRecords, reference.byteCount <= maximumSourceBytes - bytes else {
                        throw NativeHistoryNavigationError.snapshotLimit
                    }
                    references.append(reference); bytes += reference.byteCount
                }
                if page.count < 256 { break }
            }
            // Refuse an incomplete snapshot before payload access. Every source
            // then receives funding before page reads, sealing and lexical work.
            var loaded: [(MemorySourceReference, String, [MemoryHit])] = []
            for reference in references {
                guard try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 1, {
                    try store.sourceReference(eventID: reference.eventID, projectID: projectID)
                }) == reference else { throw NativeHistoryNavigationError.sourceMismatch }
                let pageBound = max(1, (reference.byteCount + 4092) / 4093)
                let raw = try MeteredRetrieval.checkedProduct(reference.byteCount, 8) + pageBound
                let value = try MeteredRetrieval.charge(lease: lease, kind: .sourceRead,
                    resources: EpisodeResources(rawSourceBytes: raw, metadataRows: pageBound + 1)) {
                    // A complete authoritative load checks the actual BLOB
                    // length as well as its stored digest. Page sealing alone
                    // would not detect bytes appended beyond a forged count.
                    let sealed = try MeteredRetrieval.authoritative(store: store, lease: lease) {
                        try store.loadCandidate(reference: reference)
                    }
                    var full = Data(), hits: [MemoryHit] = [], offset = 0
                    while offset < reference.byteCount {
                        let page = try MeteredRetrieval.authoritative(store: store, lease: lease) {
                            try store.read(eventID: reference.eventID, offset: offset,
                                length: min(4096, reference.byteCount - offset))
                        }
                        let chunk = Data(page.text.utf8)
                        guard episodeIdentifierEqual(page.eventID, reference.eventID), page.offset == offset,
                              page.totalBytes == reference.byteCount, page.digest == reference.digest,
                              page.status == reference.status, chunk.count == page.byteCount, !chunk.isEmpty,
                              page.nextOffset == (offset + chunk.count < reference.byteCount ? offset + chunk.count : nil) else {
                            throw NativeHistoryNavigationError.sourceMismatch
                        }
                        full.append(chunk)
                        hits.append(MemoryHit(eventID: reference.eventID, conversationID: reference.conversationID,
                            projectID: projectID, role: reference.role, status: reference.status,
                            createdAt: reference.createdAt, digest: reference.digest, totalBytes: reference.byteCount,
                            excerptOffset: offset, excerpt: page.text, sourceTime: reference.sourceTime))
                        offset += chunk.count
                    }
                    guard full.count == reference.byteCount, MeteredRetrieval.digest(full) == reference.digest,
                          let text = String(data: full, encoding: .utf8),
                          full == Data(sealed.text.utf8) else { throw NativeHistoryNavigationError.sourceMismatch }
                    return (reference, text, hits)
                }
                loaded.append(value)
            }
            _ = try lease.checkActive(projectID: projectID)
            return try NativeHistoryNavigation(projectID: projectID, frontier: frontier, loaded: loaded, lease: lease)
        }
    }

    private init(projectID: String, frontier: Int,
                 loaded: [(MemorySourceReference, String, [MemoryHit])], lease: EpisodeLease) throws {
        self.projectID = projectID; sourceFrontier = frontier; self.lease = lease
        let metadata = loaded.map { row -> [String: Any] in
            let ref = row.0
            return ["sequence": ref.sequence, "event_id": ref.eventID, "conversation_id": ref.conversationID,
                "project_id": ref.projectID, "role": ref.role.rawValue, "status": ref.status.rawValue,
                "digest": ref.digest, "byte_count": ref.byteCount,
                "source_time": ref.sourceTime?.object as Any? ?? NSNull()]
        }
        sourceDigest = MeteredRetrieval.digest(try NativeInvestigationJSON.data(metadata))
        var conversationOrder: [Data] = [], byConversation: [Data: [(MemorySourceReference, String, [MemoryHit])]] = [:]
        for row in loaded {
            let key = Data(row.0.conversationID.utf8)
            if byConversation[key] == nil { conversationOrder.append(key) }
            byConversation[key, default: []].append(row)
        }
        for (sessionIndex, key) in conversationOrder.enumerated() {
            let regionID = String(format: "s%06d", sessionIndex)
            var regionBlocks: [String] = [], pending: [Source] = []
            func completeBlock() {
                guard !pending.isEmpty else { return }
                let blockID = String(format: "b%06d", orderedBlockIDs.count)
                let block = Block(id: blockID, regionID: regionID, sourceIDs: pending.map(\.id),
                    hostSourceIDs: pending.map { $0.reference.eventID }, hits: pending.flatMap(\.hits),
                    byteCount: pending.reduce(0) { $0 + $1.reference.byteCount }, modelRecords: pending.map(\.object))
                blocks[blockID] = block; orderedBlockIDs.append(blockID); regionBlocks.append(blockID)
                for source in pending { sourceBlocks[source.id] = blockID }
                var frequency: [String: Int] = [:]
                for source in pending { for term in Self.terms(source.text) { frequency[term, default: 0] += 1 } }
                frequencies[blockID] = frequency
                for term in frequency.keys { documentFrequency[term, default: 0] += 1 }
                pending.removeAll()
            }
            for (turnIndex, row) in byConversation[key, default: []].enumerated() {
                if row.0.role == .human { completeBlock() }
                let sourceID = String(format: "e%06d", sources.count)
                let calendar: Any = row.0.sourceTime.map { ["original_value": $0.originalValue] } ?? NSNull()
                let object: [String: Any] = ["event_id": sourceID, "original_session_id": regionID,
                    "role": row.0.role == .human ? "user" : "assistant", "status": row.0.status.rawValue,
                    "session_index": sessionIndex, "turn_index": turnIndex, "content": row.1, "source_time": calendar]
                let source = Source(id: sourceID, reference: row.0, text: row.1, hits: row.2, object: object)
                sources[sourceID] = source; pending.append(source)
            }
            completeBlock(); nodes[regionID] = Node(children: regionBlocks, blockIDs: regionBlocks)
        }
        blockOrder = Dictionary(uniqueKeysWithValues: orderedBlockIDs.enumerated().map { ($0.element, $0.offset) })
        var layer = conversationOrder.indices.map { String(format: "s%06d", $0) }, group = 0
        while layer.count > 8 {
            var parents: [String] = []
            for start in stride(from: 0, to: layer.count, by: 8) {
                let children = Array(layer[start..<min(layer.count, start + 8)])
                let id = String(format: "g%06d", group); group += 1
                nodes[id] = Node(children: children, blockIDs: children.flatMap { nodes[$0]!.blockIDs }); parents.append(id)
            }
            layer = parents
        }
        nodes[rootRegionID] = Node(children: layer, blockIDs: orderedBlockIDs)
    }

    static func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.utf8.count <= 128 && !stopwords.contains($0) }
    }
    private static let stopwords = Set("a an and are as at be been being but by can could did do does doing for from had has have having he her here hers him his how i if in into is it its just me more most my no not of on or our ours please s say she should so some t tell than that the their theirs them then there these they this those through to too us was we were what when where which who why will with would you your yours about".split(separator: " ").map(String.init))
    private func idf(_ term: String) -> Double { log(1 + (Double(blocks.count) + 0.5) / (Double(documentFrequency[term, default: 0]) + 0.5)) }
    func blockIDs(sourceIDs: [String]) throws -> [String] {
        guard sourceIDs.allSatisfy({ sourceBlocks[$0] != nil }) else { throw NativeHistoryNavigationError.invalidExtraction }
        let wanted = Set(sourceIDs.compactMap { sourceBlocks[$0] })
        return orderedBlockIDs.filter { wanted.contains($0) }
    }
    func modelRecords(blockIDs: [String]) throws -> [[String: Any]] {
        let chosen = try validatedBlocks(blockIDs)
        return orderedBlockIDs.filter { chosen.contains($0) }.flatMap { blocks[$0]!.modelRecords }
    }
    func hostSourceIDs(sourceIDs: [String]) throws -> [String] {
        guard sourceIDs.allSatisfy({ sources[$0] != nil }) else { throw NativeHistoryNavigationError.invalidExtraction }
        return sourceIDs.map { sources[$0]!.reference.eventID }
    }
    func descriptor(blockIDs: [String]) throws -> Data {
        let chosen = try validatedBlocks(blockIDs)
        return try NativeInvestigationJSON.data(["version": Self.version, "project_id": projectID,
            "source_frontier": sourceFrontier, "source_sha256": sourceDigest,
            "blocks": orderedBlockIDs.filter { chosen.contains($0) }.map { id in
                ["block_id": id, "sources": blocks[id]!.sourceIDs.map { sourceID -> [String: Any] in
                    let reference = sources[sourceID]!.reference
                    return ["event_id": reference.eventID, "digest": reference.digest, "bytes": reference.byteCount,
                        "offsets": sources[sourceID]!.hits.map { ["offset": $0.excerptOffset, "length": $0.excerpt.utf8.count] }]
                }] as [String: Any]
            }])
    }
    private func validatedBlocks(_ ids: [String]) throws -> Set<String> {
        guard ids.count <= blocks.count, Set(ids).count == ids.count, ids.allSatisfy({ blocks[$0] != nil }) else {
            throw NativeHistoryNavigationError.invalidRegion
        }
        return Set(ids)
    }
    private func offset(_ cursor: String?, operation: String, binding: String, total: Int) throws -> Int {
        guard let cursor else { return 0 }
        guard let value = cursors[cursor], value.operation == operation, value.binding == binding,
              value.offset <= total else { throw NativeHistoryNavigationError.invalidCursor }
        return value.offset
    }
    private func next(_ operation: String, binding: String, offset: Int, total: Int) -> String? {
        guard offset < total else { return nil }
        let id = UUID().uuidString; cursors[id] = Cursor(operation: operation, binding: binding, offset: offset); return id
    }
    private func page(_ ids: [String], operation: String, binding: String, cursor: String?, pageSize: Int) throws -> Page {
        _ = try lease.checkActive(projectID: projectID)
        guard (1...128).contains(pageSize) else { throw NativeHistoryNavigationError.invalidQuery }
        let start = try offset(cursor, operation: operation, binding: binding, total: ids.count)
        let selected = Array(ids[start..<min(ids.count, start + pageSize)]), end = start + selected.count
        let continuation = next(operation, binding: binding, offset: end, total: ids.count)
        let coverage = continuation == nil ? "candidate_page_complete" : "candidate_page_partial"
        let object: [String: Any] = ["action": operation, "candidate_block_ids": selected,
            "candidate_blocks_available": ids.count, "candidate_offset": start,
            "next_cursor": continuation as Any? ?? NSNull(), "coverage": coverage,
            "full_snapshot_searched": operation == "search", "model_delivery_established": false,
            "snapshot_sha256": sourceDigest]
        return Page(blockIDs: selected, nextCursor: continuation, coverage: coverage, object: object)
    }
    func search(query: String, cursor: String? = nil, pageSize: Int = 16,
                timeFilter: NativeInvestigationTimeFilter? = nil) throws -> Page {
        guard query.utf8.count <= 16_384, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeHistoryNavigationError.invalidQuery
        }
        let queryTerms = Set(Self.terms(query))
        guard !queryTerms.isEmpty, queryTerms.count <= 256 else { throw NativeHistoryNavigationError.invalidQuery }
        var scores: [String: Double] = [:]
        for id in orderedBlockIDs {
            if let timeFilter, !blocks[id]!.sourceIDs.contains(where: { timeFilter.includes(sources[$0]!.reference.sourceTime) }) { continue }
            let frequency = frequencies[id]!, matches = queryTerms.filter { frequency[$0, default: 0] > 0 }
            guard !matches.isEmpty else { continue }
            let relevance = matches.reduce(0.0) { $0 + idf($1) * (1 + min(2, log(Double(frequency[$1]!)))) }
            scores[id] = relevance / sqrt(1 + Double(blocks[id]!.byteCount) / 512)
        }
        let ids = scores.keys.sorted { scores[$0]! == scores[$1]! ? blockOrder[$0]! > blockOrder[$1]! : scores[$0]! > scores[$1]! }
        let binding = MeteredRetrieval.digest(try NativeInvestigationJSON.data(["query": query,
            "time_filter": timeFilter?.object as Any? ?? NSNull()]))
        return try page(ids, operation: "search", binding: binding, cursor: cursor, pageSize: pageSize)
    }
    func zoom(regionID: String, cursor: String? = nil, pageSize: Int = 16) throws -> Page {
        guard let ids = nodes[regionID]?.blockIDs ?? blocks[regionID].map({ [$0.id] }) else {
            throw NativeHistoryNavigationError.invalidRegion
        }
        return try page(ids, operation: "zoom", binding: regionID, cursor: cursor, pageSize: pageSize)
    }
    private func describe(_ id: String) -> [String: Any] {
        let ids = nodes[id]?.blockIDs ?? [id]
        var terms: [String: Int] = [:], dateValues: [String] = [], unknownDates = 0
        for blockID in ids {
            for (term, count) in frequencies[blockID, default: [:]] { terms[term, default: 0] += count }
            for sourceID in blocks[blockID]!.sourceIDs {
                if let date = sources[sourceID]!.reference.sourceTime { dateValues.append(date.originalValue) } else { unknownDates += 1 }
            }
        }
        let cues = terms.keys.sorted {
            let a = (1 + log(Double(terms[$0]!))) * idf($0), b = (1 + log(Double(terms[$1]!))) * idf($1)
            return a == b ? $0 < $1 : a > b
        }.prefix(12)
        let links = cues.map { term -> [String: Any] in
            let matching = ids.filter { frequencies[$0]?[term] != nil }
            return ["cue": term, "block_ids": Array(matching.prefix(3))]
        }
        var seen = Set<String>(); let dates = dateValues.filter { seen.insert($0).inserted }
        return ["region_id": id, "topic_cues": Array(cues), "cue_links": links,
            "cues_are_literal_terms_not_facts": true, "complete_exchange_blocks": ids.count,
            "source_records": ids.reduce(0) { $0 + blocks[$1]!.sourceIDs.count },
            "block_links": Array(ids.prefix(8)), "block_links_are_sample": ids.count > 8,
            "available_dates": Array(dates.prefix(8)), "available_dates_are_sample": dates.count > 8,
            "unknown_date_records": unknownDates]
    }
    func overview(regionID: String? = nil, cursor: String? = nil, pageSize: Int = 8) throws -> [String: Any] {
        _ = try lease.checkActive(projectID: projectID)
        let id = regionID ?? rootRegionID
        guard let node = nodes[id], (1...128).contains(pageSize) else { throw NativeHistoryNavigationError.invalidRegion }
        let start = try offset(cursor, operation: "overview", binding: id, total: node.children.count)
        let selected = Array(node.children[start..<min(node.children.count, start + pageSize)])
        let continuation = next("overview", binding: id, offset: start + selected.count, total: node.children.count)
        var header = describe(rootRegionID)
        header["aggregate_covers_all_original_records"] = true; header["original_record_details_included"] = false
        header["scope"] = "accepted_project_at_fixed_source_frontier"
        header["snapshot_sha256"] = sourceDigest; header["source_frontier"] = sourceFrontier
        let object: [String: Any] = ["header": header, "region_id": id, "entries": selected.map(describe),
            "coverage": continuation == nil ? "navigation_page_complete" : "navigation_page_partial",
            "next_cursor": continuation as Any? ?? NSNull()]
        guard try NativeInvestigationJSON.data(object).count <= 65_536 else { throw NativeHistoryNavigationError.snapshotLimit }
        return object
    }
}

struct NativeInvestigationTimeFilter: Equatable {
    let start: String?
    let end: String?
    let includeUnknown: Bool
    var object: [String: Any] { ["start": start as Any? ?? NSNull(), "end": end as Any? ?? NSNull(), "include_unknown": includeUnknown] }
    func includes(_ value: EventSourceTime?) -> Bool {
        guard let value else { return includeUnknown }
        let day = String(value.value.prefix(10))
        return (start == nil || day >= start!) && (end == nil || day <= end!)
    }
    static func parse(_ value: Any) throws -> Self? {
        if value is NSNull { return nil }
        guard let row = value as? [String: Any], Set(row.keys) == ["start", "end", "include_unknown"],
              let unknown = row["include_unknown"] as? NSNumber,
              CFGetTypeID(unknown) == CFBooleanGetTypeID() else { throw NativeHistoryNavigationError.invalidPlan }
        func day(_ value: Any?) throws -> String? {
            if value is NSNull { return nil }
            guard let text = value as? String, text.utf8.count == 10,
                  let normalized = try? EventSourceTime.normalize(text), normalized.value == text,
                  normalized.precision == "day" else { throw NativeHistoryNavigationError.invalidPlan }
            return text
        }
        let start = try day(row["start"]), end = try day(row["end"])
        guard start == nil || end == nil || start! <= end! else { throw NativeHistoryNavigationError.invalidPlan }
        return Self(start: start, end: end, includeUnknown: unknown.boolValue)
    }
}

struct NativeInvestigationPlan {
    let action: String
    let query: String
    let regionID: String
    let cursor: String?
    let timeFilter: NativeInvestigationTimeFilter?
    let pinBlockIDs: [String]
    let missingFacts: [String]
    static func parse(_ text: String) throws -> Self {
        do {
            let row = try NativeInvestigationJSON.object(text)
            guard Set(row.keys) == ["action", "query", "region_id", "cursor", "time_filter", "pin_block_ids", "missing_facts"],
                  let action = row["action"] as? String, ["search", "zoom", "overview", "finish"].contains(action),
                  let query = row["query"] as? String, query.utf8.count <= 16_384,
                  let region = row["region_id"] as? String, region.utf8.count <= 128 else { throw NativeHistoryNavigationError.invalidPlan }
            let cursor: String?
            if row["cursor"] is NSNull { cursor = nil }
            else { guard let value = row["cursor"] as? String, !value.isEmpty, value.utf8.count <= 2048 else { throw NativeHistoryNavigationError.invalidPlan }; cursor = value }
            let filter = try NativeInvestigationTimeFilter.parse(row["time_filter"]!)
            let pins = try NativeInvestigationJSON.strings(row["pin_block_ids"], maximum: 128, bytes: 128)
            let missing = try NativeInvestigationJSON.strings(row["missing_facts"], maximum: 16, bytes: 512)
            guard (action == "search" && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && region.isEmpty)
                || (action == "zoom" && query.isEmpty && !region.isEmpty && filter == nil)
                || (action == "overview" && query.isEmpty && filter == nil)
                || (action == "finish" && query.isEmpty && region.isEmpty && filter == nil && cursor == nil) else { throw NativeHistoryNavigationError.invalidPlan }
            return Self(action: action, query: query, regionID: region, cursor: cursor, timeFilter: filter, pinBlockIDs: pins, missingFacts: missing)
        } catch { throw NativeHistoryNavigationError.invalidPlan }
    }
}

struct NativeInvestigationExtraction {
    let sourceIDs: [String]
    let facts: [[String: Any]]
    let unresolved: [String]
    static func parse(_ text: String, navigation: NativeHistoryNavigation, selectedBlockIDs: [String]) throws -> Self {
        do {
            let selected = try navigation.modelRecords(blockIDs: selectedBlockIDs)
            let sources = Dictionary(uniqueKeysWithValues: selected.map { ($0["event_id"] as! String, $0["content"] as! String) })
            let row = try NativeInvestigationJSON.object(text)
            guard Set(row.keys) == ["facts", "unresolved"], let facts = row["facts"] as? [[String: Any]], facts.count <= 32 else { throw NativeHistoryNavigationError.invalidExtraction }
            let unresolved = try NativeInvestigationJSON.strings(row["unresolved"], maximum: 16, bytes: 512)
            var all: [String] = []
            for fact in facts {
                guard Set(fact.keys) == ["claim", "source_ids", "quotes"], let claim = fact["claim"] as? String,
                      !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, claim.utf8.count <= 1024,
                      let quotes = fact["quotes"] as? [[String: Any]], !quotes.isEmpty, quotes.count <= 32 else { throw NativeHistoryNavigationError.invalidExtraction }
                let ids = try NativeInvestigationJSON.strings(fact["source_ids"], maximum: 16, bytes: 128)
                guard !ids.isEmpty, ids.allSatisfy({ sources[$0] != nil }) else { throw NativeHistoryNavigationError.invalidExtraction }
                var quoted = Set<String>()
                for quote in quotes {
                    guard Set(quote.keys) == ["source_id", "text"], let id = quote["source_id"] as? String, ids.contains(id),
                          let text = quote["text"] as? String, !text.isEmpty, text.utf8.count <= 2048,
                          Data(sources[id]!.utf8).range(of: Data(text.utf8)) != nil else { throw NativeHistoryNavigationError.invalidExtraction }
                    quoted.insert(id)
                }
                guard quoted == Set(ids) else { throw NativeHistoryNavigationError.invalidExtraction }
                for id in ids where !all.contains(id) { all.append(id) }
            }
            return Self(sourceIDs: all, facts: facts, unresolved: unresolved)
        } catch { throw NativeHistoryNavigationError.invalidExtraction }
    }
}

enum NativeInvestigationJSON {
    static func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) }
    static func object(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        guard data.count <= 131_072 else { throw NativeHistoryNavigationError.invalidPlan }
        var scanner = KeyScanner(bytes: Array(data)); try scanner.scan()
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeHistoryNavigationError.invalidPlan }
        return value
    }
    static func strings(_ value: Any?, maximum: Int, bytes: Int) throws -> [String] {
        guard let values = value as? [String], values.count <= maximum, Set(values).count == values.count,
              values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= bytes }) else { throw NativeHistoryNavigationError.invalidPlan }
        return values
    }
    /// Duplicate keys, including escaped spellings, must fail before Foundation
    /// selects a value. Syntax/number/string validation belongs to its decoder.
    private struct KeyScanner {
        let bytes: [UInt8]
        var position = 0
        mutating func scan() throws { try value(depth: 0); whitespace(); guard position == bytes.count else { throw NativeHistoryNavigationError.invalidPlan } }
        mutating func whitespace() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
        mutating func take(_ byte: UInt8) throws { whitespace(); guard position < bytes.count && bytes[position] == byte else { throw NativeHistoryNavigationError.invalidPlan }; position += 1 }
        mutating func string() throws -> String {
            whitespace(); let start = position; try take(34)
            while position < bytes.count {
                let byte = bytes[position]; position += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) }
                if byte == 92 { guard position < bytes.count else { throw NativeHistoryNavigationError.invalidPlan }; position += 1 }
            }
            throw NativeHistoryNavigationError.invalidPlan
        }
        mutating func value(depth: Int) throws {
            whitespace(); guard depth <= 32 && position < bytes.count else { throw NativeHistoryNavigationError.invalidPlan }
            switch bytes[position] {
            case 123:
                position += 1; whitespace(); var keys = Set<Data>()
                if position < bytes.count && bytes[position] == 125 { position += 1; return }
                while true {
                    guard keys.insert(Data(try string().utf8)).inserted else { throw NativeHistoryNavigationError.invalidPlan }
                    try take(58); try value(depth: depth + 1); whitespace()
                    guard position < bytes.count else { throw NativeHistoryNavigationError.invalidPlan }
                    if bytes[position] == 125 { position += 1; return }; try take(44)
                }
            case 91:
                position += 1; whitespace()
                if position < bytes.count && bytes[position] == 93 { position += 1; return }
                while true {
                    try value(depth: depth + 1); whitespace(); guard position < bytes.count else { throw NativeHistoryNavigationError.invalidPlan }
                    if bytes[position] == 93 { position += 1; return }; try take(44)
                }
            case 34: _ = try string()
            default:
                let start = position
                while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) { position += 1 }
                guard position > start else { throw NativeHistoryNavigationError.invalidPlan }
            }
        }
    }
}
