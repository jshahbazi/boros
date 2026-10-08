import Foundation
import CSQLite

/// Synthetic scale measurement for the P2 step 4 global semantic search.
///
/// Builds a disposable store with ROWS synthetic events and a semantic sidecar
/// holding one published 512-dimension unit vector per event, written directly
/// in the sidecar's schema (no encoder inference), then times
/// GlobalSemanticSearch.search, the committed code path, for REPEATS
/// synthetic queries without an episode lease, and once with the default
/// episode limits to record whether the vector budget admits the scan.
/// Everything is synthetic; output is counts and timings only.
///
/// Usage: GlobalSemanticScale ROWS REPEATS NEW_ABS_OUTPUT_JSON
@main
enum GlobalSemanticScale {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, let rows = Int(args[0]), (1...2_000_000).contains(rows), let repeats = Int(args[1]),
              (1...50).contains(repeats), args[2].hasPrefix("/"), !FileManager.default.fileExists(atPath: args[2]) else {
            fputs("Usage: GlobalSemanticScale ROWS REPEATS NEW_ABS_OUTPUT_JSON\n", stderr); exit(2)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("boros-global-scale-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let result = try measure(rows: rows, repeats: repeats, directory: directory)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileManager.default.createFile(atPath: args[2], contents: data, attributes: [.posixPermissions: 0o600])
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            fputs("Global semantic scale measurement failed: " + String(describing: type(of: error)) + ".\n", stderr); exit(1)
        }
    }

    static func measure(rows: Int, repeats: Int, directory: URL) throws -> [String: Any] {
        var generator = SplitMix(seed: 0x5eed_0002_0004)
        let started = DispatchTime.now().uptimeNanoseconds
        let store = try MemoryStore(directory: directory)
        let project = "synthetic-global-scale"
        let conversation = try store.createConversation(projectID: project, title: "Synthetic scale archive")
        for index in 0..<rows {
            _ = try store.append(conversationID: conversation.id, role: index % 2 == 0 ? .human : .assistant,
                text: "Synthetic scale event \(index) with filler words for a short source.", status: .complete,
                turnID: "scale-turn-\(index)", eventID: "scale-event-\(index)")
        }
        let ingested = DispatchTime.now().uptimeNanoseconds
        let encoder = Encoder(seed: generator.next())
        let index = try SemanticIndex(store: store, encoder: encoder)
        try populate(index: index, store: store, project: project, rows: rows, generator: &generator)
        let populated = DispatchTime.now().uptimeNanoseconds
        var totals: [Double] = [], loops: [Double] = [], scans: [Double] = []
        let selection = SemanticSearchSelection(.globalReciprocalRank, encoder: encoder)
        for _ in 0..<repeats {
            let report = try GlobalSemanticSearch.search(index: index, selection: selection, query: "synthetic query",
                lexicalQuery: "absentscaleterm", projectID: project, limit: 16, excludingSourceIDs: ExactSourceIDs([]), episodeLease: nil)
            guard report.audit["eligible_vector_rows"] as? Int == rows, report.report.hits.count == 16 else { throw SemanticError.invalid }
            let timing = report.audit["milliseconds"] as? [String: Double] ?? [:]
            totals.append(timing["total"] ?? -1); loops.append(timing["vector_loop"] ?? -1); scans.append(timing["vector_scan"] ?? -1)
        }
        // Default episode limits: does the per-episode vector budget admit it?
        let chat = try store.createConversation(projectID: project, title: "Synthetic scale request")
        let episodeID = UUID().uuidString, clock = Clock()
        _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "scale-request", humanEventID: "scale-request-event",
            episodeID: episodeID, text: "synthetic query", limits: EpisodeLimits(), clock: clock.now())
        let lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
        var leased: [String: Any] = ["vector_bytes_cap": EpisodeLimits().resources.vectorBytes, "metadata_rows_cap": EpisodeLimits().resources.metadataRows,
                                     "vector_bytes_required": rows * (encoder.dimension * 4 + 1)]
        do {
            let report = try GlobalSemanticSearch.search(index: index, selection: selection, query: "synthetic query",
                lexicalQuery: "absentscaleterm", projectID: project, limit: 16, excludingSourceIDs: ExactSourceIDs(["scale-request-event"]),
                episodeLease: lease)
            leased["admitted"] = true
            leased["total_milliseconds"] = (report.audit["milliseconds"] as? [String: Double])?["total"] ?? NSNull()
        } catch let error as EpisodeBudgetError {
            leased["admitted"] = false; leased["failure"] = error.failureCode
        }
        _ = try? lease.finish(reason: .cancelled)
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let ordered = values.sorted(); return ordered[max(0, Int((fraction * Double(ordered.count)).rounded(.up)) - 1)]
        }
        return ["version": "global-semantic-scale-v1", "rows": rows, "dimension": encoder.dimension, "repeats": repeats,
                "vector_bytes": rows * encoder.dimension * 4,
                "setup_seconds": ["ingest": Double(ingested - started) / 1e9, "populate": Double(populated - ingested) / 1e9],
                "unleased_milliseconds": ["total_p50": percentile(totals, 0.5), "total_max": totals.max()!,
                    "vector_scan_p50": percentile(scans, 0.5), "vector_loop_p50": percentile(loops, 0.5), "vector_loop_max": loops.max()!],
                "default_episode_limits": leased]
    }

    /// Writes one complete job and one unit vector per source in the sidecar's
    /// own schema, so search eligibility and source verification apply unchanged.
    static func populate(index: SemanticIndex, store: MemoryStore, project: String, rows: Int, generator: inout SplitMix) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(index.directory.appendingPathComponent("index.sqlite3").path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw SemanticError.database }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5000)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func run(_ sql: String) throws { guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SemanticError.database } }
        func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticError.database }
            return statement
        }
        try run("BEGIN IMMEDIATE")
        let job = try prepare("INSERT INTO jobs(index_id,event_id,project_id,source_sequence,source,next_offset,indexed_bytes,indexed_chunks,ready_publication,state) VALUES (?,?,?,?,?,?,?,1,?,'complete')")
        let chunk = try prepare("INSERT INTO chunks(publication,index_id,event_id,source_sequence,project_id,offset,byte_count,text_digest,vector,reason) VALUES (?,?,?,?,?,0,?,?,?,'')")
        defer { sqlite3_finalize(job); sqlite3_finalize(chunk) }
        for position in 0..<rows {
            guard let source = try store.sourceReference(eventID: "scale-event-\(position)", projectID: project) else { throw SemanticError.invalid }
            let page = try store.read(eventID: source.eventID, offset: 0, length: source.byteCount)
            let vector = SemanticIndex.vectorData(try SemanticIndex.normalized((0..<512).map { _ in generator.unit() }, dimension: 512))
            let sourceData = try SemanticIndex.canonical(source)
            sqlite3_reset(job); sqlite3_reset(chunk)
            sqlite3_bind_text(job, 1, index.indexFingerprint, -1, transient); sqlite3_bind_text(job, 2, source.eventID, -1, transient)
            sqlite3_bind_text(job, 3, project, -1, transient); sqlite3_bind_int64(job, 4, Int64(source.sequence))
            _ = sourceData.withUnsafeBytes { sqlite3_bind_blob(job, 5, $0.baseAddress, Int32(sourceData.count), transient) }
            sqlite3_bind_int64(job, 6, Int64(source.byteCount)); sqlite3_bind_int64(job, 7, Int64(source.byteCount))
            sqlite3_bind_int64(job, 8, Int64(position + 1))
            guard sqlite3_step(job) == SQLITE_DONE else { throw SemanticError.database }
            sqlite3_bind_int64(chunk, 1, Int64(position + 1)); sqlite3_bind_text(chunk, 2, index.indexFingerprint, -1, transient)
            sqlite3_bind_text(chunk, 3, source.eventID, -1, transient); sqlite3_bind_int64(chunk, 4, Int64(source.sequence))
            sqlite3_bind_text(chunk, 5, project, -1, transient); sqlite3_bind_int64(chunk, 6, Int64(source.byteCount))
            sqlite3_bind_text(chunk, 7, SemanticIndex.digest(Data(page.text.utf8)), -1, transient)
            _ = vector.withUnsafeBytes { sqlite3_bind_blob(chunk, 8, $0.baseAddress, Int32(vector.count), transient) }
            guard sqlite3_step(chunk) == SQLITE_DONE else { throw SemanticError.database }
        }
        try run("COMMIT")
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1 }
    }

    final class Encoder: SemanticEmbeddingAdapter {
        let dimension = 512
        let metadata = ["provider": "synthetic-global-scale", "revision": "1"]
        private var generator: SplitMix
        init(seed: UInt64) { generator = SplitMix(seed: seed) }
        func encode(_ text: String) throws -> SemanticEncoding { .vector((0..<512).map { _ in generator.unit() }) }
    }

    final class Clock: EpisodeClockSource {
        func now() throws -> EpisodeClockSnapshot {
            EpisodeClockSnapshot(domain: "synthetic-global-scale-clock", continuousNanoseconds: 1_000_000_000, utc: Date())
        }
    }
}
