import Foundation
import OSLog

enum FrontEndLog {
    static let subsystem = "com.subsly.messenger"

    static let chat = Logger(subsystem: subsystem, category: "Chat")
    static let voice = Logger(subsystem: subsystem, category: "VoiceNote")
    static let playback = Logger(subsystem: subsystem, category: "Playback")
    static let receipts = Logger(subsystem: subsystem, category: "Receipts")
    static let typing = Logger(subsystem: subsystem, category: "Typing")
}

#if DEBUG
extension FrontEndLog {
    /// Collapse whitespace and truncate the payload for log safety.
    static func makeSnippet(from text: String, limit: Int = 160) -> String {
        guard !text.isEmpty else { return "" }
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= limit { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<endIndex]) + "…"
    }
}
#endif
