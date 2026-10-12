import Foundation
import CSQLite
import Darwin

/// Synthetic contracts for the persistent exchange index. Every fixture is a
/// generated synthetic corpus; results are named booleans. The central
/// contract is parity: for the same store contents, the persistent index and
/// the per-turn in-memory rebuild produce bit-identical rankings, the same
/// block members and neighbors, and the same packed evidence.
enum ExchangeIndexChecks {
    static func run() -> [String: Bool] {
        do { return try checks() }
        catch { return ["exchange_index_fixture_setup_and_execution": false] }
    }

    typealias Query = ExchangeBlockQuery.Query

    // MARK: Synthetic corpus

    /// SplitMix64: deterministic across runs and platforms.
    struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
    }

    static let vocabulary = ["alpha", "beta", "gamma", "delta", "quokka", "habitat", "zebra", "heron", "café", "cafe\u{301}",
        "Ünïcode", "naïve", "42", "x7", "release", "deploy", "the", "and", "Synthetic", "SYNTHETIC", "marker",
        String(repeating: "long", count: 40), "κόσμε", "東京", "alpha-beta", "e\u{301}clair"]

    static func text(_ random: inout Generator) -> String {
        if random.chance(5) { return "" }
        if random.chance(3) {
            return "Synthetic oversized " + (0..<900).map { _ in vocabulary[random.below(vocabulary.count)] }.joined(separator: " ")
        }
        return (0..<(1 + random.below(18))).map { _ in vocabulary[random.below(vocabulary.count)] }.joined(separator: random.chance(20) ? ", " : " ")
    }

    final class Fixture {
        let directory: URL
        var store: MemoryStore?
        let project = "synthetic-exchange-index-project"
        let other = "synthetic-exchange-index-other"
        var conversations: [StoredConversation] = []
        var events: [MemoryEvent] = []

        init(label: String) throws {
            guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw MeteredRetrievalError.invalid }
            defer { free(path) }
            directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                .appendingPathComponent("boros-exchange-index-" + label + "-" + UUID().uuidString)
            store = try MemoryStore(directory: directory)
        }
        deinit { store = nil; try? FileManager.default.removeItem(at: directory) }

        var owner: MemoryStore { store! }
        func reopen() throws { store = nil; store = try MemoryStore(directory: directory) }
        func close() { store = nil }

        func conversation(project: String? = nil) throws -> StoredConversation {
            let value = try owner.createConversation(projectID: project ?? self.project, title: "Synthetic exchange index")
            conversations.append(value)
            return value
        }

        @discardableResult
        func append(_ conversation: StoredConversation, _ role: MemoryRole, _ text: String) throws -> MemoryEvent {
            let id = "synthetic-index-event-" + String(events.count)
            let statuses: [CaptureStatus] = [.complete, .complete, .complete, .partial, .cancelled]
            let event = try owner.append(conversationID: conversation.id, role: role, text: text,
                status: statuses[events.count % statuses.count], turnID: id + "-turn", eventID: id)
            events.append(event)
            return event
        }

        /// Interleaved conversations with mostly alternating roles, leading
        /// assistant messages, consecutive same-role runs, empty and multi-page
        /// sources, and a second project with the same vocabulary.
        func populate(seed: UInt64, events count: Int, conversations total: Int) throws {
            var random = Generator(state: seed)
            var open: [StoredConversation] = []
            for index in 0..<total { open.append(try conversation(project: index == total - 1 ? other : nil)) }
            var lastRole: [String: MemoryRole] = [:]
            for _ in 0..<count {
                let target = open[random.below(open.count)]
                let previous = lastRole[target.id]
                let role: MemoryRole = random.chance(75) ? (previous == .human ? .assistant : .human) : (random.chance(50) ? .human : .assistant)
                try append(target, role, text(&random))
                lastRole[target.id] = role
            }
        }

        func projectEvents(_ conversation: StoredConversation) -> [MemoryEvent] {
            events.filter { episodeIdentifierEqual($0.conversationID, conversation.id) }
        }

        func sql(_ statement: String, _ text: [String] = []) throws {
            var database: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let database else { throw MemoryError.database("synthetic fixture") }
            defer { sqlite3_close(database) }
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, statement, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw MemoryError.database("synthetic fixture") }
            defer { sqlite3_finalize(prepared) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in text.enumerated() {
                _ = value.withCString { sqlite3_bind_text(prepared, Int32(offset + 1), $0, Int32(value.utf8.count), transient) }
            }
            guard sqlite3_step(prepared) == SQLITE_DONE else { throw MemoryError.database("synthetic fixture") }
        }
    }

    // MARK: Parity

    struct Divergence: Error {}

    /// Compares every observable of the two index sources for one query and
    /// exclusion set: corpus counts, every ranked block's identity, anchor
    /// count and score bits, members and neighbors, and the step 1, step 2
    /// and step 3 packers' spans, audits and receipts.
    static func parity(_ store: MemoryStore, project: String, query: Query, excluded: ExactSourceIDs,
                       packing: Bool = true) throws -> Bool {
        let rebuild = try ExchangeBlockQuery.rankedCorpus(source: .inMemoryRebuild, store: store, projectID: project,
            query: query, excluded: excluded, lease: nil)
        let persistent = try ExchangeBlockQuery.rankedCorpus(source: .persistent, store: store, projectID: project,
            query: query, excluded: excluded, lease: nil)
        // A fallback would compare the rebuild with itself.
        guard persistent.indexLabel == ExchangeBlockQuery.persistentIndexLabel,
              rebuild.indexLabel == ExchangeBlockQuery.rebuildIndexLabel else { return false }
        guard rebuild.frontier == persistent.frontier, rebuild.sourceCount == persistent.sourceCount,
              rebuild.blockCount == persistent.blockCount, rebuild.ranked.count == persistent.ranked.count else { return false }
        func ids(_ corpus: ExchangeCorpus, _ sources: [Int]) throws -> [String] { try sources.map { try corpus.reference($0).eventID } }
        func neighbor(_ corpus: ExchangeCorpus, _ source: Int?) throws -> String? { try source.map { try corpus.reference($0).eventID } }
        for (left, right) in zip(rebuild.ranked, persistent.ranked) {
            guard left.anchorMatches == right.anchorMatches, left.score.bitPattern == right.score.bitPattern else { return false }
            let leftMembers = try rebuild.corpus.members(left.block), rightMembers = try persistent.corpus.members(right.block)
            guard try ids(rebuild.corpus, leftMembers) == ids(persistent.corpus, rightMembers),
                  try neighbor(rebuild.corpus, try rebuild.corpus.previous(leftMembers[0]))
                    == neighbor(persistent.corpus, try persistent.corpus.previous(rightMembers[0])),
                  try neighbor(rebuild.corpus, try rebuild.corpus.next(leftMembers.last!))
                    == neighbor(persistent.corpus, try persistent.corpus.next(rightMembers.last!)),
                  try ids(rebuild.corpus, leftMembers).indices.allSatisfy({ position in
                      try rebuild.corpus.text(leftMembers[position]) == persistent.corpus.text(rightMembers[position])
                        && rebuild.corpus.reference(leftMembers[position]) == persistent.corpus.reference(rightMembers[position])
                  }) else { return false }
        }
        guard packing else { return true }
        let version = ContextSourceFraming.currentSelectionVersion
        for (adjacent, budget) in [(false, 12_000), (true, 12_000), (true, 700)] {
            let left = try ExchangeBlockQuery.pack(index: rebuild.corpus, ranked: rebuild.ranked, maximumSpans: 48, tokenBudget: budget,
                adjacent: adjacent, selectionVersion: version)
            let right = try ExchangeBlockQuery.pack(index: persistent.corpus, ranked: persistent.ranked, maximumSpans: 48, tokenBudget: budget,
                adjacent: adjacent, selectionVersion: version)
            guard spans(left.hits) == spans(right.hits),
                  try JSONSerialization.data(withJSONObject: left.audit, options: [.sortedKeys])
                    == JSONSerialization.data(withJSONObject: right.audit, options: [.sortedKeys]) else { return false }
        }
        for (budget, audit) in [(12_000, 22_000), (900, 100_000), (100_000, 2_000)] {
            let left = try ExchangeBlockQuery.ValuePacking.plan(index: rebuild.corpus, ranked: rebuild.ranked, maximumSpans: 48,
                tokenBudget: budget, auditBudget: audit, selectionVersion: version)
            let right = try ExchangeBlockQuery.ValuePacking.plan(index: persistent.corpus, ranked: persistent.ranked, maximumSpans: 48,
                tokenBudget: budget, auditBudget: audit, selectionVersion: version)
            let leftAudit = try ExchangeBlockQuery.ValuePacking.audit(plan: left, index: rebuild.corpus, matchedBlocks: rebuild.ranked.count,
                tokenBudget: budget, auditBudget: audit, maximumSpans: 48)
            let rightAudit = try ExchangeBlockQuery.ValuePacking.audit(plan: right, index: persistent.corpus, matchedBlocks: persistent.ranked.count,
                tokenBudget: budget, auditBudget: audit, maximumSpans: 48)
            guard spans(left.hits) == spans(right.hits), left.codes == right.codes,
                  try JSONSerialization.data(withJSONObject: leftAudit, options: [.sortedKeys])
                    == JSONSerialization.data(withJSONObject: rightAudit, options: [.sortedKeys]) else { return false }
        }
        return true
    }

    static func spans(_ hits: [MemoryHit]) -> [String] {
        hits.map { $0.eventID + "|" + String($0.excerptOffset) + "|" + MeteredRetrieval.digest(Data($0.excerpt.utf8)) }
    }

    /// Queries over the synthetic vocabulary, including quoted anchors and
    /// terms that only differ by Unicode normalization.
    static func queries(_ random: inout Generator) -> [Query] {
        var result = [ExchangeBlockQuery.query("Where is the quokka habitat?"),
            ExchangeBlockQuery.query("What about the \"alpha beta\" release and café?"),
            ExchangeBlockQuery.query("cafe\u{301} naïve e\u{301}clair 東京"),
            ExchangeBlockQuery.query("`zebra heron` and \u{201C}deploy marker\u{201D} synthetic"),
            ExchangeBlockQuery.query("unmatched-term-only")]
        for _ in 0..<5 {
            let words = (0..<(1 + random.below(4))).map { _ in vocabulary[random.below(vocabulary.count)] }
            result.append(ExchangeBlockQuery.query(random.chance(30) ? "\"" + words.joined(separator: " ") + "\" synthetic" : words.joined(separator: " ")))
        }
        return result.filter { !$0.terms.isEmpty }
    }

    /// Exclusion sets of every shape the rebuild accepts: a conversation
    /// suffix (the accepted request and recent context), a block-starting
    /// source, the middle of a conversation, a conversation's first source, a
    /// whole conversation, two conversations, and IDs outside the project.
    static func exclusions(_ fixture: Fixture, _ random: inout Generator) -> [ExactSourceIDs] {
        let candidates = fixture.conversations.filter { episodeIdentifierEqual($0.projectID, fixture.project) }
        var result: [ExactSourceIDs] = [ExactSourceIDs([])]
        for conversation in candidates.prefix(2) {
            let events = fixture.projectEvents(conversation)
            guard !events.isEmpty else { continue }
            let suffix = 1 + random.below(min(events.count, 6))
            result.append(ExactSourceIDs(events.suffix(suffix).map(\.id)))
            if let human = events.dropFirst().first(where: { $0.role == .human }) { result.append(ExactSourceIDs([human.id])) }
            result.append(ExactSourceIDs([events[events.count / 2].id]))
            result.append(ExactSourceIDs([events[0].id]))
            result.append(ExactSourceIDs(events.map(\.id)))
        }
        if candidates.count >= 2 {
            let first = fixture.projectEvents(candidates[0]), second = fixture.projectEvents(candidates[1])
            result.append(ExactSourceIDs(first.suffix(2).map(\.id) + second.prefix(1).map(\.id)))
        }
        let outside = fixture.events.filter { episodeIdentifierEqual($0.projectID, fixture.other) }.prefix(2).map(\.id)
        result.append(ExactSourceIDs(outside + ["synthetic-index-missing-id"]))
        return result
    }

    /// Stored statistics against an in-memory rebuild over every source of
    /// the project: every term's block counts, every block's bytes and
    /// conversation order, block and source totals.
    static func statisticsMatch(_ store: MemoryStore, project: String) throws -> Bool {
        let loaded = try ExchangeBlockQuery.load(store: store, projectID: project, excluding: ExactSourceIDs([]), lease: nil)
        let index = ExchangeBlockQuery.Index(sources: loaded.sources)
        var expected: [String: [Int: Int]] = [:], blocks: [Int: ExchangeIndexStore.BlockAttributes] = [:]
        var first: [Data: Int] = [:]
        for source in loaded.sources where first[Data(source.reference.conversationID.utf8)] == nil {
            first[Data(source.reference.conversationID.utf8)] = source.reference.sequence
        }
        for block in index.blocks {
            let lead = index.sources[block.sources[0]].reference
            blocks[lead.sequence] = .init(conversationFirst: first[Data(lead.conversationID.utf8)]!, bytes: block.bytes, sources: block.sources.count)
            for (term, count) in block.frequency { expected[term.precomposedStringWithCanonicalMapping, default: [:]][lead.sequence] = count }
        }
        let exported = try store.withExchangeIndex(lease: nil, create: true) { stored -> (ExchangeIndexStore.ProjectRow, [String: [Int: Int]], [Int: ExchangeIndexStore.BlockAttributes]) in
            _ = try stored.catchUp(store: store, maximumEvents: Int.max)
            return try stored.exportProject(project)
        }
        return exported.0.blockCount == index.blocks.count && exported.0.sourceCount == loaded.sources.count
            && exported.0.maximumSequence == loaded.frontier && exported.1 == expected && exported.2 == blocks
    }

    static func exportByTerm(_ store: MemoryStore, project: String) throws -> [String: [Int: Int]] {
        try store.withExchangeIndex(lease: nil, create: false) { try $0.exportProject(project).terms }
    }

    // MARK: Checks

    private static func checks() throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        let previousSource = ExchangeBlockQuery.diagnosticIndexSource
        defer { ExchangeBlockQuery.diagnosticIndexSource = previousSource }
        ExchangeBlockQuery.diagnosticIndexSource = .persistent

        result["exchange_index_audit_labels_have_equal_length"] = ExchangeBlockQuery.persistentIndexLabel.utf8.count
            == ExchangeBlockQuery.rebuildIndexLabel.utf8.count && ExchangeBlockQuery.persistentIndexLabel != ExchangeBlockQuery.rebuildIndexLabel
        var coding = Data()
        let values = [0, 1, -1, 127, -128, 300, -70_000, Int(Int32.max), -Int(Int32.max)]
        for value in values { ExchangeIndexCoding.append(ExchangeIndexCoding.zigzag(value), to: &coding) }
        var reader = ExchangeIndexCoding.Reader(coding), decoded: [Int] = []
        while !reader.atEnd { decoded.append(ExchangeIndexCoding.unzigzag(try reader.next())) }
        result["exchange_index_varint_zigzag_round_trip"] = decoded == values

        // Randomized parity: two corpora, eager maintenance from the start.
        var parityCases = 0, parityPassed = 0
        for seed: UInt64 in [11, 29] {
            let fixture = try Fixture(label: "parity")
            _ = try fixture.owner.buildExchangeIndex()
            try fixture.populate(seed: seed, events: 220, conversations: 7)
            var random = Generator(state: seed &* 7919)
            let queries = queries(&random), exclusions = exclusions(fixture, &random)
            for query in queries {
                for excluded in exclusions {
                    parityCases += 1
                    if try parity(fixture.owner, project: fixture.project, query: query, excluded: excluded) { parityPassed += 1 }
                }
            }
        }
        result["exchange_index_random_corpora_rank_members_neighbors_and_packing_match_rebuild"] = parityCases >= 200 && parityPassed == parityCases

        // Matched terms are summed in sorted order, so repeated rankings of
        // the same contents with freshly built query sets are bit-identical.
        let repeated = try Fixture(label: "determinism")
        try repeated.populate(seed: 13, events: 150, conversations: 4)
        let repeatedSources = try ExchangeBlockQuery.load(store: repeated.owner, projectID: repeated.project,
            excluding: ExactSourceIDs([]), lease: nil).sources
        let repeatedIndex = ExchangeBlockQuery.Index(sources: repeatedSources)
        let rankings = (0..<12).map { _ in
            repeatedIndex.rank(ExchangeBlockQuery.query("alpha beta gamma delta quokka habitat zebra heron marker release"))
                .map { [$0.block, Int(truncatingIfNeeded: $0.score.bitPattern)] }
        }
        // Lower bounds never exceed exact page counts or token estimates, so
        // the packer's early rejections are the decisions exact costs make.
        var boundsHold = true, boundsChecked = 0
        let sourceTime = EventSourceTime(value: "2023-07-27T23:30:00", precision: "second", timezone: "-04:00",
            sourceSHA256: String(repeating: "c", count: 64), locator: "/h", originalValue: "2023-07-27T23:30:00-04:00")
        let timed = repeatedSources.prefix(40).map { source -> ExchangeBlockQuery.Source in
            let r = source.reference
            return ExchangeBlockQuery.Source(reference: MemorySourceReference(sequence: r.sequence, eventID: r.eventID,
                conversationID: r.conversationID, projectID: r.projectID, role: r.role, status: r.status, createdAt: r.createdAt,
                digest: r.digest, byteCount: r.byteCount, sourceTime: sourceTime), text: source.text)
        }
        for version in [ContextSourceFraming.legacySelectionVersion, ContextSourceFraming.identitySelectionVersion,
                        ContextSourceFraming.currentSelectionVersion, ContextSourceFraming.defaultSelectionVersion] {
            for source in repeatedSources + timed {
                let pages = ExchangeBlockQuery.pages(source)
                let exact = try pages.reduce(0) { $0 + (try ExchangeBlockQuery.estimatedTokens($1, selectionVersion: version)) }
                let reference = source.reference
                let bound = try ExchangeBlockQuery.minimumCost(eventID: reference.eventID, conversationID: reference.conversationID,
                    role: reference.role, byteCount: reference.byteCount, digest: reference.digest, selectionVersion: version)
                boundsChecked += 1
                // Valid always; tight (within 12 tokens a page) without a source time.
                if bound.spans > pages.count || bound.tokens > exact
                    || (reference.byteCount > 0 && reference.sourceTime == nil && exact - bound.tokens > 12 * pages.count) { boundsHold = false }
            }
        }
        var unchanged = true
        let boundRanked = repeatedIndex.rank(ExchangeBlockQuery.query("alpha beta quokka habitat zebra synthetic"))
        for budget in [250, 400, 700, 1_500, 4_000, 12_000] {
            for adjacent in [false, true] {
                let fast = try ExchangeBlockQuery.pack(index: repeatedIndex, ranked: boundRanked, maximumSpans: 48, tokenBudget: budget,
                    adjacent: adjacent, selectionVersion: ContextSourceFraming.currentSelectionVersion)
                let exact = try ExchangeBlockQuery.pack(index: repeatedIndex, ranked: boundRanked, maximumSpans: 48, tokenBudget: budget,
                    adjacent: adjacent, selectionVersion: ContextSourceFraming.currentSelectionVersion, lowerBounds: false)
                if try spans(fast.hits) != spans(exact.hits) || (try JSONSerialization.data(withJSONObject: fast.audit, options: [.sortedKeys]))
                    != (try JSONSerialization.data(withJSONObject: exact.audit, options: [.sortedKeys])) { unchanged = false }
            }
        }
        result["exchange_index_cost_lower_bounds_are_valid_tight_and_change_no_decision"] = boundsHold && boundsChecked >= 400 && unchanged
        result["exchange_index_repeated_rankings_are_bit_identical"] = rankings[0].count > 20 && rankings.allSatisfy { $0 == rankings[0] }
            && ExchangeBlockQuery.scoringVersion == "idf-term-coverage-sqrt-byte-cost-v2"

        // Eager maintenance and a bulk build of the same events agree with
        // each other and with a rebuild, across chunk boundaries.
        let eager = try Fixture(label: "eager"), bulk = try Fixture(label: "bulk")
        _ = try eager.owner.buildExchangeIndex()
        let longConversation = try eager.conversation(), bulkLong = try bulk.conversation()
        for index in 0..<300 {
            for (fixture, conversation) in [(eager, longConversation), (bulk, bulkLong)] {
                try fixture.append(conversation, .human, "alpha synthetic question \(index)")
                if index % 3 == 0 { try fixture.append(conversation, .assistant, "alpha reply \(index) beta") }
            }
        }
        try eager.populate(seed: 5, events: 120, conversations: 4)
        try bulk.populate(seed: 5, events: 120, conversations: 4)
        let bulkReceipt = try bulk.owner.buildExchangeIndex()
        let eagerDiagnostics = eager.owner.exchangeIndexMaintenanceDiagnostics()
        result["exchange_index_eager_maintenance_indexes_each_committed_event"] = eagerDiagnostics?.events == eager.events.count
            && bulkReceipt.events == bulk.events.count
        let eagerTerms = try exportByTerm(eager.owner, project: eager.project), bulkTerms = try exportByTerm(bulk.owner, project: bulk.project)
        result["exchange_index_incremental_and_bulk_builds_store_identical_statistics"] = !eagerTerms.isEmpty
            && eagerTerms.mapValues { $0.count } == bulkTerms.mapValues { $0.count }
            && eagerTerms.values.map { $0.values.reduce(0, +) }.sorted() == bulkTerms.values.map { $0.values.reduce(0, +) }.sorted()
        let chunked = try eager.owner.withExchangeIndex(lease: nil, create: false) { index -> (Int, Int) in
            (try index.term(eager.project, "alpha")?.chunks ?? 0, try index.project(eager.project).blockChunks)
        }
        result["exchange_index_statistics_match_rebuild_across_chunk_boundaries"] = try chunked.0 >= 3 && chunked.1 >= 3
            && (try statisticsMatch(eager.owner, project: eager.project)) && (try statisticsMatch(bulk.owner, project: bulk.project))
        let alphaQuery = ExchangeBlockQuery.query("alpha beta question")
        let suffix = ExactSourceIDs(eager.projectEvents(longConversation).suffix(3).map(\.id))
        result["exchange_index_parity_holds_for_chunked_postings_and_growth"] = try parity(eager.owner, project: eager.project,
            query: alphaQuery, excluded: suffix) && parity(bulk.owner, project: bulk.project, query: alphaQuery,
            excluded: ExactSourceIDs(bulk.projectEvents(bulkLong).suffix(3).map(\.id)))

        // Restart: the sidecar is reopened, validated and maintained.
        try eager.reopen()
        let reopened = try parity(eager.owner, project: eager.project, query: alphaQuery, excluded: suffix)
        try eager.append(longConversation, .assistant, "alpha reply after restart beta")
        try eager.append(longConversation, .human, "alpha question after restart")
        let afterRestart = try parity(eager.owner, project: eager.project, query: alphaQuery,
            excluded: ExactSourceIDs([eager.events.last!.id]))
        result["exchange_index_survives_restart_and_maintains_new_events"] = reopened && afterRestart
            && eager.owner.exchangeIndexMaintenanceDiagnostics()?.events == 2

        // A store without a sidecar catches up within a turn up to the limit,
        // and fails closed above it.
        let lagging = try Fixture(label: "lagging")
        try lagging.populate(seed: 77, events: 40, conversations: 3)
        let lagQuery = ExchangeBlockQuery.query("alpha quokka habitat")
        let refused: Bool
        do {
            _ = try ExchangeIndexView.open(store: lagging.owner, projectID: lagging.project, query: lagQuery,
                excluding: ExactSourceIDs([]), lease: nil, diagnostics: nil, maximumCatchUp: 10)
            refused = false
        } catch ExchangeBlockQuery.Failure.indexUnavailable { refused = true }
        let lagDiagnostics = ExchangeIndexDiagnostics()
        _ = try ExchangeIndexView.open(store: lagging.owner, projectID: lagging.project, query: lagQuery,
            excluding: ExactSourceIDs([]), lease: nil, diagnostics: lagDiagnostics)
        result["exchange_index_turn_catch_up_is_bounded_and_fails_closed_above_limit"] = try refused && lagDiagnostics.catchUpEvents == 40
            && (try parity(lagging.owner, project: lagging.project, query: lagQuery, excluded: ExactSourceIDs([])))
        let oversized: Bool
        do {
            _ = try ExchangeIndexView.open(store: lagging.owner, projectID: lagging.project, query: lagQuery,
                excluding: ExactSourceIDs([]), lease: nil, diagnostics: nil, maximumSources: 5)
            oversized = false
        } catch ExchangeBlockQuery.Failure.snapshotLimit { oversized = true }
        result["exchange_index_project_size_limit_fails_closed"] = oversized

        // A view's frontier is fixed: later publications in a ranked block's
        // conversation do not join its members or neighbors.
        let frozen = try Fixture(label: "frontier")
        _ = try frozen.owner.buildExchangeIndex()
        let frozenConversation = try frozen.conversation()
        try frozen.append(frozenConversation, .human, "quokka habitat question")
        let frozenQuery = ExchangeBlockQuery.query("quokka habitat")
        let view = try ExchangeIndexView.open(store: frozen.owner, projectID: frozen.project, query: frozenQuery,
            excluding: ExactSourceIDs([]), lease: nil, diagnostics: nil)
        try frozen.append(frozenConversation, .assistant, "quokka habitat late reply")
        let lateMembers = try view.members(view.ranked[0].block)
        result["exchange_index_view_ignores_publications_after_its_frontier"] = try view.ranked.count == 1 && lateMembers.count == 1
            && (try view.next(lateMembers[0])) == nil

        // Stale and corrupted sidecars.
        let donor = try Fixture(label: "donor"), recipient = try Fixture(label: "recipient")
        _ = try donor.owner.buildExchangeIndex()
        try donor.populate(seed: 3, events: 60, conversations: 3)
        try recipient.populate(seed: 4, events: 50, conversations: 3)
        _ = try recipient.owner.buildExchangeIndex()
        donor.close(); recipient.close()
        let donorFile = ExchangeIndexStore.directory(storeDirectory: donor.directory)
        let recipientFile = ExchangeIndexStore.directory(storeDirectory: recipient.directory)
        try FileManager.default.removeItem(at: recipientFile)
        try FileManager.default.copyItem(at: donorFile, to: recipientFile)
        try recipient.reopen()
        let replacedDiagnostics = ExchangeIndexDiagnostics()
        let staleQuery = ExchangeBlockQuery.query("alpha habitat zebra")
        _ = try ExchangeIndexView.open(store: recipient.owner, projectID: recipient.project, query: staleQuery,
            excluding: ExactSourceIDs([]), lease: nil, diagnostics: replacedDiagnostics)
        result["exchange_index_foreign_sidecar_is_reset_and_rebuilt"] = try replacedDiagnostics.catchUpEvents == recipient.events.count
            && (try parity(recipient.owner, project: recipient.project, query: staleQuery, excluded: ExactSourceIDs([])))

        // An indexed source changed outside the store's API fails closed when
        // a turn reads it; a removed source resets the sidecar at open.
        recipient.close()
        let probe = ExchangeBlockQuery.query("synthetic tampered probe")
        try recipient.reopen()
        let tamperedConversation = try recipient.conversation()
        let tampered = try recipient.append(tamperedConversation, .human, "synthetic tampered probe")
        try recipient.append(tamperedConversation, .assistant, "synthetic other reply")
        recipient.close()
        let replacement = "synthetic tampered probe changed"
        try recipient.sql("UPDATE events SET payload=CAST(?1 AS BLOB), digest=?2, byte_count=length(CAST(?1 AS BLOB)) WHERE id=?3",
            [replacement, MeteredRetrieval.digest(Data(replacement.utf8)), tampered.id])
        try recipient.reopen()
        var tamperRefused = false
        do {
            let opened = try ExchangeIndexView.open(store: recipient.owner, projectID: recipient.project, query: probe,
                excluding: ExactSourceIDs([]), lease: nil, diagnostics: nil)
            for entry in opened.ranked { for member in try opened.members(entry.block) { _ = try opened.text(member) } }
        } catch ExchangeBlockQuery.Failure.indexMismatch { tamperRefused = true }
        result["exchange_index_out_of_band_source_change_fails_closed"] = tamperRefused
        recipient.close()
        try recipient.sql("DELETE FROM events WHERE id=?1", [tampered.id])
        try recipient.reopen()
        let removedDiagnostics = ExchangeIndexDiagnostics()
        _ = try ExchangeIndexView.open(store: recipient.owner, projectID: recipient.project, query: staleQuery,
            excluding: ExactSourceIDs([]), lease: nil, diagnostics: removedDiagnostics)
        result["exchange_index_removed_source_resets_and_rebuilds_sidecar"] = try removedDiagnostics.catchUpEvents == recipient.events.count - 1
            && (try parity(recipient.owner, project: recipient.project, query: staleQuery, excluded: ExactSourceIDs([])))

        // Backup archives exclude the derived sidecar; a restored store
        // rebuilds it and ranks identically.
        let archive = eager.directory.deletingLastPathComponent().appendingPathComponent("boros-exchange-index-archive-" + UUID().uuidString)
        let restored = eager.directory.deletingLastPathComponent().appendingPathComponent("boros-exchange-index-restored-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive); try? FileManager.default.removeItem(at: restored) }
        _ = try BackupArchive.create(from: eager.owner, at: archive)
        let archived = try FileManager.default.contentsOfDirectory(atPath: archive.path)
        _ = try BackupArchive.restore(from: archive, to: restored, authority: .unmanagedNoDeletion)
        var restoredOwner: MemoryStore? = try MemoryStore(directory: restored)
        let restoredAbsent = !restoredOwner!.exchangeIndexExists
        let restoredParity = try parity(restoredOwner!, project: eager.project, query: alphaQuery, excluded: suffix)
        let restoredRanked = try ExchangeBlockQuery.rankedCorpus(source: .persistent, store: restoredOwner!, projectID: eager.project,
            query: alphaQuery, excluded: suffix, lease: nil)
        let originalRanked = try ExchangeBlockQuery.rankedCorpus(source: .persistent, store: eager.owner, projectID: eager.project,
            query: alphaQuery, excluded: suffix, lease: nil)
        result["exchange_index_backup_excludes_sidecar_and_restore_rebuilds_identically"] = !archived.contains { $0.contains("exchange") }
            && restoredAbsent && restoredParity && restoredOwner!.exchangeIndexExists
            && restoredRanked.ranked.map(\.score.bitPattern) == originalRanked.ranked.map(\.score.bitPattern)
        restoredOwner = nil

        // Owner-only files.
        var directoryStat = stat(), fileStat = stat()
        let sidecar = ExchangeIndexStore.directory(storeDirectory: eager.directory)
        result["exchange_index_sidecar_is_owner_only"] = lstat(sidecar.path, &directoryStat) == 0
            && directoryStat.st_mode & 0o777 == 0o700
            && lstat(sidecar.appendingPathComponent(ExchangeIndexStore.fileName).path, &fileStat) == 0 && fileStat.st_mode & 0o777 == 0o600

        result.merge(try episodeParity()) { _, latest in latest }
        result.merge(try fallbackChecks()) { _, latest in latest }
        result.merge(try oversizedFallbackChecks()) { _, latest in latest }
        return result
    }

    /// A store with more history than a turn may index and no sidecar, as
    /// after an upgrade or a restore: the first turn is served by the rebuild
    /// and selects what the rebuild selects, a build outside the episode
    /// follows, and a later turn reads the persistent index.
    private static func fallbackChecks() throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        let fixture = try Fixture(label: "fallback")
        let archive = try fixture.conversation()
        for index in 0..<1_050 {
            try fixture.append(archive, .human, "Synthetic quokka habitat question \(index) alpha")
            try fixture.append(archive, .assistant, "Synthetic habitat reply \(index) beta")
        }
        let requests = try fixture.conversation()
        try fixture.append(requests, .human, "Synthetic earlier quokka question")
        try fixture.append(requests, .assistant, "Synthetic earlier habitat answer")
        let clock = Clock(), prompt = "Where is the quokka habitat and the \"alpha beta\" reply?"
        var ordinal = 0
        /// One packed turn served by the default index source, compared with
        /// the rebuild on the same recent snapshot in the same episode.
        func turn(_ store: MemoryStore) throws -> (label: String?, identical: Bool, delivered: Bool, fallback: Bool) {
            ordinal += 1
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwenExchangePacked
            let episodeID = UUID().uuidString, humanID = "synthetic-index-fallback-request-" + String(ordinal)
            _ = try store.acceptRequestAndBeginEpisode(conversationID: requests.id, turnID: humanID + "-turn",
                humanEventID: humanID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
            defer { _ = try? lease.finish(reason: .cancelled) }
            let recent = try ContextAssembler.prepareRecent(store: store, conversationID: requests.id, projectID: fixture.project,
                prompt: prompt, system: "Synthetic index host", excludingEventID: humanID, episodeLease: lease,
                componentPolicy: .selectedQwenExchangePacked)
            let diagnostics = ExchangeIndexDiagnostics()
            func prepare(_ source: ExchangeBlockQuery.IndexSource, _ sink: ExchangeIndexDiagnostics?) throws -> ContextSnapshot {
                ExchangeBlockQuery.diagnosticIndexSource = source
                defer { ExchangeBlockQuery.diagnosticIndexSource = .persistent }
                return try ExchangeBlockQuery.prepareEvidence(recent: recent, store: store, conversationID: requests.id,
                    projectID: fixture.project, prompt: prompt, excludingEventID: humanID, episodeLease: lease,
                    lexicalQueryUTF8Range: nil, componentPolicy: .selectedQwenExchangePacked, diagnostics: sink)
            }
            let served = try prepare(.persistent, diagnostics), rebuilt = try prepare(.inMemoryRebuild, nil)
            func audit(_ snapshot: ContextSnapshot) throws -> ([String: Any], String?) {
                let retrieval = try JSONSerialization.jsonObject(with: snapshot.retrievalAuditJSON ?? Data()) as? [String: Any] ?? [:]
                var value = retrieval["exchange_query"] as? [String: Any] ?? [:]
                let label = value.removeValue(forKey: "index") as? String
                return (value, label)
            }
            let (left, label) = try audit(served), (right, _) = try audit(rebuilt)
            let identical = try spans(served.evidence) == spans(rebuilt.evidence)
                && JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: right, options: [.sortedKeys])
                && served.deliveryAudit().count == rebuilt.deliveryAudit().count
            return (label, identical, !served.evidence.isEmpty, diagnostics.fallback)
        }
        func lifecycle(_ store: MemoryStore) throws -> Bool {
            let absent = !store.exchangeIndexExists
            let first = try turn(store)
            let built = store.waitForExchangeIndexBuild()
            let lag = store.exchangeIndexLag()
            let second = try turn(store)
            return absent && first.label == ExchangeBlockQuery.fallbackIndexLabel && first.fallback && first.identical && first.delivered
                && built && lag == 0 && second.label == ExchangeBlockQuery.persistentIndexLabel && !second.fallback
                && second.identical && second.delivered
        }
        result["exchange_index_fallback_label_has_equal_length"] = ExchangeBlockQuery.fallbackIndexLabel.utf8.count
            == ExchangeBlockQuery.persistentIndexLabel.utf8.count
        let largeLifecycle = try lifecycle(fixture.owner)
        result["exchange_index_unbuilt_large_store_falls_back_identically_then_builds_outside_the_turn"] = fixture.events.count
            > ExchangeIndexStore.maximumTurnCatchUp && largeLifecycle
            && fixture.owner.exchangeIndexMaintenanceDiagnostics().map { $0.events > 0 } == true

        // The same after a restore: the archive has no sidecar.
        let archiveURL = fixture.directory.deletingLastPathComponent().appendingPathComponent("boros-exchange-fallback-archive-" + UUID().uuidString)
        let restoredURL = fixture.directory.deletingLastPathComponent().appendingPathComponent("boros-exchange-fallback-restored-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archiveURL); try? FileManager.default.removeItem(at: restoredURL) }
        _ = try BackupArchive.create(from: fixture.owner, at: archiveURL)
        _ = try BackupArchive.restore(from: archiveURL, to: restoredURL, authority: .unmanagedNoDeletion)
        var restored: MemoryStore? = try MemoryStore(directory: restoredURL)
        result["exchange_index_restored_large_store_falls_back_identically_then_builds_outside_the_turn"] = try lifecycle(restored!)
        restored!.waitForExchangeIndexBuild()
        restored = nil
        return result
    }

    /// The ordinary Send default on a store with no sidecar whose project is
    /// above the in-memory rebuild's 32 MiB limit, as on a large store's first
    /// turns after the default switch, an upgrade or a restore. Before the
    /// fallback such a turn failed (`snapshotLimit`). It now selects exactly
    /// what the v1/16 policy selects on an identical copy of the store, under
    /// the frozen exchange policy and with the fallback label; the background
    /// build still runs, the next turn reads the persistent index, and
    /// post-commit maintenance resumes. The diagnostic rebuild source still
    /// refuses, so parity arms are unchanged.
    private static func oversizedFallbackChecks() throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        let policy = ContextComponentPolicy.currentSelectedQwen
        let fixture = try Fixture(label: "oversized")
        let filler = try fixture.conversation()
        // More events than a turn indexes itself, so the turn needs the rebuild.
        for index in 0..<(ExchangeIndexStore.maximumTurnCatchUp / 2 + 25) {
            try fixture.append(filler, .human, "Synthetic filler question \(index)")
            try fixture.append(filler, .assistant, "Synthetic filler reply \(index)")
        }
        // Above the rebuild's byte limit with payloads that hold no terms.
        let bulk = try fixture.conversation(), large = String(repeating: ". ", count: 2_000_000)
        var bulkBytes = 0
        while bulkBytes <= ExchangeBlockQuery.maximumSourceBytes {
            try fixture.append(bulk, .assistant, large); bulkBytes += large.utf8.count
        }
        let needles = try fixture.conversation()
        try fixture.append(needles, .human, "Synthetic quokka habitat survey question")
        try fixture.append(needles, .assistant, "Synthetic habitat survey answer about the quokka")
        let requests = try fixture.conversation()
        // An identical copy for the v1/16 comparison turn.
        fixture.close()
        let copyURL = fixture.directory.deletingLastPathComponent()
            .appendingPathComponent("boros-exchange-oversized-v1-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copyURL) }
        try FileManager.default.copyItem(at: fixture.directory, to: copyURL)
        try fixture.reopen()
        var copy: MemoryStore? = try MemoryStore(directory: copyURL)
        let clock = Clock(), prompt = "Where was the quokka habitat survey?", humanID = "synthetic-oversized-request"
        func accept(_ store: MemoryStore, _ frozen: ContextComponentPolicy, _ human: String) throws -> EpisodeLease {
            var limits = EpisodeLimits(); limits.componentPolicy = frozen
            let episodeID = UUID().uuidString
            _ = try store.acceptRequestAndBeginEpisode(conversationID: requests.id, turnID: human + "-turn",
                humanEventID: human, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            return EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        }
        func retrieval(_ snapshot: ContextSnapshot) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: snapshot.retrievalAuditJSON ?? Data("{}".utf8)) as? [String: Any] ?? [:]
        }

        // v1/16 on the copy: ordinary Send's selection before October 12, 2026.
        let v1Lease = try accept(copy!, .selectedQwen, humanID)
        let v1Recent = try ContextAssembler.prepareRecent(store: copy!, conversationID: requests.id, projectID: fixture.project,
            prompt: prompt, system: "Synthetic index host", excludingEventID: humanID, episodeLease: v1Lease,
            componentPolicy: .selectedQwen)
        let v1 = try ChatContextPreparation.prepareEvidence(recent: v1Recent, store: copy!, conversationID: requests.id,
            projectID: fixture.project, prompt: prompt, excludingEventID: humanID, episodeLease: v1Lease,
            componentPolicy: .selectedQwen, semanticRetrieval: .ordinarySend)
        _ = try v1Lease.finish(reason: .cancelled)
        copy = nil

        // The default on the original store.
        let absent = !fixture.owner.exchangeIndexExists
        let lease = try accept(fixture.owner, policy, humanID)
        let recent = try ContextAssembler.prepareRecent(store: fixture.owner, conversationID: requests.id, projectID: fixture.project,
            prompt: prompt, system: "Synthetic index host", excludingEventID: humanID, episodeLease: lease, componentPolicy: policy)
        ExchangeBlockQuery.diagnosticIndexSource = .inMemoryRebuild
        var rebuildRefused = false
        do {
            _ = try ExchangeBlockQuery.prepareEvidence(recent: recent, store: fixture.owner, conversationID: requests.id,
                projectID: fixture.project, prompt: prompt, excludingEventID: humanID, episodeLease: lease,
                lexicalQueryUTF8Range: nil, componentPolicy: policy)
        } catch ExchangeBlockQuery.Failure.snapshotLimit { rebuildRefused = true }
        ExchangeBlockQuery.diagnosticIndexSource = .persistent
        let before = try lease.checkActive()
        let served = try ExchangeBlockQuery.prepareEvidence(recent: recent, store: fixture.owner, conversationID: requests.id,
            projectID: fixture.project, prompt: prompt, excludingEventID: humanID, episodeLease: lease,
            lexicalQueryUTF8Range: nil, componentPolicy: policy)
        let after = try lease.checkActive()
        _ = try lease.finish(reason: .cancelled)
        let audit = try retrieval(served), fallback = audit["exchange_fallback"] as? [String: Any]
        result["exchange_index_default_is_the_policy_these_lifecycle_checks_exercise"] = policy == .selectedQwenExchangePacked
        result["exchange_index_unbuilt_project_above_rebuild_limit_was_refused_by_the_rebuild"] = rebuildRefused && absent
            && fixture.events.reduce(0) { $0 + $1.byteCount } > ExchangeBlockQuery.maximumSourceBytes
            && fixture.events.count > ExchangeIndexStore.maximumTurnCatchUp
        result["exchange_index_unbuilt_oversized_turn_falls_back_to_v1_selection_identically"] = try !served.evidence.isEmpty
            && spans(served.evidence) == spans(v1.evidence) && served.recentSourceIDs == v1.recentSourceIDs
            && served.evidence.contains { $0.excerpt.contains("quokka") }
            && served.deliveryAudit().count > 0
        result["exchange_index_v1_fallback_is_labelled_under_the_frozen_policy"] = audit["mode"] as? String == ExchangeBlockQuery.lexicalFallbackMode
            && fallback?["version"] as? String == ExchangeBlockQuery.lexicalFallbackVersion
            && fallback?["reason"] as? String == ExchangeBlockQuery.unindexedLimitFallbackReason
            && fallback?["frozen_policy"] as? String == policy.version
            && fallback?["selection_policy"] as? String == ContextComponentPolicy.selectedQwen.version
            && audit["exchange_query"] == nil && audit["manifest_id"] == nil && audit["semantic_available"] as? Bool == false
            && served.selectionAudit?.version == ContextComponentPolicy.exchangeSelectionAuditVersion
            && served.selectionAudit?.maximumEvidenceSpans == policy.evidenceSpans
            && (served.retrievalNotice ?? "").contains("still being built")
            && after.limits.componentPolicy == policy && after.charged.modelCalls == before.charged.modelCalls
            && after.charged.vectorBytes == before.charged.vectorBytes && after.charged.encoderInputBytes == before.charged.encoderInputBytes
            && after.charged.metadataRows > before.charged.metadataRows

        // The fallback turn scheduled the build; the next turn reads the index.
        let built = fixture.owner.waitForExchangeIndexBuild()
        let lag = fixture.owner.exchangeIndexLag()
        let nextID = humanID + "-next"
        let nextLease = try accept(fixture.owner, policy, nextID)
        let nextRecent = try ContextAssembler.prepareRecent(store: fixture.owner, conversationID: requests.id, projectID: fixture.project,
            prompt: prompt, system: "Synthetic index host", excludingEventID: nextID, episodeLease: nextLease, componentPolicy: policy)
        let next = try ExchangeBlockQuery.prepareEvidence(recent: nextRecent, store: fixture.owner, conversationID: requests.id,
            projectID: fixture.project, prompt: prompt, excludingEventID: nextID, episodeLease: nextLease,
            lexicalQueryUTF8Range: nil, componentPolicy: policy)
        _ = try nextLease.finish(reason: .cancelled)
        let nextAudit = try retrieval(next)
        let maintainedBefore = fixture.owner.exchangeIndexMaintenanceDiagnostics()?.events ?? 0
        try fixture.append(needles, .human, "Synthetic quokka follow-up after the build")
        let maintainedAfter = fixture.owner.exchangeIndexMaintenanceDiagnostics()?.events ?? 0
        result["exchange_index_oversized_store_builds_outside_the_turn_then_serves_the_default"] = built && lag == 0
            && fixture.owner.exchangeIndexExists && nextAudit["mode"] as? String == "exchange_packed"
            && (nextAudit["exchange_query"] as? [String: Any])?["index"] as? String == ExchangeBlockQuery.persistentIndexLabel
            && nextAudit["exchange_fallback"] == nil && !next.evidence.isEmpty && next.retrievalNotice == nil
            && maintainedAfter == maintainedBefore + 1 && fixture.owner.exchangeIndexLag() == 0
        return result
    }

    /// The ordinary entry point under a lease, per exchange policy. Both
    /// index sources run on the same recent snapshot in the same episode, so
    /// the store contents are identical: they deliver identical evidence, and
    /// their audits differ only in the equal-length `index` label.
    private static func episodeParity() throws -> [String: Bool] {
        let fixture = try Fixture(label: "episode")
        try fixture.populate(seed: 101, events: 160, conversations: 5)
        let requests = try fixture.conversation()
        try fixture.append(requests, .human, "Synthetic earlier quokka question alpha")
        try fixture.append(requests, .assistant, "Synthetic earlier habitat answer beta")
        _ = try fixture.owner.buildExchangeIndex()
        let clock = Clock()
        let prompt = "Where is the quokka habitat and the \"alpha beta\" release?"
        var result: [String: Bool] = [:]
        for (ordinal, entry) in [("exchange_lexical", ContextComponentPolicy.selectedQwenExchange),
                                 ("exchange_adjacent", .selectedQwenExchangeAdjacent),
                                 ("exchange_packed", .selectedQwenExchangePacked)].enumerated() {
            let (name, policy) = entry
            var limits = EpisodeLimits(); limits.componentPolicy = policy
            let episodeID = UUID().uuidString, humanID = "synthetic-index-request-" + String(ordinal)
            _ = try fixture.owner.acceptRequestAndBeginEpisode(conversationID: requests.id, turnID: humanID + "-turn",
                humanEventID: humanID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            let lease = EpisodeLease(ledger: fixture.owner, episodeID: episodeID, clock: clock)
            defer { _ = try? lease.finish(reason: .cancelled) }
            let recent = try ContextAssembler.prepareRecent(store: fixture.owner, conversationID: requests.id, projectID: fixture.project,
                prompt: prompt, system: "Synthetic index host", excludingEventID: humanID, episodeLease: lease, componentPolicy: policy)
            func prepare(_ source: ExchangeBlockQuery.IndexSource) throws -> ContextSnapshot {
                ExchangeBlockQuery.diagnosticIndexSource = source
                defer { ExchangeBlockQuery.diagnosticIndexSource = .persistent }
                return try ExchangeBlockQuery.prepareEvidence(recent: recent, store: fixture.owner, conversationID: requests.id,
                    projectID: fixture.project, prompt: prompt, excludingEventID: humanID, episodeLease: lease,
                    lexicalQueryUTF8Range: nil, componentPolicy: policy)
            }
            let before = try lease.checkActive()
            let persistent = try prepare(.persistent)
            let after = try lease.checkActive()
            let rebuild = try prepare(.inMemoryRebuild)
            func exchangeAudit(_ snapshot: ContextSnapshot) throws -> [String: Any] {
                let retrieval = try JSONSerialization.jsonObject(with: snapshot.retrievalAuditJSON ?? Data()) as? [String: Any] ?? [:]
                return retrieval["exchange_query"] as? [String: Any] ?? [:]
            }
            var left = try exchangeAudit(persistent), right = try exchangeAudit(rebuild)
            let labels = (left.removeValue(forKey: "index") as? String, right.removeValue(forKey: "index") as? String)
            result["exchange_index_episode_" + name + "_evidence_and_audit_match_rebuild"] = try !persistent.evidence.isEmpty
                && spans(persistent.evidence) == spans(rebuild.evidence)
                && persistent.evidence.map(\.conversationID) == rebuild.evidence.map(\.conversationID)
                && (try JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]))
                    == (try JSONSerialization.data(withJSONObject: right, options: [.sortedKeys]))
                && (try persistent.deliveryAudit().count) == (try rebuild.deliveryAudit().count)
                && labels.0 == ExchangeBlockQuery.persistentIndexLabel && labels.1 == ExchangeBlockQuery.rebuildIndexLabel
            result["exchange_index_episode_" + name + "_is_metered_without_model_or_vector_work"] = after.charged.modelCalls == before.charged.modelCalls
                && after.charged.vectorBytes == before.charged.vectorBytes && after.charged.encoderInputBytes == before.charged.encoderInputBytes
                && after.charged.metadataRows > before.charged.metadataRows && after.charged.rawSourceBytes > before.charged.rawSourceBytes
                && after.limits == before.limits
        }
        return result
    }

    private final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-exchange-index-clock", continuousNanoseconds: 1_000_000,
                utc: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }
}
