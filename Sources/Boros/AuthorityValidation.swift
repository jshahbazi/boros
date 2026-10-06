import Foundation

/// Internal episode-funded full-replay validation. This receipt grants no
/// dispatch or delivery permission and cannot replace the later shared gate.
struct AuthorityValidationReceipt {
    let version = "authority-validation-v1"
    let episodeID: String
    let episodeBindingSHA256: String
    let controlEpoch: Int
    let authorityRevision: Int
    let operationIDs: [String]
    let charged: EpisodeResources
}
