import Foundation
import CSQLite

/// Complete original text inputs for the selected-Qwen legacy answering path.
/// The original records/ranges remain in the immutable selection journal. This
/// compact closure checksum grants no task, policy, route or dispatch authority.
struct AuthorityInputProof: Codable {
    let version: String
    let classification: AuthorityBindingClassification
    let episodeID: String
    let projectID: String
    let conversationID: String
    let acceptedHumanEventID: String
    let endpoint: String
    let requestBodySHA256: String
    let hostInstructionsSHA256: String
    let messagesSHA256: String
    let componentProofSHA256: String
    let sourceSelectionWorkID: String
    let sourceSelectionSHA256: String
    let sourceDependenciesSHA256: String
    let sourceDependencyCount: Int
}

struct AnswerInputProofReceipt {
    let operationID: String
    let digest: String
    let proof: AuthorityInputProof
}

enum AuthorityInputProofJournal {
    static let version = "selected-qwen-original-input-v1"
    static let maximumDependencies = 512
    struct Funding: Codable {
        let version: String
        let episodeID: String
        let requestBodySHA256: String
        let hostInstructionsSHA256: String
        let componentProofSHA256: String
        let contextAuditSHA256: String
        let bodyBytes: Int
        let admissionBytes: Int
    }
    static func resources(bodyBytes: Int, admissionBytes: Int) throws -> EpisodeResources {
        guard (1...2 * 1_048_576).contains(bodyBytes), (1...65536).contains(admissionBytes) else { throw AuthorityStateError.limit }
        // Covers parsing/serialization, retained selection and count snapshots,
        // source metadata points and bounded original historical range reads.
        return EpisodeResources(memoryOperations: 1,
            rawSourceBytes: 12 * bodyBytes + 8 * admissionBytes + 4 * 1_048_576,
            metadataRows: 8 * maximumDependencies + 128)
    }
    static func funding(episodeID: String, body: Data, admission: Data, host: String) throws -> Funding {
        _ = try resources(bodyBytes: body.count, admissionBytes: admission.count)
        guard host.utf8.count <= 131072 else { throw AuthorityStateError.limit }
        let audit = try object(admission)
        guard let receipt = audit["receipt"] as? [String: Any], let component = receipt["componentProof"],
              let context = audit["context"] as? String, let contextBytes = Data(base64Encoded: context) else { throw AuthorityStateError.integrity }
        return Funding(version: "selected-qwen-original-input-funding-v1", episodeID: episodeID,
            requestBodySHA256: digest(body), hostInstructionsSHA256: digest(Data(host.utf8)),
            componentProofSHA256: digest(try canonicalObject(component)), contextAuditSHA256: digest(contextBytes),
            bodyBytes: body.count, admissionBytes: admission.count)
    }
    static func derive(database: OpaquePointer, funding: Funding, body: Data, provider: String,
                       admission: Data, answerRequest: EpisodeWorkRequest, verifySourceRanges: Bool = true) throws -> AuthorityInputProof {
        guard funding.version == "selected-qwen-original-input-funding-v1", funding.bodyBytes == body.count,
              funding.requestBodySHA256 == digest(body) else { throw AuthorityStateError.integrity }
        _ = try resources(bodyBytes: funding.bodyBytes, admissionBytes: funding.admissionBytes)
        let scope = try AuthorityStateKernel.rows(database,
            "SELECT project_id,conversation_id,human_event_id FROM episodes WHERE id=?", [.text(funding.episodeID)])
        guard scope.count == 1, !scope[0][1].isNull, !scope[0][2].isNull,
              try AuthorityBindings.read(database: database, table: AuthorityBindings.tableNames[0],
                id: funding.episodeID, type: AuthorityEpisodeBinding.self)?.classification == .legacyUnbound else { throw AuthorityStateError.unauthorized }
        let project = scope[0][0].string, conversation = scope[0][1].string, human = scope[0][2].string
        try ContextComponentJournal.validatePrepared(database: database, episodeID: funding.episodeID, projectID: project,
            conversationID: conversation, humanEventID: human, body: body, providerIdentity: provider,
            admissionJSON: admission, answerRequest: answerRequest, verifySourceRanges: verifySourceRanges)
        let audit = try object(admission), payload = try object(body)
        guard let receipt = audit["receipt"] as? [String: Any], let component = receipt["componentProof"],
              digest(try canonicalObject(component)) == funding.componentProofSHA256,
              let encodedContext = audit["context"] as? String, let contextBytes = Data(base64Encoded: encodedContext),
              digest(contextBytes) == funding.contextAuditSHA256,
              let messages = payload["messages"] as? [[String: String]], let system = messages.first?["content"],
              let route = URLComponents(string: provider), route.scheme == "http",
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(route.host ?? ""),
              route.user == nil, route.password == nil, route.query == nil, route.fragment == nil else { throw AuthorityStateError.integrity }
        let systemBytes = Data(system.utf8)
        let framing = Data(ContextAssembler.mandatoryMessages(prompt: "", system: "")[0].content.utf8)
        let separator = Data("\n\n".utf8) + framing
        let host: Data
        if systemBytes == framing { host = Data() }
        else {
            guard systemBytes.count > separator.count, systemBytes.suffix(separator.count) == separator else { throw AuthorityStateError.integrity }
            host = Data(systemBytes.dropLast(separator.count))
        }
        guard digest(host) == funding.hostInstructionsSHA256 else { throw AuthorityStateError.integrity }
        let context = try object(contextBytes)
        guard let selectionID = context["selection_work_id"] as? String,
              let selectionDigest = context["source_snapshot_sha256"] as? String else { throw AuthorityStateError.integrity }
        let selectionRows = try AuthorityStateKernel.rows(database,
            "SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=? AND w.episode_id=?",
            [.text(selectionID), .text(funding.episodeID)])
        guard selectionRows.count == 1, let selectionBytes = selectionRows[0][0].bytes,
              selectionBytes.count <= 4 * 1_048_576, digest(selectionBytes) == selectionDigest else { throw AuthorityStateError.integrity }
        let selection = try object(selectionBytes)
        guard let recent = selection["recent_sources"] as? [[String: Any]],
              let historical = selection["historical_sources"] as? [[String: Any]],
              recent.count + historical.count + 1 <= maximumDependencies else { throw AuthorityStateError.limit }
        var dependencies: [Data: AuthoritySourceDependency] = [:]
        func append(_ id: String, offset: Int = 0, length: Int? = nil, excerpt: String? = nil) throws {
            let source = try source(database: database, id: id, dated: selection["version"] as? String == ContextSourceFraming.currentSelectionVersion)
            guard episodeIdentifierEqual(source.projectID, project) else { throw AuthorityStateError.integrity }
            let count = length ?? source.byteCount
            guard offset >= 0, count >= 0, offset <= source.byteCount, count <= source.byteCount - offset,
                  AuthorityBindings.isDigest(excerpt ?? source.digest) else { throw AuthorityStateError.integrity }
            let dependency = AuthoritySourceDependency(source: source, offset: offset, byteLength: count, excerptSHA256: excerpt ?? source.digest)
            dependencies[try AuthorityStateKernel.canonical(dependency)] = dependency
        }
        try append(human)
        for item in recent {
            guard let id = item["eventID"] as? String else { throw AuthorityStateError.integrity }
            try append(id)
        }
        for item in historical {
            guard let id = item["event_id"] as? String, let offset = item["excerpt_offset"] as? Int,
                  let length = item["excerpt_bytes"] as? Int, let excerpt = item["excerpt_sha256"] as? String else { throw AuthorityStateError.integrity }
            try append(id, offset: offset, length: length, excerpt: excerpt)
        }
        let union = dependencies.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value)
        return AuthorityInputProof(version: version, classification: .legacyUnbound, episodeID: funding.episodeID,
            projectID: project, conversationID: conversation, acceptedHumanEventID: human, endpoint: provider,
            requestBodySHA256: digest(body), hostInstructionsSHA256: funding.hostInstructionsSHA256,
            messagesSHA256: digest(try canonicalObject(messages)), componentProofSHA256: funding.componentProofSHA256,
            sourceSelectionWorkID: selectionID, sourceSelectionSHA256: selectionDigest,
            sourceDependenciesSHA256: digest(try AuthorityStateKernel.canonical(union)), sourceDependencyCount: union.count)
    }
    static func validateStored(database: OpaquePointer, episodeID: String, body: Data, provider: String,
        admission: Data, answerRequest: EpisodeWorkRequest, verifySourceRanges: Bool) throws {
        guard !admission.isEmpty else { return }
        let audit = try object(admission)
        let auditVersion = audit["version"] as? Int
        let workID = audit["inputProofWorkID"] as? String, proofDigest = audit["inputProofSHA256"] as? String
        guard auditVersion == 3 || workID == nil && proofDigest == nil else { throw AuthorityStateError.integrity }
        guard auditVersion == 3 else { return }
        guard let workID, let proofDigest, AuthorityBindings.isDigest(proofDigest),
              Set(audit.keys).isSubset(of: ["version", "receipt", "attempts", "nativeConfiguration", "context", "inputProofWorkID", "inputProofSHA256"]) else { throw AuthorityStateError.integrity }
        let work = try AuthorityStateKernel.rows(database,
            "SELECT w.episode_id,w.kind,w.adapter_identity,w.state,w.request_json,w.receipt_json,s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(workID)])
        guard work.count == 1, episodeIdentifierEqual(work[0][0].string, episodeID), work[0][1].string == "sourceRead",
              work[0][2].string == version, work[0][3].string == "completed", let requestBytes = work[0][4].bytes,
              let chainBytes = work[0][5].bytes, let descriptor = work[0][6].bytes else { throw AuthorityStateError.integrity }
        let funding = try AuthorityStateKernel.decode(Funding.self, descriptor)
        let request = try JSONDecoder().decode(EpisodeWorkRequest.self, from: requestBytes)
        let chain = try JSONDecoder().decode([EpisodeWorkSettlement].self, from: chainBytes)
        guard episodeIdentifierEqual(funding.episodeID, episodeID), episodeIdentifierEqual(request.id, workID),
              request.adapterIdentity == version, request.snapshot == nil, request.inputTokensKnown, request.kind == .sourceRead,
              request.resources == (try resources(bodyBytes: funding.bodyBytes, admissionBytes: funding.admissionBytes)),
              let last = chain.last, last.outcome == .completed, last.observed == request.resources,
              let proofBytes = last.evidence, digest(proofBytes) == proofDigest else { throw AuthorityStateError.integrity }
        let proof = try AuthorityStateKernel.decode(AuthorityInputProof.self, proofBytes)
        let derived = try derive(database: database, funding: funding, body: body, provider: provider,
            admission: admission, answerRequest: answerRequest, verifySourceRanges: verifySourceRanges)
        guard try AuthorityStateKernel.canonical(proof) == AuthorityStateKernel.canonical(derived) else { throw AuthorityStateError.integrity }
    }
    private static func source(database: OpaquePointer, id: String, dated: Bool) throws -> MemorySourceReference {
        let sql = "SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count"
            + (dated ? ",source_time_json" : "") + " FROM events WHERE id=?"
        let rows = try AuthorityStateKernel.rows(database, sql, [.text(id)])
        guard rows.count == 1, let role = MemoryRole(rawValue: rows[0][4].string), let status = CaptureStatus(rawValue: rows[0][5].string) else { throw AuthorityStateError.integrity }
        let result = MemorySourceReference(sequence: rows[0][0].integer, eventID: rows[0][1].string,
            conversationID: rows[0][2].string, projectID: rows[0][3].string, role: role, status: status,
            createdAt: rows[0][6].string, digest: rows[0][7].string, byteCount: rows[0][8].integer,
            sourceTime: dated ? try rows[0][9].bytes.map { try EventSourceTime.decodeCanonical($0) } : nil)
        try AuthorityBindings.validateSource(database: database, source: result, verifyBytes: false)
        return result
    }
    private static func object(_ bytes: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw AuthorityStateError.integrity }
        return result
    }
    private static func canonicalObject(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private static func digest(_ bytes: Data) -> String { AuthorityStateKernel.digest(bytes) }
}
