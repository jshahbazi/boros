import Foundation

/// Shared byte framing for live selection and offline provenance validation.
enum ContextSourceFraming {
    static let evidencePrefix = "Historical source excerpts for reference:\n\n"
    static let evidenceSeparator = "\n\n"
    static let evidenceFooter = "\nEND HISTORICAL SOURCE"

    static func recentPrefix(role: String, status: String) -> String {
        status == "complete" ? "" : "[Incomplete historical \(role) message; capture status: \(status).]\n"
    }

    static func evidenceHeader(eventID: String, conversationID: String, role: String,
        status: String, createdAt: String, digest: String, offset: Int, totalBytes: Int) -> String {
        """
        BEGIN HISTORICAL SOURCE
        event_id: \(eventID)
        conversation_id: \(conversationID)
        role: \(role)
        capture_status: \(status)
        source_created_utc: \(createdAt)
        source_sha256: \(digest)
        excerpt_utf8_offset: \(offset)
        source_total_bytes: \(totalBytes)
        quoted_excerpt:
        """ + "\n"
    }
}
