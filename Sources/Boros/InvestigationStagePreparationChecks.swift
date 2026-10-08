import Foundation

/// Synthetic exact-count checks never contact a model or read private history.
enum InvestigationStagePreparationChecks {
    static func run() -> [String: Bool] {
        let policy = ContextComponentPolicy.selectedQwen
        let descriptor = Data("{\"version\":\"synthetic-stage-source-v1\",\"source_sha256\":\"synthetic\"}".utf8)
        let mandatory = [ContextMessage(role: "system", content: "Synthetic private host."),
            ContextMessage(role: "user", content: "Synthetic private request.")]
        let recent = ContextMessage(role: "assistant", content: "Synthetic intact prior answer.")
        let evidence = ContextMessage(role: "user", content: "Synthetic original evidence.")
        func accepts(_ messages: [ContextMessage], _ assignments: [ProviderMessageComponent],
                     binding: Data? = nil) -> Bool {
            do {
                try InvestigationStagePreparationOperation.validate(messages: messages, assignments: assignments,
                    sourceBindingData: binding ?? descriptor, policy: policy)
                return true
            } catch { return false }
        }
        var checks: [String: Bool] = [
            "investigation_stage_mandatory_only_shape_accepted": accepts(mandatory, [.mandatory, .mandatory]),
            "investigation_stage_recent_and_evidence_shape_accepted": accepts(
                [mandatory[0], recent, evidence, mandatory[1]], [.mandatory, .recent, .evidence, .mandatory]),
            "investigation_stage_empty_messages_rejected": !accepts([], []),
            "investigation_stage_assignment_length_rejected": !accepts(mandatory, [.mandatory]),
            "investigation_stage_first_role_rejected": !accepts([recent, mandatory[1]], [.mandatory, .mandatory]),
            "investigation_stage_last_role_rejected": !accepts([mandatory[0], recent], [.mandatory, .mandatory]),
            "investigation_stage_first_assignment_rejected": !accepts(mandatory, [.recent, .mandatory]),
            "investigation_stage_last_assignment_rejected": !accepts(mandatory, [.mandatory, .evidence]),
            "investigation_stage_inserted_host_authority_rejected": !accepts(
                [mandatory[0], mandatory[0], mandatory[1]], [.mandatory, .recent, .mandatory]),
            "investigation_stage_optional_mandatory_rejected": !accepts(
                [mandatory[0], recent, mandatory[1]], [.mandatory, .mandatory, .mandatory]),
            "investigation_stage_evidence_role_rejected": !accepts(
                [mandatory[0], recent, mandatory[1]], [.mandatory, .evidence, .mandatory]),
            "investigation_stage_two_evidence_messages_rejected": !accepts(
                [mandatory[0], evidence, evidence, mandatory[1]], [.mandatory, .evidence, .evidence, .mandatory]),
            "investigation_stage_recent_after_evidence_rejected": !accepts(
                [mandatory[0], evidence, recent, mandatory[1]], [.mandatory, .evidence, .recent, .mandatory]),
            "investigation_stage_empty_binding_rejected": !accepts(mandatory, [.mandatory, .mandatory], binding: Data()),
            "investigation_stage_nonobject_binding_rejected": !accepts(mandatory, [.mandatory, .mandatory], binding: Data("[]".utf8)),
            "investigation_stage_empty_object_binding_rejected": !accepts(mandatory, [.mandatory, .mandatory], binding: Data("{}".utf8)),
            "investigation_stage_malformed_binding_rejected": !accepts(mandatory, [.mandatory, .mandatory], binding: Data("{broken".utf8)),
            "investigation_stage_planner_output_reservation_fixed": InvestigationStageKind.planner.outputReserve == 1024,
            "investigation_stage_extraction_output_reservation_fixed": InvestigationStageKind.extraction.outputReserve == 2048,
        ]
        let excessRecent = Array(repeating: recent, count: policy.recentCandidates + 1)
        checks["investigation_stage_recent_row_cap_rejected"] = !accepts(
            [mandatory[0]] + excessRecent + [mandatory[1]],
            [.mandatory] + Array(repeating: .recent, count: excessRecent.count) + [.mandatory])
        let hugeRecent = ContextMessage(role: "user", content: String(repeating: "r", count: policy.recentBytes))
        checks["investigation_stage_recent_byte_cap_rejected"] = !accepts(
            [mandatory[0], hugeRecent, mandatory[1]], [.mandatory, .recent, .mandatory])
        let hugeEvidence = ContextMessage(role: "user", content: String(repeating: "e", count: policy.evidenceBytes))
        checks["investigation_stage_evidence_byte_cap_rejected"] = !accepts(
            [mandatory[0], hugeEvidence, mandatory[1]], [.mandatory, .evidence, .mandatory])
        let hugeMandatory = ContextMessage(role: "user", content: String(repeating: "m", count: policy.maximumMessageBytes))
        checks["investigation_stage_whole_byte_cap_rejected"] = !accepts([mandatory[0], hugeMandatory], [.mandatory, .mandatory])
        return checks
    }

    static func run(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
        let suite = Suite(baseURL: baseURL, completion: completion)
        suite.next()
    }

    private enum Case: String, CaseIterable {
        case pipeline, recentOverflow, evidenceOverflow, wholeOverflow, cancelled, invalidShape, noPolicy
    }

    private final class Suite {
        let baseURL: String
        let completion: ([String: Bool]) -> Void
        var cases = Array(Case.allCases)
        var checks = InvestigationStagePreparationChecks.run()
        var operation: InvestigationStagePreparationOperation?
        var ledger: ProviderEpisodeFixtureLedger?
        var lease: EpisodeLease?
        var first: PreparedInvestigationStage?
        var callbacks = 0

        init(baseURL: String, completion: @escaping ([String: Bool]) -> Void) {
            self.baseURL = baseURL; self.completion = completion
        }

        func next() {
            guard !cases.isEmpty else { completion(checks); return }
            let kind = cases.removeFirst()
            callbacks = 0; first = nil
            var limits = EpisodeLimits()
            limits.componentPolicy = kind == .noPolicy ? nil : .selectedQwen
            let ledger = ProviderEpisodeFixtureLedger(limits: limits)
            let lease = EpisodeLease(ledger: ledger, episodeID: ledger.id)
            self.ledger = ledger; self.lease = lease
            begin(kind: kind, stage: .planner, lease: lease)
        }

        func begin(kind: Case, stage: InvestigationStageKind, lease: EpisodeLease) {
            let marker = kind == .wholeOverflow ? "fixtureMandatory" : "fixturePipeline"
            var messages = [ContextMessage(role: "system", content: "Synthetic private-stage host instructions.")]
            var assignments: [ProviderMessageComponent] = [.mandatory]
            let recentCount = kind == .recentOverflow ? 3 : 2
            for index in 0..<recentCount {
                messages.append(ContextMessage(role: index % 2 == 0 ? "user" : "assistant",
                    content: "\(marker) Synthetic complete recent original \(index)."))
                assignments.append(.recent)
            }
            let evidenceCount = kind == .evidenceOverflow ? 3 : 2
            let evidence = (0..<evidenceCount).map {
                "BEGIN HISTORICAL SOURCE\nSynthetic exact original \($0).\nEND HISTORICAL SOURCE"
            }.joined(separator: "\n\n")
            messages.append(ContextMessage(role: "user", content: evidence)); assignments.append(.evidence)
            messages.append(ContextMessage(role: "user", content: marker + " Synthetic private \(stage.rawValue) request."))
            assignments.append(.mandatory)
            if kind == .invalidShape { assignments[1] = .mandatory }
            var settings = GenerationSettings()
            settings.profile = .customLocal; settings.endpointURL = baseURL
            settings.endpointAPIKey = kind == .cancelled ? "synthetic-admission-cancel" : "synthetic-key"
            settings.thinkingEnabled = true; settings.maximumOutput = 8192
            let descriptor = Data("{\"version\":\"synthetic-private-stage-v1\",\"stage\":\"\(stage.rawValue)\",\"source_count\":\(recentCount + evidenceCount)}".utf8)
            operation = InvestigationStagePreparationOperation(stage: stage, messages: messages,
                assignments: assignments, sourceBindingData: descriptor, settings: settings,
                episodeLease: lease) { [self] result in
                    callbacks += 1
                    if kind == .pipeline, stage == .planner, case .success(let value) = result {
                        first = value
                        checkPrepared(value, messages: messages, assignments: assignments, descriptor: descriptor,
                            lease: lease, prefix: "planner")
                        begin(kind: kind, stage: .extraction, lease: lease)
                        return
                    }
                    if kind == .pipeline, case .success(let value) = result {
                        checkPrepared(value, messages: messages, assignments: assignments, descriptor: descriptor,
                            lease: lease, prefix: "extraction")
                        if let first, let firstProof = first.receipt.componentProof, let proof = value.receipt.componentProof {
                            checks["investigation_stage_each_stage_uses_fresh_session"] = firstProof.wholePrompt.sessionID != proof.wholePrompt.sessionID
                            checks["investigation_stage_each_stage_uses_fresh_work"] = first.work.id != value.work.id
                            checks["investigation_stage_prior_body_cannot_reuse_receipt"] = !first.receipt.accepts(body: value.body, address: baseURL)
                            checks["investigation_stage_prior_sources_cannot_reuse_binding"] = !proof.accepts(body: value.body,
                                assignments: assignments, sourceSnapshotDigest: first.sourceBindingDigest,
                                policyDigest: proof.policyDigest, episodeLease: lease, address: baseURL)
                        } else { checks["investigation_stage_each_stage_uses_fresh_session"] = false }
                        checks["investigation_stage_intermediate_work_does_not_dispatch"] = ledger?.records.filter {
                            $0.request.kind == .answer
                        }.allSatisfy { $0.state == .prepared } == true
                        checks["investigation_stage_calibrations_remain_original_episode"] = ledger?.records.filter {
                            $0.request.kind == .calibration
                        }.count == 2 && ledger?.records.allSatisfy { $0.episodeID == lease.episodeID } == true
                        checks["investigation_stage_pipeline_callbacks_once_each"] = callbacks == 2
                    } else {
                        let expected: Bool
                        if case .failure(let error) = result {
                            switch kind {
                            case .recentOverflow, .evidenceOverflow, .wholeOverflow: expected = (error as? ProviderAdmissionError) == .contextOverflow
                            case .cancelled: expected = (error as? ProviderAdmissionError) == .cancelled
                            case .invalidShape: expected = (error as? ProviderAdmissionError) == .invalidRequest
                            case .noPolicy: expected = (error as? ProviderAdmissionError) == .unverifiedAdapter
                            case .pipeline: expected = false
                            }
                        } else { expected = false }
                        checks["investigation_stage_\(kind.rawValue)_specific_refusal"] = expected
                        checks["investigation_stage_\(kind.rawValue)_no_answer_reservation"] = ledger?.records.contains {
                            $0.request.kind == .answer
                        } == false
                        checks["investigation_stage_\(kind.rawValue)_callback_once"] = callbacks == 1
                        if kind == .invalidShape || kind == .noPolicy {
                            checks["investigation_stage_\(kind.rawValue)_no_provider_work"] = ledger?.records.isEmpty == true
                        }
                    }
                    operation = nil; self.ledger = nil; self.lease = nil
                    DispatchQueue.main.async { [self] in next() }
                }
            operation?.start()
            if kind == .cancelled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.operation?.cancel() }
            }
        }

        func checkPrepared(_ value: PreparedInvestigationStage, messages: [ContextMessage],
                           assignments: [ProviderMessageComponent], descriptor: Data,
                           lease: EpisodeLease, prefix: String) {
            let name = "investigation_stage_\(prefix)_"
            let proof = value.receipt.componentProof
            checks[name + "request_exact_original_messages"] = value.settings.messagesOverride == messages.map {
                ["role": $0.role, "content": $0.content]
            }
            checks[name + "actual_component_counts"] = proof?.recent.tokens == 8000 && proof?.evidence.tokens == 10000
            checks[name + "whole_request_counted"] = proof?.wholePrompt.tokens == value.receipt.promptTokens
                && proof?.wholePrompt.tokenizerWorkID != nil
            checks[name + "fixed_output_and_thinking_off"] = value.settings.maximumOutput == value.stage.outputReserve
                && value.receipt.outputReserve == value.stage.outputReserve && !value.settings.thinkingEnabled
            checks[name + "same_original_lease"] = value.settings.episodeLease === lease
                && value.receipt.episodeID == lease.episodeID && value.work.episodeID == lease.episodeID
            checks[name + "prepared_model_work_bound"] = value.work.request.kind == .answer
                && value.work.request.snapshot == value.body && value.work.state == .prepared
                && value.work.request.resources == EpisodeResources(inputTokens: value.receipt.promptTokens,
                    outputTokens: value.receipt.outputReserve, modelCalls: 1, httpAttempts: 1)
            checks[name + "source_descriptor_bound"] = value.sourceBindingDigest == EndpointRequest.digest(descriptor)
                && proof?.sourceSnapshotDigest == value.sourceBindingDigest
            checks[name + "dispatch_binding_revalidated"] = value.settings.preparedContextComponents?.accepts(
                receipt: value.receipt, body: value.body, settings: value.settings) == true
            if let proof {
                checks[name + "changed_source_descriptor_rejected"] = !proof.accepts(body: value.body,
                    assignments: assignments, sourceSnapshotDigest: EndpointRequest.digest(Data("{}".utf8)),
                    policyDigest: proof.policyDigest, episodeLease: lease, address: baseURL)
            } else { checks[name + "changed_source_descriptor_rejected"] = false }
        }
    }
}
