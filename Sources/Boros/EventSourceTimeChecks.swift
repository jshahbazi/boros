import Foundation

enum EventSourceTimeChecks {
    static func run() throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let cases: [(String, String, String, String)] = [
            ("2000-02-29", "2000-02-29", "day", "unspecified"),
            ("2023-05-30T10:42", "2023-05-30T10:42", "minute", "unspecified"),
            ("2023-05-30T10:42Z", "2023-05-30T10:42", "minute", "Z"),
            ("2023-05-30T10:42:59+14:00", "2023-05-30T10:42:59", "second", "+14:00"),
            ("2023-05-30T10:42:59.123456789-12:30", "2023-05-30T10:42:59.123456789", "fractional_second", "-12:30"),
            ("2023/05/30 (Tue) 10:42", "2023-05-30T10:42", "minute", "unspecified"),
            ("0001/01/01 (Mon)", "0001-01-01", "day", "unspecified"),
            ("1582/10/04 (Mon)", "1582-10-04", "day", "unspecified")
        ]
        for (index, item) in cases.enumerated() {
            let result = try EventSourceTime.normalize(item.0)
            checks["source_time_calendar_case_\(index)"] = result.value == item.1 && result.precision == item.2 && result.timezone == item.3
        }
        let invalid = ["1900-02-29", "2023-02-29", "0000-01-01", "2023-13-01", "2023-04-31",
            "2023-05-30T24:00", "2023-05-30T10:60", "2023-05-30T10:42:60Z",
            "2023-05-30T10:42+14:01", "2023-05-30T10:42-00:00", "2023-05-30T10:42+01:60",
            "2023-05-30T10:42:59.1234567890Z", "2023-05-30\n", " 2023-05-30",
            "2023-05-30T10:42 Europe/Paris", "2023/05/30 (Mon) 10:42", "1685443320", "2023-05-30\u{00a0}"]
        for (index, literal) in invalid.enumerated() {
            checks["source_time_invalid_literal_\(index)"] = rejected { _ = try EventSourceTime.normalize(literal) }
        }
        let date = EventSourceTime(value: "2023-05-30", precision: "day", timezone: "unspecified",
            sourceSHA256: String(repeating: "a", count: 64), locator: "/messages/0/timestamp", originalValue: "2023-05-30")
        let canonical = try date.validated().canonicalData()
        checks["source_time_canonical_roundtrip"] = try EventSourceTime.decodeCanonical(canonical) == date
        checks["source_time_whitespace_bytes_refused"] = rejected { _ = try EventSourceTime.decodeCanonical(Data(" ".utf8) + canonical) }
        var extra = date.object; extra["extra"] = "synthetic"
        checks["source_time_unknown_key_refused"] = rejected { _ = try JSONDecoder().decode(EventSourceTime.self, from: JSONSerialization.data(withJSONObject: extra)) }
        var missing = date.object; missing.removeValue(forKey: "timezone")
        checks["source_time_missing_key_refused"] = rejected { _ = try JSONDecoder().decode(EventSourceTime.self, from: JSONSerialization.data(withJSONObject: missing)) }
        var mismatch = date.object; mismatch["value"] = "2023-05-31"
        checks["source_time_normalized_value_mismatch_refused"] = rejected { _ = try JSONDecoder().decode(EventSourceTime.self, from: JSONSerialization.data(withJSONObject: mismatch)) }
        checks["source_time_pointer_escapes_and_empty_components"] = try EventSourceTime.pointerTokens("/a~1b/~0//") == ["a/b", "~", "", ""]
        checks["source_time_pointer_unknown_escape_refused"] = rejected { _ = try EventSourceTime.pointerTokens("/a~2b") }
        checks["source_time_pointer_unfinished_escape_refused"] = rejected { _ = try EventSourceTime.pointerTokens("/a~") }
        let composed = EventSourceTime(value: date.value, precision: date.precision, timezone: date.timezone,
            sourceSHA256: date.sourceSHA256, locator: "/é", originalValue: date.originalValue)
        let decomposed = EventSourceTime(value: date.value, precision: date.precision, timezone: date.timezone,
            sourceSHA256: date.sourceSHA256, locator: "/e\u{301}", originalValue: date.originalValue)
        checks["source_time_locator_utf8_identity_preserved"] = composed != decomposed
        return checks
    }
    private static func rejected(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }
}
