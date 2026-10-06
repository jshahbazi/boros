import Foundation
import CryptoKit
import CSQLite

struct EpisodeAccountingSummary: Equatable {
    let workCount:Int
    let snapshotBytes:Int
    let unknownInputOperations:Int
}

struct EpisodeAccountingInventory: Codable,Equatable {
    var version="episode-accounting-inventory-v1"
    let episodes:Int
    let snapshotReferences:Int
    let settlementReceipts:Int
    let quarantineKeys:Int
    let accountingSHA256:String
    let snapshotReferencesSHA256:String
    let settlementReceiptsSHA256:String
    let quarantineSHA256:String
}

/// Original work/request/settlement rows remain authoritative. These schema-8
/// projections permit bounded setup queries; they confer no live capability.
enum EpisodeAccountingJournal {
    static let tableNames=["episode_accounting","episode_snapshot_references","episode_settlement_receipts","episode_adapter_quarantine"]
    static let schemaStatements=[
        "CREATE TABLE IF NOT EXISTS episode_accounting(episode_id TEXT COLLATE BINARY NOT NULL PRIMARY KEY REFERENCES episodes(id),work_count INTEGER NOT NULL CHECK(work_count>=0 AND work_count<=100000),snapshot_bytes INTEGER NOT NULL CHECK(snapshot_bytes>=0 AND snapshot_bytes<=67108864),unknown_input_operations INTEGER NOT NULL CHECK(unknown_input_operations>=0 AND unknown_input_operations<=work_count))",
        "CREATE TABLE IF NOT EXISTS episode_snapshot_references(episode_id TEXT COLLATE BINARY NOT NULL REFERENCES episodes(id),snapshot_digest TEXT COLLATE BINARY NOT NULL REFERENCES episode_request_snapshots(digest),PRIMARY KEY(episode_id,snapshot_digest))",
        "CREATE TABLE IF NOT EXISTS episode_settlement_receipts(episode_id TEXT COLLATE BINARY NOT NULL REFERENCES episodes(id),receipt_id TEXT COLLATE BINARY NOT NULL,work_id TEXT COLLATE BINARY NOT NULL REFERENCES episode_work(id),ordinal INTEGER NOT NULL CHECK(ordinal>=0 AND ordinal<=2),receipt_sha256 TEXT NOT NULL CHECK(length(receipt_sha256)=64),PRIMARY KEY(episode_id,receipt_id),UNIQUE(work_id,ordinal))",
        "CREATE TABLE IF NOT EXISTS episode_adapter_quarantine(kind TEXT NOT NULL CHECK(kind IN ('exact','family')),identity TEXT COLLATE BINARY NOT NULL CHECK(length(CAST(identity AS BLOB))>=1 AND length(CAST(identity AS BLOB))<=2304),witness_work_id TEXT COLLATE BINARY NOT NULL REFERENCES episode_work(id),PRIMARY KEY(kind,identity))"
    ]

    private typealias Cell=AuthorityStateKernel.Value
    private static func transactionRequired(_ db:OpaquePointer)throws {
        guard sqlite3_get_autocommit(db) == 0 else { throw AuthorityStateError.invalid }
    }
    private static func identifier(_ value:String)throws { try AuthorityStateKernel.identifier(value) }
    private static func digest(_ value:String)throws {
        guard value.utf8.count == 64,value.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else { throw AuthorityStateError.integrity }
    }
    private static func canonical<T:Encodable>(_ value:T)throws->Data {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]; return try encoder.encode(value)
    }
    private static func decode<T:Decodable>(_ type:T.Type,_ bytes:Data)throws->T {
        guard bytes.count <= 65536 else { throw AuthorityStateError.limit }
        do { return try JSONDecoder().decode(type,from:bytes) } catch { throw AuthorityStateError.integrity }
    }
    private static func visit(_ db:OpaquePointer,_ sql:String,_ values:[Cell]=[],maximumTextBytes:Int=2304,_ body:([Cell])throws->Void)throws {
        var raw:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&raw,nil) == SQLITE_OK,let statement=raw else { throw AuthorityStateError.integrity }
        defer { sqlite3_finalize(statement) }
        let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (offset,value) in values.enumerated() {
            let index=Int32(offset+1),code:Int32
            switch value {
            case .text(let text): code=text.withCString { sqlite3_bind_text(statement,index,$0,Int32(text.utf8.count),transient) }
            case .bytes(let bytes): code=bytes.withUnsafeBytes { sqlite3_bind_blob(statement,index,$0.baseAddress,Int32(bytes.count),transient) }
            case .integer(let integer): code=sqlite3_bind_int64(statement,index,Int64(integer))
            case .null: code=sqlite3_bind_null(statement,index)
            }
            guard code == SQLITE_OK else { throw AuthorityStateError.integrity }
        }
        while true {
            let code=sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else { throw AuthorityStateError.integrity }
            var row:[Cell]=[]
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement,column) {
                case SQLITE_INTEGER:row.append(.integer(Int(sqlite3_column_int64(statement,column))))
                case SQLITE_TEXT:
                    let count=Int(sqlite3_column_bytes(statement,column))
                    guard count <= maximumTextBytes,let pointer=sqlite3_column_text(statement,column),let text=String(bytes:UnsafeBufferPointer(start:pointer,count:count),encoding:.utf8) else { throw AuthorityStateError.integrity }
                    row.append(.text(text))
                case SQLITE_BLOB:
                    let count=Int(sqlite3_column_bytes(statement,column)); guard count <= 65536 else { throw AuthorityStateError.limit }
                    row.append(.bytes(sqlite3_column_blob(statement,column).map { Data(bytes:$0,count:count) } ?? Data()))
                case SQLITE_NULL:row.append(.null)
                default:throw AuthorityStateError.integrity
                }
            }
            try body(row)
        }
    }
    private static func rows(_ db:OpaquePointer,_ sql:String,_ values:[Cell]=[],maximumTextBytes:Int=2304)throws->[[Cell]] {
        var result:[[Cell]]=[]
        try visit(db,sql,values,maximumTextBytes:maximumTextBytes) { row in
            guard result.count < 16 else { throw AuthorityStateError.limit }; result.append(row)
        }
        return result
    }
    private static func execute(_ db:OpaquePointer,_ sql:String,_ values:[Cell]=[])throws {
        try AuthorityStateKernel.execute(db,sql,values)
    }
    static func install(database:OpaquePointer)throws {
        try transactionRequired(database)
        for sql in schemaStatements { try execute(database,sql) }
        try validateSchema(database:database)
    }
    private static func same(_ lhs:[Cell],_ rhs:[Cell])->Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs,rhs).allSatisfy { a,b in
            switch(a,b) {
            case(.text(let a),.text(let b)):return Data(a.utf8)==Data(b.utf8)
            case(.integer(let a),.integer(let b)):return a==b
            case(.null,.null):return true
            default:return false
            }
        }
    }
    private static let schemaQuery="SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE name IN ('episode_accounting','episode_snapshot_references','episode_settlement_receipts','episode_adapter_quarantine') OR tbl_name IN ('episode_accounting','episode_snapshot_references','episode_settlement_receipts','episode_adapter_quarantine')"
    static func validateSchema(database:OpaquePointer)throws {
        var reference:OpaquePointer?
        guard sqlite3_open(":memory:",&reference) == SQLITE_OK,let reference else { throw AuthorityStateError.integrity }
        defer { sqlite3_close(reference) }
        for sql in schemaStatements { try execute(reference,sql) }
        var expected:[Data:[Cell]]=[:]
        try visit(reference,schemaQuery,maximumTextBytes:65536) { expected[Data($0[1].string.utf8)]=$0 }
        try visit(database,schemaQuery,maximumTextBytes:65536) { row in
            guard let wanted=expected.removeValue(forKey:Data(row[1].string.utf8)),same(row,wanted) else { throw AuthorityStateError.integrity }
        }
        guard expected.isEmpty else { throw AuthorityStateError.integrity }
    }
    static func summary(database:OpaquePointer,episodeID:String)throws->EpisodeAccountingSummary {
        try identifier(episodeID)
        let result=try rows(database,"SELECT work_count,snapshot_bytes,unknown_input_operations FROM episode_accounting WHERE episode_id=?",[.text(episodeID)])
        guard result.count == 1,result[0].count == 3 else { throw AuthorityStateError.integrity }
        for cell in result[0] { guard case .integer=cell else { throw AuthorityStateError.integrity } }
        let row=result[0],count=row[0].integer,bytes=row[1].integer,unknown=row[2].integer
        guard (0...100000).contains(count),(0...67108864).contains(bytes),(0...count).contains(unknown) else { throw AuthorityStateError.integrity }
        return EpisodeAccountingSummary(workCount:count,snapshotBytes:bytes,unknownInputOperations:unknown)
    }
    static func createEpisode(database:OpaquePointer,episodeID:String)throws {
        try transactionRequired(database); try identifier(episodeID)
        guard try rows(database,"SELECT id FROM episodes WHERE id=?",[.text(episodeID)]).count == 1 else { throw AuthorityStateError.missing }
        try execute(database,"INSERT INTO episode_accounting VALUES(?,0,0,0)",[.text(episodeID)])
    }
    static func hasSnapshot(database:OpaquePointer,episodeID:String,digest:String)throws->Bool {
        try identifier(episodeID); try self.digest(digest)
        return try !rows(database,"SELECT 1 FROM episode_snapshot_references WHERE episode_id=? AND snapshot_digest=?",[.text(episodeID),.text(digest)]).isEmpty
    }
    private static func unknown(_ request:EpisodeWorkRequest,_ state:EpisodeWorkState)->Int {
        !request.inputTokensKnown && request.resources.modelCalls > 0 && state != .prepared && state != .cancelledBeforeDispatch ? 1:0
    }
    private static func workMetadata(_ db:OpaquePointer,_ id:String)throws->(episodeID:String,request:EpisodeWorkRequest,state:EpisodeWorkState,snapshot:String?,violation:Bool) {
        try identifier(id)
        let result=try rows(db,"SELECT episode_id,request_json,request_digest,state,snapshot_digest,adapter_identity,adapter_violation FROM episode_work WHERE id=?",[.text(id)])
        guard result.count == 1,let bytes=result[0][1].bytes,AuthorityStateKernel.digest(bytes) == result[0][2].string,let state=EpisodeWorkState(rawValue:result[0][3].string),case .integer=result[0][6],(0...1).contains(result[0][6].integer) else { throw AuthorityStateError.integrity }
        let row=result[0],request=try decode(EpisodeWorkRequest.self,bytes)
        try identifier(row[0].string); try identifier(request.id); _=try request.resources.validated()
        guard episodeIdentifierEqual(request.id,id),request.snapshot == nil,episodeIdentifierEqual(request.adapterIdentity,row[5].string),!request.adapterIdentity.isEmpty,request.adapterIdentity.utf8.count <= 2048,!request.adapterIdentity.utf8.contains(0) else { throw AuthorityStateError.integrity }
        let snapshot=row[4].isNull ? nil:row[4].string
        if let snapshot { try digest(snapshot) }
        return(row[0].string,request,state,snapshot,row[6].integer == 1)
    }
    private static func matches(_ actual:EpisodeWorkRequest,_ supplied:EpisodeWorkRequest)->Bool {
        episodeIdentifierEqual(actual.id,supplied.id) && episodeIdentifierEqual(actual.parentID,supplied.parentID) && actual.kind == supplied.kind && actual.resources == supplied.resources && episodeIdentifierEqual(actual.adapterIdentity,supplied.adapterIdentity) && actual.inputTokensKnown == supplied.inputTokensKnown
    }
    private static func reserved(_ db:OpaquePointer,episodeID:String,request:EpisodeWorkRequest,snapshot:String?,snapshotByteCount:Int,state:EpisodeWorkState)throws {
        let old=try summary(database:db,episodeID:episodeID)
        guard old.workCount < 100000,snapshotByteCount >= 0,snapshotByteCount <= 4194304 else { throw AuthorityStateError.limit }
        var added=0
        if let snapshot {
            try digest(snapshot)
            if try !hasSnapshot(database:db,episodeID:episodeID,digest:snapshot) {
                try execute(db,"INSERT INTO episode_snapshot_references VALUES(?,?)",[.text(episodeID),.text(snapshot)])
                added=snapshotByteCount
            }
        } else { guard snapshotByteCount == 0 else { throw AuthorityStateError.invalid } }
        guard old.snapshotBytes <= 67108864-added else { throw AuthorityStateError.limit }
        try execute(db,"UPDATE episode_accounting SET work_count=?,snapshot_bytes=?,unknown_input_operations=? WHERE episode_id=?",[.integer(old.workCount+1),.integer(old.snapshotBytes+added),.integer(old.unknownInputOperations+unknown(request,state)),.text(episodeID)])
        guard sqlite3_changes(db) == 1 else { throw AuthorityStateError.integrity }
    }
    static func recordReservedWork(database:OpaquePointer,episodeID:String,request:EpisodeWorkRequest,snapshotDigest:String?,snapshotByteCount:Int)throws {
        try transactionRequired(database); try identifier(episodeID)
        let actual=try workMetadata(database,request.id)
        guard episodeIdentifierEqual(actual.episodeID,episodeID),matches(actual.request,request),actual.state == .prepared,episodeIdentifierEqual(actual.snapshot,snapshotDigest) else { throw AuthorityStateError.integrity }
        if let snapshotDigest {
            let snapshot=try rows(database,"SELECT byte_count FROM episode_request_snapshots WHERE digest=?",[.text(snapshotDigest)])
            guard snapshot.count == 1,case .integer=snapshot[0][0],snapshot[0][0].integer == snapshotByteCount else { throw AuthorityStateError.integrity }
            if let bytes=request.snapshot { guard bytes.count == snapshotByteCount,AuthorityStateKernel.digest(bytes) == snapshotDigest else { throw AuthorityStateError.integrity } }
        } else { guard request.snapshot == nil else { throw AuthorityStateError.integrity } }
        try reserved(database,episodeID:episodeID,request:actual.request,snapshot:snapshotDigest,snapshotByteCount:snapshotByteCount,state:actual.state)
    }
    static func recordTransition(database:OpaquePointer,episodeID:String,request:EpisodeWorkRequest,from:EpisodeWorkState,to:EpisodeWorkState)throws {
        try transactionRequired(database); try identifier(episodeID)
        let actual=try workMetadata(database,request.id)
        guard episodeIdentifierEqual(actual.episodeID,episodeID),matches(actual.request,request),actual.state == to else { throw AuthorityStateError.integrity }
        let delta=unknown(actual.request,to)-unknown(actual.request,from)
        if delta != 0 {
            let old=try summary(database:database,episodeID:episodeID),next=old.unknownInputOperations+delta
            guard (0...old.workCount).contains(next) else { throw AuthorityStateError.integrity }
            try execute(database,"UPDATE episode_accounting SET unknown_input_operations=? WHERE episode_id=?",[.integer(next),.text(episodeID)])
            guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
        }
    }
    static func settlementOwner(database:OpaquePointer,episodeID:String,receiptID:String)throws->String? {
        try identifier(episodeID); try identifier(receiptID)
        let result=try rows(database,"SELECT work_id FROM episode_settlement_receipts WHERE episode_id=? AND receipt_id=?",[.text(episodeID),.text(receiptID)])
        guard result.count <= 1 else { throw AuthorityStateError.integrity }
        if let first=result.first { try identifier(first[0].string); return first[0].string }; return nil
    }
    private static func settlement(_ db:OpaquePointer,episodeID:String,workID:String,ordinal:Int,value:EpisodeWorkSettlement)throws {
        try identifier(episodeID); try identifier(workID); try identifier(value.receiptID)
        guard (0...2).contains(ordinal) else { throw AuthorityStateError.invalid }
        let sha=AuthorityStateKernel.digest(try canonical(value))
        let old=try rows(db,"SELECT work_id,ordinal,receipt_sha256 FROM episode_settlement_receipts WHERE episode_id=? AND receipt_id=?",[.text(episodeID),.text(value.receiptID)])
        if let first=old.first { guard episodeIdentifierEqual(first[0].string,workID),first[1].integer == ordinal,first[2].string == sha else { throw AuthorityStateError.conflict }; return }
        try execute(db,"INSERT INTO episode_settlement_receipts VALUES(?,?,?,?,?)",[.text(episodeID),.text(value.receiptID),.text(workID),.integer(ordinal),.text(sha)])
    }
    static func recordSettlement(database:OpaquePointer,episodeID:String,workID:String,ordinal:Int,settlement:EpisodeWorkSettlement)throws {
        try transactionRequired(database)
        let actual=try workMetadata(database,workID)
        guard episodeIdentifierEqual(actual.episodeID,episodeID) else { throw AuthorityStateError.integrity }
        let rows=try self.rows(database,"SELECT receipt_json,receipt_digest FROM episode_work WHERE id=?",[.text(workID)])
        guard rows.count == 1,let bytes=rows[0][0].bytes,AuthorityStateKernel.digest(bytes) == rows[0][1].string else { throw AuthorityStateError.integrity }
        let values=try decode([EpisodeWorkSettlement].self,bytes)
        guard values.count <= 3,(0..<values.count).contains(ordinal),values[ordinal] == settlement else { throw AuthorityStateError.integrity }
        try self.settlement(database,episodeID:episodeID,workID:workID,ordinal:ordinal,value:settlement)
    }
    private static func quarantineKey(_ identity:String)throws->(String,String) {
        guard !identity.isEmpty,identity.utf8.count <= 2048,!identity.utf8.contains(0) else { throw AuthorityStateError.invalid }
        if let family=ProviderAdapterQuarantineFamily.recognize(identity) { return("family",family.identity) }
        return("exact",identity)
    }
    static func isQuarantined(database:OpaquePointer,adapterIdentity:String)throws->Bool {
        let key=try quarantineKey(adapterIdentity)
        return try !rows(database,"SELECT 1 FROM episode_adapter_quarantine WHERE kind=? AND identity=?",[.text(key.0),.text(key.1)]).isEmpty
    }
    private static func quarantine(_ db:OpaquePointer,workID:String,adapterIdentity:String)throws {
        try identifier(workID); let key=try quarantineKey(adapterIdentity)
        try execute(db,"INSERT INTO episode_adapter_quarantine(kind,identity,witness_work_id) VALUES(?,?,?) ON CONFLICT(kind,identity) DO UPDATE SET witness_work_id=CASE WHEN excluded.witness_work_id<episode_adapter_quarantine.witness_work_id COLLATE BINARY THEN excluded.witness_work_id ELSE episode_adapter_quarantine.witness_work_id END",[.text(key.0),.text(key.1),.text(workID)])
    }
    static func recordQuarantine(database:OpaquePointer,workID:String,adapterIdentity:String)throws {
        try transactionRequired(database)
        let actual=try workMetadata(database,workID)
        guard actual.violation,episodeIdentifierEqual(actual.request.adapterIdentity,adapterIdentity) else { throw AuthorityStateError.integrity }
        try quarantine(database,workID:workID,adapterIdentity:adapterIdentity)
    }

    /// Private disposable disk-backed metadata reconstruction. It is not a
    /// durable authority ledger. Normal completion removes scratch; a killed
    /// process can leave private scratch for later scoped maintenance.
    private static func reconstructed<T>(_ source:OpaquePointer,_ body:(OpaquePointer)throws->T)throws->T {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("boros-accounting-validation-"+UUID().uuidString.lowercased(),isDirectory:true)
        var expected:OpaquePointer?
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { if let expected { sqlite3_close(expected) }; try? FileManager.default.removeItem(at:directory) }
            let path=directory.appendingPathComponent("metadata.sqlite3").path
            guard sqlite3_open_v2(path,&expected,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK,let target=expected else { throw AuthorityStateError.integrity }
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path)
            for pragma in ["PRAGMA foreign_keys=OFF","PRAGMA journal_mode=OFF","PRAGMA synchronous=OFF","PRAGMA temp_store=FILE","PRAGMA cache_size=-1024"] { _ = try rows(target,pragma) }
            for sql in schemaStatements { try execute(target,sql) }
            try execute(target,"BEGIN")
            try visit(source,"SELECT id FROM episodes ORDER BY id COLLATE BINARY") { row in
                try identifier(row[0].string)
                try execute(target,"INSERT INTO episode_accounting VALUES(?,0,0,0)",[.text(row[0].string)])
            }
            try visit(source,"SELECT id FROM episode_work ORDER BY id COLLATE BINARY") { row in
                let id=row[0].string,work=try workMetadata(source,id)
                var snapshotBytes=0
                if let snapshot=work.snapshot {
                    let values=try rows(source,"SELECT byte_count FROM episode_request_snapshots WHERE digest=?",[.text(snapshot)])
                    guard values.count == 1,case .integer=values[0][0] else { throw AuthorityStateError.integrity }
                    snapshotBytes=values[0][0].integer
                }
                try reserved(target,episodeID:work.episodeID,request:work.request,snapshot:work.snapshot,snapshotByteCount:snapshotBytes,state:work.state)
                let values=try rows(source,"SELECT receipt_json,receipt_digest FROM episode_work WHERE id=?",[.text(id)])
                guard values.count == 1,let bytes=values[0][0].bytes,(bytes.isEmpty ? "":AuthorityStateKernel.digest(bytes)) == values[0][1].string else { throw AuthorityStateError.integrity }
                let receipts=bytes.isEmpty ? []:try decode([EpisodeWorkSettlement].self,bytes)
                guard receipts.count <= 3 else { throw AuthorityStateError.integrity }
                for (ordinal,value) in receipts.enumerated() {
                    if let resources=value.observed { _=try resources.validated() }
                    guard value.evidence.map({$0.count <= 16384}) ?? true else { throw AuthorityStateError.integrity }
                    try settlement(target,episodeID:work.episodeID,workID:id,ordinal:ordinal,value:value)
                }
                if work.violation { try quarantine(target,workID:id,adapterIdentity:work.request.adapterIdentity) }
            }
            try execute(target,"COMMIT")
            return try body(target)
        } catch { throw AuthorityStateError.integrity }
    }
    private static let projections:[String]=[
        "SELECT episode_id,work_count,snapshot_bytes,unknown_input_operations FROM episode_accounting ORDER BY episode_id COLLATE BINARY",
        "SELECT episode_id,snapshot_digest FROM episode_snapshot_references ORDER BY episode_id COLLATE BINARY,snapshot_digest COLLATE BINARY",
        "SELECT episode_id,receipt_id,work_id,ordinal,receipt_sha256 FROM episode_settlement_receipts ORDER BY episode_id COLLATE BINARY,receipt_id COLLATE BINARY",
        "SELECT kind,identity,witness_work_id FROM episode_adapter_quarantine ORDER BY kind COLLATE BINARY,identity COLLATE BINARY"
    ]
    private struct EncodedCell:Codable { let kind:String; let text:String?; let integer:Int? }
    private static func rowBytes(_ row:[Cell])throws->Data {
        let values=try row.map { cell->EncodedCell in
            switch cell {
            case .text(let value):return EncodedCell(kind:"text",text:value,integer:nil)
            case .integer(let value):return EncodedCell(kind:"integer",text:nil,integer:value)
            default:throw AuthorityStateError.integrity
            }
        }
        return try canonical(values)
    }
    private static func fold(_ db:OpaquePointer,_ sql:String)throws->(Int,String) {
        var count=0,hash=SHA256(); hash.update(data:Data("[".utf8))
        try visit(db,sql) { row in
            if count > 0 { hash.update(data:Data(",".utf8)) }
            hash.update(data:try rowBytes(row)); try AuthorityStateKernel.increment(&count)
        }
        hash.update(data:Data("]".utf8))
        return(count,hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    private static func measured(_ db:OpaquePointer)throws->EpisodeAccountingInventory {
        let stats=try fold(db,projections[0]),snapshots=try fold(db,projections[1]),receipts=try fold(db,projections[2]),quarantine=try fold(db,projections[3])
        return EpisodeAccountingInventory(episodes:stats.0,snapshotReferences:snapshots.0,settlementReceipts:receipts.0,quarantineKeys:quarantine.0,accountingSHA256:stats.1,snapshotReferencesSHA256:snapshots.1,settlementReceiptsSHA256:receipts.1,quarantineSHA256:quarantine.1)
    }
    static func backfill(database:OpaquePointer)throws {
        try transactionRequired(database); try validateSchema(database:database)
        for name in tableNames { guard try rows(database,"SELECT 1 FROM "+name+" LIMIT 1").isEmpty else { throw AuthorityStateError.conflict } }
        try reconstructed(database) { expected in
            for (index,sql) in projections.enumerated() {
                let placeholders=index == 0 ? "?,?,?,?":(index == 1 ? "?,?":(index == 2 ? "?,?,?,?,?":"?,?,?"))
                try visit(expected,sql) { row in try execute(database,"INSERT INTO "+tableNames[index]+" VALUES("+placeholders+")",row) }
            }
        }
    }
    static func validate(database:OpaquePointer)throws {
        let ownsSnapshot=sqlite3_get_autocommit(database) != 0
        do {
            if ownsSnapshot { try execute(database,"BEGIN") }
            try validateSchema(database:database)
            try reconstructed(database) { expected in
                guard try measured(database) == measured(expected) else { throw AuthorityStateError.integrity }
            }
            if ownsSnapshot { try execute(database,"COMMIT") }
        } catch {
            if ownsSnapshot { try? execute(database,"ROLLBACK") }
            throw AuthorityStateError.integrity
        }
    }
    static func inventory(database:OpaquePointer)throws->EpisodeAccountingInventory {
        let ownsSnapshot=sqlite3_get_autocommit(database) != 0
        do {
            if ownsSnapshot { try execute(database,"BEGIN") }
            try validate(database:database)
            let result=try measured(database)
            if ownsSnapshot { try execute(database,"COMMIT") }
            return result
        } catch {
            if ownsSnapshot { try? execute(database,"ROLLBACK") }
            throw AuthorityStateError.integrity
        }
    }
}
