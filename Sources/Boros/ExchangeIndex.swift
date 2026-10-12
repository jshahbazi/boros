import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Persistent exchange index for the explicit P2 exchange policies.
///
/// A derived sidecar (`<store>/exchange-index/index.sqlite3`), like the
/// semantic sidecar: it is never authoritative, is not part of a backup
/// archive, and is rebuilt from exact store sources when absent or stale.
/// It holds exactly the statistics the per-turn in-memory rebuild derived
/// from every source, so ranking no longer reads every payload:
///
/// - `sources`: one row per indexed event (identity, role, bytes, digest and
///   the start sequence of its exchange block).
/// - `conversations`: first sequence, open (last) block and the term IDs that
///   block already contains, so a growing block counts each term once.
/// - `projects`: block and source counts and the highest indexed sequence.
/// - `terms`: per-project term dictionary with block document frequency.
/// - `postings`: per-term append-only chunks of (block, term count) entries.
///   A reply that extends an existing block appends a further entry for the
///   same block; a reader sums them.
/// - `block_log`: per-project append-only chunks of block creation and
///   growth entries (conversation first sequence, bytes, sources).
///
/// Maintenance is incremental: after each committed event insertion the owner
/// applies the new events, and every read first catches up from a sequence
/// watermark. Events are append-only in the current store; a watermark event
/// or per-project inventory that no longer matches the store resets the
/// sidecar, and a read that finds sidecar and store metadata disagreeing
/// fails closed. Folded terms are derived private content; the file and
/// directory are owner-only, like the store.
final class ExchangeIndexStore {
    static let format = "boros-exchange-index-v1"
    static let directoryName = "exchange-index"
    static let fileName = "index.sqlite3"
    /// Entries per append-only chunk.
    static let chunkEntries = 128
    /// Declared raw-work bound per chunk row read (128 entries of at most 32 bytes).
    static let declaredChunkBytes = 4_096
    /// A turn indexes at most this many unindexed events before it ranks;
    /// more fail closed and require `MemoryStore.buildExchangeIndex()`.
    static let maximumTurnCatchUp = 2_000

    enum Value { case integer(Int), text(String), blob(Data), null }

    struct SourceRow: Equatable {
        let sequence: Int
        let eventID: String
        let projectID: String
        let conversationID: String
        let role: MemoryRole
        let byteCount: Int
        let digest: String
        let block: Int
    }

    struct BlockAttributes: Equatable {
        let conversationFirst: Int
        var bytes: Int
        var sources: Int
    }

    struct CatchUp: Equatable {
        var events = 0
        var bytes = 0
        var milliseconds = 0.0
        var reset = false
    }

    let directory: URL
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    /// Incremented by every reset; a turn's view refuses a changed generation.
    private(set) var generation = 0
    private(set) var watermark = 0
    private var watermarkEventID = ""
    private var watermarkDigest = ""
    /// Diagnostics: committed-event maintenance work in this process.
    private(set) var eagerEvents = 0
    private(set) var eagerNanoseconds: UInt64 = 0

    static func directory(storeDirectory: URL) -> URL { storeDirectory.appendingPathComponent(directoryName, isDirectory: true) }

    static func exists(storeDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory(storeDirectory: storeDirectory).appendingPathComponent(fileName).path)
    }

    init(storeDirectory: URL) throws {
        directory = Self.directory(storeDirectory: storeDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var metadata = stat()
            guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
                  chmod(directory.path, 0o700) == 0 else { throw MemoryError.invalid("exchange index directory must be private") }
            let path = directory.appendingPathComponent(Self.fileName).path
            Darwin.close(try Self.openPrivate(path))
            try secureSidecars()
            guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw MemoryError.database("exchange index could not open")
            }
            sqlite3_busy_timeout(database, 5000)
            _ = try rows("PRAGMA journal_mode=WAL") { _ in 0 }
            // Derived data: a lost tail transaction only lowers the watermark.
            try run("PRAGMA synchronous=NORMAL")
            let version = try scalar("PRAGMA user_version") ?? 0
            guard version == 0 || version == 1 else { throw MemoryError.invalid("unsupported exchange index schema") }
            try transaction {
                for sql in Self.schema { try run(sql) }
                try run("PRAGMA user_version=1")
            }
            try secureSidecars()
            try loadMeta()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    private func close() {
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        if let database { sqlite3_close(database); self.database = nil }
    }

    static let schema = [
        "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID",
        """
        CREATE TABLE IF NOT EXISTS sources (
          sequence INTEGER PRIMARY KEY, event_id TEXT NOT NULL, project_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
          role TEXT NOT NULL CHECK(role IN ('human','assistant')), byte_count INTEGER NOT NULL CHECK(byte_count>=0),
          digest TEXT NOT NULL, block INTEGER NOT NULL CHECK(block>0 AND block<=sequence))
        """,
        "CREATE INDEX IF NOT EXISTS sources_conversation ON sources(conversation_id, sequence)",
        "CREATE INDEX IF NOT EXISTS sources_block ON sources(block, sequence)",
        """
        CREATE TABLE IF NOT EXISTS conversations (conversation_id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
          first_sequence INTEGER NOT NULL, open_block INTEGER NOT NULL, open_terms BLOB NOT NULL) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS projects (project_id TEXT PRIMARY KEY, block_count INTEGER NOT NULL,
          source_count INTEGER NOT NULL, max_sequence INTEGER NOT NULL, block_chunks INTEGER NOT NULL) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS terms (id INTEGER PRIMARY KEY, project_id TEXT NOT NULL, term TEXT NOT NULL,
          document_frequency INTEGER NOT NULL CHECK(document_frequency>=0), chunks INTEGER NOT NULL CHECK(chunks>=0),
          UNIQUE(project_id, term))
        """,
        """
        CREATE TABLE IF NOT EXISTS postings (term INTEGER NOT NULL, chunk INTEGER NOT NULL, entries INTEGER NOT NULL,
          last_block INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(term, chunk)) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS block_log (project_id TEXT NOT NULL, chunk INTEGER NOT NULL, entries INTEGER NOT NULL,
          last_block INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(project_id, chunk)) WITHOUT ROWID
        """,
    ]
    static let tables = ["meta", "sources", "conversations", "projects", "terms", "postings", "block_log"]

    // MARK: Binding and reset

    private func loadMeta() throws {
        var values: [String: String] = [:]
        for (key, value) in try rows("SELECT key, value FROM meta", [], { (Self.text($0, 0), Self.text($0, 1)) }) { values[key] = value }
        guard values["format"] == Self.format, values["terms"] == ExchangeTerms.identity,
              let mark = values["watermark"].flatMap(Int.init), mark >= 0 else {
            try reset(); return
        }
        watermark = mark; watermarkEventID = values["watermark_event_id"] ?? ""; watermarkDigest = values["watermark_digest"] ?? ""
    }

    /// Discards every derived row; the next catch-up rebuilds from sequence 0.
    func reset() throws {
        try transaction {
            for table in Self.tables { try run("DELETE FROM " + table) }
            try writeMeta(["format": Self.format, "terms": ExchangeTerms.identity,
                "watermark": "0", "watermark_event_id": "", "watermark_digest": ""])
        }
        watermark = 0; watermarkEventID = ""; watermarkDigest = ""
        generation += 1
    }

    private func writeMeta(_ values: [String: String]) throws {
        for (key, value) in values { try run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)]) }
    }

    /// Called once per open by the owner. The watermark event and the number
    /// of events through it must still match the store; otherwise (another
    /// store's sidecar, a replaced database, removed events) the sidecar is
    /// reset and rebuilt from the exact store sources.
    func validateBinding(store: MemoryStore) throws {
        guard watermark > 0 else { return }
        let binding = try store.exchangeIndexEventBinding(sequence: watermark)
        let indexed = try scalar("SELECT count(*) FROM sources") ?? -1
        guard let binding, episodeIdentifierEqual(binding.eventID, watermarkEventID), binding.digest == watermarkDigest,
              try store.exchangeIndexEventCount(throughSequence: watermark) == indexed else {
            try reset(); return
        }
    }

    // MARK: Maintenance

    /// Indexes committed store events after the watermark, in sequence order.
    @discardableResult
    func catchUp(store: MemoryStore, maximumEvents: Int, batchEvents: Int = 1_000) throws -> CatchUp {
        let started = DispatchTime.now().uptimeNanoseconds
        var receipt = CatchUp()
        let writer = try Writer(index: self)
        while receipt.events < maximumEvents {
            let batch = try store.exchangeIndexEvents(afterSequence: watermark, limit: min(batchEvents, maximumEvents - receipt.events))
            if batch.isEmpty { break }
            try transaction {
                for event in batch { try writer.apply(event) }
                try writer.flush()
            }
            commit(writer)
            receipt.events += batch.count
            receipt.bytes += batch.reduce(0) { $0 + $1.byteCount }
        }
        receipt.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return receipt
    }

    /// Applies events the owner has just committed, when the index is
    /// current up to them; otherwise it leaves them to the next build or
    /// turn catch-up.
    func applyCommitted(_ events: [ExchangeIndexEvent], store: MemoryStore) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { eagerNanoseconds &+= DispatchTime.now().uptimeNanoseconds - started }
        let fresh = events.filter { $0.sequence > watermark }
        guard let first = fresh.first else { return }
        // A lagging index (never built, or a build still running) is brought
        // up to date by `MemoryStore.buildExchangeIndex()` off the append
        // path, never inside a committing writer's call.
        guard try store.exchangeIndexEventCount(after: watermark, before: first.sequence) == 0 else { return }
        let writer = try Writer(index: self)
        try transaction {
            for event in fresh { try writer.apply(event) }
            try writer.flush()
        }
        commit(writer)
        eagerEvents += fresh.count
    }

    private func commit(_ writer: Writer) {
        watermark = writer.watermark; watermarkEventID = writer.watermarkEventID; watermarkDigest = writer.watermarkDigest
    }

    /// Batch writer. Caches are valid only while this process is the single
    /// writer, which the store's exclusive owner lock guarantees.
    private final class Writer {
        struct Project { var blockCount: Int; var sourceCount: Int; var maximumSequence: Int; var blockChunks: Int; var dirty: Bool }
        struct Conversation { let projectID: String; let first: Int; var openBlock: Int; var openTerms: Set<Int64>; var dirty: Bool }
        struct Term { let id: Int64; let projectID: String; let term: String; var documentFrequency: Int; var chunks: Int; var dirty: Bool }
        struct Tail { var chunk: Int; var entries: Int; var last: Int; var payload: Data; var dirty: Bool }

        unowned let index: ExchangeIndexStore
        var watermark: Int, watermarkEventID: String, watermarkDigest: String
        var projects: [Data: Project] = [:]
        var conversations: [Data: Conversation] = [:]
        var terms: [Data: Term] = [:]
        var postingTails: [Int64: Tail] = [:]
        var blockTails: [Data: Tail] = [:]
        var nextTermID: Int64

        init(index: ExchangeIndexStore) throws {
            self.index = index
            watermark = index.watermark; watermarkEventID = index.watermarkEventID; watermarkDigest = index.watermarkDigest
            nextTermID = Int64(try index.scalar("SELECT coalesce(max(id), 0) + 1 FROM terms") ?? 1)
        }

        func apply(_ event: ExchangeIndexEvent) throws {
            guard event.sequence > watermark, event.byteCount >= 0, event.byteCount == event.text.utf8.count else {
                throw ExchangeIndexError.mismatch
            }
            let projectKey = Data(event.projectID.utf8), conversationKey = Data(event.conversationID.utf8)
            var project = try projectState(projectKey, event.projectID)
            var conversation: Conversation
            let newBlock: Bool
            if var known = try conversationState(conversationKey, event.conversationID) {
                guard episodeIdentifierEqual(known.projectID, event.projectID) else { throw ExchangeIndexError.mismatch }
                newBlock = event.role == .human
                if newBlock { known.openBlock = event.sequence; known.openTerms = [] }
                conversation = known
            } else {
                newBlock = true
                conversation = Conversation(projectID: event.projectID, first: event.sequence, openBlock: event.sequence,
                    openTerms: [], dirty: true)
            }
            conversation.dirty = true
            let block = conversation.openBlock
            if newBlock { project.blockCount += 1 }
            try appendBlockLog(projectKey, event.projectID, project: &project, block: block, newBlock: newBlock,
                first: conversation.first, bytes: event.byteCount)
            var counts: [String: Int] = [:]
            for term in ExchangeTerms.terms(event.text) { counts[term, default: 0] += 1 }
            for (term, count) in counts {
                let normalized = term.precomposedStringWithCanonicalMapping
                var state = try termState(projectKey, event.projectID, normalized)
                if conversation.openTerms.insert(state.id).inserted { state.documentFrequency += 1; state.dirty = true }
                try appendPosting(&state, block: block, count: count)
                terms[Self.termKey(projectKey, normalized)] = state
            }
            try index.run("INSERT INTO sources (sequence, event_id, project_id, conversation_id, role, byte_count, digest, block) VALUES (?,?,?,?,?,?,?,?)",
                [.integer(event.sequence), .text(event.eventID), .text(event.projectID), .text(event.conversationID),
                 .text(event.role.rawValue), .integer(event.byteCount), .text(event.digest), .integer(block)])
            project.sourceCount += 1; project.maximumSequence = event.sequence; project.dirty = true
            projects[projectKey] = project
            conversations[conversationKey] = conversation
            watermark = event.sequence; watermarkEventID = event.eventID; watermarkDigest = event.digest
        }

        static func termKey(_ project: Data, _ term: String) -> Data {
            var key = project; key.append(0); key.append(contentsOf: Array(term.utf8)); return key
        }

        func projectState(_ key: Data, _ projectID: String) throws -> Project {
            if let known = projects[key] { return known }
            let value = try index.rows("SELECT block_count, source_count, max_sequence, block_chunks FROM projects WHERE project_id=?",
                [.text(projectID)]) { Project(blockCount: ExchangeIndexStore.integer($0, 0), sourceCount: ExchangeIndexStore.integer($0, 1),
                    maximumSequence: ExchangeIndexStore.integer($0, 2), blockChunks: ExchangeIndexStore.integer($0, 3), dirty: false) }.first
                ?? Project(blockCount: 0, sourceCount: 0, maximumSequence: 0, blockChunks: 0, dirty: true)
            projects[key] = value
            return value
        }

        func conversationState(_ key: Data, _ conversationID: String) throws -> Conversation? {
            if let known = conversations[key] { return known }
            let value = try index.rows("SELECT project_id, first_sequence, open_block, open_terms FROM conversations WHERE conversation_id=?",
                [.text(conversationID)]) { row -> Conversation in
                var terms = Set<Int64>(), reader = ExchangeIndexCoding.Reader(ExchangeIndexStore.blob(row, 3)), previous: Int64 = 0
                while !reader.atEnd { previous += Int64(try reader.next()); terms.insert(previous) }
                return Conversation(projectID: ExchangeIndexStore.text(row, 0), first: ExchangeIndexStore.integer(row, 1),
                    openBlock: ExchangeIndexStore.integer(row, 2), openTerms: terms, dirty: false)
            }.first
            if let value { conversations[key] = value }
            return value
        }

        func termState(_ projectKey: Data, _ projectID: String, _ term: String) throws -> Term {
            let key = Self.termKey(projectKey, term)
            if let known = terms[key] { return known }
            if let stored = try index.rows("SELECT id, document_frequency, chunks FROM terms WHERE project_id=? AND term=?",
                [.text(projectID), .text(term)], { Term(id: Int64(ExchangeIndexStore.integer($0, 0)), projectID: projectID, term: term,
                    documentFrequency: ExchangeIndexStore.integer($0, 1), chunks: ExchangeIndexStore.integer($0, 2), dirty: false) }).first {
                terms[key] = stored
                return stored
            }
            let created = Term(id: nextTermID, projectID: projectID, term: term, documentFrequency: 0, chunks: 0, dirty: true)
            nextTermID += 1
            terms[key] = created
            return created
        }

        func appendPosting(_ term: inout Term, block: Int, count: Int) throws {
            var tail: Tail
            if let known = postingTails[term.id] { tail = known }
            else if term.chunks > 0, let stored = try index.rows("SELECT entries, last_block, payload FROM postings WHERE term=? AND chunk=?",
                [.integer(Int(term.id)), .integer(term.chunks - 1)], { Tail(chunk: term.chunks - 1, entries: ExchangeIndexStore.integer($0, 0),
                    last: ExchangeIndexStore.integer($0, 1), payload: ExchangeIndexStore.blob($0, 2), dirty: false) }).first { tail = stored }
            else { tail = Tail(chunk: 0, entries: 0, last: 0, payload: Data(), dirty: true) }
            if tail.entries >= ExchangeIndexStore.chunkEntries {
                try writePosting(term.id, tail)
                tail = Tail(chunk: tail.chunk + 1, entries: 0, last: 0, payload: Data(), dirty: true)
            }
            ExchangeIndexCoding.append(ExchangeIndexCoding.zigzag(block - tail.last), to: &tail.payload)
            ExchangeIndexCoding.append(UInt64(count), to: &tail.payload)
            tail.entries += 1; tail.last = block; tail.dirty = true
            if term.chunks != tail.chunk + 1 { term.chunks = tail.chunk + 1; term.dirty = true }
            postingTails[term.id] = tail
        }

        func appendBlockLog(_ key: Data, _ projectID: String, project: inout Project, block: Int, newBlock: Bool,
                            first: Int, bytes: Int) throws {
            var tail: Tail
            if let known = blockTails[key] { tail = known }
            else if project.blockChunks > 0, let stored = try index.rows("SELECT entries, last_block, payload FROM block_log WHERE project_id=? AND chunk=?",
                [.text(projectID), .integer(project.blockChunks - 1)], { Tail(chunk: project.blockChunks - 1, entries: ExchangeIndexStore.integer($0, 0),
                    last: ExchangeIndexStore.integer($0, 1), payload: ExchangeIndexStore.blob($0, 2), dirty: false) }).first { tail = stored }
            else { tail = Tail(chunk: 0, entries: 0, last: 0, payload: Data(), dirty: true) }
            if tail.entries >= ExchangeIndexStore.chunkEntries {
                try writeBlockLog(projectID, tail)
                tail = Tail(chunk: tail.chunk + 1, entries: 0, last: 0, payload: Data(), dirty: true)
            }
            ExchangeIndexCoding.append(newBlock ? 0 : 1, to: &tail.payload)
            ExchangeIndexCoding.append(ExchangeIndexCoding.zigzag(block - tail.last), to: &tail.payload)
            if newBlock {
                guard block >= first else { throw ExchangeIndexError.mismatch }
                ExchangeIndexCoding.append(UInt64(block - first), to: &tail.payload)
            }
            ExchangeIndexCoding.append(UInt64(bytes), to: &tail.payload)
            tail.entries += 1; tail.last = block; tail.dirty = true
            if project.blockChunks != tail.chunk + 1 { project.blockChunks = tail.chunk + 1 }
            project.dirty = true
            blockTails[key] = tail
        }

        func writePosting(_ term: Int64, _ tail: Tail) throws {
            try index.run("INSERT OR REPLACE INTO postings (term, chunk, entries, last_block, payload) VALUES (?,?,?,?,?)",
                [.integer(Int(term)), .integer(tail.chunk), .integer(tail.entries), .integer(tail.last), .blob(tail.payload)])
        }

        func writeBlockLog(_ projectID: String, _ tail: Tail) throws {
            try index.run("INSERT OR REPLACE INTO block_log (project_id, chunk, entries, last_block, payload) VALUES (?,?,?,?,?)",
                [.text(projectID), .integer(tail.chunk), .integer(tail.entries), .integer(tail.last), .blob(tail.payload)])
        }

        func flush() throws {
            for (key, var tail) in postingTails where tail.dirty { try writePosting(key, tail); tail.dirty = false; postingTails[key] = tail }
            for (key, var tail) in blockTails where tail.dirty {
                let projectID = String(decoding: key, as: UTF8.self)
                try writeBlockLog(projectID, tail); tail.dirty = false; blockTails[key] = tail
            }
            for (key, var term) in terms where term.dirty {
                try index.run("INSERT OR REPLACE INTO terms (id, project_id, term, document_frequency, chunks) VALUES (?,?,?,?,?)",
                    [.integer(Int(term.id)), .text(term.projectID), .text(term.term), .integer(term.documentFrequency), .integer(term.chunks)])
                term.dirty = false; terms[key] = term
            }
            for (key, var conversation) in conversations where conversation.dirty {
                var encoded = Data(), previous: Int64 = 0
                for id in conversation.openTerms.sorted() { ExchangeIndexCoding.append(UInt64(id - previous), to: &encoded); previous = id }
                try index.run("INSERT OR REPLACE INTO conversations (conversation_id, project_id, first_sequence, open_block, open_terms) VALUES (?,?,?,?,?)",
                    [.text(String(decoding: key, as: UTF8.self)), .text(conversation.projectID), .integer(conversation.first),
                     .integer(conversation.openBlock), .blob(encoded)])
                conversation.dirty = false; conversations[key] = conversation
            }
            for (key, var project) in projects where project.dirty {
                try index.run("INSERT OR REPLACE INTO projects (project_id, block_count, source_count, max_sequence, block_chunks) VALUES (?,?,?,?,?)",
                    [.text(String(decoding: key, as: UTF8.self)), .integer(project.blockCount), .integer(project.sourceCount),
                     .integer(project.maximumSequence), .integer(project.blockChunks)])
                project.dirty = false; projects[key] = project
            }
            try index.writeMeta(["watermark": String(watermark), "watermark_event_id": watermarkEventID, "watermark_digest": watermarkDigest])
        }
    }

    // MARK: Reads

    struct ProjectRow: Equatable {
        let blockCount: Int
        let sourceCount: Int
        let maximumSequence: Int
        let blockChunks: Int
    }

    struct TermRow: Equatable {
        let id: Int
        let documentFrequency: Int
        let chunks: Int
    }

    func project(_ projectID: String) throws -> ProjectRow {
        try rows("SELECT block_count, source_count, max_sequence, block_chunks FROM projects WHERE project_id=?", [.text(projectID)]) {
            ProjectRow(blockCount: Self.integer($0, 0), sourceCount: Self.integer($0, 1), maximumSequence: Self.integer($0, 2),
                blockChunks: Self.integer($0, 3))
        }.first ?? ProjectRow(blockCount: 0, sourceCount: 0, maximumSequence: 0, blockChunks: 0)
    }

    func term(_ projectID: String, _ term: String) throws -> TermRow? {
        try rows("SELECT id, document_frequency, chunks FROM terms WHERE project_id=? AND term=?", [.text(projectID), .text(term)]) {
            TermRow(id: Self.integer($0, 0), documentFrequency: Self.integer($0, 1), chunks: Self.integer($0, 2))
        }.first
    }

    /// Sum of every entry for each block of one term's chunks.
    func postings(_ term: TermRow) throws -> (frequency: [Int: Int], rows: Int, entries: Int) {
        var frequency: [Int: Int] = [:], rowsRead = 0, entries = 0
        let statement = try statement("SELECT entries, payload FROM postings WHERE term=? ORDER BY chunk")
        defer { sqlite3_reset(statement) }
        try bind(statement, [.integer(term.id)])
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw databaseError() }
            rowsRead += 1
            var reader = ExchangeIndexCoding.Reader(Self.blob(statement, 1)), last = 0, count = 0
            while !reader.atEnd {
                last += ExchangeIndexCoding.unzigzag(try reader.next())
                let value = Int(try reader.next())
                guard last > 0, value > 0 else { throw ExchangeIndexError.mismatch }
                frequency[last, default: 0] += value
                count += 1
            }
            guard count == Self.integer(statement, 0) else { throw ExchangeIndexError.mismatch }
            entries += count
        }
        guard rowsRead == term.chunks, frequency.count == term.documentFrequency else { throw ExchangeIndexError.mismatch }
        return (frequency, rowsRead, entries)
    }

    /// Replays the project's block log. With `only`, keeps those blocks.
    func blockLog(_ projectID: String, chunks: Int, only: Set<Int>?) throws -> (blocks: [Int: BlockAttributes], rows: Int, created: Int) {
        var blocks: [Int: BlockAttributes] = [:], rowsRead = 0, created = 0
        let statement = try statement("SELECT entries, payload FROM block_log WHERE project_id=? ORDER BY chunk")
        defer { sqlite3_reset(statement) }
        try bind(statement, [.text(projectID)])
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw databaseError() }
            rowsRead += 1
            var reader = ExchangeIndexCoding.Reader(Self.blob(statement, 1)), last = 0, count = 0
            while !reader.atEnd {
                let kind = try reader.next()
                last += ExchangeIndexCoding.unzigzag(try reader.next())
                guard last > 0 else { throw ExchangeIndexError.mismatch }
                if kind == 0 {
                    let offset = Int(try reader.next()), bytes = Int(try reader.next())
                    created += 1
                    if only?.contains(last) ?? true {
                        guard blocks[last] == nil, offset <= last else { throw ExchangeIndexError.mismatch }
                        blocks[last] = BlockAttributes(conversationFirst: last - offset, bytes: bytes, sources: 1)
                    }
                } else if kind == 1 {
                    let bytes = Int(try reader.next())
                    if only?.contains(last) ?? true {
                        guard var known = blocks[last] else { throw ExchangeIndexError.mismatch }
                        known.bytes += bytes; known.sources += 1; blocks[last] = known
                    }
                } else { throw ExchangeIndexError.mismatch }
                count += 1
            }
            guard count == Self.integer(statement, 0) else { throw ExchangeIndexError.mismatch }
        }
        guard rowsRead == chunks else { throw ExchangeIndexError.mismatch }
        return (blocks, rowsRead, created)
    }

    private static let sourceColumns = "sequence, event_id, project_id, conversation_id, role, byte_count, digest, block"

    private static func sourceRow(_ statement: OpaquePointer) throws -> SourceRow {
        guard let role = MemoryRole(rawValue: text(statement, 4)) else { throw ExchangeIndexError.mismatch }
        return SourceRow(sequence: integer(statement, 0), eventID: text(statement, 1), projectID: text(statement, 2),
            conversationID: text(statement, 3), role: role, byteCount: integer(statement, 5), digest: text(statement, 6),
            block: integer(statement, 7))
    }

    func source(_ sequence: Int) throws -> SourceRow? {
        try rows("SELECT " + Self.sourceColumns + " FROM sources WHERE sequence=?", [.integer(sequence)], Self.sourceRow).first
    }

    /// Members of stored blocks through a frontier, chronological per block.
    func members(blocks: [Int], through frontier: Int) throws -> [SourceRow] {
        guard !blocks.isEmpty else { return [] }
        let list = "[" + blocks.map(String.init).joined(separator: ",") + "]"
        return try rows("SELECT " + Self.sourceColumns + " FROM sources WHERE block IN (SELECT value FROM json_each(?)) AND sequence<=? ORDER BY block, sequence",
            [.text(list), .integer(frontier)], Self.sourceRow)
    }

    func sources(conversationID: String, from start: Int, through frontier: Int) throws -> [SourceRow] {
        try rows("SELECT " + Self.sourceColumns + " FROM sources WHERE conversation_id=? AND sequence>=? AND sequence<=? ORDER BY sequence",
            [.text(conversationID), .integer(start), .integer(frontier)], Self.sourceRow)
    }

    func count(conversationID: String, from start: Int, through frontier: Int) throws -> Int {
        try scalar("SELECT count(*) FROM sources WHERE conversation_id=? AND sequence>=? AND sequence<=?",
            [.text(conversationID), .integer(start), .integer(frontier)]) ?? 0
    }

    func preceding(conversationID: String, before sequence: Int) throws -> SourceRow? {
        try rows("SELECT " + Self.sourceColumns + " FROM sources WHERE conversation_id=? AND sequence<? ORDER BY sequence DESC LIMIT 1",
            [.text(conversationID), .integer(sequence)], Self.sourceRow).first
    }

    func following(conversationID: String, after sequence: Int, through frontier: Int) throws -> SourceRow? {
        try rows("SELECT " + Self.sourceColumns + " FROM sources WHERE conversation_id=? AND sequence>? AND sequence<=? ORDER BY sequence LIMIT 1",
            [.text(conversationID), .integer(sequence), .integer(frontier)], Self.sourceRow).first
    }

    func sources(sequences: [Int]) throws -> [SourceRow] {
        guard !sequences.isEmpty else { return [] }
        let list = "[" + sequences.map(String.init).joined(separator: ",") + "]"
        return try rows("SELECT " + Self.sourceColumns + " FROM sources WHERE sequence IN (SELECT value FROM json_each(?)) ORDER BY sequence",
            [.text(list)], Self.sourceRow)
    }

    /// Each source's same-conversation predecessor, or successor through the
    /// frontier, among indexed sources: one statement for many sources.
    func adjacent(_ sequences: [Int], before: Bool, through frontier: Int) throws -> [Int: Int?] {
        guard !sequences.isEmpty else { return [:] }
        let list = "[" + sequences.map(String.init).joined(separator: ",") + "]"
        let neighbor = before
            ? "(SELECT p.sequence FROM sources p WHERE p.conversation_id=s.conversation_id AND p.sequence<s.sequence ORDER BY p.sequence DESC LIMIT 1)"
            : "(SELECT p.sequence FROM sources p WHERE p.conversation_id=s.conversation_id AND p.sequence>s.sequence AND p.sequence<=? ORDER BY p.sequence LIMIT 1)"
        let values: [Value] = before ? [.text(list)] : [.integer(frontier), .text(list)]
        var result: [Int: Int?] = [:]
        for (source, value) in try rows("SELECT s.sequence, " + neighbor + " FROM sources s WHERE s.sequence IN (SELECT value FROM json_each(?))",
            values, { (Self.integer($0, 0), sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : Self.integer($0, 1)) }) {
            result[source] = value
        }
        return result
    }

    func conversationFirst(_ conversationID: String) throws -> Int? {
        try scalar("SELECT first_sequence FROM conversations WHERE conversation_id=?", [.text(conversationID)])
    }

    /// Every term's postings and the block log of one project, for checks
    /// that compare the stored statistics with an in-memory rebuild.
    func exportProject(_ projectID: String) throws -> (project: ProjectRow, terms: [String: [Int: Int]], blocks: [Int: BlockAttributes]) {
        let project = try project(projectID)
        var result: [String: [Int: Int]] = [:]
        for (name, row) in try rows("SELECT term, id, document_frequency, chunks FROM terms WHERE project_id=?", [.text(projectID)], {
            (Self.text($0, 0), TermRow(id: Self.integer($0, 1), documentFrequency: Self.integer($0, 2), chunks: Self.integer($0, 3)))
        }) { result[name] = try postings(row).frequency }
        return (project, result, try blockLog(projectID, chunks: project.blockChunks, only: nil).blocks)
    }

    // MARK: Episode fence

    /// Installs the episode's interruption guard on this connection too, so a
    /// deadline or cancellation stops sidecar statements as it does store ones.
    func fenced<T>(_ fence: EpisodeSQLFence, _ body: () throws -> T) throws -> T {
        guard let database else { throw MemoryError.database("exchange index closed") }
        return try fence.perform(on: database, body)
    }

    // MARK: SQLite

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do { let value = try body(); try run("COMMIT"); return value }
        catch { try? run("ROLLBACK"); throw error }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let known = statements[sql] {
            sqlite3_reset(known); sqlite3_clear_bindings(known); return known
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        statements[sql] = statement
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [Value]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, Int64(number))
            case .text(let string): result = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), transient) }
            case .blob(let data):
                if data.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                else { result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) } }
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        let statement = try statement(sql)
        defer { sqlite3_reset(statement) }
        try bind(statement, values)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw databaseError() }
    }

    func rows<T>(_ sql: String, _ values: [Value] = [], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try statement(sql)
        defer { sqlite3_reset(statement) }
        try bind(statement, values)
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw databaseError() }
            result.append(try map(statement))
        }
    }

    func scalar(_ sql: String, _ values: [Value] = []) throws -> Int? {
        try rows(sql, values) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Self.integer($0, 0) }.first ?? nil
    }

    static func integer(_ statement: OpaquePointer, _ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func databaseError() -> MemoryError {
        MemoryError.database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "exchange index closed")
    }

    private static func openPrivate(_ path: String) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MemoryError.invalid("could not open a private exchange index file") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
              fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor); throw MemoryError.invalid("exchange index file must be a regular file owned by this user")
        }
        return descriptor
    }

    private func secureSidecars() throws {
        for suffix in ["-wal", "-shm"] {
            let path = directory.appendingPathComponent(Self.fileName + suffix).path
            if FileManager.default.fileExists(atPath: path) { Darwin.close(try Self.openPrivate(path)) }
        }
    }
}

enum ExchangeIndexError: Error { case unavailable, mismatch }

/// The exchange term function, shared by the index and the per-turn query
/// (`ExchangeBlockQuery.terms`). It lives here so the store and its
/// maintenance compile without the retrieval layer.
enum ExchangeTerms {
    /// Ported from the investigation engine's term function: case and
    /// diacritic folding, alphanumeric runs, its stopword list.
    static func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.utf8.count <= 128 && !stopwords.contains($0) }
    }

    /// Identity of `terms(_:)` for a stored index: its version, the stopword
    /// list and the operating system whose folding tables it used. A stored
    /// index with another identity is rebuilt before use.
    static var identity: String {
        let words = Data(stopwords.sorted().joined(separator: " ").utf8)
        let digest = SHA256.hash(data: words).map { String(format: "%02x", $0) }.joined()
        return "exchange-terms-v1:" + digest.prefix(16) + ":" + ProcessInfo.processInfo.operatingSystemVersionString
    }

    static let stopwords = Set("a an and are as at be been being but by can could did do does doing for from had has have having he her here hers him his how i if in into is it its just me more most my no not of on or our ours please s say she should so some t tell than that the their theirs them then there these they this those through to too us was we were what when where which who why will with would you your yours about".split(separator: " ").map(String.init))
}

/// One committed store event as the index consumes it.
struct ExchangeIndexEvent {
    let sequence: Int
    let eventID: String
    let projectID: String
    let conversationID: String
    let role: MemoryRole
    let byteCount: Int
    let digest: String
    let text: String
}

/// Unsigned LEB128 varints and zigzag signed deltas.
enum ExchangeIndexCoding {
    static func append(_ value: UInt64, to data: inout Data) {
        var remaining = value
        while remaining >= 0x80 { data.append(UInt8(truncatingIfNeeded: remaining) | 0x80); remaining >>= 7 }
        data.append(UInt8(remaining))
    }
    static func zigzag(_ value: Int) -> UInt64 { UInt64(bitPattern: Int64(value) << 1 ^ Int64(value) >> 63) }
    static func unzigzag(_ value: UInt64) -> Int { Int(Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)) }

    struct Reader {
        private let bytes: [UInt8]
        private var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        var atEnd: Bool { offset >= bytes.count }
        mutating func next() throws -> UInt64 {
            var value: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard offset < bytes.count, shift <= 63 else { throw ExchangeIndexError.mismatch }
                let byte = bytes[offset]; offset += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
        }
    }
}
