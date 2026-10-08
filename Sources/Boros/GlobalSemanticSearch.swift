import Foundation
import CSQLite

/// P2 step 4 evaluation option: which semantic population and fusion the
/// hybrid strategy uses. `.shipped` is ordinary Send and calls
/// `SemanticIndex.search` unchanged. The other modes are explicitly selected
/// by a caller (the offline retrieval harness); no setting or GUI path selects
/// them. They are measured candidates for the decision in
/// docs/P2-SEMANTIC-DECISION.md, not product defaults.
struct SemanticSearchSelection {
    enum Mode: String, Codable, CaseIterable {
        /// SemanticIndex.search: the first 4,096 eligible chunks in source
        /// order, reciprocal-rank fusion with constant 60, lexical window 100.
        case shipped
        /// Every eligible chunk, then the shipped fusion unchanged.
        case globalReciprocalRank = "global_rrf"
        /// Every eligible chunk. Lexical primaries keep their slots and order
        /// (window equal to the result limit, as lexical-only selection);
        /// semantic-only sources fill only the slots lexical leaves empty.
        case globalLexicalFill = "global_fill"
    }
    let mode: Mode
    /// Injectable only for component checks. Nil uses the product adapter,
    /// which must match the index's recorded encoder identity.
    let encoder: SemanticEmbeddingAdapter?

    init(_ mode: Mode, encoder: SemanticEmbeddingAdapter? = nil) { self.mode = mode; self.encoder = encoder }
    static let shipped = SemanticSearchSelection(.shipped)
}

/// Declared before any measurement (P2 step 4). Changing a value requires a
/// new version string and a new measurement.
struct GlobalSemanticSearchParameters: Codable, Equatable {
    let version: String
    let mode: String
    let population: String
    let fusion: String
    let reciprocalRankConstant: Int?
    let lexicalWindow: String
    let maximumVectorRows: Int
    let verification: String

    static func declared(_ mode: SemanticSearchSelection.Mode) -> GlobalSemanticSearchParameters? {
        switch mode {
        case .shipped: return nil
        case .globalReciprocalRank:
            return GlobalSemanticSearchParameters(version: "global-semantic-v1", mode: mode.rawValue,
                population: "every-eligible-chunk-bruteforce-cosine", fusion: "reciprocal-rank-equal-weight",
                reciprocalRankConstant: 60, lexicalWindow: "100", maximumVectorRows: maximumVectorRows,
                verification: "selected-results-only")
        case .globalLexicalFill:
            return GlobalSemanticSearchParameters(version: "global-semantic-v1", mode: mode.rawValue,
                population: "every-eligible-chunk-bruteforce-cosine", fusion: "lexical-first-semantic-fill",
                reciprocalRankConstant: nil, lexicalWindow: "result-limit", maximumVectorRows: maximumVectorRows,
                verification: "selected-results-only")
        }
    }
    /// A population above this bound is refused, never truncated, so a
    /// "global" result cannot silently become a partial one.
    static let maximumVectorRows = 1_048_576
}

struct GlobalSemanticSearchReport {
    let report: SemanticSearchReport
    /// Content-free: identifiers, paths, ranks, counts and timings.
    let audit: [String: Any]
}

/// Brute-force cosine search over every eligible published chunk, read through
/// a separate read-only connection to the semantic sidecar. Eligibility is the
/// predicate SemanticIndex.search applies before its 4,096-row cap. Only the
/// selected results are verified against original sources and re-read, as
/// every delivered byte is; unselected rows contribute only their ranks.
/// No index structure is built and nothing is written to the sidecar, so the
/// returned manifest is not replayable through SemanticIndex.replay.
enum GlobalSemanticSearch {
    private static let productAdapter = AppleSentenceEmbeddingAdapter()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct Entry {
        let eventKey: Data
        let eventID: String
        let sequence: Int
        let offset: Int
        let byteCount: Int
        let textDigest: String
        var source: MemorySourceReference?
        var paths: Set<String>
        var score: Double
        var cosine: Double?
        var lexicalRank: Int?
        var semanticRank: Int?
    }

    static func search(index: SemanticIndex, selection: SemanticSearchSelection, query: String, lexicalQuery: String,
                       projectID: String, limit: Int, excludingSourceIDs excluded: ExactSourceIDs,
                       episodeLease: EpisodeLease?, operationIsNested: Bool = false) throws -> GlobalSemanticSearchReport {
        guard let parameters = GlobalSemanticSearchParameters.declared(selection.mode) else { throw SemanticError.invalid }
        _ = try episodeLease?.checkActive(projectID: projectID)
        guard query.utf8.count <= MemoryStore.maximumPayloadBytes, lexicalQuery.utf8.count <= 4096,
              (1...100).contains(limit), excluded.count <= 10000 else { throw SemanticError.invalid }
        let store = index.store, encoder = selection.encoder ?? productAdapter
        return try MeteredRetrieval.operation(lease: episodeLease, nested: operationIsNested) {
            let started = DispatchTime.now().uptimeNanoseconds
            let frontier = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1) {
                try store.sourceFrontier(projectID: projectID)
            }
            // Lexical primaries: the same metered call as the shipped paths.
            let window = parameters.lexicalWindow == "100" ? 100 : limit
            let lexicalHits: [MemoryHit]
            var lexicalCoverage: MeteredLexicalCoverage?
            if let episodeLease {
                let report = try MeteredRetrieval.lexicalSearch(store: store, query: lexicalQuery, projectID: projectID,
                    limit: window, matching: .anyTerm, throughSequence: frontier, excludingSourceIDs: excluded,
                    lease: episodeLease, nested: true)
                try MeteredRetrieval.requireCompleteReadCoverage(lease: episodeLease, resourceLimited: report.continuation != nil)
                lexicalHits = report.hits; lexicalCoverage = report.coverage
            } else {
                lexicalHits = try store.search(query: lexicalQuery, projectID: projectID, limit: window, matching: .anyTerm,
                    throughSequence: frontier, excludingSourceIDs: excluded)
            }
            let lexicalDone = DispatchTime.now().uptimeNanoseconds
            let encoding: SemanticEncoding
            if let episodeLease, try episodeLease.checkActive().limits.requireKnownModelInput {
                encoding = .unsupported(.inputAccountingUnavailable)
            } else if query.utf8.count > 4096 {
                encoding = .unsupported(.inputTooLarge)
            } else {
                do {
                    encoding = try MeteredRetrieval.charge(lease: episodeLease, kind: .queryEmbedding,
                        resources: EpisodeResources(modelCalls: 1, encoderInputBytes: query.utf8.count),
                        inputTokensKnown: false, identity: index.encoderFingerprint) { try encoder.encode(query) }
                } catch {
                    if error is EpisodeBudgetError || error is MeteredRetrievalError || error is MemoryError { throw error }
                    encoding = .unsupported(.adapterUnavailable)
                }
            }
            let encodeDone = DispatchTime.now().uptimeNanoseconds
            var candidates: [Data: Entry] = [:], lexicalOrder: [Data] = []
            var lexicalRank = 0
            for hit in lexicalHits where !excluded.contains(hit.eventID) {
                guard let source = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1, {
                    try store.sourceReference(eventID: hit.eventID, projectID: projectID)
                }), source.digest == hit.digest, source.byteCount == hit.totalBytes,
                      episodeIdentifierEqual(source.conversationID, hit.conversationID), source.role == hit.role,
                      source.status == hit.status, source.createdAt == hit.createdAt else { throw SemanticError.sourceMismatch }
                guard source.sequence <= frontier else { continue }
                lexicalRank += 1
                let key = Data(hit.eventID.utf8)
                let contribution = 1.0 / Double((parameters.reciprocalRankConstant ?? 60) + lexicalRank)
                if var existing = candidates[key] {
                    existing.paths.insert("lexical"); existing.score += contribution; candidates[key] = existing
                } else {
                    candidates[key] = Entry(eventKey: key, eventID: hit.eventID, sequence: source.sequence, offset: hit.excerptOffset,
                        byteCount: hit.excerpt.utf8.count, textDigest: SemanticIndex.digest(Data(hit.excerpt.utf8)), source: source,
                        paths: ["lexical"], score: contribution, cosine: nil, lexicalRank: lexicalRank, semanticRank: nil)
                    lexicalOrder.append(key)
                }
            }
            let sidecar = try Sidecar(index: index)
            var scan = Sidecar.Scan(rows: 0, publishedFrontier: 0, events: [], coverage: nil)
            var disposition: String
            switch encoding {
            case .unsupported(let reason):
                disposition = reason.rawValue
                scan = try sidecar.read(index: index, encoder: encoder, projectID: projectID, frontier: frontier,
                    excluded: excluded, query: nil, lease: episodeLease)
            case .vector(let values):
                disposition = "supported"
                let normalized = try SemanticIndex.normalized(values, dimension: encoder.dimension)
                scan = try sidecar.read(index: index, encoder: encoder, projectID: projectID, frontier: frontier,
                    excluded: excluded, query: normalized, lease: episodeLease)
            }
            let scanDone = DispatchTime.now().uptimeNanoseconds
            var semanticOrder: [Data] = []
            for (position, event) in scan.events.enumerated() {
                let rank = position + 1, key = event.eventKey
                semanticOrder.append(key)
                let contribution = 1.0 / Double((parameters.reciprocalRankConstant ?? 60) + rank)
                if var existing = candidates[key] {
                    existing.paths.insert("semantic"); existing.cosine = event.cosine; existing.semanticRank = rank
                    if selection.mode == .globalReciprocalRank { existing.score += contribution }
                    candidates[key] = existing
                } else {
                    candidates[key] = Entry(eventKey: key, eventID: event.eventID, sequence: event.sequence, offset: event.offset,
                        byteCount: event.byteCount, textDigest: event.textDigest, source: nil, paths: ["semantic"],
                        score: contribution, cosine: event.cosine, lexicalRank: nil, semanticRank: rank)
                }
            }
            var selected: [Entry]
            switch selection.mode {
            case .globalReciprocalRank:
                selected = Array(candidates.values.sorted { lhs, rhs in
                    if lhs.score != rhs.score { return lhs.score > rhs.score }
                    return rangeOrder(lhs, rhs)
                }.prefix(limit))
            case .globalLexicalFill:
                let lexical = lexicalOrder.prefix(limit).map { candidates[$0]! }
                let taken = Set(lexical.map(\.eventKey))
                let fill = semanticOrder.filter { !taken.contains($0) }.prefix(limit - lexical.count).map { candidates[$0]! }
                selected = lexical + fill
                for position in selected.indices { selected[position].score = 1.0 / Double(position + 1) }
            case .shipped: throw SemanticError.invalid
            }
            for position in selected.indices where selected[position].source == nil {
                selected[position].source = try sidecar.source(index: index, eventID: selected[position].eventID, projectID: projectID)
                guard let source = selected[position].source, source.sequence == selected[position].sequence,
                      try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1, {
                          try store.sourceReference(eventID: source.eventID, projectID: projectID)
                      }) == source else { throw SemanticError.sourceMismatch }
            }
            let fuseDone = DispatchTime.now().uptimeNanoseconds
            let results = selected.map { entry in
                SemanticResultReference(source: entry.source!, offset: entry.offset, byteCount: entry.byteCount,
                    excerptDigest: entry.textDigest, retrievalPaths: entry.paths.sorted(), fusedScore: entry.score,
                    cosineScore: entry.cosine)
            }
            let hits = try results.map { result -> MemoryHit in
                guard !excluded.contains(result.source.eventID), episodeIdentifierEqual(result.source.projectID, projectID),
                      result.source.sequence <= frontier, result.offset >= 0, result.byteCount > 0,
                      result.byteCount <= MemoryStore.maximumPageBytes, result.offset <= result.source.byteCount,
                      result.byteCount <= result.source.byteCount - result.offset else { throw SemanticError.sourceMismatch }
                let page = try MeteredRetrieval.read(store: store, source: result.source, offset: result.offset,
                    length: result.byteCount, lease: episodeLease, nested: true, examinedPasses: 2)
                guard page.byteCount == result.byteCount, page.digest == result.source.digest, page.totalBytes == result.source.byteCount,
                      page.status == result.source.status, SemanticIndex.digest(Data(page.text.utf8)) == result.excerptDigest else {
                    throw SemanticError.sourceMismatch
                }
                return MemoryHit(eventID: result.source.eventID, conversationID: result.source.conversationID, projectID: result.source.projectID,
                    role: result.source.role, status: result.source.status, createdAt: result.source.createdAt, digest: result.source.digest,
                    totalBytes: result.source.byteCount, excerptOffset: result.offset, excerpt: page.text, sourceTime: result.source.sourceTime)
            }
            let readDone = DispatchTime.now().uptimeNanoseconds
            let parameterDigest = SemanticIndex.digest(try SemanticIndex.canonical(parameters))
            let lexicalDigest = SemanticIndex.digest(Data(lexicalQuery.utf8))
            let exclusionsDigest = SemanticIndex.digest(try SemanticIndex.canonical(excluded.sorted()))
            var queryConfiguration = ["include_literal": "false", "result_limit": String(limit), "lexical_query": lexicalDigest,
                "excluded_ids": exclusionsDigest, "lexical_matching": "anyTerm", "ranking": parameterDigest]
            if let episodeLease { queryConfiguration["episode_id"] = episodeLease.episodeID; queryConfiguration["raw_work"] = "raw_work_v1" }
            let rawCandidates = lexicalOrder.map { candidates[$0]!.eventID }
            var manifest = SemanticSearchManifest(version: 1, projectID: projectID, queryDigest: SemanticIndex.digest(Data(query.utf8)),
                lexicalQueryDigest: lexicalDigest, indexFingerprint: index.indexFingerprint, encoderFingerprint: index.encoderFingerprint,
                rankingFingerprint: parameterDigest, configurationFingerprint: parameterDigest, configuration: index.configuration,
                queryConfigurationFingerprint: SemanticIndex.digest(try SemanticIndex.canonical(queryConfiguration)),
                resultLimit: limit, sourceFrontier: frontier, publishedChunkFrontier: scan.publishedFrontier,
                queryDisposition: disposition, includeLiteral: false, literalScanBytes: 0, literalSearchPerformed: false,
                rawSnapshotID: SemanticIndex.digest(try SemanticIndex.canonical(rawCandidates)), rawFallbackAvailable: true,
                coverage: scan.coverage!, vectorCandidatesInspected: scan.rows, vectorContinuation: nil,
                excludedEventIDs: excluded.sorted(), results: results)
            manifest.episodeID = episodeLease?.episodeID
            manifest.meteredLexicalCoverage = lexicalCoverage
            let payload = try SemanticIndex.canonical(manifest)
            guard payload.count <= MemoryStore.maximumPayloadBytes else { throw SemanticError.invalid }
            func milliseconds(_ from: UInt64, _ to: UInt64) -> Double { (Double(to - from) / 1_000).rounded() / 1_000 }
            // Compact on purpose: the delivery audit is capped at 32 KiB and
            // drops the selection trace first. Per-result paths and ranks are
            // in the returned manifest; the audit keeps identity, size, timing.
            let audit: [String: Any] = ["parameters_sha256": parameterDigest, "eligible_vector_rows": scan.rows,
                "milliseconds": ["lexical": milliseconds(started, lexicalDone), "encode": milliseconds(lexicalDone, encodeDone),
                    "vector_scan": milliseconds(encodeDone, scanDone), "vector_loop": milliseconds(0, scan.loopNanoseconds),
                    "fuse": milliseconds(scanDone, fuseDone), "read": milliseconds(fuseDone, readDone),
                    "total": milliseconds(started, readDone)]]
            return GlobalSemanticSearchReport(report: SemanticSearchReport(hits: hits, manifestID: SemanticIndex.digest(payload),
                manifest: manifest), audit: audit)
        }
    }

    /// Same tie order as SemanticIndex: source sequence, exact event ID, offset.
    private static func rangeOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.eventID != rhs.eventID { return lhs.eventID < rhs.eventID }
        return lhs.offset < rhs.offset
    }

    /// Read-only, query-only connection. One deferred read transaction gives
    /// the frontier, identity, coverage and population a single snapshot.
    private final class Sidecar {
        struct Event { let eventKey: Data; let eventID: String; let sequence: Int; let offset: Int; let byteCount: Int; let textDigest: String; let cosine: Double }
        struct Scan { var rows: Int; var publishedFrontier: Int; var events: [Event]; var coverage: SemanticCoverage?; var loopNanoseconds: UInt64 = 0 }
        private var database: OpaquePointer?

        init(index: SemanticIndex) throws {
            let path = index.directory.appendingPathComponent("index.sqlite3").path
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, database != nil else {
                if let database { sqlite3_close(database) }; database = nil
                throw SemanticError.database
            }
            sqlite3_busy_timeout(database, 5000)
            try execute("PRAGMA query_only=1")
        }
        deinit { if let database { sqlite3_close(database) } }

        func read(index: SemanticIndex, encoder: SemanticEmbeddingAdapter, projectID: String, frontier: Int,
                  excluded: ExactSourceIDs, query: [Float]?, lease: EpisodeLease?) throws -> Scan {
            guard let database else { throw SemanticError.database }
            let body = { () throws -> Scan in
                try self.execute("BEGIN")
                defer { try? self.execute("COMMIT") }
                // The adapter must be the one that produced the stored vectors.
                guard let stored = try self.rows("SELECT metadata FROM versions WHERE id=?", [.text(index.indexFingerprint)], { self.blob($0, 0) }).first,
                      let metadata = try JSONSerialization.jsonObject(with: stored) as? [String: String],
                      SemanticIndex.digest(try SemanticIndex.canonical(metadata.merging(["declared_dimension": String(encoder.dimension)]) { _, actual in actual }))
                        == index.encoderFingerprint,
                      metadata.filter({ $0.key != "probe_digest" }) == encoder.metadata.filter({ $0.key != "probe_digest" }) else {
                    throw SemanticError.invalid
                }
                let published = try MeteredRetrieval.metadata(lease: lease, maximumRows: 1) {
                    try self.integer("SELECT coalesce(max(publication),0) FROM chunks WHERE index_id=? AND project_id=?",
                        [.text(index.indexFingerprint), .text(projectID)])
                }
                let coverage = try MeteredRetrieval.metadata(lease: lease, maximumRows: 2) {
                    try self.coverage(index: index, projectID: projectID, frontier: frontier, published: published)
                }
                guard let query else { return Scan(rows: 0, publishedFrontier: published, events: [], coverage: coverage) }
                var predicate = " FROM chunks c JOIN jobs j ON j.index_id=c.index_id AND j.event_id=c.event_id WHERE c.index_id=? AND c.project_id=? AND c.source_sequence<=? AND c.publication<=? AND j.ready_publication>0 AND j.ready_publication<=? AND c.reason='' AND j.state IN ('complete','unsupported')"
                var bindings: [Value] = [.text(index.indexFingerprint), .text(projectID), .integer(frontier), .integer(published), .integer(published)]
                if !excluded.isEmpty {
                    predicate += " AND c.event_id NOT IN (SELECT value FROM json_each(?))"
                    bindings.append(.text(String(decoding: try SemanticIndex.canonical(excluded.sorted()), as: UTF8.self)))
                }
                let count = try MeteredRetrieval.metadata(lease: lease, maximumRows: 1) { try self.integer("SELECT count(*)" + predicate, bindings) }
                guard count <= GlobalSemanticSearchParameters.maximumVectorRows else { throw SemanticError.invalid }
                let dimension = encoder.dimension, width = dimension * 4
                guard query.count == dimension else { throw SemanticError.invalid }
                var best: [Data: Event] = [:], scanned = 0
                var loopStarted: UInt64 = 0
                try MeteredRetrieval.charge(lease: lease, resources: EpisodeResources(
                    vectorBytes: try MeteredRetrieval.checkedProduct(count, width + 1), metadataRows: count)) {
                    loopStarted = DispatchTime.now().uptimeNanoseconds
                    let statement = try self.prepare("SELECT c.event_id,c.source_sequence,c.offset,c.byte_count,c.text_digest,substr(c.vector,1,?),length(c.vector)" + predicate,
                        [.integer(width + 1)] + bindings)
                    defer { sqlite3_finalize(statement) }
                    while true {
                        let step = sqlite3_step(statement)
                        if step == SQLITE_DONE { break }
                        guard step == SQLITE_ROW else { throw SemanticError.database }
                        scanned += 1
                        guard scanned <= count, Int(sqlite3_column_int64(statement, 6)) == width,
                              Int(sqlite3_column_bytes(statement, 5)) == width, let pointer = sqlite3_column_blob(statement, 5) else {
                            throw SemanticError.sourceMismatch
                        }
                        // Same arithmetic as SemanticIndex: little-endian float32,
                        // unit-norm check, then a Double dot product in order.
                        let raw = UnsafeRawPointer(pointer)
                        var norm = 0.0, dot = 0.0
                        for component in 0..<dimension {
                            let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: component * 4, as: UInt32.self)))
                            guard value.isFinite else { throw SemanticError.sourceMismatch }
                            norm += Double(value) * Double(value)
                            dot += Double(value) * Double(query[component])
                        }
                        guard abs(norm - 1) < 0.001 else { throw SemanticError.sourceMismatch }
                        let eventID = self.string(statement, 0), key = Data(eventID.utf8)
                        let event = Event(eventKey: key, eventID: eventID, sequence: Int(sqlite3_column_int64(statement, 1)),
                            offset: Int(sqlite3_column_int64(statement, 2)), byteCount: Int(sqlite3_column_int64(statement, 3)),
                            textDigest: self.string(statement, 4), cosine: max(-1, min(1, dot)))
                        // One range per source: the best chunk, earliest on ties.
                        if let current = best[key], current.cosine > event.cosine || (current.cosine == event.cosine && current.offset < event.offset) { continue }
                        best[key] = event
                    }
                }
                guard scanned == count else { throw SemanticError.sourceMismatch }
                let events = best.values.sorted { lhs, rhs in
                    if lhs.cosine != rhs.cosine { return lhs.cosine > rhs.cosine }
                    if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                    if lhs.eventID != rhs.eventID { return lhs.eventID < rhs.eventID }
                    return lhs.offset < rhs.offset
                }
                return Scan(rows: scanned, publishedFrontier: published, events: events, coverage: coverage,
                    loopNanoseconds: DispatchTime.now().uptimeNanoseconds - loopStarted)
            }
            guard let lease else { return try body() }
            return try lease.progressGuard().perform(on: database, body)
        }

        func source(index: SemanticIndex, eventID: String, projectID: String) throws -> MemorySourceReference? {
            guard let data = try rows("SELECT source FROM jobs WHERE index_id=? AND event_id=? AND project_id=?",
                [.text(index.indexFingerprint), .text(eventID), .text(projectID)], { self.blob($0, 0) }).first else { return nil }
            return try JSONDecoder().decode(MemorySourceReference.self, from: data)
        }

        /// Aggregate counts only; per-source rows and hole ranges are not listed.
        private func coverage(index: SemanticIndex, projectID: String, frontier: Int, published: Int) throws -> SemanticCoverage {
            let scope: [Value] = [.text(index.indexFingerprint), .text(projectID), .integer(frontier)]
            let jobs = try rows("SELECT count(*),coalesce(sum(state IN ('complete','unsupported')),0),coalesce(sum(state IN ('pending','processing')),0),coalesce(sum(state='failed'),0),coalesce(sum(CAST(json_extract(CAST(source AS TEXT),'$.byteCount') AS INTEGER)),0) FROM jobs WHERE index_id=? AND project_id=? AND source_sequence<=?", scope) {
                (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)), Int(sqlite3_column_int64($0, 2)), Int(sqlite3_column_int64($0, 3)), Int(sqlite3_column_int64($0, 4)))
            }.first!
            let chunks = try rows("SELECT coalesce(sum(CASE WHEN reason='' THEN byte_count ELSE 0 END),0),coalesce(sum(reason=''),0),coalesce(sum(reason!=''),0),count(DISTINCT CASE WHEN reason!='' THEN event_id END) FROM chunks WHERE index_id=? AND project_id=? AND source_sequence<=? AND publication<=?", scope + [.integer(published)]) {
                (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)), Int(sqlite3_column_int64($0, 2)), Int(sqlite3_column_int64($0, 3)))
            }.first!
            return SemanticCoverage(inspectedSources: jobs.0, completeSources: jobs.1 - chunks.3, pendingSources: jobs.2,
                unsupportedSources: chunks.3, failedSources: jobs.3, indexedBytes: chunks.0, inspectedSourceBytes: jobs.4,
                indexedChunks: chunks.1, unsupportedChunks: chunks.2, metadataContinuationSequence: nil, holes: [],
                holesTruncated: chunks.2 > 0, sources: [])
        }

        enum Value { case text(String), integer(Int) }
        private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticError.database }
            for (offset, value) in values.enumerated() {
                let position = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, GlobalSemanticSearch.transient)
                case .integer(let number): result = sqlite3_bind_int64(statement, position, Int64(number))
                }
                guard result == SQLITE_OK else { sqlite3_finalize(statement); throw SemanticError.database }
            }
            return statement
        }
        private func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SemanticError.database }
        }
        private func rows<T>(_ sql: String, _ values: [Value], _ map: (OpaquePointer) throws -> T) throws -> [T] {
            let statement = try prepare(sql, values)
            defer { sqlite3_finalize(statement) }
            var output: [T] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return output }
                guard step == SQLITE_ROW else { throw SemanticError.database }
                output.append(try map(statement))
            }
        }
        private func integer(_ sql: String, _ values: [Value]) throws -> Int { try rows(sql, values) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
        private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(decoding: UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
        }
        private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
            guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }
}
