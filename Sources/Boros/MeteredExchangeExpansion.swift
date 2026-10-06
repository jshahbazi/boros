import Foundation

struct ExchangeExpansionReport {
    let hits: [MemoryHit]
    /// Metadata only. Prefixes remain excerpts; the complete originals stay
    /// in the store and retain their digest, byte length and capture status.
    let audit: [String: Any]
}

/// Bounded same-conversation adjacency, not a claim of complete exchange
/// coverage or answer sufficiency. Every added payload read is prefunded.
enum MeteredExchangeExpansion {
    static let version = "following-assistant-prefix-v2"
    static let maximumCandidates = 16
    private struct PrimarySpan: Hashable {
        let eventID: Data
        let offset: Int
        let bytes: Data
    }

    /// Complete a matched source only when the entire original fits one page.
    /// Verify the incoming fragment before replacement so expansion cannot
    /// conceal corrupt retrieval evidence. This does not widen candidate scope.
    static func completeShortPrimaries(store: MemoryStore, projectID: String, primaryHits: [MemoryHit],
        sourceFrontier: Int, excludingSourceIDs: ExactSourceIDs, episodeLease: EpisodeLease? = nil,
        operationIsNested: Bool = false) throws -> ExchangeExpansionReport {
        _ = try episodeLease?.checkActive(projectID: projectID)
        guard sourceFrontier >= 0, primaryHits.count <= maximumCandidates, excludingSourceIDs.count <= 10000,
              primaryHits.allSatisfy({ episodeIdentifierEqual($0.projectID, projectID) && $0.excerptOffset >= 0
                  && $0.totalBytes >= 0 && $0.totalBytes <= MemoryStore.maximumPayloadBytes
                  && $0.excerptOffset <= $0.totalBytes && $0.excerpt.utf8.count <= $0.totalBytes - $0.excerptOffset }) else {
            throw MeteredRetrievalError.invalid
        }
        return try MeteredRetrieval.operation(lease: episodeLease, nested: operationIsNested) {
            var hits: [MemoryHit] = [], decisions: [[String: Any]] = []
            var completed = 0
            for hit in primaryHits {
                guard !excludingSourceIDs.contains(hit.eventID) else {
                    decisions.append(["event_id": hit.eventID, "disposition": "excluded_primary"]); continue
                }
                guard let source = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1, {
                    try store.sourceReference(eventID: hit.eventID, projectID: projectID)
                }), source.sequence <= sourceFrontier, matches(hit, source: source), hit.sourceTime == source.sourceTime else {
                    throw MeteredRetrievalError.sourceMismatch
                }
                guard source.byteCount > 0, source.byteCount <= MemoryStore.maximumPageBytes,
                      hit.excerptOffset != 0 || hit.excerpt.utf8.count != source.byteCount else {
                    hits.append(hit)
                    decisions.append(["event_id": hit.eventID, "disposition": "retained_primary"]); continue
                }
                let page = try MeteredRetrieval.read(store: store, source: source, offset: 0, length: source.byteCount,
                    lease: episodeLease, nested: true, examinedPasses: 3)
                let bytes = Data(page.text.utf8), end = hit.excerptOffset + hit.excerpt.utf8.count
                guard page.offset == 0, page.byteCount == source.byteCount, bytes.count == source.byteCount,
                      String(data: bytes.prefix(hit.excerptOffset), encoding: .utf8) != nil,
                      bytes.subdata(in: hit.excerptOffset..<end) == Data(hit.excerpt.utf8),
                      String(data: bytes.suffix(bytes.count - end), encoding: .utf8) != nil else {
                    throw MeteredRetrievalError.sourceMismatch
                }
                hits.append(MemoryHit(eventID: source.eventID, conversationID: source.conversationID, projectID: source.projectID,
                    role: source.role, status: source.status, createdAt: source.createdAt, digest: source.digest,
                    totalBytes: source.byteCount, excerptOffset: 0, excerpt: page.text, sourceTime: source.sourceTime))
                completed += 1
                decisions.append(["event_id": hit.eventID, "disposition": "completed_short_primary",
                    "original_excerpt_offset": hit.excerptOffset, "original_excerpt_bytes": hit.excerpt.utf8.count,
                    "complete_source_bytes": source.byteCount])
            }
            return ExchangeExpansionReport(hits: hits, audit: ["version": "complete-short-primaries-v1",
                "source_frontier": sourceFrontier, "primary_count": primaryHits.count,
                "retained_primary_count": hits.count, "completed_primary_count": completed, "decisions": decisions])
        }
    }

    static func expand(store: MemoryStore, projectID: String, primaryHits: [MemoryHit], sourceFrontier: Int,
        excludingSourceIDs: ExactSourceIDs, episodeLease: EpisodeLease? = nil,
        operationIsNested: Bool = false) throws -> ExchangeExpansionReport {
        _ = try episodeLease?.checkActive(projectID: projectID)
        guard sourceFrontier >= 0, primaryHits.count <= maximumCandidates, excludingSourceIDs.count <= 10000,
              primaryHits.allSatisfy({ episodeIdentifierEqual($0.projectID, projectID) && $0.excerptOffset >= 0
                  && $0.totalBytes >= 0 && $0.totalBytes <= MemoryStore.maximumPayloadBytes
                  && $0.excerptOffset <= $0.totalBytes && $0.excerpt.utf8.count <= $0.totalBytes - $0.excerptOffset }) else {
            throw MeteredRetrievalError.invalid
        }
        return try MeteredRetrieval.operation(lease: episodeLease, nested: operationIsNested) {
            var hits: [MemoryHit] = [], seenSpans: Set<PrimarySpan> = [], promotedSpans: Set<PrimarySpan> = []
            var expandedAnchors: Set<Data> = [], decisions: [[String: Any]] = []
            var retained = 0, added = 0, promoted = 0, truncated = 0
            for hit in primaryHits {
                let key = Data(hit.eventID.utf8)
                let span = PrimarySpan(eventID: key, offset: hit.excerptOffset, bytes: Data(hit.excerpt.utf8))
                if promotedSpans.contains(span) {
                    decisions.append(["anchor_event_id": hit.eventID, "disposition": "promoted_primary_retained"]); continue
                }
                guard hits.count < maximumCandidates else {
                    decisions.append(["anchor_event_id": hit.eventID, "disposition": "candidate_limit"]); continue
                }
                guard !excludingSourceIDs.contains(hit.eventID), !seenSpans.contains(span) else {
                    decisions.append(["anchor_event_id": hit.eventID,
                        "disposition": excludingSourceIDs.contains(hit.eventID) ? "excluded_primary" : "duplicate_primary"]); continue
                }
                guard let anchor = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1, {
                    try store.sourceReference(eventID: hit.eventID, projectID: projectID)
                }), anchor.sequence <= sourceFrontier, episodeIdentifierEqual(anchor.conversationID, hit.conversationID),
                      anchor.role == hit.role, anchor.status == hit.status, episodeIdentifierEqual(anchor.createdAt, hit.createdAt),
                      episodeIdentifierEqual(anchor.digest, hit.digest), anchor.byteCount == hit.totalBytes else {
                    throw MeteredRetrievalError.sourceMismatch
                }
                hits.append(hit); seenSpans.insert(span); retained += 1
                guard anchor.role == .human else { continue }
                guard expandedAnchors.insert(key).inserted else {
                    decisions.append(["anchor_event_id": hit.eventID, "disposition": "duplicate_anchor"]); continue
                }
                guard hits.count < maximumCandidates else {
                    decisions.append(["anchor_event_id": hit.eventID, "disposition": "candidate_limit"]); continue
                }
                let neighbor = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 2) {
                    try store.followingSourceReference(anchor: anchor, throughSequence: sourceFrontier)
                }
                var decision: [String: Any] = ["anchor_event_id": hit.eventID]
                guard let neighbor else {
                    decision["disposition"] = "no_neighbor"; decisions.append(decision); continue
                }
                decision["neighbor_event_id"] = neighbor.eventID
                guard neighbor.role == .assistant else {
                    decision["disposition"] = "human_boundary"; decisions.append(decision); continue
                }
                guard !excludingSourceIDs.contains(neighbor.eventID) else {
                    decision["disposition"] = "excluded_neighbor"; decisions.append(decision); continue
                }
                guard neighbor.byteCount > 0 else {
                    decision["disposition"] = "empty_neighbor"; decisions.append(decision); continue
                }
                let prefixBytes = min(neighbor.byteCount, MemoryStore.maximumPageBytes)
                func coversPrefix(_ candidate: MemoryHit) -> Bool {
                    candidate.excerptOffset == 0 && candidate.excerpt.utf8.count >= prefixBytes
                        && candidate.excerpt.utf8.count <= MemoryStore.maximumPageBytes
                        && matches(candidate, source: neighbor)
                }
                if hits.contains(where: coversPrefix) {
                    decision["disposition"] = "covered_neighbor_prefix"; decisions.append(decision); continue
                }
                // A complete future primary prefix is retained now, so later
                // candidate limits cannot turn source-ID dedup into lost bytes.
                if let primary = primaryHits.first(where: coversPrefix) {
                    let promotedSpan = PrimarySpan(eventID: Data(primary.eventID.utf8), offset: primary.excerptOffset,
                        bytes: Data(primary.excerpt.utf8))
                    hits.append(primary); seenSpans.insert(promotedSpan); promotedSpans.insert(promotedSpan)
                    retained += 1; promoted += 1
                    decision["disposition"] = "promoted_primary"; decision["excerpt_bytes"] = primary.excerpt.utf8.count
                    decision["prefix_truncated"] = primary.excerpt.utf8.count < neighbor.byteCount
                    if primary.excerpt.utf8.count < neighbor.byteCount { truncated += 1 }
                    decisions.append(decision); continue
                }
                let page = try MeteredRetrieval.read(store: store, source: neighbor, offset: 0,
                    length: prefixBytes, lease: episodeLease, nested: true, examinedPasses: 2)
                guard page.byteCount > 0, page.byteCount == page.text.utf8.count,
                      episodeIdentifierEqual(page.eventID, neighbor.eventID), episodeIdentifierEqual(page.digest, neighbor.digest),
                      page.totalBytes == neighbor.byteCount else { throw MeteredRetrievalError.sourceMismatch }
                let prefix = MemoryHit(eventID: neighbor.eventID, conversationID: neighbor.conversationID, projectID: neighbor.projectID,
                    role: neighbor.role, status: neighbor.status, createdAt: neighbor.createdAt, digest: neighbor.digest,
                    totalBytes: neighbor.byteCount, excerptOffset: 0, excerpt: page.text, sourceTime: neighbor.sourceTime)
                hits.append(prefix)
                seenSpans.insert(PrimarySpan(eventID: Data(prefix.eventID.utf8), offset: 0, bytes: Data(prefix.excerpt.utf8)))
                added += 1
                if page.byteCount < neighbor.byteCount { truncated += 1 }
                decision["disposition"] = "included_prefix"; decision["excerpt_bytes"] = page.byteCount
                decision["prefix_truncated"] = page.byteCount < neighbor.byteCount; decisions.append(decision)
            }
            return ExchangeExpansionReport(hits: hits, audit: ["version": version, "source_frontier": sourceFrontier,
                "primary_count": primaryHits.count, "retained_primary_count": retained,
                "dropped_primary_count": primaryHits.count - retained, "added_neighbor_count": added,
                "promoted_primary_count": promoted,
                "prefix_truncated_count": truncated, "decisions": decisions])
        }
    }
    private static func matches(_ hit: MemoryHit, source: MemorySourceReference) -> Bool {
        episodeIdentifierEqual(hit.eventID, source.eventID) && episodeIdentifierEqual(hit.projectID, source.projectID)
            && episodeIdentifierEqual(hit.conversationID, source.conversationID) && hit.role == source.role && hit.status == source.status
            && episodeIdentifierEqual(hit.createdAt, source.createdAt) && episodeIdentifierEqual(hit.digest, source.digest)
            && hit.totalBytes == source.byteCount
    }
}
