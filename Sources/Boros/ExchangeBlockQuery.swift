import Foundation

/// Experimental P2 ordinary-path selection (explicit policies only).
///
/// Step 1 ranks complete human-led exchange blocks against every content term
/// of the question with inverse-document-frequency weights, ported from the
/// investigation engine's block search. Quoted anchors are mandatory: blocks
/// that contain every term of more quoted anchors rank first. The index is
/// rebuilt in memory for each turn from one fixed source frontier; nothing is
/// persisted. Step 2 additionally packs each selected block's adjacent
/// opposite-role messages beside it when the estimated budget allows.
///
/// Delivered spans are exact store pages that the assembler re-reads and
/// verifies. Audits contain identifiers, counts and digests, never text.
enum ExchangeBlockQuery {
    static let version = "exchange-block-query-v1"
    static let scoringVersion = "idf-term-coverage-sqrt-byte-cost-v1"
    static let blockPackingVersion = "exchange-block-greedy-v1"
    static let adjacentPackingVersion = "exchange-adjacent-greedy-v1"
    static let maximumSources = 20_000
    static let maximumSourceBytes = 32 * 1_048_576
    static let maximumQueryTerms = 256
    static let maximumAnchors = 8
    /// Ranked blocks reported by identifier for offline diagnosis.
    static let auditedBlocks = 24
    /// Byte-to-token estimates for the selected tokenizer: host metadata
    /// (digests, identifiers) is dense; prose is lighter. Measured on the P1
    /// development cohort at a 0.9 budget fraction, actual evidence tokens
    /// were 0.87 to 1.02 of this estimate (median 0.93). The packer therefore
    /// fills the whole cap; the exact component count still decides, and an
    /// overflow removes one lowest-ranked span per counted round.
    static let headerBytesPerToken = 2.0
    static let contentBytesPerToken = 3.2
    static let evidenceTokenFraction = 1.0

    enum Failure: Error { case snapshotLimit, sourceMismatch }

    struct Query: Equatable {
        let terms: Set<String>
        let anchors: [Set<String>]
    }

    struct Source {
        let reference: MemorySourceReference
        let text: String
    }

    struct Block {
        /// Indices into `Index.sources`, chronological within one conversation.
        let sources: [Int]
        let bytes: Int
        let frequency: [String: Int]
    }

    struct RankedBlock {
        let block: Int
        let anchorMatches: Int
        let score: Double
    }

    /// Per-turn, in-memory exchange index over one fixed frontier.
    struct Index {
        let sources: [Source]
        let blocks: [Block]
        /// Same-conversation predecessor/successor source index, if any.
        let previous: [Int?]
        let next: [Int?]
        let documentFrequency: [String: Int]

        init(sources: [Source]) {
            self.sources = sources
            var order: [Data] = [], members: [Data: [Int]] = [:]
            for (index, source) in sources.enumerated() {
                let key = Data(source.reference.conversationID.utf8)
                if members[key] == nil { order.append(key) }
                members[key, default: []].append(index)
            }
            var blocks: [Block] = [], previous = [Int?](repeating: nil, count: sources.count)
            var next = [Int?](repeating: nil, count: sources.count), frequencyOfDocuments: [String: Int] = [:]
            for key in order {
                let indices = members[key]!
                for (position, index) in indices.enumerated() {
                    if position > 0 { previous[index] = indices[position - 1] }
                    if position + 1 < indices.count { next[index] = indices[position + 1] }
                }
                var pending: [Int] = []
                func complete() {
                    guard !pending.isEmpty else { return }
                    var frequency: [String: Int] = [:]
                    for index in pending { for term in ExchangeBlockQuery.terms(sources[index].text) { frequency[term, default: 0] += 1 } }
                    for term in frequency.keys { frequencyOfDocuments[term, default: 0] += 1 }
                    blocks.append(Block(sources: pending, bytes: pending.reduce(0) { $0 + sources[$1].reference.byteCount },
                        frequency: frequency))
                    pending.removeAll()
                }
                for index in indices {
                    if sources[index].reference.role == .human { complete() }
                    pending.append(index)
                }
                complete()
            }
            self.blocks = blocks; self.previous = previous; self.next = next
            documentFrequency = frequencyOfDocuments
        }

        func idf(_ term: String) -> Double {
            log(1 + (Double(blocks.count) + 0.5) / (Double(documentFrequency[term, default: 0]) + 0.5))
        }

        /// Blocks matching at least one query term, best first. Blocks that
        /// contain every term of more quoted anchors always rank first; ties
        /// prefer the later block, as the investigation search does.
        func rank(_ query: Query) -> [RankedBlock] {
            var ranked: [RankedBlock] = []
            for (index, block) in blocks.enumerated() {
                let matches = query.terms.filter { block.frequency[$0, default: 0] > 0 }
                guard !matches.isEmpty else { continue }
                let relevance = matches.reduce(0.0) { $0 + idf($1) * (1 + min(2, log(Double(block.frequency[$1]!)))) }
                let anchors = query.anchors.filter { anchor in anchor.allSatisfy { block.frequency[$0, default: 0] > 0 } }.count
                ranked.append(RankedBlock(block: index, anchorMatches: anchors,
                    score: relevance / sqrt(1 + Double(block.bytes) / 512)))
            }
            return ranked.sorted {
                if $0.anchorMatches != $1.anchorMatches { return $0.anchorMatches > $1.anchorMatches }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.block > $1.block
            }
        }
    }

    // MARK: Query

    /// Ported from the investigation engine's term function: case and
    /// diacritic folding, alphanumeric runs, its stopword list.
    static func terms(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.utf8.count <= 128 && !stopwords.contains($0) }
    }

    /// Every content term of the question, plus up to eight complete quoted
    /// spans ("...", curly double quotes, or backticks) as anchor term sets.
    static func query(_ text: String) -> Query {
        var anchors: [Set<String>] = [], span = "", close: Character?
        var escaped = false
        for character in text {
            if let active = close {
                if escaped { escaped = false; span.append(character); continue }
                if character == "\\" { escaped = true; span.append(character); continue }
                if character == active {
                    let anchor = Set(terms(span))
                    if !anchor.isEmpty, span.utf8.count <= 16_384, anchors.count < maximumAnchors { anchors.append(anchor) }
                    close = nil; span = ""
                } else { span.append(character) }
            } else if anchors.count < maximumAnchors {
                switch character {
                case "\"": close = "\""
                case "\u{201C}": close = "\u{201D}"
                case "`": close = "`"
                default: break
                }
            }
        }
        var all = Set<String>()
        for anchor in anchors { all.formUnion(anchor) }
        for term in terms(text) where all.count < maximumQueryTerms { all.insert(term) }
        return Query(terms: all, anchors: anchors)
    }

    // MARK: Loading

    /// One complete scoped snapshot through a fixed frontier, excluding the
    /// accepted request and recent sources. Payloads are prefunded as one
    /// declared source read and verified against stored digests.
    static func load(store: MemoryStore, projectID: String, excluding: ExactSourceIDs,
                     lease: EpisodeLease?) throws -> (frontier: Int, sources: [Source]) {
        let frontier = try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 1) {
            try store.sourceFrontier(projectID: projectID)
        }
        var references: [MemorySourceReference] = [], after = 0, bytes = 0
        while true {
            let page = try MeteredRetrieval.sourceMetadata(store: store, lease: lease, maximumRows: 1000) {
                try store.sourceManifest(projectID: projectID, afterSequence: after, throughSequence: frontier,
                    limit: 1000, excludingSourceIDs: excluding)
            }
            for reference in page {
                guard episodeIdentifierEqual(reference.projectID, projectID), reference.sequence > after,
                      reference.sequence <= frontier, !excluding.contains(reference.eventID),
                      reference.byteCount >= 0, reference.byteCount <= MemoryStore.maximumPayloadBytes else {
                    throw Failure.sourceMismatch
                }
                after = reference.sequence
                guard references.count < maximumSources, reference.byteCount <= maximumSourceBytes - bytes else {
                    throw Failure.snapshotLimit
                }
                references.append(reference); bytes += reference.byteCount
            }
            if page.count < 1000 { break }
        }
        // Two declared passes: the integrity load and the in-memory term scan.
        let raw = try MeteredRetrieval.checkedProduct(bytes, 2) + references.count
        let sources: [Source] = try MeteredRetrieval.charge(lease: lease, kind: .sourceRead,
            resources: EpisodeResources(rawSourceBytes: raw, metadataRows: references.count)) {
            try MeteredRetrieval.authoritative(store: store, lease: lease) {
                try references.map { reference in
                    let event = try store.loadCandidate(reference: reference)
                    guard episodeIdentifierEqual(event.id, reference.eventID), event.byteCount == reference.byteCount,
                          event.text.utf8.count == reference.byteCount,
                          MeteredRetrieval.digest(Data(event.text.utf8)) == reference.digest else { throw Failure.sourceMismatch }
                    return Source(reference: reference, text: event.text)
                }
            }
        }
        return (frontier, sources)
    }

    // MARK: Packing

    /// Exact store-page boundaries: at most 4,096 bytes, ending on a scalar.
    static func pages(_ source: Source) -> [MemoryHit] {
        let bytes = Array(source.text.utf8), reference = source.reference
        var hits: [MemoryHit] = [], offset = 0
        while offset < bytes.count {
            var end = min(bytes.count, offset + MemoryStore.maximumPageBytes)
            while end < bytes.count && end > offset && bytes[end] & 0xC0 == 0x80 { end -= 1 }
            hits.append(MemoryHit(eventID: reference.eventID, conversationID: reference.conversationID,
                projectID: reference.projectID, role: reference.role, status: reference.status,
                createdAt: reference.createdAt, digest: reference.digest, totalBytes: reference.byteCount,
                excerptOffset: offset, excerpt: String(decoding: bytes[offset..<end], as: UTF8.self),
                sourceTime: reference.sourceTime))
            offset = end
        }
        return hits
    }

    static func estimatedTokens(_ hit: MemoryHit, selectionVersion: String) throws -> Int {
        // V4 estimates deliberately use the V3 header bytes: the framing
        // version must not reorder this experimental packing. Exact provider
        // counts of the delivered V4 bytes still govern admission.
        let estimateVersion = ContextSourceFraming.quotesSources(selectionVersion)
            ? ContextSourceFraming.currentSelectionVersion : selectionVersion
        let header = try ContextSourceFraming.evidenceHeader(eventID: hit.eventID, conversationID: hit.conversationID,
            role: hit.role.rawValue, status: hit.status.rawValue, createdAt: hit.createdAt, digest: hit.digest,
            offset: hit.excerptOffset, totalBytes: hit.totalBytes, selectionVersion: estimateVersion, sourceTime: hit.sourceTime)
        let framing = header.utf8.count + ContextSourceFraming.evidenceFooter.utf8.count + ContextSourceFraming.evidenceSeparator.utf8.count
        return Int((Double(framing) / headerBytesPerToken + Double(hit.excerpt.utf8.count) / contentBytesPerToken).rounded(.up))
    }

    struct Packing {
        let hits: [MemoryHit]
        let audit: [String: Any]
    }

    /// Greedy by rank. A block is atomic: all of its sources, whole, or none.
    /// With `adjacent`, each included block is followed by its neighbors in
    /// chronological order beside it: the opposite-role message before its
    /// first source and after its last, each added only if it still fits.
    static func pack(index: Index, ranked: [RankedBlock], maximumSpans: Int, tokenBudget: Int,
                     adjacent: Bool, selectionVersion: String) throws -> Packing {
        var included = Set<Int>(), hits: [MemoryHit] = [], tokens = 0
        var selectedBlocks = 0, skippedBlocks = 0, neighbors = 0, skippedNeighbors = 0
        var costs: [Int: (spans: [MemoryHit], tokens: Int)] = [:]
        func cost(_ source: Int) throws -> (spans: [MemoryHit], tokens: Int) {
            if let known = costs[source] { return known }
            let spans = pages(index.sources[source])
            let value = (spans, try spans.reduce(0) { $0 + (try estimatedTokens($1, selectionVersion: selectionVersion)) })
            costs[source] = value
            return value
        }
        func fits(_ sources: [Int]) throws -> Bool {
            var spans = 0, estimate = 0
            for source in sources where !included.contains(source) {
                let value = try cost(source); spans += value.spans.count; estimate += value.tokens
            }
            return hits.count + spans <= maximumSpans && tokens + estimate <= tokenBudget
        }
        func add(_ sources: [Int]) throws {
            for source in sources where !included.contains(source) {
                let value = try cost(source)
                included.insert(source); hits += value.spans; tokens += value.tokens
            }
        }
        var auditedRanks: [[String: Any]] = []
        for (rank, entry) in ranked.enumerated() {
            // Past the audited ranks, stop once no further span could fit.
            if rank >= auditedBlocks && (hits.count >= maximumSpans || tokenBudget - tokens < 128) { break }
            let block = index.blocks[entry.block]
            let members = block.sources.filter { !included.contains($0) && index.sources[$0].reference.byteCount > 0 }
            var disposition = "included"
            if members.isEmpty { disposition = "already_delivered" }
            else if try fits(members) {
                // Neighbors are placed beside the block in chronological order.
                var before: Int?, after: Int?
                if adjacent, let first = block.sources.first, let last = block.sources.last {
                    if let candidate = index.previous[first], index.sources[candidate].reference.role != index.sources[first].reference.role,
                       index.sources[candidate].reference.byteCount > 0, !included.contains(candidate) { before = candidate }
                    if let candidate = index.next[last], index.sources[candidate].reference.role != index.sources[last].reference.role,
                       index.sources[candidate].reference.byteCount > 0, !included.contains(candidate) { after = candidate }
                }
                if let candidate = before {
                    if try fits(members + [candidate]) { try add([candidate]); neighbors += 1 } else { skippedNeighbors += 1 }
                }
                try add(members); selectedBlocks += 1
                if let candidate = after {
                    if try fits([candidate]) { try add([candidate]); neighbors += 1 } else { skippedNeighbors += 1 }
                }
            } else { disposition = "estimated_budget"; skippedBlocks += 1 }
            if rank < auditedBlocks {
                auditedRanks.append(["rank": rank, "event_ids": block.sources.map { index.sources[$0].reference.eventID },
                    "anchor_matches": entry.anchorMatches, "disposition": disposition])
            }
        }
        return Packing(hits: hits, audit: ["packing_version": adjacent ? adjacentPackingVersion : blockPackingVersion,
            "selected_block_count": selectedBlocks, "budget_skipped_block_count": skippedBlocks,
            "neighbor_count": neighbors, "budget_skipped_neighbor_count": skippedNeighbors,
            "span_count": hits.count, "maximum_spans": maximumSpans,
            "estimated_evidence_tokens": tokens, "estimated_token_budget": tokenBudget, "ranked_blocks": auditedRanks])
    }

    // MARK: Ordinary-path entry

    /// Evidence entry for explicit exchange policies, called by component
    /// preparation in place of ChatContextPreparation.prepareEvidence (which
    /// refuses these policies). Same preconditions, one metered operation,
    /// the same recent snapshot, exclusions, lease and assembler checks as v1.
    /// It never reads a semantic index.
    static func prepareEvidence(recent: ContextSnapshot, store: MemoryStore, conversationID: String,
        projectID: String, prompt: String, excludingEventID: String, episodeLease: EpisodeLease?,
        lexicalQueryUTF8Range: Range<Int>?, componentPolicy: ContextComponentPolicy) throws -> ContextSnapshot {
        let active = try episodeLease?.checkActive(projectID: projectID)
        guard try componentPolicy.validated().usesExchangeQuery else { throw ContextError.sourceMismatch }
        if let frozen = active?.limits.componentPolicy, frozen != componentPolicy { throw EpisodeBudgetError.invalid }
        return try MeteredRetrieval.operation(lease: episodeLease) {
            _ = try recent.componentAssignments()
            guard let binding = recent.selectionBinding,
                  episodeIdentifierEqual(binding.projectID, projectID), episodeIdentifierEqual(binding.conversationID, conversationID),
                  episodeIdentifierEqual(binding.acceptedHumanEventID, excludingEventID),
                  episodeIdentifierEqual(recent.messages.last?.content, prompt), recent.evidence.isEmpty,
                  recent.selectionAudit?.version == componentPolicy.selectionAuditVersion else { throw ContextError.sourceMismatch }
            return try select(recent: recent, binding: binding, store: store, conversationID: conversationID, projectID: projectID,
                prompt: prompt, excludingEventID: excludingEventID, episodeLease: episodeLease,
                lexicalQueryUTF8Range: lexicalQueryUTF8Range, componentPolicy: componentPolicy)
        }
    }

    private static func select(recent: ContextSnapshot, binding: ContextSelectionBinding, store: MemoryStore,
        conversationID: String, projectID: String, prompt: String, excludingEventID: String, episodeLease: EpisodeLease?,
        lexicalQueryUTF8Range: Range<Int>?, componentPolicy: ContextComponentPolicy) throws -> ContextSnapshot {
        let input = try HistoricalQueryFormulation.input(prompt, utf8Range: lexicalQueryUTF8Range)
        let query = Self.query(input)
        let excluded = ExactSourceIDs(recent.recentSourceIDs + [excludingEventID])
        var audit: [String: Any] = ["version": version, "scoring_version": scoringVersion,
            "query_term_count": query.terms.count, "quoted_anchor_count": query.anchors.count,
            "query_terms_sha256": MeteredRetrieval.digest(Data(query.terms.sorted().joined(separator: "\n").utf8)),
            "index": "in_memory_per_turn"]
        var hits: [MemoryHit] = []
        if !query.terms.isEmpty {
            let loaded = try load(store: store, projectID: projectID, excluding: excluded, lease: episodeLease)
            let index = Index(sources: loaded.sources)
            let ranked = index.rank(query)
            let budget = Int(Double(componentPolicy.evidenceTokens) * evidenceTokenFraction)
            if componentPolicy.packsExchangeValueDensity {
                // P2 step 3: declared candidate window, value-density packing.
                audit["source_frontier"] = loaded.frontier
                audit["indexed_source_count"] = loaded.sources.count
                audit["block_count"] = index.blocks.count
                audit["matched_block_count"] = ranked.count
                audit["anchor_matched_block_count"] = ranked.filter { $0.anchorMatches > 0 }.count
                return try ValuePacking.select(recent: recent, binding: binding, store: store, conversationID: conversationID,
                    projectID: projectID, excludingEventID: excludingEventID, episodeLease: episodeLease,
                    componentPolicy: componentPolicy, index: index, ranked: ranked, tokenBudget: budget, baseAudit: audit)
            }
            let packing = try pack(index: index, ranked: ranked, maximumSpans: componentPolicy.evidenceSpans,
                tokenBudget: budget, adjacent: componentPolicy.packsAdjacentExchanges, selectionVersion: binding.version)
            hits = packing.hits
            audit.merge(packing.audit) { _, new in new }
            audit["source_frontier"] = loaded.frontier
            audit["indexed_source_count"] = loaded.sources.count
            audit["block_count"] = index.blocks.count
            audit["matched_block_count"] = ranked.count
            audit["anchor_matched_block_count"] = ranked.filter { $0.anchorMatches > 0 }.count
        } else {
            audit["skipped"] = "no_query_terms"
        }
        var result = try ContextAssembler.addEvidence(to: recent, store: store, conversationID: conversationID,
            projectID: projectID, excludingEventID: excludingEventID, historicalHits: hits,
            maximumEvidenceSpans: componentPolicy.evidenceSpans, episodeLease: episodeLease, operationIsNested: true,
            componentPolicy: componentPolicy, historicalProvenance: nil)
        var retrieval = try result.retrievalAuditJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        retrieval["mode"] = componentPolicy.packsExchangeValueDensity ? "exchange_packed"
            : componentPolicy.packsAdjacentExchanges ? "exchange_adjacent" : "exchange_lexical"
        retrieval["semantic_available"] = false
        retrieval["exchange_query"] = audit
        result.retrievalAuditJSON = try JSONSerialization.data(withJSONObject: retrieval, options: [.sortedKeys])
        result.retrievalManifestID = nil; result.retrievalManifestJSON = nil
        result.retrievalNotice = "Archive recall ranked complete exchanges lexically over the whole question; semantic recall was not used."
        return result
    }

    private static let stopwords = Set("a an and are as at be been being but by can could did do does doing for from had has have having he her here hers him his how i if in into is it its just me more most my no not of on or our ours please s say she should so some t tell than that the their theirs them then there these they this those through to too us was we were what when where which who why will with would you your yours about".split(separator: " ").map(String.init))
}
