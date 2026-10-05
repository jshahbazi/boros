import Foundation

/// A worker-local hint; no bytes/vectors survive beyond an armed attempt. The
/// final completion gate always performs its own freshly charged full seal.
struct BackgroundInitialSealToken {
    let sourceDigest: String
    let indexFingerprint: String
    let workID: String
    let bindingDigest: String
    func matches(sourceDigest: String, indexFingerprint: String) -> Bool {
        backgroundIndexIdentifierEqual(self.sourceDigest, sourceDigest)
            && backgroundIndexIdentifierEqual(self.indexFingerprint, indexFingerprint)
    }
}

enum BackgroundIndexWorkerStage { case armed, beforePublication, publishedBeforeSettlement }

/// Deterministic component checks may stop at these content-free boundaries.
/// The application never installs an observer.
typealias BackgroundIndexWorkerObserver = (BackgroundIndexWorkerStage, BackgroundIndexWorkRecord) throws -> Void

enum BackgroundWorkerAccounting {
    static func reference(_ source: MemorySourceReference) -> BackgroundIndexSourceReference {
        .init(sequence: source.sequence, eventID: source.eventID, conversationID: source.conversationID,
            projectID: source.projectID, role: source.role.rawValue, status: source.status.rawValue,
            createdAt: source.createdAt, digest: source.digest, byteCount: source.byteCount)
    }
    static func sealEvidence(source: BackgroundIndexSourceReference) throws -> Data {
        try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: BackgroundIndexCanonical.digest(source),
            offset: 0, byteCount: source.byteCount, sourceSealedSHA256: source.digest,
            sourceSealedByteCount: source.byteCount).canonicalData()
    }
    static func emptyEvidence(source: BackgroundIndexSourceReference) throws -> Data {
        try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: BackgroundIndexCanonical.digest(source),
            offset: 0, byteCount: 0, sourceSealedSHA256: source.digest, sourceSealedByteCount: 0).canonicalData()
    }
    static func chunkEvidence(source: BackgroundIndexSourceReference, offset: Int, byteCount: Int, textDigest: String,
                              vectorBytes: Int, publication: Int, isFinal: Bool) throws -> Data {
        try BackgroundIndexWorkerEvidence(sourceReferenceSHA256: BackgroundIndexCanonical.digest(source),
            offset: offset, byteCount: byteCount, textSHA256: textDigest,
            vectorByteCount: vectorBytes, publicationSequence: publication,
            sourceSealedSHA256: isFinal ? source.digest : nil,
            sourceSealedByteCount: isFinal ? source.byteCount : nil).canonicalData()
    }

    /// Only declared public sentences enter the startup probe. Reservation and
    /// arm precede every inference; failed probes retain their declared charge.
    static func probe(store: MemoryStore, encoder: SemanticEmbeddingAdapter, adapterIdentity: String,
                      clock: BackgroundIndexClockSource, limits: BackgroundIndexLimits) throws -> [String: String] {
        let request = try BackgroundIndexWorkRequest.publicEncoderProbe(id: UUID().uuidString, adapterIdentity: adapterIdentity)
        let prepared = try store.reserveBackgroundWork(request: request, clockSource: clock, limits: limits)
        let work: BackgroundIndexWorkRecord
        do {
            work = try store.armBackgroundWork(workID: prepared.request.id, bindingDigest: prepared.bindingDigest, clockSource: clock)
        } catch {
            _ = try? store.settleBackgroundWork(workID: prepared.request.id,
                settlement: .init(receiptID: UUID().uuidString, outcome: .cancelledBeforeDispatch), clockSource: clock)
            throw error
        }
        do {
            var bytes = Data()
            for sentence in BackgroundIndexOperationDescriptor.publicProbeSentences {
                if case .vector(let values) = try encoder.encode(sentence) {
                    bytes.append(SemanticIndex.vectorData(try SemanticIndex.normalized(values, dimension: encoder.dimension)))
                }
            }
            _ = try store.settleBackgroundWork(workID: work.request.id,
                settlement: .init(receiptID: UUID().uuidString, outcome: .completed), clockSource: clock)
            return encoder.metadata.merging(["probe_digest": bytes.count == 2 * encoder.dimension * 4
                ? BackgroundIndexCanonical.sha256(bytes) : "unavailable"]) { _, actual in actual }
        } catch {
            _ = try? store.settleBackgroundWork(workID: work.request.id,
                settlement: .init(receiptID: UUID().uuidString, outcome: error is BackgroundIndexBudgetError ? .outcomeUnknown : .failedConfirmed), clockSource: clock)
            throw error
        }
    }
}
