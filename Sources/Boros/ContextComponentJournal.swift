import Foundation
import CryptoKit
import CoreFoundation
import CSQLite

/// Offline integrity checks reuse the production renderer and link counts to
/// the actual tokenizer snapshots and committed provider count evidence. They
/// do not run a tokenizer, authenticate an archive, or infer usage from bytes.
enum ContextComponentJournal {
    static func validate(database: OpaquePointer, invocationID: String? = nil, verifySourceRanges: Bool = true) throws {
        let sql = """
            SELECT i.id,i.episode_id,i.project_id,i.request_body,i.request_digest,i.admission_json,
                   ep.limits_json,w.request_json,i.provider_identity,
                   ep.clock_domain,ep.created_ticks,ep.deadline_ticks,i.conversation_id,i.human_event_id
            FROM invocations i
            LEFT JOIN episodes ep ON ep.id=i.episode_id
            LEFT JOIN episode_work w ON w.id=i.episode_work_id
            """ + (invocationID == nil ? "" : " WHERE i.id=?")
        try rows(database, sql, invocationID.map { [$0] } ?? []) { row in
            let admissionBytes = data(row, 5)
            let admission = admissionBytes.isEmpty ? [:] : try object(admissionBytes)
            let endpointReceipt = admission["receipt"] as? [String: Any]
            let proof = endpointReceipt?["componentProof"] as? [String: Any]
            let limitsBytes = data(row, 6)
            let limits = limitsBytes.isEmpty ? nil : try JSONDecoder().decode(EpisodeLimits.self, from: limitsBytes)
            guard let policy = limits?.componentPolicy else {
                guard proof == nil else { throw invalid("proof has no frozen policy") }
                return
            }
            _ = try policy.validated()
            guard let receipt = endpointReceipt, let proof else { throw invalid("frozen policy lacks proof") }
            let bodyBytes = data(row, 3), body = try object(bodyBytes)
            let episodeID = text(row, 1), projectID = text(row, 2), provider = text(row, 8)
            let policyDigest = digest(try policy.canonicalData())
            guard let proofIdentity = proof["modelIdentity"] as? [String: Any],
                  let receiptIdentity = receipt["modelIdentity"] as? [String: Any],
                  try canonical(proofIdentity) == canonical(receiptIdentity) else {
                throw invalid("model observation linkage mismatch")
            }
            let modelIdentity: ProviderObservedModelIdentity
            do {
                modelIdentity = try JSONDecoder().decode(ProviderObservedModelIdentity.self,
                    from: canonical(proofIdentity)).validated()
            } catch { throw invalid("unsupported model observation") }
            guard bodyBytes.count <= 2 * 1_048_576,
                  equal(proof["episodeID"], episodeID), equal(proof["projectID"], projectID),
                  equal(receipt["episodeID"], episodeID), equal(receipt["modelID"], Qwen38TextRendering.modelID),
                  equal(proof["endpoint"], provider), equal(receipt["endpoint"], provider),
                  proof["bodyDigest"] as? String == digest(bodyBytes),
                  receipt["bodyDigest"] as? String == digest(bodyBytes), text(row, 4) == digest(bodyBytes),
                  proof["policyDigest"] as? String == policyDigest,
                  proof["policyVersion"] as? String == policy.version,
                  integer(proof["recentCap"]) == policy.recentTokens,
                  integer(proof["evidenceCap"]) == policy.evidenceTokens,
                  proof["renderingVersion"] as? String == policy.rendererVersion,
                  proof["reductionVersion"] as? String == policy.reductionVersion,
                  equal(body["model"], Qwen38TextRendering.modelID),
                  let thinking = boolean(body["enable_thinking"]), boolean(proof["thinkingEnabled"]) == thinking,
                  boolean(receipt["thinkingEnabled"]) == thinking,
                  let output = integer(body["max_tokens"]), output > 0,
                  integer(proof["outputReserve"]) == output, integer(receipt["outputReserve"]) == output,
                  let safety = integer(proof["safetyTokens"]), integer(receipt["safetyTokens"]) == safety,
                  let contextLimit = integer(proof["effectiveContextLimit"]), contextLimit > 0,
                  integer(receipt["effectiveContextLimit"]) == contextLimit,
                  contextLimit <= modelIdentity.modelContextLimit, contextLimit <= modelIdentity.maxModelLength,
                  integer(proof["modelEpoch"]) == 0, integer(receipt["loadedModelEpoch"]) == 0,
                  receipt["templateDigest"] as? String == Qwen38TextRendering.templateDigest,
                  receipt["serverVersion"] as? String == Qwen38TextRendering.serverVersion,
                  let contextString = admission["context"] as? String,
                  let contextBytes = Data(base64Encoded: contextString) else { throw invalid("proof binding mismatch") }
            let context = try object(contextBytes)
            guard let componentNames = context["message_components"] as? [String],
                  let sourceDigest = context["source_snapshot_sha256"] as? String, isDigest(sourceDigest),
                  proof["sourceSnapshotDigest"] as? String == sourceDigest,
                  let recentCount = integer(context["recent_source_count"]), recentCount <= policy.recentCandidates,
                  let historical = context["historical_sources"] as? [[String: Any]], historical.count <= policy.evidenceSpans,
                  componentNames == ["mandatory"] + Array(repeating: "recent", count: recentCount)
                    + (historical.isEmpty ? [] : ["historicalEvidence"]) + ["mandatory"],
                  let contextProof = context["components"] as? [String: Any],
                  try canonical(contextProof) == canonical(proof) else { throw invalid("source audit mismatch") }
            try validateSelection(database: database, context: context, body: body, sourceDigest: sourceDigest,
                episodeID: episodeID, projectID: projectID, conversationID: text(row, 12), humanID: text(row, 13),
                policy: policy, verifySourceRanges: verifySourceRanges)
            let assignments: [ProviderMessageComponent] = try componentNames.map {
                switch $0 {
                case "mandatory": return .mandatory
                case "recent": return .recent
                case "historicalEvidence": return .evidence
                default: throw invalid("invalid provenance label")
                }
            }
            let assignmentDigest = digest(Data(assignments.map(\.rawValue).joined(separator: "\0").utf8))
            guard proof["assignmentDigest"] as? String == assignmentDigest else { throw invalid("provenance digest mismatch") }
            let rendered = try Qwen38TextRendering.renderAttributed(body, assignments: assignments)
            let adapter = ProviderObservedModelIdentity.adapterIdentity(endpoint: provider,
                metadataDigest: digest(try modelIdentity.canonicalData()), thinking: thinking)
            guard equal(proof["adapterIdentity"], adapter) else { throw invalid("adapter binding mismatch") }
            let recent = try count(database: database, proof: proof, key: "recent", kind: "recent",
                rendered: rendered.recent, episodeID: episodeID, projectID: projectID, adapter: adapter, policy: policy)
            let evidence = try count(database: database, proof: proof, key: "evidence", kind: "evidence",
                rendered: rendered.evidence, episodeID: episodeID, projectID: projectID, adapter: adapter, policy: policy)
            let whole = try count(database: database, proof: proof, key: "wholePrompt", kind: "wholePrompt",
                rendered: rendered.complete, episodeID: episodeID, projectID: projectID, adapter: adapter, policy: policy)
            let createdTicks = sqlite3_column_int64(row, 10), deadlineTicks = sqlite3_column_int64(row, 11)
            guard recent.tokens <= policy.recentTokens, evidence.tokens <= policy.evidenceTokens,
                  recent.sessionID == evidence.sessionID, evidence.sessionID == whole.sessionID,
                  equal(recent.domain, whole.domain), equal(evidence.domain, whole.domain), equal(whole.domain, text(row, 9)),
                  recent.ticks == whole.ticks, evidence.ticks == whole.ticks,
                  createdTicks > 0, deadlineTicks > createdTicks,
                  whole.ticks >= UInt64(createdTicks), whole.ticks < UInt64(deadlineTicks),
                  output <= contextLimit, safety <= contextLimit - output, whole.tokens <= contextLimit - output - safety,
                  integer(receipt["promptTokens"]) == whole.tokens,
                  integer(receipt["envelopeBytes"]) == bodyBytes.count else { throw invalid("component allowance mismatch") }
            let answer = try JSONDecoder().decode(EpisodeWorkRequest.self, from: data(row, 7))
            guard answer.kind == .answer, answer.resources.inputTokens == whole.tokens,
                  answer.resources.outputTokens == output, answer.resources.modelCalls == 1,
                  equal(answer.adapterIdentity, adapter) else { throw invalid("answer count linkage mismatch") }
        }
    }

    private static func count(database: OpaquePointer, proof: [String: Any], key: String, kind: String,
        rendered: String, episodeID: String, projectID: String, adapter: String, policy: ContextComponentPolicy) throws -> (tokens: Int, sessionID: String, domain: String, ticks: UInt64) {
        guard let receipt = proof[key] as? [String: Any], receipt["kind"] as? String == kind,
              let tokens = integer(receipt["tokens"]), let session = receipt["sessionID"] as? String,
              !session.isEmpty, session.utf8.count <= 256, !session.contains("\0"),
              equal(receipt["episodeID"], episodeID), equal(receipt["projectID"], projectID),
              equal(receipt["adapterIdentity"], adapter), receipt["rendererVersion"] as? String == policy.rendererVersion,
              receipt["renderedDigest"] as? String == digest(Data(rendered.utf8)),
              let clockDomain = receipt["clockDomain"] as? String, !clockDomain.isEmpty,
              clockDomain.utf8.count <= 256, !clockDomain.contains("\0"),
              let ticks = unsignedInteger(receipt["verifiedNanoseconds"]), ticks > 0,
              ticks <= UInt64(Int64.max) else { throw invalid("count receipt mismatch") }
        if rendered.isEmpty {
            guard tokens == 0, receipt["tokenizerWorkID"] == nil || receipt["tokenizerWorkID"] is NSNull else {
                throw invalid("empty component has performed count work")
            }
            return (tokens, session, clockDomain, ticks)
        }
        guard tokens > 0, let workID = receipt["tokenizerWorkID"] as? String, !workID.isEmpty, workID.utf8.count <= 256 else {
            throw invalid("tokenizer work missing")
        }
        var matches = 0
        try rows(database, """
            SELECT w.episode_id,w.kind,w.adapter_identity,w.state,w.request_json,w.receipt_json,s.payload,w.created_ticks
            FROM episode_work w LEFT JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?
            """, [workID]) { row in
            matches += 1
            guard equal(text(row, 0), episodeID), text(row, 1) == "tokenizer",
                  equal(text(row, 2), adapter), text(row, 3) == "completed" else { throw invalid("count work scope mismatch") }
            guard sqlite3_column_int64(row, 7) >= Int64(ticks) else { throw invalid("count precedes verification") }
            let request = try JSONDecoder().decode(EpisodeWorkRequest.self, from: data(row, 4))
            guard request.resources == EpisodeResources(httpAttempts: 1), request.inputTokensKnown else {
                throw invalid("count work resource mismatch")
            }
            let snapshot = try object(data(row, 6))
            guard equal(snapshot["model"], Qwen38TextRendering.modelID), equal(snapshot["content"], rendered) else {
                throw invalid("counted text differs from dispatch")
            }
            let chain = try JSONDecoder().decode([EpisodeWorkSettlement].self, from: data(row, 5))
            guard let last = chain.last, last.outcome == .completed, last.observed == EpisodeResources(httpAttempts: 1),
                  let evidenceBytes = last.evidence else { throw invalid("count evidence missing") }
            let evidence = try object(evidenceBytes)
            guard evidence["version"] as? String == "provider-tokenizer-count-v1",
                  equal(evidence["model"], Qwen38TextRendering.modelID), integer(evidence["token_count"]) == tokens,
                  evidence["rendered_sha256"] as? String == digest(Data(rendered.utf8)),
                  equal(evidence["tokenizer_work_id"], workID), equal(evidence["adapter_identity"], adapter) else {
                throw invalid("provider count evidence mismatch")
            }
        }
        guard matches == 1 else { throw invalid("count work not unique") }
        return (tokens, session, clockDomain, ticks)
    }

    private static func validateSelection(database: OpaquePointer, context: [String: Any], body: [String: Any],
        sourceDigest: String, episodeID: String, projectID: String, conversationID: String, humanID: String,
        policy: ContextComponentPolicy, verifySourceRanges: Bool) throws {
        guard let workID = context["selection_work_id"] as? String, !workID.isEmpty, workID.utf8.count <= 256,
              let messages = body["messages"] as? [[String: String]], messages.count >= 2 else { throw invalid("selection snapshot missing") }
        var selection: [String: Any]?
        var selectionRequest: EpisodeWorkRequest?
        try rows(database, """
            SELECT w.episode_id,w.kind,w.adapter_identity,w.state,s.digest,s.payload,w.request_json,w.receipt_json
            FROM episode_work w LEFT JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?
            """, [workID]) { row in
            guard selection == nil, equal(text(row, 0), episodeID), text(row, 1) == "sourceRead",
                  text(row, 2) == "context-source-snapshot-v1", text(row, 3) == "completed",
                  text(row, 4) == sourceDigest, digest(data(row, 5)) == sourceDigest else { throw invalid("selection work mismatch") }
            selection = try object(data(row, 5))
            let request = try JSONDecoder().decode(EpisodeWorkRequest.self, from: data(row, 6))
            let settlements = try JSONDecoder().decode([EpisodeWorkSettlement].self, from: data(row, 7))
            guard request.kind == .sourceRead, request.inputTokensKnown,
                  request.adapterIdentity == "context-source-snapshot-v1", settlements.last?.outcome == .completed,
                  settlements.last?.observed == request.resources else { throw invalid("selection charge linkage mismatch") }
            selectionRequest = request
        }
        guard let selection, selection["version"] as? String == "context-source-snapshot-v1",
              let recentIDs = selection["recent_source_ids"] as? [String], recentIDs.count <= policy.recentCandidates,
              let recent = selection["recent_sources"] as? [[String: Any]], recent.count == recentIDs.count,
              let historical = selection["historical_sources"] as? [[String: Any]], historical.count <= policy.evidenceSpans,
              let binding = selection["binding"] as? [String: Any], binding["version"] as? String == "context-source-snapshot-v1",
              equal(binding["projectID"], projectID), equal(binding["conversationID"], conversationID),
              equal(binding["acceptedHumanEventID"], humanID),
              selection["messages_sha256"] as? String == digest(try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys])),
              binding["mandatoryMessagesSHA256"] as? String == digest(try JSONSerialization.data(withJSONObject: [messages.first!, messages.last!], options: [.sortedKeys])),
              let assignments = selection["assignments"] as? [String], assignments == context["message_components"] as? [String],
              integer(selection["omitted_recent_count"]) == integer(context["omitted_recent_count"]),
              try canonicalArray(historical) == canonicalArray(context["historical_sources"] as? [[String: Any]] ?? []),
              let audit = selection["selection"] as? [String: Any], let deliveredAudit = context["selection"] as? [String: Any],
              try canonical(audit) == canonical(deliveredAudit),
              context["ordered_recent_source_ids_sha256"] as? String == digest(try JSONEncoder().encode(recentIDs)),
              recentIDs.count == integer(context["recent_source_count"]),
              messages.count == recent.count + 2 + (historical.isEmpty ? 0 : 1),
              messages.first?["role"] == "system", messages.last?["role"] == "user",
              try JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys]).count <= policy.maximumMessageBytes,
              try JSONSerialization.data(withJSONObject: Array(messages.dropFirst().prefix(recent.count)), options: [.sortedKeys]).count <= policy.recentBytes else {
            throw invalid("selection provenance mismatch")
        }
        guard selectionRequest?.resources == EpisodeResources(memoryOperations: 1, metadataRows: recent.count + historical.count + 8) else {
            throw invalid("selection work resource mismatch")
        }
        let caps: [String: Int] = ["maximumRecentBytes": policy.recentBytes, "maximumRecentRows": policy.recentCandidates,
            "maximumEvidenceBytes": policy.evidenceBytes, "maximumEvidenceSpans": policy.evidenceSpans,
            "maximumEvidenceSpanBytes": 4096, "maximumSerializedBytes": policy.maximumMessageBytes]
        guard audit["version"] as? String == "context-geometric-v1", caps.allSatisfy({ integer(audit[$0.key]) == $0.value }),
              audit.allSatisfy({ $0.key == "version" || integer($0.value) != nil }),
              integer(selection["omitted_recent_count"]) != nil else { throw invalid("selection limits mismatch") }
        var seen = Set<Data>()
        for (index, source) in recent.enumerated() {
            guard let id = source["eventID"] as? String, equal(id, recentIDs[index]), seen.insert(Data(id.utf8)).inserted,
                  !equal(id, humanID), equal(source["projectID"], projectID), equal(source["conversationID"], conversationID),
                  let role = source["role"] as? String, let status = source["status"] as? String,
                  let length = integer(source["byteCount"]), let hash = source["digest"] as? String,
                  messages[index + 1]["role"] == (role == "human" ? "user" : "assistant"),
                  let content = messages[index + 1]["content"] else { throw invalid("recent source mismatch") }
            let prefix = Data(ContextSourceFraming.recentPrefix(role: role, status: status).utf8), bytes = Data(content.utf8)
            guard bytes.starts(with: prefix), bytes.count - prefix.count == length,
                  digest(Data(bytes.dropFirst(prefix.count))) == hash else { throw invalid("recent source bytes mismatch") }
            try sourceMetadata(database: database, id: id, projectID: projectID, conversationID: conversationID,
                role: role, status: status, createdAt: source["createdAt"] as? String, hash: hash, length: length)
        }
        var humanMatches = 0
        try rows(database, "SELECT digest,byte_count,role,status FROM events WHERE id=? AND project_id=? AND conversation_id=?", [humanID, projectID, conversationID]) { row in
            humanMatches += 1
            let bytes = Data((messages.last?["content"] ?? "").utf8)
            guard text(row, 2) == "human", text(row, 3) == "complete", digest(bytes) == text(row, 0),
                  bytes.count == Int(sqlite3_column_int64(row, 1)) else { throw invalid("accepted request mismatch") }
        }
        guard humanMatches == 1 else { throw invalid("accepted request missing") }
        if !historical.isEmpty {
            let message = messages[recent.count + 1]
            guard message["role"] == "user", let content = message["content"],
                  try JSONSerialization.data(withJSONObject: [message], options: [.sortedKeys]).count <= policy.evidenceBytes else { throw invalid("evidence framing mismatch") }
            let bytes = Data(content.utf8)
            var cursor = 0
            func consume(_ expected: Data) throws {
                guard cursor <= bytes.count, expected.count <= bytes.count - cursor,
                      bytes.subdata(in: cursor..<(cursor + expected.count)) == expected else { throw invalid("evidence framing mismatch") }
                cursor += expected.count
            }
            try consume(Data(ContextSourceFraming.evidencePrefix.utf8))
            for (index, source) in historical.enumerated() {
                if index > 0 { try consume(Data(ContextSourceFraming.evidenceSeparator.utf8)) }
                guard let id = source["event_id"] as? String, !equal(id, humanID), !seen.contains(Data(id.utf8)),
                      equal(source["project_id"], projectID), let sourceConversation = source["conversation_id"] as? String,
                      let role = source["role"] as? String, let status = source["capture_status"] as? String,
                      let created = source["source_created_utc"] as? String, let hash = source["source_sha256"] as? String,
                      let length = integer(source["source_bytes"]), let offset = integer(source["excerpt_offset"]),
                      let excerptBytes = integer(source["excerpt_bytes"]), excerptBytes <= 4096, offset <= length,
                      excerptBytes <= length - offset, let excerptHash = source["excerpt_sha256"] as? String else { throw invalid("historical source mismatch") }
                try sourceMetadata(database: database, id: id, projectID: projectID, conversationID: sourceConversation,
                    role: role, status: status, createdAt: created, hash: hash, length: length)
                try consume(Data(ContextSourceFraming.evidenceHeader(eventID: id, conversationID: sourceConversation,
                    role: role, status: status, createdAt: created, digest: hash, offset: offset, totalBytes: length).utf8))
                guard excerptBytes <= bytes.count - cursor else { throw invalid("excerpt bytes missing") }
                let excerpt = bytes.subdata(in: cursor..<(cursor + excerptBytes))
                guard String(data: excerpt, encoding: .utf8) != nil, digest(excerpt) == excerptHash else { throw invalid("excerpt digest mismatch") }
                if verifySourceRanges {
                    var matches = 0
                    try rows(database, "SELECT substr(payload,?,?) FROM events WHERE id=? AND project_id=? AND conversation_id=?",
                        [String(offset + 1), String(excerptBytes), id, projectID, sourceConversation]) { row in
                        matches += 1
                        guard data(row, 0) == excerpt else { throw invalid("excerpt source range mismatch") }
                    }
                    guard matches == 1 else { throw invalid("excerpt source range missing") }
                }
                cursor += excerptBytes
                try consume(Data(ContextSourceFraming.evidenceFooter.utf8))
            }
            guard cursor == bytes.count else { throw invalid("extra evidence bytes") }
        }
    }

    private static func sourceMetadata(database: OpaquePointer, id: String, projectID: String, conversationID: String,
        role: String, status: String, createdAt: String?, hash: String, length: Int) throws {
        var matches = 0
        try rows(database, "SELECT role,status,created_at,digest,byte_count FROM events WHERE id=? AND project_id=? AND conversation_id=?", [id, projectID, conversationID]) { row in
            matches += 1
            guard equal(text(row, 0), role), equal(text(row, 1), status), equal(text(row, 2), createdAt ?? ""),
                  text(row, 3) == hash, Int(sqlite3_column_int64(row, 4)) == length else { throw invalid("source metadata mismatch") }
        }
        guard matches == 1 else { throw invalid("source metadata missing") }
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, _ bindings: [String], _ body: (OpaquePointer) throws -> Void) throws {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else { throw invalid("query failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            guard binding.withCString({ sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(binding.utf8.count), transient) }) == SQLITE_OK else {
                throw invalid("query binding failed")
            }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw invalid("query failed") }
            try body(statement)
        }
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard !bytes.isEmpty, bytes.count <= MemoryStore.maximumPayloadBytes,
              let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw invalid("metadata malformed") }
        return value
    }
    private static func canonical(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func canonicalArray(_ value: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(row, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(row, column))), as: UTF8.self)
    }
    private static func data(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, column)))
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
        return number.intValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }
    private static func equal(_ left: Any?, _ right: String) -> Bool {
        guard let left = left as? String else { return false }
        return episodeIdentifierEqual(left, right)
    }
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func invalid(_ reason: String) -> MemoryError { .database("component journal " + reason) }
}
