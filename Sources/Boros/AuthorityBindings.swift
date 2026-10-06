import Foundation
import CSQLite
import CryptoKit

enum AuthorityBindingClassification:String,Codable { case legacyUnbound,managed }
enum AuthorityAuthenticatedOrigin:String,Codable { case humanHost,humanCLI }
enum AuthorityRouteRestriction:String,Codable { case localOnly }
enum AuthorityLocalRouteKind:String,Codable { case loopbackHTTP,localMemory,localNative }
struct AuthorityLocalRoute:Codable {
    let kind:AuthorityLocalRouteKind
    let identity:String
}
struct AuthorityPolicyRevisionReference:Codable {
    let policyID:String
    let revision:Int
}
struct AuthoritySourceDependency:Codable {
    let source:MemorySourceReference
    let offset:Int
    let byteLength:Int
    let excerptSHA256:String
}
enum HumanTaskIntent:Codable {
    case retainOrCreate
    case new(taskID:String)
    case select(taskID:String,expectedRevision:Int)
    private enum Keys:String,CodingKey { case version,kind,taskID,expectedRevision }
    private struct Key:CodingKey { let stringValue:String; var intValue:Int?{nil}; init?(stringValue:String){self.stringValue=stringValue}; init?(intValue:Int){return nil} }
    init(from decoder:Decoder)throws {
        let values=try decoder.container(keyedBy:Keys.self)
        guard try values.decode(String.self,forKey:.version) == "human-task-intent-v1" else { throw AuthorityStateError.invalid }
        let kind=try values.decode(String.self,forKey:.kind)
        let keys=Set(try decoder.container(keyedBy:Key.self).allKeys.map(\.stringValue))
        switch kind {
        case "retainOrCreate": guard keys == ["version","kind"] else { throw AuthorityStateError.invalid }; self = .retainOrCreate
        case "new": guard keys == ["version","kind","taskID"] else { throw AuthorityStateError.invalid }; let id=try values.decode(String.self,forKey:.taskID); try AuthorityStateKernel.identifier(id); self = .new(taskID:id)
        case "select": guard keys == ["version","kind","taskID","expectedRevision"] else { throw AuthorityStateError.invalid }; let id=try values.decode(String.self,forKey:.taskID),revision=try values.decode(Int.self,forKey:.expectedRevision); try AuthorityStateKernel.identifier(id); guard revision >= 0 else { throw AuthorityStateError.invalid }; self = .select(taskID:id,expectedRevision:revision)
        default: throw AuthorityStateError.invalid
        }
    }
    func encode(to encoder:Encoder)throws {
        var values=encoder.container(keyedBy:Keys.self); try values.encode("human-task-intent-v1",forKey:.version)
        switch self {
        case .retainOrCreate: try values.encode("retainOrCreate",forKey:.kind)
        case .new(let id): try AuthorityStateKernel.identifier(id); try values.encode("new",forKey:.kind); try values.encode(id,forKey:.taskID)
        case .select(let id,let revision): try AuthorityStateKernel.identifier(id); guard revision >= 0 else { throw AuthorityStateError.invalid }; try values.encode("select",forKey:.kind); try values.encode(id,forKey:.taskID); try values.encode(revision,forKey:.expectedRevision)
        }
    }
}
struct AuthorityEpisodeBinding:Codable {
    var version="authority-episode-binding-v1"
    let episodeID:String
    let storeID:String
    let ownerID:String
    let startupReceiptID:String
    let controlReceiptID:String
    let controlEpoch:Int
    let authorityRevision:Int
    let projectID:String
    var conversationID:String?=nil
    let requestID:String
    let authenticatedOrigin:AuthorityAuthenticatedOrigin
    var taskID:String?=nil
    var taskRevision:Int?=nil
    var policyReferences:[AuthorityPolicyRevisionReference]=[]
    let resolutionSHA256:String
    let originSHA256:String
    var acceptedSource:MemorySourceReference?=nil
    let taskIntentSHA256:String
    var hostConstraintVersion="authority-local-text-v1"
    var routeRestriction:AuthorityRouteRestriction = .localOnly
}
struct ManagedAcceptance {
    let episode:EpisodeReceipt
    let binding:AuthorityEpisodeBinding
}
struct AuthorityWorkBinding:Codable {
    var version="authority-work-binding-v1"
    let workID:String
    let episodeID:String
    let episodeBindingSHA256:String
    let requestSHA256:String
    var snapshotSHA256:String?=nil
    let localRoute:AuthorityLocalRoute
    var rendererProofSHA256:String?=nil
    var sourceDependencies:[AuthoritySourceDependency]=[]
    var artifactLineage:[String]=[]
}
struct AuthorityInvocationBinding:Codable {
    var version="authority-invocation-binding-v1"
    let invocationID:String
    let workID:String
    let episodeID:String
    let workBindingSHA256:String
    let episodeBindingSHA256:String
    let requestBodySHA256:String
    let providerIdentity:String
    let projectID:String
    let conversationID:String
}
struct AuthorityBindingInventory:Codable,Equatable {
    var version="authority-binding-inventory-v1"
    let episodes:Int; let work:Int; let invocations:Int
    let managedEpisodes:Int; let managedWork:Int; let managedInvocations:Int
    let legacyEpisodes:Int; let legacyWork:Int; let legacyInvocations:Int
    let episodeSHA256:String; let workSHA256:String; let invocationSHA256:String
}
struct AuthorityBindingRow<T:Codable>:Codable {
    var version="authority-binding-row-v1"
    let classification:AuthorityBindingClassification
    let id:String
    let managed:T?
}
/// These immutable records declare historical provenance. They grant no
/// dispatch/output permission until the shared runtime gates are implemented.
enum AuthorityBindings {
    static let tableNames=["authority_episode_bindings","authority_work_bindings","authority_invocation_bindings"]
    static let schemaStatements=tableNames.map { "CREATE TABLE IF NOT EXISTS "+$0+"(id TEXT COLLATE BINARY PRIMARY KEY,payload BLOB NOT NULL,digest TEXT NOT NULL)" }
    static let maximumRecordBytes=524288,maximumDependencies=512
    static let hostConstraintVersion="authority-local-text-v1"
    static func install(database:OpaquePointer)throws { for sql in schemaStatements { try AuthorityStateKernel.execute(database,sql) } }
    static func policyReferences(state:AuthorityStateSnapshot,projectID:String,taskID:String?)throws->[AuthorityPolicyRevisionReference] {
        try state.resolvedPolicies(projectID:projectID,taskID:taskID).selected.map { AuthorityPolicyRevisionReference(policyID:$0.id,revision:$0.revision) }
    }
    static func resolutionSHA256(state:AuthorityStateSnapshot,projectID:String,taskID:String?)throws->String {
        try resolutionSHA256(resolution:state.resolvedPolicies(projectID:projectID,taskID:taskID))
    }
    static func resolutionSHA256(resolution:AuthorityPolicyResolution)throws->String {
        struct Conflict:Codable { let rule:String; let policyIDs:[String] }
        struct Resolution:Codable { let selected:[AuthorityPolicyRecord]; let conflicts:[Conflict]; let blocked:Bool }
        let result=resolution
        return AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(Resolution(selected:result.selected,conflicts:result.conflicts.map{Conflict(rule:$0.rule,policyIDs:$0.policyIDs)},blocked:result.blocked)))
    }
    static func taskIntentSHA256(_ intent:HumanTaskIntent)throws->String { AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(intent)) }
    static func classifyLegacy(database:OpaquePointer)throws {
        for (table,target) in zip(["episodes","episode_work","invocations"],tableNames) {
            try visit(database:database,sql:"SELECT id FROM "+table+" ORDER BY id COLLATE BINARY") { row in
                try insertLegacy(database:database,table:target,id:row[0].string)
            }
        }
    }
    static func insertLegacyEpisode(database:OpaquePointer,id:String)throws { try requireOriginal(database,"episodes",id); try insertLegacy(database:database,table:tableNames[0],id:id) }
    static func insertLegacyWork(database:OpaquePointer,id:String)throws { try requireOriginal(database,"episode_work",id); try insertLegacy(database:database,table:tableNames[1],id:id) }
    static func insertLegacyInvocation(database:OpaquePointer,id:String)throws { try requireOriginal(database,"invocations",id); try insertLegacy(database:database,table:tableNames[2],id:id) }
    private static func insertLegacy(database:OpaquePointer,table:String,id:String)throws {
        struct NoGrant:Codable {}
        try insert(database:database,table:table,row:AuthorityBindingRow<NoGrant>(classification:.legacyUnbound,id:id,managed:nil))
    }
    static func managedEpisode(database:OpaquePointer,id:String)throws->AuthorityEpisodeBinding? {
        let result=try read(database:database,table:tableNames[0],id:id,type:AuthorityEpisodeBinding.self)?.managed
        if let result { guard episodeIdentifierEqual(result.episodeID,id) else { throw AuthorityStateError.integrity } }; return result
    }
    static func managedWork(database:OpaquePointer,id:String)throws->AuthorityWorkBinding? {
        let result=try read(database:database,table:tableNames[1],id:id,type:AuthorityWorkBinding.self)?.managed
        if let result { guard episodeIdentifierEqual(result.workID,id) else { throw AuthorityStateError.integrity } }; return result
    }
    static func insertManagedEpisode(database:OpaquePointer,binding:AuthorityEpisodeBinding,authority:AuthorityContext)throws {
        try AuthorityStateKernel.validateAuthority(database:database,authority:authority)
        guard episodeIdentifierEqual(binding.ownerID,authority.ownerID),binding.authenticatedOrigin.rawValue == authority.origin.rawValue else { throw AuthorityStateError.unauthorized }
        try validateEpisode(database:database,binding:binding,verifySourceBytes:false)
        let duplicate=try AuthorityStateKernel.rows(database,"SELECT id FROM authority_episode_bindings WHERE json_extract(payload,'$.classification')='managed' AND json_extract(payload,'$.managed.requestID')=? AND id!=?",[.text(binding.requestID),.text(binding.episodeID)])
        guard duplicate.isEmpty else { throw AuthorityStateError.conflict }
        try insert(database:database,table:tableNames[0],row:AuthorityBindingRow(classification:.managed,id:binding.episodeID,managed:binding))
    }
    static func insertManagedWork(database:OpaquePointer,binding:AuthorityWorkBinding)throws {
        try validateWork(database:database,binding:binding,verifySourceBytes:false)
        try insert(database:database,table:tableNames[1],row:AuthorityBindingRow(classification:.managed,id:binding.workID,managed:binding))
    }
    @discardableResult static func insertManagedInvocation(database:OpaquePointer,id:String)throws->AuthorityInvocationBinding {
        let binding=try derivedInvocation(database:database,id:id)
        try validateInvocation(database:database,binding:binding)
        try insert(database:database,table:tableNames[2],row:AuthorityBindingRow(classification:.managed,id:id,managed:binding))
        return binding
    }
    static func read<T:Codable>(database:OpaquePointer,table:String,id:String,type:T.Type)throws->AuthorityBindingRow<T>? {
        try AuthorityStateKernel.identifier(id)
        // SQLite evaluates the guards in this same statement before exposing
        // original payload bytes. Affinity alone does not reject TEXT/BLOB
        // substitution, and a later decoder bound would allocate too much.
        let rows=try AuthorityStateKernel.rows(database,"SELECT id,CASE WHEN typeof(payload)='blob' AND length(payload)<=\(maximumRecordBytes) THEN payload ELSE NULL END,CASE WHEN typeof(digest)='text' AND length(CAST(digest AS BLOB))=64 THEN digest ELSE NULL END FROM "+table+" WHERE id=?",[.text(id)])
        guard rows.count <= 1 else { throw AuthorityStateError.integrity }
        return try rows.first.map { try decoded($0,type:type) }
    }
    static func decoded<T:Codable>(_ row:[AuthorityStateKernel.Value],type:T.Type)throws->AuthorityBindingRow<T> {
        guard row.count == 3,let bytes=row[1].bytes,bytes.count <= maximumRecordBytes,row[2].string == AuthorityStateKernel.digest(bytes) else { throw AuthorityStateError.integrity }
        let result=try AuthorityStateKernel.decode(AuthorityBindingRow<T>.self,bytes)
        guard result.version == "authority-binding-row-v1",episodeIdentifierEqual(result.id,row[0].string),(result.classification == .managed) == (result.managed != nil) else { throw AuthorityStateError.integrity }
        try AuthorityStateKernel.identifier(result.id); return result
    }
    private static func insert<T:Codable>(database:OpaquePointer,table:String,row:AuthorityBindingRow<T>)throws {
        try AuthorityStateKernel.identifier(row.id)
        let bytes=try AuthorityStateKernel.canonical(row)
        guard bytes.count <= maximumRecordBytes else { throw AuthorityStateError.limit }
        let existing=try AuthorityStateKernel.rows(database,"SELECT payload,digest FROM "+table+" WHERE id=?",[.text(row.id)])
        if let old=existing.first { guard old[0].bytes == bytes,old[1].string == AuthorityStateKernel.digest(bytes) else { throw AuthorityStateError.conflict }; return }
        try AuthorityStateKernel.execute(database,"INSERT INTO "+table+"(id,payload,digest) VALUES(?,?,?)",[.text(row.id),.bytes(bytes),.text(AuthorityStateKernel.digest(bytes))])
    }
    private static func requireOriginal(_ database:OpaquePointer,_ table:String,_ id:String)throws {
        try AuthorityStateKernel.identifier(id)
        guard try AuthorityStateKernel.rows(database,"SELECT id FROM "+table+" WHERE id=?",[.text(id)]).count == 1 else { throw AuthorityStateError.missing }
    }
    static func isDigest(_ value:String)->Bool { value.utf8.count == 64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)} }
    private static func episodeCanonical<T:Encodable>(_ value:T)throws->Data { let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]; return try encoder.encode(value) }
    /// A supplied historical result comes only from an already funded internal
    /// journal replay. It is not an external serialized authority capability.
    static func validateEpisode(database:OpaquePointer,binding:AuthorityEpisodeBinding,verifySourceBytes:Bool,historical:AuthorityHistoricalState?=nil)throws {
        let b=binding
        guard b.version == "authority-episode-binding-v1",b.hostConstraintVersion == hostConstraintVersion,b.routeRestriction == .localOnly,b.authorityRevision >= 0,b.controlEpoch >= 0,isDigest(b.resolutionSHA256),isDigest(b.originSHA256),isDigest(b.taskIntentSHA256),b.policyReferences.count <= AuthorityStateKernel.maximumRecords,(b.taskID == nil) == (b.taskRevision == nil) else { throw AuthorityStateError.integrity }
        for id in [b.episodeID,b.storeID,b.ownerID,b.startupReceiptID,b.controlReceiptID,b.projectID,b.requestID]+[b.conversationID,b.taskID].compactMap({$0}) { try AuthorityStateKernel.identifier(id) }
        let anchor=try historical ?? AuthorityStateJournal.resolve(database:database,receiptID:b.controlReceiptID,revision:b.authorityRevision,controlEpoch:b.controlEpoch),state=anchor.state
        guard anchor.receipt.version == "authority-receipt-v1",["startup","mutation","time"].contains(anchor.receipt.kind),episodeIdentifierEqual(anchor.receipt.requestID,b.controlReceiptID),state.revision == b.authorityRevision,state.controlEpoch == b.controlEpoch,anchor.receipt.revision == state.revision,anchor.receipt.controlEpoch == state.controlEpoch,anchor.receipt.stateSHA256 == AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(state)),episodeIdentifierEqual(state.storeID,b.storeID),episodeIdentifierEqual(state.ownerID,b.ownerID),episodeIdentifierEqual(anchor.startupReceiptID,b.startupReceiptID) else { throw AuthorityStateError.integrity }
        if let taskID=b.taskID {
            guard let task=state.tasks.first(where:{episodeIdentifierEqual($0.id,taskID)}),task.state == .active,task.revision == b.taskRevision,episodeIdentifierEqual(task.projectID,b.projectID) else { throw AuthorityStateError.integrity }
            if let conversation=b.conversationID { guard state.bindings.contains(where:{episodeIdentifierEqual($0.conversationID,conversation)&&episodeIdentifierEqual($0.projectID,b.projectID)&&episodeIdentifierEqual($0.taskID,taskID)}) else { throw AuthorityStateError.integrity } }
        }
        let resolution=try state.resolvedPolicies(projectID:b.projectID,taskID:b.taskID)
        guard !resolution.blocked,try AuthorityStateKernel.canonical(policyReferences(state:state,projectID:b.projectID,taskID:b.taskID)) == AuthorityStateKernel.canonical(b.policyReferences),try resolutionSHA256(state:state,projectID:b.projectID,taskID:b.taskID) == b.resolutionSHA256 else { throw AuthorityStateError.integrity }
        let rows=try AuthorityStateKernel.rows(database,"SELECT conversation_id,project_id,turn_id,human_event_id,origin_json,origin_digest FROM episodes WHERE id=?",[.text(b.episodeID)])
        guard rows.count == 1,episodeIdentifierEqual(rows[0][1].string,b.projectID),let bytes=rows[0][4].bytes,b.originSHA256 == rows[0][5].string,b.originSHA256 == (try MemoryStore.episodeOriginDigest(projectID:b.projectID,originJSON:bytes)) else { throw AuthorityStateError.integrity }
        let origin=try JSONDecoder().decode(EpisodeOrigin.self,from:bytes)
        guard try episodeCanonical(origin) == bytes else { throw AuthorityStateError.integrity }
        switch origin {
        case .chat(let conversation,let turn,let human):
            guard episodeIdentifierEqual(b.conversationID,conversation),episodeIdentifierEqual(rows[0][0].string,conversation),episodeIdentifierEqual(rows[0][2].string,turn),episodeIdentifierEqual(rows[0][3].string,human),let accepted=b.acceptedSource,accepted.byteCount > 0,accepted.role == .human,accepted.status == .complete,episodeIdentifierEqual(accepted.eventID,human),episodeIdentifierEqual(accepted.conversationID,conversation),episodeIdentifierEqual(accepted.projectID,b.projectID) else { throw AuthorityStateError.integrity }
            try validateSource(database:database,source:accepted,verifyBytes:verifySourceBytes)
            let sourceTurn=try AuthorityStateKernel.rows(database,"SELECT turn_id FROM events WHERE id=?",[.text(human)])
            guard sourceTurn.count == 1,episodeIdentifierEqual(sourceTurn[0][0].string,turn) else { throw AuthorityStateError.integrity }
        case .localRead(let local):
            guard b.conversationID == nil,b.acceptedSource == nil,rows[0][0].isNull,rows[0][2].isNull,rows[0][3].isNull,episodeIdentifierEqual(b.requestID,local.requestID) else { throw AuthorityStateError.integrity }
        }
    }
    static func validateSource(database:OpaquePointer,source:MemorySourceReference,verifyBytes:Bool)throws {
        for id in [source.eventID,source.projectID,source.conversationID] { try AuthorityStateKernel.identifier(id) }
        guard source.sequence > 0,source.byteCount >= 0,source.byteCount <= 4194304,isDigest(source.digest),source.createdAt.utf8.count <= 256 else { throw AuthorityStateError.integrity }
        let rows=try AuthorityStateKernel.rows(database,"SELECT sequence,id,conversation_id,project_id,role,status,created_at,digest,byte_count"+(verifyBytes ? ",payload":"")+" FROM events WHERE id=?",[.text(source.eventID)])
        guard rows.count == 1,let role=MemoryRole(rawValue:rows[0][4].string),let status=CaptureStatus(rawValue:rows[0][5].string) else { throw AuthorityStateError.integrity }
        let actual=MemorySourceReference(sequence:rows[0][0].integer,eventID:rows[0][1].string,conversationID:rows[0][2].string,projectID:rows[0][3].string,role:role,status:status,createdAt:rows[0][6].string,digest:rows[0][7].string,byteCount:rows[0][8].integer)
        guard actual == source else { throw AuthorityStateError.integrity }
        if verifyBytes { guard let bytes=rows[0][9].bytes,bytes.count == source.byteCount,String(data:bytes,encoding:.utf8) != nil,AuthorityStateKernel.digest(bytes) == source.digest else { throw AuthorityStateError.integrity } }
    }
    static func validateWork(database:OpaquePointer,binding:AuthorityWorkBinding,verifySourceBytes:Bool)throws {
        let b=binding
        guard b.version == "authority-work-binding-v1",isDigest(b.episodeBindingSHA256),isDigest(b.requestSHA256),b.snapshotSHA256.map(isDigest) ?? true,b.rendererProofSHA256.map(isDigest) ?? true,b.sourceDependencies.count <= maximumDependencies,b.artifactLineage.isEmpty,let episode=try managedEpisode(database:database,id:b.episodeID),b.episodeBindingSHA256 == AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(episode)) else { throw AuthorityStateError.integrity }
        try AuthorityStateKernel.identifier(b.workID)
        let rows=try AuthorityStateKernel.rows(database,"SELECT episode_id,request_json,request_digest,snapshot_digest,kind,adapter_identity FROM episode_work WHERE id=?",[.text(b.workID)])
        guard rows.count == 1,episodeIdentifierEqual(rows[0][0].string,b.episodeID),let bytes=rows[0][1].bytes,AuthorityStateKernel.digest(bytes) == b.requestSHA256,b.requestSHA256 == rows[0][2].string,episodeIdentifierEqual(rows[0][3].isNull ? nil:rows[0][3].string,b.snapshotSHA256) else { throw AuthorityStateError.integrity }
        let request=try JSONDecoder().decode(EpisodeWorkRequest.self,from:bytes)
        guard try episodeCanonical(request) == bytes,request.snapshot == nil,episodeIdentifierEqual(request.id,b.workID),request.kind.rawValue == rows[0][4].string,episodeIdentifierEqual(request.adapterIdentity,rows[0][5].string) else { throw AuthorityStateError.integrity }
        if let digest=b.snapshotSHA256 {
            let snapshots=try AuthorityStateKernel.rows(database,"SELECT payload,byte_count FROM episode_request_snapshots WHERE digest=?",[.text(digest)])
            guard snapshots.count == 1,let payload=snapshots[0][0].bytes,payload.count == snapshots[0][1].integer,AuthorityStateKernel.digest(payload) == digest else { throw AuthorityStateError.integrity }
        }
        try validateRoute(b.localRoute,request:request)
        var seen=Set<Data>()
        for dependency in b.sourceDependencies {
            guard episodeIdentifierEqual(dependency.source.projectID,episode.projectID),dependency.offset >= 0,dependency.byteLength > 0,dependency.offset <= dependency.source.byteCount,dependency.byteLength <= dependency.source.byteCount-dependency.offset,isDigest(dependency.excerptSHA256),seen.insert(try AuthorityStateKernel.canonical(dependency)).inserted else { throw AuthorityStateError.integrity }
            try validateSource(database:database,source:dependency.source,verifyBytes:verifySourceBytes)
            if verifySourceBytes {
                let sources=try AuthorityStateKernel.rows(database,"SELECT payload FROM events WHERE id=?",[.text(dependency.source.eventID)])
                guard let source=sources.first?[0].bytes else { throw AuthorityStateError.integrity }
                let excerpt=source.subdata(in:dependency.offset..<(dependency.offset+dependency.byteLength))
                guard String(data:source.prefix(dependency.offset),encoding:.utf8) != nil,String(data:excerpt,encoding:.utf8) != nil,AuthorityStateKernel.digest(excerpt) == dependency.excerptSHA256 else { throw AuthorityStateError.integrity }
            }
        }
    }
    private static func validateRoute(_ route:AuthorityLocalRoute,request:EpisodeWorkRequest)throws {
        guard !route.identity.isEmpty,route.identity.utf8.count <= 2048,!route.identity.utf8.contains(0) else { throw AuthorityStateError.integrity }
        switch route.kind {
        case .loopbackHTTP:
            guard let url=URLComponents(string:route.identity),url.scheme == "http",["127.0.0.1","localhost","::1","[::1]"].contains(url.host ?? ""),url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,url.port.map({(1...65535).contains($0)}) ?? true else { throw AuthorityStateError.integrity }
            let components=request.adapterIdentity.split(separator:"|",omittingEmptySubsequences:false).map(String.init)
            guard episodeIdentifierEqual(request.adapterIdentity,route.identity) || (components.count >= 2 && ["mlx-serve-qwen38-text-v1","mlx-serve-qwen38-observed-text-v1"].contains(components[0]) && episodeIdentifierEqual(components[1],route.identity)) else { throw AuthorityStateError.integrity }
        case .localMemory:
            guard [.retrieval,.sourceRead,.authorityValidation].contains(request.kind),episodeIdentifierEqual(route.identity,request.adapterIdentity),!route.identity.contains("://") else { throw AuthorityStateError.integrity }
        case .localNative:
            guard [.nativeInference,.queryEmbedding,.tokenizer].contains(request.kind),episodeIdentifierEqual(route.identity,request.adapterIdentity),!route.identity.contains("://") else { throw AuthorityStateError.integrity }
        }
    }
    static func derivedInvocation(database:OpaquePointer,id:String)throws->AuthorityInvocationBinding {
        let rows=try AuthorityStateKernel.rows(database,"SELECT episode_id,episode_work_id,request_body,request_digest,provider_identity,project_id,conversation_id,turn_id,human_event_id FROM invocations WHERE id=?",[.text(id)])
        guard rows.count == 1,!rows[0][0].isNull,!rows[0][1].isNull,let work=try managedWork(database:database,id:rows[0][1].string),let episode=try managedEpisode(database:database,id:rows[0][0].string),episodeIdentifierEqual(work.episodeID,episode.episodeID),let body=rows[0][2].bytes,AuthorityStateKernel.digest(body) == rows[0][3].string,work.snapshotSHA256 == rows[0][3].string,episodeIdentifierEqual(episode.projectID,rows[0][5].string),episodeIdentifierEqual(episode.conversationID,rows[0][6].string) else { throw AuthorityStateError.integrity }
        try validateWork(database:database,binding:work,verifySourceBytes:false)
        let original=try AuthorityStateKernel.rows(database,"SELECT w.kind,e.turn_id,e.human_event_id FROM episode_work w JOIN episodes e ON e.id=w.episode_id WHERE w.id=?",[.text(work.workID)])
        guard original.count == 1,["answer","nativeInference"].contains(original[0][0].string),episodeIdentifierEqual(original[0][1].string,rows[0][7].string),episodeIdentifierEqual(original[0][2].string,rows[0][8].string),episodeIdentifierEqual(episode.acceptedSource?.eventID,rows[0][8].string) else { throw AuthorityStateError.integrity }
        switch work.localRoute.kind {
        case .loopbackHTTP,.localNative: guard episodeIdentifierEqual(work.localRoute.identity,rows[0][4].string) else { throw AuthorityStateError.integrity }
        case .localMemory: throw AuthorityStateError.integrity
        }
        return AuthorityInvocationBinding(invocationID:id,workID:work.workID,episodeID:episode.episodeID,workBindingSHA256:AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(work)),episodeBindingSHA256:AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(episode)),requestBodySHA256:rows[0][3].string,providerIdentity:rows[0][4].string,projectID:rows[0][5].string,conversationID:rows[0][6].string)
    }
    static func validateInvocation(database:OpaquePointer,binding:AuthorityInvocationBinding)throws {
        guard binding.version == "authority-invocation-binding-v1",try AuthorityStateKernel.canonical(binding) == AuthorityStateKernel.canonical(derivedInvocation(database:database,id:binding.invocationID)) else { throw AuthorityStateError.integrity }
        if let work=try managedWork(database:database,id:binding.workID),let proof=work.rendererProofSHA256 {
            let rows=try AuthorityStateKernel.rows(database,"SELECT admission_json FROM invocations WHERE id=?",[.text(binding.invocationID)])
            guard let bytes=rows.first?[0].bytes,let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let receipt=object["receipt"] as? [String:Any],let component=receipt["componentProof"] else { throw AuthorityStateError.integrity }
            let encoded=try JSONSerialization.data(withJSONObject:component,options:[.sortedKeys])
            guard AuthorityStateKernel.digest(encoded) == proof else { throw AuthorityStateError.integrity }
        }
    }
    /// Streaming avoids a new global cardinality limit on historical stores.
    static func visit(database:OpaquePointer,sql:String,body:([AuthorityStateKernel.Value])throws->Void)throws {
        var raw:OpaquePointer?; guard sqlite3_prepare_v2(database,sql,-1,&raw,nil)==SQLITE_OK,let statement=raw else { throw AuthorityStateError.integrity }; defer { sqlite3_finalize(statement) }
        while true {
            let code=sqlite3_step(statement); if code==SQLITE_DONE { return }; guard code==SQLITE_ROW else { throw AuthorityStateError.integrity }
            var row:[AuthorityStateKernel.Value]=[]
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement,column) {
                case SQLITE_INTEGER: row.append(.integer(Int(sqlite3_column_int64(statement,column))))
                case SQLITE_TEXT: let count=Int(sqlite3_column_bytes(statement,column)); guard count <= maximumRecordBytes,let pointer=sqlite3_column_text(statement,column),let value=String(bytes:UnsafeBufferPointer(start:pointer,count:count),encoding:.utf8) else { throw AuthorityStateError.integrity }; row.append(.text(value))
                case SQLITE_BLOB: let count=Int(sqlite3_column_bytes(statement,column)); guard count <= maximumRecordBytes else { throw AuthorityStateError.limit }; row.append(.bytes(sqlite3_column_blob(statement,column).map{Data(bytes:$0,count:count)} ?? Data()))
                case SQLITE_NULL: row.append(.null)
                default: throw AuthorityStateError.integrity
                }
            }
            try body(row)
        }
    }
}
