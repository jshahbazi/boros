import Foundation

/// P2 step 3 packer for the explicit `selectedQwenExchangePacked` policy.
///
/// It takes the step 1 ranking and step 2 neighbors, declares a candidate
/// window of ranked blocks before packing, splits each candidate block into
/// source units (lead, replies, opposite-role neighbors), protects every
/// member of a quoted-anchor block, and packs the remaining units by declared
/// relevance per estimated cost. The cost has two resources: estimated
/// evidence tokens against the 12,000-token cap, and delivery-audit bytes
/// against what the 32 KiB delivery audit leaves for historical sources.
/// Every candidate unit receives an explicit disposition code in the audit.
///
/// All parameters below were declared and committed before any measurement
/// of this packer on the development cohort.
extension ExchangeBlockQuery {
    enum ValuePacking {
        static let version = "exchange-value-density-v1"
        /// R1 depth: ranked blocks whose units are packing candidates, for
        /// `exchange_packed`. The wide variant declares its own depth on the
        /// policy (`ContextComponentPolicy.candidateBlockDepth`).
        static let candidateBlockDepth = 32
        /// Relevance of a unit is its block's score times this weight.
        static let memberWeight = 1.0
        static let neighborWeight = 0.5
        /// Lead-priority policies: the fraction of the token budget that
        /// candidate leads may fill before the density pass (declared before
        /// measurement, docs/EVIDENCE-ALLOWANCE.md).
        static let leadShare = 0.5
        /// Hard limit of `ContextSnapshot.deliveryAudit()` for `exchange_packed`.
        /// The wide variant declares its own on the policy
        /// (`ContextComponentPolicy.deliveryAuditBytes`).
        static let deliveryAuditLimitBytes = 32_768
        /// Reserved for what admission adds after selection: the component
        /// count proof, the selection work ID and reduction receipts.
        static let admissionHeadroomBytes = 5_120
        /// Reserved for numeric fields that change after the size probe.
        static let probeSlackBytes = 256
        /// Candidate identifiers are SHA-256 of the event ID, truncated.
        static let candidateIDHexDigits = 12
        static let costModel = "estimated_tokens/token_budget+audit_bytes/audit_budget"
        static let dispositionCodes: [String: String] = [
            "D": "delivered", "M": "mandatory_over_budget", "S": "span_limit", "T": "estimated_token_budget",
            "A": "delivery_audit_bytes", "L": "lead_not_delivered", "U": "source_delivered_by_other_unit",
            "Z": "empty_source", "?": "not_considered"]
        static let kindCodes: [String: String] = ["p": "previous_neighbor", "l": "lead", "r": "reply", "n": "next_neighbor"]

        static func candidateID(_ eventID: String) -> String {
            String(MeteredRetrieval.digest(Data(eventID.utf8)).prefix(candidateIDHexDigits))
        }

        /// Byte length this span adds to the delivery audit's
        /// `historical_sources` array (a replica of the assembler's entry,
        /// plus one separator).
        static func auditEntryBytes(_ hit: MemoryHit, selectionVersion: String) throws -> Int {
            var source: [String: Any] = ["event_id": hit.eventID, "conversation_id": hit.conversationID, "project_id": hit.projectID,
                "role": hit.role.rawValue, "capture_status": hit.status.rawValue, "source_created_utc": hit.createdAt,
                "source_sha256": hit.digest, "source_bytes": hit.totalBytes, "excerpt_offset": hit.excerptOffset,
                "excerpt_bytes": hit.excerpt.utf8.count, "excerpt_sha256": MeteredRetrieval.digest(Data(hit.excerpt.utf8))]
            if ContextSourceFraming.carriesSourceTime(selectionVersion) {
                source.removeValue(forKey: "source_created_utc")
                source["captured_utc"] = hit.createdAt
                source["source_time"] = hit.sourceTime?.object as Any? ?? NSNull()
            }
            return try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys]).count + 1
        }

        struct Unit {
            let rank: Int
            let kind: String
            let source: Int
            let value: Double
            let mandatory: Bool
        }

        struct Plan {
            /// Delivered spans in delivery order: by owning block rank, then
            /// chronological within the block.
            let hits: [MemoryHit]
            /// Per delivered span, the candidate (rank, unit position).
            let owners: [(rank: Int, unit: Int)]
            /// Per candidate block in rank order: anchor matches and units.
            let blocks: [(anchors: Int, units: [Unit])]
            var codes: [[String]]
            let estimatedTokens: Int
            let estimatedAuditBytes: Int
        }

        /// Candidate units of the top ranked blocks, in chronological order
        /// within each block: previous neighbor, lead, replies, next neighbor.
        static func candidates(index: ExchangeCorpus, ranked: [RankedBlock],
                               depth: Int = candidateBlockDepth) throws -> [(anchors: Int, units: [Unit])] {
            try ranked.prefix(depth).enumerated().map { rank, entry in
                let sources = try index.members(entry.block), mandatory = entry.anchorMatches > 0
                var units: [Unit] = []
                if let first = sources.first, let candidate = try index.previous(first),
                   try index.role(candidate) != (try index.role(first)) {
                    units.append(Unit(rank: rank, kind: "p", source: candidate, value: entry.score * neighborWeight, mandatory: false))
                }
                for (position, source) in sources.enumerated() {
                    units.append(Unit(rank: rank, kind: position == 0 ? "l" : "r", source: source,
                        value: entry.score * memberWeight, mandatory: mandatory))
                }
                if let last = sources.last, let candidate = try index.next(last),
                   try index.role(candidate) != (try index.role(last)) {
                    units.append(Unit(rank: rank, kind: "n", source: candidate, value: entry.score * neighborWeight, mandatory: false))
                }
                return (entry.anchorMatches, units)
            }
        }

        /// Mandatory members first in rank order, then every other unit by
        /// value per normalized cost. A reply or neighbor needs its block's
        /// lead delivered; one that outranks its lead waits for that lead.
        static func plan(index: ExchangeCorpus, ranked: [RankedBlock], maximumSpans: Int, tokenBudget: Int,
                         auditBudget: Int, selectionVersion: String, depth: Int = candidateBlockDepth,
                         leadsFirst: Bool = false) throws -> Plan {
            let blocks = try candidates(index: index, ranked: ranked, depth: depth)
            var codes = blocks.map { Array(repeating: "?", count: $0.units.count) }
            var costs: [Int: (spans: [MemoryHit], tokens: Int, audit: Int)] = [:]
            func cost(_ source: Int) throws -> (spans: [MemoryHit], tokens: Int, audit: Int) {
                if let known = costs[source] { return known }
                let spans = try pages(index, source)
                var tokens = 0, audit = 0
                for span in spans {
                    tokens += try estimatedTokens(span, selectionVersion: selectionVersion)
                    audit += try auditEntryBytes(span, selectionVersion: selectionVersion)
                }
                costs[source] = (spans, tokens, audit); return (spans, tokens, audit)
            }
            var delivered: [Int: (rank: Int, unit: Int)] = [:], spanCount = 0, tokens = 0, auditBytes = 0
            func attempt(_ rank: Int, _ position: Int, mandatory: Bool) throws {
                let unit = blocks[rank].units[position]
                if delivered[unit.source] != nil { codes[rank][position] = "U"; return }
                if try index.byteCount(unit.source) == 0 { codes[rank][position] = "Z"; return }
                let value = try cost(unit.source)
                let reason = spanCount + value.spans.count > maximumSpans ? "S"
                    : tokens + value.tokens > tokenBudget ? "T" : auditBytes + value.audit > auditBudget ? "A" : nil
                if let reason { codes[rank][position] = mandatory ? "M" : reason; return }
                delivered[unit.source] = (rank, position); spanCount += value.spans.count
                tokens += value.tokens; auditBytes += value.audit; codes[rank][position] = "D"
            }
            func leadPosition(_ rank: Int) -> Int? { blocks[rank].units.firstIndex { $0.kind == "l" } }

            // Pass 1: every member of a quoted-anchor block, in rank order.
            for rank in blocks.indices where blocks[rank].anchors > 0 {
                for position in blocks[rank].units.indices where blocks[rank].units[position].mandatory {
                    try attempt(rank, position, mandatory: true)
                }
            }
            // Pass 2: value per normalized two-resource cost.
            var order: [(rank: Int, position: Int, density: Double)] = []
            for rank in blocks.indices {
                for (position, unit) in blocks[rank].units.enumerated() where codes[rank][position] == "?" {
                    let value = try cost(unit.source)
                    let normalized = Double(value.tokens) / Double(max(1, tokenBudget)) + Double(value.audit) / Double(max(1, auditBudget))
                    order.append((rank, position, unit.value / max(normalized, 1e-9)))
                }
            }
            let kindOrder = ["l": 0, "r": 1, "p": 2, "n": 3]
            order.sort {
                if $0.density != $1.density { return $0.density > $1.density }
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                let left = blocks[$0.rank].units[$0.position], right = blocks[$1.rank].units[$1.position]
                if left.kind != right.kind { return kindOrder[left.kind]! < kindOrder[right.kind]! }
                return left.source < right.source
            }
            var waiting: [Int: [Int]] = [:]
            func consider(_ rank: Int, _ position: Int) throws {
                guard codes[rank][position] == "?" else { return }
                let unit = blocks[rank].units[position]
                if unit.kind != "l", let lead = leadPosition(rank) {
                    let leadSource = blocks[rank].units[lead].source
                    if delivered[leadSource] == nil {
                        if codes[rank][lead] == "?" { waiting[rank, default: []].append(position) }
                        else { codes[rank][position] = "L" }
                        return
                    }
                }
                try attempt(rank, position, mandatory: false)
                if unit.kind == "l" {
                    let pending = waiting.removeValue(forKey: rank) ?? []
                    for other in pending {
                        if delivered[unit.source] != nil { try consider(rank, other) } else { codes[rank][other] = "L" }
                    }
                }
            }
            // Lead share (lead-priority policies): before the density pass,
            // candidate leads are admitted in density order while their
            // total stays within `leadShare` of the token budget. A lead that
            // does not fit this share keeps its "?" and competes in the
            // density pass like every other unit, so replies and neighbors
            // of the best blocks keep the rest of the budget.
            if leadsFirst {
                let leadBudget = Int(Double(tokenBudget) * leadShare)
                for item in order where blocks[item.rank].units[item.position].kind == "l" && codes[item.rank][item.position] == "?" {
                    let unit = blocks[item.rank].units[item.position]
                    if delivered[unit.source] != nil { continue }
                    let bytes = try index.byteCount(unit.source)
                    if bytes == 0 { continue }
                    let value = try cost(unit.source)
                    guard tokens + value.tokens <= leadBudget, spanCount + value.spans.count <= maximumSpans,
                          auditBytes + value.audit <= auditBudget else { continue }
                    try attempt(item.rank, item.position, mandatory: false)
                }
            }
            for item in order { try consider(item.rank, item.position) }
            for (rank, pending) in waiting { for position in pending where codes[rank][position] == "?" { codes[rank][position] = "L" } }

            // Delivery order: owning block rank, then chronological.
            let owned = delivered.sorted {
                $0.value.rank != $1.value.rank ? $0.value.rank < $1.value.rank : $0.key < $1.key
            }
            var hits: [MemoryHit] = [], owners: [(rank: Int, unit: Int)] = []
            for (source, owner) in owned {
                let spans = try cost(source).spans
                hits += spans; owners += Array(repeating: owner, count: spans.count)
            }
            return Plan(hits: hits, owners: owners, blocks: blocks, codes: codes, estimatedTokens: tokens,
                estimatedAuditBytes: auditBytes)
        }

        /// Content-free audit of the candidate window. Codes are one
        /// character, so a placeholder plan has the final serialized size up
        /// to numeric fields.
        static func audit(plan: Plan, index: ExchangeCorpus, matchedBlocks: Int, tokenBudget: Int, auditBudget: Int?,
                          maximumSpans: Int, depth: Int = candidateBlockDepth, leadsFirst: Bool = false) throws -> [String: Any] {
            var counts: [String: Int] = [:]
            for row in plan.codes { for code in row { counts[code, default: 0] += 1 } }
            let candidates: [[Any]] = try plan.blocks.enumerated().map { rank, block in
                [block.anchors, try block.units.enumerated().map { position, unit in
                    [candidateID(try index.eventID(unit.source)), unit.kind, plan.codes[rank][position]]
                }]
            }
            return ["packing_version": version, "candidate_block_depth": depth, "lead_priority": leadsFirst,
                "lead_share": leadsFirst ? leadShare : 0.0,
                "candidate_block_count": plan.blocks.count,
                "below_candidate_depth_block_count": max(0, matchedBlocks - plan.blocks.count),
                "candidate_unit_count": plan.blocks.reduce(0) { $0 + $1.units.count },
                "candidate_id_encoding": "sha256(event_id) hex prefix \(candidateIDHexDigits)",
                "candidates": candidates, "disposition_counts": counts,
                "disposition_codes": dispositionCodes, "unit_kinds": kindCodes,
                "member_weight": memberWeight, "neighbor_weight": neighborWeight, "cost_model": costModel,
                "estimated_token_budget": tokenBudget, "estimated_evidence_tokens": plan.estimatedTokens,
                "audit_byte_budget": auditBudget ?? -1, "estimated_audit_bytes": plan.estimatedAuditBytes,
                "admission_headroom_bytes": admissionHeadroomBytes,
                "span_count": plan.hits.count, "maximum_spans": maximumSpans,
                "assembler_selection_trace": "superseded_by_candidates"]
        }

        /// Plan, deliver through the assembler, and verify the delivery audit
        /// leaves the declared admission headroom. If it does not, the last
        /// planned source is removed with an `A` receipt and delivery repeats.
        static func select(recent: ContextSnapshot, binding: ContextSelectionBinding, store: MemoryStore,
            conversationID: String, projectID: String, excludingEventID: String, episodeLease: EpisodeLease?,
            componentPolicy: ContextComponentPolicy, index: ExchangeCorpus, ranked: [RankedBlock], tokenBudget: Int,
            baseAudit: [String: Any]) throws -> ContextSnapshot {
            func retrieval(_ exchange: [String: Any], from snapshot: ContextSnapshot) throws -> Data {
                var value = try snapshot.retrievalAuditJSON.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                value.removeValue(forKey: "selection_trace")
                value["mode"] = ExchangeBlockQuery.retrievalMode(componentPolicy); value["semantic_available"] = false
                value["exchange_query"] = baseAudit.merging(exchange) { _, new in new }
                return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            }
            // The policy's declared window and audit limit (`exchange_packed`
            // keeps this packer's declared constants).
            let depth = componentPolicy.candidateBlockDepth, auditLimit = componentPolicy.deliveryAuditBytes
            let leadsFirst = componentPolicy.packsLeadsFirst
            // Size probe: the delivery audit with no historical sources and
            // a placeholder candidate audit of the final shape.
            let placeholderBlocks = try candidates(index: index, ranked: ranked, depth: depth)
            let placeholder = Plan(hits: [], owners: [], blocks: placeholderBlocks,
                codes: placeholderBlocks.map { Array(repeating: "?", count: $0.units.count) },
                estimatedTokens: tokenBudget, estimatedAuditBytes: auditLimit)
            var probe = recent
            probe.deliveryAuditLimit = auditLimit
            probe.retrievalAuditJSON = try retrieval(try audit(plan: placeholder, index: index, matchedBlocks: ranked.count,
                tokenBudget: tokenBudget, auditBudget: auditLimit, maximumSpans: componentPolicy.evidenceSpans, depth: depth,
                leadsFirst: leadsFirst), from: recent)
            let base = try probe.deliveryAudit().count
            let auditBudget = max(0, auditLimit - admissionHeadroomBytes - probeSlackBytes - base)
            var plan = try plan(index: index, ranked: ranked, maximumSpans: componentPolicy.evidenceSpans,
                tokenBudget: tokenBudget, auditBudget: auditBudget, selectionVersion: binding.version, depth: depth,
                leadsFirst: leadsFirst)
            var trimmed = 0
            while true {
                var result = try ContextAssembler.addEvidence(to: recent, store: store, conversationID: conversationID,
                    projectID: projectID, excludingEventID: excludingEventID, historicalHits: plan.hits,
                    maximumEvidenceSpans: componentPolicy.evidenceSpans, episodeLease: episodeLease, operationIsNested: true,
                    componentPolicy: componentPolicy, historicalProvenance: nil)
                var exchange = try audit(plan: plan, index: index, matchedBlocks: ranked.count, tokenBudget: tokenBudget,
                    auditBudget: auditBudget, maximumSpans: componentPolicy.evidenceSpans, depth: depth, leadsFirst: leadsFirst)
                exchange["verification_trimmed_source_count"] = trimmed
                exchange["delivery_audit_bytes_before_admission"] = 0
                result.retrievalAuditJSON = try retrieval(exchange, from: result)
                // The assembler silently drops this audit above its limit,
                // so the measured audit must also still carry it.
                var measured = Int.max
                if let bytes = try? result.deliveryAudit(),
                   let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                   (object["retrieval"] as? [String: Any])?["exchange_query"] != nil { measured = bytes.count }
                if measured <= auditLimit - admissionHeadroomBytes || plan.hits.isEmpty {
                    exchange["delivery_audit_bytes_before_admission"] = measured
                    result.retrievalAuditJSON = try retrieval(exchange, from: result)
                    result.retrievalManifestID = nil; result.retrievalManifestJSON = nil
                    // As the October 8, 2026 lexical decision did, the ordinary
                    // Send default shows no notice for its intended selection;
                    // an explicit policy names itself.
                    result.retrievalNotice = componentPolicy == .currentSelectedQwen ? nil
                        : "Archive recall ranked complete exchanges lexically over the whole question and packed them by relevance per cost; semantic recall was not used."
                    return result
                }
                // Remove the last planned source (all of its pages).
                guard let owner = plan.owners.last else { throw ContextError.invalidBudget }
                let keep = plan.hits.indices.filter { !(plan.owners[$0].rank == owner.rank && plan.owners[$0].unit == owner.unit) }
                plan.codes[owner.rank][owner.unit] = "A"
                plan = Plan(hits: keep.map { plan.hits[$0] }, owners: keep.map { plan.owners[$0] }, blocks: plan.blocks,
                    codes: plan.codes, estimatedTokens: plan.estimatedTokens, estimatedAuditBytes: plan.estimatedAuditBytes)
                trimmed += 1
            }
        }
    }
}
