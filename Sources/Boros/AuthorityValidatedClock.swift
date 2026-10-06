import Foundation
import CSQLite

extension AuthorityStateKernel {
    /// The caller owns BEGIN IMMEDIATE, funding and owner/data_version/write
    /// generation fences. The proof alone is not a live permission capability.
    static func advanceTimeValidated(database:OpaquePointer,proof:AuthorityValidatedCurrent,expectedControlSHA256:String,expectedTailReceiptSHA256:String,now:Int64,progress:AuthorityValidationProgress?=nil)throws->AuthorityValidatedClockResult {
        try AuthorityStateJournal.advanceTimeValidated(database:database,proof:proof,expectedControlSHA256:expectedControlSHA256,expectedTailReceiptSHA256:expectedTailReceiptSHA256,now:now,progress:progress)
    }
}

/// Performs checked transitions but cannot mint replay evidence. Only the
/// journal's fileprivate proof constructor publishes a returned candidate.
enum AuthorityValidatedClock {
    static let fixedPointMetadataRows=2
    static let fixedPointStatements=2
    static let maximumTemporalProjectionRows=3*AuthorityStateKernel.maximumRecords
    struct Update {
        let current:AuthorityStateSnapshot
        let currentBytes:Int
        let tail:AuthorityOperationReceipt
        let beforeTail:AuthorityStateSnapshot
        let tailReceiptSHA256:String
        let tailReceiptBytes:Int
        let journalBytes:Int
        let verifiedRequestIDs:Set<Data>
        let changed:Bool
    }
    static func advance(database:OpaquePointer,proof:AuthorityValidatedCurrent,expectedControlSHA256:String,expectedTailReceiptSHA256:String,now:Int64,progress:AuthorityValidationProgress?)throws->Update? {
        let kernel=AuthorityStateKernel.self
        try progress?()
        guard sqlite3_get_autocommit(database) == 0,now >= 0,
            expectedControlSHA256 == proof.controlSHA256,expectedTailReceiptSHA256 == proof.tailReceiptSHA256,
            proof.current.journalSequence == proof.tail.journalSequence,
            proof.verifiedRequestIDs.count == proof.current.journalSequence,
            proof.journalBytes >= proof.tailReceiptBytes+proof.tailRequestBytes,
            proof.journalBytes <= kernel.maximumJournalBytes else { throw AuthorityStateError.integrity }
        // No original control/receipt payload is materialized by these fixed
        // point reads. Guards also bound corrupt TEXT before copying it.
        let control=try kernel.rows(database,"SELECT CASE WHEN typeof(digest)='text' AND length(CAST(digest AS BLOB))=64 THEN digest ELSE NULL END,typeof(payload),length(CAST(payload AS BLOB)) FROM authority_control WHERE id=1")
        guard control.count == 1,control[0][0].string == expectedControlSHA256,control[0][1].string == "blob",control[0][2].integer == proof.currentBytes else { throw AuthorityStateError.staleRevision }
        let tail=try kernel.rows(database,"SELECT sequence,CASE WHEN typeof(request_id)='text' AND length(CAST(request_id AS BLOB))<=256 THEN request_id ELSE NULL END,CASE WHEN typeof(receipt_digest)='text' AND length(CAST(receipt_digest AS BLOB))=64 THEN receipt_digest ELSE NULL END,typeof(receipt_payload),length(CAST(receipt_payload AS BLOB)),typeof(request_payload),coalesce(length(CAST(request_payload AS BLOB)),0) FROM authority_operations ORDER BY sequence DESC LIMIT 1")
        guard tail.count == 1,tail[0][0].integer == proof.tail.journalSequence,episodeIdentifierEqual(tail[0][1].string,proof.tail.requestID),tail[0][2].string == expectedTailReceiptSHA256,tail[0][3].string == "blob",tail[0][4].integer == proof.tailReceiptBytes,tail[0][6].integer == proof.tailRequestBytes,
            (proof.tail.requestSHA256 == nil ? tail[0][5].string == "null":tail[0][5].string == "blob") else { throw AuthorityStateError.staleRevision }
        try progress?()
        guard now > proof.current.timeHighWater else { return nil }
        let before=proof.current; var after=before; after.timeHighWater=now
        let changed:Bool
        if proof.nextTemporalBoundary.map({now >= $0}) ?? false { changed=try kernel.expireAndActivate(&after,progress:progress) }
        else { changed=false }
        let coalesce = !changed && proof.tail.version == "authority-receipt-v2" && proof.tail.kind == "clockCheckpoint"
        if changed { try kernel.increment(&after.controlEpoch); try kernel.increment(&after.revision) }
        if !coalesce { try kernel.increment(&after.journalSequence) }
        guard after.journalSequence <= kernel.maximumOperations else { throw AuthorityStateError.limit }
        let requestID=coalesce ? proof.tail.requestID:(changed ? "authority-time:":"authority-clock:")+UUID().uuidString.lowercased()
        var requestIDs=proof.verifiedRequestIDs
        if !coalesce { guard requestIDs.insert(Data(requestID.utf8)).inserted else { throw AuthorityStateError.conflict } }
        var expired:[String]=[]
        if changed {
            var oldPolicies:[Data:AuthorityPolicyState]=[:]
            for policy in before.policies { try progress?(); oldPolicies[Data(policy.id.utf8)]=policy.state }
            expired=after.policies.filter { $0.state == .expired && oldPolicies[Data($0.id.utf8)] != .expired }.map(\.id)
        }
        try progress?()
        let beforeTail=coalesce ? proof.beforeTail:before
        let stateBytes=try kernel.canonical(after)
        try progress?()
        guard stateBytes.count <= 4*1024*1024 else { throw AuthorityStateError.limit }
        var receipt=AuthorityOperationReceipt(requestID:requestID,operation:nil,kind:changed ? "time":"clockCheckpoint",origin:"scheduler",revision:after.revision,controlEpoch:after.controlEpoch,journalSequence:after.journalSequence,timeHighWater:after.timeHighWater,previousStateSHA256:coalesce ? proof.tail.previousStateSHA256:proof.controlSHA256,stateSHA256:kernel.digest(stateBytes),requestSHA256:nil,expiredPolicyIDs:expired)
        receipt.version=changed ? "authority-receipt-v1":"authority-receipt-v2"
        let receiptBytes=try kernel.canonical(receipt)
        try progress?()
        let receiptSHA=kernel.digest(receiptBytes)
        let keptBytes=proof.journalBytes-(coalesce ? proof.tailReceiptBytes:0)
        guard receiptBytes.count <= 4*1024*1024,keptBytes <= kernel.maximumJournalBytes-receiptBytes.count else { throw AuthorityStateError.limit }
        try progress?()
        if coalesce {
            guard proof.tail.origin == "scheduler",proof.tail.operation == nil,proof.tail.requestSHA256 == nil,proof.tail.expiredPolicyIDs.isEmpty,proof.tail.requestID.hasPrefix("authority-clock:"),proof.tail.revision == before.revision,proof.tail.controlEpoch == before.controlEpoch,proof.tail.timeHighWater == before.timeHighWater else { throw AuthorityStateError.integrity }
            try kernel.execute(database,"UPDATE authority_operations SET receipt_payload=?,receipt_digest=? WHERE sequence=? AND request_id=? AND receipt_digest=?",[.bytes(receiptBytes),.text(receiptSHA),.integer(proof.tail.journalSequence),.text(proof.tail.requestID),.text(expectedTailReceiptSHA256)])
        } else {
            try kernel.execute(database,"INSERT INTO authority_operations(sequence,request_id,request_payload,receipt_payload,receipt_digest) VALUES(?,?,NULL,?,?)",[.integer(after.journalSequence),.text(requestID),.bytes(receiptBytes),.text(receiptSHA)])
        }
        guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
        try kernel.execute(database,"UPDATE authority_control SET payload=?,digest=? WHERE id=1 AND digest=?",[.bytes(stateBytes),.text(receipt.stateSHA256),.text(expectedControlSHA256)])
        guard sqlite3_changes(database) == 1 else { throw AuthorityStateError.integrity }
        if changed { try kernel.persistProjections(database,state:after,progress:progress) }
        try progress?()
        return Update(current:after,currentBytes:stateBytes.count,tail:receipt,beforeTail:beforeTail,tailReceiptSHA256:receiptSHA,tailReceiptBytes:receiptBytes.count,journalBytes:keptBytes+receiptBytes.count,verifiedRequestIDs:requestIDs,changed:changed)
    }
}
