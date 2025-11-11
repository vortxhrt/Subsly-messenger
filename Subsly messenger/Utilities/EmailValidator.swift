import Foundation

enum EmailValidator {
    private static let detector: NSDataDetector? = {
        return try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    static func isValid(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 254 else { return false }
        guard let detector else { return false }

        let nsRange = NSRange(location: 0, length: trimmed.utf16.count)
        let matches = detector.matches(in: trimmed, options: [], range: nsRange)
        guard matches.count == 1, let result = matches.first else { return false }
        guard result.range == nsRange, result.url?.scheme == "mailto" else { return false }
        return true
    }
}
