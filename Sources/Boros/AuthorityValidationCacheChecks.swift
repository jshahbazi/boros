import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Private synthetic cache/session schedules. Only fixed Boolean checks escape.
/// These callbacks do not dispatch model work or expose application content.
enum AuthorityValidationCacheChecks {
    enum CheckError:Error { case invalid }
    final class Clock:EpisodeClockSource {
        private let mutex=NSLock()
        private var milliseconds:Int64=100
        func set(_ value:Int64) { mutex.lock(); milliseconds=value; mutex.unlock() }
        func now()throws->EpisodeClockSnapshot {
            mutex.lock(); defer { mutex.unlock() }
            return EpisodeClockSnapshot(domain:"synthetic-authority-cache-clock",continuousNanoseconds:UInt64(max(1,milliseconds))*1_000_000,utc:Date(timeIntervalSince1970:Double(milliseconds)/1000+0.0001))
        }
    }
    struct Fixture {
        let owner:MemoryStore; let lease:EpisodeLease; let clock:Clock
        let conversation:StoredConversation; let acceptance:ManagedAcceptance
    }
    static func run()throws->[String:Bool] {
        guard let path=realpath(FileManager.default.temporaryDirectory.path,nil) else { throw CheckError.invalid }
        let root=URL(fileURLWithPath:String(cString:path),isDirectory:true); free(path)
        let scratch=root.appendingPathComponent("boros-authority-cache-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:scratch) }
        var checks:[String:Bool]=[:]
        let groups:[(String,(URL,inout [String:Bool])throws->Void)]=[("clock_equivalence",clockEquivalence),("funding",funding),("identity",identity),("external",external),("owner_writes",ownerWrites),("temporal",temporal),("interruption",interruption),("quotas",quotas),("restart",restart)]
        for (name,body) in groups { do { try body(scratch.appendingPathComponent(name),&checks) } catch { checks["authority_cache_"+name+"_fixture"]=false } }
        return checks
    }
    private static func fixture(_ directory:URL,clock:Clock=Clock(),limits:AuthorityValidationCacheLimits = .defaults,checkpoint:((String,OpaquePointer)throws->Void)?=nil,validationCheckpoint:((String)throws->Void)?=nil)throws->Fixture {
        let owner=try MemoryStore(directory:directory,authorityValidationCheckpoint:validationCheckpoint,authorityCacheLimits:limits,authorityCacheCheckpoint:checkpoint)
        let conversation=try owner.createConversation(projectID:"synthetic-cache-project",title:"Synthetic cache")
        let state=try owner.authorityStateSnapshot()
        let accepted=try owner.acceptManagedHumanRequest(conversationID:conversation.id,turnID:"cache-turn",humanEventID:"cache-human",episodeID:"cache-episode",requestID:"cache-request",text:"Synthetic complete cache input",limits:EpisodeLimits(),authority:AuthorityContext(ownerID:state.ownerID,origin:.humanHost),clock:clock.now())
        return Fixture(owner:owner,lease:EpisodeLease(ledger:owner,episodeID:accepted.episode.id,clock:clock),clock:clock,conversation:conversation,acceptance:accepted)
    }
    private static func reject(_ body:()throws->Void)->Bool { do { try body(); return false } catch { return true } }
    private static func canonical<T:Encodable>(_ value:T)throws->Data { try AuthorityStateKernel.canonical(value) }
    private static func database<T>(_ directory:URL,_ body:(OpaquePointer)throws->T)throws->T {
        var pointer:OpaquePointer?; guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path,&pointer,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let db=pointer else { throw CheckError.invalid }
        defer { sqlite3_close(db) }; sqlite3_busy_timeout(db,2000); return try body(db)
    }
    private static func charged(_ fixture:Fixture)throws->EpisodeResources { try fixture.owner.episodeReceipt(id:fixture.acceptance.episode.id,clock:fixture.clock.now()).charged }
    // Observational evidence after an external commit cannot authorize more work.
    private static func durableCharged(_ directory:URL,episodeID:String)throws->EpisodeResources {
        try database(directory) { db in
            var result=EpisodeResources.zero
            let rows=try AuthorityStateKernel.rows(db,"SELECT resource,charged FROM episode_resource_totals WHERE episode_id=?",[.text(episodeID)])
            guard rows.count == EpisodeResource.allCases.count else { throw CheckError.invalid }
            for row in rows {
                guard let key=EpisodeResource(rawValue:row[0].string) else { throw CheckError.invalid }
                result[key]=row[1].integer
            }
            return result
        }
    }
    private static func mutation(_ fixture:Fixture,_ id:String,_ operation:AuthorityOperation,task:String?=nil,policyID:String?=nil,policy:AuthorityPolicyDefinition?=nil)throws {
        let state=try fixture.owner.authorityStateSnapshot()
        _ = try fixture.owner.applyAuthorityOperation(request:AuthorityOperationRequest(requestID:id,expectedRevision:state.revision,operation:operation,taskID:task,policyID:policyID,expectedTaskRevision:task.flatMap { id in state.tasks.first { $0.id == id }?.revision },policy:policy),authority:AuthorityContext(ownerID:state.ownerID,origin:.humanHost),now:Int64((try fixture.clock.now().utc.timeIntervalSince1970*1000).rounded(.down)))
    }
    private static func funding(_ directory:URL,_ checks:inout [String:Bool])throws {
        let f=try fixture(directory)
        let session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"funded-session")
        let prepaid=try charged(f), initial=f.owner.authorityValidationCacheDiagnostics()
        checks["authority_cache_session_has_frozen_default_256_attempts"]=session.maximumAttempts == 256 && session.attemptsUsed == 0 && session.episodeID == f.acceptance.episode.id
        checks["authority_cache_session_funded_under_original_development_limits"]=prepaid.memoryOperations > 0 && prepaid.memoryOperations < 24 && prepaid.metadataRows > 0 && prepaid.metadataRows <= 100000 && session.charged.memoryOperations > 0
        var accepted=0
        for attempt in 1...256 {
            f.clock.set(Int64(100+attempt))
            let returned=try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1; return attempt }
            guard returned == attempt else { throw CheckError.invalid }
        }
        let used=try f.owner.authorityValidationSessionReceipt(sessionID:session.sessionID), warm=f.owner.authorityValidationCacheDiagnostics()
        checks["authority_cache_more_than_24_and_all_256_bounded_checks_accept"]=accepted == 256 && accepted > EpisodeResources.developmentCaps.memoryOperations && used.attemptsUsed == 256
        checks["authority_cache_warm_checks_do_not_repeat_funded_replay"]=warm.fullReplays == initial.fullReplays && initial.fullReplays > 0
        checks["authority_cache_warm_checks_do_not_prepare_original_source_payload_statements"]=warm.sourcePayloadStatements == initial.sourcePayloadStatements
        checks["authority_cache_warm_checks_retain_exact_prepaid_charge"]=try charged(f) == prepaid
        checks["authority_cache_warm_hits_and_attempts_are_counted"]=warm.cacheHits-initial.cacheHits == 256 && warm.sessionChecks-initial.sessionChecks == 256
        var exhausted=false
        do { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 } } catch EpisodeBudgetError.exhausted { exhausted=true } catch { }
        checks["authority_cache_attempt_257_exhausts_before_acceptance"]=exhausted && accepted == 256
        let retry=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:session.sessionID)
        checks["authority_cache_exact_creation_retry_does_not_reset_counter_or_charge"]=try retry == (try f.owner.authorityValidationSessionReceipt(sessionID:session.sessionID)) && retry.attemptsUsed >= 256 && retry.maximumAttempts == session.maximumAttempts && retry.operationID == session.operationID && retry.charged == session.charged
        checks["authority_cache_exact_retry_cannot_replenish_exhausted_checks"]=reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 } } && accepted == 256
        checks["authority_cache_exhausted_session_denials_preserve_prepaid_charge"]=try charged(f) == prepaid
        let state=try f.owner.authorityStateSnapshot()
        checks["authority_cache_256_pure_ticks_coalesce_without_epoch_mutation"]=state.controlEpoch == f.acceptance.binding.controlEpoch && state.revision == f.acceptance.binding.authorityRevision && state.timeHighWater == 356
        try database(directory) { try AuthorityStateJournal.validate(database:$0); try AuthorityBindingJournal.validate(database:$0) }
        checks["authority_cache_fast_clock_path_matches_offline_canonical_validator"]=true
    }
    private static func clockEquivalence(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let source=directory.appendingPathComponent("source"), clone=directory.appendingPathComponent("clone"), f=try fixture(source)
        let session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"equivalent-clock",maximumAttempts:8)
        f.clock.set(101); _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { }
        try FileManager.default.createDirectory(at:clone,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try database(source) { origin in
            var pointer:OpaquePointer?; guard sqlite3_open_v2(clone.appendingPathComponent("memory.sqlite3").path,&pointer,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE,nil)==SQLITE_OK,let target=pointer else { throw CheckError.invalid }
            defer { sqlite3_close(target) }
            guard let backup=sqlite3_backup_init(target,"main",origin,"main") else { throw CheckError.invalid }
            let copied=sqlite3_backup_step(backup,-1), finished=sqlite3_backup_finish(backup)
            guard copied == SQLITE_DONE,finished == SQLITE_OK else { throw CheckError.invalid }
        }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:clone.appendingPathComponent("memory.sqlite3").path)
        let initial=try authorityRows(source)
        checks["authority_cache_uncached_comparison_fixture_preserves_exact_clock_id_and_prefix"]=try initial == authorityRows(clone)
        var identical=true
        let diagnostics=f.owner.authorityValidationCacheDiagnostics()
        for time in [Int64(102),103,1000,1001] {
            f.clock.set(time); _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { }
            try database(clone) { db in
                try AuthorityStateKernel.execute(db,"BEGIN IMMEDIATE")
                do { try AuthorityStateKernel.advanceTime(database:db,now:time); try AuthorityStateKernel.execute(db,"COMMIT") } catch { try? AuthorityStateKernel.execute(db,"ROLLBACK"); throw error }
                try AuthorityStateJournal.validate(database:db)
            }
            identical = try identical && authorityRows(source) == authorityRows(clone)
        }
        checks["authority_cache_cached_pure_clock_coalescing_matches_uncached_durable_bytes"]=identical
        checks["authority_cache_equivalent_clock_schedule_uses_no_extra_replay_or_original_reads"]=f.owner.authorityValidationCacheDiagnostics().fullReplays == diagnostics.fullReplays && f.owner.authorityValidationCacheDiagnostics().sourcePayloadStatements == diagnostics.sourcePayloadStatements
    }
    private static func authorityRows(_ directory:URL)throws->[Data] {
        try database(directory) { db in
            try AuthorityStateKernel.tableNames.flatMap { name in
                let primary=name == "authority_control" ? "id":(name == "authority_operations" ? "sequence":(name == "authority_bindings" ? "conversation_id COLLATE BINARY":"id COLLATE BINARY"))
                return try AuthorityStateKernel.rows(db,"SELECT * FROM "+name+" ORDER BY "+primary).map { row in
                    var parts:[Data]=[]
                    for value in row {
                        switch value {
                        case .text(let text):parts.append(Data([0])+Data(text.utf8))
                        case .integer(let integer):parts.append(Data([1])+Data(String(integer).utf8))
                        case .bytes(let bytes):parts.append(Data([2])+bytes)
                        case .null:parts.append(Data([3]))
                        }
                    }
                    return try canonical(parts)
                }
            }
        }
    }
    private static func identity(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let f=try fixture(directory.appendingPathComponent("first")), other=try fixture(directory.appendingPathComponent("other"))
        let session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"identity-session",maximumAttempts:8)
        checks["authority_cache_foreign_owner_lease_matching_episode_id_cannot_create"]=reject { _ = try f.owner.beginAuthorityValidationSession(lease:other.lease,sessionID:"foreign-session",maximumAttempts:8) }
        var calls=0
        checks["authority_cache_foreign_owner_lease_matching_episode_id_cannot_check"]=reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:other.lease) { calls += 1 } } && calls == 0
        let impostor=EpisodeLease(ledger:f.owner,episodeID:f.acceptance.episode.id,clock:f.clock)
        checks["authority_cache_same_owner_episode_new_lease_cannot_replace_original_stop_signal"]=reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:impostor) { calls += 1 } } && calls == 0
        checks["authority_cache_changed_maximum_same_session_id_conflicts"]=reject { _ = try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:session.sessionID,maximumAttempts:9) }
        let composed="unicode-session-é", decomposed="unicode-session-e\u{301}"
        let first=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:composed,maximumAttempts:2)
        let second=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:decomposed,maximumAttempts:2)
        _ = try f.owner.withAuthorityValidationSession(sessionID:first.sessionID,lease:f.lease) { calls += 1 }
        let a=try f.owner.authorityValidationSessionReceipt(sessionID:composed), b=try f.owner.authorityValidationSessionReceipt(sessionID:decomposed)
        checks["authority_cache_session_unicode_ids_preserve_exact_utf8_identity"] = !episodeIdentifierEqual(a.operationID,b.operationID) && a.attemptsUsed == 1 && b.attemptsUsed == 0
        try f.owner.finishAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease)
        let before=try charged(f)
        checks["authority_cache_finished_session_refuses_fresh_checks"]=reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { calls += 1 } }
        checks["authority_cache_finished_session_creation_retry_retains_original_funding"]=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:session.sessionID,maximumAttempts:8).operationID == session.operationID && charged(f) == before
    }
    private static func external(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for reverted in [false,true] {
            let name=reverted ? "edit_revert":"corrupt_source", location=directory.appendingPathComponent(name)
            let retained: (Clock,String) = try {
            let f=try fixture(location), session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:name,maximumAttempts:8)
            _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { }
            let before=f.owner.authorityValidationCacheDiagnostics(), cost=try charged(f)
            try database(location) { db in
                let original=try AuthorityStateKernel.rows(db,"SELECT payload,digest FROM events WHERE id='cache-human'")[0]
                guard let payload=original[0].bytes else { throw CheckError.invalid }
                var changed=payload; changed[0]=0x58
                try AuthorityStateKernel.execute(db,"UPDATE events SET payload=?,digest=? WHERE id='cache-human'",[.bytes(changed),.text(AuthorityStateKernel.digest(changed))])
                if reverted { try AuthorityStateKernel.execute(db,"UPDATE events SET payload=?,digest=? WHERE id='cache-human'",[.bytes(payload),.text(original[1].string)]) }
            }
            var callbacks=0, stale=false
            do { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { callbacks += 1 } } catch AuthorityStateError.staleRevision { stale=true } catch { }
            let after=f.owner.authorityValidationCacheDiagnostics(), used=try f.owner.authorityValidationSessionReceipt(sessionID:session.sessionID)
            checks["authority_cache_external_"+name+"_invalidates_even_rebound_hashes"]=stale && callbacks == 0 && after.invalidations > before.invalidations
            checks["authority_cache_external_"+name+"_denial_consumes_prepaid_attempt"]=try used.attemptsUsed == 2 && (try durableCharged(location,episodeID:f.acceptance.episode.id)) == cost
            checks["authority_cache_external_"+name+"_stale_hit_does_not_read_source_or_replay"]=after.fullReplays == before.fullReplays && after.sourcePayloadStatements == before.sourcePayloadStatements
            let retry=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:session.sessionID,maximumAttempts:8)
            checks["authority_cache_external_"+name+"_exact_creation_retry_does_not_restore_eligibility"]=retry.attemptsUsed == 2 && reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { callbacks += 1 } } && callbacks == 0
            checks["authority_cache_external_"+name+"_accounting_lookup_refuses_unvalidated_owner"]=reject { _ = try charged(f) }
            checks["authority_cache_external_"+name+"_work_publication_refuses_unvalidated_owner"]=reject { _ = try f.owner.episodeWork(episodeID:f.acceptance.episode.id,operationID:session.operationID) }
            checks["authority_cache_external_"+name+"_fresh_funding_refuses_unvalidated_accounting"]=reject { _ = try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"fresh-unvalidated",maximumAttempts:4) }
            checks["authority_cache_external_"+name+"_refusal_preserves_incurred_charges"]=try durableCharged(location,episodeID:f.acceptance.episode.id) == cost
            return (f.clock,f.conversation.id)
            }()
            if reverted {
                var callbacks=0
                let reopened=try MemoryStore(directory:location)
                let state=try reopened.authorityStateSnapshot()
                let accepted=try reopened.acceptManagedHumanRequest(conversationID:retained.1,turnID:"revalidated-turn",humanEventID:"revalidated-human",episodeID:"revalidated-episode",requestID:"revalidated-request",text:"Synthetic revalidated input",limits:EpisodeLimits(),authority:AuthorityContext(ownerID:state.ownerID,origin:.humanHost),clock:retained.0.now())
                let lease=EpisodeLease(ledger:reopened,episodeID:accepted.episode.id,clock:retained.0)
                let fresh=try reopened.beginAuthorityValidationSession(lease:lease,sessionID:"fresh-after-revalidation",maximumAttempts:4)
                _ = try reopened.withAuthorityValidationSession(sessionID:fresh.sessionID,lease:lease) { callbacks += 1 }
                checks["authority_cache_external_reverted_bytes_require_revalidated_owner_and_funded_replay"]=callbacks == 1 && reopened.authorityValidationCacheDiagnostics().fullReplays > 0
            } else {
                checks["authority_cache_external_corrupt_source_owner_revalidation_refused"]=reject { _ = try MemoryStore(directory:location) }
            }
        }
        let raceDirectory=directory.appendingPathComponent("between-fences")
        var inject=false, injected=false
        let race=try fixture(raceDirectory,checkpoint:{ name,_ in
            if inject && name == "before-session-fence" {
                try database(raceDirectory) { try AuthorityStateKernel.execute($0,"UPDATE conversations SET title='Changed synthetic title' WHERE project_id='synthetic-cache-project'") }
                inject=false; injected=true
            }
        })
        let session=try race.owner.beginAuthorityValidationSession(lease:race.lease,sessionID:"external-gap",maximumAttempts:4)
        inject=true; var accepted=0
        checks["authority_cache_external_commit_between_planning_and_fence_denies_acceptance"]=reject { _ = try race.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:race.lease) { accepted += 1 } } && injected && accepted == 0
        checks["authority_cache_external_gap_denial_records_consumed_attempt"]=try race.owner.authorityValidationSessionReceipt(sessionID:session.sessionID).attemptsUsed == 1
        let fencedDirectory=directory.appendingPathComponent("acceptance-fence"), fenced=try fixture(fencedDirectory)
        let fenceSession=try fenced.owner.beginAuthorityValidationSession(lease:fenced.lease,sessionID:"acceptance-fence",maximumAttempts:4)
        let externalCode:Int32=try fenced.owner.withAuthorityValidationSession(sessionID:fenceSession.sessionID,lease:fenced.lease) {
            try database(fencedDirectory) { db in sqlite3_busy_timeout(db,0); return sqlite3_exec(db,"UPDATE conversations SET title='Blocked synthetic title'",nil,nil,nil) }
        }
        checks["authority_cache_external_write_fence_held_through_bounded_acceptance"]=externalCode == SQLITE_BUSY || externalCode == SQLITE_LOCKED
    }
    private static func ownerWrites(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let location=directory.appendingPathComponent("unknown-write")
        var inject=false, didWrite=false
        let f=try fixture(location,checkpoint:{ name,db in
            if inject && name == "before-session-fence" {
                try AuthorityStateKernel.execute(db,"UPDATE conversations SET title='Unknown same-connection title' WHERE project_id='synthetic-cache-project'")
                inject=false; didWrite=true
            }
        })
        let session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"unknown-owner-write",maximumAttempts:4)
        let before=f.owner.authorityValidationCacheDiagnostics(), cost=try charged(f)
        inject=true; var accepted=0
        checks["authority_cache_unmanifested_same_connection_write_denies_cached_acceptance"]=reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 } } && didWrite && accepted == 0
        checks["authority_cache_unmanifested_owner_write_invalidates_proof_and_retains_charge"]=try f.owner.authorityValidationCacheDiagnostics().invalidations > before.invalidations && (try charged(f)) == cost
        let safe=try fixture(directory.appendingPathComponent("safe-append"))
        let safeSession=try safe.owner.beginAuthorityValidationSession(lease:safe.lease,sessionID:"safe-append",maximumAttempts:4)
        let warmed=safe.owner.authorityValidationCacheDiagnostics()
        _ = try safe.owner.append(conversationID:safe.conversation.id,role:.human,text:"Synthetic new immutable evidence",status:.complete,turnID:"fresh-turn",eventID:"fresh-event")
        checks["authority_cache_ordinary_append_conservatively_invalidates_existing_session"]=reject { _ = try safe.owner.withAuthorityValidationSession(sessionID:safeSession.sessionID,lease:safe.lease) { accepted += 1 } }
        let newSafe=try safe.owner.beginAuthorityValidationSession(lease:safe.lease,sessionID:"after-safe-append",maximumAttempts:4)
        _ = try safe.owner.withAuthorityValidationSession(sessionID:newSafe.sessionID,lease:safe.lease) { accepted += 1 }
        let after=safe.owner.authorityValidationCacheDiagnostics()
        checks["authority_cache_ordinary_append_requires_fresh_funded_proof"]=after.fullReplays > warmed.fullReplays && after.cacheHits > warmed.cacheHits
        let activeBefore=try canonical(safe.owner.authorityStateSnapshot())
        checks["authority_cache_failed_duplicate_immutable_append_never_replaces_source"]=reject { _ = try safe.owner.append(conversationID:safe.conversation.id,role:.human,text:"Synthetic replacing bytes",status:.complete,turnID:"replacement-turn",eventID:"cache-human") }
        checks["authority_cache_failed_append_preserves_exact_control_and_original_capture"]=try canonical(safe.owner.authorityStateSnapshot()) == activeBefore && safe.owner.events(conversationID:safe.conversation.id).first!.text == "Synthetic complete cache input"
        let chunk=try fixture(directory.appendingPathComponent("audited-chunks"))
        _ = try chunk.owner.beginInvocation(invocationID:"synthetic-chunk-invocation",conversationID:chunk.conversation.id,turnID:"cache-turn",humanEventID:"cache-human",assistantEventID:"synthetic-chunk-assistant",providerIdentity:"native:synthetic-cache",requestBody:Data("{\"model\":\"synthetic\"}".utf8))
        let chunkSession=try chunk.owner.beginAuthorityValidationSession(lease:chunk.lease,sessionID:"audited-chunks",maximumAttempts:4)
        let chunkBefore=chunk.owner.authorityValidationCacheDiagnostics()
        _ = try chunk.owner.appendInvocationChunk(invocationID:"synthetic-chunk-invocation",sequence:0,text:"Synthetic accepted capture prefix")
        var chunkAccepted=0
        _ = try chunk.owner.withAuthorityValidationSession(sessionID:chunkSession.sessionID,lease:chunk.lease) { chunkAccepted += 1 }
        let chunkAfter=chunk.owner.authorityValidationCacheDiagnostics()
        checks["authority_cache_audited_chunk_accounting_preserves_control_source_proof"]=chunkAccepted == 1 && chunkAfter.fullReplays == chunkBefore.fullReplays && chunkAfter.invalidations == chunkBefore.invalidations
        let liveDirectory=directory.appendingPathComponent("write-after-validation")
        var finalInject=false
        let live=try fixture(liveDirectory,checkpoint:{ name,db in
            if finalInject && name == "before-session-acceptance" {
                try AuthorityStateKernel.execute(db,"UPDATE conversations SET title='Unknown acceptance mutation' WHERE project_id='synthetic-cache-project'")
                finalInject=false
            }
        })
        let liveSession=try live.owner.beginAuthorityValidationSession(lease:live.lease,sessionID:"final-owner-write",maximumAttempts:4)
        finalInject=true; var liveAccepted=0
        checks["authority_cache_same_connection_write_after_validation_fenced_before_callback"]=reject { _ = try live.owner.withAuthorityValidationSession(sessionID:liveSession.sessionID,lease:live.lease) { liveAccepted += 1 } } && liveAccepted == 0
    }
    private static func fresh(_ f:Fixture,_ name:String)throws->Fixture {
        let state=try f.owner.authorityStateSnapshot()
        let accepted=try f.owner.acceptManagedHumanRequest(conversationID:f.conversation.id,turnID:name+"-turn",humanEventID:name+"-human",episodeID:name+"-episode",requestID:name+"-request",text:"Synthetic refreshed cache input",limits:EpisodeLimits(),authority:AuthorityContext(ownerID:state.ownerID,origin:.humanHost),clock:f.clock.now())
        return Fixture(owner:f.owner,lease:EpisodeLease(ledger:f.owner,episodeID:accepted.episode.id,clock:f.clock),clock:f.clock,conversation:f.conversation,acceptance:accepted)
    }
    private static func temporal(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for activation in [false,true] {
            let name=activation ? "activation":"expiry", original=try fixture(directory.appendingPathComponent(name))
            let definition=AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-temporal",value:"Synthetic temporal policy",effectiveFrom:activation ? 200:0,expiresAt:activation ? 300:200)
            try mutation(original,"temporal-"+name,.policySet,policyID:"temporal-policy",policy:definition)
            let f=try fresh(original,"temporal-current"), session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:name,maximumAttempts:8)
            f.clock.set(199); var accepted=0
            _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 }
            let before=try f.owner.authorityStateSnapshot(), prepaid=try charged(f)
            f.clock.set(200)
            checks["authority_cache_due_"+name+"_denies_old_binding_at_exact_boundary"]=reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 } } && accepted == 1
            let after=try f.owner.authorityStateSnapshot()
            checks["authority_cache_due_"+name+"_commits_before_stale_denial"]=after.controlEpoch == before.controlEpoch+1 && after.revision == before.revision+1 && after.timeHighWater == 200 && after.policies.first!.state == (activation ? .active:.expired)
            let maintenanceCost=try charged(f)
            checks["authority_cache_due_"+name+"_preserves_immutable_binding_and_retains_maintenance_charge"]=try f.owner.managedEpisodeBinding(id:f.acceptance.episode.id)?.controlEpoch == f.acceptance.binding.controlEpoch && maintenanceCost.memoryOperations == prepaid.memoryOperations+1 && maintenanceCost.rawSourceBytes >= prepaid.rawSourceBytes && maintenanceCost.metadataRows > prepaid.metadataRows && f.owner.episodeReceipt(id:f.acceptance.episode.id,clock:f.clock.now()).held == .zero
            f.clock.set(150)
            checks["authority_cache_backward_clock_after_"+name+"_cannot_revive_old_session"]=try reject { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 } } && accepted == 1 && (try f.owner.authorityStateSnapshot()).timeHighWater == 200
            try database(directory.appendingPathComponent(name)) { try AuthorityStateJournal.validate(database:$0) }
            checks["authority_cache_due_"+name+"_fast_transition_validates_offline"]=true
        }
        let proposedOriginal=try fixture(directory.appendingPathComponent("proposed"))
        try mutation(proposedOriginal,"proposed-policy",.policyPropose,policyID:"proposed-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-proposed",value:"Synthetic proposed value",expiresAt:200))
        let proposed=try fresh(proposedOriginal,"proposed-current"), proposedSession=try proposed.owner.beginAuthorityValidationSession(lease:proposed.lease,sessionID:"proposed-expiry",maximumAttempts:4)
        proposed.clock.set(200)
        checks["authority_cache_proposed_policy_expiry_also_invalidates_session"]=try reject { _ = try proposed.owner.withAuthorityValidationSession(sessionID:proposedSession.sessionID,lease:proposed.lease) { } } && (try proposed.owner.authorityStateSnapshot()).policies.first!.state == .expired
        for activation in [false,true] {
            let name=activation ? "late-activation":"late-expiry", clock=Clock()
            var crossBoundary=false, crossed=false
            let original=try fixture(directory.appendingPathComponent(name),clock:clock,checkpoint:{ checkpoint,_ in
                if crossBoundary && checkpoint == "before-session-acceptance" { clock.set(200); crossBoundary=false; crossed=true }
            })
            try mutation(original,name+"-policy",.policySet,policyID:name+"-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-late-boundary",value:"Synthetic late boundary policy",effectiveFrom:activation ? 200:0,expiresAt:activation ? 300:200))
            let f=try fresh(original,name+"-current"), session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:name,maximumAttempts:4)
            let binding=try canonical(f.owner.managedEpisodeBinding(id:f.acceptance.episode.id)!), cost=try charged(f), before=try canonical(f.owner.authorityStateSnapshot())
            crossBoundary=true; var accepted=0, stale=false
            do { _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { accepted += 1 } } catch AuthorityStateError.staleRevision { stale=true } catch { }
            let key=name.replacingOccurrences(of:"-",with:"_")
            checks["authority_cache_"+key+"_after_validation_denies_actual_callback"]=stale && crossed && accepted == 0
            checks["authority_cache_"+key+"_denial_retains_consumed_funded_attempt"]=try f.owner.authorityValidationSessionReceipt(sessionID:session.sessionID).attemptsUsed == 1 && charged(f) == cost
            checks["authority_cache_"+key+"_does_not_mutate_binding_or_apply_unfunded_transition"]=try canonical(f.owner.managedEpisodeBinding(id:f.acceptance.episode.id)!) == binding && canonical(f.owner.authorityStateSnapshot()) == before
        }
        let failedLocation=directory.appendingPathComponent("failed-maintenance")
        var invalidateMaintenance=false
        let failedOriginal=try fixture(failedLocation,validationCheckpoint:{ checkpoint in
            if invalidateMaintenance && checkpoint == "cached-temporal-maintenance" {
                try database(failedLocation) { try AuthorityStateKernel.execute($0,"UPDATE conversations SET title='Synthetic failed maintenance witness'") }
                invalidateMaintenance=false
            }
        })
        try mutation(failedOriginal,"failed-maintenance-policy",.policySet,policyID:"failed-maintenance-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-failed-maintenance",value:"Synthetic maintenance policy",expiresAt:200))
        let failed=try fresh(failedOriginal,"failed-maintenance-current"), failedSession=try failed.owner.beginAuthorityValidationSession(lease:failed.lease,sessionID:"failed-maintenance",maximumAttempts:4)
        let failedBefore=try canonical(failed.owner.authorityStateSnapshot()), failedCost=try charged(failed)
        failed.clock.set(200); invalidateMaintenance=true; var failedAccepted=0
        checks["authority_cache_stale_due_maintenance_refuses_callback"]=reject { _ = try failed.owner.withAuthorityValidationSession(sessionID:failedSession.sessionID,lease:failed.lease) { failedAccepted += 1 } } && failedAccepted == 0
        let maintenanceRows=try database(failedLocation) { try AuthorityStateKernel.rows($0,"SELECT state,receipt_json,held_json,charged_json FROM episode_work WHERE episode_id=? AND adapter_identity=?",[.text(failed.acceptance.episode.id),.text("authority-validation-v1:cached-temporal-maintenance")]) }
        checks["authority_cache_failed_maintenance_actual_funded_row_present"]=maintenanceRows.count == 1
        guard maintenanceRows.count == 1,let receiptBytes=maintenanceRows[0][1].bytes,let heldBytes=maintenanceRows[0][2].bytes,let chargeBytes=maintenanceRows[0][3].bytes else { throw CheckError.invalid }
        let maintenanceReceipts=try receiptBytes.isEmpty ? [] : JSONDecoder().decode([EpisodeWorkSettlement].self,from:receiptBytes), maintenanceHeld=try JSONDecoder().decode(EpisodeResources.self,from:heldBytes), maintenanceCharge=try JSONDecoder().decode(EpisodeResources.self,from:chargeBytes)
        checks["authority_cache_external_commit_during_maintenance_refuses_unvalidated_settlement"]=maintenanceRows[0][0].string == EpisodeWorkState.dispatchArmed.rawValue && maintenanceReceipts.isEmpty && maintenanceHeld == .zero && maintenanceCharge.memoryOperations == 1
        checks["authority_cache_failed_maintenance_retains_charge_and_attempt"]=try durableCharged(failedLocation,episodeID:failed.acceptance.episode.id).memoryOperations == failedCost.memoryOperations+1 && failed.owner.authorityValidationSessionReceipt(sessionID:failedSession.sessionID).attemptsUsed == 1
        checks["authority_cache_failed_maintenance_does_not_apply_transition_or_change_binding"]=try canonical(failed.owner.authorityStateSnapshot()) == failedBefore && canonical(failed.owner.managedEpisodeBinding(id:failed.acceptance.episode.id)!) == canonical(failed.acceptance.binding)
        checks["authority_cache_failed_maintenance_accounting_requires_owner_revalidation"]=reject { _ = try charged(failed) }

        let stable=try fixture(directory.appendingPathComponent("backward-pure")), stableSession=try stable.owner.beginAuthorityValidationSession(lease:stable.lease,sessionID:"backward-pure",maximumAttempts:4)
        stable.clock.set(1000); _ = try stable.owner.withAuthorityValidationSession(sessionID:stableSession.sessionID,lease:stable.lease) { }
        let prior=try canonical(stable.owner.authorityStateSnapshot())
        stable.clock.set(999)
        // Continuous-clock rollback is refused independently; it cannot lower
        // authority high-water even though wall-clock rollback alone is harmless.
        _ = reject { _ = try stable.owner.withAuthorityValidationSession(sessionID:stableSession.sessionID,lease:stable.lease) { } }
        checks["authority_cache_backward_observation_never_rewrites_durable_clock_state"]=try canonical(stable.owner.authorityStateSnapshot()) == prior
    }
    private static func interruption(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let reentrant=try fixture(directory.appendingPathComponent("reentrant"))
        let session=try reentrant.owner.beginAuthorityValidationSession(lease:reentrant.lease,sessionID:"reentrant",maximumAttempts:4)
        var refused=false, entered=0
        let beforeState=try reentrant.owner.authorityStateSnapshot(), before=try canonical(beforeState)
        let request=AuthorityOperationRequest(requestID:"reentrant-suspend",expectedRevision:beforeState.revision,operation:.taskSuspend,taskID:reentrant.acceptance.binding.taskID,expectedTaskRevision:beforeState.tasks.first!.revision)
        _ = try reentrant.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:reentrant.lease) {
            entered += 1
            do { _ = try reentrant.owner.applyAuthorityOperation(request:request,authority:AuthorityContext(ownerID:beforeState.ownerID,origin:.humanHost),now:9000) } catch AuthorityValidationCacheError.reentrant { refused=true } catch { }
        }
        checks["authority_cache_reentrant_control_mutation_rejects_before_state_or_time_write"]=try refused && entered == 1 && canonical(reentrant.owner.authorityStateSnapshot()) == before
        checks["authority_cache_reentrant_denial_does_not_interrupt_accepted_callback"]=try reentrant.owner.authorityValidationSessionReceipt(sessionID:session.sessionID).attemptsUsed == 1 && reentrant.owner.authorityStateSnapshot().tasks.first!.state == .active
        let reentrantCost=try charged(reentrant)
        checks["authority_cache_throwing_bounded_callback_retains_consumed_attempt"]=try reject { _ = try reentrant.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:reentrant.lease) { throw CheckError.invalid } } && reentrant.owner.authorityValidationSessionReceipt(sessionID:session.sessionID).attemptsUsed == 2 && charged(reentrant) == reentrantCost
        let rollbackClock=Clock(); var lateTick=false
        let rollback=try fixture(directory.appendingPathComponent("callback-clock-rollback"),clock:rollbackClock,checkpoint:{ name,_ in
            if lateTick && name == "before-session-acceptance" { rollbackClock.set(200); lateTick=false }
        })
        let rollbackSession=try rollback.owner.beginAuthorityValidationSession(lease:rollback.lease,sessionID:"callback-clock-rollback",maximumAttempts:1)
        let rollbackState=try canonical(rollback.owner.authorityStateSnapshot()), rollbackCost=try charged(rollback), rollbackDiagnostics=rollback.owner.authorityValidationCacheDiagnostics()
        lateTick=true; var throwingCallbacks=0, callbackFailed=false
        do { _ = try rollback.owner.withAuthorityValidationSession(sessionID:rollbackSession.sessionID,lease:rollback.lease) { throwingCallbacks += 1; throw CheckError.invalid } } catch CheckError.invalid { callbackFailed=true } catch { }
        checks["authority_cache_callback_throw_rolls_back_late_pure_clock_durable_write"]=try callbackFailed && throwingCallbacks == 1 && canonical(rollback.owner.authorityStateSnapshot()) == rollbackState
        let rollbackRetry=try rollback.owner.beginAuthorityValidationSession(lease:rollback.lease,sessionID:rollbackSession.sessionID,maximumAttempts:1)
        checks["authority_cache_callback_throw_exact_retry_retains_exhausted_counter_and_charge"]=try rollbackRetry.attemptsUsed == 1 && rollbackRetry.maximumAttempts == 1 && rollbackRetry.operationID == rollbackSession.operationID && charged(rollback) == rollbackCost
        var retryExhausted=false
        do { _ = try rollback.owner.withAuthorityValidationSession(sessionID:rollbackSession.sessionID,lease:rollback.lease) { throwingCallbacks += 1 } } catch EpisodeBudgetError.exhausted { retryExhausted=true } catch { }
        checks["authority_cache_callback_throw_retry_cannot_restore_acceptance_attempt"]=retryExhausted && throwingCallbacks == 1
        let afterRollback=try rollback.owner.beginAuthorityValidationSession(lease:rollback.lease,sessionID:"new-session-after-callback-rollback",maximumAttempts:1)
        _ = try rollback.owner.withAuthorityValidationSession(sessionID:afterRollback.sessionID,lease:rollback.lease) { throwingCallbacks += 1 }
        checks["authority_cache_callback_rollback_requires_fresh_funded_proof_for_new_session"]=try throwingCallbacks == 2 && rollback.owner.authorityValidationCacheDiagnostics().fullReplays == rollbackDiagnostics.fullReplays+1 && rollback.owner.authorityStateSnapshot().timeHighWater == 200 && canonical(rollback.owner.managedEpisodeBinding(id:rollback.acceptance.episode.id)!) == canonical(rollback.acceptance.binding) && rollback.owner.events(conversationID:rollback.conversation.id).first!.text == "Synthetic complete cache input"
        try database(directory.appendingPathComponent("callback-clock-rollback")) { try AuthorityStateJournal.validate(database:$0) }
        checks["authority_cache_callback_rollback_then_new_funded_session_validates_offline"]=true
        let stopClock=Clock(); var stopLease:EpisodeLease?, stop=false
        let stopped=try fixture(directory.appendingPathComponent("stop"),clock:stopClock,checkpoint:{ name,_ in if stop && name == "before-session-acceptance" { stopLease?.interruptLocally(reason:.cancelled); stop=false } })
        stopLease=stopped.lease
        let stopSession=try stopped.owner.beginAuthorityValidationSession(lease:stopped.lease,sessionID:"stop",maximumAttempts:4), cost=try charged(stopped)
        stop=true; var stopAccepted=0
        checks["authority_cache_stop_between_validation_and_acceptance_fences_callback"]=reject { _ = try stopped.owner.withAuthorityValidationSession(sessionID:stopSession.sessionID,lease:stopped.lease) { stopAccepted += 1 } } && stopAccepted == 0
        checks["authority_cache_stop_denial_consumes_attempt_and_retains_charge"]=try stopped.owner.authorityValidationSessionReceipt(sessionID:stopSession.sessionID).attemptsUsed == 1 && charged(stopped) == cost
        let deadlineClock=Clock(); var expire=false
        let deadline=try fixture(directory.appendingPathComponent("deadline"),clock:deadlineClock,checkpoint:{ name,_ in if expire && name == "before-session-acceptance" { deadlineClock.set(120100); expire=false } })
        let deadlineSession=try deadline.owner.beginAuthorityValidationSession(lease:deadline.lease,sessionID:"deadline",maximumAttempts:4), deadlineCost=try charged(deadline)
        expire=true; var deadlineAccepted=0
        checks["authority_cache_deadline_crossing_after_validation_fences_callback"]=reject { _ = try deadline.owner.withAuthorityValidationSession(sessionID:deadlineSession.sessionID,lease:deadline.lease) { deadlineAccepted += 1 } } && deadlineAccepted == 0
        checks["authority_cache_deadline_denial_preserves_charge_without_reset"]=try charged(deadline) == deadlineCost && deadline.owner.authorityValidationSessionReceipt(sessionID:deadlineSession.sessionID).attemptsUsed == 1
        let coldClock=Clock(); var coldLease:EpisodeLease?, cancelCold=false
        let cold=try fixture(directory.appendingPathComponent("cold-cancel"),clock:coldClock,checkpoint:{ name,_ in if cancelCold && name == "cold-replay-progress" { coldLease?.interruptLocally(reason:.cancelled); cancelCold=false } })
        coldLease=cold.lease; cancelCold=true
        checks["authority_cache_independent_stop_interrupts_funded_cold_replay"]=reject { _ = try cold.owner.beginAuthorityValidationSession(lease:cold.lease,sessionID:"cold-cancel",maximumAttempts:4) }
        checks["authority_cache_cancelled_cold_replay_does_not_create_usable_session"]=reject { _ = try cold.owner.withAuthorityValidationSession(sessionID:"cold-cancel",lease:cold.lease) { } }
        checks["authority_cache_cancelled_cold_replay_preserves_incurred_charge"]=try charged(cold).memoryOperations > 0 && cold.owner.episodeReceipt(id:cold.acceptance.episode.id,clock:cold.clock.now()).held == .zero
        for useDeadline in [false,true] {
            let name=useDeadline ? "busy-deadline":"busy-stop", location=directory.appendingPathComponent(name), busyClock=Clock()
            var shouldBlock=false, blockingDB:OpaquePointer?, busyLease:EpisodeLease?
            let busy=try fixture(location,clock:busyClock,checkpoint:{ checkpoint,_ in
                guard shouldBlock && checkpoint == "before-session-fence" else { return }
                var pointer:OpaquePointer?
                guard sqlite3_open_v2(location.appendingPathComponent("memory.sqlite3").path,&pointer,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let db=pointer,let lease=busyLease else { throw CheckError.invalid }
                blockingDB=db; try AuthorityStateKernel.execute(db,"BEGIN IMMEDIATE"); shouldBlock=false
                DispatchQueue.global().asyncAfter(deadline:.now()+0.025) {
                    if useDeadline { busyClock.set(120100) } else { lease.interruptLocally(reason:.cancelled) }
                }
            })
            busyLease=busy.lease
            let busySession=try busy.owner.beginAuthorityValidationSession(lease:busy.lease,sessionID:name,maximumAttempts:4), busyCost=try charged(busy)
            shouldBlock=true; var busyAccepted=0
            let start=DispatchTime.now().uptimeNanoseconds
            let denied=reject { _ = try busy.owner.withAuthorityValidationSession(sessionID:busySession.sessionID,lease:busy.lease) { busyAccepted += 1 } }
            let elapsed=DispatchTime.now().uptimeNanoseconds-start
            if let blockingDB { try AuthorityStateKernel.execute(blockingDB,"ROLLBACK"); sqlite3_close(blockingDB) }
            checks["authority_cache_"+name.replacingOccurrences(of:"-",with:"_")+"_interrupts_locked_begin_before_callback"]=denied && busyAccepted == 0 && elapsed < 1_000_000_000
            checks["authority_cache_"+name.replacingOccurrences(of:"-",with:"_")+"_denial_preserves_funding_and_count"]=try charged(busy) == busyCost && busy.owner.authorityValidationSessionReceipt(sessionID:name).attemptsUsed == 1
        }
    }
    private static func quotas(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let f=try fixture(directory.appendingPathComponent("sessions"))
        var sessions:[AuthorityValidationSessionReceipt]=[]
        for index in 0..<4 { sessions.append(try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"quota-"+String(index),maximumAttempts:1)) }
        checks["authority_cache_default_four_live_sessions_supported"]=sessions.count == 4
        var capped=false
        do { _ = try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"quota-fifth",maximumAttempts:1) } catch AuthorityStateError.limit { capped=true } catch { }
        checks["authority_cache_fifth_live_session_fails_closed_at_default_quota"]=capped
        try f.owner.finishAuthorityValidationSession(sessionID:sessions[0].sessionID,lease:f.lease)
        let replacement=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"quota-replacement",maximumAttempts:1)
        checks["authority_cache_finished_session_slot_can_be_reused_without_resetting_old_id"]=try replacement.sessionID == "quota-replacement" && (try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:sessions[0].sessionID,maximumAttempts:1)).operationID == sessions[0].operationID
        let lowered=try fixture(directory.appendingPathComponent("lowered"),limits:AuthorityValidationCacheLimits(maximumSessions:1,maximumAttempts:2,maximumCanonicalBytes:16*1024*1024,maximumProofDescriptors:4096))
        let short=try lowered.owner.beginAuthorityValidationSession(lease:lowered.lease,sessionID:"short",maximumAttempts:2)
        _ = try lowered.owner.withAuthorityValidationSession(sessionID:short.sessionID,lease:lowered.lease) { }
        _ = try lowered.owner.withAuthorityValidationSession(sessionID:short.sessionID,lease:lowered.lease) { }
        checks["authority_cache_lowered_attempt_ceiling_is_enforced"]=reject { _ = try lowered.owner.withAuthorityValidationSession(sessionID:short.sessionID,lease:lowered.lease) { } }
        checks["authority_cache_request_cannot_raise_lowered_attempt_limit"]=reject { _ = try lowered.owner.beginAuthorityValidationSession(lease:lowered.lease,sessionID:"oversized-request",maximumAttempts:3) }
        for (name,config) in [("sessions",AuthorityValidationCacheLimits(maximumSessions:5)),("attempts",AuthorityValidationCacheLimits(maximumAttempts:257)),("bytes",AuthorityValidationCacheLimits(maximumCanonicalBytes:16*1024*1024+1)),("proofs",AuthorityValidationCacheLimits(maximumProofDescriptors:4097))] {
            checks["authority_cache_config_cannot_raise_production_"+name+"_cap"]=reject { _ = try MemoryStore(directory:directory.appendingPathComponent("raised-"+name),authorityCacheLimits:config) }
        }
        let zero=try fixture(directory.appendingPathComponent("zero-sessions"),limits:AuthorityValidationCacheLimits(maximumSessions:0))
        checks["authority_cache_zero_session_quota_denies_without_callback_capability"]=reject { _ = try zero.owner.beginAuthorityValidationSession(lease:zero.lease,sessionID:"zero",maximumAttempts:1) }
        let bytes=try fixture(directory.appendingPathComponent("zero-bytes"),limits:AuthorityValidationCacheLimits(maximumCanonicalBytes:0))
        checks["authority_cache_retained_canonical_byte_quota_denies_oversized_proof"]=reject { _ = try bytes.owner.beginAuthorityValidationSession(lease:bytes.lease,sessionID:"zero-bytes",maximumAttempts:1) }
        checks["authority_cache_byte_quota_failure_creates_no_usable_session"]=reject { _ = try bytes.owner.withAuthorityValidationSession(sessionID:"zero-bytes",lease:bytes.lease) { } }
        let proofOriginal=try fixture(directory.appendingPathComponent("zero-proofs"),limits:AuthorityValidationCacheLimits(maximumProofDescriptors:0))
        let source=proofOriginal.acceptance.binding.acceptedSource!
        let span=AuthoritySourceSpan(eventID:source.eventID,projectID:source.projectID,conversationID:source.conversationID,offset:0,byteLength:source.byteCount,sourceSHA256:source.digest,excerptSHA256:source.digest)
        try mutation(proofOriginal,"quota-sourced-policy",.policySet,policyID:"quota-sourced-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-proof-quota",value:"Synthetic sourced policy",sources:[span]))
        let proofs=try fresh(proofOriginal,"proof-quota-current")
        checks["authority_cache_source_proof_descriptor_quota_denies_instead_of_evading_proofs"]=reject { _ = try proofs.owner.beginAuthorityValidationSession(lease:proofs.lease,sessionID:"zero-proofs",maximumAttempts:1) }
        checks["authority_cache_source_proof_quota_failure_creates_no_usable_session"]=reject { _ = try proofs.owner.withAuthorityValidationSession(sessionID:"zero-proofs",lease:proofs.lease) { } }
    }
    private static func restart(_ directory:URL,_ checks:inout [String:Bool])throws {
        var originalBinding:Data?, conversationID:String?, oldOperationID:String?
        do {
            let f=try fixture(directory), session=try f.owner.beginAuthorityValidationSession(lease:f.lease,sessionID:"before-restart",maximumAttempts:4)
            _ = try f.owner.withAuthorityValidationSession(sessionID:session.sessionID,lease:f.lease) { }
            originalBinding=try canonical(f.acceptance.binding); conversationID=f.conversation.id; oldOperationID=session.operationID
        }
        let owner=try MemoryStore(directory:directory), clock=Clock()
        let oldLease=EpisodeLease(ledger:owner,episodeID:"cache-episode",clock:clock)
        checks["authority_cache_restart_destroys_private_session_handle"]=reject { _ = try owner.withAuthorityValidationSession(sessionID:"before-restart",lease:oldLease) { } }
        checks["authority_cache_restart_never_recreates_old_session_as_new_permission"]=reject { _ = try owner.beginAuthorityValidationSession(lease:oldLease,sessionID:"before-restart",maximumAttempts:4) }
        checks["authority_cache_restart_preserves_original_binding_bytes"]=try canonical(owner.managedEpisodeBinding(id:"cache-episode")!) == originalBinding
        let state=try owner.authorityStateSnapshot()
        let accepted=try owner.acceptManagedHumanRequest(conversationID:conversationID!,turnID:"post-restart-turn",humanEventID:"post-restart-human",episodeID:"post-restart-episode",requestID:"post-restart-request",text:"Synthetic post-restart input",limits:EpisodeLimits(),authority:AuthorityContext(ownerID:state.ownerID,origin:.humanHost),clock:clock.now())
        let freshLease=EpisodeLease(ledger:owner,episodeID:accepted.episode.id,clock:clock)
        checks["authority_cache_durable_old_session_work_id_blocks_recreation_for_fresh_episode"]=reject { _ = try owner.beginAuthorityValidationSession(lease:freshLease,sessionID:"before-restart",maximumAttempts:4) }
        let new=try owner.beginAuthorityValidationSession(lease:freshLease,sessionID:"after-restart",maximumAttempts:4)
        _ = try owner.withAuthorityValidationSession(sessionID:new.sessionID,lease:freshLease) { }
        checks["authority_cache_restart_new_session_requires_new_work_and_funded_replay"]=new.operationID != oldOperationID && owner.authorityValidationCacheDiagnostics().fullReplays > 0
    }
}
