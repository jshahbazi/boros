import Foundation

/// Shared byte framing for live selection and offline provenance validation.
enum ContextSourceFraming {
    static let legacySelectionVersion = "context-source-snapshot-v1"
    static let identitySelectionVersion = "context-source-snapshot-v2"
    static let currentSelectionVersion = "context-source-snapshot-v3"
    static let recentMetadataHeading = "Recent source metadata (host): "
    static let evidencePrefix = "Historical source excerpts for reference:\n\n"
    static let evidenceSeparator = "\n\n"
    static let evidenceFooter = "\nEND HISTORICAL SOURCE"

    static func recentPrefix(role: String, status: String) -> String {
        status == "complete" ? "" : "[Incomplete historical \(role) message; capture status: \(status).]\n"
    }

    static func isSupportedSelectionVersion(_ version: String) -> Bool {
        version == legacySelectionVersion || version == identitySelectionVersion || version == currentSelectionVersion
    }

    /// V1 and V2 retain their exact bytes for existing journals and archives.
    /// V3 adds captured/source calendar evidence without changing payload bytes.
    /// IDs are arbitrary valid store identifiers, not interpolated field text.
    static func recentPrefix(eventID: String, role: String, status: String,
                             selectionVersion: String, capturedAt: String? = nil, sourceTime: EventSourceTime? = nil) throws -> String {
        if selectionVersion == legacySelectionVersion { return recentPrefix(role: role, status: status) }
        guard (selectionVersion == identitySelectionVersion || selectionVersion == currentSelectionVersion), !eventID.isEmpty,
              eventID.utf8.count <= 256, !eventID.utf8.contains(0),
              MemoryRole(rawValue: role) != nil, CaptureStatus(rawValue: status) != nil else { throw ContextError.sourceMismatch }
        var fields: [String: Any] = ["event_id": eventID, "role": role, "capture_status": status]
        if selectionVersion == currentSelectionVersion {
            guard let capturedAt else { throw ContextError.sourceMismatch }
            try validateCapturedUTC(capturedAt)
            fields["captured_utc"] = capturedAt
            fields["source_time"] = try sourceTime?.validated().object as Any? ?? NSNull()
        }
        let bytes = try JSONSerialization.data(withJSONObject: fields,
            options: [.sortedKeys, .withoutEscapingSlashes])
        // JSON permits these Unicode separators literally. Escape them so a
        // hostile identifier cannot introduce another metadata line.
        let metadata = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return recentPrefix(role: role, status: status) + recentMetadataHeading + metadata + "\nOriginal message text:\n"
    }

    private static func validateCapturedUTC(_ value: String) throws {
        let calendar: (value: String, precision: String, timezone: String)
        do { calendar = try EventSourceTime.normalize(value) } catch { throw ContextError.sourceMismatch }
        guard calendar.timezone == "Z", ["second", "fractional_second"].contains(calendar.precision) else { throw ContextError.sourceMismatch }
    }

    static func evidenceHeader(eventID: String, conversationID: String, role: String,
        status: String, createdAt: String, digest: String, offset: Int, totalBytes: Int,
        selectionVersion: String = currentSelectionVersion, sourceTime: EventSourceTime? = nil) throws -> String {
        guard isSupportedSelectionVersion(selectionVersion) else { throw ContextError.sourceMismatch }
        let chronology: String
        if selectionVersion == currentSelectionVersion {
            try validateCapturedUTC(createdAt)
            let metadata = try JSONSerialization.data(withJSONObject: sourceTime?.validated().object as Any? ?? NSNull(),
                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            let json = String(decoding: metadata, as: UTF8.self)
                .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            chronology = "captured_utc: " + createdAt + "\nsource_time: " + json
        } else { chronology = "source_created_utc: " + createdAt }
        return """
        BEGIN HISTORICAL SOURCE
        event_id: \(eventID)
        conversation_id: \(conversationID)
        role: \(role)
        capture_status: \(status)
        \(chronology)
        source_sha256: \(digest)
        excerpt_utf8_offset: \(offset)
        source_total_bytes: \(totalBytes)
        quoted_excerpt:
        """ + "\n"
    }
}
