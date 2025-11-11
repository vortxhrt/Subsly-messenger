import Foundation

enum ProfileSanitizer {
    private static let disallowedDisplayCharacters: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.remove(charactersIn: " ")
        return set
    }()

    private static let disallowedBioCharacters: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.remove(charactersIn: "\n")
        return set
    }()

    static func sanitizeDisplayName(_ name: String, fallback: String) -> String {
        let cleaned = stripCharacters(from: name, disallowedSet: disallowedDisplayCharacters)
        let collapsed = collapseWhitespace(in: cleaned)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(50))

        let fallbackCleaned = collapseWhitespace(in: fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackValue = fallbackCleaned.isEmpty ? "User" : fallbackCleaned
        return capped.isEmpty ? String(fallbackValue.prefix(50)) : capped
    }

    static func sanitizeBio(_ bio: String?, limit: Int = 160) -> String? {
        guard let bio else { return nil }
        let stripped = stripCharacters(from: bio, disallowedSet: disallowedBioCharacters)
        let normalizedNewlines = stripped.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let collapsed = collapseWhitespace(in: normalizedNewlines, allowNewlines: true)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    static func normalizeBioDraft(_ draft: String, limit: Int) -> String {
        let stripped = stripCharacters(from: draft, disallowedSet: disallowedBioCharacters)
        if stripped.count <= limit { return stripped }
        return String(stripped.prefix(limit))
    }

    private static func stripCharacters(from string: String, disallowedSet: CharacterSet) -> String {
        let scalars = string.unicodeScalars.filter { !disallowedSet.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func collapseWhitespace(in string: String, allowNewlines: Bool = false) -> String {
        if allowNewlines {
            let verticalWhitespace = try? NSRegularExpression(pattern: "[\t\x0B\f]+", options: [])
            let range = NSRange(location: 0, length: string.utf16.count)
            let cleaned = verticalWhitespace?.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: "") ?? string
            let multipleSpaces = try? NSRegularExpression(pattern: " {2,}", options: [])
            let cleanedRange = NSRange(location: 0, length: cleaned.utf16.count)
            return multipleSpaces?.stringByReplacingMatches(in: cleaned, options: [], range: cleanedRange, withTemplate: " ") ?? cleaned
        } else {
            let regex = try? NSRegularExpression(pattern: "[\s\t\x0B\f]+", options: [])
            let range = NSRange(location: 0, length: string.utf16.count)
            return regex?.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: " ") ?? string
        }
    }
}
