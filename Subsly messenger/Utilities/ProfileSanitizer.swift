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
            return collapseWhitespacePreservingNewlines(in: string)
        } else {
            return collapseWhitespaceReplacingNewlines(in: string)
        }
    }

    private static func collapseWhitespacePreservingNewlines(in string: String) -> String {
        let spaceScalar = UnicodeScalar(" ")!
        let newlineScalar = "\n".unicodeScalars.first!
        let newlineSet = CharacterSet.newlines
        let verticalWhitespace = CharacterSet(charactersIn: "\t\u{000B}\u{000C}")

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(string.unicodeScalars.count)

        var justInsertedSpace = false

        for scalar in string.unicodeScalars {
            if newlineSet.contains(scalar) {
                scalars.append(newlineScalar)
                justInsertedSpace = false
                continue
            }

            if verticalWhitespace.contains(scalar) {
                continue
            }

            if CharacterSet.whitespaces.contains(scalar) {
                if !justInsertedSpace {
                    scalars.append(spaceScalar)
                    justInsertedSpace = true
                }
                continue
            }

            scalars.append(scalar)
            justInsertedSpace = false
        }

        return String(scalars)
    }

    private static func collapseWhitespaceReplacingNewlines(in string: String) -> String {
        let spaceScalar = UnicodeScalar(" ")!
        let collapseSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{000B}\u{000C}"))

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(string.unicodeScalars.count)

        var justInsertedSpace = false

        for scalar in string.unicodeScalars {
            if collapseSet.contains(scalar) {
                if !justInsertedSpace {
                    scalars.append(spaceScalar)
                    justInsertedSpace = true
                }
            } else {
                scalars.append(scalar)
                justInsertedSpace = false
            }
        }

        return String(scalars)
    }
}
