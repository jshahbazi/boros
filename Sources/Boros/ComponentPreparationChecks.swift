import Foundation
import CSQLite
import Darwin

/// Exercises the actual coordinator against a declared synthetic tokenizer.
/// The fixture controls count completion with barriers, never real model data.
enum ComponentPreparationChecks {
    static func run(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        let suite = Suite(baseURL: baseURL, completion: completion)
        suite.next()
    }

    private enum Case: String, CaseIterable {
        case mandatory, scope, boundary, pipeline, envelope, httpLimit, cancel, deadline
        case identityModel, identityTemplate, identityRuntime
        case legacyVersion, identityVersion
        case jsonCapability
        case neighborhood, neighborhoodEnvelope, neighborhoodRecentOnly
        case neighborhoodAuditDated, neighborhoodAuditFit
        /// The pipeline fixture under the V4 quoted framing. `.pipeline`
        /// itself is pinned to V3 so the old format keeps its full coverage.
        case quotedPipeline
    }
    private final class Clock: EpisodeClockSource {
        private let lock = NSLock()
        private var ticks: UInt64 = 1_000_000_000
        func expire() { lock.lock(); ticks = 200_000_000_000; lock.unlock() }
        func now() throws -> EpisodeClockSnapshot {
            lock.lock(); defer { lock.unlock() }
            return EpisodeClockSnapshot(domain: "synthetic-component-preparation-clock", continuousNanoseconds: ticks, utc: Date())
        }
    }
    private final class Suite {
        let baseURL: String
        let completion: ([String: Bool]) -> Void
        var cases = Array(Case.allCases)
        var checks: [String: Bool] = [:]
        var current: Attempt?
        init(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.completion = completion
        }
        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            do {
                let attempt = try Attempt(kind: kind, baseURL: baseURL) { [self] result in
                    checks.merge(result) { _, latest in latest }
                    current = nil
                    next()
                }
                current = attempt
                attempt.start()
            } catch {
                checks["component_preparation_\(kind.rawValue)_fixture_started"] = false
                next()
            }
        }
    }
    private final class Attempt {
        let kind: Case
        let baseURL: String
        let directory: URL
        let store: MemoryStore
        let chat: StoredConversation
        let clock = Clock()
        let lease: EpisodeLease
        let currentID: String
        let prompt: String
        let completion: ([String: Bool]) -> Void
        var settings = GenerationSettings()
        var operation: ComponentContextPreparationOperation?
        var legacySession: ProviderComponentSession?
        var completed = false
        private var inputProof: AnswerInputProofReceipt?
        private var failureStage = "preparation_audit"
        let droppedSourceID: String

        init(kind: Case, baseURL: String, completion: @escaping ([String: Bool]) -> Void) throws {
            self.kind = kind; self.baseURL = baseURL; self.completion = completion
            guard let resolvedTemporary = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw MemoryError.database("synthetic fixture temporary path resolution failed")
            }
            let temporaryPath = String(cString: resolvedTemporary)
            free(resolvedTemporary)
            directory = URL(fileURLWithPath: temporaryPath, isDirectory: true)
                .appendingPathComponent("boros-preparation-" + UUID().uuidString, isDirectory: true)
            store = try MemoryStore(directory: directory)
            chat = try store.createConversation(projectID: kind == .neighborhoodAuditDated
                ? "synthetic-audit-" + String(repeating: "p", count: 240) : "synthetic-preparation", title: "Synthetic component preparation")
            currentID = "fixture-current-" + kind.rawValue
            droppedSourceID = "fixture-" + kind.rawValue + "-recent-0"
            let marker: String
            switch kind {
            case .mandatory: marker = "fixtureMandatory"
            case .boundary: marker = "fixtureBoundary"
            case .cancel: marker = "fixtureBarrierCancel"
            case .deadline: marker = "fixtureBarrierDeadline"
            case .identityModel: marker = "fixtureIdentityModel"
            case .identityTemplate: marker = "fixtureIdentityTemplate"
            case .identityRuntime: marker = "fixtureIdentityRuntime"
            default: marker = "fixturePipeline"
            }
            prompt = marker + " Where is pipelinekey?"
            if kind == .pipeline || kind == .quotedPipeline || kind == .envelope || kind == .boundary || kind == .httpLimit {
                let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic original spans")
                for index in 0..<(kind == .boundary ? 3 : 5) {
                    let prefix = "pipelinekey archived source \(index) "
                    let text = prefix + String(repeating: " filler", count: (4096 - prefix.utf8.count) / 7)
                    _ = try store.append(conversationID: archive.id, role: .human, text: text, status: .complete,
                        turnID: "fixture-archive-turn-\(index)", eventID: "fixture-\(kind.rawValue)-archive-\(index)")
                }
            }
            if kind == .neighborhood || kind == .neighborhoodEnvelope || kind == .neighborhoodRecentOnly {
                let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic neighborhood evidence")
                for (index, role) in [MemoryRole.assistant, .human, .assistant].enumerated() {
                    _ = try store.append(conversationID: archive.id, role: role,
                        text: index == 1 ? "pipelinekey synthetic original request" : "Synthetic immediate neighboring answer \(index)",
                        status: index == 0 ? .partial : .complete, turnID: "fixture-neighborhood-turn-\(index)",
                        eventID: "fixture-\(kind.rawValue)-archive-\(index)")
                }
            }
            if kind == .neighborhoodAuditDated || kind == .neighborhoodAuditFit {
                for primary in 0..<16 {
                    let archive = try store.createConversation(projectID: chat.projectID, title: "Synthetic bounded audit evidence")
                    for (index, role) in [MemoryRole.assistant, .human, .assistant].enumerated() {
                        let prefix = "fixture-\(kind.rawValue)-archive-\(primary)-\(index)-"
                        let eventID = kind == .neighborhoodAuditDated
                            ? prefix + String(repeating: "e", count: 256 - prefix.utf8.count) : prefix
                        _ = try store.append(conversationID: archive.id, role: role,
                            text: index == 1 ? "pipelinekey original primary \(primary)" : "Adjacent original response \(index)",
                            status: index == 0 ? .partial : .complete, turnID: "fixture-audit-turn-\(primary)-\(index)",
                            eventID: eventID, sourceTime: kind == .neighborhoodAuditDated ? try Self.syntheticDate("2023-05-30") : nil)
                    }
                }
            }
            let count = kind == .neighborhood || kind == .neighborhoodEnvelope || kind == .neighborhoodAuditDated || kind == .neighborhoodAuditFit ? 0
                : kind == .boundary || kind == .legacyVersion || kind == .identityVersion || kind == .neighborhoodRecentOnly ? 2 : (kind == .cancel || kind == .deadline
                || kind == .identityModel || kind == .identityTemplate || kind == .identityRuntime) ? 1 : 7
            for index in 0..<count {
                let text = kind == .cancel || kind == .deadline ? marker + " recent source"
                    : index == 0 ? "pipelinekey original recent decision" : "Synthetic recent source \(index)"
                _ = try store.append(conversationID: chat.id, role: index % 2 == 0 ? .human : .assistant,
                    text: text, status: index == 3 || ((kind == .legacyVersion || kind == .identityVersion) && index == 1) ? .partial : .complete,
                    turnID: "fixture-recent-turn-\(index)", eventID: "fixture-\(kind.rawValue)-recent-\(index)", sourceTime: kind == .pipeline || kind == .quotedPipeline ? try Self.syntheticDate("2023-05-30") : nil)
            }
            let episodeID = UUID().uuidString
            var limits = EpisodeLimits(); limits.componentPolicy = .selectedQwen
            if kind == .neighborhood || kind == .neighborhoodEnvelope || kind == .neighborhoodRecentOnly
                || kind == .neighborhoodAuditDated || kind == .neighborhoodAuditFit {
                limits.componentPolicy = .selectedQwenNeighborhood
            }
            if kind == .httpLimit { limits.resources.httpAttempts = 4 }
            _ = try store.acceptRequestAndBeginEpisode(conversationID: chat.id, turnID: "fixture-current-turn",
                humanEventID: currentID, episodeID: episodeID, text: prompt, limits: limits, clock: clock.now())
            lease = EpisodeLease(ledger: store, episodeID: episodeID, clock: clock)
            settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.endpointModel = Qwen38TextAdapter.modelID; settings.maximumOutput = 64
            settings.endpointSafetyTokens = 256; settings.endpointContextLimit = kind == .envelope || kind == .neighborhoodEnvelope ? 9000 : 32768
            settings.temperature = 0; settings.episodeLease = lease
            settings.endpointJSONOutput = kind == .jsonCapability
            // `.pipeline` keeps full V3 coverage. The synthetic tokenizer
            // oracle keys the boundary and audit-size fixtures on event IDs
            // that only V1 to V3 show to the model, so they also stay on V3.
            if [.pipeline, .boundary, .neighborhoodAuditDated, .neighborhoodAuditFit].contains(kind) {
                settings.contextFraming = ContextSourceFraming.currentSelectionVersion
            }
            switch kind {
            case .identityModel: settings.endpointAPIKey = "synthetic-component-model-drift"
            case .identityTemplate: settings.endpointAPIKey = "synthetic-component-template-drift"
            case .identityRuntime: settings.endpointAPIKey = "synthetic-component-version-drift"
            default: break
            }
        }
        private static func syntheticDate(_ literal: String) throws -> EventSourceTime {
            let value = try EventSourceTime.normalize(literal)
            return try EventSourceTime(value: value.value, precision: value.precision, timezone: value.timezone,
                sourceSHA256: String(repeating: "b", count: 64), locator: "/synthetic/time", originalValue: literal).validated()
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func start() {
            if kind == .legacyVersion || kind == .identityVersion { startLegacy(); return }
            let preparation = ComponentContextPreparationOperation(store: store, conversationID: chat.id,
                projectID: chat.projectID, humanEventID: kind == .scope ? "fixture-foreign-human" : currentID,
                prompt: prompt, settings: settings,
                conversation: Conversation(), semanticIndex: nil,
                retrievalStrategy: kind == .neighborhoodRecentOnly ? .recentOnly : .hybrid,
                episodeLease: lease) { [self] outcome in finish(outcome) }
            operation = preparation
            if kind == .cancel || kind == .deadline { installBarrierObserver() }
            preparation.start()
        }
        /// Actual V1 and V2 bytes are independently rendered, counted, admitted,
        /// archived and restored. No counted V3 proof is relabelled.
        private func startLegacy() {
            do {
                var mandatory = settings
                // V1 and V2 used the same System framing as V3.
                mandatory.messagesOverride = ContextAssembler.mandatoryMessages(prompt: prompt, system: settings.system,
                    selectionVersion: ContextSourceFraming.currentSelectionVersion)
                    .map { ["role": $0.role, "content": $0.content] }
                let mandatoryBody = try EndpointRequest.build(prompt: prompt, settings: mandatory, conversation: Conversation())
                legacySession = ProviderAdmission.beginComponentSession(mandatoryBody: mandatoryBody,
                    address: settings.endpointURL, apiKey: settings.endpointAPIKey, contextLimit: settings.endpointContextLimit,
                    safetyTokens: settings.endpointSafetyTokens, episodeLease: lease) { [self] outcome in
                    switch outcome {
                    case .failure(let error): finish(.failure(error))
                    case .success(let session):
                        do {
                            let selected = try ContextAssembler.prepareRecent(store: store, conversationID: chat.id,
                                projectID: chat.projectID, prompt: prompt, system: settings.system,
                                excludingEventID: currentID, episodeLease: lease,
                                selectionVersion: ContextSourceFraming.currentSelectionVersion)
                            let originals = try store.events(conversationID: chat.id).filter { !episodeIdentifierEqual($0.id, currentID) }
                            let selectionVersion = kind == .legacyVersion ? ContextSourceFraming.legacySelectionVersion : ContextSourceFraming.identitySelectionVersion
                            let legacyMessages = [selected.messages[0]] + (try originals.map {
                                ContextMessage(role: $0.role == .human ? "user" : "assistant",
                                    content: try ContextSourceFraming.recentPrefix(eventID: $0.id, role: $0.role.rawValue, status: $0.status.rawValue, selectionVersion: selectionVersion) + $0.text)
                            }) + [selected.messages.last!]
                            var binding = selected.selectionBinding!
                            binding.version = selectionVersion
                            let snapshot = ContextSnapshot(messages: legacyMessages, evidence: [],
                                serializedBytes: try ContextAssembler.serializedMessages(legacyMessages).count,
                                omittedRecentCount: selected.omittedRecentCount, includedRecentCount: selected.includedRecentCount,
                                recentSourceIDs: selected.recentSourceIDs, recentSources: selected.recentSources,
                                selectionBinding: binding, selectionAudit: selected.selectionAudit)
                            var ready = settings
                            ready.messagesOverride = legacyMessages.map { ["role": $0.role, "content": $0.content] }
                            let body = try EndpointRequest.build(prompt: prompt, settings: ready, conversation: Conversation())
                            let assignment: [ProviderMessageComponent] = try snapshot.componentAssignments().map {
                                switch $0 { case .mandatory: return .mandatory; case .recent: return .recent; case .historicalEvidence: return .evidence }
                            }
                            let policyDigest = EndpointRequest.digest(try ContextComponentPolicy.selectedQwen.canonicalData())
                            let sourceDigest = try snapshot.selectionDigest()
                            session.countComponent(requestBody: body, assignments: assignment, component: .recent) { [self] recentOutcome in
                                switch recentOutcome {
                                case .failure(let error): finish(.failure(error))
                                case .success(let recent):
                                    session.countComponent(requestBody: body, assignments: assignment, component: .evidence) { [self] evidenceOutcome in
                                        switch evidenceOutcome {
                                        case .failure(let error): finish(.failure(error))
                                        case .success(let evidence):
                                            session.admit(requestBody: body, assignments: assignment, sourceSnapshotDigest: sourceDigest,
                                                policyDigest: policyDigest, recentReceipt: recent, evidenceReceipt: evidence) { [self] admitted in
                                                switch admitted {
                                                case .failure(let error): finish(.failure(error))
                                                case .success(let receipt):
                                                    do {
                                                        var audited = snapshot
                                                        audited.componentAuditJSON = try receipt.componentProof.map { try JSONEncoder().encode($0) }
                                                        let resources = EpisodeResources(memoryOperations: 1, metadataRows: snapshot.recentSources.count + 8)
                                                        let work = try lease.prepare(kind: .sourceRead, resources: resources,
                                                            adapterIdentity: selectionVersion, snapshot: snapshot.selectionEvidence())
                                                        let submitted = try lease.dispatch(work, start: {})
                                                        _ = try lease.settle(submitted, outcome: .completed, observed: resources)
                                                        audited.selectionWorkID = work.id
                                                        var finalSettings = ready
                                                        finalSettings.preparedEndpointBody = body; finalSettings.endpointAdmission = receipt
                                                        finalSettings.preparedContextComponents = ContextComponentDispatchBinding(assignments: assignment,
                                                            sourceSnapshotDigest: sourceDigest, policyDigest: policyDigest)
                                                        session.close(); legacySession = nil
                                                        finish(.success(PreparedComponentContext(snapshot: audited, settings: finalSettings,
                                                            body: body, receipt: receipt)))
                                                    } catch { finish(.failure(error)) }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } catch { finish(.failure(error)) }
                    }
                }
            } catch { finish(.failure(error)) }
        }
        private func installBarrierObserver() {
            guard let base = LocalEndpoint.chatURL(baseURL), var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
            parts.path = "/fixture-wait"; parts.queryItems = [URLQueryItem(name: "case", value: kind.rawValue)]
            guard let url = parts.url else { return }
            var request = URLRequest(url: url); request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { [self] data, response, error in
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      object["ready"] as? Bool == true else {
                    operation?.cancel(); return
                }
                if kind == .cancel { operation?.cancel() }
                else { clock.expire() }
                var releaseParts = parts
                releaseParts.path = "/fixture-release"
                guard let releaseURL = releaseParts.url else { operation?.cancel(); return }
                var releaseRequest = URLRequest(url: releaseURL); releaseRequest.httpMethod = "POST"
                releaseRequest.timeoutInterval = 10
                URLSession.shared.dataTask(with: releaseRequest) { _, _, _ in }.resume()
            }.resume()
        }
        private func journalInventory() throws -> (episodes: Int, invocations: Int, answerWork: Int, tokenizerWork: Int, generativeTokenizerWork: Int) {
            var database: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &database,
                SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else { throw MemoryError.database("synthetic ledger inventory failed") }
            defer { sqlite3_close(database) }
            func count(_ sql: String) throws -> Int {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw MemoryError.database("synthetic inventory query failed") }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw MemoryError.database("synthetic inventory read failed") }
                return Int(sqlite3_column_int64(statement, 0))
            }
            return (try count("SELECT count(*) FROM episodes"), try count("SELECT count(*) FROM invocations"),
                try count("SELECT count(*) FROM episode_work WHERE kind='answer'"),
                try count("SELECT count(*) FROM episode_work WHERE kind='tokenizer'"),
                try count("SELECT count(*) FROM episode_work WHERE kind='tokenizer' AND (json_extract(charged_json,'$.inputTokens')!=0 OR json_extract(charged_json,'$.outputTokens')!=0 OR json_extract(charged_json,'$.modelCalls')!=0 OR json_extract(request_json,'$.resources.inputTokens')!=0 OR json_extract(request_json,'$.resources.outputTokens')!=0 OR json_extract(request_json,'$.resources.modelCalls')!=0)"))
        }
        private struct AdmissionAudit: Codable {
            let version: Int
            let receipt: EndpointAdmissionReceipt
            let attempts: [ProviderAdmissionAccounting]
            let context: Data
            var inputProofWorkID: String? = nil
            var inputProofSHA256: String? = nil
        }
        private func validateJournal() throws {
            var raw: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw,
                SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database = raw else {
                if let raw { sqlite3_close(raw) }
                throw MemoryError.database("synthetic journal preflight open failed")
            }
            defer { sqlite3_close(database) }
            try MemoryStore.validateEpisodeJournal(database: database)
        }
        private func capturePrepared(_ prepared: PreparedComponentContext) throws {
            failureStage = "answer_reservation"
            let work = try lease.prepare(kind: .answer,
                resources: EpisodeResources(inputTokens: prepared.receipt.promptTokens, outputTokens: prepared.receipt.outputReserve,
                    modelCalls: 1, httpAttempts: 1), adapterIdentity: prepared.receipt.answerAdapterIdentity, snapshot: prepared.body)
            failureStage = "admission_encoding"
            let admission = try JSONEncoder().encode(AdmissionAudit(version: inputProof == nil ? 2 : 3, receipt: prepared.receipt,
                attempts: prepared.receipt.accounting.map { [$0] } ?? [], context: prepared.snapshot.deliveryAudit(),
                inputProofWorkID: inputProof?.operationID, inputProofSHA256: inputProof?.digest))
            failureStage = "invocation_admission"
            _ = try store.beginInvocation(invocationID: "fixture-invocation", conversationID: chat.id, turnID: "fixture-current-turn",
                humanEventID: currentID, assistantEventID: "fixture-assistant", providerIdentity: prepared.receipt.endpoint,
                requestBody: prepared.body, admissionJSON: admission, episodeID: lease.episodeID, episodeWorkID: work.id)
            failureStage = "episode_terminalization"
            _ = try lease.finish(reason: .cancelled)
            failureStage = "invocation_terminalization"
            _ = try store.finalizeInvocation(invocationID: "fixture-invocation", status: .cancelled, reason: .cancelled)
        }
        private func inputProofEvidence(_ workID: String, directory: URL) throws -> Data? {
            var raw: OpaquePointer?
            guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let database = raw else { if let raw { sqlite3_close(raw) }; throw MemoryError.database("synthetic input proof evidence open failed") }
            defer { sqlite3_close(database) }
            var rawStatement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT receipt_json FROM episode_work WHERE id=?", -1, &rawStatement, nil) == SQLITE_OK,
                  let statement = rawStatement else { throw MemoryError.database("synthetic input proof evidence query failed") }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard workID.withCString({ sqlite3_bind_text(statement, 1, $0, Int32(workID.utf8.count), transient) }) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
                throw MemoryError.database("synthetic input proof evidence missing")
            }
            let chain = try JSONDecoder().decode([EpisodeWorkSettlement].self,
                from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            return chain.last?.evidence
        }
        private func inputProofChecks(_ prepared: PreparedComponentContext) throws -> [String: Bool] {
            guard [.pipeline, .quotedPipeline, .boundary, .envelope].contains(kind) else { return [:] }
            failureStage = "original_input_proof"
            let prefix = "component_preparation_" + kind.rawValue + "_input_proof"
            let admission = try JSONEncoder().encode(AdmissionAudit(version: 2, receipt: prepared.receipt,
                attempts: prepared.receipt.accounting.map { [$0] } ?? [], context: prepared.snapshot.deliveryAudit()))
            let request = EpisodeWorkRequest(id: "fixture-proof-answer", parentID: nil, kind: .answer,
                resources: EpisodeResources(inputTokens: prepared.receipt.promptTokens, outputTokens: prepared.receipt.outputReserve,
                    modelCalls: 1, httpAttempts: 1), adapterIdentity: prepared.receipt.answerAdapterIdentity,
                snapshot: prepared.body, inputTokensKnown: true)
            var checks: [String: Bool] = [:]
            let original = try lease.checkActive()
            if kind == .pipeline || kind == .quotedPipeline {
                var oversizedDenied = false
                do { _ = try store.prepareAnswerInputProof(lease: lease, requestBody: prepared.body,
                    providerIdentity: prepared.receipt.endpoint, admissionJSON: admission, answerRequest: request,
                    hostInstructions: String(repeating: "x", count: 131073)) } catch { oversizedDenied = true }
                let afterRefusal = try lease.checkActive()
                checks[prefix + "_oversized_host_refused_before_inspection"] = oversizedDenied
                    && afterRefusal.charged == original.charged
                let receipt = try store.prepareAnswerInputProof(lease: lease, requestBody: prepared.body,
                    providerIdentity: prepared.receipt.endpoint, admissionJSON: admission, answerRequest: request,
                    hostInstructions: prepared.settings.system)
                inputProof = receipt
                let proof = receipt.proof
                let after = try lease.checkActive()
                let resources = try AuthorityInputProofJournal.resources(bodyBytes: prepared.body.count, admissionBytes: admission.count)
                checks[prefix + "_original_allowance_funds_exact_declared_work"] = try after.charged == original.charged.adding(resources)
                    && after.held == original.held && after.limits == original.limits
                let retained = try store.episodeWork(episodeID: lease.episodeID, operationID: receipt.operationID)
                let proofBytes = try AuthorityStateKernel.canonical(proof)
                checks[prefix + "_durable_completed_evidence_is_bound"] = try retained?.state == .completed
                    && retained?.request.kind == .sourceRead && retained?.request.adapterIdentity == AuthorityInputProofJournal.version
                    && retained?.charged == resources && retained?.observed == resources
                    && retained?.request.snapshot != nil && retained?.held == .zero
                    && ContextSnapshot.digest(proofBytes) == receipt.digest && proofBytes.count <= 16384
                    && inputProofEvidence(receipt.operationID, directory: directory) == proofBytes
                let body = try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any]
                let component = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared.receipt.componentProof!))
                checks[prefix + "_actual_body_host_and_count_hashes"] = try proof.requestBodySHA256 == ContextSnapshot.digest(prepared.body)
                    && proof.hostInstructionsSHA256 == ContextSnapshot.digest(Data(prepared.settings.system.utf8))
                    && proof.messagesSHA256 == ContextSnapshot.digest(JSONSerialization.data(withJSONObject: body["messages"]!, options: [.sortedKeys]))
                    && proof.componentProofSHA256 == ContextSnapshot.digest(JSONSerialization.data(withJSONObject: component, options: [.sortedKeys]))
                checks[prefix + "_original_scope_and_selection_are_bound"] = try proof.episodeID == lease.episodeID
                    && proof.projectID == chat.projectID && proof.conversationID == chat.id && proof.acceptedHumanEventID == currentID
                    && proof.endpoint == prepared.receipt.endpoint && proof.sourceSelectionWorkID == prepared.snapshot.selectionWorkID
                    && proof.sourceSelectionSHA256 == prepared.snapshot.selectionDigest()
                var expected: [Data: AuthoritySourceDependency] = [:]
                func include(_ id: String, offset: Int = 0, length: Int? = nil, excerpt: String? = nil) throws {
                    guard let source = try store.sourceReference(eventID: id, projectID: chat.projectID) else {
                        throw MemoryError.database("synthetic input proof original missing")
                    }
                    let dependency = AuthoritySourceDependency(source: source, offset: offset,
                        byteLength: length ?? source.byteCount, excerptSHA256: excerpt ?? source.digest)
                    expected[try AuthorityStateKernel.canonical(dependency)] = dependency
                }
                try include(currentID)
                for source in prepared.snapshot.recentSources { try include(source.eventID) }
                for source in prepared.snapshot.evidence {
                    try include(source.eventID, offset: source.excerptOffset, length: source.excerpt.utf8.count,
                        excerpt: ContextSnapshot.digest(Data(source.excerpt.utf8)))
                }
                let union = expected.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.value)
                checks[prefix + "_complete_accepted_recent_historical_union"] = try union.count == 3
                    && proof.sourceDependencyCount == union.count
                    && proof.sourceDependenciesSHA256 == ContextSnapshot.digest(AuthorityStateKernel.canonical(union))
            }
            var body = prepared.body, candidateAdmission = admission, host = prepared.settings.system
            let refusal: String
            if kind == .boundary { host += "Synthetic host mismatch"; refusal = "host_mismatch" }
            else if kind == .envelope { body.append(contentsOf: " ".utf8); refusal = "actual_body_mismatch" }
            else {
                var audit = try JSONSerialization.jsonObject(with: admission) as! [String: Any]
                var context = try JSONSerialization.jsonObject(with: prepared.snapshot.deliveryAudit()) as! [String: Any]
                context["selection_work_id"] = "fixture-missing-original-selection"
                audit["context"] = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]).base64EncodedString()
                candidateAdmission = try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
                refusal = "missing_selection"
            }
            let before = try lease.checkActive()
            var denied = false
            do { _ = try store.prepareAnswerInputProof(lease: lease, requestBody: body,
                providerIdentity: prepared.receipt.endpoint, admissionJSON: candidateAdmission, answerRequest: request,
                hostInstructions: host) } catch { denied = true }
            let after = try lease.checkActive()
            let resources = try AuthorityInputProofJournal.resources(bodyBytes: body.count, admissionBytes: candidateAdmission.count)
            let inventory = try journalInventory()
            checks[prefix + "_" + refusal + "_refused_after_retained_charge"] = try denied
                && after.charged == before.charged.adding(resources) && after.held == before.held
                && after.limits == original.limits && after.state == .active
                && inventory.answerWork == 0 && inventory.invocations == 0
            checks[prefix + "_denial_preserves_original_accepted_source"] = try store.events(conversationID: chat.id)
                .first { episodeIdentifierEqual($0.id, currentID) }.map { Data($0.text.utf8) } == Data(prompt.utf8)
            return checks
        }
        /// Alter only capability observation and its matching adapter references.
        /// Body, assignments, rendered hashes, count work IDs and original caps
        /// remain those of the actual independently counted preparation. The
        /// text-only positive control proves rejection is conditional on format.
        private func jsonCapabilityProofChecks(_ prepared: PreparedComponentContext) throws -> [String: Bool] {
            guard let original = prepared.receipt.componentProof,
                  let binding = prepared.settings.preparedContextComponents else { throw ProviderAdmissionError.countMismatch }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var candidate = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
            var identity = candidate["modelIdentity"] as! [String: Any]
            identity["capabilities"] = original.modelIdentity.capabilities.filter { $0 != "json_schema" }
            let identityBytes = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
            let textOnly = try JSONDecoder().decode(ProviderObservedModelIdentity.self, from: identityBytes)
            let adapter = ProviderAdmission.adapterIdentity(endpoint: original.endpoint,
                modelIdentity: textOnly, thinking: original.thinkingEnabled)
            candidate["modelIdentity"] = identity; candidate["adapterIdentity"] = adapter
            for key in ["recent", "evidence", "wholePrompt"] {
                var count = candidate[key] as! [String: Any]
                count["adapterIdentity"] = adapter; candidate[key] = count
            }
            let changed = try JSONDecoder().decode(ProviderComponentProof.self,
                from: JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys]))
            func accepts(_ proof: ProviderComponentProof) -> Bool {
                proof.accepts(body: prepared.body, assignments: binding.assignments,
                    sourceSnapshotDigest: binding.sourceSnapshotDigest, policyDigest: binding.policyDigest,
                    episodeLease: lease, address: prepared.settings.endpointURL)
            }
            let prefix = "component_preparation_" + kind.rawValue
            return [prefix + "_original_capability_proof_accepts": accepts(original),
                prefix + "_capability_change_retains_exact_body_and_counts": changed.bodyDigest == original.bodyDigest
                    && changed.assignmentDigest == original.assignmentDigest
                    && changed.recent.renderedDigest == original.recent.renderedDigest
                    && changed.evidence.renderedDigest == original.evidence.renderedDigest
                    && changed.wholePrompt.renderedDigest == original.wholePrompt.renderedDigest
                    && changed.wholePrompt.tokens == original.wholePrompt.tokens,
                prefix + "_text_only_capability_bound_to_actual_mode": accepts(changed) == !prepared.settings.endpointJSONOutput]
        }
        private func finish(_ outcome: Result<PreparedComponentContext, Error>) {
            guard !completed else { return }
            completed = true
            legacySession?.close(); legacySession = nil
            var checks: [String: Bool] = [:]
            let prefix = "component_preparation_" + kind.rawValue
            do {
                let state = try store.episodeReceipt(id: lease.episodeID, clock: clock.now())
                switch outcome {
                case .success(let prepared):
                    guard let proof = prepared.receipt.componentProof else { throw ProviderAdmissionError.countMismatch }
                    let sourceDigest = try prepared.snapshot.selectionDigest()
                    checks[prefix + "_one_original_episode"] = proof.episodeID == lease.episodeID
                        && prepared.settings.episodeLease?.episodeID == lease.episodeID
                    checks[prefix + "_mandatory_output_safety_intact"] = prepared.snapshot.messages.last?.content == prompt
                        && prepared.settings.maximumOutput == 64 && prepared.receipt.outputReserve == 64
                        && prepared.settings.endpointSafetyTokens == 256 && prepared.receipt.safetyTokens == 256
                    checks[prefix + "_counted_source_body_policy_proof"] = prepared.settings.preparedEndpointBody == prepared.body
                        && prepared.settings.preparedContextComponents?.accepts(receipt: prepared.receipt,
                            body: prepared.body, settings: prepared.settings) == true
                        && prepared.settings.preparedContextComponents?.sourceSnapshotDigest == sourceDigest
                    checks[prefix + "_component_caps_independent_of_whole"] = proof.recent.tokens <= 8000
                        && proof.evidence.tokens <= 12000 && prepared.receipt.promptTokens == proof.wholePrompt.tokens
                    checks[prefix + "_proof_uses_own_frozen_policy_version_and_reduction"] = try proof.policyVersion == state.limits.componentPolicy?.version
                        && proof.reductionVersion == state.limits.componentPolicy?.reductionVersion
                        && proof.policyDigest == EndpointRequest.digest(try state.limits.componentPolicy!.canonicalData())
                    let countInventory = try journalInventory()
                    checks[prefix + "_tokenizer_counts_charge_no_generative_input"] = countInventory.tokenizerWork > 0
                        && countInventory.generativeTokenizerWork == 0 && state.charged.httpAttempts > 4
                    if let accounting = prepared.receipt.accounting, let usage = accounting.calibrationUsage {
                        checks[prefix + "_independent_session_calibration_is_fully_charged"] = accounting.calibrationRequestCount == 1
                            && state.charged.modelCalls == 1 && state.charged.inputTokens == usage.promptTokens
                            && state.charged.outputTokens == usage.completionTokens && usage.completionTokens == 1
                            && state.held.outputTokens == 0
                    } else { checks[prefix + "_independent_session_calibration_is_fully_charged"] = false }
                    checks[prefix + "_provider_instance_identity_is_explicitly_unknown"] = proof.modelIdentity.instanceIdentity == "unobservable"
                        && prepared.receipt.modelIdentity?.instanceIdentity == "unobservable"
                        && proof.modelEpoch == 0 && prepared.receipt.loadedModelEpoch == 0
                    let audit = try JSONSerialization.jsonObject(with: prepared.snapshot.deliveryAudit()) as! [String: Any]
                    checks[prefix + "_durable_component_audit_attached"] = audit["components"] is [String: Any]
                        && audit["source_snapshot_sha256"] as? String == sourceDigest
                    switch kind {
                    case .legacyVersion:
                        checks[prefix + "_authentic_complete_and_partial_original_bodies_counted"] = prepared.snapshot.selectionBinding?.version == ContextSourceFraming.legacySelectionVersion
                            && prepared.snapshot.includedRecentCount == 2 && prepared.snapshot.messages[1].content == "pipelinekey original recent decision"
                            && prepared.snapshot.messages[2].content == "[Incomplete historical assistant message; capture status: partial.]\nSynthetic recent source 1"
                            && proof.recent.tokens == 8000 && proof.evidence.tokens == 0 && proof.wholePrompt.tokens == 8100
                    case .identityVersion:
                        let sources = prepared.snapshot.recentSources
                        let expected = try sources.enumerated().map { index, source in
                            try ContextSourceFraming.recentPrefix(eventID: source.eventID, role: source.role.rawValue,
                                status: source.status.rawValue, selectionVersion: ContextSourceFraming.identitySelectionVersion)
                                + (index == 0 ? "pipelinekey original recent decision" : "Synthetic recent source 1")
                        }
                        checks[prefix + "_authentic_complete_and_partial_original_bodies_counted"] = prepared.snapshot.selectionBinding?.version == ContextSourceFraming.identitySelectionVersion
                            && prepared.snapshot.includedRecentCount == 2 && prepared.snapshot.messages[1].content == expected[0]
                            && prepared.snapshot.messages[2].content == expected[1] && !expected[0].contains("source_time")
                            && proof.recent.tokens == 8000 && proof.evidence.tokens == 0 && proof.wholePrompt.tokens == 8100
                    case .boundary:
                        checks[prefix + "_exact_cap_boundaries_retained"] = proof.recent.tokens == 8000 && proof.evidence.tokens == 12000
                            && prepared.snapshot.includedRecentCount == 2 && prepared.snapshot.evidence.count == 3
                    case .pipeline:
                        checks[prefix + "_token_reduced_recent_source_eligible"] = prepared.snapshot.recentSourceIDs == ["fixture-pipeline-recent-6"]
                            && prepared.snapshot.evidence.map(\.eventID) == [droppedSourceID]
                            && prepared.snapshot.selectionAudit?.recentTokenExcludedCount == 6
                            && prepared.snapshot.selectionAudit?.evidenceTokenExcludedCount == 6
                        let selectedSource = prepared.snapshot.recentSources[0]
                        let historicalSource = prepared.snapshot.evidence[0]
                        let selection = try JSONSerialization.jsonObject(with: prepared.snapshot.selectionEvidence()) as! [String: Any]
                        let recentDocuments = selection["recent_sources"] as! [[String: Any]]
                        let historicalDocuments = selection["historical_sources"] as! [[String: Any]]
                        checks[prefix + "_recent_historical_calendar_and_capture_dates_counted"] = prepared.snapshot.selectionBinding?.version == ContextSourceFraming.currentSelectionVersion
                            && (recentDocuments[0]["source_time"] as? [String: String]) == selectedSource.sourceTime?.object
                            && (historicalDocuments[0]["source_time"] as? [String: String]) == historicalSource.sourceTime?.object
                            && prepared.snapshot.messages[1].content.contains("\"captured_utc\":\"" + selectedSource.createdAt + "\"")
                            && prepared.snapshot.messages[2].content.contains("captured_utc: " + historicalSource.createdAt)
                            && !prepared.snapshot.messages[2].content.contains("source_created_utc:")
                        let retrieval = try prepared.snapshot.retrievalAuditJSON.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
                        let expansion = retrieval?["exchange_expansion"] as? [String: Any]
                        let trace = retrieval?["selection_trace"] as? [String: Any]
                        checks[prefix + "_following_source_was_counted_then_removed_under_same_caps"] = expansion?["added_neighbor_count"] as? Int == 1
                            && trace?["candidate_count"] as? Int == 7 && prepared.snapshot.evidence.count == 1
                            && !prepared.snapshot.evidence.contains { $0.eventID == "fixture-pipeline-recent-1" }
                        checks[prefix + "_geometric_underfilled_caps_declared"] = proof.recent.tokens == 4000 && proof.evidence.tokens == 5000
                            && proof.wholePrompt.tokens == 9100
                    case .quotedPipeline:
                        let quoted = ContextSourceFraming.quotedSelectionVersion
                        let snapshot = prepared.snapshot
                        let selectedSource = snapshot.recentSources[0]
                        let historicalSource = snapshot.evidence[0]
                        let selection = try JSONSerialization.jsonObject(with: snapshot.selectionEvidence()) as! [String: Any]
                        let labels = selection["citation_labels"] as? [[String: Any]] ?? []
                        let modelText = snapshot.messages.map(\.content).joined(separator: "\n")
                        checks[prefix + "_same_selection_and_token_geometry_as_v3"] = snapshot.recentSourceIDs == ["fixture-quotedPipeline-recent-6"]
                            && snapshot.evidence.map(\.eventID) == [droppedSourceID]
                            && snapshot.selectionAudit?.recentTokenExcludedCount == 6
                            && snapshot.selectionAudit?.evidenceTokenExcludedCount == 6
                            && proof.recent.tokens == 4000 && proof.evidence.tokens == 5000 && proof.wholePrompt.tokens == 9100
                        checks[prefix + "_v4_quoted_recent_turns_carry_no_assistant_role"] = snapshot.selectionBinding?.version == quoted
                            && snapshot.messages.allSatisfy { $0.role != "assistant" }
                            && snapshot.messages[1].role == "user"
                            && snapshot.messages[1].content.hasPrefix(ContextSourceFraming.quotedRecentHeading + "[E1]")
                            && snapshot.messages[1].content.contains("captured_utc: " + selectedSource.createdAt)
                            && !modelText.contains(ContextSourceFraming.recentMetadataHeading)
                        checks[prefix + "_v4_historical_label_continues_and_ids_hidden"] =
                            snapshot.messages[2].content.contains("BEGIN HISTORICAL SOURCE [E2]\n")
                            && snapshot.messages[2].content.hasSuffix("END HISTORICAL SOURCE [E2]")
                            && snapshot.messages[2].content.contains("captured_utc: " + historicalSource.createdAt)
                            && !snapshot.messages[2].content.contains("event_id:")
                            && !modelText.contains(selectedSource.eventID) && !modelText.contains(historicalSource.eventID)
                        checks[prefix + "_v4_label_map_recorded_in_selection_journal"] =
                            selection["citation_label_version"] as? String == ContextSourceFraming.citationLabelVersion
                            && labels.count == 2 && labels[0]["label"] as? String == "E1" && labels[0]["kind"] as? String == "recent"
                            && labels[0]["event_id"] as? String == selectedSource.eventID
                            && labels[1]["label"] as? String == "E2" && labels[1]["kind"] as? String == "historical"
                            && labels[1]["event_id"] as? String == historicalSource.eventID
                            && labels[1]["excerpt_offset"] as? Int == historicalSource.excerptOffset
                            && labels[1]["excerpt_bytes"] as? Int == historicalSource.excerpt.utf8.count
                        checks[prefix + "_v4_system_framing_and_mandatory_binding"] = try
                            snapshot.messages[0].content.hasSuffix(ContextAssembler.historyFraming(selectionVersion: quoted))
                            && snapshot.selectionBinding?.mandatoryMessagesSHA256 == ContextSnapshot.digest(try ContextAssembler.serializedMessages(
                                ContextAssembler.mandatoryMessages(prompt: prompt, system: settings.system, selectionVersion: quoted)))
                    case .envelope:
                        checks[prefix + "_whole_overflow_reduces_evidence_before_recent"] = prepared.snapshot.evidence.isEmpty
                            && prepared.snapshot.recentSourceIDs == ["fixture-envelope-recent-6"]
                            && prepared.snapshot.selectionAudit?.evidenceEnvelopeExcludedCount == 1
                            && prepared.snapshot.selectionAudit?.recentEnvelopeExcludedCount == 0
                        checks[prefix + "_whole_recount_not_component_sum"] = proof.wholePrompt.tokens == 4100
                            && proof.evidence.tokens == 0 && proof.evidence.tokenizerWorkID == nil
                    case .jsonCapability:
                        let body = try JSONSerialization.jsonObject(with: prepared.body) as! [String: Any]
                        checks[prefix + "_actual_optional_body_counted"] = (body["response_format"] as? [String: String]) == ["type": "json_object"]
                            && proof.modelIdentity.capabilities.contains("json_schema")
                    case .neighborhood, .neighborhoodEnvelope:
                        let expectedCount = kind == .neighborhood ? 2 : 1
                        let selection = try JSONSerialization.jsonObject(with: prepared.snapshot.selectionEvidence()) as! [String: Any]
                        let retrieval = try JSONSerialization.jsonObject(with: prepared.snapshot.retrievalAuditJSON!) as! [String: Any]
                        let trace = retrieval["selection_trace"] as! [String: Any]
                        checks[prefix + "_new_policy_preserves_original_primary_after_counted_neighbor_reduction"] =
                            state.limits.componentPolicy == .selectedQwenNeighborhood && prepared.snapshot.evidence.count == expectedCount
                            && prepared.snapshot.protectedPrimarySpanCount == 1
                            && prepared.snapshot.evidence[0].eventID == "fixture-\(kind.rawValue)-archive-1"
                            && prepared.snapshot.evidenceProvenance?.first?.origin == "primary"
                            && proof.evidence.tokens == expectedCount * 5000
                        checks[prefix + "_initial_assembly_and_final_delivery_are_distinct_and_bound"] =
                            try trace["version"] as? String == "historical-selection-trace-v2"
                            && trace["candidate_count"] as? Int == 3 && trace["delivered_count"] as? Int == expectedCount
                            && (trace["delivery"] as? [[String: Any]])?.count == expectedCount
                            && selection["historical_selection_trace"] is [String: Any]
                            && audit["historical_provenance_sha256"] as? String == EndpointRequest.digest(
                                try JSONSerialization.data(withJSONObject: selection["historical_provenance"]!, options: [.sortedKeys]))
                        checks[prefix + "_counted_reductions_keep_byte_token_and_provider_limits"] =
                            prepared.snapshot.selectionAudit?.maximumEvidenceSpans == 48
                            && prepared.snapshot.selectionAudit?.maximumEvidenceBytes == 131072
                            && prepared.snapshot.selectionAudit?.evidenceTokenExcludedCount == 1
                            && prepared.snapshot.selectionAudit?.evidenceEnvelopeExcludedCount == (kind == .neighborhoodEnvelope ? 1 : 0)
                            && state.limits.resources == EpisodeResources.developmentCaps
                    case .neighborhoodRecentOnly:
                        let recentBytes = "pipelinekey original recent decision".utf8.count + "Synthetic recent source 1".utf8.count
                        let retrieval = try JSONSerialization.jsonObject(with: prepared.snapshot.retrievalAuditJSON!) as! [String: Any]
                        checks[prefix + "_new_policy_recent_only_has_zero_historical_work"] = prepared.snapshot.evidence.isEmpty
                            && prepared.snapshot.protectedPrimarySpanCount == 0 && retrieval["selection_trace"] == nil
                            && retrieval["exchange_expansion"] == nil && state.charged.rawSourceBytes == 2 * (prompt.utf8.count + recentBytes)
                            && state.charged.encoderInputBytes == 0 && state.charged.vectorBytes == 0
                            && proof.evidence.tokens == 0 && proof.evidence.tokenizerWorkID == nil
                        checks[prefix + "_new_policy_recent_only_journal_has_empty_bound_provenance"] =
                            state.limits.componentPolicy == .selectedQwenNeighborhood
                            && prepared.snapshot.selectionAudit?.maximumEvidenceSpans == 48
                            && prepared.snapshot.evidenceProvenance?.isEmpty == true
                    case .neighborhoodAuditDated, .neighborhoodAuditFit:
                        let dated = kind == .neighborhoodAuditDated, count = prepared.snapshot.evidence.count
                        let selection = try JSONSerialization.jsonObject(with: prepared.snapshot.selectionEvidence()) as! [String: Any]
                        let retrieval = try JSONSerialization.jsonObject(with: prepared.snapshot.retrievalAuditJSON!) as! [String: Any]
                        let trace = retrieval["selection_trace"] as! [String: Any]
                        let excluded = prepared.snapshot.selectionAudit?.evidenceAuditExcludedCount
                        checks[prefix + "_forty_eight_candidates_keep_sixteen_protected_primaries"] =
                            trace["candidate_count"] as? Int == 48 && prepared.snapshot.protectedPrimarySpanCount == 16
                            && prepared.snapshot.evidenceProvenance?.prefix(16).allSatisfy { $0.origin == "primary" } == true
                            && (dated ? count >= 16 && count < 48 : count == 48)
                        checks[prefix + "_exact_proof_and_real_selection_link_fit_hard_delivery_bound"] =
                            try prepared.snapshot.deliveryAudit().count <= 32768
                            && audit["components"] is [String: Any] && audit["selection_work_id"] as? String == prepared.snapshot.selectionWorkID
                            && prepared.snapshot.selectionWorkID?.utf8.count == 36 && proof.sourceSnapshotDigest == sourceDigest
                            && proof.evidence.tokens == count * 100 && proof.wholePrompt.tokens == 100 + count * 100
                        checks[prefix + "_only_audit_size_removes_optional_neighbors_and_recounts"] =
                            excluded == 48 - count && prepared.snapshot.selectionAudit?.evidenceAuditReductionRounds == excluded
                            && prepared.snapshot.selectionAudit?.evidenceTokenExcludedCount == 0
                            && prepared.snapshot.selectionAudit?.evidenceEnvelopeExcludedCount == 0
                            && (dated ? (excluded ?? 0) > 0 && countInventory.tokenizerWork >= 5 : excluded == 0)
                            && trace["audit_size_excluded_count"] as? Int == excluded
                            && (trace["delivery"] as? [[String: Any]])?.count == count
                            && (selection["historical_provenance"] as? [[String: Any]])?.count == count
                        checks[prefix + "_source_dates_and_maximum_id_ranges_remain_required"] =
                            prepared.snapshot.evidence.allSatisfy { dated ? $0.sourceTime != nil && $0.eventID.utf8.count == 256 : $0.sourceTime == nil }
                            && prepared.snapshot.selectionAudit?.maximumEvidenceSpans == 48
                            && prepared.snapshot.selectionAudit?.maximumEvidenceBytes == 131072
                            && state.limits.resources == EpisodeResources.developmentCaps
                    default: checks[prefix + "_expected_failure"] = false
                    }
                    if kind == .pipeline || kind == .jsonCapability {
                        checks.merge(try jsonCapabilityProofChecks(prepared)) { _, latest in latest }
                    }
                    checks.merge(try inputProofChecks(prepared)) { _, latest in latest }
                    try capturePrepared(prepared)
                    checks[prefix + "_prepared_proof_accepts_durable_invocation"] = true
                    let archive = directory.appendingPathComponent("verified-component-archive")
                    failureStage = "journal_preflight"
                    try validateJournal()
                    failureStage = "archive_creation"
                    let manifest = try BackupArchive.create(from: store, at: archive)
                    failureStage = "archive_verification"
                    let verified = try BackupArchive.verify(at: archive)
                    checks[prefix + "_archive_validates_component_proof_linkage"] = verified == manifest
                        && manifest.inventory.invocations == 1 && manifest.inventory.episodes == 1
                    let restoredDirectory = directory.appendingPathComponent("restored-component-store")
                    failureStage = "archive_restore"
                    _ = try BackupArchive.restore(from: archive, to: restoredDirectory, authority: .unmanagedNoDeletion)
                    let restored = try MemoryStore(directory: restoredDirectory)
                    let invocation = try restored.invocation(id: "fixture-invocation")
                    let restoredReceipt = try restored.episodeReceipt(id: lease.episodeID, clock: clock.now())
                    let originalReceipt = try store.episodeReceipt(id: lease.episodeID, clock: clock.now())
                    let originalAdmission = try store.invocation(id: "fixture-invocation")?.admissionJSON
                    checks[prefix + "_restore_preserves_exact_component_body_and_charges"] = invocation?.requestBody == prepared.body
                        && invocation?.finalStatus == .cancelled && restoredReceipt.charged == originalReceipt.charged
                        && restoredReceipt.held == originalReceipt.held
                        && invocation?.admissionJSON == originalAdmission
                    checks[prefix + "_restore_preserves_own_frozen_policy_and_span_cap"] = restoredReceipt.limits == originalReceipt.limits
                        && restoredReceipt.limits.componentPolicy?.evidenceSpans == state.limits.componentPolicy?.evidenceSpans
                    if kind == .pipeline || kind == .quotedPipeline {
                        if let inputProof {
                            let proofWork = try restored.episodeWork(episodeID: lease.episodeID, operationID: inputProof.operationID)
                            let restoredAudit: [String: Any]
                            if let bytes = invocation?.admissionJSON { restoredAudit = (try JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:] }
                            else { restoredAudit = [:] }
                            checks[prefix + "_restore_retains_durable_input_proof_link"] = try proofWork?.state == .completed
                                && proofWork?.request.snapshot == store.episodeWork(episodeID: lease.episodeID, operationID: inputProof.operationID)?.request.snapshot
                                && restoredAudit["inputProofWorkID"] as? String == inputProof.operationID
                                && restoredAudit["inputProofSHA256"] as? String == inputProof.digest
                                && inputProofEvidence(inputProof.operationID, directory: restoredDirectory) == inputProofEvidence(inputProof.operationID, directory: directory)
                        } else { checks[prefix + "_restore_retains_durable_input_proof_link"] = false }
                        checks.merge(JournalCorruptionChecks.run(archive: archive, directory: directory,
                            prefixOverride: kind == .quotedPipeline ? "component_preparation_quoted_journal_" : nil)) { _, latest in latest }
                    }
                    if kind == .legacyVersion || kind == .identityVersion {
                        checks.merge(JournalCorruptionChecks.run(archive: archive, directory: directory, versionsOnly: true, identityVersion: kind == .identityVersion)) { _, latest in latest }
                    }
                    if kind == .neighborhoodRecentOnly {
                        checks.merge(JournalCorruptionChecks.neighborhoodShapeChecks(archive: archive, directory: directory)) { _, latest in latest }
                    }
                case .failure(let error):
                    let code = ComponentContextPreparationOperation.failureCode(error)
                    let failureInventory = try journalInventory()
                    switch kind {
                    case .identityModel, .identityTemplate, .identityRuntime:
                        let expected = kind == .identityTemplate ? ProviderAdmissionError.templateMismatch.failureCode
                            : ProviderAdmissionError.unverifiedAdapter.failureCode
                        checks[prefix + "_actual_metadata_drift_rejects_prepared_result"] = code == expected
                        let countInventory = try journalInventory()
                        checks[prefix + "_drift_retains_counts_and_calibration_before_answer"] = state.charged.httpAttempts >= 7
                            && state.charged.modelCalls == 1 && state.charged.inputTokens > 0 && state.charged.outputTokens == 1
                            && countInventory.tokenizerWork > 1 && countInventory.generativeTokenizerWork == 0
                            && countInventory.answerWork == 0 && countInventory.invocations == 0
                            && settings.maximumOutput == 64 && settings.endpointSafetyTokens == 256
                    case .scope:
                        checks[prefix + "_foreign_accepted_origin_rejected_before_work"] = code == "episode_scope_mismatch"
                            && state.charged.httpAttempts == 0 && state.charged.rawSourceBytes == 0
                            && state.charged.metadataRows == 0 && state.charged.memoryOperations == 0
                            && state.charged.modelCalls == 0 && state.held == .zero
                    case .mandatory:
                        checks[prefix + "_overflow_before_source_access"] = code == "context_full"
                            && state.charged.rawSourceBytes == 0 && state.charged.metadataRows == 0
                            && state.charged.memoryOperations == 0
                        checks[prefix + "_accepted_request_preserved"] = try store.events(conversationID: chat.id).last?.text == prompt
                            && settings.maximumOutput == 64 && settings.endpointSafetyTokens == 256
                    case .httpLimit:
                        checks[prefix + "_shared_http_allowance_exhausted_without_reset"] = code == "episode_budget_exceeded"
                            && state.state == .budgetExceeded && state.charged.httpAttempts == 4
                            && state.limits.resources.httpAttempts == 4 && state.charged.modelCalls == 0
                    case .cancel:
                        checks[prefix + "_stop_while_count_waits_no_prepared_result"] = code == "cancelled" || code == "episode_inactive"
                        checks[prefix + "_performed_http_charges_retained"] = state.charged.httpAttempts >= 5
                            && state.charged.inputTokens > 0 && state.charged.modelCalls == 1 && state.charged.outputTokens == 1
                            && failureInventory.generativeTokenizerWork == 0
                    case .deadline:
                        checks[prefix + "_continuous_deadline_while_count_waits"] = code == "episode_deadline_exceeded"
                            && state.state == .deadlineExceeded
                        checks[prefix + "_deadline_keeps_prior_http_work"] = state.charged.httpAttempts >= 5
                            && state.charged.inputTokens > 0 && state.charged.modelCalls == 1 && state.charged.outputTokens == 1
                            && failureInventory.generativeTokenizerWork == 0
                    default: checks[prefix + "_successful_preparation"] = false
                    }
                    _ = try lease.finish(reason: kind == .cancel ? .cancelled : .failed)
                }
                let terminal = try store.episodeReceipt(id: lease.episodeID, clock: clock.now())
                let inventory = try journalInventory()
                let admitted: Bool
                if case .success = outcome { admitted = true } else { admitted = false }
                checks[prefix + "_terminal_journal_links_original_episode"] = terminal.state != .active && inventory.episodes == 1
                    && inventory.invocations == (admitted ? 1 : 0) && inventory.answerWork == (admitted ? 1 : 0)
            } catch {
                checks[prefix + "_completed_contract_checks"] = false
                checks[prefix + "_failed_at_" + failureStage + "_" + sanitizedFailure(error)] = false
            }
            operation = nil
            completion(checks)
        }
        private func sanitizedFailure(_ error: Error) -> String {
            if let error = error as? BackupError {
                switch error {
                case .invalid(let reason):
                    let known: Set<String> = ["SQLite integrity or foreign-key check failed", "admission or usage receipt digest mismatch",
                        "archive changed during restore", "archive contains missing or unlisted files",
                        "archive files must be private regular files without hard links", "archive metadata exceeds its size limit",
                        "archive must be a private real directory owned by this user", "copied database inventory mismatch",
                        "credential fields are excluded from archive configuration", "database inventory differs from manifest",
                        "database is not a standalone SQLite snapshot", "destination already exists",
                        "destination must be an absolute local path", "destination parent is missing or contains a symbolic link",
                        "destination path cannot contain dot components", "episode journal failed integrity verification",
                        "episode origin inventory mismatch", "file length or checksum mismatch", "invalid JSON metadata",
                        "invalid destination name", "invalid draft or stored setting", "invalid event scope or capture state",
                        "invalid invocation terminal state", "invalid loopback provider identity", "invalid native provider identity",
                        "invalid recovered cancellation state", "invalid recovered state", "invocation chunk failed integrity verification",
                        "invocation chunk manifest mismatch", "invocation lacks its matching human source", "invocation request digest mismatch",
                        "legacy restore introduced episode records", "local read episode cannot own an invocation",
                        "missing or malformed archive manifest", "noncontiguous or oversized invocation stream",
                        "online snapshot exceeded its deadline", "required regular file is missing or symbolic",
                        "restored episode recovery inventory mismatch", "restored exact read failed source checksum",
                        "restored exact read failed to advance", "restored exact-read metadata mismatch",
                        "restored startup recovery inventory mismatch", "source database has an unsupported schema",
                        "source payload failed digest, length or UTF-8 verification",
                        "source table, column, index or constraint contract is not a recognized Boros schema",
                        "table, column, index or constraint contract is not a recognized Boros schema",
                        "terminal invocation disagrees with assistant source", "unfinished invocation has a published result",
                        "unknown episode resource", "unsupported archive format, schema, or control metadata",
                        "unsupported database object inventory", "unsupported database schema", "unsupported historical schema",
                        "unsupported or duplicate file inventory", "unsupported table contract"]
                    return known.contains(reason) ? "backup_invalid_" + reason.replacingOccurrences(of: " ", with: "_") : "backup_invalid"
                case .io(let reason):
                    let known: Set<String> = ["archive copy read failed", "atomic publication refused an existing or invalid destination",
                        "cannot create private file", "cannot create private staging directory", "cannot create restored file",
                        "cannot inspect source item", "cannot open filesystem root", "cannot open staging directory for sync",
                        "destination parent changed", "file hash read failed", "file sync failed", "file write failed",
                        "file write made no progress", "metadata read failed", "restored file sync failed", "staging directory sync failed"]
                    return known.contains(reason) ? "backup_io_" + reason.replacingOccurrences(of: " ", with: "_") : "backup_io"
                case .database: return "backup_database"
                case .publicationDurabilityUnknown: return "backup_publication_durability_unknown"
                case .cancelled: return "backup_cancelled"
                case .authorityUnavailable: return "backup_authority_unavailable"
                }
            }
            if case MemoryError.database(let reason) = error {
                let journalReasons: Set<String> = ["proof binding mismatch", "source audit mismatch", "selection snapshot missing",
                    "selection work mismatch", "selection charge linkage mismatch", "selection provenance mismatch",
                    "selection work resource mismatch", "selection limits mismatch", "recent source mismatch",
                    "recent source bytes mismatch", "source metadata mismatch", "source metadata missing",
                    "source calendar metadata missing", "source calendar metadata invalid", "source calendar metadata mismatch",
                    "accepted request mismatch", "accepted request missing", "evidence framing mismatch",
                    "historical source mismatch", "excerpt bytes missing", "excerpt digest mismatch",
                    "excerpt source range mismatch", "excerpt source range missing", "extra evidence bytes",
                    "provenance digest mismatch", "adapter binding mismatch", "count receipt mismatch",
                    "tokenizer work missing", "count work scope mismatch", "count precedes verification",
                    "count work resource mismatch", "counted text differs from dispatch", "count evidence missing",
                    "provider count evidence mismatch", "count work not unique", "component allowance mismatch",
                    "answer count linkage mismatch", "frozen policy lacks proof", "proof has no frozen policy",
                    "unsupported model observation", "model observation linkage mismatch", "unsupported JSON format capability"]
                let journalPrefix = "component journal "
                if reason.hasPrefix(journalPrefix) {
                    let suffix = String(reason.dropFirst(journalPrefix.count))
                    if journalReasons.contains(suffix) { return "component_journal_" + suffix.replacingOccurrences(of: " ", with: "_") }
                }
                let episodeReasons: Set<String> = ["duplicate episode archive receipt ID", "duplicate episode archive snapshots",
                    "episode archive HTTP attempt mismatch", "episode archive adapter violation flag missing",
                    "episode archive budget exceeded without adapter violation", "episode archive chat origin linkage failure",
                    "episode archive contains forbidden credential metadata", "episode archive integrity failure",
                    "episode archive invocation linkage mismatch", "episode archive lost armed charge",
                    "episode archive lost unknown output bound", "episode archive model call mismatch",
                    "episode archive origin integrity failure", "episode archive origin is not canonical",
                    "episode archive output settlement inconsistent", "episode archive parent scope mismatch",
                    "episode archive query failed", "episode archive read origin linkage failure",
                    "episode archive receipt exceeds bound", "episode archive receipt integrity failure",
                    "episode archive receipt linkage mismatch", "episode archive receipt transition mismatch",
                    "episode archive recovery state mismatch", "episode archive repeated unknown receipt",
                    "episode archive resource totals incomplete", "episode archive retrieval call mismatch",
                    "episode archive scope mismatch", "episode archive snapshot bound exceeded",
                    "episode archive snapshot integrity failure", "episode archive snapshot missing",
                    "episode archive terminal receipt missing", "episode archive terminal receipt replay mismatch",
                    "episode archive terminal state disagrees with receipt", "episode archive tokens lack model call",
                    "episode archive totals disagree with work", "episode archive unfinished work has terminal clock",
                    "episode archive unknown receipt has no new identity evidence", "episode archive work clock mismatch",
                    "episode archive work exceeds reservation", "episode archive work never armed",
                    "episode archive work row bound exceeded", "episode work archive integrity failure",
                    "invalid armed episode archive work", "invalid episode archive JSON", "invalid episode archive identifier",
                    "invalid episode archive lifecycle", "invalid episode archive metadata", "invalid episode archive metadata bounds",
                    "invalid episode archive schema", "invalid episode archive work linkage", "invalid prepared episode archive work",
                    "invalid unarmed terminal episode archive work", "local read episode archive contains generative work",
                    "unknown episode archive resource", "unsupported episode archive schema"]
                if episodeReasons.contains(reason) { return "episode_journal_" + reason.replacingOccurrences(of: " ", with: "_") }
                return "database"
            }
            if let error = error as? EpisodeBudgetError { return error.failureCode }
            if let error = error as? ProviderAdmissionError { return error.failureCode }
            return "contract_error"
        }
    }

    /// Each mutation starts from the coordinator's verified synthetic archive.
    /// Ordinary hashes are refreshed so these test the source/count bindings.
    private enum JournalCorruptionChecks {
        private enum Mutation: String, CaseIterable {
            case copiedHistoricalScope, copiedHistoricalOffset, copiedHistoricalHash
            case sourceSnapshotDigest, sourceSnapshotWorkLink, receiptModel, receiptEpisode
            case receiptModelIdentity, modelIdentityVersion, modelIdentityInstance, modelIdentityEpoch, modelIdentityExtraKey
            case fractionalOriginalClock, foreignOriginalClock, nonuniformOriginalClock
            case tokenizerSnapshot, tokenizerCountEvidence, tokenizerRenderedEvidence
            case policyExtraKey, policyChangedCap
            case reboundHistoricalScope, reboundHistoricalOffset, reboundHistoricalHash
            case reboundRecentRole, reboundRecentStatus, reboundRecentHash, originalSourceRange
            case unknownSelectionVersion, mixedSelectionDocumentVersion, mixedSelectionBindingVersion, mixedSelectionWorkVersion
            case reboundRecentBodyLabel, reboundRecentBodyID
            case originalSourceCalendar, originalCaptureDate
            case reboundCitationLabelMap
        }
        private enum FixtureError: Error { case malformed, database }
        private enum Binding { case text(String), bytes(Data), integer(Int) }

        private final class Database {
            let handle: OpaquePointer
            init(_ url: URL) throws {
                var raw: OpaquePointer?
                guard sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let raw else {
                    if let raw { sqlite3_close(raw) }
                    throw FixtureError.database
                }
                handle = raw
            }
            deinit { sqlite3_close(handle) }
            private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
                var raw: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let statement = raw else { throw FixtureError.database }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (offset, binding) in bindings.enumerated() {
                    let index = Int32(offset + 1)
                    let code: Int32
                    switch binding {
                    case .text(let text):
                        code = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient) }
                    case .bytes(let bytes):
                        code = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(bytes.count), transient) }
                    case .integer(let value): code = sqlite3_bind_int64(statement, index, Int64(value))
                    }
                    guard code == SQLITE_OK else { sqlite3_finalize(statement); throw FixtureError.database }
                }
                return statement
            }
            func bytes(_ sql: String, _ bindings: [Binding] = []) throws -> Data {
                let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw FixtureError.database }
                return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            }
            func execute(_ sql: String, _ bindings: [Binding]) throws {
                let statement = try prepare(sql, bindings); defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else { throw FixtureError.database }
            }
            func schema(_ sql: String) throws {
                guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
            }
            func replaceSnapshot(workID: String, payload: Data) throws {
                let digest = ContextSnapshot.digest(payload)
                try execute("INSERT INTO episode_request_snapshots (digest,byte_count,payload) VALUES (?,?,?)",
                    [.text(digest), .integer(payload.count), .bytes(payload)])
                try execute("UPDATE episode_work SET snapshot_digest=? WHERE id=?", [.text(digest), .text(workID)])
            }
        }
        private static func object(_ bytes: Data) throws -> [String: Any] {
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw FixtureError.malformed }
            return value
        }
        private static func encoded(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        private static func string(_ value: Any?) throws -> String {
            guard let value = value as? String, !value.isEmpty else { throw FixtureError.malformed }
            return value
        }
        private static func withCopy<T>(archive: URL, directory: URL, _ body: (Database) throws -> T) throws -> T {
            let copied = directory.appendingPathComponent("corruption-" + UUID().uuidString + ".sqlite3")
            try FileManager.default.copyItem(at: archive.appendingPathComponent("memory.sqlite3"), to: copied)
            defer {
                for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: copied.path + suffix) }
            }
            return try body(Database(copied))
        }
        static func run(archive: URL, directory: URL, versionsOnly: Bool = false, identityVersion: Bool = false,
                        prefixOverride: String? = nil) -> [String: Bool] {
            var checks: [String: Bool] = [:]
            let prefix = prefixOverride ?? (versionsOnly ? (identityVersion ? "component_preparation_identity_journal_" : "component_preparation_legacy_journal_") : "component_preparation_journal_")
            do {
                try withCopy(archive: archive, directory: directory) { try MemoryStore.validateEpisodeJournal(database: $0.handle) }
                checks[prefix + "valid_coordinator_control"] = true
            } catch { checks[prefix + "valid_coordinator_control"] = false }
            if versionsOnly {
                do {
                    try withCopy(archive: archive, directory: directory) { database in
                        try database.schema("DROP INDEX events_source_day")
                        try database.schema("ALTER TABLE events DROP COLUMN source_time_json")
                        try database.schema("PRAGMA user_version=9")
                        try ContextComponentJournal.validate(database: database.handle)
                    }
                    checks[prefix + "original_schema9_column_absent_replay_validates"] = true
                } catch { checks[prefix + "original_schema9_column_absent_replay_validates"] = false }
            }
            let versionMutations: [Mutation] = [.unknownSelectionVersion, .mixedSelectionDocumentVersion,
                .mixedSelectionBindingVersion, .mixedSelectionWorkVersion, .reboundRecentBodyLabel, .reboundRecentBodyID,
                .reboundCitationLabelMap]
            for mutation in versionsOnly ? versionMutations : Mutation.allCases {
                do {
                    checks[prefix + mutation.rawValue + "_rejected"] = try withCopy(archive: archive, directory: directory) { database in
                        try MemoryStore.validateEpisodeJournal(database: database.handle)
                        try apply(mutation, database: database)
                        if mutation == .policyExtraKey || mutation == .policyChangedCap {
                            // Prove the policy contract independently even when
                            // schema-9 cleanup validation rejects limits first.
                            var policyRejected = false
                            do { try ContextComponentJournal.validate(database: database.handle) }
                            catch DecodingError.dataCorrupted { policyRejected = mutation == .policyExtraKey }
                            catch EpisodeBudgetError.invalid { policyRejected = mutation == .policyChangedCap || mutation == .policyExtraKey }
                            do { try MemoryStore.validateEpisodeJournal(database: database.handle); return false }
                            catch AuthorityStateError.integrity { return policyRejected }
                            catch MemoryError.database(let reason) { return policyRejected && reason == "invalid episode archive metadata" }
                        }
                        // Changed snapshots may first fail schema-8 accounting
                        // reconstruction. Independently prove the intended
                        // component contract also refuses the rehashed fixture.
                        var componentRejected = false
                        do { try ContextComponentJournal.validate(database: database.handle) }
                        catch MemoryError.database(let reason) { componentRejected = reason.hasPrefix("component journal ") }
                        do { try MemoryStore.validateEpisodeJournal(database: database.handle); return false }
                        catch { return componentRejected }
                    }
                } catch { checks[prefix + mutation.rawValue + "_rejected"] = false }
            }
            do {
                var oldLimits = try object(JSONEncoder().encode(EpisodeLimits()))
                oldLimits.removeValue(forKey: "componentPolicy")
                let decoded = try JSONDecoder().decode(EpisodeLimits.self, from: encoded(oldLimits))
                checks[prefix + "legacy_missing_policy_decodes_nil"] = decoded.componentPolicy == nil
                    && decoded.resources == EpisodeResources.developmentCaps
            } catch { checks[prefix + "legacy_missing_policy_decodes_nil"] = false }
            return checks
        }
        static func neighborhoodShapeChecks(archive: URL, directory: URL) -> [String: Bool] {
            var checks: [String: Bool] = [:]
            let shapes: [(String, Any)] = [("array", [Any]()), ("string", "synthetic scalar"),
                ("number", 7), ("null", NSNull())]
            for (selectionKey, digestKey, retrievalKey) in [
                ("historical_selection_trace", "historical_selection_trace_sha256", "selection_trace"),
                ("neighborhood_expansion", "neighborhood_expansion_sha256", "exchange_expansion")
            ] {
                for (shape, value) in shapes {
                    let key = "component_preparation_neighborhood_recent_only_" + selectionKey + "_" + shape + "_rejected_with_matching_digests"
                    do {
                        checks[key] = try withCopy(archive: archive, directory: directory) { database in
                            try MemoryStore.validateEpisodeJournal(database: database.handle)
                            var admission = try object(database.bytes("SELECT admission_json FROM invocations WHERE id='fixture-invocation'"))
                            guard var receipt = admission["receipt"] as? [String: Any],
                                  var proof = receipt["componentProof"] as? [String: Any],
                                  let contextBytes = Data(base64Encoded: try string(admission["context"])) else { throw FixtureError.malformed }
                            var context = try object(contextBytes)
                            let workID = try string(context["selection_work_id"])
                            let source = try database.bytes("SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(workID)])
                            var selection = try object(source)
                            guard (selection["historical_sources"] as? [[String: Any]])?.isEmpty == true,
                                  var retrieval = context["retrieval"] as? [String: Any],
                                  retrieval["mode"] as? String == "recent_only" else { throw FixtureError.malformed }
                            selection[selectionKey] = value
                            let boundBytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                            context[digestKey] = ContextSnapshot.digest(boundBytes)
                            retrieval[retrievalKey] = value
                            context["retrieval"] = retrieval
                            let refreshedSource = try encoded(selection), sourceDigest = ContextSnapshot.digest(refreshedSource)
                            try database.replaceSnapshot(workID: workID, payload: refreshedSource)
                            context["source_snapshot_sha256"] = sourceDigest
                            proof["sourceSnapshotDigest"] = sourceDigest
                            receipt["componentProof"] = proof; context["components"] = proof
                            admission["receipt"] = receipt; admission["context"] = try encoded(context).base64EncodedString()
                            let refreshedAdmission = try encoded(admission)
                            try database.execute("UPDATE invocations SET admission_json=?,admission_digest=? WHERE id='fixture-invocation'",
                                [.bytes(refreshedAdmission), .text(ContextSnapshot.digest(refreshedAdmission))])
                            var componentRejected = false
                            do { try ContextComponentJournal.validate(database: database.handle) }
                            catch MemoryError.database(let reason) { componentRejected = reason == "component journal neighborhood audit shape invalid" }
                            do { try MemoryStore.validateEpisodeJournal(database: database.handle); return false }
                            catch { return componentRejected }
                        }
                    } catch { checks[key] = false }
                }
            }
            return checks
        }
        private static func apply(_ mutation: Mutation, database: Database) throws {
            var admission = try object(database.bytes("SELECT admission_json FROM invocations WHERE id='fixture-invocation'"))
            guard var receipt = admission["receipt"] as? [String: Any], var proof = receipt["componentProof"] as? [String: Any],
                  let contextData = Data(base64Encoded: try string(admission["context"])) else { throw FixtureError.malformed }
            var context = try object(contextData)
            let selectionWorkID = try string(context["selection_work_id"])
            guard let recentCount = proof["recent"] as? [String: Any] else { throw FixtureError.malformed }
            let tokenizerWorkID = try string(recentCount["tokenizerWorkID"])
            let zeroDigest = String(repeating: "0", count: 64)
            switch mutation {
            case .unknownSelectionVersion, .mixedSelectionDocumentVersion, .mixedSelectionBindingVersion, .mixedSelectionWorkVersion,
                 .reboundRecentBodyLabel, .reboundRecentBodyID, .reboundCitationLabelMap:
                let payload = try database.bytes("SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(selectionWorkID)])
                var selection = try object(payload)
                guard var binding = selection["binding"] as? [String: Any] else { throw FixtureError.malformed }
                let oldVersion = try string(selection["version"])
                let otherVersion = oldVersion == ContextSourceFraming.legacySelectionVersion
                    ? ContextSourceFraming.currentSelectionVersion : ContextSourceFraming.legacySelectionVersion
                if mutation == .unknownSelectionVersion || mutation == .mixedSelectionDocumentVersion {
                    selection["version"] = mutation == .unknownSelectionVersion ? "context-source-snapshot-v999" : otherVersion
                }
                if mutation == .unknownSelectionVersion || mutation == .mixedSelectionBindingVersion {
                    binding["version"] = mutation == .unknownSelectionVersion ? "context-source-snapshot-v999" : otherVersion
                    selection["binding"] = binding
                }
                if mutation == .unknownSelectionVersion || mutation == .mixedSelectionWorkVersion {
                    let version = mutation == .unknownSelectionVersion ? "context-source-snapshot-v999" : otherVersion
                    var request = try object(database.bytes("SELECT request_json FROM episode_work WHERE id=?", [.text(selectionWorkID)]))
                    request["adapterIdentity"] = version
                    let bytes = try encoded(request)
                    try database.execute("UPDATE episode_work SET adapter_identity=?,request_json=?,request_digest=? WHERE id=?",
                        [.text(version), .bytes(bytes), .text(ContextSnapshot.digest(bytes)), .text(selectionWorkID)])
                }
                if mutation == .reboundCitationLabelMap {
                    // V4: point the first label at another source. V1 to V3:
                    // add a label map the unlabelled framing never carries.
                    if var labels = selection["citation_labels"] as? [[String: Any]], !labels.isEmpty {
                        labels[0]["event_id"] = "synthetic-fabricated-citation-id"
                        selection["citation_labels"] = labels
                    } else {
                        selection["citation_label_version"] = ContextSourceFraming.citationLabelVersion
                        selection["citation_labels"] = [["label": "E1", "kind": "recent", "event_id": "synthetic-fabricated-citation-id"]]
                    }
                }
                if mutation == .reboundRecentBodyLabel || mutation == .reboundRecentBodyID {
                    var body = try object(database.bytes("SELECT request_body FROM invocations WHERE id='fixture-invocation'"))
                    guard var messages = body["messages"] as? [[String: String]], messages.count > 2 else { throw FixtureError.malformed }
                    let original = try string(messages[1]["content"])
                    if mutation == .reboundRecentBodyLabel {
                        messages[1]["content"] = "Synthetic incorrect metadata label\n" + original
                    } else if oldVersion == ContextSourceFraming.quotedSelectionVersion {
                        // A fabricated citation label in place of the delivered one.
                        let label = ContextSourceFraming.quotedRecentHeading + "[E1]"
                        guard original.hasPrefix(label) else { throw FixtureError.malformed }
                        messages[1]["content"] = ContextSourceFraming.quotedRecentHeading + "[E9]" + original.dropFirst(label.count)
                    } else if oldVersion == ContextSourceFraming.currentSelectionVersion || oldVersion == ContextSourceFraming.identitySelectionVersion {
                        var lines = original.components(separatedBy: "\n")
                        guard let line = lines.firstIndex(where: { $0.hasPrefix(ContextSourceFraming.recentMetadataHeading) }) else { throw FixtureError.malformed }
                        var metadata = try object(Data(lines[line].dropFirst(ContextSourceFraming.recentMetadataHeading.count).utf8))
                        metadata["event_id"] = "synthetic-fabricated-citation-id"
                        lines[line] = ContextSourceFraming.recentMetadataHeading + String(decoding: try encoded(metadata), as: UTF8.self)
                        messages[1]["content"] = lines.joined(separator: "\n")
                    } else {
                        messages[1]["content"] = try ContextSourceFraming.recentPrefix(eventID: "synthetic-fabricated-citation-id",
                            role: "human", status: "complete", selectionVersion: ContextSourceFraming.currentSelectionVersion,
                            capturedAt: "2026-10-06T12:00:00Z") + original
                    }
                    body["messages"] = messages
                    let bodyBytes = try encoded(body), bodyDigest = ContextSnapshot.digest(bodyBytes)
                    selection["messages_sha256"] = ContextSnapshot.digest(try encoded(messages))
                    receipt["bodyDigest"] = bodyDigest; proof["bodyDigest"] = bodyDigest
                    let answerRequest = try object(database.bytes("SELECT request_json FROM episode_work WHERE id=(SELECT episode_work_id FROM invocations WHERE id='fixture-invocation')"))
                    let answerID = try string(answerRequest["id"])
                    try database.replaceSnapshot(workID: answerID, payload: bodyBytes)
                    try database.execute("UPDATE invocations SET request_body=?,request_digest=? WHERE id='fixture-invocation'",
                        [.bytes(bodyBytes), .text(bodyDigest)])
                }
                let refreshed = try encoded(selection), digest = ContextSnapshot.digest(refreshed)
                // A work-version mutation deliberately leaves the selection
                // bytes unchanged. Its already-deduplicated snapshot must not
                // be reinserted under the same primary key before validation.
                if digest != ContextSnapshot.digest(payload) {
                    try database.replaceSnapshot(workID: selectionWorkID, payload: refreshed)
                }
                context["source_snapshot_sha256"] = digest; proof["sourceSnapshotDigest"] = digest
            case .copiedHistoricalScope, .copiedHistoricalOffset, .copiedHistoricalHash:
                guard var historical = context["historical_sources"] as? [[String: Any]], !historical.isEmpty else { throw FixtureError.malformed }
                if mutation == .copiedHistoricalScope { historical[0]["project_id"] = "foreign-synthetic-project" }
                if mutation == .copiedHistoricalOffset { historical[0]["excerpt_offset"] = 1 }
                if mutation == .copiedHistoricalHash { historical[0]["source_sha256"] = zeroDigest }
                context["historical_sources"] = historical
            case .sourceSnapshotDigest:
                context["source_snapshot_sha256"] = zeroDigest; proof["sourceSnapshotDigest"] = zeroDigest
            case .sourceSnapshotWorkLink: context["selection_work_id"] = tokenizerWorkID
            case .receiptModel: receipt["modelID"] = "foreign-synthetic-model"
            case .receiptEpisode: receipt["episodeID"] = "foreign-synthetic-episode"
            case .receiptModelIdentity:
                guard var identity = receipt["modelIdentity"] as? [String: Any] else { throw FixtureError.malformed }
                identity["modelID"] = "foreign-synthetic-model"
                receipt["modelIdentity"] = identity
            case .modelIdentityVersion, .modelIdentityInstance, .modelIdentityEpoch, .modelIdentityExtraKey:
                guard var identity = proof["modelIdentity"] as? [String: Any] else { throw FixtureError.malformed }
                if mutation == .modelIdentityVersion { identity["version"] = "unsupported-synthetic-observation" }
                if mutation == .modelIdentityInstance { identity["instanceIdentity"] = "fabricated-load-generation" }
                if mutation == .modelIdentityExtraKey { identity["unexpectedInstanceEpoch"] = 1 }
                if mutation == .modelIdentityEpoch { proof["modelEpoch"] = 1; receipt["loadedModelEpoch"] = 1 }
                proof["modelIdentity"] = identity; receipt["modelIdentity"] = identity
            case .fractionalOriginalClock, .foreignOriginalClock, .nonuniformOriginalClock:
                for key in ["recent", "evidence", "wholePrompt"] {
                    guard var count = proof[key] as? [String: Any] else { throw FixtureError.malformed }
                    if mutation == .fractionalOriginalClock { count["verifiedNanoseconds"] = 1_000_000_000.5 }
                    if mutation == .foreignOriginalClock { count["clockDomain"] = "foreign-synthetic-clock" }
                    if mutation == .nonuniformOriginalClock && key == "recent" {
                        guard let ticks = count["verifiedNanoseconds"] as? NSNumber else { throw FixtureError.malformed }
                        count["verifiedNanoseconds"] = ticks.uint64Value - 1
                    }
                    proof[key] = count
                }
            case .tokenizerSnapshot:
                let payload = try database.bytes("SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(tokenizerWorkID)])
                var snapshot = try object(payload)
                snapshot["content"] = try string(snapshot["content"]) + " synthetic mutation"
                try database.replaceSnapshot(workID: tokenizerWorkID, payload: encoded(snapshot))
            case .tokenizerCountEvidence, .tokenizerRenderedEvidence:
                let chainBytes = try database.bytes("SELECT receipt_json FROM episode_work WHERE id=?", [.text(tokenizerWorkID)])
                guard var chain = try JSONSerialization.jsonObject(with: chainBytes) as? [[String: Any]],
                      var last = chain.last, let evidence = Data(base64Encoded: try string(last["evidence"])) else { throw FixtureError.malformed }
                var evidenceObject = try object(evidence)
                if mutation == .tokenizerCountEvidence {
                    guard let tokens = evidenceObject["token_count"] as? NSNumber else { throw FixtureError.malformed }
                    evidenceObject["token_count"] = tokens.intValue + 1
                } else { evidenceObject["rendered_sha256"] = zeroDigest }
                last["evidence"] = try encoded(evidenceObject).base64EncodedString()
                chain[chain.count - 1] = last
                let refreshed = try encoded(chain)
                try database.execute("UPDATE episode_work SET receipt_json=?,receipt_digest=? WHERE id=?",
                    [.bytes(refreshed), .text(ContextSnapshot.digest(refreshed)), .text(tokenizerWorkID)])
            case .policyExtraKey, .policyChangedCap:
                var limits = try object(database.bytes("SELECT limits_json FROM episodes"))
                guard var policy = limits["componentPolicy"] as? [String: Any] else { throw FixtureError.malformed }
                if mutation == .policyExtraKey { policy["unexpectedCap"] = 8000 }
                else { policy["recentTokens"] = 8001 }
                limits["componentPolicy"] = policy
                let refreshed = try encoded(limits)
                try database.execute("UPDATE episodes SET limits_json=?,limits_digest=?",
                    [.bytes(refreshed), .text(ContextSnapshot.digest(refreshed))])
            case .reboundHistoricalScope, .reboundHistoricalOffset, .reboundHistoricalHash,
                 .reboundRecentRole, .reboundRecentStatus, .reboundRecentHash:
                let payload = try database.bytes("SELECT s.payload FROM episode_work w JOIN episode_request_snapshots s ON s.digest=w.snapshot_digest WHERE w.id=?", [.text(selectionWorkID)])
                var selection = try object(payload)
                switch mutation {
                case .reboundHistoricalScope, .reboundHistoricalOffset, .reboundHistoricalHash:
                    guard var sources = selection["historical_sources"] as? [[String: Any]], !sources.isEmpty else { throw FixtureError.malformed }
                    if mutation == .reboundHistoricalScope { sources[0]["project_id"] = "foreign-synthetic-project" }
                    if mutation == .reboundHistoricalOffset { sources[0]["excerpt_offset"] = 1 }
                    if mutation == .reboundHistoricalHash { sources[0]["source_sha256"] = zeroDigest }
                    selection["historical_sources"] = sources; context["historical_sources"] = sources
                default:
                    guard var sources = selection["recent_sources"] as? [[String: Any]], !sources.isEmpty else { throw FixtureError.malformed }
                    if mutation == .reboundRecentRole { sources[0]["role"] = "assistant" }
                    if mutation == .reboundRecentStatus { sources[0]["status"] = "partial" }
                    if mutation == .reboundRecentHash { sources[0]["digest"] = zeroDigest }
                    selection["recent_sources"] = sources
                }
                let refreshed = try encoded(selection), digest = ContextSnapshot.digest(refreshed)
                try database.replaceSnapshot(workID: selectionWorkID, payload: refreshed)
                context["source_snapshot_sha256"] = digest; proof["sourceSnapshotDigest"] = digest
            case .originalSourceCalendar, .originalCaptureDate:
                guard let sources = context["historical_sources"] as? [[String: Any]], let source = sources.first else { throw FixtureError.malformed }
                let id = try string(source["event_id"])
                if mutation == .originalSourceCalendar {
                    let normalized = try EventSourceTime.normalize("2023-05-31")
                    let date = try EventSourceTime(value: normalized.value, precision: normalized.precision, timezone: normalized.timezone,
                        sourceSHA256: String(repeating: "b", count: 64), locator: "/synthetic/time", originalValue: "2023-05-31").validated()
                    try database.execute("UPDATE events SET source_time_json=? WHERE id=?", [.bytes(date.canonicalData()), .text(id)])
                } else {
                    try database.execute("UPDATE events SET created_at=? WHERE id=?", [.text("2000-01-01T00:00:00Z"), .text(id)])
                }
            case .originalSourceRange:
                guard let sources = context["historical_sources"] as? [[String: Any]], let source = sources.first else { throw FixtureError.malformed }
                let id = try string(source["event_id"])
                var payload = try database.bytes("SELECT payload FROM events WHERE id=?", [.text(id)])
                guard !payload.isEmpty else { throw FixtureError.malformed }
                payload[0] = payload[0] == 113 ? 112 : 113
                try database.execute("UPDATE events SET payload=? WHERE id=?", [.bytes(payload), .text(id)])
            }
            // Keep both copies of the component proof identical. Ordinary
            // integrity hashes pass even when the semantic binding is corrupt.
            receipt["componentProof"] = proof; context["components"] = proof
            admission["receipt"] = receipt; admission["context"] = try encoded(context).base64EncodedString()
            let refreshed = try encoded(admission)
            try database.execute("UPDATE invocations SET admission_json=?,admission_digest=? WHERE id='fixture-invocation'",
                [.bytes(refreshed), .text(ContextSnapshot.digest(refreshed))])
        }
    }
}
