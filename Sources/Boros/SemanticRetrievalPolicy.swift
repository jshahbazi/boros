import Foundation

/// Whether a host may consult, build or maintain the local semantic index.
///
/// User decision, October 8, 2026: ordinary Send retrieves with lexical
/// selection only, and the application schedules no background semantic
/// indexing. The evidence is in docs/P2-SEMANTIC-DECISION.md: on the offline
/// retrieval harness, fused semantic retrieval lowered delivered recall
/// (development R2 50/90 against 60/90 for lexical alone, regression 8/12
/// against 9/12), and no semantic-only result recovered any case.
///
/// `ordinarySend` is the single switch for both decisions. Setting it to
/// `.enabled` restores fused retrieval on ordinary Send and background
/// semantic maintenance together. Explicit evaluation commands, harness arms
/// and self-tests construct their own index on demand and pass `.enabled`
/// (the parameter default), so comparisons with fused retrieval stay possible.
/// Existing sidecar files are neither read nor deleted under the policy.
enum SemanticRetrievalPolicy: String, Codable {
    case enabled
    case disabledByPolicy = "disabled_by_policy"

    /// The application's ordinary Send paths and its background maintenance.
    static let ordinarySend: SemanticRetrievalPolicy = .disabledByPolicy

    /// Content-free retrieval-audit field recorded when the policy withholds
    /// the semantic index. Absent when semantic retrieval is permitted.
    static let auditField = "semantic_retrieval"

    /// The index a preparation may consult under this policy.
    func admit(_ index: SemanticIndex?) -> SemanticIndex? { self == .enabled ? index : nil }

    /// Whether the application may open the sidecar, run the startup encoder
    /// probe, or schedule background semantic work.
    var permitsBackgroundIndexing: Bool { self == .enabled }

    /// User-facing state for the background indexing status sheet.
    static let disabledStatus = "Semantic indexing is turned off by policy. Ordinary Send searches original sources lexically, and no background encoder work is scheduled."
    static let disabledStorageNote = "Semantic index files written by earlier versions remain on disk and are not read or deleted."
}

/// The application's owner of the optional semantic sidecar. Ordinary hosts go
/// through these entry points so the policy gates opening (which runs a metered
/// encoder probe and takes the sidecar owner lock) and scheduling. Explicit
/// on-demand builders call `SemanticIndex(store:)` and `process` directly.
enum ApplicationSemanticMaintenance {
    static func openIndex(store: MemoryStore, policy: SemanticRetrievalPolicy = .ordinarySend,
                          open: (MemoryStore) throws -> SemanticIndex = { try SemanticIndex(store: $0) }) throws -> SemanticIndex? {
        guard policy.permitsBackgroundIndexing else { return nil }
        return try open(store)
    }

    /// Returns whether background semantic work was requested.
    @discardableResult
    static func schedule(_ index: SemanticIndex?, projectID: String, policy: SemanticRetrievalPolicy = .ordinarySend) -> Bool {
        guard policy.permitsBackgroundIndexing, let index else { return false }
        index.schedule(projectID: projectID)
        return true
    }
}
