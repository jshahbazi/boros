import Foundation

/// Shared byte framing for live selection and offline provenance validation.
enum ContextSourceFraming {
    static let legacySelectionVersion = "context-source-snapshot-v1"
    static let currentSelectionVersion = "context-source-snapshot-v2"
    static let recentMetadataHeading = "Recent source metadata (host): "
    static let evidencePrefix = "Historical source excerpts for reference:\n\n"
    static let evidenceSeparator = "\n\n"
    static let evidenceFooter = "\nEND HISTORICAL SOURCE"

    static func recentPrefix(role: String, status: String) -> String {
        status == "complete" ? "" : "[Incomplete historical \(role) message; capture status: \(status).]\n"
    }

    static func isSupportedSelectionVersion(_ version: String) -> Bool {
        version == legacySelectionVersion || version == currentSelectionVersion
    }

    /// V1 is retained byte-for-byte for existing journals and archives. V2
    /// exposes source identity while the original payload remains unmodified.
    /// IDs are arbitrary valid store identifiers, not interpolated field text.
    static func recentPrefix(eventID: String, role: String, status: String,
                             selectionVersion: String) throws -> String {
        if selectionVersion == legacySelectionVersion { return recentPrefix(role: role, status: status) }
        guard selectionVersion == currentSelectionVersion, !eventID.isEmpty,
              eventID.utf8.count <= 256, !eventID.utf8.contains(0),
              MemoryRole(rawValue: role) != nil, CaptureStatus(rawValue: status) != nil else { throw ContextError.sourceMismatch }
        let bytes = try JSONSerialization.data(withJSONObject: ["event_id": eventID, "role": role, "capture_status": status],
            options: [.sortedKeys, .withoutEscapingSlashes])
        // JSON permits these Unicode separators literally. Escape them so a
        // hostile identifier cannot introduce another metadata line.
        let metadata = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return recentPrefix(role: role, status: status) + recentMetadataHeading + metadata + "\nOriginal message text:\n"
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
