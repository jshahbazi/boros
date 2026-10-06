import Foundation
import CryptoKit
import CoreFoundation
import CSQLite

// This dormant state kernel confers no processing or external-action capability.
enum AuthorityStateError: Error {
    case invalid, unauthorized, conflict, staleRevision, missing, limit, integrity
    var failureCode: String { "authority_" + String(describing: self) }
}
enum AuthorityOrigin: String { case humanHost, humanCLI, imported, model, quoted, document, subagent }
struct AuthorityContext { let ownerID: String; let origin: AuthorityOrigin }
enum AuthorityOperation: String, Codable {
    case taskNew, taskSelect, taskSuspend, taskResume, taskComplete, taskCancel, taskReopen
    case policyPropose, policySet, policyActivate, policyRevoke, policySupersede
}
enum AuthorityTaskState: String, Codable { case active, suspended, completed, cancelled }
enum AuthorityPolicyState: String, Codable { case proposed, scheduled, active, revoked, expired, superseded }
enum AuthorityScopeKind: String, Codable { case global, project, task }
struct AuthorityPolicyScope: Codable {
    let kind: AuthorityScopeKind
    var projectID: String? = nil
    var taskID: String? = nil
    init(kind: AuthorityScopeKind, projectID: String? = nil, taskID: String? = nil) { self.kind = kind; self.projectID = projectID; self.taskID = taskID }
    init(from decoder: Decoder) throws {
        try authorityKeys(decoder, allowed: ["kind","projectID","taskID"], required: ["kind"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(AuthorityScopeKind.self, forKey: .kind)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID); taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
    }
}
struct AuthoritySourceSpan: Codable {
    let eventID: String; let projectID: String; let conversationID: String
    let offset: Int; let byteLength: Int; let sourceSHA256: String; let excerptSHA256: String
    init(eventID: String, projectID: String, conversationID: String, offset: Int, byteLength: Int, sourceSHA256: String, excerptSHA256: String) {
        self.eventID = eventID; self.projectID = projectID; self.conversationID = conversationID
        self.offset = offset; self.byteLength = byteLength; self.sourceSHA256 = sourceSHA256; self.excerptSHA256 = excerptSHA256
    }
    init(from decoder: Decoder) throws {
        try authorityKeys(decoder, allowed: ["eventID","projectID","conversationID","offset","byteLength","sourceSHA256","excerptSHA256"], required: ["eventID","projectID","conversationID","offset","byteLength","sourceSHA256","excerptSHA256"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try c.decode(String.self, forKey: .eventID); projectID = try c.decode(String.self, forKey: .projectID); conversationID = try c.decode(String.self, forKey: .conversationID)
        offset = try c.decode(Int.self, forKey: .offset); byteLength = try c.decode(Int.self, forKey: .byteLength)
        sourceSHA256 = try c.decode(String.self, forKey: .sourceSHA256); excerptSHA256 = try c.decode(String.self, forKey: .excerptSHA256)
    }
}
struct AuthorityPolicyDefinition: Codable {
    let scope: AuthorityPolicyScope; let rule: String; let value: String
    var effectiveFrom: Int64 = 0; var expiresAt: Int64? = nil; var untilTaskComplete = false
    var sources: [AuthoritySourceSpan] = []
    init(scope: AuthorityPolicyScope, rule: String, value: String, effectiveFrom: Int64 = 0, expiresAt: Int64? = nil, untilTaskComplete: Bool = false, sources: [AuthoritySourceSpan] = []) {
        self.scope = scope; self.rule = rule; self.value = value; self.effectiveFrom = effectiveFrom; self.expiresAt = expiresAt; self.untilTaskComplete = untilTaskComplete; self.sources = sources
    }
    init(from decoder: Decoder) throws {
        try authorityKeys(decoder, allowed: ["scope","rule","value","effectiveFrom","expiresAt","untilTaskComplete","sources"], required: ["scope","rule","value","effectiveFrom","untilTaskComplete","sources"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scope = try c.decode(AuthorityPolicyScope.self, forKey: .scope); rule = try c.decode(String.self, forKey: .rule); value = try c.decode(String.self, forKey: .value)
        effectiveFrom = try c.decode(Int64.self, forKey: .effectiveFrom); expiresAt = try c.decodeIfPresent(Int64.self, forKey: .expiresAt)
        untilTaskComplete = try c.decode(Bool.self, forKey: .untilTaskComplete); sources = try c.decode([AuthoritySourceSpan].self, forKey: .sources)
    }
}
struct AuthorityOperationRequest: Codable {
    var version = "authority-operation-v1"
    let requestID: String; let expectedRevision: Int; let operation: AuthorityOperation
    var taskID: String? = nil; var projectID: String? = nil; var conversationID: String? = nil; var policyID: String? = nil
    var expectedTaskRevision: Int? = nil; var expectedPolicyRevision: Int? = nil
    var policy: AuthorityPolicyDefinition? = nil; var supersedesPolicyIDs: [String] = []
    init(requestID: String, expectedRevision: Int, operation: AuthorityOperation, taskID: String? = nil, projectID: String? = nil, conversationID: String? = nil, policyID: String? = nil, expectedTaskRevision: Int? = nil, expectedPolicyRevision: Int? = nil, policy: AuthorityPolicyDefinition? = nil, supersedesPolicyIDs: [String] = []) {
        self.requestID = requestID; self.expectedRevision = expectedRevision; self.operation = operation; self.taskID = taskID; self.projectID = projectID; self.conversationID = conversationID; self.policyID = policyID; self.expectedTaskRevision = expectedTaskRevision; self.expectedPolicyRevision = expectedPolicyRevision; self.policy = policy; self.supersedesPolicyIDs = supersedesPolicyIDs
    }
    init(from decoder: Decoder) throws {
        try authorityKeys(decoder, allowed: ["version","requestID","expectedRevision","operation","taskID","projectID","conversationID","policyID","expectedTaskRevision","expectedPolicyRevision","policy","supersedesPolicyIDs"], required: ["version","requestID","expectedRevision","operation","supersedesPolicyIDs"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version); requestID = try c.decode(String.self, forKey: .requestID); expectedRevision = try c.decode(Int.self, forKey: .expectedRevision); operation = try c.decode(AuthorityOperation.self, forKey: .operation)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID); projectID = try c.decodeIfPresent(String.self, forKey: .projectID); conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID); policyID = try c.decodeIfPresent(String.self, forKey: .policyID)
        expectedTaskRevision = try c.decodeIfPresent(Int.self, forKey: .expectedTaskRevision); expectedPolicyRevision = try c.decodeIfPresent(Int.self, forKey: .expectedPolicyRevision)
        policy = try c.decodeIfPresent(AuthorityPolicyDefinition.self, forKey: .policy); supersedesPolicyIDs = try c.decode([String].self, forKey: .supersedesPolicyIDs)
    }
}
struct AuthorityTaskRecord: Codable { let id: String; let projectID: String; let ownerID: String; var revision: Int; var state: AuthorityTaskState }
struct AuthorityConversationBinding: Codable { let conversationID: String; let projectID: String; var taskID: String }
struct AuthorityPolicyRecord: Codable { let id: String; let ownerID: String; var revision: Int; var state: AuthorityPolicyState; var definition: AuthorityPolicyDefinition }
struct AuthorityPolicyConflict { let rule: String; let policyIDs: [String] }
struct AuthorityPolicyResolution { let selected: [AuthorityPolicyRecord]; let conflicts: [AuthorityPolicyConflict]; let blocked: Bool }
struct AuthorityStateSnapshot: Codable {
    var version = "authority-state-v1"
    let storeID: String; let ownerID: String
    var controlEpoch: Int = 0; var revision: Int = 0; var journalSequence: Int = 0; var timeHighWater: Int64 = 0
    var tasks: [AuthorityTaskRecord] = []; var bindings: [AuthorityConversationBinding] = []; var policies: [AuthorityPolicyRecord] = []
    func resolvedPolicies(projectID: String?, taskID: String?) throws -> AuthorityPolicyResolution {
        if let projectID { try AuthorityStateKernel.identifier(projectID) }; if let taskID { try AuthorityStateKernel.identifier(taskID) }
        let task = taskID.flatMap { id in tasks.first { episodeIdentifierEqual($0.id,id) } }
        if taskID != nil { guard let task, let projectID, episodeIdentifierEqual(task.projectID,projectID) else { throw AuthorityStateError.missing } }
        let applicable = policies.filter { p in
            guard p.state == .active else { return false }
            switch p.definition.scope.kind {
            case .global: return true
            case .project: return episodeIdentifierEqual(p.definition.scope.projectID,projectID)
            case .task: return task?.state == .active && episodeIdentifierEqual(p.definition.scope.taskID,taskID)
            }
        }
        var grouped: [Data:[AuthorityPolicyRecord]] = [:]
        for p in applicable { let key = try AuthorityStateKernel.canonical(p.definition.scope) + Data([0]) + Data(p.definition.rule.utf8); grouped[key,default:[]].append(p) }
        let conflicts = grouped.values.filter { Set($0.map { Data($0.definition.value.utf8) }).count > 1 }
            .map { AuthorityPolicyConflict(rule:$0[0].definition.rule,policyIDs:$0.map(\.id)) }
        var rules: [Data:[AuthorityPolicyRecord]] = [:]
        for p in applicable { rules[Data(p.definition.rule.utf8),default:[]].append(p) }
        let selected = rules.values.flatMap { records -> [AuthorityPolicyRecord] in
            func rank(_ p:AuthorityPolicyRecord)->Int { p.definition.scope.kind == .task ? 2 : p.definition.scope.kind == .project ? 1 : 0 }
            let best = records.map(rank).max() ?? 0; return records.filter { rank($0) == best }
        }.sorted { Data($0.id.utf8).lexicographicallyPrecedes(Data($1.id.utf8)) }
        return AuthorityPolicyResolution(selected:selected,conflicts:conflicts.sorted { let a=Data($0.rule.utf8), b=Data($1.rule.utf8); return a == b ? Data($0.policyIDs.joined(separator:"\0").utf8).lexicographicallyPrecedes(Data($1.policyIDs.joined(separator:"\0").utf8)) : a.lexicographicallyPrecedes(b) },blocked:!conflicts.isEmpty || (task != nil && task?.state != .active))
    }
}
struct AuthorityOperationReceipt: Codable {
    var version = "authority-receipt-v1"
    let requestID: String; let operation: AuthorityOperation?; let kind: String; let origin: String
    let revision: Int; let controlEpoch: Int; let journalSequence: Int; let timeHighWater: Int64
    let previousStateSHA256: String; let stateSHA256: String; let requestSHA256: String?
    let expiredPolicyIDs: [String]
}
struct AuthorityStateInventory: Codable, Equatable {
    var version = "authority-state-v1"
    let storeID:String; let ownerID:String; let controlEpoch:Int; let revision:Int; let timeHighWater:Int64
    let tasks:Int; let bindings:Int; let policies:Int; let operations:Int; let stateSHA256:String
}

private struct AuthorityCodingKey: CodingKey { let stringValue:String; var intValue:Int? { nil }; init?(stringValue:String){self.stringValue=stringValue}; init?(intValue:Int){return nil} }
private func authorityKeys(_ decoder:Decoder,allowed:Set<String>,required:Set<String>) throws {
    let keys=Set(try decoder.container(keyedBy:AuthorityCodingKey.self).allKeys.map(\.stringValue))
    guard keys.isSubset(of:allowed),required.isSubset(of:keys) else { throw AuthorityStateError.invalid }
}

enum AuthorityStateKernel {
    static let tableNames = ["authority_control","authority_tasks","authority_bindings","authority_policies","authority_operations"]
    static let schemaStatements = [
        "CREATE TABLE IF NOT EXISTS authority_control(id INTEGER PRIMARY KEY CHECK(id=1),payload BLOB NOT NULL,digest TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS authority_tasks(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS authority_bindings(conversation_id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS authority_policies(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL)",
        "CREATE TABLE IF NOT EXISTS authority_operations(sequence INTEGER PRIMARY KEY,request_id TEXT COLLATE BINARY UNIQUE NOT NULL,request_payload BLOB,receipt_payload BLOB NOT NULL,receipt_digest TEXT NOT NULL)"
    ]
    static let maximumRecords = 4096, maximumOperations = 8192, maximumJournalBytes = 64 * 1024 * 1024
    static func install(database:OpaquePointer,ownerID:String) throws {
        try identifier(ownerID)
        for sql in schemaStatements { try execute(database,sql) }
        if try rows(database,"SELECT payload FROM authority_control").isEmpty {
            let initial = AuthorityStateSnapshot(storeID:UUID().uuidString.lowercased(),ownerID:ownerID)
            try persist(database,state:initial)
        } else { guard episodeIdentifierEqual(try snapshot(database:database).ownerID,ownerID) else { throw AuthorityStateError.unauthorized } }
    }
    static func snapshot(database:OpaquePointer) throws -> AuthorityStateSnapshot {
        let records=try rows(database,"SELECT payload,digest FROM authority_control WHERE id=1")
        guard records.count == 1, let bytes=records[0][0].bytes,records[0][1].string == digest(bytes) else { throw AuthorityStateError.integrity }
        return try decode(AuthorityStateSnapshot.self,bytes)
    }
    static func validateAuthority(database:OpaquePointer,authority:AuthorityContext) throws {
        let state=try snapshot(database:database)
        guard (authority.origin == .humanHost || authority.origin == .humanCLI),episodeIdentifierEqual(state.ownerID,authority.ownerID) else { throw AuthorityStateError.unauthorized }
    }
    static func advanceStartup(database:OpaquePointer) throws {
        let before=try snapshot(database:database); var after=before
        try increment(&after.controlEpoch); try increment(&after.revision); try increment(&after.journalSequence)
        try record(database,before:before,after:after,request:nil,kind:"startup",origin:"startup",requestID:"authority-startup:"+UUID().uuidString.lowercased())
    }
    /// A final v2 pure-clock receipt is a durable checkpoint. Coalescing drops
    /// intermediate clock samples; every human and actual state-change receipt
    /// remains immutable. The owner supplies the surrounding transaction.
    static func advanceTime(database:OpaquePointer,now:Int64) throws {
        guard now >= 0 else { throw AuthorityStateError.invalid }
        let before=try snapshot(database:database); guard now > before.timeHighWater else { return }
        var after=before; after.timeHighWater=now; let changed=try expireAndActivate(&after)
        if changed {
            try increment(&after.controlEpoch); try increment(&after.revision); try increment(&after.journalSequence)
            try record(database,before:before,after:after,request:nil,kind:"time",origin:"scheduler",requestID:"authority-time:"+UUID().uuidString.lowercased())
            return
        }
        let last=try rows(database,"SELECT sequence,request_id,request_payload,receipt_payload,receipt_digest FROM authority_operations ORDER BY sequence DESC LIMIT 1")
        if let row=last.first {
            guard let bytes=row[3].bytes,row[4].string == digest(bytes) else { throw AuthorityStateError.integrity }
            let old=try decode(AuthorityOperationReceipt.self,bytes)
            guard supportedReceipt(old),row[0].integer == before.journalSequence,old.journalSequence == before.journalSequence,episodeIdentifierEqual(row[1].string,old.requestID),old.stateSHA256 == digest(try canonical(before)) else { throw AuthorityStateError.integrity }
            if old.version == "authority-receipt-v2" && old.kind == "clockCheckpoint" {
                // Replay proves the old anchor, pure-clock semantics, schema,
                // and every unchanged projection before any row is replaced.
                try AuthorityStateJournal.validate(database:database)
                guard row[0].integer == before.journalSequence,old.journalSequence == before.journalSequence,episodeIdentifierEqual(row[1].string,old.requestID),row[2].isNull,old.origin == "scheduler",old.operation == nil,old.requestSHA256 == nil,old.expiredPolicyIDs.isEmpty,old.requestID.hasPrefix("authority-clock:"),old.revision == before.revision,old.controlEpoch == before.controlEpoch,old.timeHighWater == before.timeHighWater,old.stateSHA256 == digest(try canonical(before)) else { throw AuthorityStateError.integrity }
                var receipt=AuthorityOperationReceipt(requestID:old.requestID,operation:nil,kind:"clockCheckpoint",origin:"scheduler",revision:after.revision,controlEpoch:after.controlEpoch,journalSequence:after.journalSequence,timeHighWater:after.timeHighWater,previousStateSHA256:old.previousStateSHA256,stateSHA256:digest(try canonical(after)),requestSHA256:nil,expiredPolicyIDs:[])
                receipt.version="authority-receipt-v2"
                let replacement=try canonical(receipt),total=try journalBytes(database)
                guard total >= bytes.count,total-bytes.count <= maximumJournalBytes-replacement.count else { throw AuthorityStateError.limit }
                try execute(database,"UPDATE authority_operations SET receipt_payload=?,receipt_digest=? WHERE sequence=? AND request_id=?",[.bytes(replacement),.text(digest(replacement)),.integer(old.journalSequence),.text(old.requestID)])
                guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
                try persistControl(database,state:after)
                return
            }
        } else { guard before.journalSequence == 0 else { throw AuthorityStateError.integrity } }
        try increment(&after.journalSequence)
        try record(database,before:before,after:after,request:nil,kind:"clockCheckpoint",origin:"scheduler",requestID:"authority-clock:"+UUID().uuidString.lowercased(),version:"authority-receipt-v2",controlOnly:true)
    }
    static func apply(database:OpaquePointer,request:AuthorityOperationRequest,authority:AuthorityContext,now:Int64) throws -> AuthorityOperationReceipt {
        try validateAuthority(database:database,authority:authority); try validateRequest(request)
        let requestBytes=try canonical(request)
        let old=try rows(database,"SELECT request_payload,receipt_payload FROM authority_operations WHERE request_id=?",[.text(request.requestID)])
        if let first=old.first {
            guard first[0].bytes == requestBytes else { throw AuthorityStateError.conflict }
            return try decode(AuthorityOperationReceipt.self,first[1].bytes ?? Data())
        }
        // This namespace was not reserved by the original v1 request contract.
        // Preserve old receipt replay/retries, while reserving all new IDs.
        guard !request.requestID.hasPrefix("authority-clock:") else { throw AuthorityStateError.invalid }
        let before=try snapshot(database:database)
        guard now >= 0,now <= before.timeHighWater else { throw AuthorityStateError.invalid }
        let after=try reduce(before,request:request,database:database)
        return try record(database,before:before,after:after,request:request,kind:"mutation",origin:authority.origin.rawValue,requestID:request.requestID)
    }
    static func reduce(_ before:AuthorityStateSnapshot,request:AuthorityOperationRequest,database:OpaquePointer,progress:AuthorityValidationProgress?=nil) throws -> AuthorityStateSnapshot {
        try progress?()
        try validateRequest(request); guard request.expectedRevision == before.revision else { throw AuthorityStateError.staleRevision }
        var state=before
        func taskIndex() throws -> Int {
            guard let id=request.taskID,let i=state.tasks.firstIndex(where:{episodeIdentifierEqual($0.id,id)}) else { throw AuthorityStateError.missing }
            guard request.expectedTaskRevision == state.tasks[i].revision else { throw AuthorityStateError.staleRevision }
            if let project=request.projectID { guard episodeIdentifierEqual(project,state.tasks[i].projectID) else { throw AuthorityStateError.invalid } }
            return i
        }
        func bind(_ task:AuthorityTaskRecord) throws {
            guard let conversation=request.conversationID else { return }
            let rows=try self.rows(database,"SELECT project_id FROM conversations WHERE id=?",[.text(conversation)])
            guard rows.count == 1,episodeIdentifierEqual(rows[0][0].string,task.projectID) else { throw AuthorityStateError.invalid }
            if let i=state.bindings.firstIndex(where:{episodeIdentifierEqual($0.conversationID,conversation)}) { state.bindings[i].taskID=task.id }
            else { state.bindings.append(AuthorityConversationBinding(conversationID:conversation,projectID:task.projectID,taskID:task.id)) }
        }
        switch request.operation {
        case .taskNew:
            guard let id=request.taskID,let project=request.projectID,request.expectedTaskRevision == nil,!state.tasks.contains(where:{episodeIdentifierEqual($0.id,id)}) else { throw AuthorityStateError.conflict }
            let task=AuthorityTaskRecord(id:id,projectID:project,ownerID:state.ownerID,revision:0,state:.active); state.tasks.append(task); try bind(task)
        case .taskSelect:
            let i=try taskIndex(); guard state.tasks[i].state == .active,request.conversationID != nil else { throw AuthorityStateError.invalid }; try bind(state.tasks[i])
        case .taskSuspend,.taskResume,.taskComplete,.taskCancel,.taskReopen:
            let i=try taskIndex(); let old=state.tasks[i].state; let next:AuthorityTaskState
            switch request.operation {
            case .taskSuspend: guard old == .active else { throw AuthorityStateError.conflict }; next = .suspended
            case .taskResume: guard old == .suspended else { throw AuthorityStateError.conflict }; next = .active
            case .taskComplete: guard old == .active || old == .suspended else { throw AuthorityStateError.conflict }; next = .completed
            case .taskCancel: guard old == .active || old == .suspended else { throw AuthorityStateError.conflict }; next = .cancelled
            default: guard old == .completed || old == .cancelled else { throw AuthorityStateError.conflict }; next = .active
            }
            state.tasks[i].state=next; try increment(&state.tasks[i].revision)
            if next == .completed || next == .cancelled {
                for p in state.policies.indices where state.policies[p].definition.untilTaskComplete && episodeIdentifierEqual(state.policies[p].definition.scope.taskID,state.tasks[i].id) && !terminal(state.policies[p].state) { state.policies[p].state = .expired; try increment(&state.policies[p].revision) }
            }
        case .policyPropose,.policySet,.policySupersede:
            guard let id=request.policyID,let definition=request.policy else { throw AuthorityStateError.invalid }
            try validateDefinition(definition,state:state,database:database,progress:progress)
            let existing=state.policies.firstIndex(where:{episodeIdentifierEqual($0.id,id)})
            if let i=existing {
                guard request.operation == .policySet,!terminal(state.policies[i].state),request.expectedPolicyRevision == state.policies[i].revision else { throw AuthorityStateError.conflict }
                state.policies[i].definition=definition; try increment(&state.policies[i].revision); state.policies[i].state=activation(definition,at:state.timeHighWater)
            } else {
                guard request.expectedPolicyRevision == nil else { throw AuthorityStateError.staleRevision }
                state.policies.append(AuthorityPolicyRecord(id:id,ownerID:state.ownerID,revision:0,state:request.operation == .policyPropose ? .proposed : activation(definition,at:state.timeHighWater),definition:definition))
            }
            if request.operation == .policySupersede {
                guard !request.supersedesPolicyIDs.isEmpty else { throw AuthorityStateError.invalid }
                for oldID in request.supersedesPolicyIDs {
                    guard !episodeIdentifierEqual(oldID,id),let i=state.policies.firstIndex(where:{episodeIdentifierEqual($0.id,oldID)}),!terminal(state.policies[i].state),try canonical(state.policies[i].definition.scope) == canonical(definition.scope),episodeIdentifierEqual(state.policies[i].definition.rule,definition.rule) else { throw AuthorityStateError.conflict }
                    state.policies[i].state = .superseded; try increment(&state.policies[i].revision)
                }
            } else { guard request.supersedesPolicyIDs.isEmpty else { throw AuthorityStateError.invalid } }
        case .policyActivate,.policyRevoke:
            guard let id=request.policyID,let i=state.policies.firstIndex(where:{episodeIdentifierEqual($0.id,id)}) else { throw AuthorityStateError.missing }
            guard request.expectedPolicyRevision == state.policies[i].revision else { throw AuthorityStateError.staleRevision }
            guard !terminal(state.policies[i].state) else { throw AuthorityStateError.conflict }
            if request.operation == .policyRevoke { state.policies[i].state = .revoked }
            else { try validateDefinition(state.policies[i].definition,state:state,database:database,progress:progress); state.policies[i].state=activation(state.policies[i].definition,at:state.timeHighWater) }
            try increment(&state.policies[i].revision)
        }
        guard state.tasks.count <= maximumRecords,state.bindings.count <= maximumRecords,state.policies.count <= maximumRecords else { throw AuthorityStateError.limit }
        state.tasks.sort { Data($0.id.utf8).lexicographicallyPrecedes(Data($1.id.utf8)) }; state.bindings.sort { Data($0.conversationID.utf8).lexicographicallyPrecedes(Data($1.conversationID.utf8)) }; state.policies.sort { Data($0.id.utf8).lexicographicallyPrecedes(Data($1.id.utf8)) }
        try increment(&state.controlEpoch); try increment(&state.revision); try increment(&state.journalSequence); return state
    }
    static func terminal(_ state:AuthorityPolicyState)->Bool { state == .expired || state == .revoked || state == .superseded }
    static func activation(_ definition:AuthorityPolicyDefinition,at:Int64)->AuthorityPolicyState { definition.effectiveFrom > at ? .scheduled : .active }
    static func expireAndActivate(_ state:inout AuthorityStateSnapshot,progress:AuthorityValidationProgress?=nil) throws -> Bool {
        var changed=false
        for i in state.policies.indices where !terminal(state.policies[i].state) {
            try progress?()
            let d=state.policies[i].definition
            if let expiry=d.expiresAt,expiry <= state.timeHighWater { state.policies[i].state = .expired; try increment(&state.policies[i].revision); changed=true }
            else if state.policies[i].state == .scheduled,d.effectiveFrom <= state.timeHighWater { state.policies[i].state = .active; try increment(&state.policies[i].revision); changed=true }
        }
        return changed
    }
    static func validateRequest(_ request:AuthorityOperationRequest) throws {
        guard request.version == "authority-operation-v1",request.expectedRevision >= 0,request.supersedesPolicyIDs.count <= 16 else { throw AuthorityStateError.invalid }
        switch request.operation {
        case .taskNew,.taskSelect,.taskSuspend,.taskResume,.taskComplete,.taskCancel,.taskReopen:
            guard request.taskID != nil,request.policyID == nil,request.policy == nil,request.expectedPolicyRevision == nil,request.supersedesPolicyIDs.isEmpty else { throw AuthorityStateError.invalid }
            if request.operation != .taskNew && request.operation != .taskSelect { guard request.conversationID == nil else { throw AuthorityStateError.invalid } }
        case .policyPropose,.policySet,.policySupersede:
            guard request.policyID != nil,request.policy != nil,request.taskID == nil,request.conversationID == nil,request.expectedTaskRevision == nil else { throw AuthorityStateError.invalid }
        case .policyActivate,.policyRevoke:
            guard request.policyID != nil,request.policy == nil,request.taskID == nil,request.conversationID == nil,request.expectedTaskRevision == nil,request.supersedesPolicyIDs.isEmpty else { throw AuthorityStateError.invalid }
        }
        try identifier(request.requestID); guard !request.requestID.hasPrefix("authority-startup:"),!request.requestID.hasPrefix("authority-time:") else { throw AuthorityStateError.invalid }
        for id in [request.taskID,request.projectID,request.conversationID,request.policyID].compactMap({$0})+request.supersedesPolicyIDs { try identifier(id) }
        guard Set(request.supersedesPolicyIDs.map { Data($0.utf8) }).count == request.supersedesPolicyIDs.count,request.expectedTaskRevision.map({$0 >= 0}) ?? true,request.expectedPolicyRevision.map({$0 >= 0}) ?? true,(try canonical(request)).count <= 65536 else { throw AuthorityStateError.invalid }
    }
    static func validateDefinition(_ d:AuthorityPolicyDefinition,state:AuthorityStateSnapshot,database:OpaquePointer,progress:AuthorityValidationProgress?=nil) throws {
        try progress?()
        guard !d.rule.isEmpty,d.rule.utf8.count <= 256,!d.rule.utf8.contains(0),d.value.utf8.count <= 8192,d.effectiveFrom >= 0,d.expiresAt.map({$0 > d.effectiveFrom && $0 > state.timeHighWater}) ?? true,d.sources.count <= 16 else { throw AuthorityStateError.invalid }
        switch d.scope.kind {
        case .global: guard d.scope.projectID == nil,d.scope.taskID == nil,!d.untilTaskComplete else { throw AuthorityStateError.invalid }
        case .project: guard let project=d.scope.projectID,d.scope.taskID == nil,!d.untilTaskComplete else { throw AuthorityStateError.invalid }; try identifier(project)
        case .task: guard let project=d.scope.projectID,let task=d.scope.taskID,let record=state.tasks.first(where:{episodeIdentifierEqual($0.id,task)}),episodeIdentifierEqual(project,record.projectID),record.state == .active || record.state == .suspended else { throw AuthorityStateError.invalid }; try identifier(project); try identifier(task)
        }
        for span in d.sources {
            try progress?()
            try identifier(span.eventID); try identifier(span.projectID); try identifier(span.conversationID)
            if let project=d.scope.projectID { guard episodeIdentifierEqual(span.projectID,project) else { throw AuthorityStateError.invalid } }
            guard span.offset >= 0,span.byteLength > 0,span.byteLength <= 4096 else { throw AuthorityStateError.invalid }
            let rows=try self.rows(database,"SELECT project_id,conversation_id,payload,digest,byte_count FROM events WHERE id=?",[.text(span.eventID)])
            guard rows.count == 1,episodeIdentifierEqual(rows[0][0].string,span.projectID),episodeIdentifierEqual(rows[0][1].string,span.conversationID),let source=rows[0][2].bytes,source.count == rows[0][4].integer,String(data:source,encoding:.utf8) != nil,try digest(source,progress:progress) == span.sourceSHA256,rows[0][3].string == span.sourceSHA256,span.offset <= source.count,span.byteLength <= source.count-span.offset else { throw AuthorityStateError.invalid }
            let excerpt=source.subdata(in:span.offset..<(span.offset+span.byteLength))
            guard String(data:source.prefix(span.offset),encoding:.utf8) != nil,String(data:excerpt,encoding:.utf8) != nil,digest(excerpt) == span.excerptSHA256 else { throw AuthorityStateError.invalid }
            try progress?()
        }
    }
    @discardableResult
    static func record(_ database:OpaquePointer,before:AuthorityStateSnapshot,after:AuthorityStateSnapshot,request:AuthorityOperationRequest?,kind:String,origin:String,requestID:String,version:String="authority-receipt-v1",controlOnly:Bool=false) throws -> AuthorityOperationReceipt {
        guard after.journalSequence <= maximumOperations else { throw AuthorityStateError.limit }
        let requestBytes=try request.map(canonical)
        let expired=after.policies.filter { p in p.state == .expired && before.policies.first(where:{episodeIdentifierEqual($0.id,p.id)})?.state != .expired }.map(\.id)
        var receipt=AuthorityOperationReceipt(requestID:requestID,operation:request?.operation,kind:kind,origin:origin,revision:after.revision,controlEpoch:after.controlEpoch,journalSequence:after.journalSequence,timeHighWater:after.timeHighWater,previousStateSHA256:digest(try canonical(before)),stateSHA256:digest(try canonical(after)),requestSHA256:requestBytes.map(digest),expiredPolicyIDs:expired)
        receipt.version=version
        let receiptBytes=try canonical(receipt)
        let total=try journalBytes(database)
        guard total <= maximumJournalBytes-(requestBytes?.count ?? 0)-receiptBytes.count else { throw AuthorityStateError.limit }
        try execute(database,"INSERT INTO authority_operations(sequence,request_id,request_payload,receipt_payload,receipt_digest) VALUES(?,?,?,?,?)",[.integer(after.journalSequence),.text(requestID),requestBytes.map(Value.bytes) ?? .null,.bytes(receiptBytes),.text(digest(receiptBytes))])
        if controlOnly { try persistControl(database,state:after) } else { try persist(database,state:after) }
        return receipt
    }
    private static func journalBytes(_ database:OpaquePointer) throws -> Int {
        let total=try rows(database,"SELECT coalesce(sum(coalesce(length(request_payload),0)+length(receipt_payload)),0) FROM authority_operations")[0][0].integer
        guard total >= 0,total <= maximumJournalBytes else { throw AuthorityStateError.limit }; return total
    }
    static func supportedReceipt(_ receipt:AuthorityOperationReceipt)->Bool {
        (receipt.version == "authority-receipt-v1" && ["startup","time","mutation"].contains(receipt.kind)) || (receipt.version == "authority-receipt-v2" && receipt.kind == "clockCheckpoint")
    }
    private static func persistControl(_ database:OpaquePointer,state:AuthorityStateSnapshot) throws {
        let bytes=try canonical(state); guard bytes.count <= 4*1024*1024 else { throw AuthorityStateError.limit }
        try execute(database,"INSERT OR REPLACE INTO authority_control(id,payload,digest) VALUES(1,?,?)",[.bytes(bytes),.text(digest(bytes))])
    }
    static func persist(_ database:OpaquePointer,state:AuthorityStateSnapshot,progress:AuthorityValidationProgress?=nil) throws {
        try progress?()
        try persistControl(database,state:state)
        try persistProjections(database,state:state,progress:progress)
    }
    static func persistProjections(_ database:OpaquePointer,state:AuthorityStateSnapshot,progress:AuthorityValidationProgress?=nil) throws {
        try progress?()
        for table in ["authority_tasks","authority_bindings","authority_policies"] { try execute(database,"DELETE FROM "+table) }
        for record in state.tasks { try progress?(); let bytes=try canonical(record); try execute(database,"INSERT INTO authority_tasks(id,payload,digest) VALUES(?,?,?)",[.text(record.id),.bytes(bytes),.text(digest(bytes))]) }
        for record in state.bindings { try progress?(); let bytes=try canonical(record); try execute(database,"INSERT INTO authority_bindings(conversation_id,payload,digest) VALUES(?,?,?)",[.text(record.conversationID),.bytes(bytes),.text(digest(bytes))]) }
        for record in state.policies { try progress?(); let bytes=try canonical(record); try execute(database,"INSERT INTO authority_policies(id,payload,digest) VALUES(?,?,?)",[.text(record.id),.bytes(bytes),.text(digest(bytes))]) }
        try progress?()
    }
    static func identifier(_ value:String) throws { guard !value.isEmpty,value.utf8.count <= 256,!value.utf8.contains(0) else { throw AuthorityStateError.invalid } }
    static func increment(_ value:inout Int) throws { guard value >= 0,value < Int.max else { throw AuthorityStateError.limit }; value += 1 }
    static func canonical<T:Encodable>(_ value:T) throws -> Data { let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]; return try encoder.encode(value) }
    static func decode<T:Codable>(_ type:T.Type,_ bytes:Data) throws -> T {
        guard !bytes.isEmpty,bytes.count <= 4*1024*1024 else { throw AuthorityStateError.integrity }
        do { let value=try JSONDecoder().decode(type,from:bytes); guard try canonical(value) == bytes else { throw AuthorityStateError.integrity }; return value } catch { throw AuthorityStateError.integrity }
    }
    static func digest(_ bytes:Data)->String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    static func digest(_ bytes:Data,progress:AuthorityValidationProgress?)throws->String {
        guard let progress else { return digest(bytes) }
        var hash=SHA256(),offset=0
        while offset < bytes.count {
            try progress()
            let end=min(bytes.count,offset+4096)
            hash.update(data:bytes.subdata(in:offset..<end)); offset=end
        }
        try progress(); return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    enum Value { case text(String),bytes(Data),integer(Int),null
        var isNull:Bool { if case .null=self { return true }; return false }
        var bytes:Data? { if case .bytes(let value)=self { return value }; return nil }
        var string:String { if case .text(let value)=self { return value }; return "" }
        var integer:Int { if case .integer(let value)=self { return value }; return 0 }
    }
    static func execute(_ db:OpaquePointer,_ sql:String,_ bindings:[Value]=[]) throws { _=try query(db,sql,bindings,collect:false) }
    static func rows(_ db:OpaquePointer,_ sql:String,_ bindings:[Value]=[]) throws -> [[Value]] { try query(db,sql,bindings,collect:true) }
    private static func query(_ db:OpaquePointer,_ sql:String,_ bindings:[Value],collect:Bool) throws -> [[Value]] {
        var raw:OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&raw,nil)==SQLITE_OK,let statement=raw else { throw AuthorityStateError.integrity }; defer { sqlite3_finalize(statement) }
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (offset,binding) in bindings.enumerated() {
            let index=Int32(offset+1),code:Int32
            switch binding { case .text(let v): code=v.withCString { sqlite3_bind_text(statement,index,$0,Int32(v.utf8.count),transient) }; case .bytes(let v): code=v.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(v.count),transient) }; case .integer(let v): code=sqlite3_bind_int64(statement,index,Int64(v)); case .null: code=sqlite3_bind_null(statement,index) }
            guard code==SQLITE_OK else { throw AuthorityStateError.integrity }
        }
        var result:[[Value]]=[]
        while true {
            let code=sqlite3_step(statement); if code==SQLITE_DONE { return result }; guard code==SQLITE_ROW,collect else { throw AuthorityStateError.integrity }
            guard result.count < maximumOperations+1 else { throw AuthorityStateError.limit }
            var row:[Value]=[]
            for column in 0..<sqlite3_column_count(statement) { switch sqlite3_column_type(statement,column) {
            case SQLITE_INTEGER: row.append(.integer(Int(sqlite3_column_int64(statement,column))))
            case SQLITE_TEXT: if let p=sqlite3_column_text(statement,column) { guard let value=String(bytes:UnsafeBufferPointer(start:p,count:Int(sqlite3_column_bytes(statement,column))),encoding:.utf8) else { throw AuthorityStateError.integrity }; row.append(.text(value)) } else { row.append(.null) }
            case SQLITE_BLOB: let count=Int(sqlite3_column_bytes(statement,column)); guard count <= 4*1024*1024 else { throw AuthorityStateError.limit }; row.append(.bytes(sqlite3_column_blob(statement,column).map { Data(bytes:$0,count:count) } ?? Data()))
            case SQLITE_NULL: row.append(.null)
            default: throw AuthorityStateError.integrity
            } }
            result.append(row)
        }
    }
}
