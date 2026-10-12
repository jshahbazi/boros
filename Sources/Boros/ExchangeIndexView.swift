import Foundation

/// Optional timing and volume sink for diagnostics; product paths pass nil.
/// Contains counts and durations only.
final class ExchangeIndexDiagnostics {
    var catchUpEvents = 0
    var snapshotMilliseconds = 0.0
    var recomputeMilliseconds = 0.0
    var rankMilliseconds = 0.0
    var windowMilliseconds = 0.0
    var postingRows = 0
    var postingEntries = 0
    var blockLogRows = 0
    var matchedBlocks = 0
    var affectedConversations = 0
    var recomputedSources = 0
    var windows = 0
    var loadedSources = 0

    var dictionary: [String: Any] {
        ["catch_up_events": catchUpEvents, "snapshot_milliseconds": snapshotMilliseconds,
         "recompute_milliseconds": recomputeMilliseconds, "rank_milliseconds": rankMilliseconds,
         "window_milliseconds": windowMilliseconds, "posting_rows": postingRows, "posting_entries": postingEntries,
         "block_log_rows": blockLogRows, "matched_blocks": matchedBlocks, "affected_conversations": affectedConversations,
         "recomputed_sources": recomputedSources, "windows": windows, "loaded_sources": loadedSources]
    }
}

/// One turn's ranked corpus over the persistent exchange index.
///
/// The snapshot (catch-up, project inventory, query-term statistics, the
/// block log and the excluded sources' conversations) is read under the store
/// owner mutex, so it describes exactly the project's sources through one
/// frontier. Excluding the accepted request and recent sources changes block
/// boundaries only in their own conversations: from the block holding the
/// earliest excluded source (or the block before it when that source starts
/// its block) to the frontier. Those blocks are rebuilt in memory from their
/// remaining sources, exactly as the per-turn rebuild forms them, and their
/// stored statistics are subtracted. Ranking uses the shared scoring.
///
/// Packing then reads only what it touches: members and neighbors of ranked
/// blocks in rank-ordered windows (32, 64, 128 ... blocks), each a declared
/// metadata read plus a verified source read. A loaded source whose store
/// metadata differs from its indexed row fails closed.
final class ExchangeIndexView: ExchangeCorpus {
    typealias Failure = ExchangeBlockQuery.Failure
    typealias Row = ExchangeIndexStore.SourceRow

    struct Block {
        let start: Int
        /// Conversation order: its first non-excluded sequence.
        let order: Int
        let bytes: Int
        let sources: Int
        /// Term counts per query-term position.
        let frequency: [Int]
        /// Members of blocks rebuilt in memory; stored blocks load lazily.
        let members: [Int]?
    }

    struct Affected {
        let conversationID: String
        let rangeStart: Int
        let previousBeforeRange: Int?
        let remaining: [Int]
    }

    let frontier: Int
    let sourceCount: Int
    let blockCount: Int
    let blocks: [Block]
    let ranked: [ExchangeBlockQuery.RankedBlock]
    private let store: MemoryStore
    private let lease: EpisodeLease?
    private let projectID: String
    private let generation: Int
    private let affected: [Data: Affected]
    private let diagnostics: ExchangeIndexDiagnostics?
    private var rankOf: [Int]
    private var loadedRanks = 0
    private var windowSize = ExchangeBlockQuery.ValuePacking.candidateBlockDepth
    private var membersOf: [Int: [Int]] = [:]
    private var rows: [Int: Row]
    private var sources: [Int: (reference: MemorySourceReference, text: String)]
    private var previousOf: [Int: Int?] = [:]
    private var nextOf: [Int: Int?] = [:]
    /// Lowest rank whose block lists the source as a member or neighbor.
    private var sourceRank: [Int: Int] = [:]
    private var sourcesByRank: [Int: [Int]] = [:]
    private var missBatch = ExchangeBlockQuery.ValuePacking.candidateBlockDepth

    private struct Snapshot {
        let generation: Int
        let project: ExchangeIndexStore.ProjectRow
        let documentFrequency: [Int]
        let postings: [[Int: Int]]
        let attributes: [Int: ExchangeIndexStore.BlockAttributes]
        let excluded: [Row]
        let conversations: [(conversationID: String, first: Int, rangeStart: Int, previous: Row?, rows: [Row], excluded: Set<Int>)]
    }

    private init(store: MemoryStore, lease: EpisodeLease?, projectID: String, generation: Int, frontier: Int, sourceCount: Int,
                 blockCount: Int, blocks: [Block], ranked: [ExchangeBlockQuery.RankedBlock], affected: [Data: Affected],
                 rows: [Int: Row], sources: [Int: (reference: MemorySourceReference, text: String)],
                 diagnostics: ExchangeIndexDiagnostics?) {
        self.store = store; self.lease = lease; self.projectID = projectID; self.generation = generation
        self.frontier = frontier; self.sourceCount = sourceCount; self.blockCount = blockCount
        self.blocks = blocks; self.ranked = ranked; self.affected = affected; self.rows = rows; self.sources = sources
        self.diagnostics = diagnostics
        rankOf = Array(repeating: -1, count: blocks.count)
        for (rank, entry) in ranked.enumerated() { rankOf[entry.block] = rank }
    }

    static func open(store: MemoryStore, projectID: String, query: ExchangeBlockQuery.Query, excluding: ExactSourceIDs,
                     lease: EpisodeLease?, diagnostics: ExchangeIndexDiagnostics?,
                     maximumSources: Int = ExchangeBlockQuery.persistentMaximumSources,
                     maximumCatchUp: Int = ExchangeIndexStore.maximumTurnCatchUp) throws -> ExchangeIndexView {
        var started = DispatchTime.now().uptimeNanoseconds
        func lap() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds, value = Double(now - started) / 1_000_000
            started = now; return value
        }
        let terms = Array(query.terms)
        let snapshot = try store.withExchangeIndex(lease: lease, create: true) { index in
            try Self.snapshot(index: index, store: store, projectID: projectID, terms: terms, excluding: excluding,
                lease: lease, diagnostics: diagnostics, maximumSources: maximumSources, maximumCatchUp: maximumCatchUp)
        }
        diagnostics?.snapshotMilliseconds = lap()
        let frontier = snapshot.project.maximumSequence

        // Rebuild the excluded conversations' trailing blocks in memory.
        var rows: [Int: Row] = [:], remaining: [Int] = [], remainingBytes = 0
        for conversation in snapshot.conversations {
            if let previous = conversation.previous { rows[previous.sequence] = previous }
            for row in conversation.rows {
                rows[row.sequence] = row
                if !conversation.excluded.contains(row.sequence) { remaining.append(row.sequence); remainingBytes += row.byteCount }
            }
        }
        var sources: [Int: (reference: MemorySourceReference, text: String)] = [:]
        if !remaining.isEmpty {
            // Two declared passes, as in the rebuild: integrity load and term scan.
            let raw = try MeteredRetrieval.checkedProduct(remainingBytes, 2) + remaining.count
            let loaded = try MeteredRetrieval.charge(lease: lease, kind: .sourceRead,
                resources: EpisodeResources(rawSourceBytes: raw, metadataRows: remaining.count)) {
                try MeteredRetrieval.authoritative(store: store, lease: lease) { try store.exchangeIndexLoad(sequences: remaining) }
            }
            for sequence in remaining {
                guard let row = rows[sequence], let value = loaded[sequence], Self.matches(row, value.reference, projectID: projectID) else {
                    throw Failure.indexMismatch
                }
                sources[sequence] = value
            }
        }
        let positions = Dictionary(uniqueKeysWithValues: terms.enumerated().map { ($1, $0) })
        var storedAffected = Set<Int>(), rebuilt: [Block] = [], affected: [Data: Affected] = [:]
        for conversation in snapshot.conversations {
            storedAffected.formUnion(conversation.rows.map(\.block))
            let kept = conversation.rows.filter { !conversation.excluded.contains($0.sequence) }
            affected[Data(conversation.conversationID.utf8)] = Affected(conversationID: conversation.conversationID,
                rangeStart: conversation.rangeStart, previousBeforeRange: conversation.previous?.sequence, remaining: kept.map(\.sequence))
            guard let firstKept = kept.first else { continue }
            let order = conversation.rangeStart == conversation.first ? firstKept.sequence : conversation.first
            var pending: [Row] = []
            func complete() throws {
                guard let lead = pending.first else { return }
                var frequency: [String: Int] = [:]
                for row in pending {
                    guard let text = sources[row.sequence]?.text else { throw Failure.indexMismatch }
                    for term in ExchangeBlockQuery.terms(text) { frequency[term, default: 0] += 1 }
                }
                rebuilt.append(Block(start: lead.sequence, order: order, bytes: pending.reduce(0) { $0 + $1.byteCount },
                    sources: pending.count, frequency: terms.map { frequency[$0, default: 0] }, members: pending.map(\.sequence)))
                pending.removeAll()
            }
            for row in kept {
                if row.role == .human { try complete() }
                pending.append(row)
            }
            try complete()
        }
        diagnostics?.affectedConversations = snapshot.conversations.count
        diagnostics?.recomputedSources = remaining.count
        diagnostics?.recomputeMilliseconds = lap()

        // Corrected statistics and the matched blocks in corpus order.
        let blockCount = snapshot.project.blockCount - storedAffected.count + rebuilt.count
        var documentFrequency = snapshot.documentFrequency
        for position in terms.indices {
            documentFrequency[position] -= snapshot.postings[position].keys.filter { storedAffected.contains($0) }.count
            documentFrequency[position] += rebuilt.filter { $0.frequency[position] > 0 }.count
            guard documentFrequency[position] >= 0 else { throw Failure.indexMismatch }
        }
        var matched: [Int: [Int]] = [:]
        for (position, postings) in snapshot.postings.enumerated() {
            for (block, count) in postings where !storedAffected.contains(block) {
                matched[block, default: Array(repeating: 0, count: terms.count)][position] = count
            }
        }
        var blocks: [Block] = []
        blocks.reserveCapacity(matched.count + rebuilt.count)
        for (start, frequency) in matched {
            guard let attributes = snapshot.attributes[start] else { throw Failure.indexMismatch }
            blocks.append(Block(start: start, order: attributes.conversationFirst, bytes: attributes.bytes,
                sources: attributes.sources, frequency: frequency, members: nil))
        }
        blocks += rebuilt.filter { $0.frequency.contains { $0 > 0 } }
        blocks.sort { $0.order != $1.order ? $0.order < $1.order : $0.start < $1.start }
        let ranked = ExchangeBlockQuery.rank(query, blockCount: blocks.count, bytes: { blocks[$0].bytes },
            frequency: { blocks[$0].frequency[positions[$1]!] },
            idf: { ExchangeBlockQuery.idf(blockCount: blockCount, documentFrequency: documentFrequency[positions[$0]!]) })
        diagnostics?.matchedBlocks = blocks.count
        diagnostics?.rankMilliseconds = lap()
        return ExchangeIndexView(store: store, lease: lease, projectID: projectID, generation: snapshot.generation,
            frontier: frontier, sourceCount: snapshot.project.sourceCount - snapshot.excluded.count, blockCount: blockCount,
            blocks: blocks, ranked: ranked, affected: affected, rows: rows, sources: sources, diagnostics: diagnostics)
    }

    /// Runs under the owner mutex with the sidecar open.
    private static func snapshot(index: ExchangeIndexStore, store: MemoryStore, projectID: String, terms: [String],
                                 excluding: ExactSourceIDs, lease: EpisodeLease?, diagnostics: ExchangeIndexDiagnostics?,
                                 maximumSources: Int, maximumCatchUp: Int) throws -> Snapshot {
        let pending = try MeteredRetrieval.metadata(lease: lease, maximumRows: 1) {
            try store.exchangeIndexPendingInventory(afterSequence: index.watermark)
        }
        guard pending.count <= maximumCatchUp else { throw Failure.indexUnavailable }
        if pending.count > 0 {
            let raw = try MeteredRetrieval.checkedProduct(pending.bytes, 2) + pending.count
            let receipt = try MeteredRetrieval.charge(lease: lease, kind: .sourceRead,
                resources: EpisodeResources(rawSourceBytes: raw, metadataRows: pending.count)) {
                try index.catchUp(store: store, maximumEvents: pending.count)
            }
            guard receipt.events == pending.count else { throw Failure.indexMismatch }
            diagnostics?.catchUpEvents = receipt.events
        }
        let base = try MeteredRetrieval.metadata(lease: lease, maximumRows: 2 + terms.count + 2 * excluding.count) {
            () -> (ExchangeIndexStore.ProjectRow, [ExchangeIndexStore.TermRow?], [Row]) in
            let project = try index.project(projectID)
            let inventory = try store.exchangeIndexProjectInventory(projectID: projectID)
            guard inventory.count == project.sourceCount, inventory.maximum == project.maximumSequence else { throw Failure.indexMismatch }
            guard project.sourceCount <= maximumSources else { throw Failure.snapshotLimit }
            let termRows = try terms.map { try index.term(projectID, $0.precomposedStringWithCanonicalMapping) }
            let excluded = try store.exchangeIndexLocate(eventIDs: excluding).filter {
                episodeIdentifierEqual($0.projectID, projectID) && $0.sequence <= project.maximumSequence
            }.map { located -> Row in
                guard let row = try index.source(located.sequence), episodeIdentifierEqual(row.eventID, located.eventID),
                      episodeIdentifierEqual(row.projectID, projectID) else { throw Failure.indexMismatch }
                return row
            }
            return (project, termRows, excluded)
        }
        let (project, termRows, excluded) = base
        let frontier = project.maximumSequence

        // Conversations with excluded sources, in first-exclusion order.
        var order: [Data] = [], grouped: [Data: [Row]] = [:]
        for row in excluded.sorted(by: { $0.sequence < $1.sequence }) {
            let key = Data(row.conversationID.utf8)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }
        var conversations: [(conversationID: String, first: Int, rangeStart: Int, previous: Row?, rows: [Row], excluded: Set<Int>)] = []
        for key in order {
            let group = grouped[key]!, conversationID = group[0].conversationID
            let excludedSequences = Set(group.map(\.sequence))
            let (rangeStart, first, count) = try MeteredRetrieval.metadata(lease: lease, maximumRows: 3) { () -> (Int, Int, Int) in
                var start = group[0].block
                if excludedSequences.contains(start), let previous = try index.preceding(conversationID: conversationID, before: start) {
                    start = previous.block
                }
                guard let first = try index.conversationFirst(conversationID) else { throw Failure.indexMismatch }
                return (start, first, try index.count(conversationID: conversationID, from: start, through: frontier))
            }
            let (rows, previous) = try MeteredRetrieval.metadata(lease: lease, maximumRows: count + 1) {
                (try index.sources(conversationID: conversationID, from: rangeStart, through: frontier),
                 try index.preceding(conversationID: conversationID, before: rangeStart))
            }
            guard rows.count == count, rows.first?.sequence == rangeStart,
                  rows.allSatisfy({ episodeIdentifierEqual($0.projectID, projectID) }) else { throw Failure.indexMismatch }
            conversations.append((conversationID, first, rangeStart, previous, rows, excludedSequences))
        }

        // Query-term postings and the project's block log.
        let chunks = termRows.reduce(0) { $0 + ($1?.chunks ?? 0) } + project.blockChunks
        let (postings, attributes) = try MeteredRetrieval.charge(lease: lease,
            resources: EpisodeResources(rawSourceBytes: try MeteredRetrieval.checkedProduct(chunks, ExchangeIndexStore.declaredChunkBytes),
                metadataRows: chunks)) { () -> ([[Int: Int]], [Int: ExchangeIndexStore.BlockAttributes]) in
            var postings: [[Int: Int]] = [], needed = Set<Int>()
            for row in termRows {
                guard let row else { postings.append([:]); continue }
                let read = try index.postings(row)
                diagnostics?.postingRows += read.rows; diagnostics?.postingEntries += read.entries
                postings.append(read.frequency)
                needed.formUnion(read.frequency.keys)
            }
            let log = try index.blockLog(projectID, chunks: project.blockChunks, only: needed)
            diagnostics?.blockLogRows = log.rows
            guard log.created == project.blockCount, log.blocks.count == needed.count else { throw Failure.indexMismatch }
            return (postings, log.blocks)
        }
        return Snapshot(generation: index.generation, project: project,
            documentFrequency: termRows.map { $0?.documentFrequency ?? 0 }, postings: postings, attributes: attributes,
            excluded: excluded, conversations: conversations)
    }

    private static func matches(_ row: Row, _ reference: MemorySourceReference, projectID: String) -> Bool {
        reference.sequence == row.sequence && episodeIdentifierEqual(reference.eventID, row.eventID)
            && episodeIdentifierEqual(reference.projectID, row.projectID) && episodeIdentifierEqual(reference.projectID, projectID)
            && episodeIdentifierEqual(reference.conversationID, row.conversationID) && reference.role == row.role
            && reference.byteCount == row.byteCount && reference.digest == row.digest
    }

    // MARK: ExchangeCorpus

    func members(_ block: Int) throws -> [Int] {
        if let known = membersOf[block] { return known }
        guard blocks.indices.contains(block), rankOf[block] >= 0 else { throw Failure.indexMismatch }
        try loadWindows(through: rankOf[block])
        guard let known = membersOf[block] else { throw Failure.indexMismatch }
        return known
    }

    func reference(_ source: Int) throws -> MemorySourceReference { try loaded(source).reference }
    func text(_ source: Int) throws -> String { try loaded(source).text }
    func role(_ source: Int) throws -> MemoryRole { try row(source).role }
    func byteCount(_ source: Int) throws -> Int { try row(source).byteCount }
    func eventID(_ source: Int) throws -> String { try row(source).eventID }

    func minimumCost(_ source: Int, selectionVersion: String) throws -> (spans: Int, tokens: Int) {
        let row = try row(source)
        return try ExchangeBlockQuery.minimumCost(eventID: row.eventID, conversationID: row.conversationID, role: row.role,
            byteCount: row.byteCount, digest: row.digest, selectionVersion: selectionVersion)
    }

    func previous(_ source: Int) throws -> Int? {
        if let known = previousOf[source] { return known }
        let value = try neighbors([source], before: true)[source] ?? nil
        previousOf[source] = value
        return value
    }

    func next(_ source: Int) throws -> Int? {
        if let known = nextOf[source] { return known }
        let value = try neighbors([source], before: false)[source] ?? nil
        nextOf[source] = value
        return value
    }

    private func row(_ source: Int) throws -> Row {
        guard let row = rows[source] else { throw Failure.indexMismatch }
        return row
    }

    /// Payloads load lazily: a miss loads every unloaded member and neighbor
    /// of the ranked blocks from its rank onward (32 ranks, doubling with each
    /// miss to 4,096), in one declared, verified source read.
    private func loaded(_ source: Int) throws -> (reference: MemorySourceReference, text: String) {
        if let value = sources[source] { return value }
        var batch = [source]
        if let rank = sourceRank[source] {
            var seen = Set(batch)
            for next in rank..<min(ranked.count, rank + missBatch) {
                for member in sourcesByRank[next] ?? [] where sources[member] == nil && seen.insert(member).inserted { batch.append(member) }
            }
        }
        try load(batch.sorted())
        missBatch = min(missBatch * 2, 4_096)
        guard let value = sources[source] else { throw Failure.indexMismatch }
        return value
    }

    private func assign(_ source: Int, rank: Int) {
        if let known = sourceRank[source], known <= rank { return }
        sourceRank[source] = rank
        sourcesByRank[rank, default: []].append(source)
    }

    /// Loads indexed metadata (no payloads) for rank-ordered windows until
    /// `rank` is covered: members of every block and the neighbors of each
    /// block's first and last member.
    private func loadWindows(through rank: Int) throws {
        while loadedRanks <= rank {
            let started = DispatchTime.now().uptimeNanoseconds
            let range = loadedRanks..<min(ranked.count, loadedRanks + windowSize)
            guard !range.isEmpty else { throw Failure.indexMismatch }
            let positions = range.map { ranked[$0].block }
            let stored = positions.filter { blocks[$0].members == nil }
            let declared = stored.reduce(0) { $0 + blocks[$1].sources } + 4 * positions.count
            try MeteredRetrieval.metadata(lease: lease, maximumRows: declared) {
                try store.withExchangeIndex(lease: lease, create: false) { index in
                    guard index.generation == generation else { throw Failure.indexMismatch }
                    var grouped: [Int: [Int]] = [:]
                    for row in try index.members(blocks: stored.map { blocks[$0].start }, through: frontier) {
                        guard episodeIdentifierEqual(row.projectID, projectID), row.sequence <= frontier else { throw Failure.indexMismatch }
                        rows[row.sequence] = row
                        grouped[row.block, default: []].append(row.sequence)
                    }
                    for (offset, position) in positions.enumerated() {
                        let members = blocks[position].members ?? grouped[blocks[position].start] ?? []
                        guard members.count == blocks[position].sources, members.first == blocks[position].start else { throw Failure.indexMismatch }
                        membersOf[position] = members
                        for member in members { assign(member, rank: range.lowerBound + offset) }
                    }
                    let firsts = positions.map { membersOf[$0]!.first! }.filter { previousOf[$0] == nil }
                    let lasts = positions.map { membersOf[$0]!.last! }.filter { nextOf[$0] == nil }
                    for (source, value) in try neighborsLocked(index, firsts, before: true) { previousOf[source] = value }
                    for (source, value) in try neighborsLocked(index, lasts, before: false) { nextOf[source] = value }
                }
            }
            for (offset, position) in positions.enumerated() {
                let members = membersOf[position]!
                if let value = previousOf[members.first!] ?? nil { assign(value, rank: range.lowerBound + offset) }
                if let value = nextOf[members.last!] ?? nil { assign(value, rank: range.lowerBound + offset) }
            }
            loadedRanks = range.upperBound
            windowSize = min(windowSize * 2, 4_096)
            diagnostics?.windows += 1
            diagnostics?.windowMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
    }

    /// One declared lookup outside a window.
    private func neighbors(_ sequences: [Int], before: Bool) throws -> [Int: Int?] {
        guard !sequences.isEmpty else { return [:] }
        return try MeteredRetrieval.metadata(lease: lease, maximumRows: 2 * sequences.count) {
            try store.withExchangeIndex(lease: lease, create: false) { index in
                guard index.generation == generation else { throw Failure.indexMismatch }
                return try neighborsLocked(index, sequences, before: before)
            }
        }
    }

    /// Same-conversation neighbors among this turn's sources: excluded
    /// sources are skipped and later publications are beyond the frontier.
    /// Sources outside excluded conversations use one batched statement.
    private func neighborsLocked(_ index: ExchangeIndexStore, _ sequences: [Int], before: Bool) throws -> [Int: Int?] {
        var result: [Int: Int?] = [:], plain: [Int] = []
        for source in sequences {
            let row = try row(source)
            guard let range = affected[Data(row.conversationID.utf8)] else { plain.append(source); continue }
            if source >= range.rangeStart {
                guard let position = range.remaining.firstIndex(of: source) else { throw Failure.indexMismatch }
                result[source] = before ? (position > 0 ? range.remaining[position - 1] : range.previousBeforeRange)
                    : (position + 1 < range.remaining.count ? range.remaining[position + 1] : nil)
            } else if before {
                let found = try index.preceding(conversationID: row.conversationID, before: source)
                if let found { rows[found.sequence] = found }
                result[source] = found?.sequence
            } else if let found = try index.following(conversationID: row.conversationID, after: source, through: frontier),
                      found.sequence < range.rangeStart {
                rows[found.sequence] = found
                result[source] = found.sequence
            } else {
                result[source] = range.remaining.first
            }
        }
        let adjacent = try index.adjacent(plain, before: before, through: frontier)
        let missing = Set(adjacent.values.compactMap { $0 }).filter { rows[$0] == nil }
        for row in try index.sources(sequences: missing.sorted()) {
            guard episodeIdentifierEqual(row.projectID, projectID), row.sequence <= frontier else { throw Failure.indexMismatch }
            rows[row.sequence] = row
        }
        for source in plain {
            guard let value = adjacent[source] else { throw Failure.indexMismatch }
            if let value, rows[value] == nil { throw Failure.indexMismatch }
            result[source] = value
        }
        return result
    }

    /// One declared, verified source read of indexed sources.
    private func load(_ sequences: [Int]) throws {
        guard !sequences.isEmpty else { return }
        var bytes = 0
        for sequence in sequences { bytes += try row(sequence).byteCount }
        let loaded = try MeteredRetrieval.charge(lease: lease, kind: .sourceRead,
            resources: EpisodeResources(rawSourceBytes: bytes + sequences.count, metadataRows: sequences.count)) {
            try MeteredRetrieval.authoritative(store: store, lease: lease) { try store.exchangeIndexLoad(sequences: sequences) }
        }
        for sequence in sequences {
            guard let row = rows[sequence], let value = loaded[sequence], Self.matches(row, value.reference, projectID: projectID) else {
                throw Failure.indexMismatch
            }
            sources[sequence] = value
        }
        diagnostics?.loadedSources += sequences.count
    }
}
