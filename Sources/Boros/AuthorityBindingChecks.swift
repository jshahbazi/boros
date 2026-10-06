import Foundation
import CryptoKit
import CSQLite
import Darwin

/// Private synthetic acceptance and provenance fixtures; output contains fixed
/// Boolean keys only. These checks confer no processing or mutation capability.
enum AuthorityBindingChecks {
    enum CheckError: Error { case invalid }
    static func run() throws -> [String:Bool] {
        guard let resolved=realpath(FileManager.default.temporaryDirectory.path,nil) else { throw CheckError.invalid }
        let root=URL(fileURLWithPath:String(cString:resolved),isDirectory:true); free(resolved)
        let scratch=root.appendingPathComponent("boros-authority-binding-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:scratch) }
        var checks:[String:Bool]=[:]
        let groups:[(String,(URL,inout [String:Bool])throws->Void)]=[("validation_regressions",validationRegressions),("local_read",localRead),("validation",validation),("acceptance",acceptance),("lifecycle",lifecycle),("work",work),("archive",archive),("corruption",corruption)]
        for (name,body) in groups { do { try body(scratch.appendingPathComponent(name),&checks) } catch { checks["authority_binding_"+name+"_fixture"]=false } }
        return checks
    }
    private static func clock(_ milliseconds:Int64=100)->EpisodeClockSnapshot {
        EpisodeClockSnapshot(domain:"synthetic-binding-clock",continuousNanoseconds:UInt64(milliseconds)*1_000_000,utc:Date(timeIntervalSince1970:Double(milliseconds)/1000+0.0001))
    }
    private static func limits()->EpisodeLimits { var value=EpisodeLimits(); value.deadlineMilliseconds=120000; return value }
    private static func context(_ store:MemoryStore)throws->AuthorityContext { AuthorityContext(ownerID:try store.authorityStateSnapshot().ownerID,origin:.humanHost) }
    private static func accept(_ store:MemoryStore,_ conversation:String,_ name:String,text:String="Synthetic accepted request",intent:HumanTaskIntent = .retainOrCreate,at:Int64=100,authority:AuthorityContext?=nil)throws->ManagedAcceptance {
        try store.acceptManagedHumanRequest(conversationID:conversation,turnID:name+"-turn",humanEventID:name+"-human",episodeID:name+"-episode",requestID:name+"-request",text:text,limits:limits(),authority:try authority ?? context(store),taskIntent:intent,clock:clock(at))
    }
    private static func bytes<T:Encodable>(_ value:T)throws->Data { try AuthorityStateKernel.canonical(value) }
    private static func rejects(_ body:()throws->Void)->Bool { do { try body(); return false } catch { return true } }
    private static func database<T>(_ directory:URL,_ body:(OpaquePointer)throws->T)throws->T {
        var raw:OpaquePointer?; guard sqlite3_open_v2(directory.appendingPathComponent("memory.sqlite3").path,&raw,SQLITE_OPEN_READWRITE,nil)==SQLITE_OK,let handle=raw else { throw CheckError.invalid }
        defer { sqlite3_close(handle) }; sqlite3_busy_timeout(handle,3000); return try body(handle)
    }
    private static func counts(_ directory:URL)throws->[Int] { try database(directory) { db in try ["events","episodes","authority_tasks","authority_episode_bindings","episode_work","authority_work_bindings"].map { name in try AuthorityStateKernel.rows(db,"SELECT count(*) FROM "+name)[0][0].integer } } }
    private static func bindingBytes(_ directory:URL)throws->[Data] { try database(directory) { db in try AuthorityBindings.tableNames.flatMap { name in try AuthorityStateKernel.rows(db,"SELECT payload FROM "+name+" ORDER BY id COLLATE BINARY").map { guard let value=$0[0].bytes else { throw CheckError.invalid }; return value } } } }
    private static func mutation(_ store:MemoryStore,_ name:String,_ operation:AuthorityOperation,task:String?=nil,project:String?=nil,conversation:String?=nil,expectedTask:Int?=nil,policyID:String?=nil,policy:AuthorityPolicyDefinition?=nil,at:Int64=100)throws {
        let state=try store.authorityStateSnapshot()
        _ = try store.applyAuthorityOperation(request:AuthorityOperationRequest(requestID:name,expectedRevision:state.revision,operation:operation,taskID:task,projectID:project,conversationID:conversation,policyID:policyID,expectedTaskRevision:expectedTask ?? (operation == .taskNew ? nil:state.tasks.first(where: { $0.id == task })?.revision),policy:policy),authority:context(store),now:at)
    }
    private static func acceptance(_ directory:URL,_ checks:inout [String:Bool])throws {
        var owner:MemoryStore?=try MemoryStore(directory:directory)
        let conversation=try owner!.createConversation(projectID:"synthetic-binding-project",title:"Synthetic binding")
        let initial=try owner!.authorityStateSnapshot(), payload=String(repeating:"Synthetic complete capture café\n",count:2000)+"\0tail"
        let first=try accept(owner!,conversation.id,"first",text:payload)
        let after=try owner!.authorityStateSnapshot(), events=try owner!.events(conversationID:conversation.id)
        checks["authority_binding_first_human_creates_active_selected_task"]=after.tasks.count == 1 && after.tasks[0].state == .active && after.bindings.count == 1 && first.binding.taskID == after.tasks[0].id
        checks["authority_binding_first_human_commits_task_capture_episode_atomically"]=try counts(directory).prefix(4).elementsEqual([1,1,1,1]) && events[0].text.utf8.elementsEqual(payload.utf8) && events[0].status == .complete
        checks["authority_binding_first_human_increments_control_once"]=after.revision == initial.revision+1 && after.controlEpoch == initial.controlEpoch+1
        checks["authority_binding_first_human_full_source_digest"]=first.binding.acceptedSource?.byteCount == payload.utf8.count && first.binding.acceptedSource?.digest == AuthorityStateKernel.digest(Data(payload.utf8))
        let second=try accept(owner!,conversation.id,"second",at:101), retained=try owner!.authorityStateSnapshot()
        checks["authority_binding_subsequent_turn_retains_task_and_epoch"]=second.binding.taskID == first.binding.taskID && second.binding.controlEpoch == first.binding.controlEpoch && retained.tasks.count == 1 && retained.revision == after.revision
        let original=try bytes(first.binding), before=try counts(directory)
        checks["authority_binding_retry_original_identity_and_capture"]=try bytes(accept(owner!,conversation.id,"first",text:payload,at:102).binding) == original && counts(directory) == before
        checks["authority_binding_changed_text_retry_rejected"]=rejects { _ = try accept(owner!,conversation.id,"first",text:payload+"changed",at:102) }
        checks["authority_binding_changed_task_intent_retry_rejected"]=rejects { _ = try accept(owner!,conversation.id,"first",text:payload,intent:.new(taskID:"changed-intent"),at:102) }
        checks["authority_binding_wrong_owner_cannot_accept"]=rejects { _ = try accept(owner!,conversation.id,"wrong-owner",at:900,authority:AuthorityContext(ownerID:"unrelated-synthetic-owner",origin:.humanHost)) }
        checks["authority_binding_changed_authenticated_origin_retry_rejected"]=rejects { _ = try accept(owner!,conversation.id,"first",text:payload,at:102,authority:AuthorityContext(ownerID:initial.ownerID,origin:.humanCLI)) }
        checks["authority_binding_duplicate_host_request_other_episode_rejected"]=rejects { _ = try owner!.acceptManagedHumanRequest(conversationID:conversation.id,turnID:"dup-turn",humanEventID:"dup-human",episodeID:"dup-episode",requestID:"first-request",text:"Synthetic duplicate",limits:limits(),authority:context(owner!),clock:clock(102)) }
        for origin in [AuthorityOrigin.imported,.model,.quoted,.document,.subagent] {
            let prefix="unauthorized-"+origin.rawValue
            checks["authority_binding_"+origin.rawValue+"_origin_cannot_accept"]=rejects { _ = try accept(owner!,conversation.id,prefix,at:900,authority:AuthorityContext(ownerID:initial.ownerID,origin:origin)) }
        }
        checks["authority_binding_rejected_origin_does_not_advance_clock"]=try owner!.authorityStateSnapshot().timeHighWater == 102
        checks["authority_binding_failed_retry_and_duplicates_leave_no_partial_rows"]=try counts(directory) == before
        try mutation(owner!,"complete-original",.taskComplete,task:first.binding.taskID,at:103)
        checks["authority_binding_retry_after_lifecycle_returns_original_binding"]=try bytes(accept(owner!,conversation.id,"first",text:payload,at:104).binding) == original
        owner=nil
        owner=try MemoryStore(directory:directory)
        checks["authority_binding_retry_after_startup_returns_original_binding"]=try bytes(accept(owner!,conversation.id,"first",text:payload,at:105).binding) == original
        checks["authority_binding_startup_retains_historical_binding_epoch"]=try owner!.authorityStateSnapshot().controlEpoch > first.binding.controlEpoch && owner!.managedEpisodeBinding(id:first.episode.id)?.controlEpoch == first.binding.controlEpoch
        try database(directory) { try AuthorityBindingJournal.validate(database:$0) }
        checks["authority_binding_historical_binding_validates_after_task_completion_and_startup"]=true
    }
    private static func lifecycle(_ directory:URL,_ checks:inout [String:Bool])throws {
        let owner=try MemoryStore(directory:directory), conversation=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic lifecycle")
        let first=try accept(owner,conversation.id,"initial"), task=first.binding.taskID!
        try mutation(owner,"suspend",.taskSuspend,task:task)
        var before=try counts(directory)
        checks["authority_binding_suspended_selection_refuses_acceptance"]=rejects { _ = try accept(owner,conversation.id,"suspended") }
        checks["authority_binding_suspended_acceptance_leaves_no_partial_capture_episode_task"]=try counts(directory) == before
        try mutation(owner,"resume",.taskResume,task:task)
        try mutation(owner,"complete",.taskComplete,task:task)
        before=try counts(directory)
        checks["authority_binding_completed_selection_refuses_acceptance"]=rejects { _ = try accept(owner,conversation.id,"completed") }
        checks["authority_binding_completed_acceptance_leaves_no_partial_rows"]=try counts(directory) == before
        let fresh=try accept(owner,conversation.id,"new-explicit",intent:.new(taskID:"explicit-new-task"))
        checks["authority_binding_explicit_new_selects_new_active_task"]=fresh.binding.taskID == "explicit-new-task" && fresh.binding.taskID != task
        try mutation(owner,"other-task",.taskNew,task:"other-active-task",project:"synthetic-binding-project")
        let target=try owner.authorityStateSnapshot().tasks.first { $0.id == "other-active-task" }!
        before=try counts(directory)
        checks["authority_binding_explicit_select_stale_task_revision_refused"]=rejects { _ = try accept(owner,conversation.id,"stale-select",intent:.select(taskID:target.id,expectedRevision:target.revision+1)) }
        checks["authority_binding_stale_select_rolls_back_capture_and_episode"]=try counts(directory) == before
        let selected=try accept(owner,conversation.id,"valid-select",intent:.select(taskID:target.id,expectedRevision:target.revision))
        checks["authority_binding_explicit_select_freezes_exact_task_revision"]=selected.binding.taskID == target.id && selected.binding.taskRevision == target.revision
        try mutation(owner,"foreign-task",.taskNew,task:"foreign-task",project:"other-project")
        before=try counts(directory)
        checks["authority_binding_cross_project_select_refused"]=rejects { _ = try accept(owner,conversation.id,"foreign-select",intent:.select(taskID:"foreign-task",expectedRevision:0)) }
        checks["authority_binding_cross_project_select_no_partial_rows"]=try counts(directory) == before
        let definition=AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-policy",value:"Synthetic policy",expiresAt:200)
        try mutation(owner,"dated-policy",.policySet,policyID:"dated-policy",policy:definition)
        try mutation(owner,"suspend-dated",.taskSuspend,task:target.id)
        let prior=try owner.authorityStateSnapshot(); before=try counts(directory)
        checks["authority_binding_expired_policy_acceptance_with_suspended_task_refused"]=rejects { _ = try accept(owner,conversation.id,"expired-refused",at:200) }
        let after=try owner.authorityStateSnapshot()
        checks["authority_binding_due_expiry_commits_despite_rejected_acceptance"]=after.policies.first!.state == .expired && after.controlEpoch == prior.controlEpoch+1 && after.timeHighWater == 200
        checks["authority_binding_due_expiry_rejection_preserves_no_capture_partial_rows"]=try counts(directory) == before
        try mutation(owner,"resume-dated",.taskResume,task:target.id,at:200)
        let source=try owner.append(conversationID:conversation.id,role:.human,text:"Synthetic explicit policy source",status:.complete,turnID:"policy-source-turn",eventID:"policy-source")
        let span=AuthoritySourceSpan(eventID:source.id,projectID:source.projectID,conversationID:conversation.id,offset:0,byteLength:source.byteCount,sourceSHA256:source.digest,excerptSHA256:source.digest)
        try mutation(owner,"source-backed-policy",.policySet,policyID:"source-backed-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.task,projectID:"synthetic-binding-project",taskID:target.id),rule:"source-backed",value:"Synthetic sourced value",sources:[span]),at:200)
        let bound=try accept(owner,conversation.id,"source-backed",at:200)
        checks["authority_binding_resolved_policy_reference_includes_exact_active_revision"]=bound.binding.policyReferences.count == 1 && bound.binding.policyReferences[0].policyID == "source-backed-policy" && bound.binding.policyReferences[0].revision == 0
        checks["authority_binding_resolution_digest_binds_actual_selected_policies"]=try bound.binding.resolutionSHA256 == AuthorityBindings.resolutionSHA256(state:owner.authorityStateSnapshot(),projectID:source.projectID,taskID:target.id)
        try mutation(owner,"conflict-policy",.policySet,policyID:"conflict-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.task,projectID:"synthetic-binding-project",taskID:target.id),rule:"source-backed",value:"Conflicting synthetic value"),at:200)
        before=try counts(directory)
        checks["authority_binding_policy_conflict_refuses_new_acceptance"]=rejects { _ = try accept(owner,conversation.id,"conflict",at:200) }
        checks["authority_binding_policy_conflict_does_not_partially_capture"]=try counts(directory) == before
        let unselected=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic unselected")
        try mutation(owner,"global-conflict-one",.policySet,policyID:"global-conflict-one",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"global-conflict",value:"Synthetic first"),at:200)
        try mutation(owner,"global-conflict-two",.policySet,policyID:"global-conflict-two",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"global-conflict",value:"Synthetic second"),at:200)
        let atomicState=try bytes(owner.authorityStateSnapshot()); before=try counts(directory)
        checks["authority_binding_post_task_creation_conflict_refuses_acceptance"]=rejects { _ = try accept(owner,unselected.id,"atomic-conflict",intent:.new(taskID:"rolled-back-new-task"),at:200) }
        checks["authority_binding_post_task_creation_failure_rolls_back_control_journal_and_all_rows"]=try bytes(owner.authorityStateSnapshot()) == atomicState && counts(directory) == before
    }
    private static func request(_ id:String,kind:EpisodeWorkKind = .retrieval,adapter:String="synthetic-memory",snapshot:Data?=nil,parent:String?=nil)->EpisodeWorkRequest {
        EpisodeWorkRequest(id:id,parentID:parent,kind:kind,resources:EpisodeResources(memoryOperations:1,metadataRows:4),adapterIdentity:adapter,snapshot:snapshot,inputTokensKnown:true)
    }
    private static func work(_ directory:URL,_ checks:inout [String:Bool])throws {
        let owner=try MemoryStore(directory:directory), conversation=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic work")
        let accepted=try accept(owner,conversation.id,"work-input"), source=accepted.binding.acceptedSource!
        let dependency=AuthoritySourceDependency(source:source,offset:0,byteLength:source.byteCount,excerptSHA256:source.digest)
        let initial=request("managed-retrieval"), route=AuthorityLocalRoute(kind:.localMemory,identity:initial.adapterIdentity)
        let prepared=try owner.prepareManagedWork(episodeID:accepted.episode.id,request:initial,route:route,dependencies:[dependency],clock:clock())
        let binding=try database(directory) { try AuthorityBindingJournal.managedWork(database:$0,id:initial.id)! }
        checks["authority_binding_managed_work_prepared_immutable_request_and_episode_digest"]=try binding.workID == initial.id && binding.episodeBindingSHA256 == AuthorityStateKernel.digest(try bytes(accepted.binding)) && prepared.state == .prepared
        checks["authority_binding_managed_work_exact_source_and_route"]=try bytes(binding.sourceDependencies) == bytes([dependency]) && binding.localRoute.kind == route.kind && binding.localRoute.identity == route.identity
        let prior=try bindingBytes(directory)
        checks["authority_binding_managed_work_exact_retry_idempotent"]=try owner.prepareManagedWork(episodeID:accepted.episode.id,request:initial,route:route,dependencies:[dependency],clock:clock()) == prepared && bindingBytes(directory) == prior
        checks["authority_binding_changed_route_retry_refused"]=rejects { _ = try owner.prepareManagedWork(episodeID:accepted.episode.id,request:initial,route:AuthorityLocalRoute(kind:.localMemory,identity:"changed-memory"),dependencies:[dependency],clock:clock()) }
        checks["authority_binding_changed_dependencies_retry_refused"]=rejects { _ = try owner.prepareManagedWork(episodeID:accepted.episode.id,request:initial,route:route,dependencies:[],clock:clock()) }
        checks["authority_binding_public_legacy_reserve_refuses_managed_episode"]=rejects { _ = try owner.reserveEpisodeWork(episodeID:accepted.episode.id,request:request("legacy-on-managed"),clock:clock()) }
        checks["authority_binding_public_arm_refuses_managed_work"]=rejects { _ = try owner.armEpisodeWork(episodeID:accepted.episode.id,operationID:initial.id,expectedRevision:prepared.revision,clock:clock()) }
        var starts=0
        checks["authority_binding_public_handoff_refuses_managed_work"]=rejects { _ = try owner.performEpisodeHandoff(episodeID:accepted.episode.id,operationID:initial.id,expectedRevision:prepared.revision,clock:clock()) { starts += 1 } }
        checks["authority_binding_refused_managed_dispatch_has_no_acceptance_or_charge"]=try starts == 0 && owner.episodeWork(episodeID:accepted.episode.id,operationID:initial.id)?.state == .prepared && owner.episodeReceipt(id:accepted.episode.id,clock:clock()).charged == .zero
        let remoteRoutes=["https://localhost/v1","http://example.invalid/v1","http://localhost@evil.invalid/v1","http://localhost/v1?query=synthetic","http://localhost/v1#fragment","http://localhost:0/v1"]
        for (index,url) in remoteRoutes.enumerated() {
            checks["authority_binding_unsupported_http_route_"+String(index)+"_refused"]=rejects { _ = try owner.prepareManagedWork(episodeID:accepted.episode.id,request:request("bad-route-"+String(index),adapter:url),route:AuthorityLocalRoute(kind:.loopbackHTTP,identity:url),clock:clock()) }
        }
        checks["authority_binding_native_route_on_retrieval_refused"]=rejects { _ = try owner.prepareManagedWork(episodeID:accepted.episode.id,request:request("bad-native"),route:AuthorityLocalRoute(kind:.localNative,identity:"synthetic-memory"),clock:clock()) }
        let foreign=try owner.createConversation(projectID:"other-project",title:"Synthetic foreign")
        let foreignEvent=try owner.append(conversationID:foreign.id,role:.human,text:"Synthetic foreign source",status:.complete,turnID:"foreign-source-turn",eventID:"foreign-source")
        let foreignSource=try owner.sourceReference(eventID:foreignEvent.id,projectID:foreign.projectID)!
        checks["authority_binding_cross_project_work_dependency_refused"]=rejects { _ = try owner.prepareManagedWork(episodeID:accepted.episode.id,request:request("foreign-dependency"),route:route,dependencies:[AuthoritySourceDependency(source:foreignSource,offset:0,byteLength:foreignSource.byteCount,excerptSHA256:foreignSource.digest)],clock:clock()) }
        checks["authority_binding_duplicate_source_dependency_refused"]=rejects { _ = try owner.prepareManagedWork(episodeID:accepted.episode.id,request:request("duplicate-dependency"),route:route,dependencies:[dependency,dependency],clock:clock()) }
        checks["authority_binding_unsupported_artifact_lineage_refused"]=rejects { try database(directory) { db in var changed=binding; changed.artifactLineage=["unsupported-artifact"]; try AuthorityBindings.validateWork(database:db,binding:changed,verifySourceBytes:true) } }
        checks["authority_binding_changed_work_request_digest_refused"]=rejects { try database(directory) { db in let changed=AuthorityWorkBinding(workID:binding.workID,episodeID:binding.episodeID,episodeBindingSHA256:binding.episodeBindingSHA256,requestSHA256:String(repeating:"0",count:64),localRoute:route,sourceDependencies:[dependency]); try AuthorityBindings.validateWork(database:db,binding:changed,verifySourceBytes:true) } }
        let body=Data("{\"model\":\"synthetic-local\",\"stream\":true}".utf8), url="http://127.0.0.1:11234/v1/chat/completions"
        let withBody=try owner.prepareManagedWork(episodeID:accepted.episode.id,request:request("body-binding",adapter:url,snapshot:body),route:AuthorityLocalRoute(kind:.loopbackHTTP,identity:url),clock:clock())
        let bodyBinding=try database(directory) { try AuthorityBindingJournal.managedWork(database:$0,id:withBody.id)! }
        checks["authority_binding_exact_snapshot_body_digest_retained"]=bodyBinding.snapshotSHA256 == AuthorityStateKernel.digest(body)
        let native=EpisodeWorkRequest(id:"native-body-binding",parentID:nil,kind:.nativeInference,resources:EpisodeResources(inputTokens:3,outputTokens:2,modelCalls:1),adapterIdentity:"native:synthetic-local",snapshot:body,inputTokensKnown:true)
        let nativeWork=try owner.prepareManagedWork(episodeID:accepted.episode.id,request:native,route:AuthorityLocalRoute(kind:.localNative,identity:native.adapterIdentity),clock:clock())
        checks["authority_binding_supported_native_route_prepares_exact_body"]=try nativeWork.state == .prepared && database(directory) { try AuthorityBindingJournal.managedWork(database:$0,id:nativeWork.id)?.snapshotSHA256 } == AuthorityStateKernel.digest(body)
        checks["authority_binding_native_managed_dispatch_remains_refused"]=rejects { _ = try owner.armEpisodeWork(episodeID:accepted.episode.id,operationID:nativeWork.id,expectedRevision:nativeWork.revision,clock:clock()) }
        try database(directory) { try AuthorityBindingJournal.validate(database:$0) }
        checks["authority_binding_managed_work_complete_offline_journal_validates"]=true
    }
    private static func archive(_ directory:URL,_ checks:inout [String:Bool])throws {
        let source=directory.appendingPathComponent("source"), archive=directory.appendingPathComponent("archive"), restored=directory.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let owner=try MemoryStore(directory:source), conversation=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic archive")
        let first=try accept(owner,conversation.id,"archive-input")
        _ = try owner.prepareManagedWork(episodeID:first.episode.id,request:request("archive-work"),route:AuthorityLocalRoute(kind:.localMemory,identity:"synthetic-memory"),clock:clock())
        _ = try owner.acceptRequestAndBeginEpisode(conversationID:conversation.id,turnID:"legacy-turn",humanEventID:"legacy-human",episodeID:"legacy-episode",text:"Synthetic historical capture",limits:limits(),clock:clock())
        let retained=try bindingBytes(source), inventory=try database(source) { try AuthorityBindingJournal.inventory(database:$0) }
        checks["authority_binding_inventory_explicit_managed_and_legacy_classification"]=inventory.managedEpisodes == 1 && inventory.legacyEpisodes == 1 && inventory.managedWork == 1 && inventory.legacyWork == 0
        let manifest=try BackupArchive.create(from:owner,at:archive)
        checks["authority_binding_archive_manifest_inventory_exact"]=manifest.inventory.authorityBindingInventory == inventory && manifest.databaseSchema == 7
        checks["authority_binding_archive_verify_exact_manifest"]=try BackupArchive.verify(at:archive) == manifest
        _ = try BackupArchive.restore(from:archive,to:restored,authority:.unmanagedNoDeletion)
        let restoredOwner=try MemoryStore(directory:restored)
        checks["authority_binding_restore_preserves_original_binding_record_bytes"]=try bindingBytes(restored) == retained
        checks["authority_binding_restore_preserves_accepted_text"]=try restoredOwner.events(conversationID:conversation.id).first!.text == "Synthetic accepted request"
        checks["authority_binding_restore_startup_makes_historical_binding_stale"]=try restoredOwner.authorityStateSnapshot().controlEpoch > first.binding.controlEpoch && restoredOwner.managedEpisodeBinding(id:first.episode.id)?.controlEpoch == first.binding.controlEpoch
        checks["authority_binding_restore_inventory_unchanged"]=try database(restored) { try AuthorityBindingJournal.inventory(database:$0) } == inventory
        checks["authority_binding_restore_exact_retry_returns_original_binding"]=try bytes(accept(restoredOwner,conversation.id,"archive-input",at:101).binding) == bytes(first.binding)
    }
    private static func localRead(_ directory:URL,_ checks:inout [String:Bool])throws {
        let owner=try MemoryStore(directory:directory), project="synthetic-binding-project"
        func descriptor(_ id:String)->EpisodeLocalReadBinding { EpisodeLocalReadBinding(initiator:.localReadCLI,purpose:.sourcePage,requestID:id,descriptorVersion:"synthetic-page-v1",descriptorSHA256:AuthorityStateKernel.digest(Data(id.utf8))) }
        let first=try owner.acceptManagedLocalRead(episodeID:"read-episode",projectID:project,binding:descriptor("read-request"),limits:limits(),authority:context(owner),clock:clock())
        let before=try counts(directory), state=try owner.authorityStateSnapshot()
        checks["authority_binding_local_read_has_no_invented_task_or_capture"]=first.binding.taskID == nil && first.binding.conversationID == nil && first.binding.acceptedSource == nil && before[0] == 0 && before[2] == 0
        checks["authority_binding_local_read_matches_exact_origin_request"]=first.binding.requestID == "read-request" && first.episode.origin == .localRead(descriptor("read-request"))
        checks["authority_binding_local_read_retry_original_binding"]=try bytes(owner.acceptManagedLocalRead(episodeID:"read-episode",projectID:project,binding:descriptor("read-request"),limits:limits(),authority:context(owner),clock:clock()).binding) == bytes(first.binding)
        checks["authority_binding_local_read_duplicate_request_rejected"]=rejects { _ = try owner.acceptManagedLocalRead(episodeID:"duplicate-read",projectID:project,binding:descriptor("read-request"),limits:limits(),authority:context(owner),clock:clock()) }
        checks["authority_binding_local_read_duplicate_no_partial_rows"]=try counts(directory) == before
        checks["authority_binding_local_read_untrusted_origin_rejected"]=rejects { _ = try owner.acceptManagedLocalRead(episodeID:"untrusted-read",projectID:project,binding:descriptor("untrusted-request"),limits:limits(),authority:AuthorityContext(ownerID:state.ownerID,origin:.model),clock:clock()) }
        _ = try owner.validateManagedAuthority(episodeID:first.episode.id,clock:clock())
        checks["authority_binding_local_read_managed_validation_without_human_capture"]=true
        try mutation(owner,"read-task-new",.taskNew,task:"read-task",project:project)
        let task=try owner.authorityStateSnapshot().tasks.first!
        let scoped=try owner.acceptManagedLocalRead(episodeID:"scoped-read",projectID:project,binding:descriptor("scoped-request"),limits:limits(),authority:context(owner),taskID:task.id,clock:clock())
        checks["authority_binding_local_read_explicit_task_freezes_revision"]=scoped.binding.taskID == task.id && scoped.binding.taskRevision == task.revision
        checks["authority_binding_local_read_changed_task_retry_rejected"]=rejects { _ = try owner.acceptManagedLocalRead(episodeID:"read-episode",projectID:project,binding:descriptor("read-request"),limits:limits(),authority:context(owner),taskID:task.id,clock:clock()) }
        try mutation(owner,"read-task-suspend",.taskSuspend,task:task.id)
        let prior=try counts(directory)
        checks["authority_binding_local_read_suspended_explicit_task_rejected"]=rejects { _ = try owner.acceptManagedLocalRead(episodeID:"suspended-read",projectID:project,binding:descriptor("suspended-read-request"),limits:limits(),authority:context(owner),taskID:task.id,clock:clock()) }
        checks["authority_binding_local_read_suspended_rejection_atomic"]=try counts(directory) == prior
    }
    private static func validation(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let source=directory.appendingPathComponent("source"), owner=try MemoryStore(directory:source)
        let conversation=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic validation")
        let accepted=try accept(owner,conversation.id,"validated"), original=try bytes(accepted.binding)
        let before=try owner.episodeReceipt(id:accepted.episode.id,clock:clock())
        let result=try owner.validateManagedAuthority(episodeID:accepted.episode.id,clock:clock(101))
        let after=try owner.episodeReceipt(id:accepted.episode.id,clock:clock(101))
        checks["authority_binding_validation_four_phases_settle_before_receipt"]=try result.operationIDs.count == 4 && Set(result.operationIDs).count == 4 && (try result.operationIDs.allSatisfy { try owner.episodeWork(episodeID:accepted.episode.id,operationID:$0)?.state == .completed })
        checks["authority_binding_validation_receipt_exact_binding_and_epoch"]=result.episodeBindingSHA256 == AuthorityStateKernel.digest(original) && result.controlEpoch == accepted.binding.controlEpoch && result.authorityRevision == accepted.binding.authorityRevision
        checks["authority_binding_validation_charges_metadata_and_original_bytes"]=try result.charged.memoryOperations == 4 && result.charged.metadataRows > 0 && result.charged.rawSourceBytes >= accepted.binding.acceptedSource!.byteCount && after.charged == (try before.charged.adding(result.charged)) && after.held == .zero
        let bindingsBefore=try bindingBytes(source)
        try mutation(owner,"invalidate-validation",.taskSuspend,task:accepted.binding.taskID,at:102)
        let chargedBefore=try owner.episodeReceipt(id:accepted.episode.id,clock:clock(102)).charged
        checks["authority_binding_stale_epoch_validation_refused"]=rejects { _ = try owner.validateManagedAuthority(episodeID:accepted.episode.id,clock:clock(102)) }
        let failed=try owner.episodeReceipt(id:accepted.episode.id,clock:clock(102))
        checks["authority_binding_stale_validation_retains_completed_and_failed_phase_charges"]=failed.charged.memoryOperations == chargedBefore.memoryOperations+4 && failed.charged.rawSourceBytes > chargedBefore.rawSourceBytes && failed.held == .zero
        checks["authority_binding_stale_validation_does_not_refresh_original_binding"]=try bytes(owner.managedEpisodeBinding(id:accepted.episode.id)!) == original && Array(try bindingBytes(source).prefix(1)) == Array(bindingsBefore.prefix(1))
        let exhaustedDirectory=directory.appendingPathComponent("exhausted"), exhausted=try MemoryStore(directory:exhaustedDirectory)
        let exhaustedConversation=try exhausted.createConversation(projectID:"synthetic-binding-project",title:"Synthetic exhaustion")
        var small=limits(); small.resources.memoryOperations=3
        let low=try exhausted.acceptManagedHumanRequest(conversationID:exhaustedConversation.id,turnID:"low-turn",humanEventID:"low-human",episodeID:"low-episode",requestID:"low-request",text:"Synthetic allowance",limits:small,authority:context(exhausted),clock:clock())
        checks["authority_binding_validation_exhaustion_refuses_receipt"]=rejects { _ = try exhausted.validateManagedAuthority(episodeID:low.episode.id,clock:clock()) }
        let exhaustedReceipt=try exhausted.episodeReceipt(id:low.episode.id,clock:clock())
        checks["authority_binding_validation_exhaustion_retains_first_three_phase_charges"]=exhaustedReceipt.state == .budgetExceeded && exhaustedReceipt.charged.memoryOperations == 3 && exhaustedReceipt.charged.metadataRows > 0 && exhaustedReceipt.held == .zero
        checks["authority_binding_validation_exhaustion_has_no_replay_work"]=try database(exhaustedDirectory) { try AuthorityStateKernel.rows($0,"SELECT count(*) FROM episode_work WHERE kind='authorityValidation'")[0][0].integer == 3 }
        let byteDirectory=directory.appendingPathComponent("byte-exhausted"), byteOwner=try MemoryStore(directory:byteDirectory)
        let byteConversation=try byteOwner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic byte exhaustion")
        var noBytes=limits(); noBytes.resources.rawSourceBytes=0
        let byteAccepted=try byteOwner.acceptManagedHumanRequest(conversationID:byteConversation.id,turnID:"byte-turn",humanEventID:"byte-human",episodeID:"byte-episode",requestID:"byte-request",text:"Synthetic accepted request",limits:noBytes,authority:context(byteOwner),clock:clock())
        try database(byteDirectory) { try AuthorityStateKernel.execute($0,"UPDATE events SET payload=? WHERE id='byte-human'",[.bytes(Data("Synthetix accepted request".utf8))]) }
        var exhaustion=false
        do { _ = try byteOwner.validateManagedAuthority(episodeID:byteAccepted.episode.id,clock:clock()) } catch EpisodeBudgetError.exhausted { exhaustion=true } catch { }
        checks["authority_binding_zero_byte_allowance_exhausts_before_original_payload_proof"]=exhaustion
        let byteReceipt=try byteOwner.episodeReceipt(id:byteAccepted.episode.id,clock:clock())
        checks["authority_binding_zero_byte_allowance_retains_only_metadata_phase_charge"]=byteReceipt.charged.memoryOperations == 1 && byteReceipt.charged.rawSourceBytes == 0 && byteReceipt.held == .zero
        checks["authority_binding_zero_byte_allowance_has_no_payload_phase_work"]=try database(byteDirectory) { try AuthorityStateKernel.rows($0,"SELECT count(*) FROM episode_work WHERE kind='authorityValidation'")[0][0].integer == 1 }
        _ = try owner.finishEpisode(episodeID:accepted.episode.id,reason:.cancelled,clock:clock(102))
        let settled=try owner.episodeWork(episodeID:accepted.episode.id,operationID:result.operationIDs[0])!
        let late=try owner.settleEpisodeWork(episodeID:accepted.episode.id,operationID:settled.id,settlement:EpisodeWorkSettlement(receiptID:settled.receiptID!,outcome:.completed,observed:nil,evidence:nil),clock:clock(102))
        checks["authority_binding_late_accounting_retry_preserves_original_receipt"]=late == settled
        checks["authority_binding_late_accounting_retry_does_not_reopen_cancelled_episode"]=try owner.episodeReceipt(id:accepted.episode.id,clock:clock(102)).state == .cancelled && bytes(owner.managedEpisodeBinding(id:accepted.episode.id)!) == original
        let temporalDirectory=directory.appendingPathComponent("temporal"), temporal=try MemoryStore(directory:temporalDirectory)
        let temporalConversation=try temporal.createConversation(projectID:"synthetic-binding-project",title:"Synthetic temporal validation")
        try mutation(temporal,"temporal-policy",.policySet,policyID:"temporal-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"synthetic-temporal",value:"Synthetic dated policy",expiresAt:200))
        let dated=try accept(temporal,temporalConversation.id,"dated-validation")
        checks["authority_binding_due_expiry_validation_refuses_old_binding"]=rejects { _ = try temporal.validateManagedAuthority(episodeID:dated.episode.id,clock:clock(200)) }
        let expired=try temporal.authorityStateSnapshot()
        checks["authority_binding_due_expiry_validation_commits_temporal_transition"]=expired.policies[0].state == .expired && expired.controlEpoch == dated.binding.controlEpoch+1 && expired.timeHighWater == 200
        checks["authority_binding_due_expiry_validation_preserves_cost_and_binding"]=try temporal.episodeReceipt(id:dated.episode.id,clock:clock(200)).charged.memoryOperations == 4 && temporal.managedEpisodeBinding(id:dated.episode.id)?.controlEpoch == dated.binding.controlEpoch
        let corruptDirectory=directory.appendingPathComponent("changed-source"), corrupt=try MemoryStore(directory:corruptDirectory)
        let corruptConversation=try corrupt.createConversation(projectID:"synthetic-binding-project",title:"Synthetic changed source")
        let originalSource=try accept(corrupt,corruptConversation.id,"changed-source")
        try database(corruptDirectory) { try AuthorityStateKernel.execute($0,"UPDATE events SET payload=? WHERE id='changed-source-human'",[.bytes(Data("Synthetix accepted request".utf8))]) }
        checks["authority_binding_validation_checks_original_source_bytes"]=rejects { _ = try corrupt.validateManagedAuthority(episodeID:originalSource.episode.id,clock:clock()) }
        let damaged=try corrupt.episodeReceipt(id:originalSource.episode.id,clock:clock())
        checks["authority_binding_failed_original_source_proof_retains_charges"]=damaged.charged.memoryOperations == 4 && damaged.charged.rawSourceBytes >= originalSource.binding.acceptedSource!.byteCount && damaged.held == .zero
    }
    private static func validationRegressions(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let variants:[(String,String,Any)]=[
            ("unknown_version","version","authority-episode-binding-unknown"),
            ("unknown_host_constraint","hostConstraintVersion","authority-local-text-unknown"),
            ("wrong_startup_anchor","startupReceiptID","unrelated-synthetic-startup"),
            ("wrong_control_anchor","controlReceiptID","unrelated-synthetic-control")
        ]
        for (name,key,value) in variants {
            let fixture=directory.appendingPathComponent(name), owner=try MemoryStore(directory:fixture)
            let conversation=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic binding regression")
            let accepted=try accept(owner,conversation.id,name)
            try database(fixture) { try alterManaged($0,table:"authority_episode_bindings",key:key,value:value) }
            checks["authority_binding_validation_"+name+"_rehashed_record_refused"]=rejects { _ = try owner.validateManagedAuthority(episodeID:accepted.episode.id,clock:clock()) }
            let receipt=try owner.episodeReceipt(id:accepted.episode.id,clock:clock())
            checks["authority_binding_validation_"+name+"_failed_cost_retained"]=receipt.charged.memoryOperations == 4 && receipt.held == .zero
        }
        let swappedDirectory=directory.appendingPathComponent("swapped-accepted-source"), swapped=try MemoryStore(directory:swappedDirectory)
        let conversation=try swapped.createConversation(projectID:"synthetic-binding-project",title:"Synthetic swapped source")
        let accepted=try accept(swapped,conversation.id,"source-swap")
        let extra=try swapped.append(conversationID:conversation.id,role:.human,text:"Synthetic other complete request",status:.complete,turnID:"other-complete-turn",eventID:"other-complete-human")
        let reference=try swapped.sourceReference(eventID:extra.id,projectID:extra.projectID)!
        let current=try swapped.authorityStateSnapshot()
        checks["authority_binding_validation_swapped_source_fixture_has_same_epoch_resolution"]=try current.controlEpoch == accepted.binding.controlEpoch && (try AuthorityBindings.resolutionSHA256(state:current,projectID:extra.projectID,taskID:accepted.binding.taskID)) == accepted.binding.resolutionSHA256 && reference.role == .human && reference.status == .complete
        try database(swappedDirectory) { db in
            try rewrite(db,table:"authority_episode_bindings") { data in
                var row=try JSONSerialization.jsonObject(with:data) as! [String:Any],record=row["managed"] as! [String:Any]
                record["acceptedSource"]=try JSONSerialization.jsonObject(with:bytes(reference)); row["managed"]=record
                return try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
            }
        }
        checks["authority_binding_validation_swapped_complete_human_source_refused"]=rejects { _ = try swapped.validateManagedAuthority(episodeID:accepted.episode.id,clock:clock()) }
        let swappedReceipt=try swapped.episodeReceipt(id:accepted.episode.id,clock:clock())
        checks["authority_binding_validation_swapped_source_failed_cost_retained"]=swappedReceipt.charged.memoryOperations == 4 && swappedReceipt.held == .zero
        let textDirectory=directory.appendingPathComponent("text-affinity")
        var textPhases:[String]=[]
        let textOwner=try MemoryStore(directory:textDirectory,authorityValidationCheckpoint:{ textPhases.append($0) })
        let textConversation=try textOwner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic text storage")
        try mutation(textOwner,"unicode-policy",.policySet,policyID:"unicode-policy",policy:AuthorityPolicyDefinition(scope:AuthorityPolicyScope(kind:.global),rule:"unicode-storage",value:String(repeating:"café",count:128)))
        let textAccepted=try accept(textOwner,textConversation.id,"text-storage")
        try database(textDirectory) { try AuthorityStateKernel.execute($0,"UPDATE authority_operations SET request_payload=CAST(request_payload AS TEXT) WHERE request_id='unicode-policy'") }
        checks["authority_binding_validation_text_blob_affinity_fixture_has_utf8_size_gap"]=try database(textDirectory) { db in let row=try AuthorityStateKernel.rows(db,"SELECT typeof(request_payload),length(request_payload),length(CAST(request_payload AS BLOB)) FROM authority_operations WHERE request_id='unicode-policy'")[0]; return row[0].string == "text" && row[1].integer < row[2].integer }
        checks["authority_binding_validation_unicode_text_request_payload_refused_before_descriptors"]=rejects { _ = try textOwner.validateManagedAuthority(episodeID:textAccepted.episode.id,clock:clock()) } && textPhases == ["metadata"]
        let textReceipt=try textOwner.episodeReceipt(id:textAccepted.episode.id,clock:clock())
        checks["authority_binding_validation_text_affinity_retains_only_metadata_charge"]=textReceipt.charged.memoryOperations == 1 && textReceipt.charged.rawSourceBytes == 0 && textReceipt.held == .zero
        for growth in [false,true] {
            let name=growth ? "grow":"replace", raceDirectory=directory.appendingPathComponent("external-"+name)
            var phases:[String]=[], injected=false
            let race=try MemoryStore(directory:raceDirectory,authorityValidationCheckpoint:{ phase in
                phases.append(phase)
                if phase == "journal-descriptors" {
                    try database(raceDirectory) { db in
                        let row=try AuthorityStateKernel.rows(db,"SELECT request_id,request_payload FROM authority_operations WHERE request_payload IS NOT NULL ORDER BY sequence LIMIT 1")[0]
                        guard let previous=row[1].bytes else { throw CheckError.invalid }
                        let changed=Data(repeating:0x78,count:previous.count+(growth ? 4096:0))
                        try AuthorityStateKernel.execute(db,"UPDATE authority_operations SET request_payload=? WHERE request_id=?",[.bytes(changed),.text(row[0].string)])
                    }
                    injected=true
                }
            })
            let raceConversation=try race.createConversation(projectID:"synthetic-binding-project",title:"Synthetic external change")
            let bound=try accept(race,raceConversation.id,"external-"+name)
            var stale=false
            do { _ = try race.validateManagedAuthority(episodeID:bound.episode.id,clock:clock()) } catch AuthorityStateError.staleRevision { stale=true } catch { }
            checks["authority_binding_validation_external_"+name+"_after_sizing_rejected_as_stale"]=injected && stale
            checks["authority_binding_validation_external_"+name+"_fenced_before_source_or_replay_phase"]=phases == ["metadata","journal-descriptors"]
            let cost=try race.episodeReceipt(id:bound.episode.id,clock:clock())
            checks["authority_binding_validation_external_"+name+"_preserves_two_armed_phase_charges"]=cost.charged.memoryOperations == 2 && cost.charged.rawSourceBytes > 0 && cost.held == .zero
            let work=try database(raceDirectory) { try AuthorityStateKernel.rows($0,"SELECT adapter_identity,state FROM episode_work ORDER BY created_ticks,id") }
            checks["authority_binding_validation_external_"+name+"_settles_descriptor_failure_without_new_work"]=work.count == 2 && work.contains { $0[0].string == "authority-validation-v1:metadata" && $0[1].string == "completed" } && work.contains { $0[0].string == "authority-validation-v1:journal-descriptors" && $0[1].string == "failedConfirmed" }
        }
    }
    private static func corruption(_ directory:URL,_ checks:inout [String:Bool])throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let source=directory.appendingPathComponent("source"), archive=directory.appendingPathComponent("archive")
        let owner=try MemoryStore(directory:source), conversation=try owner.createConversation(projectID:"synthetic-binding-project",title:"Synthetic corruption")
        let first=try accept(owner,conversation.id,"corruption-input")
        _ = try owner.prepareManagedWork(episodeID:first.episode.id,request:request("corruption-work"),route:AuthorityLocalRoute(kind:.localMemory,identity:"synthetic-memory"),clock:clock())
        _ = try BackupArchive.create(from:owner,at:archive)
        let variants:[(String,(OpaquePointer)throws->Void)]=[
            ("missing_episode", { try AuthorityStateKernel.execute($0,"DELETE FROM authority_episode_bindings") }),
            ("missing_work", { try AuthorityStateKernel.execute($0,"DELETE FROM authority_work_bindings") }),
            ("orphan_episode", { db in try AuthorityStateKernel.execute(db,"INSERT INTO authority_episode_bindings SELECT 'orphan',payload,digest FROM authority_episode_bindings LIMIT 1") }),
            ("unknown_index", { try AuthorityStateKernel.execute($0,"CREATE INDEX extra_binding_index ON authority_episode_bindings(digest)") }),
            ("unknown_trigger", { try AuthorityStateKernel.execute($0,"CREATE TRIGGER extra_binding_trigger AFTER INSERT ON authority_episode_bindings BEGIN SELECT 1; END") }),
            ("altered_ddl", { db in try AuthorityStateKernel.execute(db,"ALTER TABLE authority_work_bindings RENAME TO old_bindings"); try AuthorityStateKernel.execute(db,"CREATE TABLE authority_work_bindings(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB,digest TEXT NOT NULL)"); try AuthorityStateKernel.execute(db,"INSERT INTO authority_work_bindings SELECT * FROM old_bindings"); try AuthorityStateKernel.execute(db,"DROP TABLE old_bindings") }),
            ("noncanonical_rehashed", { db in try rewrite(db,table:"authority_episode_bindings") { data in Data(" ".utf8)+data } }),
            ("unknown_field_rehashed", { db in try rewrite(db,table:"authority_episode_bindings") { data in var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]; object["unknown"]=true; return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) } }),
            ("wrong_epoch_rehashed", { db in try alterManaged(db,table:"authority_episode_bindings",key:"controlEpoch",value:999) }),
            ("wrong_task_revision_rehashed", { db in try alterManaged(db,table:"authority_episode_bindings",key:"taskRevision",value:999) }),
            ("wrong_resolution_rehashed", { db in try alterManaged(db,table:"authority_episode_bindings",key:"resolutionSHA256",value:String(repeating:"0",count:64)) }),
            ("wrong_request_digest_rehashed", { db in try alterManaged(db,table:"authority_work_bindings",key:"requestSHA256",value:String(repeating:"0",count:64)) }),
            ("wrong_route_rehashed", { db in try alterManaged(db,table:"authority_work_bindings",key:"localRoute",value:["kind":"loopbackHTTP","identity":"http://example.invalid/v1"]) }),
            ("artifact_lineage_rehashed", { db in try alterManaged(db,table:"authority_work_bindings",key:"artifactLineage",value:["unsupported-artifact"]) }),
            ("mixed_child_classification", { db in try rewrite(db,table:"authority_work_bindings") { data in let object=try JSONSerialization.jsonObject(with:data) as! [String:Any]; return try JSONSerialization.data(withJSONObject:["version":"authority-binding-row-v1","id":object["id"]!,"classification":"legacyUnbound"],options:[.sortedKeys]) } }),
            ("wrong_source_payload", { db in try AuthorityStateKernel.execute(db,"UPDATE events SET payload=? WHERE id=?",[.bytes(Data("Synthetix accepted request".utf8)),.text("corruption-input-human")]) })
        ]
        for (name,change) in variants {
            let fixture=directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try FileManager.default.copyItem(at:archive.appendingPathComponent("memory.sqlite3"),to:fixture.appendingPathComponent("memory.sqlite3"))
            do { try database(fixture,change) } catch { checks["authority_binding_corruption_"+name+"_setup"]=false; continue }
            checks["authority_binding_corruption_"+name+"_journal_refused"]=rejects { try database(fixture) { try AuthorityBindingJournal.validate(database:$0) } }
            checks["authority_binding_corruption_"+name+"_owner_refused"]=rejects { _ = try MemoryStore(directory:fixture) }
        }
    }
    private static func rewrite(_ database:OpaquePointer,table:String,transform:(Data)throws->Data)throws {
        let row=try AuthorityStateKernel.rows(database,"SELECT id,payload FROM "+table+" ORDER BY id COLLATE BINARY LIMIT 1")[0]
        guard let original=row[1].bytes else { throw CheckError.invalid }
        let modified=try transform(original)
        try AuthorityStateKernel.execute(database,"UPDATE "+table+" SET payload=?,digest=? WHERE id=?",[.bytes(modified),.text(AuthorityStateKernel.digest(modified)),.text(row[0].string)])
    }
    private static func alterManaged(_ database:OpaquePointer,table:String,key:String,value:Any)throws {
        try rewrite(database,table:table) { bytes in
            var row=try JSONSerialization.jsonObject(with:bytes) as! [String:Any],record=row["managed"] as! [String:Any]
            record[key]=value; row["managed"]=record
            return try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
        }
    }
}
