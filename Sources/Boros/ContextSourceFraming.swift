import Foundation

/// Shared byte framing for live selection and offline provenance validation.
enum ContextSourceFraming {
    static let legacySelectionVersion = "context-source-snapshot-v1"
    static let identitySelectionVersion = "context-source-snapshot-v2"
    /// The v3 dated header framing. The name is retained for existing
    /// journals, archives and checks; it is no longer the default.
    static let currentSelectionVersion = "context-source-snapshot-v3"
    /// V4 quotes every recent source in a host-labelled user message (no
    /// assistant-role turn carries host text), replaces model-visible event IDs
    /// with host citation labels, and adds the insufficient-evidence wording.
    static let quotedSelectionVersion = "context-source-snapshot-v4"
    /// New episodes, ordinary Send and unpinned evaluation runs use this.
    static let defaultSelectionVersion = quotedSelectionVersion
    static let citationLabelVersion = "context-citation-labels-v1"
    static let quotedRecentHeading = "Earlier conversation message "
    static let quotedRecentNote = " (quoted by the host; not the current request)\n"
    static let recentMetadataHeading = "Recent source metadata (host): "
    static let evidencePrefix = "Historical source excerpts for reference:\n\n"
    static let evidenceSeparator = "\n\n"
    static let evidenceFooter = "\nEND HISTORICAL SOURCE"

    static func recentPrefix(role: String, status: String) -> String {
        status == "complete" ? "" : "[Incomplete historical \(role) message; capture status: \(status).]\n"
    }

    static func isSupportedSelectionVersion(_ version: String) -> Bool {
        version == legacySelectionVersion || version == identitySelectionVersion || version == currentSelectionVersion
            || version == quotedSelectionVersion
    }

    /// V3 and V4 deliver captured/source calendar evidence.
    static func carriesSourceTime(_ version: String) -> Bool {
        version == currentSelectionVersion || version == quotedSelectionVersion
    }

    /// V4 presents recent sources as host-quoted user messages with citation labels.
    static func quotesSources(_ version: String) -> Bool { version == quotedSelectionVersion }

    /// Host citation label for a zero-based delivery position: recent sources
    /// oldest first, then historical spans in delivered rank order.
    static func citationLabel(position: Int) throws -> String {
        guard position >= 0, position < 100_000 else { throw ContextError.sourceMismatch }
        return "E" + String(position + 1)
    }

    /// Chat role used for a recent source in this framing version.
    static func recentMessageRole(sourceRole: String, selectionVersion: String) -> String {
        quotesSources(selectionVersion) ? "user" : (sourceRole == "human" ? "user" : "assistant")
    }

    private static func escapedJSON(_ bytes: Data) -> String {
        // JSON permits these Unicode separators literally. Escape them so a
        // hostile identifier or locator cannot introduce another metadata line.
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{0085}", with: "\\u0085")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private static func sourceTimeJSON(_ sourceTime: EventSourceTime?) throws -> String {
        escapedJSON(try JSONSerialization.data(withJSONObject: sourceTime?.validated().object as Any? ?? NSNull(),
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]))
    }

    /// V1 and V2 retain their exact bytes for existing journals and archives.
    /// V3 adds captured/source calendar evidence without changing payload bytes.
    /// IDs are arbitrary valid store identifiers, not interpolated field text.
    /// V4 requires `citationPosition`; earlier versions refuse it. The V4
    /// prefix carries no event ID: the label maps to it in the selection journal.
    static func recentPrefix(eventID: String, role: String, status: String,
                             selectionVersion: String, capturedAt: String? = nil, sourceTime: EventSourceTime? = nil,
                             citationPosition: Int? = nil) throws -> String {
        guard quotesSources(selectionVersion) == (citationPosition != nil) else { throw ContextError.sourceMismatch }
        if selectionVersion == legacySelectionVersion { return recentPrefix(role: role, status: status) }
        guard (selectionVersion == identitySelectionVersion || carriesSourceTime(selectionVersion)), !eventID.isEmpty,
              eventID.utf8.count <= 256, !eventID.utf8.contains(0),
              MemoryRole(rawValue: role) != nil, CaptureStatus(rawValue: status) != nil else { throw ContextError.sourceMismatch }
        if let citationPosition {
            guard let capturedAt else { throw ContextError.sourceMismatch }
            try validateCapturedUTC(capturedAt)
            let label = try citationLabel(position: citationPosition)
            return recentPrefix(role: role, status: status) + quotedRecentHeading + "[" + label + "]"
                + quotedRecentNote + "role: " + role + "\ncapture_status: " + status + "\ncaptured_utc: " + capturedAt
                + "\nsource_time: " + (try sourceTimeJSON(sourceTime)) + "\nquoted_text:\n"
        }
        var fields: [String: Any] = ["event_id": eventID, "role": role, "capture_status": status]
        if selectionVersion == currentSelectionVersion {
            guard let capturedAt else { throw ContextError.sourceMismatch }
            try validateCapturedUTC(capturedAt)
            fields["captured_utc"] = capturedAt
            fields["source_time"] = try sourceTime?.validated().object as Any? ?? NSNull()
        }
        let metadata = escapedJSON(try JSONSerialization.data(withJSONObject: fields,
            options: [.sortedKeys, .withoutEscapingSlashes]))
        return recentPrefix(role: role, status: status) + recentMetadataHeading + metadata + "\nOriginal message text:\n"
    }

    private static func validateCapturedUTC(_ value: String) throws {
        let calendar: (value: String, precision: String, timezone: String)
        do { calendar = try EventSourceTime.normalize(value) } catch { throw ContextError.sourceMismatch }
        guard calendar.timezone == "Z", ["second", "fractional_second"].contains(calendar.precision) else { throw ContextError.sourceMismatch }
    }

    static func evidenceHeader(eventID: String, conversationID: String, role: String,
        status: String, createdAt: String, digest: String, offset: Int, totalBytes: Int,
        selectionVersion: String = currentSelectionVersion, sourceTime: EventSourceTime? = nil,
        citationPosition: Int? = nil) throws -> String {
        guard isSupportedSelectionVersion(selectionVersion), quotesSources(selectionVersion) == (citationPosition != nil) else {
            throw ContextError.sourceMismatch
        }
        let chronology: String
        if carriesSourceTime(selectionVersion) {
            try validateCapturedUTC(createdAt)
            chronology = "captured_utc: " + createdAt + "\nsource_time: " + (try sourceTimeJSON(sourceTime))
        } else { chronology = "source_created_utc: " + createdAt }
        if let citationPosition {
            // V4: the label replaces the model-visible event ID line.
            let label = try citationLabel(position: citationPosition)
            return """
            BEGIN HISTORICAL SOURCE [\(label)]
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

    /// V1 to V3 keep the unlabelled footer; V4 repeats the citation label.
    static func evidenceFooter(selectionVersion: String, citationPosition: Int? = nil) throws -> String {
        guard isSupportedSelectionVersion(selectionVersion), quotesSources(selectionVersion) == (citationPosition != nil) else {
            throw ContextError.sourceMismatch
        }
        guard let citationPosition else { return evidenceFooter }
        let label = try citationLabel(position: citationPosition)
        return evidenceFooter + " [" + label + "]"
    }
}
