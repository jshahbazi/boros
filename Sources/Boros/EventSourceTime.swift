import Foundation

/// Captured source-calendar evidence, independent of the host's ingestion clock.
/// The importer additionally verifies the literal at its original JSON pointer.
struct EventSourceTime: Codable, Equatable {
    let value: String
    let precision: String
    let timezone: String
    let sourceSHA256: String
    let locator: String
    let originalValue: String
    static let maximumBytes = 4096

    enum CodingKeys: String, CodingKey {
        case value, precision, timezone, locator
        case sourceSHA256 = "source_sha256", originalValue = "original_value"
    }
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(value: String, precision: String, timezone: String, sourceSHA256: String,
         locator: String, originalValue: String) {
        self.value = value; self.precision = precision; self.timezone = timezone
        self.sourceSHA256 = sourceSHA256; self.locator = locator; self.originalValue = originalValue
    }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allNames) else { throw Self.invalid() }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(value: try c.decode(String.self, forKey: .value), precision: try c.decode(String.self, forKey: .precision),
            timezone: try c.decode(String.self, forKey: .timezone), sourceSHA256: try c.decode(String.self, forKey: .sourceSHA256),
            locator: try c.decode(String.self, forKey: .locator), originalValue: try c.decode(String.self, forKey: .originalValue))
        _ = try validated()
    }
    func validated() throws -> Self {
        guard sourceSHA256.utf8.count == 64,
              sourceSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              locator.hasPrefix("/"), locator.utf8.count <= 2048, !locator.utf8.contains(0),
              originalValue.utf8.count <= 128 else { throw Self.invalid() }
        _ = try Self.pointerTokens(locator)
        let normalized = try Self.normalize(originalValue)
        guard value == normalized.value, precision == normalized.precision, timezone == normalized.timezone,
              try canonicalData().count <= Self.maximumBytes else { throw Self.invalid() }
        return self
    }
    func canonicalData() throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    var object: [String: String] {
        ["value": value, "precision": precision, "timezone": timezone, "source_sha256": sourceSHA256,
         "locator": locator, "original_value": originalValue]
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        zip([lhs.value, lhs.precision, lhs.timezone, lhs.sourceSHA256, lhs.locator, lhs.originalValue],
            [rhs.value, rhs.precision, rhs.timezone, rhs.sourceSHA256, rhs.locator, rhs.originalValue])
            .allSatisfy { Data($0.0.utf8) == Data($0.1.utf8) }
    }
    static func decodeCanonical(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw invalid() }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard try value.canonicalData() == bytes else { throw invalid() }
        return value
    }
    /// Supported formats are explicit calendar literals. No locale guessing,
    /// epoch-unit guessing, timezone assignment, or conversion to host time.
    static func normalize(_ literal: String) throws -> (value: String, precision: String, timezone: String) {
        guard literal.utf8.count <= 128 else { throw invalid() }
        let iso = "^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(\\.[0-9]{1,9})?)?(Z|[+-][0-9]{2}:[0-9]{2})?)?$"
        let local = "^([0-9]{4})/([0-9]{2})/([0-9]{2}) \\((Sun|Mon|Tue|Wed|Thu|Fri|Sat)\\)(?: ([0-9]{2}):([0-9]{2}))?$"
        func groups(_ pattern: String) throws -> [String?]? {
            let regex = try NSRegularExpression(pattern: pattern)
            let full = NSRange(literal.startIndex..<literal.endIndex, in: literal)
            guard let match = regex.firstMatch(in: literal, range: full), match.range == full else { return nil }
            return (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: literal) else { return nil }
                return String(literal[range])
            }
        }
        let pieces: [String?], isLocal: Bool
        if let parsed = try groups(iso) { pieces = parsed; isLocal = false }
        else if let parsed = try groups(local) { pieces = parsed; isLocal = true }
        else { throw invalid() }
        guard let y = pieces[0], let m = pieces[1], let d = pieces[2], let year = Int(y), let month = Int(m), let day = Int(d),
              (1...9999).contains(year), (1...12).contains(month) else { throw invalid() }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { throw invalid() }
        if isLocal {
            // Proleptic Gregorian arithmetic also handles dates before the
            // historical calendar cutover, consistently with the import adapter.
            let adjustedYear = month < 3 ? year - 1 : year
            let shifts = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
            let weekday = (adjustedYear + adjustedYear / 4 - adjustedYear / 100 + adjustedYear / 400 + shifts[month - 1] + day) % 7
            guard ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][weekday] == pieces[3] else { throw invalid() }
        }
        var value = y + "-" + m + "-" + d
        let h = pieces[isLocal ? 4 : 3], minute = pieces[isLocal ? 5 : 4]
        guard let hour = h, let minute else { return (value, "day", "unspecified") }
        guard let hh = Int(hour), let mm = Int(minute), (0...23).contains(hh), (0...59).contains(mm) else { throw invalid() }
        value += "T" + hour + ":" + minute
        if isLocal { return (value, "minute", "unspecified") }
        let seconds = pieces[5], fraction = pieces[6], zone = pieces[7] ?? "unspecified"
        if let seconds {
            guard let ss = Int(seconds), (0...59).contains(ss) else { throw invalid() }
            value += ":" + seconds + (fraction ?? "")
        }
        if zone != "unspecified" && zone != "Z" {
            let raw = Array(zone.utf8)
            guard let zh = Int(String(decoding: raw[1...2], as: UTF8.self)),
                  let zm = Int(String(decoding: raw[4...5], as: UTF8.self)), zh <= 14, zm <= 59,
                  zh != 14 || zm == 0, zone != "-00:00" else { throw invalid() }
        }
        return (value, seconds == nil ? "minute" : (fraction == nil ? "second" : "fractional_second"), zone)
    }
    static func pointerTokens(_ pointer: String) throws -> [String] {
        guard pointer.hasPrefix("/") else { throw invalid() }
        return try pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { token in
            var result = "", index = token.startIndex
            while index < token.endIndex {
                let char = token[index]; index = token.index(after: index)
                if char != "~" { result.append(char); continue }
                guard index < token.endIndex else { throw invalid() }
                let escaped = token[index]; index = token.index(after: index)
                if escaped == "0" { result.append("~") } else if escaped == "1" { result.append("/") } else { throw invalid() }
            }
            return result
        }
    }
    private static func invalid() -> CocoaError { CocoaError(.coderInvalidValue) }
}
private extension EventSourceTime.CodingKeys {
    static var allNames: [String] { ["value", "precision", "timezone", "source_sha256", "locator", "original_value"] }
}
