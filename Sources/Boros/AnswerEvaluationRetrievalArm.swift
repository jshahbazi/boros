import Foundation

/// Retrieval configuration of one `--answer-evaluation` attempt.
///
/// Without `--retrieval-arm`, each attempt runs its declared strategy exactly
/// as before: `recent_only`, or `hybrid` (explicit fused retrieval: the runner
/// builds the history's semantic index before acceptance and passes it with
/// the coordinator's default `.enabled` policy).
///
/// `--retrieval-arm ordinary_send` runs each declared `hybrid` attempt in the
/// ordinary Send configuration of the selected-Qwen GUI path
/// (`BonsaiPlayground.sendSharedAttempt`, docs/P2-SEMANTIC-DECISION.md): the
/// host obtains its index through `ApplicationSemanticMaintenance.openIndex`,
/// which opens nothing under `SemanticRetrievalPolicy.ordinarySend`, and the
/// coordinator receives `semanticRetrieval: .ordinarySend`. No semantic index
/// is built or passed, selection is lexical, and the retrieval audit records
/// `"semantic_retrieval": "disabled_by_policy"`. This is the retrieval harness
/// `ordinary_send` arm, which selects exactly what its `lexical` arm selects.
/// Declared `recent_only` attempts are unchanged by the flag.
enum AnswerEvaluationRetrievalArm: String, CaseIterable {
    case recentOnly = "recent_only"
    case hybrid
    case ordinarySend = "ordinary_send"

    /// The only value `--retrieval-arm` accepts. The other arms are selected
    /// by an attempt's declared strategy.
    static let selectable: Set<AnswerEvaluationRetrievalArm> = [.ordinarySend]

    /// The arm an attempt runs: its declared strategy, unless the invocation
    /// selected an arm for retrieval-on (declared `hybrid`) attempts.
    static func resolve(declared: ContextRetrievalStrategy, selected: AnswerEvaluationRetrievalArm?) -> AnswerEvaluationRetrievalArm {
        switch declared {
        case .recentOnly: return .recentOnly
        case .hybrid: return selected ?? .hybrid
        }
    }

    /// `--retrieval-arm ordinary_send` reproduces ordinary Send only while the
    /// application's policy withholds the semantic index. If the policy were
    /// enabled again, the GUI would pass a background-maintained index that an
    /// evaluation attempt does not have, so the flag is refused instead.
    static var ordinarySendSelectable: Bool { SemanticRetrievalPolicy.ordinarySend == .disabledByPolicy }

    var retrievalStrategy: ContextRetrievalStrategy { self == .recentOnly ? .recentOnly : .hybrid }

    /// The coordinator's policy argument. `.enabled` is the coordinator's
    /// default, so the recent-only and hybrid arms pass exactly what they
    /// passed before this type existed.
    var semanticRetrieval: SemanticRetrievalPolicy { self == .ordinarySend ? .ordinarySend : .enabled }

    /// Whether the runner builds the history's semantic index before
    /// acceptance (the existing per-hybrid-attempt construction).
    var buildsSemanticIndex: Bool { self == .hybrid }

    /// The index the application host would hold for ordinary Send, obtained
    /// through the host's own entry point. Nil for the other arms, whose index
    /// (if any) comes from the explicit construction instead.
    func hostIndex(store: MemoryStore,
                   open: (MemoryStore) throws -> SemanticIndex = { try SemanticIndex(store: $0) }) throws -> SemanticIndex? {
        guard self == .ordinarySend else { return nil }
        return try ApplicationSemanticMaintenance.openIndex(store: store, policy: .ordinarySend, open: open)
    }
}
