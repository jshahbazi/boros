import Foundation

/// Frozen host choice for context selection. Both strategies retain the same
/// mandatory/recent preparation, component caps and original episode lease.
enum ContextRetrievalStrategy: String, Codable, CaseIterable {
    case hybrid
    case recentOnly = "recent_only"
}
