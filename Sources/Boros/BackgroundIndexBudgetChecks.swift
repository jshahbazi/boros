import Foundation

enum BackgroundIndexBudgetChecks {
    static func run() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ predicate: () throws -> Bool) { do { checks[name] = try predicate() } catch { checks[name] = false } }
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); checks[name] = false } catch { checks[name] = true } }
        func one(_ resource: BackgroundIndexResource, _ value: Int) -> BackgroundIndexResources {
            BackgroundIndexResources(rawSourceBytes: resource == .rawSourceBytes ? value : 0,
                encoderCalls: resource == .encoderCalls ? value : 0, encoderInputBytes: resource == .encoderInputBytes ? value : 0,
                vectorBytes: resource == .vectorBytes ? value : 0, metadataRows: resource == .metadataRows ? value : 0,
                sourceJobs: resource == .sourceJobs ? value : 0)
        }
        for resource in BackgroundIndexResource.allCases {
            let cap = BackgroundIndexResources.developmentCaps[resource]
            check("exact_cap_" + resource.rawValue) { one(resource,cap).fits(within:.developmentCaps) }
            check("one_over_cap_" + resource.rawValue) { !one(resource,cap+1).fits(within:.developmentCaps) }
            rejects("negative_" + resource.rawValue) { try one(resource,-1).validate() }
            rejects("overflow_" + resource.rawValue) { _ = try one(resource,Int.max).adding(one(resource,1)) }
            rejects("underflow_" + resource.rawValue) { _ = try BackgroundIndexResources.zero.subtracting(one(resource,1)) }
            check("exact_subtraction_" + resource.rawValue) { try one(resource,cap).subtracting(one(resource,cap)) == .zero }
        }
        let hash = String(repeating:"a",count:64), fingerprint = String(repeating:"b",count:64)
        let probe = BackgroundIndexWorkRequest(id:"probe",binding:BackgroundIndexBinding(projectID:nil,indexFingerprint:nil,
            adapterIdentity:"fixture-public-probe-v1",descriptor:.publicEncoderProbe),resources:BackgroundIndexResources(encoderCalls:2,encoderInputBytes:65),
            encoderInput:.unknown,snapshot:BackgroundIndexWorkSnapshot(payload:try BackgroundIndexOperationDescriptor.publicProbeData))
        check("public_probe_is_65_bytes") { BackgroundIndexOperationDescriptor.publicProbeSentences.reduce(0) { $0 + $1.utf8.count } == 65 }
        check("valid_public_probe") { try probe.validate(); return true }
        let alteredProbe = BackgroundIndexWorkRequest(id:"probe",binding:probe.binding,resources:probe.resources,encoderInput:.unknown,
            snapshot:BackgroundIndexWorkSnapshot(payload:Data("unexpected".utf8)))
        rejects("private_input_cannot_use_probe_scope") { try alteredProbe.validate() }
        let descriptor = BackgroundIndexMetadataDescriptor(target:.captureSourceFrontier,afterSequence:0,throughSequence:nil,limit:1,sourceReferencesSHA256:nil)
        let metadataBinding = BackgroundIndexBinding(projectID:"fixture",indexFingerprint:fingerprint,adapterIdentity:"fixture-index",descriptor:.metadataFrontier(descriptor))
        let metadata = BackgroundIndexWorkRequest(id:"metadata",binding:metadataBinding,resources:BackgroundIndexResources(metadataRows:1),encoderInput:.notApplicable,snapshot:nil)
        check("capture_current_frontier_binding") { try metadata.validate(); return true }
        func sourceReference(bytes: Int = 100, project: String = "fixture", event: String = "fixture-source", sequence: Int = 1,
                             role: String = "human", status: String = "complete", time: String = "2026-10-05T00:00:00Z") -> BackgroundIndexSourceReference {
            BackgroundIndexSourceReference(sequence: sequence, eventID: event, conversationID: "fixture-chat", projectID: project,
                role: role, status: status, createdAt: time, digest: bytes == 0 ? BackgroundIndexCanonical.sha256(Data()) : hash, byteCount: bytes)
        }
        let source = sourceReference()
        let chunk = try BackgroundIndexWorkRequest.chunkAttempt(id: "chunk", source: source, offset: 0, chunkBytes: 1024,
            dimension: 512, indexFingerprint: fingerprint, adapterIdentity: "fixture-index")
        guard case .source(_, let sourceBinding) = chunk.binding.descriptor else { throw BackgroundIndexBudgetError.invalid }
        check("source_bundle_valid") { try chunk.validate(); return true }
        rejects("source_without_project_rejected") { try BackgroundIndexBinding(projectID:nil,indexFingerprint:fingerprint,
            adapterIdentity:"fixture-index",descriptor:.source(.chunkAttempt,sourceBinding)).validate() }
        rejects("metadata_without_project_rejected") { try BackgroundIndexBinding(projectID:nil,indexFingerprint:fingerprint,
            adapterIdentity:"fixture-index",descriptor:.metadataFrontier(descriptor)).validate() }
        rejects("manifest_without_frozen_frontier_rejected") { try BackgroundIndexMetadataDescriptor(target:.sourceManifest,
            afterSequence:0,throughSequence:nil,limit:16,sourceReferencesSHA256:nil).validate() }
        rejects("schedule_without_ordered_sources_digest_rejected") { try BackgroundIndexMetadataDescriptor(target:.scheduleSources,
            afterSequence:0,throughSequence:16,limit:16,sourceReferencesSHA256:nil).validate() }
        rejects("underdeclared_chunk_read_rejected") { try BackgroundIndexWorkRequest(id:chunk.id,binding:chunk.binding,
            resources:BackgroundIndexResources(rawSourceBytes:99,encoderCalls:1,encoderInputBytes:100,vectorBytes:2048,metadataRows:5),
            encoderInput:.unknown,snapshot:chunk.snapshot).validate() }
        rejects("encoder_tokens_cannot_be_inferred_known") { try BackgroundIndexWorkRequest(id:chunk.id,binding:chunk.binding,
            resources:chunk.resources,encoderInput:.notApplicable,snapshot:chunk.snapshot).validate() }
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        check("canonical_equivalent_ids_remain_distinct") { composed == decomposed && !backgroundIndexIdentifierEqual(composed,decomposed) }
        let aliasBinding = BackgroundIndexBinding(projectID:composed,indexFingerprint:fingerprint,adapterIdentity:"fixture-index",descriptor:.metadataFrontier(descriptor))
        let otherBinding = BackgroundIndexBinding(projectID:decomposed,indexFingerprint:fingerprint,adapterIdentity:"fixture-index",descriptor:.metadataFrontier(descriptor))
        check("binding_scope_equality_uses_utf8") { aliasBinding != otherBinding }
        check("binding_digest_uses_utf8") { try aliasBinding.digest() != otherBinding.digest() }
        let aliasRequest = BackgroundIndexWorkRequest(id:composed,binding:metadataBinding,resources:metadata.resources,encoderInput:.notApplicable,snapshot:nil)
        let otherRequest = BackgroundIndexWorkRequest(id:decomposed,binding:metadataBinding,resources:metadata.resources,encoderInput:.notApplicable,snapshot:nil)
        check("request_id_equality_uses_utf8") { aliasRequest != otherRequest }
        check("request_id_digest_uses_utf8") { try aliasRequest.digest() != otherRequest.digest() }
        let day = BackgroundIndexLimits.durationNanoseconds, baseUTC:Int64 = 1_790_000_000_000, startTicks:UInt64 = 1_000
        func clock(_ elapsed:UInt64 = 0,_ utcDelta:Int64 = 0,_ domain:String = "boot-a") -> BackgroundIndexClockSnapshot {
            BackgroundIndexClockSnapshot(domain:domain,continuousNanoseconds:startTicks+elapsed,utcMilliseconds:baseUTC+utcDelta)
        }
        let window = try BackgroundIndexWindow.begin(id:"window",limits:.development,clock:clock())
        check("first_window_empty") { try window.remaining() == .developmentCaps && window.charged == .zero && window.held == .zero }
        check("wall_forward_cannot_roll_same_boot") { try !window.observed(at:clock(1,BackgroundIndexLimits.durationMilliseconds*10)).rolloverEligible }
        check("day_minus_one_ns_retains_window") { try !window.observed(at:clock(day-1,BackgroundIndexLimits.durationMilliseconds)).rolloverEligible }
        check("exact_continuous_day_rolls") { try window.observed(at:clock(day,0)).rolloverEligible }
        check("wall_rollback_does_not_extend_same_boot_day") { try window.observed(at:clock(day,-1)).rolloverEligible }
        rejects("same_boot_tick_regression_rejected") { _ = try window.observed(at:BackgroundIndexClockSnapshot(domain:"boot-a",continuousNanoseconds:999,utcMilliseconds:baseUTC)) }
        rejects("premature_window_close_rejected") { _ = try window.closing(at:clock(1,BackgroundIndexLimits.durationMilliseconds*10)) }
        let nextBoot = try window.observed(at:clock(0,3_600_000,"boot-b"))
        check("reboot_after_hour_retains_original_limits") { !nextBoot.rolloverEligible && nextBoot.window.limits == window.limits }
        check("reboot_valid_remaining_day_allows_original_capacity") {
            let observation = try nextBoot.window.observed(at: clock(1, 3_600_000, "boot-b"))
            return observation.pauseReason == nil && !observation.rolloverEligible
                && observation.window.anchor.requiresUTCForRollover
                && observation.window.limits == window.limits
        }
        check("reboot_valid_remaining_day_charges_original_window") {
            let observation = try nextBoot.window.observed(at: clock(1, 3_600_000, "boot-b"))
            let held = try observation.window.reserving(metadata)
            let armed = try held.arming(metadata)
            return armed.id == window.id && armed.charged == metadata.resources && armed.held == .zero
        }
        check("reboot_remaining_day_wall_jump_cannot_roll") { try !nextBoot.window.observed(at:clock(1,BackgroundIndexLimits.durationMilliseconds*10,"boot-b")).rolloverEligible }
        check("reboot_remaining_day_minus_one_ns_retains") { try !nextBoot.window.observed(at:clock(day-3_600_000_000_000-1,BackgroundIndexLimits.durationMilliseconds,"boot-b")).rolloverEligible }
        check("reboot_remaining_day_exact_rolls") { try nextBoot.window.observed(at:clock(day-3_600_000_000_000,BackgroundIndexLimits.durationMilliseconds,"boot-b")).rolloverEligible }
        check("reboot_after_utc_day_rolls") { try window.observed(at:clock(0,BackgroundIndexLimits.durationMilliseconds,"boot-b")).rolloverEligible }
        let raisedWater = try window.observed(at:clock(1,10_000)).window
        let regressedBoot = try raisedWater.observed(at:clock(0,9_999,"boot-b"))
        check("reboot_utc_high_water_regression_retains") { !regressedBoot.rolloverEligible && regressedBoot.pauseReason == .clockUnavailable }
        check("unknown_reboot_wall_jump_cannot_roll_early") { try !regressedBoot.window.observed(at:clock(1,BackgroundIndexLimits.durationMilliseconds*10,"boot-b")).rolloverEligible }
        check("unknown_reboot_full_day_still_requires_valid_utc") { try !regressedBoot.window.observed(at:clock(day,9_999,"boot-b")).rolloverEligible }
        check("unknown_reboot_full_day_and_valid_utc_rolls") { try regressedBoot.window.observed(at:clock(day,BackgroundIndexLimits.durationMilliseconds,"boot-b")).rolloverEligible }
        check("huge_future_utc_does_not_trap") { try window.observed(at:BackgroundIndexClockSnapshot(domain:"boot-b",continuousNanoseconds:1_000,utcMilliseconds:Int64.max)).rolloverEligible }
        let closed = try raisedWater.closing(at:clock(day,-1))
        let nextWindow = try BackgroundIndexWindow.begin(id:"next-window",limits:.development,clock:clock(day,-1),previousUTCHighWaterMilliseconds:closed.utcHighWaterMilliseconds)
        check("new_window_rollback_uses_previous_high_water_floor") { nextWindow.utcRolloverBaselineMilliseconds == closed.utcHighWaterMilliseconds }
        check("new_window_does_not_rewrite_old_window") { closed.state == .closed && window.state == .active && nextWindow.startedClock == clock(day,-1) }
        let tiny = BackgroundIndexLimits(resources:BackgroundIndexResources(metadataRows:1))
        let tinyWindow = try BackgroundIndexWindow.begin(id:"tiny-window",limits:tiny,clock:clock())
        let reserved = try tinyWindow.reserving(metadata)
        check("exact_reservation_cap") { try reserved.remaining() == .zero && reserved.held == metadata.resources }
        rejects("same_window_cannot_obtain_another_cap") { _ = try reserved.reserving(metadata) }
        check("reservation_preserves_frozen_limits") { reserved.limits == tiny }
        let armedWindow = try reserved.arming(metadata)
        check("arming_moves_full_hold_to_charge") { armedWindow.held == .zero && armedWindow.charged == metadata.resources }
        let probeHeld = try window.reserving(probe), probeArmed = try probeHeld.arming(probe)
        check("probe_marks_two_unknown_encoder_calls") { probeArmed.unknownEncoderCalls == 2 && probeArmed.charged.encoderCalls == 2 }
        let work = try BackgroundIndexWorkRecord.prepared(windowID:window.id,request:metadata,clock:clock())
        let recoveredPrepared = try work.recovered(receiptID:"prepared-recovery")
        check("prepared_recovery_releases_only_unused_hold") { recoveredPrepared.state == .cancelledBeforeDispatch && recoveredPrepared.charged == .zero && recoveredPrepared.held == .zero }
        check("prepared_recovery_reopen_is_stable") { try recoveredPrepared.recovered(receiptID:"second-reopen") == recoveredPrepared }
        let armed = try work.armed(at:clock(1)), submitted = try armed.submitted(), unknown = try submitted.recovered(receiptID:"armed-recovery")
        check("armed_recovery_retains_conservative_charge") { unknown.state == .outcomeUnknown && unknown.charged == metadata.resources && unknown.held == .zero }
        check("armed_recovery_reopen_is_stable") { try unknown.recovered(receiptID:"second-reopen") == unknown }
        rejects("changed_binding_digest_conflicts") { try work.accepts(bindingDigest:hash) }
        rejects("prepared_work_cannot_claim_completion") { _ = try work.settled(BackgroundIndexWorkSettlement(receiptID:"invalid-completion",outcome:.completed)) }
        rejects("armed_work_cannot_refund_charge") { _ = try armed.settled(BackgroundIndexWorkSettlement(receiptID:"invalid-refund",outcome:.cancelledBeforeDispatch)) }
        let completion = BackgroundIndexWorkSettlement(receiptID:"complete",outcome:.completed,observed:.zero)
        let complete = try submitted.settled(completion)
        check("completed_zero_observation_does_not_refund") { complete.charged == metadata.resources }
        check("terminal_settlement_retry_idempotent") { try complete.settled(completion) == complete }
        rejects("terminal_settlement_changed_receipt_conflicts") { _ = try complete.settled(BackgroundIndexWorkSettlement(receiptID:"changed-complete",outcome:.completed,observed:.zero)) }
        rejects("observed_violation_requires_explicit_flag") { try BackgroundIndexWorkSettlement(receiptID:"violation",outcome:.failedConfirmed,
            observed:BackgroundIndexResources(metadataRows:2)).validate(for:metadata) }
        check("explicit_observed_violation_keeps_maximum_charge") { try armed.settled(BackgroundIndexWorkSettlement(receiptID:"violation",outcome:.failedConfirmed,
            observed:BackgroundIndexResources(metadataRows:2),adapterViolation:true)).charged == metadata.resources }
        check("canonical_window_roundtrip") { try BackgroundIndexCanonical.decode(BackgroundIndexWindow.self,bytes:BackgroundIndexCanonical.data(probeArmed)) == probeArmed }
        check("canonical_work_roundtrip") { try BackgroundIndexCanonical.decode(BackgroundIndexWorkRecord.self,bytes:BackgroundIndexCanonical.data(unknown)) == unknown }
        check("canonical_probe_request_roundtrip") { try BackgroundIndexCanonical.decode(BackgroundIndexWorkRequest.self,bytes:BackgroundIndexCanonical.data(probe)) == probe }
        var changedWindow = try JSONSerialization.jsonObject(with:BackgroundIndexCanonical.data(window)) as! [String:Any]
        changedWindow["unknown_future_field"] = 1
        rejects("canonical_decode_rejects_unknown_fields") { _ = try BackgroundIndexCanonical.decode(BackgroundIndexWindow.self,bytes:JSONSerialization.data(withJSONObject:changedWindow,options:[.sortedKeys])) }
        rejects("resource_decode_rejects_boolean_counter") { _ = try BackgroundIndexCanonical.decode(BackgroundIndexResources.self,
            bytes:Data("{\"encoderCalls\":true,\"encoderInputBytes\":0,\"metadataRows\":0,\"rawSourceBytes\":0,\"sourceJobs\":0,\"vectorBytes\":0}".utf8)) }
        check("not_started_snapshot_opens_no_window") { try BackgroundIndexBudgetSnapshot(window:nil).window == nil }
        check("budget_snapshot_is_content_free") { try BackgroundIndexBudgetSnapshot(window:probeArmed).remaining.encoderCalls == 4094 }
        let fullSource = sourceReference(bytes: 4_194_304)
        let sealResources = try BackgroundWorkerRawRules.initialSeal(source: fullSource)
        check("four_mib_full_seal_measured_recipe") {
            sealResources == BackgroundIndexResources(rawSourceBytes: 8_396_808, metadataRows: 1027)
        }
        let firstPage = try BackgroundWorkerRawRules.chunkAttempt(source: fullSource, offset: 0, chunkBytes: 1024, dimension: 512)
        check("chunk_page_does_not_multiply_full_source") {
            firstPage == BackgroundIndexResources(rawSourceBytes: 4100, encoderCalls: 1, encoderInputBytes: 1024,
                vectorBytes: 2048, metadataRows: 5)
        }
        let lastPage = try BackgroundWorkerRawRules.chunkAttempt(source: fullSource, offset: 4_193_280, chunkBytes: 1024, dimension: 512)
        check("final_chunk_preflights_fresh_seal_in_same_request") {
            lastPage == BackgroundIndexResources(rawSourceBytes: 8_400_908, encoderCalls: 1, encoderInputBytes: 1024,
                vectorBytes: 2048, metadataRows: 1032)
        }
        check("whole_source_nominal_1024_page_raw_total") { 4100 * 4096 + 2 * sealResources.rawSourceBytes == 33_587_216 }
        check("nominal_source_probe_encoder_requires_two_windows") { 4096 + probe.resources.encoderCalls > BackgroundIndexResources.developmentCaps.encoderCalls }
        let tinySource = sourceReference(bytes: 1)
        check("one_byte_final_chunk_is_bounded_not_minimum_k") {
            try BackgroundWorkerRawRules.chunkAttempt(source: tinySource, offset: 0, chunkBytes: 4096, dimension: 8192)
                == BackgroundIndexResources(rawSourceBytes: 18, encoderCalls: 1, encoderInputBytes: 1, vectorBytes: 32768, metadataRows: 8)
        }
        for invalid in [-1, 0, 63, 4097, Int.max] {
            rejects("chunk_size_rejects_" + String(invalid)) { _ = try BackgroundWorkerRawRules.chunkAttempt(source: fullSource, offset: 0, chunkBytes: invalid, dimension: 1) }
        }
        for invalid in [-1, 0, 8193, Int.max] {
            rejects("dimension_rejects_" + String(invalid)) { _ = try BackgroundWorkerRawRules.chunkAttempt(source: fullSource, offset: 0, chunkBytes: 64, dimension: invalid) }
        }
        for invalid in [-1, fullSource.byteCount, Int.max] {
            rejects("source_offset_rejects_" + String(invalid)) { _ = try BackgroundWorkerRawRules.chunkAttempt(source: fullSource, offset: invalid, chunkBytes: 64, dimension: 1) }
        }
        rejects("oversize_source_rejects_before_arithmetic") { _ = try BackgroundWorkerRawRules.initialSeal(source: sourceReference(bytes: Int.max)) }
        rejects("negative_source_rejects_before_arithmetic") { _ = try BackgroundWorkerRawRules.initialSeal(source: sourceReference(bytes: -1)) }
        rejects("empty_source_cannot_charge_encoder") { _ = try BackgroundWorkerRawRules.chunkAttempt(source: sourceReference(bytes: 0), offset: 0, chunkBytes: 64, dimension: 1) }
        check("empty_source_only_declares_five_metadata_rows") { try BackgroundWorkerRawRules.emptySource(source: sourceReference(bytes: 0)) == BackgroundIndexResources(metadataRows: 5) }
        for altered in [sourceReference(role: "assistant"), sourceReference(status: "partial"), sourceReference(time: "2026-10-05T00:00:01Z")] {
            check("source_digest_binds_" + altered.role + altered.status + altered.createdAt) { try source.canonicalDigest() != altered.canonicalDigest() }
        }
        check("canonical_source_scope_is_exact_utf8") { sourceReference(project: composed) != sourceReference(project: decomposed) }
        rejects("canonical_equivalent_project_cannot_bind_source") {
            try BackgroundIndexBinding(projectID: decomposed, indexFingerprint: fingerprint, adapterIdentity: "fixture-index",
                descriptor: .source(.initialSeal, BackgroundIndexSourceBinding(source: sourceReference(project: composed), offset: 0, byteCount: 100))).validate()
        }
        rejects("request_must_snapshot_complete_source") {
            try BackgroundIndexWorkRequest(id: chunk.id, binding: chunk.binding, resources: chunk.resources,
                encoderInput: chunk.encoderInput, snapshot: BackgroundIndexWorkSnapshot(payload: try sourceReference(role: "assistant").canonicalData())).validate()
        }
        rejects("request_cannot_overdeclare_an_alternate_recipe") {
            try BackgroundIndexWorkRequest(id: chunk.id, binding: chunk.binding, resources: chunk.resources.adding(BackgroundIndexResources(rawSourceBytes: 1)),
                encoderInput: chunk.encoderInput, snapshot: chunk.snapshot).validate()
        }
        let initial = try BackgroundIndexWorkRequest.initialSeal(id: "initial", source: source, indexFingerprint: fingerprint, adapterIdentity: "fixture-index")
        let initialEvidence = BackgroundIndexWorkerEvidence(sourceReferenceSHA256: try source.canonicalDigest(), offset: 0, byteCount: 100,
            sourceSealedSHA256: source.digest, sourceSealedByteCount: 100)
        check("initial_seal_completion_exact_evidence") {
            try BackgroundIndexWorkSettlement(receiptID: "initial-complete", outcome: .completed,
                evidence: initialEvidence.canonicalData()).validate(for: initial); return true
        }
        let finalEvidence = BackgroundIndexWorkerEvidence(sourceReferenceSHA256: try source.canonicalDigest(), offset: 0, byteCount: 100,
            textSHA256: hash, vectorByteCount: 2048, publicationSequence: 1, sourceSealedSHA256: hash, sourceSealedByteCount: 100)
        check("final_chunk_completion_requires_current_seal") {
            try BackgroundIndexWorkSettlement(receiptID: "chunk-complete", outcome: .completed,
                evidence: finalEvidence.canonicalData()).validate(for: chunk); return true
        }
        rejects("final_chunk_missing_fresh_seal_rejected") {
            try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: source.canonicalDigest(), offset: 0, byteCount: 100,
                textSHA256: hash, vectorByteCount: 2048, publicationSequence: 1).validate(for: chunk)
        }
        rejects("final_chunk_shorter_actual_range_rejected") {
            try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: source.canonicalDigest(), offset: 0, byteCount: 99,
                textSHA256: hash, vectorByteCount: 2048, publicationSequence: 1, sourceSealedSHA256: hash, sourceSealedByteCount: 100).validate(for: chunk)
        }
        rejects("final_chunk_over_bound_vector_rejected") {
            try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: source.canonicalDigest(), offset: 0, byteCount: 100,
                textSHA256: hash, vectorByteCount: 2052, publicationSequence: 1, sourceSealedSHA256: hash, sourceSealedByteCount: 100).validate(for: chunk)
        }
        rejects("completed_chunk_cannot_omit_evidence") { try BackgroundIndexWorkSettlement(receiptID: "missing", outcome: .completed).validate(for: chunk) }
        rejects("completed_chunk_cannot_reuse_initial_evidence") {
            try BackgroundIndexWorkSettlement(receiptID: "wrong-op", outcome: .completed, evidence: initialEvidence.canonicalData()).validate(for: chunk)
        }
        let ordinary = try BackgroundIndexWorkRequest.chunkAttempt(id: "ordinary", source: fullSource, offset: 1024, chunkBytes: 1024,
            dimension: 512, indexFingerprint: fingerprint, adapterIdentity: "fixture-index")
        let ordinaryEvidence = BackgroundIndexWorkerEvidence(sourceReferenceSHA256: try fullSource.canonicalDigest(), offset: 1024, byteCount: 200,
            textSHA256: hash, vectorByteCount: 0, publicationSequence: 1)
        check("unsupported_chunk_records_hole_without_vector") { try ordinaryEvidence.validate(for: ordinary); return true }
        rejects("ordinary_chunk_cannot_claim_unreserved_seal") {
            try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: fullSource.canonicalDigest(), offset: 1024, byteCount: 200,
                textSHA256: hash, vectorByteCount: 0, publicationSequence: 1, sourceSealedSHA256: hash, sourceSealedByteCount: fullSource.byteCount).validate(for: ordinary)
        }
        let empty = try BackgroundIndexWorkRequest.emptySource(id: "empty", source: sourceReference(bytes: 0), indexFingerprint: fingerprint, adapterIdentity: "fixture-index")
        check("empty_completion_has_no_vector_or_publication") {
            let evidence = BackgroundIndexWorkerEvidence(sourceReferenceSHA256: try sourceReference(bytes: 0).canonicalDigest(), offset: 0, byteCount: 0,
                sourceSealedSHA256: BackgroundIndexCanonical.sha256(Data()), sourceSealedByteCount: 0)
            try evidence.validate(for: empty); return true
        }
        let ordered = [source, sourceReference(event: "fixture-next", sequence: 2)]
        let orderedData = try BackgroundIndexCanonical.data(ordered)
        let scheduling = BackgroundIndexMetadataDescriptor(target: .scheduleSources, afterSequence: 0, throughSequence: 2,
            limit: 2, sourceReferencesSHA256: BackgroundIndexCanonical.sha256(orderedData))
        let schedule = try BackgroundIndexWorkRequest.metadata(id: "schedule", projectID: "fixture", indexFingerprint: fingerprint,
            adapterIdentity: "fixture-index", descriptor: scheduling, sourceReferences: ordered)
        check("schedule_declares_actual_jobs_and_binding_inspections") { schedule.resources == BackgroundIndexResources(metadataRows: 5, sourceJobs: 2) }
        rejects("schedule_reordered_sources_rejected") {
            _ = try BackgroundIndexWorkRequest.metadata(id: "reversed", projectID: "fixture", indexFingerprint: fingerprint,
                adapterIdentity: "fixture-index", descriptor: scheduling, sourceReferences: ordered.reversed())
        }
        rejects("schedule_changed_scope_rejected") {
            _ = try BackgroundIndexWorkRequest.metadata(id: "wrong-scope", projectID: "other", indexFingerprint: fingerprint,
                adapterIdentity: "fixture-index", descriptor: scheduling, sourceReferences: ordered)
        }
        let manifest = try BackgroundIndexWorkRequest.metadata(id: "manifest", projectID: "fixture", indexFingerprint: fingerprint, adapterIdentity: "fixture-index",
            descriptor: BackgroundIndexMetadataDescriptor(target: .sourceManifest, afterSequence: 0, throughSequence: 50, limit: 32, sourceReferencesSHA256: nil))
        check("manifest_charges_bound_before_rows_are_known") { manifest.resources == BackgroundIndexResources(metadataRows: 32) }
        rejects("metadata_snapshot_cannot_hide_payload") {
            try BackgroundIndexWorkRequest(id: metadata.id, binding: metadata.binding, resources: metadata.resources, encoderInput: .notApplicable,
                snapshot: BackgroundIndexWorkSnapshot(payload: Data("unrelated".utf8))).validate()
        }
        check("valid_reboot_anchor_later_utc_rollback_cannot_roll") {
            let reboot = try window.observed(at: clock(0, 3_600_000, "boot-b")).window
            return try !reboot.observed(at: clock(day - 3_600_000_000_000, 3_599_999, "boot-b")).rolloverEligible
        }
        check("valid_reboot_anchor_after_utc_forward_then_regression_cannot_roll") {
            let reboot = try window.observed(at: clock(0, 3_600_000, "boot-b")).window
            let forward = try reboot.observed(at: clock(1, BackgroundIndexLimits.durationMilliseconds * 10, "boot-b")).window
            return try !forward.observed(at: clock(day, BackgroundIndexLimits.durationMilliseconds, "boot-b")).rolloverEligible
        }
        rejects("clock_before_unix_epoch_rejected") { _ = try BackgroundIndexClockSnapshot(domain: "boot", continuousNanoseconds: 1, utc: Date(timeIntervalSince1970: -1)) }
        rejects("invalid_boot_ticks_rejected") { try BackgroundIndexClockSnapshot(domain: "boot", continuousNanoseconds: UInt64.max, utcMilliseconds: baseUTC).validate() }
        rejects("negative_prior_high_water_rejected") { _ = try BackgroundIndexWindow.begin(id: "invalid", limits: .development, clock: clock(), previousUTCHighWaterMilliseconds: -1) }
        rejects("raised_allowance_rejected") { try BackgroundIndexLimits(resources: BackgroundIndexResources(metadataRows: 100001)).validate() }
        rejects("shortened_allowance_window_rejected") { try BackgroundIndexLimits(windowNanoseconds: day - 1).validate() }
        rejects("completed_violation_rejected") { try BackgroundIndexWorkSettlement(receiptID: "violation", outcome: .completed, adapterViolation: true).validate() }
        func corrupt<T: Codable & BackgroundIndexValidated>(_ type: T.Type, _ value: T, _ update: (inout [String: Any]) -> Void) throws {
            var object = try JSONSerialization.jsonObject(with: BackgroundIndexCanonical.data(value)) as! [String: Any]
            update(&object)
            _ = try BackgroundIndexCanonical.decode(type, bytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }
        rejects("canonical_source_unknown_field_rejected") { try corrupt(BackgroundIndexSourceReference.self, source) { $0["unexpected"] = 1 } }
        rejects("canonical_binding_missing_role_rejected") {
            try corrupt(BackgroundIndexSourceBinding.self, sourceBinding) { object in
                var source = object["source"] as! [String: Any]; source.removeValue(forKey: "role"); object["source"] = source
            }
        }
        rejects("canonical_binding_changed_status_rejected") {
            try corrupt(BackgroundIndexSourceBinding.self, sourceBinding) { object in
                var source = object["source"] as! [String: Any]; source["status"] = "partial"; object["source"] = source
            }
        }
        rejects("canonical_binding_changed_recipe_rejected") { try corrupt(BackgroundIndexSourceBinding.self, sourceBinding) { $0["version"] = "other-recipe" } }
        rejects("canonical_binding_false_final_seal_rejected") { try corrupt(BackgroundIndexSourceBinding.self, sourceBinding) { $0["requiresFinalSeal"] = false } }
        rejects("canonical_binding_boolean_dimension_rejected") { try corrupt(BackgroundIndexSourceBinding.self, sourceBinding) { $0["encoderDimension"] = true } }
        rejects("canonical_worker_unknown_evidence_rejected") { try corrupt(BackgroundIndexWorkerEvidence.self, finalEvidence) { $0["hiddenText"] = "synthetic" } }
        rejects("canonical_worker_fractional_byte_counter_rejected") { try corrupt(BackgroundIndexWorkerEvidence.self, finalEvidence) { $0["byteCount"] = 1.5 } }
        rejects("canonical_work_lower_revision_rejected") { try corrupt(BackgroundIndexWorkRecord.self, unknown) { $0["revision"] = 0 } }
        rejects("canonical_completed_work_cannot_claim_recovery") { try corrupt(BackgroundIndexWorkRecord.self, complete) { $0["recovered"] = true } }
        rejects("canonical_window_unknown_input_count_cannot_underreport") { try corrupt(BackgroundIndexWindow.self, probeArmed) { $0["unknownEncoderCalls"] = 0 } }
        rejects("canonical_window_boolean_clock_rejected") {
            try corrupt(BackgroundIndexWindow.self, window) { object in
                var clock = object["lastClock"] as! [String: Any]; clock["utcMilliseconds"] = true; object["lastClock"] = clock
            }
        }
        rejects("canonical_original_boot_cannot_inherit_utc_age") {
            try corrupt(BackgroundIndexWindow.self, window) { object in
                var anchor = object["anchor"] as! [String: Any]
                anchor["establishedAgeNanoseconds"] = BackgroundIndexLimits.durationNanoseconds - 1
                object["anchor"] = anchor
            }
        }
        rejects("canonical_original_boot_anchor_tick_is_immutable") {
            try corrupt(BackgroundIndexWindow.self, window) { object in
                var anchor = object["anchor"] as! [String: Any]; anchor["continuousNanoseconds"] = startTicks - 1
                object["anchor"] = anchor
            }
        }
        rejects("canonical_original_boot_cannot_require_reboot_utc") {
            try corrupt(BackgroundIndexWindow.self, window) { object in
                var anchor = object["anchor"] as! [String: Any]; anchor["requiresUTCForRollover"] = true
                object["anchor"] = anchor
            }
        }
        rejects("canonical_reboot_anchor_cannot_drop_utc_requirement") {
            try corrupt(BackgroundIndexWindow.self, nextBoot.window) { object in
                var anchor = object["anchor"] as! [String: Any]; anchor["requiresUTCForRollover"] = false
                object["anchor"] = anchor
            }
        }
        let canonicalChunk = try BackgroundIndexCanonical.data(chunk)
        check("canonical_chunk_request_roundtrip") { try BackgroundIndexCanonical.decode(BackgroundIndexWorkRequest.self, bytes: canonicalChunk) == chunk }
        rejects("canonical_encoding_rejects_trailing_whitespace") { _ = try BackgroundIndexCanonical.decode(BackgroundIndexWorkRequest.self, bytes: canonicalChunk + Data(" ".utf8)) }
        return checks
    }
}
