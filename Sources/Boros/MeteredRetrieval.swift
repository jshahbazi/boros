import Foundation
import CryptoKit

enum MeteredRetrievalError: LocalizedError {
    case invalid, sourceMismatch
    var errorDescription: String? {
        switch self {
        case .invalid: return "Invalid metered retrieval request or continuation."
        case .sourceMismatch: return "Retrieved source metadata or bytes no longer match the original source."
        }
    }
}

/// These continuations carry only source metadata. Their candidate order and
/// frontier are frozen, and a caller cannot replenish an episode by replaying
/// one under another lease.
struct MeteredLexicalContinuation: Codable, Equatable {
    let projectID: String
    let episodeID: String
    let queryDigest: String
    let exclusionsDigest: String
    let matching: String
    let sourceFrontier: Int
    let candidates: [MemorySourceReference]
    let nextCandidate: Int
    let candidateWindowFull: Bool
}

struct MeteredLexicalReport {
    let hits: [MemoryHit]
    let sourceFrontier: Int
    let inspectedCandidates: Int
    let rawWorkCharged: Int
    let candidateWindowFull: Bool
    let continuation: MeteredLexicalContinuation?
    var candidateWindowComplete: Bool { continuation == nil }
    var coverage: MeteredLexicalCoverage { MeteredLexicalCoverage(sourceFrontier: sourceFrontier,
        inspectedCandidates: inspectedCandidates, rawWorkCharged: rawWorkCharged,
        candidateWindowFull: candidateWindowFull, continuation: continuation) }
}

struct MeteredLexicalCoverage: Codable, Equatable {
    let sourceFrontier: Int
    let inspectedCandidates: Int
    let rawWorkCharged: Int
    let candidateWindowFull: Bool
    let continuation: MeteredLexicalContinuation?
    var candidateWindowComplete: Bool { continuation == nil }
}

struct MeteredLiteralContinuation: Codable, Equatable {
    let projectID: String
    let episodeID: String
    let queryDigest: String
    let exclusionsDigest: String
    let sourceFrontier: Int
    let afterSequence: Int
}

struct MeteredLiteralReport {
    let hits: [MemoryHit]
    let sourceFrontier: Int
    let inspectedSources: Int
    let rawWorkCharged: Int
    let continuation: MeteredLiteralContinuation?
    let incompleteReason: String?
    var complete: Bool { continuation == nil }
    var coverage: MeteredLiteralCoverage { MeteredLiteralCoverage(sourceFrontier: sourceFrontier,
        inspectedSources: inspectedSources, rawWorkCharged: rawWorkCharged,
        continuation: continuation, incompleteReason: incompleteReason) }
}

struct MeteredLiteralCoverage: Codable, Equatable {
    let sourceFrontier: Int
    let inspectedSources: Int
    let rawWorkCharged: Int
    let continuation: MeteredLiteralContinuation?
    let incompleteReason: String?
    var complete: Bool { continuation == nil }
}

/// raw_work_v1 measures conservative logical source work. A load, digest and
/// matching pass each count separately; cache hits do not refund work. Every
/// reservation is committed before a source or derived vector is inspected.
enum MeteredRetrieval {
    static let adapterIdentity = "boros.raw_work_v1.memory_operations_v1"

    static func operation<T>(lease: EpisodeLease?, nested: Bool = false, _ body: () throws -> T) throws -> T {
        guard let lease else { return try body() }
        if nested { _ = try lease.checkActive(); return try body() }
        return try charge(lease: lease, resources: EpisodeResources(memoryOperations: 1), body)
    }

    static func charge<T>(lease: EpisodeLease?, kind: EpisodeWorkKind = .retrieval,
                          resources: EpisodeResources, inputTokensKnown: Bool = true,
                          identity: String = adapterIdentity, _ body: () throws -> T) throws -> T {
        guard let lease else { return try body() }
        let prepared = try lease.prepare(kind: kind, resources: resources, adapterIdentity: identity,
            inputTokensKnown: inputTokensKnown)
        // The short local handoff records attempted work; the source read or
        // encoder call executes outside the owner transaction and mutex.
        let started = try lease.dispatch(prepared, start: {})
        do {
            _ = try lease.checkActive()
            let value = try body()
            // Raw/metadata/vector reservations are declared conservative work
            // bounds. They are charged, but are not measured provider usage.
            _ = try lease.settle(started, outcome: .completed)
            _ = try lease.checkActive()
            return value
        } catch {
            _ = try? lease.settle(started, outcome: .failedConfirmed)
            throw error
        }
    }

    static func metadata<T>(lease: EpisodeLease?, maximumRows: Int, _ body: () throws -> T) throws -> T {
        try charge(lease: lease, resources: EpisodeResources(metadataRows: maximumRows), body)
    }

    static func authoritative<T>(store: MemoryStore, lease: EpisodeLease?, _ body: () throws -> T) throws -> T {
        if let lease { return try store.withEpisodeSQLFence(lease: lease, body) }
        return try body()
    }

    static func sourceMetadata<T>(store: MemoryStore, lease: EpisodeLease?, maximumRows: Int,
                                  _ body: () throws -> T) throws -> T {
        try metadata(lease: lease, maximumRows: maximumRows) {
            try authoritative(store: store, lease: lease, body)
        }
    }

    static func available(_ resources: EpisodeResources, lease: EpisodeLease) throws -> Bool {
        let receipt = try lease.checkActive()
        return try receipt.charged.adding(receipt.held).adding(resources).fits(within: receipt.limits.resources)
    }

    static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        guard lhs >= 0, rhs >= 0 else { throw EpisodeBudgetError.invalid }
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw EpisodeBudgetError.invalid }
        return value
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func exclusionDigest(_ ids: Set<String>) throws -> String { digest(try JSONEncoder().encode(ids.sorted())) }

    /// Loading checks complete source identity and SHA-256 in MemoryStore.
    /// The caller declares additional matching/preview passes before loading.
    static func load(store: MemoryStore, reference: MemorySourceReference, lease: EpisodeLease,
                     passes: Int = 2) throws -> MemoryEvent {
        guard reference.byteCount >= 0, reference.byteCount <= MemoryStore.maximumPayloadBytes, passes >= 2 else { throw MeteredRetrievalError.sourceMismatch }
        let bytes = try checkedProduct(reference.byteCount, passes)
        return try charge(lease: lease, kind: .sourceRead, resources: EpisodeResources(rawSourceBytes: bytes, metadataRows: 1)) {
            try authoritative(store: store, lease: lease) { try store.loadCandidate(reference: reference) }
        }
    }

    /// A public page costs a logical operation. Internal evidence validation
    /// belongs to its composite operation, but repeated bytes remain charged.
    static func read(store: MemoryStore, source: MemorySourceReference, offset: Int, length: Int,
                     lease: EpisodeLease?, nested: Bool = false, examinedPasses: Int = 1) throws -> PayloadPage {
        guard offset >= 0, length > 0, length <= MemoryStore.maximumPageBytes,
              source.byteCount >= 0, source.byteCount <= MemoryStore.maximumPayloadBytes,
              offset <= source.byteCount, examinedPasses >= 1 else { throw MemoryError.invalid("invalid metered source page") }
        return try operation(lease: lease, nested: nested) {
            let bytes = try checkedProduct(length + 1, examinedPasses)
            return try charge(lease: lease, kind: .sourceRead, resources: EpisodeResources(rawSourceBytes: bytes)) {
                let page = try authoritative(store: store, lease: lease) { try store.read(eventID: source.eventID, offset: offset, length: length) }
                guard page.eventID == source.eventID, page.digest == source.digest,
                      page.totalBytes == source.byteCount, page.status == source.status else { throw MeteredRetrievalError.sourceMismatch }
                return page
            }
        }
    }

    static func page(store: MemoryStore, eventID: String, projectID: String, offset: Int, length: Int,
                     lease: EpisodeLease) throws -> PayloadPage {
        try operation(lease: lease) {
            guard let reference = try sourceMetadata(store: store, lease: lease, maximumRows: 1, {
                try store.sourceReference(eventID: eventID, projectID: projectID)
            }) else { throw MemoryError.missing("scoped source") }
            return try read(store: store, source: reference, offset: offset, length: length, lease: lease, nested: true)
        }
    }

    static func lexicalSearch(store: MemoryStore, query: String, projectID: String, limit: Int = 16,
                              matching: LexicalMatchMode = .allTerms, throughSequence: Int? = nil,
                              excludingEventIDs: Set<String> = [], lease: EpisodeLease,
                              continuation: MeteredLexicalContinuation? = nil,
                              nested: Bool = false) throws -> MeteredLexicalReport {
        try operation(lease: lease, nested: nested) {
            guard query.utf8.count <= 4096, (1...100).contains(limit), excludingEventIDs.count <= 10000 else { throw MeteredRetrievalError.invalid }
            let terms = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            guard terms.count <= 32 else { throw MemoryError.invalid("lexical search accepts at most 32 terms") }
            let queryDigest = digest(Data(query.utf8)), exclusions = try exclusionDigest(excludingEventIDs)
            let matchingID = matching == .allTerms ? "allTerms" : "anyTerm"
            let frontier: Int, references: [MemorySourceReference], first: Int, windowFull: Bool
            if let continuation {
                guard continuation.projectID == projectID, continuation.episodeID == lease.episodeID,
                      continuation.queryDigest == queryDigest, continuation.exclusionsDigest == exclusions,
                      continuation.matching == matchingID, continuation.sourceFrontier >= 0,
                      continuation.candidates.count <= 100, continuation.nextCandidate >= 0,
                      continuation.nextCandidate <= continuation.candidates.count,
                      throughSequence == nil || throughSequence == continuation.sourceFrontier,
                      continuation.candidates.allSatisfy({ $0.projectID == projectID && $0.sequence > 0 && $0.sequence <= continuation.sourceFrontier && $0.byteCount >= 0 && $0.byteCount <= MemoryStore.maximumPayloadBytes && !excludingEventIDs.contains($0.eventID) }) else { throw MeteredRetrievalError.invalid }
                frontier = continuation.sourceFrontier; references = continuation.candidates
                first = continuation.nextCandidate; windowFull = continuation.candidateWindowFull
            } else {
                frontier = try throughSequence ?? sourceMetadata(store: store, lease: lease, maximumRows: 1) { try store.sourceFrontier(projectID: projectID) }
                references = terms.isEmpty ? [] : try sourceMetadata(store: store, lease: lease, maximumRows: limit) {
                    try store.lexicalCandidateReferences(query: query, projectID: projectID, limit: limit, matching: matching,
                        throughSequence: frontier, excludingEventIDs: excludingEventIDs)
                }
                first = 0; windowFull = references.count == limit
            }
            var hits: [MemoryHit] = [], charged = 0, inspected = 0, next: Int?
            for index in first..<references.count {
                let reference = references[index]
                guard reference.byteCount >= 0, reference.byteCount <= MemoryStore.maximumPayloadBytes else { throw MeteredRetrievalError.sourceMismatch }
                // One materialization, one digest, a declared whole-source
                // bound for every Unicode term search, and two preview/range
                // walks. Retain only the excerpt before loading another BLOB.
                let bytes = try checkedProduct(reference.byteCount, 4 + terms.count)
                guard try available(EpisodeResources(rawSourceBytes: bytes, metadataRows: 1), lease: lease) else { next = index; break }
                let hit = try charge(lease: lease, kind: .sourceRead, resources: EpisodeResources(rawSourceBytes: bytes, metadataRows: 1)) {
                    let event = try authoritative(store: store, lease: lease) { try store.loadCandidate(reference: reference) }
                    return preview(event, terms: terms)
                }
                charged += bytes; inspected += 1
                if !hit.excerpt.isEmpty { hits.append(hit) }
            }
            let cursor = next.map { MeteredLexicalContinuation(projectID: projectID, episodeID: lease.episodeID,
                queryDigest: queryDigest, exclusionsDigest: exclusions, matching: matchingID, sourceFrontier: frontier,
                candidates: references, nextCandidate: $0, candidateWindowFull: windowFull) }
            return MeteredLexicalReport(hits: hits, sourceFrontier: frontier, inspectedCandidates: inspected,
                rawWorkCharged: charged, candidateWindowFull: windowFull, continuation: cursor)
        }
    }

    /// Exact byte matching uses streaming KMP; query state crosses page and
    /// UTF-8 boundaries without decoding or rescanning an overlap. A source
    /// must seal against its full SHA before any match can be published.
    static func literalSearch(store: MemoryStore, query: String, projectID: String, limit: Int = 16,
                              throughSequence: Int? = nil, excludingEventIDs: Set<String> = [], lease: EpisodeLease,
                              continuation: MeteredLiteralContinuation? = nil,
                              maximumSources: Int = 1000, nested: Bool = false) throws -> MeteredLiteralReport {
        try operation(lease: lease, nested: nested) {
            guard !query.isEmpty, query.utf8.count <= MemoryStore.maximumPageBytes, (1...100).contains(limit),
                  (1...1000).contains(maximumSources), excludingEventIDs.count <= 10000 else { throw MeteredRetrievalError.invalid }
            let needle = Array(query.utf8), queryDigest = digest(Data(needle)), exclusions = try exclusionDigest(excludingEventIDs)
            let frontier: Int
            var cursor = 0
            if let continuation {
                guard continuation.projectID == projectID, continuation.episodeID == lease.episodeID,
                      continuation.queryDigest == queryDigest, continuation.exclusionsDigest == exclusions,
                      continuation.sourceFrontier >= 0, continuation.afterSequence >= 0,
                      continuation.afterSequence <= continuation.sourceFrontier,
                      throughSequence == nil || throughSequence == continuation.sourceFrontier else { throw MeteredRetrievalError.invalid }
                frontier = continuation.sourceFrontier; cursor = continuation.afterSequence
            } else {
                frontier = try throughSequence ?? sourceMetadata(store: store, lease: lease, maximumRows: 1) { try store.sourceFrontier(projectID: projectID) }
            }
            let sources = try sourceMetadata(store: store, lease: lease, maximumRows: maximumSources) {
                try store.sourceManifest(projectID: projectID, afterSequence: cursor, throughSequence: frontier, limit: maximumSources)
            }
            var table = [Int](repeating: 0, count: needle.count), prefix = 0
            if needle.count > 1 {
                for index in 1..<needle.count {
                    while prefix > 0 && needle[index] != needle[prefix] { prefix = table[prefix - 1] }
                    if needle[index] == needle[prefix] { prefix += 1 }
                    table[index] = prefix
                }
            }
            var hits: [MemoryHit] = [], inspected = 0, charged = 0, reason: String?
            for source in sources {
                guard source.projectID == projectID, source.sequence > cursor, source.sequence <= frontier,
                      source.byteCount >= 0, source.byteCount <= MemoryStore.maximumPayloadBytes else { throw MeteredRetrievalError.sourceMismatch }
                if excludingEventIDs.contains(source.eventID) { cursor = source.sequence; continue }
                // A page can shorten by three bytes at a UTF-8 boundary. This
                // bound includes that repeated materialization and the extra
                // byte read by SQLite's page primitive. KMP comparisons can
                // visit each byte twice, in addition to loading and hashing.
                let pages = source.byteCount / (MemoryStore.maximumPageBytes - 3) + 1
                let bound = try checkedProduct(source.byteCount + pages * 4, 4)
                guard try available(EpisodeResources(rawSourceBytes: bound), lease: lease) else { reason = "raw_source_budget"; break }
                let match: Int? = try charge(lease: lease, kind: .sourceRead, resources: EpisodeResources(rawSourceBytes: bound)) {
                    var hasher = SHA256(), offset = 0, matched = 0, firstMatch: Int?
                    repeat {
                        _ = try lease.checkActive()
                        let page = try authoritative(store: store, lease: lease) { try store.read(eventID: source.eventID, offset: offset, length: MemoryStore.maximumPageBytes) }
                        guard page.digest == source.digest, page.totalBytes == source.byteCount, page.status == source.status,
                              page.offset == offset, page.byteCount > 0 || source.byteCount == 0 else { throw MeteredRetrievalError.sourceMismatch }
                        let bytes = Data(page.text.utf8)
                        hasher.update(data: bytes)
                        for (index, byte) in bytes.enumerated() {
                            while matched > 0 && byte != needle[matched] { matched = table[matched - 1] }
                            if byte == needle[matched] { matched += 1 }
                            if matched == needle.count {
                                if firstMatch == nil { firstMatch = offset + index + 1 - needle.count }
                                matched = table[matched - 1]
                            }
                        }
                        offset += page.byteCount
                        guard offset <= source.byteCount else { throw MeteredRetrievalError.sourceMismatch }
                        if page.nextOffset == nil { break }
                        guard page.nextOffset == offset else { throw MeteredRetrievalError.sourceMismatch }
                    } while offset < source.byteCount
                    guard offset == source.byteCount,
                          hasher.finalize().map({ String(format: "%02x", $0) }).joined() == source.digest else { throw MeteredRetrievalError.sourceMismatch }
                    return firstMatch
                }
                inspected += 1; charged += bound; cursor = source.sequence
                if let match {
                    hits.append(MemoryHit(eventID: source.eventID, conversationID: source.conversationID, projectID: source.projectID,
                        role: source.role, status: source.status, createdAt: source.createdAt, digest: source.digest,
                        totalBytes: source.byteCount, excerptOffset: match, excerpt: query))
                    if hits.count == limit { reason = "result_limit"; break }
                }
            }
            if reason == nil && sources.count == maximumSources { reason = "source_window" }
            // A one-row bounded lookahead can establish completion even when
            // the last result happened to coincide with the final source.
            if reason != "raw_source_budget", reason != nil {
                let more = try sourceMetadata(store: store, lease: lease, maximumRows: 1) {
                    try store.sourceManifest(projectID: projectID, afterSequence: cursor, throughSequence: frontier, limit: 1)
                }
                if more.isEmpty { reason = nil }
            }
            let next = reason.map { _ in MeteredLiteralContinuation(projectID: projectID, episodeID: lease.episodeID,
                queryDigest: queryDigest, exclusionsDigest: exclusions, sourceFrontier: frontier, afterSequence: cursor) }
            return MeteredLiteralReport(hits: hits, sourceFrontier: frontier, inspectedSources: inspected,
                rawWorkCharged: charged, continuation: next, incompleteReason: reason)
        }
    }

    private static func preview(_ event: MemoryEvent, terms: [String]) -> MemoryHit {
        let target = terms.lazy.compactMap { event.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let center = target?.lowerBound ?? event.text.startIndex
        let lower = event.text.index(center, offsetBy: -160, limitedBy: event.text.startIndex) ?? event.text.startIndex
        let upper = event.text.index(lower, offsetBy: 560, limitedBy: event.text.endIndex) ?? event.text.endIndex
        let candidate = Data(event.text[lower..<upper].utf8)
        var end = min(candidate.count, MemoryStore.maximumPageBytes)
        while end > 0 && String(data: candidate.prefix(end), encoding: .utf8) == nil { end -= 1 }
        let excerpt = String(decoding: candidate.prefix(end), as: UTF8.self)
        return MemoryHit(eventID: event.id, conversationID: event.conversationID, projectID: event.projectID,
            role: event.role, status: event.status, createdAt: event.createdAt, digest: event.digest,
            totalBytes: event.byteCount, excerptOffset: event.text[..<lower].utf8.count, excerpt: excerpt)
    }
}
