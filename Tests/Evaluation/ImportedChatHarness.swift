import Foundation
import CryptoKit
import Darwin

// Standalone diagnostic only. The app build never compiles this entry point.
// All source text, queries and vectors remain inside the private scratch store.
private struct ImportFixture: Decodable {
    let version: Int
    let messages: [ImportedSource]
    let probes: [ImportProbe]
    let semanticChunks: Int
    let indexSeconds: Int
    let memoryOperationCap: Int
}
private struct ImportedSource: Decodable {
    let id: String
    let role: MemoryRole
    let status: CaptureStatus
    let turnID: String?
    let text: String
    let sha256: String
    let sourceTime: EventSourceTime?
}
private struct ImportProbe: Decodable {
    let prompt: String
    let query: String
    let literal: String?
    let region: String
    let kind: String
    let gold: [ImportGold]
}
private struct ImportGold: Decodable {
    let message: Int
    let offset: Int
    let bytes: Int
    let sha256: String
}
private struct DeliveredRange {
    let id: String
    let offset: Int
    let bytes: Data
    let digest: String
}
private struct HitWindowIdentity: Hashable {
    let source: Data
    let offset: Int
    let bytes: Int
}
private enum HarnessFailure: Error { case invalid, sourceMismatch }

private struct ReadAttempt {
    let lease: EpisodeLease
    let clock: SystemEpisodeClock
    let start: EpisodeClockSnapshot

    static func begin(store: MemoryStore, probe: ImportProbe, protocolName: String, cap: Int) throws -> Self {
        let clock = SystemEpisodeClock(), start = try clock.now()
        var limits = EpisodeLimits()
        limits.resources.memoryOperations = cap
        let descriptor = try JSONSerialization.data(withJSONObject: ["version": "imported-chat-probe-v2",
            "protocol": protocolName, "prompt_sha256": ContextSnapshot.digest(Data(probe.prompt.utf8)),
            "query_sha256": ContextSnapshot.digest(Data(probe.query.utf8)), "context_bytes": 65536,
            "recent_bytes": 24000, "evidence_bytes": 12000], options: [.sortedKeys])
        let id = UUID().uuidString
        let binding = EpisodeLocalReadBinding(version: "local-read-v1", initiator: .syntheticEvaluation,
            purpose: .retrievalProbe, requestID: id, descriptorVersion: "imported-chat-probe-v2",
            descriptorSHA256: ContextSnapshot.digest(descriptor))
        _ = try store.beginLocalReadEpisode(episodeID: id, projectID: "default", binding: binding, limits: limits, clock: start)
        return Self(lease: EpisodeLease(ledger: store, episodeID: id, clock: clock), clock: clock, start: start)
    }

    func finish(error: Error?) throws -> [String: Any] {
        var reason: EpisodeState = error == nil ? .completed : .failed
        if let error = error as? EpisodeBudgetError {
            if case .exhausted = error { reason = .budgetExceeded }
            if case .deadlineExceeded = error { reason = .deadlineExceeded }
        }
        let receipt = try lease.finish(reason: reason)
        let end = try clock.now()
        guard receipt.state != .active, end.domain == start.domain,
              end.continuousNanoseconds >= start.continuousNanoseconds else { throw HarnessFailure.invalid }
        return ["receipt": try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)),
                "state": receipt.state.rawValue,
                "fullEpisodeMilliseconds": Double(end.continuousNanoseconds - start.continuousNanoseconds) / 1_000_000]
    }
}

@main
private enum ImportedChatHarness {
    static func main() {
        do {
            guard CommandLine.arguments.count == 5 else { throw HarnessFailure.invalid }
            let mode = CommandLine.arguments[1]
            guard ["warm", "restart"].contains(mode) else { throw HarnessFailure.invalid }
            let fixture = try JSONDecoder().decode(ImportFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            try validate(fixture)
            let directory = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
            let output = URL(fileURLWithPath: CommandLine.arguments[4])
            let report = try run(fixture, mode: mode, directory: directory)
            let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try bytes.write(to: output, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        } catch {
            fputs("Offline imported-chat diagnostic failed.\n", stderr)
            exit(1)
        }
    }

    static func validate(_ fixture: ImportFixture) throws {
        guard [1, 2].contains(fixture.version), !fixture.messages.isEmpty, fixture.messages.count <= 100000,
              (0...4096).contains(fixture.semanticChunks), (1...300).contains(fixture.indexSeconds),
              (0...24).contains(fixture.memoryOperationCap), (1...200).contains(fixture.probes.count),
              Set(fixture.messages.map(\.id)).count == fixture.messages.count else { throw HarnessFailure.invalid }
        for source in fixture.messages {
            if let time = source.sourceTime {
                guard fixture.version == 2 else { throw HarnessFailure.invalid }
                _ = try time.validated()
            }
            guard source.id.hasPrefix("import-"), source.id.utf8.count <= 256,
                  source.text.utf8.count <= MemoryStore.maximumPayloadBytes,
                  ContextSnapshot.digest(Data(source.text.utf8)) == source.sha256 else { throw HarnessFailure.invalid }
            if let turn = source.turnID {
                guard !turn.isEmpty, turn.utf8.count <= 256, !turn.contains("\0") else { throw HarnessFailure.invalid }
            }
        }
        for probe in fixture.probes {
            guard !probe.prompt.isEmpty, probe.prompt.utf8.count <= 16384, !probe.query.isEmpty,
                  probe.query.utf8.count <= 1024, probe.gold.count <= 16,
                  ["early", "middle", "late", "recent", "absent"].contains(probe.region),
                  probe.kind == (probe.gold.isEmpty ? "absent" : "answerable") else { throw HarnessFailure.invalid }
            for gold in probe.gold {
                guard fixture.messages.indices.contains(gold.message), gold.offset >= 0, gold.bytes > 0 else { throw HarnessFailure.invalid }
                let bytes = Data(fixture.messages[gold.message].text.utf8)
                guard gold.offset <= bytes.count, gold.bytes <= bytes.count - gold.offset else { throw HarnessFailure.invalid }
                let span = bytes.subdata(in: gold.offset..<(gold.offset + gold.bytes))
                guard ContextSnapshot.digest(span) == gold.sha256, String(data: span, encoding: .utf8) != nil,
                      String(data: bytes.prefix(gold.offset), encoding: .utf8) != nil else { throw HarnessFailure.invalid }
            }
        }
    }

    static func verifySources(store: MemoryStore, conversation: String, sources: [ImportedSource]) throws {
        let events = try store.events(conversationID: conversation)
        guard events.count == sources.count else { throw HarnessFailure.sourceMismatch }
        for (event, source) in zip(events, sources) {
            guard episodeIdentifierEqual(event.id, source.id), event.projectID == "default",
                  event.role == source.role, event.status == source.status, event.digest == source.sha256,
                  event.sourceTime == source.sourceTime,
                  Data(event.text.utf8) == Data(source.text.utf8) else { throw HarnessFailure.sourceMismatch }
            if let turn = source.turnID, !episodeIdentifierEqual(event.turnID, turn) { throw HarnessFailure.sourceMismatch }
        }
    }

    static func run(_ fixture: ImportFixture, mode: String, directory: URL) throws -> [String: Any] {
        let start = DispatchTime.now().uptimeNanoseconds
        let store = try MemoryStore(directory: directory)
        let mapping = directory.appendingPathComponent("diagnostic-conversation.json")
        let conversation: String
        if mode == "warm" {
            conversation = try store.createConversation(projectID: "default", title: "Imported chat offline diagnostic").id
            for (ordinal, source) in fixture.messages.enumerated() {
                _ = try store.append(conversationID: conversation, role: source.role, text: source.text, status: source.status,
                                     turnID: source.turnID ?? "diagnostic-turn-\(ordinal)", eventID: source.id, sourceTime: source.sourceTime)
            }
            try JSONEncoder().encode(conversation).write(to: mapping, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapping.path)
        } else { conversation = try JSONDecoder().decode(String.self, from: Data(contentsOf: mapping)) }
        try verifySources(store: store, conversation: conversation, sources: fixture.messages)
        let constructionMs = elapsed(start)
        let indexingStart = DispatchTime.now().uptimeNanoseconds
        var index: SemanticIndex?
        var indexReport: [String: Any] = ["status": "disabled", "requestedChunkCapacity": 0]
        if fixture.semanticChunks > 0 {
            do {
                let candidate = try SemanticIndex(store: store)
                index = candidate
                var attempted = 0
                var published = 0, failed = 0, scheduled = 0
                var stopReason = mode == "restart" ? "retained_index" : "chunk_capacity"
                if mode == "warm" {
                    while attempted < fixture.semanticChunks, elapsed(indexingStart) < Double(fixture.indexSeconds * 1000) {
                        let batch = min(128, fixture.semanticChunks - attempted)
                        let result = try candidate.process(projectID: "default", maximumChunks: batch)
                        attempted += batch
                        published += result.publishedChunks; failed += result.failedChunks; scheduled += result.scheduledSources
                        if result.budgetPauseReason != nil { stopReason = "background_budget"; break }
                        if result.publishedChunks == 0 && result.failedChunks == 0 && result.scheduledSources == 0 { stopReason = "no_work"; break }
                    }
                    if elapsed(indexingStart) >= Double(fixture.indexSeconds * 1000), stopReason == "chunk_capacity" { stopReason = "scheduling_deadline" }
                }
                indexReport = ["status": "available", "requestedChunkCapacity": attempted,
                               "publishedChunkRecords": published, "failedChunkAttempts": failed, "scheduledSources": scheduled,
                               "stopReason": stopReason, "coverageRecordedPerHybridProbe": true,
                               "indexFingerprint": candidate.indexFingerprint,
                               "budgetPauseCode": candidate.backgroundPauseReason as Any? ?? NSNull(),
                               "backgroundBudget": try JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate.backgroundBudgetSnapshot()))]
            } catch let error as BackgroundIndexBudgetError {
                indexReport = ["status": "budget_limited", "errorCode": error.failureCode]
            } catch {
                if error is MemoryError { throw error }
                if let semantic = error as? SemanticError {
                    switch semantic { case .sourceMismatch, .publicationConflict: throw error; default: break }
                }
                indexReport = ["status": index == nil ? "unavailable" : "indexing_error",
                               "errorCode": "semantic_initialization_or_indexing_failed", "coverageRecordedPerHybridProbe": index != nil]
            }
        }
        indexReport["milliseconds"] = elapsed(indexingStart)
        var probes: [[String: Any]] = []
        for (ordinal, probe) in fixture.probes.enumerated() {
            var protocols: [String: Any] = [:]
            for name in ["recent_only", "lexical_context", "hybrid_context", "raw_pages"] {
                if name == "hybrid_context", index == nil {
                    protocols[name] = ["status": "skipped", "errorCode": "semantic_unavailable_or_disabled",
                        "allRequiredSpansPresent": false, "goldSpanCoverage": probe.gold.map { _ in false },
                        "coverageLimits": ["semantic_unavailable"], "sourceCount": 0, "fullEpisodeMilliseconds": 0]
                } else {
                    protocols[name] = try evaluate(probe, name: name, fixture: fixture, store: store,
                                                   conversation: conversation, index: index)
                }
            }
            probes.append(["ordinal": ordinal, "kind": probe.kind, "region": probe.region,
                           "goldSpanCount": probe.gold.count, "protocols": protocols])
        }
        try verifySources(store: store, conversation: conversation, sources: fixture.messages)
        return ["mode": mode, "sourcesVerifiedBeforeAndAfter": true, "messageCount": fixture.messages.count,
                "storeConstructionOrReopenMilliseconds": constructionMs, "semanticIndex": indexReport,
                "probes": probes, "questionsCaptured": 0, "answeringInvocations": 0]
    }

    static func evaluate(_ probe: ImportProbe, name: String, fixture: ImportFixture, store: MemoryStore,
                         conversation: String, index: SemanticIndex?) throws -> [String: Any] {
        let start = DispatchTime.now().uptimeNanoseconds
        let attempt = try ReadAttempt.begin(store: store, probe: probe, protocolName: name, cap: fixture.memoryOperationCap)
        var ranges: [DeliveredRange] = []
        var sourceCount = 0
        var metadata: [String: Any] = [:]
        var searchHits: [MemoryHit] = []
        var failure: Error?
        var limits: [String] = []
        do {
            if name == "raw_pages" {
                let lexical = try MeteredRetrieval.lexicalSearch(store: store, query: probe.query, projectID: "default",
                    limit: 16, matching: .anyTerm, lease: attempt.lease)
                if lexical.continuation != nil { limits.append("raw_source_budget"); throw EpisodeBudgetError.exhausted }
                if lexical.candidateWindowFull { limits.append("lexical_candidate_window") }
                var literal: [MemoryHit] = []
                if let query = probe.literal {
                    let report = try MeteredRetrieval.literalSearch(store: store, query: query, projectID: "default", limit: 16, lease: attempt.lease)
                    literal = report.hits
                    if let reason = report.incompleteReason { limits.append(reason) }
                    if report.incompleteReason == "raw_source_budget" { throw EpisodeBudgetError.exhausted }
                }
                // Rank agreement first. The literal scanner's source order
                // carries no relevance rank and must not bury a top lexical
                // result shared by both search paths.
                let literalIDs = Set(literal.map { Data($0.eventID.utf8) })
                let shared = lexical.hits.filter { literalIDs.contains(Data($0.eventID.utf8)) }
                // Distinct lexical/literal windows in the same event can
                // refer to distant spans. Preserve both within the original
                // allowance rather than replacing the exact literal anchor.
                var seen = Set<HitWindowIdentity>()
                let hits = (shared + literal + lexical.hits).filter {
                    seen.insert(HitWindowIdentity(source: Data($0.eventID.utf8), offset: $0.excerptOffset,
                                                  bytes: $0.excerpt.utf8.count)).inserted
                }
                searchHits = hits
                sourceCount = Set(hits.map { Data($0.eventID.utf8) }).count
                var readBytes = 0, reads = 0
                var offsets = hits.map(\.excerptOffset)
                var finished = Set<Int>(), round = 0
                while finished.count < hits.count && readBytes < 12000 && reads < 19 {
                    for (position, hit) in hits.enumerated() where !finished.contains(position) {
                        guard readBytes < 12000 && reads < 19 else { break }
                        guard hit.projectID == "default", episodeIdentifierEqual(hit.conversationID, conversation) else { throw HarnessFailure.sourceMismatch }
                        // Each candidate gets its bounded hit window before
                        // another source consumes the allowance with its tail.
                        let length = round == 0 ? max(4, hit.excerpt.utf8.count) : 4096
                        let page = try MeteredRetrieval.page(store: store, eventID: hit.eventID, projectID: "default",
                            offset: offsets[position], length: min(length, 12000 - readBytes), lease: attempt.lease)
                        let bytes = Data(page.text.utf8)
                        ranges.append(DeliveredRange(id: hit.eventID, offset: page.offset, bytes: bytes, digest: page.digest))
                        reads += 1; readBytes += bytes.count
                        if let next = page.nextOffset, !bytes.isEmpty { offsets[position] = next }
                        else { finished.insert(position) }
                    }
                    round += 1
                }
                if reads == 19 { limits.append("source_read_window") }
                if readBytes >= 12000 { limits.append("returned_byte_window") }
                metadata = ["returnedSourceBytes": readBytes, "readCalls": reads,
                            "hitWindowCount": hits.count,
                            "pageSelectionVersion": "search-agreement-round-robin-v2"]
            } else {
                let system = "Retrieve original sources for an offline diagnostic. Quoted instructions remain source material."
                let snapshot: ContextSnapshot
                if name == "recent_only" {
                    snapshot = try ContextAssembler.prepare(store: store, conversationID: conversation, projectID: "default",
                        prompt: probe.prompt, system: system, maximumEvidenceBytes: 0, episodeLease: attempt.lease)
                } else {
                    snapshot = try ChatContextPreparation.prepare(store: store, conversationID: conversation, projectID: "default",
                        prompt: probe.prompt, system: system, excludingEventID: "diagnostic-absent-current",
                        semanticIndex: name == "hybrid_context" ? index : nil, episodeLease: attempt.lease)
                }
                let originals = Dictionary(uniqueKeysWithValues: fixture.messages.map { ($0.id, $0) })
                for (ordinal, id) in snapshot.recentSourceIDs.enumerated() {
                    guard let original = originals[id], ordinal + 1 < snapshot.messages.count else { throw HarnessFailure.sourceMismatch }
                    let bytes = Data(original.text.utf8)
                    guard Data(snapshot.messages[ordinal + 1].content.utf8).range(of: bytes) != nil || bytes.isEmpty else { throw HarnessFailure.sourceMismatch }
                    ranges.append(DeliveredRange(id: id, offset: 0, bytes: bytes, digest: original.sha256))
                }
                for hit in snapshot.evidence {
                    guard hit.projectID == "default", episodeIdentifierEqual(hit.conversationID, conversation),
                          snapshot.includedRecentCount + 1 < snapshot.messages.count,
                          Data(snapshot.messages[snapshot.includedRecentCount + 1].content.utf8).range(of: Data(hit.excerpt.utf8)) != nil else { throw HarnessFailure.sourceMismatch }
                    ranges.append(DeliveredRange(id: hit.eventID, offset: hit.excerptOffset, bytes: Data(hit.excerpt.utf8), digest: hit.digest))
                }
                sourceCount = Set(ranges.map(\.id)).count
                metadata = ["serializedContextBytes": snapshot.serializedBytes, "recentSources": snapshot.recentSourceIDs.count,
                            "evidenceSources": snapshot.evidence.count]
                if let data = snapshot.retrievalManifestJSON {
                    let manifest = try JSONDecoder().decode(SemanticSearchManifest.self, from: data)
                    let coverage = manifest.coverage
                    metadata["semanticCoverage"] = ["complete": coverage.complete, "inspectedSources": coverage.inspectedSources,
                        "completeSources": coverage.completeSources, "pendingSources": coverage.pendingSources,
                        "unsupportedSources": coverage.unsupportedSources, "failedSources": coverage.failedSources,
                        "indexedBytes": coverage.indexedBytes, "indexedChunks": coverage.indexedChunks,
                        "unsupportedChunks": coverage.unsupportedChunks, "reportedHoles": coverage.holes.count,
                        "holesTruncated": coverage.holesTruncated, "metadataWindowLimited": coverage.metadataContinuationSequence != nil,
                        "queryDisposition": manifest.queryDisposition]
                    metadata["semanticReportedHoleReasons"] = Dictionary(grouping: coverage.holes, by: \.reason).mapValues(\.count)
                    if coverage.metadataContinuationSequence != nil { limits.append("semantic_metadata_window") }
                    if coverage.holesTruncated { limits.append("semantic_hole_report_window") }
                }
                if let data = snapshot.retrievalAuditJSON, let audit = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    metadata["retrieval"] = audit
                    if audit["candidate_window_full"] as? Bool == true { limits.append("lexical_candidate_window") }
                    if audit["coverage_complete"] as? Bool == false { limits.append("semantic_index_incomplete") }
                    if audit["vector_continuation_available"] as? Bool == true { limits.append("vector_candidate_window") }
                    if audit["candidate_window_complete"] as? Bool == false { limits.append("raw_source_budget") }
                }
            }
        } catch {
            failure = error
            if let error = error as? EpisodeBudgetError {
                if case .exhausted = error { limits.append("episode_budget") }
                if case .deadlineExceeded = error { limits.append("episode_deadline") }
            }
        }
        let accounting = try attempt.finish(error: failure)
        if failure == nil, accounting["state"] as? String != "completed" {
            failure = accounting["state"] as? String == "deadlineExceeded" ? EpisodeBudgetError.deadlineExceeded : EpisodeBudgetError.inactive
            limits.append("terminal_episode_outcome")
        }
        let pathMilliseconds = elapsed(start)
        // Oracle verification and gold scoring occur after episode terminalization.
        let scoringStart = DispatchTime.now().uptimeNanoseconds
        let originals = Dictionary(uniqueKeysWithValues: fixture.messages.map { ($0.id, $0) })
        for range in ranges {
            guard let source = originals[range.id], source.sha256 == range.digest else { throw HarnessFailure.sourceMismatch }
            let bytes = Data(source.text.utf8)
            guard range.offset >= 0, range.offset <= bytes.count, range.bytes.count <= bytes.count - range.offset,
                  bytes.subdata(in: range.offset..<(range.offset + range.bytes.count)) == range.bytes else { throw HarnessFailure.sourceMismatch }
        }
        let coverage = probe.gold.map { gold in
            failure == nil && covered(gold, source: fixture.messages[gold.message].id, ranges: ranges)
        }
        // Post-terminal oracle diagnostics never influence query selection or
        // page scheduling. Emit only ordinals, byte positions and booleans.
        let diagnostics: [[String: Any]] = probe.gold.enumerated().map { ordinal, gold in
            let id = fixture.messages[gold.message].id
            let delivered = ranges.filter { episodeIdentifierEqual($0.id, id) }
            let candidate = searchHits.firstIndex { episodeIdentifierEqual($0.eventID, id) }
            let stage = failure != nil ? "episode_failure" : coverage[ordinal] ? "covered"
                : !delivered.isEmpty ? "range_not_delivered" : candidate != nil ? "candidate_not_paged" : "source_not_delivered"
            return ["messageOrdinal": gold.message, "goldOffset": gold.offset, "goldBytes": gold.bytes,
                    "covered": coverage[ordinal], "sourceDelivered": !delivered.isEmpty,
                    "failureStage": stage,
                    "deliveredRanges": delivered.map { ["offset": $0.offset, "bytes": $0.bytes.count] },
                    "searchCandidateRank": candidate.map { $0 + 1 } as Any? ?? NSNull()]
        }
        metadata.merge(["status": failure == nil ? "selected" : "error",
                        "errorCode": failure.map { ($0 as? EpisodeBudgetError)?.failureCode ?? "retrieval_failed" } ?? "",
                        "allRequiredSpansPresent": !coverage.isEmpty && coverage.allSatisfy { $0 },
                        "goldSpanCoverage": coverage, "sourceCount": sourceCount,
                        "goldDiagnostics": diagnostics,
                        "coverageLimits": Array(Set(limits)).sorted(), "returnedBytesVerified": true,
                        "memoryPathMilliseconds": pathMilliseconds, "oracleScoringMilliseconds": elapsed(scoringStart),
                        "fullEpisodeMilliseconds": accounting["fullEpisodeMilliseconds"]!,
                        "episodeReceipt": accounting["receipt"]!]) { _, new in new }
        return metadata
    }

    static func covered(_ gold: ImportGold, source: String, ranges: [DeliveredRange]) -> Bool {
        let selected = ranges.filter { episodeIdentifierEqual($0.id, source) }.sorted { $0.offset < $1.offset }
        var position = gold.offset, bytes = Data()
        for range in selected {
            let end = range.offset + range.bytes.count
            if range.offset > position { break }
            if end <= position { continue }
            let upper = min(end, gold.offset + gold.bytes)
            bytes.append(range.bytes.subdata(in: (position - range.offset)..<(upper - range.offset)))
            position = upper
            if position == gold.offset + gold.bytes { return ContextSnapshot.digest(bytes) == gold.sha256 }
        }
        return false
    }

    static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
