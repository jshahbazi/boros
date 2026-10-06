import Foundation
import CryptoKit
import CSQLite

/// Offline linkage/provenance checks do not authorize live dispatch or output.
enum AuthorityBindingJournal {
    static let tableNames=AuthorityBindings.tableNames
    static let schemaStatements=AuthorityBindings.schemaStatements
    static func classifyLegacy(database:OpaquePointer)throws { try AuthorityBindings.classifyLegacy(database:database) }
    static func insertLegacyEpisode(database:OpaquePointer,id:String)throws { try AuthorityBindings.insertLegacyEpisode(database:database,id:id) }
    static func insertLegacyWork(database:OpaquePointer,id:String)throws { try AuthorityBindings.insertLegacyWork(database:database,id:id) }
    static func insertLegacyInvocation(database:OpaquePointer,id:String)throws { try AuthorityBindings.insertLegacyInvocation(database:database,id:id) }
    static func managedEpisode(database:OpaquePointer,id:String)throws->AuthorityEpisodeBinding? { try AuthorityBindings.managedEpisode(database:database,id:id) }
    static func managedWork(database:OpaquePointer,id:String)throws->AuthorityWorkBinding? { try AuthorityBindings.managedWork(database:database,id:id) }
    static func insertManagedEpisode(database:OpaquePointer,binding:AuthorityEpisodeBinding,authority:AuthorityContext)throws { try AuthorityBindings.insertManagedEpisode(database:database,binding:binding,authority:authority) }
    static func insertManagedWork(database:OpaquePointer,binding:AuthorityWorkBinding)throws { try AuthorityBindings.insertManagedWork(database:database,binding:binding) }
    @discardableResult static func insertManagedInvocation(database:OpaquePointer,id:String)throws->AuthorityInvocationBinding { try AuthorityBindings.insertManagedInvocation(database:database,id:id) }
    static func validateSchema(database:OpaquePointer)throws {
        do {
            let rows=try AuthorityStateKernel.rows(database,"SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE name IN ('authority_episode_bindings','authority_work_bindings','authority_invocation_bindings') OR tbl_name IN ('authority_episode_bindings','authority_work_bindings','authority_invocation_bindings')")
            var expected:[Data:[AuthorityStateKernel.Value]]=[:]
            for (name,sql) in zip(tableNames,schemaStatements) {
                expected[Data(name.utf8)]=[.text("table"),.text(name),.text(name),.text(sql.replacingOccurrences(of:"IF NOT EXISTS ",with:""))]
                let index="sqlite_autoindex_"+name+"_1"
                expected[Data(index.utf8)]=[.text("index"),.text(index),.text(name),.null]
                let columns=try AuthorityStateKernel.rows(database,"PRAGMA table_info("+name+")")
                let desired:[[AuthorityStateKernel.Value]]=[
                    [.integer(0),.text("id"),.text("TEXT"),.integer(0),.null,.integer(1)],
                    [.integer(1),.text("payload"),.text("BLOB"),.integer(1),.null,.integer(0)],
                    [.integer(2),.text("digest"),.text("TEXT"),.integer(1),.null,.integer(0)]
                ]
                guard columns.count == desired.count,zip(columns,desired).allSatisfy({same($0.0,$0.1)}) else { throw AuthorityStateError.integrity }
                let indices=try AuthorityStateKernel.rows(database,"PRAGMA index_list("+name+")"),info=try AuthorityStateKernel.rows(database,"PRAGMA index_info("+index+")")
                guard indices.count == 1,same(indices[0],[.integer(0),.text(index),.integer(1),.text("pk"),.integer(0)]),info.count == 1,same(info[0],[.integer(0),.integer(0),.text("id")]) else { throw AuthorityStateError.integrity }
            }
            guard rows.count == expected.count else { throw AuthorityStateError.integrity }
            for row in rows { guard row.count == 4,let wanted=expected.removeValue(forKey:Data(row[1].string.utf8)),same(row,wanted) else { throw AuthorityStateError.integrity } }
            guard expected.isEmpty else { throw AuthorityStateError.integrity }
        } catch { throw AuthorityStateError.integrity }
    }
    private static func same(_ a:[AuthorityStateKernel.Value],_ b:[AuthorityStateKernel.Value])->Bool {
        guard a.count == b.count else { return false }
        return zip(a,b).allSatisfy { left,right in
            switch(left,right) {
            case (.text(let a),.text(let b)):return Data(a.utf8)==Data(b.utf8)
            case (.integer(let a),.integer(let b)):return a==b
            case (.null,.null):return true
            default:return false
            }
        }
    }
    static func validate(database:OpaquePointer)throws {
        do { try validateImpl(database:database) } catch { throw AuthorityStateError.integrity }
    }
    private static func validateImpl(database:OpaquePointer)throws {
        try validateSchema(database:database)
        for (source,target) in zip(["episodes","episode_work","invocations"],tableNames) {
            let missing=try AuthorityStateKernel.rows(database,"SELECT s.id FROM "+source+" s LEFT JOIN "+target+" b ON b.id=s.id WHERE b.id IS NULL LIMIT 1")
            let orphan=try AuthorityStateKernel.rows(database,"SELECT b.id FROM "+target+" b LEFT JOIN "+source+" s ON s.id=b.id WHERE s.id IS NULL LIMIT 1")
            guard missing.isEmpty,orphan.isEmpty else { throw AuthorityStateError.integrity }
        }
        let duplicates=try AuthorityStateKernel.rows(database,"SELECT count(*) FROM authority_episode_bindings WHERE json_extract(payload,'$.classification')='managed' GROUP BY json_extract(payload,'$.managed.requestID') HAVING count(*)>1 LIMIT 1")
        guard duplicates.isEmpty else { throw AuthorityStateError.integrity }
        try AuthorityBindings.visit(database:database,sql:"SELECT id,payload,digest FROM authority_episode_bindings ORDER BY id COLLATE BINARY") { row in
            let record=try AuthorityBindings.decoded(row,type:AuthorityEpisodeBinding.self)
            if let binding=record.managed {
                guard episodeIdentifierEqual(binding.episodeID,record.id) else { throw AuthorityStateError.integrity }
                try AuthorityBindings.validateEpisode(database:database,binding:binding,verifySourceBytes:true)
            }
        }
        try AuthorityBindings.visit(database:database,sql:"SELECT id,payload,digest FROM authority_work_bindings ORDER BY id COLLATE BINARY") { row in
            let record=try AuthorityBindings.decoded(row,type:AuthorityWorkBinding.self)
            if let binding=record.managed {
                guard episodeIdentifierEqual(binding.workID,record.id) else { throw AuthorityStateError.integrity }
                try AuthorityBindings.validateWork(database:database,binding:binding,verifySourceBytes:true)
            } else {
                let parents=try AuthorityStateKernel.rows(database,"SELECT episode_id FROM episode_work WHERE id=?",[.text(record.id)])
                guard parents.count == 1,let parent=try AuthorityBindings.read(database:database,table:tableNames[0],id:parents[0][0].string,type:AuthorityEpisodeBinding.self),parent.classification == .legacyUnbound else { throw AuthorityStateError.integrity }
            }
        }
        try AuthorityBindings.visit(database:database,sql:"SELECT id,payload,digest FROM authority_invocation_bindings ORDER BY id COLLATE BINARY") { row in
            let record=try AuthorityBindings.decoded(row,type:AuthorityInvocationBinding.self)
            if let binding=record.managed {
                guard episodeIdentifierEqual(binding.invocationID,record.id) else { throw AuthorityStateError.integrity }
                try AuthorityBindings.validateInvocation(database:database,binding:binding)
            } else {
                let parents=try AuthorityStateKernel.rows(database,"SELECT episode_id,episode_work_id FROM invocations WHERE id=?",[.text(record.id)])
                guard parents.count == 1,parents[0][0].isNull == parents[0][1].isNull else { throw AuthorityStateError.integrity }
                if !parents[0][0].isNull {
                    guard let episode=try AuthorityBindings.read(database:database,table:tableNames[0],id:parents[0][0].string,type:AuthorityEpisodeBinding.self),let work=try AuthorityBindings.read(database:database,table:tableNames[1],id:parents[0][1].string,type:AuthorityWorkBinding.self),episode.classification == .legacyUnbound,work.classification == .legacyUnbound else { throw AuthorityStateError.integrity }
                    let original=try AuthorityStateKernel.rows(database,"SELECT episode_id FROM episode_work WHERE id=?",[.text(parents[0][1].string)])
                    guard original.count == 1,episodeIdentifierEqual(original[0][0].string,parents[0][0].string) else { throw AuthorityStateError.integrity }
                }
            }
        }
    }
    private static func digest<T:Codable>(database:OpaquePointer,table:String,type:T.Type)throws->(total:Int,managed:Int,sha:String) {
        var total=0,managed=0,hasher=SHA256(); hasher.update(data:Data("[".utf8))
        try AuthorityBindings.visit(database:database,sql:"SELECT id,payload,digest FROM "+table+" ORDER BY id COLLATE BINARY") { row in
            let record=try AuthorityBindings.decoded(row,type:type)
            if total > 0 { hasher.update(data:Data(",".utf8)) }
            guard let payload=row[1].bytes else { throw AuthorityStateError.integrity }
            // Byte-for-byte canonical [Data] encoding, folded without retaining
            // all bindings. Each element carries its exact ID/classification.
            hasher.update(data:try AuthorityStateKernel.canonical(payload))
            try AuthorityStateKernel.increment(&total)
            if record.classification == .managed { try AuthorityStateKernel.increment(&managed) }
        }
        hasher.update(data:Data("]".utf8))
        return(total,managed,hasher.finalize().map{String(format:"%02x",$0)}.joined())
    }
    static func inventory(database:OpaquePointer)throws->AuthorityBindingInventory {
        try validate(database:database)
        let ep=try digest(database:database,table:tableNames[0],type:AuthorityEpisodeBinding.self)
        let work=try digest(database:database,table:tableNames[1],type:AuthorityWorkBinding.self)
        let invocation=try digest(database:database,table:tableNames[2],type:AuthorityInvocationBinding.self)
        return AuthorityBindingInventory(episodes:ep.total,work:work.total,invocations:invocation.total,managedEpisodes:ep.managed,managedWork:work.managed,managedInvocations:invocation.managed,legacyEpisodes:ep.total-ep.managed,legacyWork:work.total-work.managed,legacyInvocations:invocation.total-invocation.managed,episodeSHA256:ep.sha,workSHA256:work.sha,invocationSHA256:invocation.sha)
    }
    static func validateRestore(database:OpaquePointer,archived:AuthorityBindingInventory)throws {
        guard archived.version == "authority-binding-inventory-v1",try inventory(database:database) == archived else { throw AuthorityStateError.integrity }
    }
}
