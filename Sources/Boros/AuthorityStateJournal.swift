import Foundation
import CSQLite

/// Replays typed control operations, then compares every materialized row. Hash
/// integrity is local provenance; it is not a cryptographic external authority.
enum AuthorityStateJournal {
    static func validate(database:OpaquePointer) throws {
        do { try validateImpl(database:database) } catch { throw AuthorityStateError.integrity }
    }
    private static func validateImpl(database:OpaquePointer) throws {
        let kernel=AuthorityStateKernel.self
        try validateSchema(database)
        let current=try kernel.snapshot(database:database)
        try kernel.identifier(current.storeID); try kernel.identifier(current.ownerID)
        guard current.version == "authority-state-v1",current.controlEpoch >= 0,current.revision >= 0,current.journalSequence >= 0,current.timeHighWater >= 0,current.tasks.count <= kernel.maximumRecords,current.bindings.count <= kernel.maximumRecords,current.policies.count <= kernel.maximumRecords else { throw AuthorityStateError.integrity }
        guard try kernel.rows(database,"SELECT id FROM authority_control").count == 1 else { throw AuthorityStateError.integrity }
        var replay=AuthorityStateSnapshot(storeID:current.storeID,ownerID:current.ownerID)
        let entries=try kernel.rows(database,"SELECT sequence,request_id,request_payload,receipt_payload,receipt_digest FROM authority_operations ORDER BY sequence")
        guard entries.count == current.journalSequence,entries.count <= kernel.maximumOperations else { throw AuthorityStateError.integrity }
        var requestIDs=Set<Data>(),totalBytes=0
        for row in entries {
            guard row.count == 5,let receiptBytes=row[3].bytes,row[4].string == kernel.digest(receiptBytes) else { throw AuthorityStateError.integrity }
            let receipt=try kernel.decode(AuthorityOperationReceipt.self,receiptBytes)
            try kernel.identifier(receipt.requestID)
            guard row[0].integer == replay.journalSequence+1,receipt.journalSequence == row[0].integer,episodeIdentifierEqual(row[1].string,receipt.requestID),requestIDs.insert(Data(receipt.requestID.utf8)).inserted,receipt.previousStateSHA256 == kernel.digest(try kernel.canonical(replay)) else { throw AuthorityStateError.integrity }
            totalBytes += receiptBytes.count + (row[2].bytes?.count ?? 0)
            guard totalBytes <= kernel.maximumJournalBytes else { throw AuthorityStateError.integrity }
            let before=replay
            switch receipt.kind {
            case "startup":
                guard receipt.version == "authority-receipt-v1",receipt.origin == "startup",receipt.operation == nil,receipt.requestSHA256 == nil,row[2].isNull,receipt.requestID.hasPrefix("authority-startup:"),receipt.timeHighWater == replay.timeHighWater else { throw AuthorityStateError.integrity }
                try kernel.increment(&replay.controlEpoch); try kernel.increment(&replay.revision); try kernel.increment(&replay.journalSequence)
            case "time":
                guard receipt.version == "authority-receipt-v1",receipt.origin == "scheduler",receipt.operation == nil,receipt.requestSHA256 == nil,row[2].isNull,receipt.requestID.hasPrefix("authority-time:"),receipt.timeHighWater > replay.timeHighWater else { throw AuthorityStateError.integrity }
                replay.timeHighWater=receipt.timeHighWater
                if try kernel.expireAndActivate(&replay) { try kernel.increment(&replay.controlEpoch); try kernel.increment(&replay.revision) }
                try kernel.increment(&replay.journalSequence)
            case "clockCheckpoint":
                guard receipt.version == "authority-receipt-v2",receipt.origin == "scheduler",receipt.operation == nil,receipt.requestSHA256 == nil,row[2].isNull,receipt.requestID.hasPrefix("authority-clock:"),receipt.timeHighWater > replay.timeHighWater,receipt.expiredPolicyIDs.isEmpty else { throw AuthorityStateError.integrity }
                replay.timeHighWater=receipt.timeHighWater
                guard try !kernel.expireAndActivate(&replay) else { throw AuthorityStateError.integrity }
                try kernel.increment(&replay.journalSequence)
            case "mutation":
                guard receipt.version == "authority-receipt-v1",receipt.origin == AuthorityOrigin.humanHost.rawValue || receipt.origin == AuthorityOrigin.humanCLI.rawValue,let bytes=row[2].bytes,kernel.digest(bytes) == receipt.requestSHA256 else { throw AuthorityStateError.integrity }
                let request=try kernel.decode(AuthorityOperationRequest.self,bytes)
                guard episodeIdentifierEqual(request.requestID,receipt.requestID),request.operation == receipt.operation else { throw AuthorityStateError.integrity }
                replay=try kernel.reduce(replay,request:request,database:database)
            default: throw AuthorityStateError.integrity
            }
            let expired=replay.policies.filter { p in p.state == .expired && before.policies.first(where:{episodeIdentifierEqual($0.id,p.id)})?.state != .expired }.map(\.id)
            guard receipt.revision == replay.revision,receipt.controlEpoch == replay.controlEpoch,receipt.timeHighWater == replay.timeHighWater,receipt.stateSHA256 == kernel.digest(try kernel.canonical(replay)),try kernel.canonical(expired) == kernel.canonical(receipt.expiredPolicyIDs) else { throw AuthorityStateError.integrity }
        }
        guard try kernel.canonical(replay) == kernel.canonical(current) else { throw AuthorityStateError.integrity }
        try projections(database,"authority_tasks",key:"id",records:current.tasks.map { ($0.id,try kernel.canonical($0)) })
        try projections(database,"authority_bindings",key:"conversation_id",records:current.bindings.map { ($0.conversationID,try kernel.canonical($0)) })
        try projections(database,"authority_policies",key:"id",records:current.policies.map { ($0.id,try kernel.canonical($0)) })
    }
    /// Owner-open validation runs before installation. A receipt cannot attest a
    /// schema that adds mutation triggers or changes identifier constraints.
    private static func validateSchema(_ database:OpaquePointer) throws {
        let kernel=AuthorityStateKernel.self
        let objects=try kernel.rows(database,"SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE substr(name,1,10)='authority_' OR tbl_name IN ('authority_control','authority_tasks','authority_bindings','authority_policies','authority_operations')")
        var expected:[Data:[AuthorityStateKernel.Value]]=[:]
        for (name,sql) in zip(kernel.tableNames,kernel.schemaStatements) {
            expected[Data(name.utf8)]=[.text("table"),.text(name),.text(name),.text(sql.replacingOccurrences(of:"IF NOT EXISTS ",with:""))]
        }
        let indexes:[(table:String,column:String,cid:Int,origin:String)]=[
            ("authority_tasks","id",0,"pk"),("authority_bindings","conversation_id",0,"pk"),
            ("authority_policies","id",0,"pk"),("authority_operations","request_id",1,"u")
        ]
        for index in indexes {
            let name="sqlite_autoindex_"+index.table+"_1"
            expected[Data(name.utf8)]=[.text("index"),.text(name),.text(index.table),.null]
        }
        guard objects.count == expected.count else { throw AuthorityStateError.integrity }
        for object in objects {
            guard object.count == 4,let wanted=expected.removeValue(forKey:Data(object[1].string.utf8)),same(object,wanted) else { throw AuthorityStateError.integrity }
        }
        guard expected.isEmpty else { throw AuthorityStateError.integrity }
        let columns:[[(String,String,Int,Int)]]=[
            [("id","INTEGER",0,1),("payload","BLOB",1,0),("digest","TEXT",1,0)],
            [("id","TEXT",0,1),("payload","BLOB",1,0),("digest","TEXT",1,0)],
            [("conversation_id","TEXT",0,1),("payload","BLOB",1,0),("digest","TEXT",1,0)],
            [("id","TEXT",0,1),("payload","BLOB",1,0),("digest","TEXT",1,0)],
            [("sequence","INTEGER",0,1),("request_id","TEXT",1,0),("request_payload","BLOB",0,0),("receipt_payload","BLOB",1,0),("receipt_digest","TEXT",1,0)]
        ]
        for (table,definitions) in zip(kernel.tableNames,columns) {
            let actual=try kernel.rows(database,"PRAGMA table_info("+table+")")
            let wanted=definitions.enumerated().map { position,column -> [AuthorityStateKernel.Value] in
                [.integer(position),.text(column.0),.text(column.1),.integer(column.2),.null,.integer(column.3)]
            }
            guard actual.count == wanted.count,zip(actual,wanted).allSatisfy({same($0.0,$0.1)}) else { throw AuthorityStateError.integrity }
            let indexRows=try kernel.rows(database,"PRAGMA index_list("+table+")")
            if let index=indexes.first(where:{$0.table == table}) {
                let name="sqlite_autoindex_"+table+"_1"
                guard indexRows.count == 1,same(indexRows[0],[.integer(0),.text(name),.integer(1),.text(index.origin),.integer(0)]) else { throw AuthorityStateError.integrity }
                let info=try kernel.rows(database,"PRAGMA index_info("+name+")")
                guard info.count == 1,same(info[0],[.integer(0),.integer(index.cid),.text(index.column)]) else { throw AuthorityStateError.integrity }
            } else { guard indexRows.isEmpty else { throw AuthorityStateError.integrity } }
        }
    }
    private static func same(_ lhs:[AuthorityStateKernel.Value],_ rhs:[AuthorityStateKernel.Value])->Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs,rhs).allSatisfy { left,right in
            switch (left,right) {
            case (.text(let a),.text(let b)): return Data(a.utf8) == Data(b.utf8)
            case (.integer(let a),.integer(let b)): return a == b
            case (.bytes(let a),.bytes(let b)): return a == b
            case (.null,.null): return true
            default: return false
            }
        }
    }
    private static func projections(_ database:OpaquePointer,_ table:String,key:String,records:[(String,Data)]) throws {
        let rows=try AuthorityStateKernel.rows(database,"SELECT "+key+",payload,digest FROM "+table)
        guard rows.count == records.count else { throw AuthorityStateError.integrity }
        var expected:[Data:Data]=[:]
        for (id,bytes) in records { guard expected.updateValue(bytes,forKey:Data(id.utf8)) == nil else { throw AuthorityStateError.integrity } }
        for row in rows {
            guard let bytes=row[1].bytes,expected.removeValue(forKey:Data(row[0].string.utf8)) == bytes,row[2].string == AuthorityStateKernel.digest(bytes) else { throw AuthorityStateError.integrity }
        }
        guard expected.isEmpty else { throw AuthorityStateError.integrity }
    }
    static func inventory(database:OpaquePointer) throws -> AuthorityStateInventory {
        try validate(database:database)
        let state=try AuthorityStateKernel.snapshot(database:database)
        return AuthorityStateInventory(storeID:state.storeID,ownerID:state.ownerID,controlEpoch:state.controlEpoch,revision:state.revision,timeHighWater:state.timeHighWater,tasks:state.tasks.count,bindings:state.bindings.count,policies:state.policies.count,operations:state.journalSequence,stateSHA256:AuthorityStateKernel.digest(try AuthorityStateKernel.canonical(state)))
    }
    static func validateRestore(database:OpaquePointer,archived:AuthorityStateInventory) throws {
        let current=try inventory(database:database)
        guard archived.controlEpoch < Int.max,archived.revision < Int.max,archived.operations < Int.max,episodeIdentifierEqual(current.storeID,archived.storeID),episodeIdentifierEqual(current.ownerID,archived.ownerID),current.controlEpoch == archived.controlEpoch+1,current.revision == archived.revision+1,current.operations == archived.operations+1,current.timeHighWater == archived.timeHighWater,current.tasks == archived.tasks,current.bindings == archived.bindings,current.policies == archived.policies else { throw AuthorityStateError.integrity }
        let rows=try AuthorityStateKernel.rows(database,"SELECT receipt_payload FROM authority_operations ORDER BY sequence DESC LIMIT 1")
        guard rows.count == 1,let bytes=rows[0][0].bytes else { throw AuthorityStateError.integrity }
        let receipt=try AuthorityStateKernel.decode(AuthorityOperationReceipt.self,bytes)
        guard receipt.kind == "startup",receipt.previousStateSHA256 == archived.stateSHA256,receipt.stateSHA256 == current.stateSHA256 else { throw AuthorityStateError.integrity }
    }
}
