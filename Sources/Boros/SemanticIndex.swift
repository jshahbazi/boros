import Foundation
import NaturalLanguage
import CryptoKit
import CSQLite
import Darwin

enum SemanticUnsupportedReason: String, Codable {
    case adapterUnavailable, inputTooLarge, emptyInput, codeLike, nonEnglish, ambiguousLanguage, inputAccountingUnavailable
}

enum SemanticEncoding {
    case vector([Float])
    case unsupported(SemanticUnsupportedReason)
}

/// Injectable only for component checks; the product uses the real Apple adapter.
protocol SemanticEmbeddingAdapter: AnyObject {
    var metadata: [String: String] { get }
    var dimension: Int { get }
    func encode(_ text: String) throws -> SemanticEncoding
}

/// Uses installed resources only. No asset request, model download, or server launch.
final class AppleSentenceEmbeddingAdapter: SemanticEmbeddingAdapter {
    let dimension = 512
    let metadata: [String: String]
    private let embedding: NLEmbedding?
    private let lock = NSLock()

    init() {
        let supported = NLEmbedding.supportedSentenceEmbeddingRevisions(for: .english)
        let candidate = supported.contains(1) ? NLEmbedding.sentenceEmbedding(for: .english, revision: 1) : nil
        embedding = candidate?.revision == 1 && candidate?.dimension == 512 && candidate?.language == .english ? candidate : nil
        metadata = ["provider": "apple.NaturalLanguage.NLEmbedding.sentence", "language": "en", "revision": "1",
            "dimension": "512", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "guard": "ascii-letters-sentence-en-confidence-0.90-code-markers-v1",
            "normalization": "finite-l2-float32-le-v1", "probe_version": "public-two-sentences-v1",
            "probe_digest": embedding == nil ? "unavailable" : "not-probed"]
    }

    func encode(_ text: String) throws -> SemanticEncoding {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unsupported(.emptyInput) }
        guard text.utf8.count <= 4096 else { return .unsupported(.inputTooLarge) }
        guard let embedding else { return .unsupported(.adapterUnavailable) }
        // Conservative support guard, not proof of language purity or model quality.
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "`{};")) != nil || text.contains("=>") || text.contains("->") || text.contains("\0") {
            return .unsupported(.codeLike)
        }
        let codePrefixes = ["let ", "var ", "func ", "def ", "class ", "import ", "const ", "select ", "#include", "//"]
        if text.components(separatedBy: .newlines).contains(where: { line in
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            return codePrefixes.contains { lower.hasPrefix($0) }
        }) { return .unsupported(.codeLike) }
        if text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) && $0.value > 127 }) { return .unsupported(.nonEnglish) }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var reason: SemanticUnsupportedReason?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sentence)
            let probabilities = recognizer.languageHypotheses(withMaximum: 8)
            if recognizer.dominantLanguage != .english { reason = probabilities.isEmpty ? .ambiguousLanguage : .nonEnglish; return false }
            if (probabilities[.english] ?? 0) < 0.90 { reason = .ambiguousLanguage; return false }
            return true
        }
        if let reason { return .unsupported(reason) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard recognizer.dominantLanguage == .english, (recognizer.languageHypotheses(withMaximum: 8)[.english] ?? 0) >= 0.90 else {
            return .unsupported(.ambiguousLanguage)
        }
        lock.lock(); defer { lock.unlock() }
        guard let vector = embedding.vector(for: text) else { return .unsupported(.adapterUnavailable) }
        return .vector(try SemanticIndex.normalized(vector.map(Float.init), dimension: dimension))
    }
}

struct SemanticIndexConfiguration: Codable, Equatable {
    var chunkBytes = 1024
    var maximumNewSourcesPerRun = 256
    var maximumChunksPerRun = 128
    var maximumCandidateChunks = 4096
    var maximumManifestSources = 1000
    var maximumReportedHoles = 128
    var maximumFailureAttempts = 3
    var reciprocalRankConstant = 60
}

struct SemanticCoverageHole: Codable, Equatable {
    let eventID: String
    let offset: Int
    let byteCount: Int
    let reason: String
}

struct SemanticSourceCoverage: Codable, Equatable {
    let source: MemorySourceReference
    let state: String
    let nextOffset: Int
    let indexedBytes: Int
    let indexedChunks: Int
    let unsupportedChunks: Int
    let failureAttempts: Int
    let failureReason: String?
}

struct SemanticCoverage: Codable, Equatable {
    let inspectedSources: Int
    let completeSources: Int
    let pendingSources: Int
    let unsupportedSources: Int
    let failedSources: Int
    let indexedBytes: Int
    let inspectedSourceBytes: Int
    let indexedChunks: Int
    let unsupportedChunks: Int
    let metadataContinuationSequence: Int?
    let holes: [SemanticCoverageHole]
    let holesTruncated: Bool
    let sources: [SemanticSourceCoverage]
    var complete: Bool { metadataContinuationSequence == nil && pendingSources == 0 && unsupportedSources == 0 && failedSources == 0 }
}

struct SemanticSearchContinuation: Codable, Equatable {
    let projectID: String
    let indexFingerprint: String
    let queryDigest: String
    let sourceFrontier: Int
    let publishedChunkFrontier: Int
    let afterSequence: Int
    let afterOffset: Int
    let rawSnapshotID: String
    let includeLiteral: Bool
    var episodeID: String? = nil
}

struct SemanticResultReference: Codable, Equatable {
    let source: MemorySourceReference
    let offset: Int
    let byteCount: Int
    let excerptDigest: String
    let retrievalPaths: [String]
    let fusedScore: Double
    let cosineScore: Double?
}

struct SemanticSearchManifest: Codable, Equatable {
    let version: Int
    let projectID: String
    let queryDigest: String
    let lexicalQueryDigest: String
    let indexFingerprint: String
    let encoderFingerprint: String
    let rankingFingerprint: String
    let configurationFingerprint: String
    let configuration: SemanticIndexConfiguration
    let queryConfigurationFingerprint: String
    let resultLimit: Int
    let sourceFrontier: Int
    let publishedChunkFrontier: Int
    let queryDisposition: String
    let includeLiteral: Bool
    let literalScanBytes: Int?
    let literalSearchPerformed: Bool
    let rawSnapshotID: String
    let rawFallbackAvailable: Bool
    let coverage: SemanticCoverage
    let vectorCandidatesInspected: Int
    let vectorContinuation: SemanticSearchContinuation?
    let excludedEventIDs: [String]
    let results: [SemanticResultReference]
    var episodeID: String? = nil
    var meteredLexicalCoverage: MeteredLexicalCoverage? = nil
    var meteredLiteralCoverage: MeteredLiteralCoverage? = nil
}

struct SemanticSearchReport {
    let hits: [MemoryHit]
    let manifestID: String
    let manifest: SemanticSearchManifest
    func serializedManifest() throws -> Data { try SemanticIndex.canonical(manifest) }
}

struct SemanticWorkReceipt {
    let scheduledSources: Int
    let publishedChunks: Int
    let failedChunks: Int
    let schedulingFrontier: Int
    var budgetPauseReason: String? = nil
}

enum SemanticError: LocalizedError {
    case invalid, unavailable, sourceMismatch, publicationConflict, database, ownerBusy
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid semantic retrieval configuration or continuation."
        case .unavailable: return "The requested semantic manifest is unavailable."
        case .sourceMismatch: return "Semantic source metadata or bytes no longer match the original source."
        case .publicationConflict: return "A semantic publication conflicts with its committed job snapshot."
        case .database: return "The local semantic index could not complete a database operation."
        case .ownerBusy: return "Another semantic index already owns this derived store."
        }
    }
}

/// Derived data has its own durable transaction boundary. Raw accepted events
/// remain usable immediately, including when no semantic job has run.
final class SemanticIndex: @unchecked Sendable {
    let store: MemoryStore // Strong lifetime coupling retains the authoritative owner lock.
    let directory: URL
    let configuration: SemanticIndexConfiguration
    let encoderFingerprint: String
    let indexFingerprint: String
    let rankingFingerprint: String
    private let encoder: SemanticEmbeddingAdapter
    private let encoderMetadata: [String: String]
    private let backgroundClock: BackgroundIndexClockSource
    private let workerObserver: BackgroundIndexWorkerObserver?
    private let backgroundLimits: BackgroundIndexLimits
    private let backgroundAdapterIdentity: String
    // Serialize worker attempts without holding the sidecar mutex across bytes
    // or inference. Searches can continue during a slow background encoder.
    private let processMutex = NSLock()
    private var initialSealToken: BackgroundInitialSealToken?
    private let maintenanceStateMutex = NSLock()
    private var maintenancePauseReason: String?
    private let mutex = NSRecursiveLock()
    private let worker = DispatchQueue(label: "dev.boros.semantic-index", qos: .utility)
    private var scheduledProjects: Set<Data> = []
    private var database: OpaquePointer?
    private var ownerFD: Int32 = -1
    // Set only while holding the index mutex. It checks the authoritative
    // episode between bounded SQL steps without opening a sidecar transaction
    // across source reads, encoder calls or a network operation.
    private var activeSearchLease: EpisodeLease?
    private var activeSearchFence: EpisodeSQLFence?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(store: MemoryStore, encoder: SemanticEmbeddingAdapter = AppleSentenceEmbeddingAdapter(), configuration: SemanticIndexConfiguration = .init(),
         backgroundClock: BackgroundIndexClockSource = SystemBackgroundIndexClock(),
         backgroundLimits: BackgroundIndexLimits = .development, workerObserver: BackgroundIndexWorkerObserver? = nil) throws {
        guard (64...4096).contains(configuration.chunkBytes), (1...1000).contains(configuration.maximumNewSourcesPerRun),
              (1...65536).contains(configuration.maximumChunksPerRun), (1...65536).contains(configuration.maximumCandidateChunks),
              (1...1000).contains(configuration.maximumManifestSources), (1...1000).contains(configuration.maximumReportedHoles),
              (1...10).contains(configuration.maximumFailureAttempts), (1...1000).contains(configuration.reciprocalRankConstant),
              (1...8192).contains(encoder.dimension) else { throw SemanticError.invalid }
        self.store = store; self.encoder = encoder; self.configuration = configuration
        self.backgroundClock = backgroundClock; self.backgroundLimits = backgroundLimits; self.workerObserver = workerObserver
        try backgroundLimits.validate()
        backgroundAdapterIdentity = "semantic-encoder-observation-v1:" + Self.digest(try Self.canonical(encoder.metadata.filter { $0.key != "probe_digest" }))
        if encoder is AppleSentenceEmbeddingAdapter {
            encoderMetadata = try BackgroundWorkerAccounting.probe(store: store, encoder: encoder,
                adapterIdentity: backgroundAdapterIdentity, clock: backgroundClock, limits: backgroundLimits)
        } else {
            // Injected adapters declare their identity and perform no hidden
            // initialization inference. Any explicit test probe uses the same
            // metered helper as the product adapter.
            encoderMetadata = encoder.metadata
        }
        directory = store.directory.appendingPathComponent("semantic", isDirectory: true)
        encoderFingerprint = Self.digest(try Self.canonical(encoderMetadata.merging(["declared_dimension": String(encoder.dimension)]) { _, actual in actual }))
        indexFingerprint = Self.digest(try Self.canonical(["encoder": encoderFingerprint, "chunker": "utf8-whitespace-v1", "chunk_bytes": String(configuration.chunkBytes), "schema": "2-source-seal"]))
        rankingFingerprint = Self.digest(try Self.canonical(["ranking": "literal-first-rrf-cosine-v1", "rrf_constant": String(configuration.reciprocalRankConstant),
            "candidate_cap": String(configuration.maximumCandidateChunks), "lexical": "caller-query-anyterm-prefiltered-exclusions-v2",
            "raw_filters": "scope-frontier-utf8-exclusions-before-limit-v2", "dedup": "one-range-per-source-v1",
            "lexical_excerpt": "first-occurrence-cluster-v2"]))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var statValue = stat()
            guard lstat(directory.path, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFDIR, statValue.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw SemanticError.invalid }
            ownerFD = try Self.openPrivate(directory.appendingPathComponent("owner.lock"))
            guard flock(ownerFD, LOCK_EX | LOCK_NB) == 0 else { throw SemanticError.ownerBusy }
            let path = directory.appendingPathComponent("index.sqlite3")
            close(try Self.openPrivate(path))
            try secureSidecars()
            guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw SemanticError.database }
            sqlite3_busy_timeout(database, 5000)
            _ = try query("PRAGMA journal_mode=WAL") { string($0, 0) }; try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA foreign_keys=ON")
            let version = try integer("PRAGMA user_version")
            guard (0...2).contains(version) else { throw SemanticError.invalid }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS versions (id TEXT PRIMARY KEY, encoder TEXT NOT NULL, metadata BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS scopes (index_id TEXT NOT NULL REFERENCES versions(id), project_id TEXT NOT NULL, scheduled_sequence INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(index_id,project_id)) WITHOUT ROWID")
                try execute("""
                    CREATE TABLE IF NOT EXISTS jobs (
                      index_id TEXT NOT NULL REFERENCES versions(id), event_id TEXT NOT NULL, project_id TEXT NOT NULL,
                      source_sequence INTEGER NOT NULL, source BLOB NOT NULL, next_offset INTEGER NOT NULL DEFAULT 0,
                      indexed_bytes INTEGER NOT NULL DEFAULT 0, indexed_chunks INTEGER NOT NULL DEFAULT 0,
                      unsupported_chunks INTEGER NOT NULL DEFAULT 0, failure_attempts INTEGER NOT NULL DEFAULT 0,
                      failure_reason TEXT NOT NULL DEFAULT '', ready_publication INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'pending'
                        CHECK(state IN ('pending','processing','complete','unsupported','failed')),
                      PRIMARY KEY(index_id,event_id), UNIQUE(index_id,project_id,source_sequence)
                    ) WITHOUT ROWID
                    """)
                if version == 1 { try execute("ALTER TABLE jobs ADD COLUMN ready_publication INTEGER NOT NULL DEFAULT 0") }
                try execute("""
                    CREATE TABLE IF NOT EXISTS chunks (
                      publication INTEGER PRIMARY KEY AUTOINCREMENT, index_id TEXT NOT NULL,
                      event_id TEXT NOT NULL, source_sequence INTEGER NOT NULL, project_id TEXT NOT NULL,
                      offset INTEGER NOT NULL, byte_count INTEGER NOT NULL, text_digest TEXT NOT NULL,
                      vector BLOB NOT NULL, reason TEXT NOT NULL,
                      FOREIGN KEY(index_id,event_id) REFERENCES jobs(index_id,event_id),
                      UNIQUE(index_id,event_id,offset), CHECK(offset>=0 AND byte_count>0)
                    )
                    """)
                try execute("CREATE INDEX IF NOT EXISTS chunk_scope ON chunks(index_id,project_id,source_sequence,offset)")
                try execute("CREATE TABLE IF NOT EXISTS manifests (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, payload BLOB NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS raw_snapshots (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, payload BLOB NOT NULL)")
                let metadata = try Self.canonical(encoderMetadata)
                try execute("INSERT OR IGNORE INTO versions VALUES (?,?,?)", [.text(indexFingerprint), .text(encoderFingerprint), .blob(metadata)])
                guard try query("SELECT encoder,metadata FROM versions WHERE id=?", [.text(indexFingerprint)], { (string($0, 0), blob($0, 1)) }).first.map({ $0.0 == encoderFingerprint && $0.1 == metadata }) == true else { throw SemanticError.publicationConflict }
                // A killed process can leave an armed calculation, never a
                // published vector without its committed continuation offset.
                try execute("UPDATE jobs SET state='pending' WHERE state='processing'")
                try execute("PRAGMA user_version=2")
            }
            try secureSidecars()
        } catch {
            if let database { sqlite3_close(database); self.database = nil }
            if ownerFD >= 0 { close(ownerFD); ownerFD = -1 }
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
        if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD) }
    }

    /// Coalesces requests and returns immediately. A run is bounded; pending
    /// work resumes on another capture/open/search scheduling request.
    func schedule(projectID: String) {
        mutex.lock()
        let projectKey = Data(projectID.utf8)
        guard !scheduledProjects.contains(projectKey) else { mutex.unlock(); return }
        scheduledProjects.insert(projectKey); mutex.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            defer { self.mutex.lock(); self.scheduledProjects.remove(projectKey); self.mutex.unlock() }
            // Jobs retain content-free failures. Index failure cannot fail Send.
            _ = try? self.process(projectID: projectID, maximumChunks: self.configuration.maximumChunksPerRun)
        }
    }

    /// Bounded worker entry point also used by deterministic component checks.
    @discardableResult
    func process(projectID: String, maximumChunks: Int? = nil) throws -> SemanticWorkReceipt {
        let maximum = maximumChunks ?? configuration.maximumChunksPerRun
        guard (0...65536).contains(maximum) else { throw SemanticError.invalid }
        processMutex.lock(); defer { processMutex.unlock() }
        var frontier = 0, scheduled = 0, published = 0, failed = 0
        setMaintenancePauseReason(nil)
        do {
            frontier = try backgroundMetadata(projectID: projectID, target: .captureSourceFrontier) {
                try store.sourceFrontier(projectID: projectID)
            }
            scheduled = try enqueueMetered(projectID: projectID, frontier: frontier)
            for _ in 0..<maximum {
                guard let job = try backgroundMetadata(projectID: projectID, target: .pendingJobPeek, throughSequence: frontier, {
                    try locked { try peek(projectID: projectID, frontier: frontier) }
                }) else { break }
                do {
                    let source = BackgroundWorkerAccounting.reference(job.source)
                    let sourceDigest = try BackgroundIndexCanonical.digest(source)
                    if job.source.byteCount > 0 && initialSealToken?.matches(sourceDigest: sourceDigest, indexFingerprint: indexFingerprint) != true {
                        initialSealToken = nil
                        let request = try BackgroundIndexWorkRequest.initialSeal(id: UUID().uuidString, source: source,
                            indexFingerprint: indexFingerprint, adapterIdentity: backgroundAdapterIdentity)
                        let work = try beginBackground(request)
                        do {
                            let reader = try store.makeBackgroundSourceReader(for: work, clockSource: backgroundClock)
                            try reader.validateCompleteSource(source: job.source)
                            let evidence = try BackgroundWorkerAccounting.sealEvidence(source: source)
                            _ = try store.settleBackgroundWork(workID: work.request.id,
                                settlement: .init(receiptID: UUID().uuidString, outcome: .completed, evidence: evidence), clockSource: backgroundClock)
                            initialSealToken = .init(sourceDigest: sourceDigest, indexFingerprint: indexFingerprint,
                                workID: work.request.id, bindingDigest: work.bindingDigest)
                        } catch {
                            try? settleBackgroundFailure(work, error: error)
                            throw error
                        }
                    }
                    let request = try job.source.byteCount == 0
                        ? BackgroundIndexWorkRequest.emptySource(id: UUID().uuidString, source: source, indexFingerprint: indexFingerprint, adapterIdentity: backgroundAdapterIdentity)
                        : BackgroundIndexWorkRequest.chunkAttempt(id: UUID().uuidString, source: source, offset: job.offset,
                            chunkBytes: configuration.chunkBytes, dimension: encoder.dimension,
                            indexFingerprint: indexFingerprint, adapterIdentity: backgroundAdapterIdentity)
                    // Final page and its fresh complete-source seal are one
                    // immutable request, admitted before claim or encoding.
                    let work = try beginBackground(request)
                    var didClaim = false, didPublish = false
                    do {
                        let reader = try store.makeBackgroundSourceReader(for: work, clockSource: backgroundClock)
                        try locked { try claim(job) }; didClaim = true
                        if job.source.byteCount == 0 {
                            try reader.validateCompleteSource(source: job.source)
                            try workerObserver?(.beforePublication, work)
                            try locked {
                                try store.withBackgroundPublication(workID: work.request.id, bindingDigest: work.bindingDigest, clockSource: backgroundClock) {
                                    try completeEmpty(job)
                                }
                            }
                            didPublish = true
                            try workerObserver?(.publishedBeforeSettlement, work)
                            _ = try store.settleBackgroundWork(workID: work.request.id, settlement: .init(receiptID: UUID().uuidString,
                                outcome: .completed, evidence: try BackgroundWorkerAccounting.emptyEvidence(source: source)), clockSource: backgroundClock)
                            initialSealToken = nil
                            continue
                        }
                        let page = try reader.readChunk(source: job.source)
                        guard page.digest == job.source.digest, page.totalBytes == job.source.byteCount,
                              page.status == job.source.status, page.offset == job.offset else { throw SemanticError.sourceMismatch }
                        let text = Self.chunk(page.text, atEOF: page.nextOffset == nil)
                        guard !text.isEmpty, text.utf8.count <= configuration.chunkBytes else { throw SemanticError.sourceMismatch }
                        let encoding = try encoder.encode(text)
                        let vector: Data, reason: String
                        switch encoding {
                        case .vector(let values): vector = Self.vectorData(try Self.normalized(values, dimension: encoder.dimension)); reason = ""
                        case .unsupported(let value): vector = Data(); reason = value.rawValue
                        }
                        let excerptBytes = Data(text.utf8)
                        let excerptDigest = Self.digest(excerptBytes)
                        let excerptCount = excerptBytes.count
                        let isFinal = job.offset + excerptCount == job.source.byteCount
                        if isFinal { try reader.validateCompleteSource(source: job.source) }
                        try workerObserver?(.beforePublication, work)
                        let publication = try locked {
                            try store.withBackgroundPublication(workID: work.request.id, bindingDigest: work.bindingDigest, clockSource: backgroundClock) {
                                try publish(job, byteCount: excerptCount, textDigest: excerptDigest, vector: vector, reason: reason)
                            }
                        }
                        didPublish = true
                        published += 1
                        try workerObserver?(.publishedBeforeSettlement, work)
                        _ = try store.settleBackgroundWork(workID: work.request.id, settlement: .init(receiptID: UUID().uuidString,
                            outcome: .completed, evidence: try BackgroundWorkerAccounting.chunkEvidence(source: source, offset: job.offset,
                                byteCount: excerptCount, textDigest: excerptDigest, vectorBytes: vector.count, publication: publication, isFinal: isFinal)), clockSource: backgroundClock)
                        if isFinal { initialSealToken = nil }
                    } catch {
                        initialSealToken = nil
                        // Publication and settlement cannot be atomic across
                        // databases. Preserve the maximum armed charge after
                        // the commit; never rewind or republish its cursor.
                        if !didPublish {
                            try? settleBackgroundFailure(work, error: error)
                            if didClaim {
                                if Self.backgroundPause(error) { try locked { try releaseClaim(job) } }
                                else { try locked { try fail(job, reason: "sourceOrVectorValidation") } }
                            }
                        } else {
                            // A committed cursor with an uncertain ledger
                            // receipt retains its charge and stops this slice.
                            throw BackgroundIndexBudgetError.inactive
                        }
                        throw error
                    }
                } catch let error as BackgroundIndexBudgetError {
                    if Self.backgroundPause(error) { throw error }
                    initialSealToken = nil
                    try locked { try failUnclaimed(job, reason: "backgroundAccountingValidation") }
                    failed += 1
                } catch {
                    initialSealToken = nil
                    try locked { try failUnclaimed(job, reason: "sourceOrVectorValidation") }
                    // A claimed failure was already recorded above. Count
                    // attempted errors once in the content-free receipt.
                    failed += 1
                }
            }
        } catch let error as BackgroundIndexBudgetError {
            initialSealToken = nil
            setMaintenancePauseReason(error.failureCode)
        }
        return SemanticWorkReceipt(scheduledSources: scheduled, publishedChunks: published, failedChunks: failed,
            schedulingFrontier: frontier, budgetPauseReason: backgroundPauseReason)
    }

    /// This snapshot contains counters and public reason codes only.
    func backgroundBudgetSnapshot() throws -> BackgroundIndexBudgetSnapshot {
        let snapshot = try store.backgroundBudgetSnapshot(clockSource: backgroundClock)
        if backgroundPauseReason == BackgroundIndexBudgetError.exhausted.failureCode && !snapshot.rolloverEligible {
            return try BackgroundIndexBudgetSnapshot(window: snapshot.window, rolloverEligible: false, pauseReason: .exhausted)
        }
        return snapshot
    }
    var backgroundPauseReason: String? {
        maintenanceStateMutex.lock(); defer { maintenanceStateMutex.unlock() }
        return maintenancePauseReason
    }
    private func setMaintenancePauseReason(_ value: String?) {
        maintenanceStateMutex.lock(); maintenancePauseReason = value; maintenanceStateMutex.unlock()
    }
    private static func backgroundPause(_ error: Error) -> Bool {
        guard let error = error as? BackgroundIndexBudgetError else { return false }
        return [.exhausted, .clockUnavailable, .inactive, .adapterViolation].contains(error)
    }

    func search(query: String, lexicalQuery: String? = nil, projectID: String, limit: Int = 16,
                excludingEventIDs: Set<String> = [], includeLiteral: Bool = true, continuation: SemanticSearchContinuation? = nil,
                episodeLease: EpisodeLease? = nil, operationIsNested: Bool = false) throws -> SemanticSearchReport {
        try search(query: query, lexicalQuery: lexicalQuery, projectID: projectID, limit: limit,
            excludingSourceIDs: ExactSourceIDs(Array(excludingEventIDs)), includeLiteral: includeLiteral,
            continuation: continuation, episodeLease: episodeLease, operationIsNested: operationIsNested)
    }

    func search(query: String, lexicalQuery: String? = nil, projectID: String, limit: Int = 16,
                excludingSourceIDs excludingEventIDs: ExactSourceIDs, includeLiteral: Bool = true, continuation: SemanticSearchContinuation? = nil,
                episodeLease: EpisodeLease? = nil, operationIsNested: Bool = false) throws -> SemanticSearchReport {
        _ = try episodeLease?.checkActive(projectID: projectID)
        return try MeteredRetrieval.operation(lease: episodeLease, nested: operationIsNested) {
            try searchWithinOperation(query: query, lexicalQuery: lexicalQuery, projectID: projectID, limit: limit,
                excludingEventIDs: excludingEventIDs, includeLiteral: includeLiteral, continuation: continuation, episodeLease: episodeLease)
        }
    }

    private func searchWithinOperation(query: String, lexicalQuery: String?, projectID: String, limit: Int,
                                      excludingEventIDs: ExactSourceIDs, includeLiteral: Bool,
                                      continuation: SemanticSearchContinuation?, episodeLease: EpisodeLease?) throws -> SemanticSearchReport {
        guard query.utf8.count <= MemoryStore.maximumPayloadBytes, (1...100).contains(limit), excludingEventIDs.count <= 10000 else { throw SemanticError.invalid }
        let lexical = lexicalQuery ?? query
        guard lexical.utf8.count <= 4096 else {
            // Large current prompts can still use a caller's bounded lexical
            // formulation. No implicit truncation of either query occurs.
            throw SemanticError.invalid
        }
        let queryDigest = Self.digest(Data(query.utf8))
        if let continuation {
            guard episodeIdentifierEqual(continuation.projectID, projectID), continuation.indexFingerprint == indexFingerprint, continuation.queryDigest == queryDigest, continuation.includeLiteral == includeLiteral,
                  episodeIdentifierEqual(continuation.episodeID, episodeLease?.episodeID),
                  continuation.sourceFrontier >= 0, continuation.publishedChunkFrontier >= 0, continuation.afterSequence >= 0, continuation.afterOffset >= 0 else { throw SemanticError.invalid }
        }
        let frontier = try continuation?.sourceFrontier ?? MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1) { try store.sourceFrontier(projectID: projectID) }
        var literalReport: MeteredLiteralReport?, lexicalReport: MeteredLexicalReport?
        let literal: [MemoryHit], lexicalHits: [MemoryHit]
        if let episodeLease {
            if continuation == nil && includeLiteral && query.utf8.count <= 4096 {
                let report = try MeteredRetrieval.literalSearch(store: store, query: query, projectID: projectID, limit: 100,
                    throughSequence: frontier, excludingSourceIDs: excludingEventIDs, lease: episodeLease, nested: true)
                try MeteredRetrieval.requireCompleteReadCoverage(lease: episodeLease, resourceLimited: report.incompleteReason == "raw_source_budget")
                literalReport = report; literal = report.hits
            } else { literal = [] }
            if continuation == nil {
                let report = try MeteredRetrieval.lexicalSearch(store: store, query: lexical, projectID: projectID, limit: 100,
                    matching: .anyTerm, throughSequence: frontier, excludingSourceIDs: excludingEventIDs, lease: episodeLease, nested: true)
                try MeteredRetrieval.requireCompleteReadCoverage(lease: episodeLease, resourceLimited: report.continuation != nil)
                lexicalReport = report; lexicalHits = report.hits
            } else { lexicalHits = [] }
        } else {
            literal = continuation == nil && includeLiteral && query.utf8.count <= 4096 ? try store.literalSearch(query: query, projectID: projectID,
                limit: 100, throughSequence: frontier, excludingSourceIDs: excludingEventIDs) : []
            lexicalHits = continuation == nil ? try store.search(query: lexical, projectID: projectID, limit: 100, matching: .anyTerm,
                throughSequence: frontier, excludingSourceIDs: excludingEventIDs) : []
        }
        let encoding: SemanticEncoding
        if let episodeLease, try episodeLease.checkActive().limits.requireKnownModelInput {
            // Apple supplies vectors without token usage or a verified upper
            // token bound. Strict mode uses original lexical sources and does
            // not dispatch opaque inference.
            encoding = .unsupported(.inputAccountingUnavailable)
        } else if query.utf8.count > 4096 {
            encoding = .unsupported(.inputTooLarge)
        } else {
            do {
                encoding = try MeteredRetrieval.charge(lease: episodeLease, kind: .queryEmbedding,
                    resources: EpisodeResources(modelCalls: 1, encoderInputBytes: query.utf8.count),
                    inputTokensKnown: false, identity: encoderFingerprint) { try encoder.encode(query) }
            } catch {
                if error is EpisodeBudgetError || error is MeteredRetrievalError || error is MemoryError { throw error }
                encoding = .unsupported(.adapterUnavailable)
            }
        }
        return try MeteredRetrieval.metadata(lease: episodeLease, maximumRows: 4) {
            try locked {
                let previousLease = activeSearchLease; activeSearchLease = episodeLease
                defer { activeSearchLease = previousLease }
                return try withSearchSQLFence(lease: episodeLease) {
                    let publishedFrontier = try continuation?.publishedChunkFrontier ?? integer("SELECT coalesce(max(publication),0) FROM chunks WHERE index_id=? AND project_id=?", [.text(indexFingerprint), .text(projectID)])
                    let coverage = try MeteredRetrieval.metadata(lease: episodeLease,
                        maximumRows: configuration.maximumManifestSources * 3 + configuration.maximumReportedHoles + 1) {
                        try self.coverage(projectID: projectID, frontier: frontier, publishedFrontier: publishedFrontier)
                    }
                    var candidates: [Data: Candidate] = [:]
                    let configurationDigest = Self.digest(try Self.canonical(configuration))
                    let lexicalDigest = Self.digest(Data(lexical.utf8))
                    let exclusionsDigest = Self.digest(try Self.canonical(excludingEventIDs.sorted()))
                    var queryConfiguration = ["include_literal": String(includeLiteral), "result_limit": String(limit),
                        "lexical_query": lexicalDigest, "excluded_ids": exclusionsDigest, "lexical_matching": "anyTerm", "ranking": rankingFingerprint]
                    if let episodeLease { queryConfiguration["episode_id"] = episodeLease.episodeID; queryConfiguration["raw_work"] = "raw_work_v1" }
                    let queryConfigurationDigest = Self.digest(try Self.canonical(queryConfiguration))
                    let rawSnapshotID: String
                    var meteredLexicalCoverage = lexicalReport?.coverage, meteredLiteralCoverage = literalReport?.coverage
                    if let continuation {
                        guard let payload = try self.query("SELECT payload FROM raw_snapshots WHERE id=? AND project_id=?", [.text(continuation.rawSnapshotID), .text(projectID)], { blob($0, 0) }).first,
                              Self.digest(payload) == continuation.rawSnapshotID else { throw SemanticError.invalid }
                        let snapshot = try JSONDecoder().decode(RawSnapshot.self, from: payload)
                        guard snapshot.projectID == projectID, snapshot.queryDigest == queryDigest, snapshot.lexicalQueryDigest == lexicalDigest,
                              snapshot.indexFingerprint == indexFingerprint, snapshot.rankingFingerprint == rankingFingerprint,
                              snapshot.configurationFingerprint == configurationDigest, snapshot.exclusionsDigest == exclusionsDigest,
                              snapshot.queryConfigurationFingerprint == queryConfigurationDigest,
                              snapshot.includeLiteral == includeLiteral, snapshot.sourceFrontier == frontier, snapshot.publishedChunkFrontier == publishedFrontier else { throw SemanticError.invalid }
                        for result in snapshot.candidates {
                            guard result.source.projectID == projectID, result.source.sequence <= frontier,
                                  !excludingEventIDs.contains(result.source.eventID), result.fusedScore.isFinite, result.fusedScore > 0,
                                  result.retrievalPaths.allSatisfy({ $0 == "literal" || $0 == "lexical" }) else { throw SemanticError.invalid }
                            try verify(result.source, lease: activeSearchLease)
                            candidates[Data(result.source.eventID.utf8)] = Candidate(source: result.source, offset: result.offset, byteCount: result.byteCount,
                                textDigest: result.excerptDigest, paths: Set(result.retrievalPaths), score: result.fusedScore, cosine: nil)
                        }
                        meteredLexicalCoverage = snapshot.meteredLexicalCoverage
                        meteredLiteralCoverage = snapshot.meteredLiteralCoverage
                        rawSnapshotID = continuation.rawSnapshotID
                    } else {
                        try addRaw(literal, path: "literal", frontier: frontier, excluded: excludingEventIDs, candidates: &candidates)
                        try addRaw(lexicalHits, path: "lexical", frontier: frontier, excluded: excludingEventIDs, candidates: &candidates)
                        let raw = candidates.values.sorted { Self.rangeOrder($0.source, $0.offset, $1.source, $1.offset) }.map {
                            SemanticResultReference(source: $0.source, offset: $0.offset, byteCount: $0.byteCount, excerptDigest: $0.textDigest,
                                retrievalPaths: $0.paths.sorted(), fusedScore: $0.score, cosineScore: nil)
                        }
                        var snapshot = RawSnapshot(projectID: projectID, queryDigest: queryDigest, lexicalQueryDigest: lexicalDigest,
                            indexFingerprint: indexFingerprint, rankingFingerprint: rankingFingerprint, configurationFingerprint: configurationDigest,
                            exclusionsDigest: exclusionsDigest, queryConfigurationFingerprint: queryConfigurationDigest, includeLiteral: includeLiteral,
                            sourceFrontier: frontier, publishedChunkFrontier: publishedFrontier, candidates: raw)
                        snapshot.meteredLexicalCoverage = meteredLexicalCoverage
                        snapshot.meteredLiteralCoverage = meteredLiteralCoverage
                        let payload = try Self.canonical(snapshot)
                        rawSnapshotID = Self.digest(payload)
                        try execute("INSERT OR IGNORE INTO raw_snapshots VALUES (?,?,?)", [.text(rawSnapshotID), .text(projectID), .blob(payload)])
                        guard try self.query("SELECT payload FROM raw_snapshots WHERE id=? AND project_id=?", [.text(rawSnapshotID), .text(projectID)], { blob($0, 0) }).first == payload else { throw SemanticError.publicationConflict }
                    }
                    var vectorCount = 0, next: SemanticSearchContinuation?, disposition: String
                    switch encoding {
                    case .unsupported(let reason): disposition = reason.rawValue
                    case .vector(let values):
                        let normalized = try Self.normalized(values, dimension: encoder.dimension)
                        disposition = "supported"
                        var bindings: [Value] = [.text(indexFingerprint), .text(projectID), .integer(frontier), .integer(publishedFrontier), .integer(publishedFrontier)]
                        var cursor = ""
                        if let continuation {
                            cursor = " AND (c.source_sequence>? OR (c.source_sequence=? AND c.offset>?))"
                            bindings += [.integer(continuation.afterSequence), .integer(continuation.afterSequence), .integer(continuation.afterOffset)]
                        }
                        if !excludingEventIDs.isEmpty {
                            cursor += " AND c.event_id NOT IN (SELECT value FROM json_each(?))"
                            bindings.append(.text(String(decoding: try Self.canonical(excludingEventIDs.sorted()), as: UTF8.self)))
                        }
                        // Filtering by project, fingerprint, frozen source frontier,
                        // and publication frontier occurs before any vector ranking.
                        let vectorRows = configuration.maximumCandidateChunks + 1
                        let vectorByteBound = try MeteredRetrieval.checkedProduct(vectorRows, encoder.dimension * 4 + 1)
                        let rows = try MeteredRetrieval.charge(lease: episodeLease,
                            resources: EpisodeResources(vectorBytes: vectorByteBound, metadataRows: vectorRows)) {
                            // Bound the BLOB projection before Swift materialization.
                            // An oversized/corrupt vector is an integrity failure;
                            // its declared length never enlarges our reservation.
                            try self.query("SELECT j.source,c.offset,c.byte_count,c.text_digest,substr(c.vector,1,?),length(c.vector) FROM chunks c JOIN jobs j ON j.index_id=c.index_id AND j.event_id=c.event_id WHERE c.index_id=? AND c.project_id=? AND c.source_sequence<=? AND c.publication<=? AND j.ready_publication>0 AND j.ready_publication<=? AND c.reason='' AND j.state IN ('complete','unsupported')" + cursor + " ORDER BY c.source_sequence,c.offset LIMIT ?", [.integer(encoder.dimension * 4 + 1)] + bindings + [.integer(vectorRows)]) { statement in
                                guard Int(sqlite3_column_int64(statement, 5)) == encoder.dimension * 4 else { throw SemanticError.sourceMismatch }
                                return ChunkRow(source: try JSONDecoder().decode(MemorySourceReference.self, from: blob(statement, 0)), offset: Int(sqlite3_column_int64(statement, 1)), byteCount: Int(sqlite3_column_int64(statement, 2)), textDigest: string(statement, 3), vector: blob(statement, 4))
                            }
                        }
                        let inspected = Array(rows.prefix(configuration.maximumCandidateChunks))
                        vectorCount = inspected.count
                        if rows.count > inspected.count, let last = inspected.last {
                            next = SemanticSearchContinuation(projectID: projectID, indexFingerprint: indexFingerprint, queryDigest: queryDigest, sourceFrontier: frontier,
                                publishedChunkFrontier: publishedFrontier, afterSequence: last.source.sequence, afterOffset: last.offset,
                                rawSnapshotID: rawSnapshotID, includeLiteral: includeLiteral, episodeID: episodeLease?.episodeID)
                        }
                        var ranked: [(ChunkRow, Double)] = []
                        for row in inspected where !excludingEventIDs.contains(row.source.eventID) {
                            guard row.source.projectID == projectID else { throw SemanticError.sourceMismatch }
                            try verify(row.source, lease: activeSearchLease)
                            let vector = try Self.decodeVector(row.vector, dimension: encoder.dimension)
                            let score = zip(vector, normalized).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                            ranked.append((row, max(-1, min(1, score))))
                        }
                        ranked.sort { lhs, rhs in lhs.1 == rhs.1 ? Self.rangeOrder(lhs.0.source, lhs.0.offset, rhs.0.source, rhs.0.offset) : lhs.1 > rhs.1 }
                        var seen: Set<Data> = []
                        for (row, score) in ranked where seen.insert(Data(row.source.eventID.utf8)).inserted {
                            let rank = seen.count
                            let contribution = 1.0 / Double(configuration.reciprocalRankConstant + rank)
                            if var existing = candidates[Data(row.source.eventID.utf8)] {
                                existing.paths.insert("semantic"); existing.score += contribution; existing.cosine = score
                                candidates[Data(row.source.eventID.utf8)] = existing
                            } else {
                                candidates[Data(row.source.eventID.utf8)] = Candidate(source: row.source, offset: row.offset, byteCount: row.byteCount, textDigest: row.textDigest,
                                    paths: ["semantic"], score: contribution, cosine: score)
                            }
                        }
                    }
                    let ranked = candidates.values.sorted { lhs, rhs in
                        let lExact = lhs.paths.contains("literal"), rExact = rhs.paths.contains("literal")
                        if lExact != rExact { return lExact }
                        if lhs.score != rhs.score { return lhs.score > rhs.score }
                        return Self.rangeOrder(lhs.source, lhs.offset, rhs.source, rhs.offset)
                    }
                    let results = ranked.prefix(limit).map { candidate in
                        SemanticResultReference(source: candidate.source, offset: candidate.offset, byteCount: candidate.byteCount, excerptDigest: candidate.textDigest,
                            retrievalPaths: candidate.paths.sorted(), fusedScore: candidate.score, cosineScore: candidate.cosine)
                    }
                    var manifest = SemanticSearchManifest(version: 1, projectID: projectID, queryDigest: queryDigest, lexicalQueryDigest: Self.digest(Data(lexical.utf8)),
                        indexFingerprint: indexFingerprint, encoderFingerprint: encoderFingerprint, rankingFingerprint: rankingFingerprint,
                        configurationFingerprint: configurationDigest, configuration: configuration, queryConfigurationFingerprint: queryConfigurationDigest,
                        resultLimit: limit, sourceFrontier: frontier,
                        publishedChunkFrontier: publishedFrontier, queryDisposition: disposition, includeLiteral: includeLiteral,
                        literalScanBytes: literalReport?.rawWorkCharged ?? (continuation == nil && includeLiteral && query.utf8.count <= 4096 ? nil : 0),
                        literalSearchPerformed: continuation == nil && includeLiteral && query.utf8.count <= 4096,
                        rawSnapshotID: rawSnapshotID, rawFallbackAvailable: true, coverage: coverage,
                        vectorCandidatesInspected: vectorCount, vectorContinuation: next, excludedEventIDs: excludingEventIDs.sorted(), results: Array(results))
                    manifest.episodeID = episodeLease?.episodeID
                    manifest.meteredLexicalCoverage = meteredLexicalCoverage
                    manifest.meteredLiteralCoverage = meteredLiteralCoverage
                    let payload = try Self.canonical(manifest)
                    guard payload.count <= MemoryStore.maximumPayloadBytes else { throw SemanticError.invalid }
                    let manifestID = Self.digest(payload)
                    let hits = try readResults(manifest)
                    try execute("INSERT OR IGNORE INTO manifests VALUES (?,?,?)", [.text(manifestID), .text(projectID), .blob(payload)])
                    guard try self.query("SELECT payload FROM manifests WHERE id=? AND project_id=?", [.text(manifestID), .text(projectID)], { blob($0, 0) }).first == payload else { throw SemanticError.publicationConflict }
                    return SemanticSearchReport(hits: hits, manifestID: manifestID, manifest: manifest)
                }
            }
        }
    }

    func replay(manifestID: String, projectID: String, episodeLease: EpisodeLease? = nil) throws -> SemanticSearchReport {
        _ = try episodeLease?.checkActive(projectID: projectID)
        return try MeteredRetrieval.operation(lease: episodeLease) {
            try locked {
                let previousLease = activeSearchLease; activeSearchLease = episodeLease
                defer { activeSearchLease = previousLease }
                return try withSearchSQLFence(lease: episodeLease) {
                    guard let data = try MeteredRetrieval.metadata(lease: episodeLease, maximumRows: 1, {
                        try query("SELECT payload FROM manifests WHERE id=? AND project_id=?", [.text(manifestID), .text(projectID)], { blob($0, 0) }).first
                    }) else { throw SemanticError.unavailable }
                    guard Self.digest(data) == manifestID else { throw SemanticError.sourceMismatch }
                    let manifest = try JSONDecoder().decode(SemanticSearchManifest.self, from: data)
                    guard manifest.version == 1, episodeIdentifierEqual(manifest.projectID, projectID) else { throw SemanticError.sourceMismatch }
                    return SemanticSearchReport(hits: try readResults(manifest), manifestID: manifestID, manifest: manifest)
                }
            }
        }
    }

    private struct Job { let source: MemorySourceReference; let offset: Int; let failureAttempts: Int; let state: String }
    private struct RawSnapshot: Codable {
        let projectID: String; let queryDigest: String; let lexicalQueryDigest: String
        let indexFingerprint: String; let rankingFingerprint: String; let configurationFingerprint: String; let exclusionsDigest: String
        let queryConfigurationFingerprint: String
        let includeLiteral: Bool; let sourceFrontier: Int; let publishedChunkFrontier: Int; let candidates: [SemanticResultReference]
        var meteredLexicalCoverage: MeteredLexicalCoverage? = nil
        var meteredLiteralCoverage: MeteredLiteralCoverage? = nil
    }
    private struct ChunkRow { let source: MemorySourceReference; let offset: Int; let byteCount: Int; let textDigest: String; let vector: Data }
    private struct Candidate { let source: MemorySourceReference; let offset: Int; let byteCount: Int; let textDigest: String; var paths: Set<String>; var score: Double; var cosine: Double? }

    private func beginBackground(_ request: BackgroundIndexWorkRequest) throws -> BackgroundIndexWorkRecord {
        let prepared = try store.reserveBackgroundWork(request: request, clockSource: backgroundClock, limits: backgroundLimits)
        do {
            let armed = try store.armBackgroundWork(workID: prepared.request.id, bindingDigest: prepared.bindingDigest, clockSource: backgroundClock)
            do { try workerObserver?(.armed, armed) }
            catch {
                _ = try? store.settleBackgroundWork(workID: armed.request.id, settlement: .init(receiptID: UUID().uuidString, outcome: .outcomeUnknown), clockSource: backgroundClock)
                throw error
            }
            return armed
        } catch {
            _ = try? store.settleBackgroundWork(workID: prepared.request.id,
                settlement: .init(receiptID: UUID().uuidString, outcome: .cancelledBeforeDispatch), clockSource: backgroundClock)
            throw error
        }
    }

    private func settleBackgroundFailure(_ work: BackgroundIndexWorkRecord, error: Error) throws {
        let outcome: BackgroundIndexWorkOutcome = error is BackgroundIndexBudgetError ? .outcomeUnknown : .failedConfirmed
        _ = try store.settleBackgroundWork(workID: work.request.id,
            settlement: .init(receiptID: UUID().uuidString, outcome: outcome), clockSource: backgroundClock)
    }

    private func backgroundMetadata<T>(projectID: String, target: BackgroundIndexMetadataTarget,
        afterSequence: Int = 0, throughSequence: Int? = nil, limit: Int = 1,
        sourceReferences: [BackgroundIndexSourceReference]? = nil, _ operation: () throws -> T) throws -> T {
        let descriptor = BackgroundIndexMetadataDescriptor(target: target, afterSequence: afterSequence,
            throughSequence: throughSequence, limit: limit,
            sourceReferencesSHA256: try sourceReferences.map { try BackgroundIndexCanonical.digest($0) })
        let request = try BackgroundIndexWorkRequest.metadata(id: UUID().uuidString, projectID: projectID,
            indexFingerprint: indexFingerprint, adapterIdentity: backgroundAdapterIdentity,
            descriptor: descriptor, sourceReferences: sourceReferences)
        let work = try beginBackground(request)
        do {
            let value = try operation()
            _ = try store.settleBackgroundWork(workID: work.request.id,
                settlement: .init(receiptID: UUID().uuidString, outcome: .completed), clockSource: backgroundClock)
            return value
        } catch {
            try? settleBackgroundFailure(work, error: error)
            throw error
        }
    }

    private func enqueueMetered(projectID: String, frontier: Int) throws -> Int {
        let cursor = try backgroundMetadata(projectID: projectID, target: .scopeCursor, throughSequence: frontier) {
            try locked { try integer("SELECT scheduled_sequence FROM scopes WHERE index_id=? AND project_id=?", [.text(indexFingerprint), .text(projectID)]) }
        }
        guard cursor <= frontier else { throw SemanticError.sourceMismatch }
        let candidates = try backgroundMetadata(projectID: projectID, target: .sourceManifest,
            afterSequence: cursor, throughSequence: frontier, limit: configuration.maximumNewSourcesPerRun) {
            try store.sourceManifest(projectID: projectID, afterSequence: cursor, throughSequence: frontier, limit: configuration.maximumNewSourcesPerRun)
        }
        // Large source IDs can make the canonical scheduling snapshot exceed
        // its independent durable bound. Schedule an ordered prefix only;
        // leave the remainder behind the unchanged cursor for a later trigger.
        var sources = candidates
        while !sources.isEmpty {
            if try BackgroundIndexCanonical.data(sources.map(BackgroundWorkerAccounting.reference)).count <= BackgroundIndexCanonical.maximumSnapshotBytes { break }
            sources.removeLast()
        }
        if sources.isEmpty { return 0 }
        return try backgroundMetadata(projectID: projectID, target: .scheduleSources, afterSequence: cursor,
            throughSequence: frontier, limit: sources.count, sourceReferences: sources.map(BackgroundWorkerAccounting.reference)) {
            try locked {
                try transaction {
                    guard try integer("SELECT scheduled_sequence FROM scopes WHERE index_id=? AND project_id=?", [.text(indexFingerprint), .text(projectID)]) == cursor else { throw SemanticError.publicationConflict }
                    try execute("INSERT OR IGNORE INTO scopes VALUES (?,?,0)", [.text(indexFingerprint), .text(projectID)])
                    for source in sources {
                        guard episodeIdentifierEqual(source.projectID, projectID), source.sequence > cursor, source.sequence <= frontier else { throw SemanticError.sourceMismatch }
                        let data = try Self.canonical(source)
                        try execute("INSERT OR IGNORE INTO jobs(index_id,event_id,project_id,source_sequence,source) VALUES (?,?,?,?,?)", [.text(indexFingerprint), .text(source.eventID), .text(projectID), .integer(source.sequence), .blob(data)])
                        guard try query("SELECT source FROM jobs WHERE index_id=? AND event_id=?", [.text(indexFingerprint), .text(source.eventID)], { blob($0, 0) }).first == data else { throw SemanticError.publicationConflict }
                    }
                    if let last = sources.last { try execute("UPDATE scopes SET scheduled_sequence=? WHERE index_id=? AND project_id=?", [.integer(last.sequence), .text(indexFingerprint), .text(projectID)]) }
                    return sources.count
                }
            }
        }
    }

    private func peek(projectID: String, frontier: Int) throws -> Job? {
        try query("SELECT source,next_offset,failure_attempts,state FROM jobs WHERE index_id=? AND project_id=? AND source_sequence<=? AND (state='pending' OR (state='failed' AND failure_attempts<?)) ORDER BY source_sequence LIMIT 1", [.text(indexFingerprint), .text(projectID), .integer(frontier), .integer(configuration.maximumFailureAttempts)]) { statement in
            let source = try JSONDecoder().decode(MemorySourceReference.self, from: blob(statement, 0))
            guard episodeIdentifierEqual(source.projectID, projectID) else { throw SemanticError.sourceMismatch }
            return Job(source: source, offset: Int(sqlite3_column_int64(statement, 1)), failureAttempts: Int(sqlite3_column_int64(statement, 2)), state: string(statement, 3))
        }.first
    }

    private func claim(_ job: Job) throws {
        try transaction {
            try execute("UPDATE jobs SET state='processing' WHERE index_id=? AND event_id=? AND source=? AND next_offset=? AND state=? AND failure_attempts=?", [.text(indexFingerprint), .text(job.source.eventID), .blob(try Self.canonical(job.source)), .integer(job.offset), .text(job.state), .integer(job.failureAttempts)])
            guard sqlite3_changes(database) == 1 else { throw SemanticError.publicationConflict }
        }
    }

    private func releaseClaim(_ job: Job) throws {
        try execute("UPDATE jobs SET state='pending' WHERE index_id=? AND event_id=? AND source=? AND next_offset=? AND state='processing'", [.text(indexFingerprint), .text(job.source.eventID), .blob(try Self.canonical(job.source)), .integer(job.offset)])
    }

    private func failUnclaimed(_ job: Job, reason: String) throws {
        try execute("UPDATE jobs SET state='failed',failure_attempts=failure_attempts+1,failure_reason=? WHERE index_id=? AND event_id=? AND source=? AND next_offset=? AND state=? AND failure_attempts=?", [.text(reason), .text(indexFingerprint), .text(job.source.eventID), .blob(try Self.canonical(job.source)), .integer(job.offset), .text(job.state), .integer(job.failureAttempts)])
    }

    private func publish(_ job: Job, byteCount: Int, textDigest: String, vector: Data, reason: String) throws -> Int {
        // The caller already holds sidecar -> main ownership. The final main
        // gate verified the complete source and actual reader execution; this
        // callback performs bounded sidecar SQL/commit only.
        guard job.offset >= 0, byteCount > 0, job.offset + byteCount <= job.source.byteCount else { throw SemanticError.sourceMismatch }
        return try transaction {
            let current = try query("SELECT source,next_offset,state,unsupported_chunks FROM jobs WHERE index_id=? AND event_id=?", [.text(indexFingerprint), .text(job.source.eventID)]) { (blob($0, 0), Int(sqlite3_column_int64($0, 1)), string($0, 2), Int(sqlite3_column_int64($0, 3))) }.first
            guard let current, current.0 == (try Self.canonical(job.source)), current.1 == job.offset, current.2 == "processing" else { throw SemanticError.publicationConflict }
            try execute("INSERT INTO chunks(index_id,event_id,source_sequence,project_id,offset,byte_count,text_digest,vector,reason) VALUES (?,?,?,?,?,?,?,?,?)",
                [.text(indexFingerprint), .text(job.source.eventID), .integer(job.source.sequence), .text(job.source.projectID), .integer(job.offset), .integer(byteCount), .text(textDigest), .blob(vector), .text(reason)])
            let publication = Int(sqlite3_last_insert_rowid(database))
            let next = job.offset + byteCount
            let holes = current.3 + (reason.isEmpty ? 0 : 1)
            let state = next == job.source.byteCount ? (holes > 0 ? "unsupported" : "complete") : "pending"
            let readyPublication = next == job.source.byteCount ? Int(sqlite3_last_insert_rowid(database)) : 0
            try execute("UPDATE jobs SET next_offset=?,indexed_bytes=indexed_bytes+?,indexed_chunks=indexed_chunks+?,unsupported_chunks=unsupported_chunks+?,failure_reason='',ready_publication=?,state=? WHERE index_id=? AND event_id=?",
                [.integer(next), .integer(reason.isEmpty ? byteCount : 0), .integer(reason.isEmpty ? 1 : 0), .integer(reason.isEmpty ? 0 : 1), .integer(readyPublication), .text(state), .text(indexFingerprint), .text(job.source.eventID)])
            return publication
        }
    }

    private func completeEmpty(_ job: Job) throws {
        guard job.source.byteCount == 0, job.offset == 0 else { throw SemanticError.sourceMismatch }
        try execute("UPDATE jobs SET state='complete' WHERE index_id=? AND event_id=? AND source=? AND next_offset=0 AND state='processing'", [.text(indexFingerprint), .text(job.source.eventID), .blob(try Self.canonical(job.source))])
        guard sqlite3_changes(database) == 1 else { throw SemanticError.publicationConflict }
    }

    private func fail(_ job: Job, reason: String) throws {
        try execute("UPDATE jobs SET state='failed',failure_attempts=failure_attempts+1,failure_reason=? WHERE index_id=? AND event_id=? AND next_offset=? AND state='processing'",
            [.text(reason), .text(indexFingerprint), .text(job.source.eventID), .integer(job.offset)])
    }

    private func verify(_ source: MemorySourceReference, lease: EpisodeLease? = nil) throws {
        _ = try lease?.checkActive(projectID: source.projectID)
        guard source.sequence > 0, source.byteCount >= 0, source.byteCount <= MemoryStore.maximumPayloadBytes,
              try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 1, {
                  try store.sourceManifest(projectID: source.projectID, afterSequence: source.sequence - 1, throughSequence: source.sequence, limit: 1).first
              }) == source else { throw SemanticError.sourceMismatch }
    }

    private func coverage(projectID: String, frontier: Int, publishedFrontier: Int) throws -> SemanticCoverage {
        _ = try activeSearchLease?.checkActive(projectID: projectID)
        let sources = try MeteredRetrieval.authoritative(store: store, lease: activeSearchLease) {
            try store.sourceManifest(projectID: projectID, afterSequence: 0, throughSequence: frontier, limit: configuration.maximumManifestSources)
        }
        let more = try sources.last.map { source in
            try MeteredRetrieval.authoritative(store: store, lease: activeSearchLease) {
                try !store.sourceManifest(projectID: projectID, afterSequence: source.sequence, throughSequence: frontier, limit: 1).isEmpty
            }
        } ?? false
        var states: [SemanticSourceCoverage] = [], holes: [SemanticCoverageHole] = [], holesTotal = 0
        for source in sources {
            let job = try query("SELECT source,next_offset,failure_attempts,failure_reason,state FROM jobs WHERE index_id=? AND event_id=? AND project_id=?", [.text(indexFingerprint), .text(source.eventID), .text(projectID)]) { (blob($0, 0), Int(sqlite3_column_int64($0, 1)), Int(sqlite3_column_int64($0, 2)), string($0, 3), string($0, 4)) }.first
            let canonicalSource = try Self.canonical(source)
            guard job == nil || job!.0 == canonicalSource else { throw SemanticError.sourceMismatch }
            let bindings: [Value] = [.text(indexFingerprint), .text(projectID), .text(source.eventID), .integer(publishedFrontier)]
            let summary = try query("SELECT coalesce(sum(byte_count),0),coalesce(max(offset+byte_count),0),coalesce(sum(CASE WHEN reason='' THEN byte_count ELSE 0 END),0),coalesce(sum(CASE WHEN reason='' THEN 1 ELSE 0 END),0),coalesce(sum(CASE WHEN reason!='' THEN 1 ELSE 0 END),0) FROM chunks WHERE index_id=? AND project_id=? AND event_id=? AND publication<=?", bindings) {
                (Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1)), Int(sqlite3_column_int64($0, 2)), Int(sqlite3_column_int64($0, 3)), Int(sqlite3_column_int64($0, 4)))
            }.first!
            let offset = summary.1, indexedBytes = summary.2, indexedChunks = summary.3, unsupported = summary.4
            guard summary.0 == offset, offset <= source.byteCount else { throw SemanticError.sourceMismatch }
            holesTotal += unsupported
            if holes.count < configuration.maximumReportedHoles {
                let ranges = try query("SELECT offset,byte_count,reason FROM chunks WHERE index_id=? AND project_id=? AND event_id=? AND publication<=? AND reason!='' ORDER BY offset LIMIT ?", bindings + [.integer(configuration.maximumReportedHoles - holes.count)]) {
                    SemanticCoverageHole(eventID: source.eventID, offset: Int(sqlite3_column_int64($0, 0)), byteCount: Int(sqlite3_column_int64($0, 1)), reason: string($0, 2))
                }
                holes.append(contentsOf: ranges)
            }
            let failed = job?.4 == "failed"
            let state = failed ? "failed" : (offset == source.byteCount && job != nil ? (unsupported > 0 ? "unsupported" : "complete") : "pending")
            states.append(SemanticSourceCoverage(source: source, state: state, nextOffset: offset, indexedBytes: indexedBytes,
                indexedChunks: indexedChunks, unsupportedChunks: unsupported, failureAttempts: job?.2 ?? 0, failureReason: (job?.3.isEmpty ?? true) ? nil : job?.3))
        }
        return SemanticCoverage(inspectedSources: states.count, completeSources: states.filter { $0.state == "complete" }.count,
            pendingSources: states.filter { $0.state == "pending" }.count, unsupportedSources: states.filter { $0.unsupportedChunks > 0 }.count,
            failedSources: states.filter { $0.state == "failed" }.count, indexedBytes: states.reduce(0) { $0 + $1.indexedBytes },
            inspectedSourceBytes: sources.reduce(0) { $0 + $1.byteCount }, indexedChunks: states.reduce(0) { $0 + $1.indexedChunks },
            unsupportedChunks: states.reduce(0) { $0 + $1.unsupportedChunks }, metadataContinuationSequence: more ? sources.last?.sequence : nil,
            holes: holes, holesTruncated: holesTotal > holes.count, sources: states)
    }

    private func addRaw(_ hits: [MemoryHit], path: String, frontier: Int, excluded: ExactSourceIDs, candidates: inout [Data: Candidate]) throws {
        var rank = 0
        for hit in hits where !excluded.contains(hit.eventID) {
            // Obtain source sequence without reading a complete payload.
            let source = try querySource(hit)
            guard source.sequence <= frontier else { continue }
            rank += 1
            let contribution = 1.0 / Double(configuration.reciprocalRankConstant + rank)
            if var existing = candidates[Data(hit.eventID.utf8)] {
                existing.paths.insert(path); existing.score += contribution; candidates[Data(hit.eventID.utf8)] = existing
            } else {
                candidates[Data(hit.eventID.utf8)] = Candidate(source: source, offset: hit.excerptOffset, byteCount: hit.excerpt.utf8.count, textDigest: Self.digest(Data(hit.excerpt.utf8)), paths: [path], score: contribution, cosine: nil)
            }
        }
    }

    private func querySource(_ hit: MemoryHit) throws -> MemorySourceReference {
        _ = try activeSearchLease?.checkActive(projectID: hit.projectID)
        // A scoped indexed lookup obtains sequence without scanning the archive.
        guard let source = try MeteredRetrieval.sourceMetadata(store: store, lease: activeSearchLease, maximumRows: 1, { try store.sourceReference(eventID: hit.eventID, projectID: hit.projectID) }),
              source.digest == hit.digest, source.byteCount == hit.totalBytes, episodeIdentifierEqual(source.conversationID, hit.conversationID),
              source.role == hit.role, source.status == hit.status, source.createdAt == hit.createdAt else { throw SemanticError.sourceMismatch }
        return source
    }

    private func readResults(_ manifest: SemanticSearchManifest) throws -> [MemoryHit] {
        let excluded = ExactSourceIDs(manifest.excludedEventIDs)
        return try manifest.results.map { result in
            guard !excluded.contains(result.source.eventID), episodeIdentifierEqual(result.source.projectID, manifest.projectID), result.source.sequence <= manifest.sourceFrontier,
                  result.offset >= 0, result.byteCount > 0, result.byteCount <= MemoryStore.maximumPageBytes,
                  result.source.byteCount >= 0, result.source.byteCount <= MemoryStore.maximumPayloadBytes,
                  result.offset <= result.source.byteCount,
                  result.byteCount <= result.source.byteCount - result.offset else { throw SemanticError.sourceMismatch }
            try verify(result.source, lease: activeSearchLease)
            let page = try MeteredRetrieval.read(store: store, source: result.source, offset: result.offset,
                length: result.byteCount, lease: activeSearchLease, nested: true, examinedPasses: 2)
            guard page.byteCount == result.byteCount, page.digest == result.source.digest, page.totalBytes == result.source.byteCount,
                  page.status == result.source.status, Self.digest(Data(page.text.utf8)) == result.excerptDigest else { throw SemanticError.sourceMismatch }
            return MemoryHit(eventID: result.source.eventID, conversationID: result.source.conversationID, projectID: result.source.projectID,
                role: result.source.role, status: result.source.status, createdAt: result.source.createdAt, digest: result.source.digest,
                totalBytes: result.source.byteCount, excerptOffset: result.offset, excerpt: page.text)
        }
    }

    private static func chunk(_ text: String, atEOF: Bool) -> String {
        guard !atEOF else { return text }
        // Prefer the last whitespace in the latter half. Bytes including that
        // separator are retained, so ranges partition the full original text.
        let bytes = text.utf8.count
        var split: String.Index?
        for index in text.indices where text[index].isWhitespace {
            let next = text.index(after: index)
            if text[..<next].utf8.count >= bytes / 2 { split = next }
        }
        return split.map { String(text[..<$0]) } ?? text
    }

    private static func rangeOrder(_ lhs: MemorySourceReference, _ lo: Int, _ rhs: MemorySourceReference, _ ro: Int) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.eventID != rhs.eventID { return lhs.eventID < rhs.eventID }
        return lo < ro
    }

    static func normalized(_ values: [Float], dimension: Int) throws -> [Float] {
        guard values.count == dimension, values.allSatisfy(\.isFinite) else { throw SemanticError.invalid }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0 else { throw SemanticError.invalid }
        return values.map { Float(Double($0) / norm) }
    }

    static func vectorData(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        return data
    }

    private static func decodeVector(_ data: Data, dimension: Int) throws -> [Float] {
        guard data.count == dimension * 4 else { throw SemanticError.sourceMismatch }
        let bytes = Array(data)
        let values: [Float] = stride(from: 0, to: bytes.count, by: 4).map { offset in
            let low = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            let high = (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            return Float(bitPattern: low | high)
        }
        guard values.allSatisfy(\.isFinite), abs(values.reduce(0.0) { $0 + Double($1) * Double($1) } - 1) < 0.001 else { throw SemanticError.sourceMismatch }
        return values
    }

    static func canonical<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    private enum Value { case text(String), integer(Int), blob(Data) }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { mutex.lock(); defer { mutex.unlock() }; return try body() }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result } catch { try? execute("ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SemanticError.database }
        do {
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1), code: Int32
                switch value {
                case .text(let text): code = text.utf8CString.withUnsafeBufferPointer { sqlite3_bind_text(statement, position, $0.baseAddress, Int32($0.count - 1), transient) }
                case .integer(let value): code = sqlite3_bind_int64(statement, position, Int64(value))
                case .blob(let bytes):
                    if bytes.isEmpty { code = sqlite3_bind_zeroblob(statement, position, 0) }
                    else { code = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) } }
                }
                guard code == SQLITE_OK else { throw SemanticError.database }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SemanticError.database }
    }
    private func query<T>(_ sql: String, _ values: [Value] = [], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values); defer { sqlite3_finalize(statement) }
        var output: [T] = []
        while true {
            _ = try activeSearchLease?.checkActive()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return output }
            guard code == SQLITE_ROW else { throw SemanticError.database }
            output.append(try map(statement))
        }
    }
    private func withSearchSQLFence<T>(lease: EpisodeLease?, _ body: () throws -> T) throws -> T {
        guard let lease else { return try body() }
        guard let database else { throw SemanticError.database }
        let previous = activeSearchFence, fence = try lease.progressGuard()
        activeSearchFence = fence
        defer { activeSearchFence = previous }
        return try fence.perform(on: database, restoring: previous, body)
    }
    private func integer(_ sql: String, _ values: [Value] = []) throws -> Int { try query(sql, values) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0 }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data { guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }; return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))) }
    private static func openPrivate(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SemanticError.invalid }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else { close(descriptor); throw SemanticError.invalid }
        return descriptor
    }
    private func secureSidecars() throws {
        for suffix in ["-wal", "-shm"] {
            let url = directory.appendingPathComponent("index.sqlite3" + suffix)
            if FileManager.default.fileExists(atPath: url.path) { close(try Self.openPrivate(url)) }
        }
    }
}
