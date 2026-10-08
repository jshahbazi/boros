import Foundation

/// Exact-span provenance is host metadata, independently bound in the source
/// snapshot. A source may have a protected tail and an optional prefix.
struct ContextEvidenceProvenance: Codable {
    static let version = "bounded-neighborhood-provenance-v1"
    let eventID: String
    let offset: Int
    let byteLength: Int
    let excerptSHA256: String
    let candidateRank: Int
    let origin: String
    let primaryRank: Int
    let anchorEventID: String?
    let direction: String?

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id", offset, byteLength = "byte_length", excerptSHA256 = "excerpt_sha256"
        case candidateRank = "candidate_rank", origin, primaryRank = "primary_rank"
        case anchorEventID = "anchor_event_id", direction
    }
    func validated() throws -> Self {
        guard !eventID.isEmpty, eventID.utf8.count <= 256, !eventID.utf8.contains(0),
              offset >= 0, byteLength > 0, byteLength <= MemoryStore.maximumPageBytes,
              excerptSHA256.utf8.count == 64, excerptSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (0..<BoundedNeighborhoodExpansion.maximumCandidates).contains(candidateRank),
              (0..<BoundedNeighborhoodExpansion.maximumPrimaryCandidates).contains(primaryRank),
              origin == "primary" || origin == "neighbor" else { throw ContextError.sourceMismatch }
        if origin == "primary" {
            guard anchorEventID == nil, direction == nil else { throw ContextError.sourceMismatch }
        } else {
            guard let anchorEventID, !anchorEventID.isEmpty, anchorEventID.utf8.count <= 256, !anchorEventID.utf8.contains(0),
                  direction == "previous" || direction == "next" else { throw ContextError.sourceMismatch }
        }
        return self
    }
    func matches(_ hit: MemoryHit) -> Bool {
        episodeIdentifierEqual(eventID, hit.eventID) && offset == hit.excerptOffset && byteLength == hit.excerpt.utf8.count
            && excerptSHA256 == ContextSnapshot.digest(Data(hit.excerpt.utf8))
    }
    func object(finalRank: Int? = nil) throws -> [String: Any] {
        _ = try validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var value = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any] else {
            throw ContextError.sourceMismatch
        }
        if let finalRank { value["final_rank"] = finalRank }
        return value
    }
}

/// Preserve the ranked retrieval frontier before adding immediate exchange
/// neighbors. Payload reads remain bounded pages charged to the same episode.
enum BoundedNeighborhoodExpansion {
    static let version = "bounded-bidirectional-neighborhood-v1"
    static let maximumPrimaryCandidates = 16
    static let maximumCandidates = 48

    static func provenance(for report: ExchangeExpansionReport) throws -> [ContextEvidenceProvenance] {
        guard report.audit["version"] as? String == version,
              let decisions = report.audit["decisions"] as? [[String: Any]], report.hits.count <= maximumCandidates else {
            throw ContextError.sourceMismatch
        }
        return try report.hits.enumerated().map { rank, hit in
            guard let decision = decisions.first(where: {
                $0["final_rank"] as? Int == rank && ["retained_primary", "included_prefix"].contains($0["disposition"] as? String ?? "")
            }), let origin = decision["origin"] as? String, let primaryRank = decision["primary_rank"] as? Int else {
                throw ContextError.sourceMismatch
            }
            return try ContextEvidenceProvenance(eventID: hit.eventID, offset: hit.excerptOffset,
                byteLength: hit.excerpt.utf8.count, excerptSHA256: ContextSnapshot.digest(Data(hit.excerpt.utf8)),
                candidateRank: rank, origin: origin, primaryRank: primaryRank,
                anchorEventID: origin == "neighbor" ? decision["anchor_event_id"] as? String : nil,
                direction: origin == "neighbor" ? decision["direction"] as? String : nil).validated()
        }
    }

    private struct Span: Hashable {
        let eventID: Data
        let offset: Int
        let bytes: Data
    }
    private struct Anchor {
        let source: MemorySourceReference
        let primaryRank: Int
    }

    static func expand(store: MemoryStore, projectID: String, primaryHits: [MemoryHit], sourceFrontier: Int,
        excludingSourceIDs: ExactSourceIDs, episodeLease: EpisodeLease? = nil,
        operationIsNested: Bool = false) throws -> ExchangeExpansionReport {
        _ = try episodeLease?.checkActive(projectID: projectID)
        guard sourceFrontier >= 0, primaryHits.count <= maximumPrimaryCandidates,
              excludingSourceIDs.count <= 10000,
              primaryHits.allSatisfy({ episodeIdentifierEqual($0.projectID, projectID)
                  && $0.excerptOffset >= 0 && $0.totalBytes > 0
                  && $0.totalBytes <= MemoryStore.maximumPayloadBytes
                  && $0.excerptOffset <= $0.totalBytes && !$0.excerpt.isEmpty
                  && $0.excerpt.utf8.count <= MemoryStore.maximumPageBytes
                  && $0.excerpt.utf8.count <= $0.totalBytes - $0.excerptOffset }) else {
            throw MeteredRetrievalError.invalid
        }
        return try MeteredRetrieval.operation(lease: episodeLease, nested: operationIsNested) {
            var hits: [MemoryHit] = [], spans: Set<Span> = [], anchors: [Anchor] = []
            var sources: [Data: MemorySourceReference] = [:], inputs: [Data: MemoryHit] = [:]
            var fundedPrefixes: [Data: (source: MemorySourceReference, rank: Int)] = [:]
            var decisions: [[String: Any]] = []
            var duplicatePrimaries = 0, excludedPrimaries = 0, added = 0, truncated = 0

            // Validate every incoming primary, including repeated spans. A
            // repeated source ID cannot conceal changed status/date/digest.
            // All retained primaries precede every newly read neighbor.
            for (rank, hit) in primaryHits.enumerated() {
                let key = Data(hit.eventID.utf8)
                if let earlier = inputs[key], try !sameMetadata(earlier, hit) {
                    throw MeteredRetrievalError.sourceMismatch
                }
                inputs[key] = hit
                guard let source = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 1, {
                    try store.sourceReference(eventID: hit.eventID, projectID: projectID)
                }), source.sequence > 0, source.sequence <= sourceFrontier, try matches(hit, source) else {
                    throw MeteredRetrievalError.sourceMismatch
                }
                if let earlier = sources[key], earlier != source { throw MeteredRetrievalError.sourceMismatch }
                var decision: [String: Any] = ["event_id": hit.eventID, "primary_rank": rank,
                    "origin": "primary", "metadata_funded": episodeLease != nil,
                    "metadata_rows_reserved": episodeLease == nil ? 0 : 1,
                    "payload_funded": false, "raw_source_bytes_reserved": 0]
                if excludingSourceIDs.contains(hit.eventID) {
                    excludedPrimaries += 1
                    decision["disposition"] = "excluded_primary"
                    decisions.append(decision); continue
                }
                if sources[key] == nil { anchors.append(Anchor(source: source, primaryRank: rank)) }
                sources[key] = source
                let span = Span(eventID: key, offset: hit.excerptOffset, bytes: Data(hit.excerpt.utf8))
                guard spans.insert(span).inserted else {
                    duplicatePrimaries += 1
                    decision["disposition"] = "duplicate_primary_span"
                    decision["final_rank"] = hits.firstIndex { spanOf($0) == span }
                    decisions.append(decision); continue
                }
                decision["disposition"] = "retained_primary"
                decision["final_rank"] = hits.count
                decision["offset"] = hit.excerptOffset
                decision["excerpt_bytes"] = hit.excerpt.utf8.count
                hits.append(hit); decisions.append(decision)
            }
            let retained = hits.count

            // Only original, validated primaries enter this loop. A neighbor
            // that is also a future primary retains its own neighborhood;
            // neighbor-only sources never recursively widen the frontier.
            for anchor in anchors {
                for preceding in [true, false] {
                    var decision: [String: Any] = ["anchor_event_id": anchor.source.eventID,
                        "primary_rank": anchor.primaryRank, "origin": "neighbor",
                        "direction": preceding ? "previous" : "next"]
                    guard hits.count < maximumCandidates else {
                        decision["disposition"] = "candidate_limit"
                        decision["metadata_funded"] = false
                        decision["payload_funded"] = false
                        decisions.append(decision); continue
                    }
                    let neighbor = try MeteredRetrieval.sourceMetadata(store: store, lease: episodeLease, maximumRows: 2) {
                        try preceding ? store.precedingSourceReference(anchor: anchor.source, throughSequence: sourceFrontier)
                            : store.followingSourceReference(anchor: anchor.source, throughSequence: sourceFrontier)
                    }
                    decision["metadata_funded"] = episodeLease != nil
                    decision["metadata_rows_reserved"] = episodeLease == nil ? 0 : 2
                    decision["payload_funded"] = false
                    decision["raw_source_bytes_reserved"] = 0
                    guard let neighbor else {
                        decision["disposition"] = "no_neighbor"; decisions.append(decision); continue
                    }
                    guard neighbor.sequence > 0, neighbor.sequence <= sourceFrontier,
                          preceding ? neighbor.sequence < anchor.source.sequence : neighbor.sequence > anchor.source.sequence,
                          episodeIdentifierEqual(neighbor.projectID, projectID),
                          episodeIdentifierEqual(neighbor.conversationID, anchor.source.conversationID),
                          neighbor.byteCount >= 0, neighbor.byteCount <= MemoryStore.maximumPayloadBytes else {
                        throw MeteredRetrievalError.sourceMismatch
                    }
                    decision["neighbor_event_id"] = neighbor.eventID
                    guard neighbor.role != anchor.source.role else {
                        decision["disposition"] = "same_role_boundary"; decisions.append(decision); continue
                    }
                    guard !excludingSourceIDs.contains(neighbor.eventID) else {
                        decision["disposition"] = "excluded_neighbor"; decisions.append(decision); continue
                    }
                    guard neighbor.byteCount > 0 else {
                        decision["disposition"] = "empty_neighbor"; decisions.append(decision); continue
                    }
                    let prefixBytes = min(neighbor.byteCount, MemoryStore.maximumPageBytes)
                    if let funded = fundedPrefixes[Data(neighbor.eventID.utf8)] {
                        guard funded.source == neighbor else { throw MeteredRetrievalError.sourceMismatch }
                        decision["disposition"] = "covered_funded_neighbor_prefix"
                        decision["final_rank"] = funded.rank
                        decisions.append(decision); continue
                    }
                    // A scalar-safe 4096-byte page can be shorter by up to
                    // three bytes. A full short primary covers its prefix;
                    // an oversized partial primary is conservatively reread.
                    var coveredRank: Int?
                    for (rank, candidate) in hits.enumerated() where episodeIdentifierEqual(candidate.eventID, neighbor.eventID) {
                        guard try matches(candidate, neighbor) else { throw MeteredRetrievalError.sourceMismatch }
                        if candidate.excerptOffset == 0 && candidate.excerpt.utf8.count >= prefixBytes {
                            coveredRank = rank; break
                        }
                    }
                    if let coveredRank {
                        decision["disposition"] = "covered_neighbor_prefix"
                        decision["final_rank"] = coveredRank
                        decisions.append(decision); continue
                    }
                    let page = try MeteredRetrieval.read(store: store, source: neighbor, offset: 0,
                        length: prefixBytes, lease: episodeLease, nested: true, examinedPasses: 2)
                    guard page.offset == 0, page.byteCount > 0, page.byteCount <= prefixBytes,
                          page.byteCount == page.text.utf8.count,
                          episodeIdentifierEqual(page.eventID, neighbor.eventID),
                          episodeIdentifierEqual(page.digest, neighbor.digest), page.totalBytes == neighbor.byteCount,
                          page.status == neighbor.status else { throw MeteredRetrievalError.sourceMismatch }
                    let prefix = MemoryHit(eventID: neighbor.eventID, conversationID: neighbor.conversationID,
                        projectID: neighbor.projectID, role: neighbor.role, status: neighbor.status,
                        createdAt: neighbor.createdAt, digest: neighbor.digest, totalBytes: neighbor.byteCount,
                        excerptOffset: 0, excerpt: page.text, sourceTime: neighbor.sourceTime)
                    let span = spanOf(prefix)
                    decision["payload_funded"] = episodeLease != nil
                    decision["metadata_rows_reserved"] = episodeLease == nil ? 0 : 3
                    decision["raw_source_bytes_reserved"] = episodeLease == nil ? 0 : 2 * (prefixBytes + 1)
                    decision["excerpt_bytes"] = page.byteCount
                    decision["offset"] = 0
                    decision["prefix_truncated"] = page.byteCount < neighbor.byteCount
                    if let existing = hits.firstIndex(where: { spanOf($0) == span }) {
                        decision["disposition"] = "duplicate_neighbor_span"
                        decision["final_rank"] = existing
                        fundedPrefixes[Data(neighbor.eventID.utf8)] = (neighbor, existing)
                    } else {
                        spans.insert(span)
                        decision["disposition"] = "included_prefix"
                        decision["final_rank"] = hits.count
                        fundedPrefixes[Data(neighbor.eventID.utf8)] = (neighbor, hits.count)
                        hits.append(prefix); added += 1
                        if page.byteCount < neighbor.byteCount { truncated += 1 }
                    }
                    decisions.append(decision)
                }
            }
            return ExchangeExpansionReport(hits: hits, audit: ["version": version, "source_frontier": sourceFrontier,
                "maximum_primary_candidates": maximumPrimaryCandidates, "maximum_candidates": maximumCandidates,
                "primary_count": primaryHits.count, "retained_primary_count": retained,
                "dropped_primary_count": excludedPrimaries + duplicatePrimaries,
                "excluded_primary_count": excludedPrimaries, "duplicate_primary_span_count": duplicatePrimaries,
                "added_neighbor_count": added, "promoted_primary_count": 0,
                "prefix_truncated_count": truncated, "decisions": decisions])
        }
    }

    private static func spanOf(_ hit: MemoryHit) -> Span {
        Span(eventID: Data(hit.eventID.utf8), offset: hit.excerptOffset, bytes: Data(hit.excerpt.utf8))
    }
    private static func sameMetadata(_ lhs: MemoryHit, _ rhs: MemoryHit) throws -> Bool {
        let lhsTime = try lhs.sourceTime?.canonicalData(), rhsTime = try rhs.sourceTime?.canonicalData()
        return episodeIdentifierEqual(lhs.eventID, rhs.eventID) && episodeIdentifierEqual(lhs.projectID, rhs.projectID)
            && episodeIdentifierEqual(lhs.conversationID, rhs.conversationID) && lhs.role == rhs.role && lhs.status == rhs.status
            && episodeIdentifierEqual(lhs.createdAt, rhs.createdAt) && episodeIdentifierEqual(lhs.digest, rhs.digest)
            && lhs.totalBytes == rhs.totalBytes && lhsTime == rhsTime
    }
    private static func matches(_ hit: MemoryHit, _ source: MemorySourceReference) throws -> Bool {
        let hitTime = try hit.sourceTime?.canonicalData(), sourceTime = try source.sourceTime?.canonicalData()
        return episodeIdentifierEqual(hit.eventID, source.eventID) && episodeIdentifierEqual(hit.projectID, source.projectID)
            && episodeIdentifierEqual(hit.conversationID, source.conversationID) && hit.role == source.role && hit.status == source.status
            && episodeIdentifierEqual(hit.createdAt, source.createdAt) && episodeIdentifierEqual(hit.digest, source.digest)
            && hit.totalBytes == source.byteCount && hitTime == sourceTime
    }
}
