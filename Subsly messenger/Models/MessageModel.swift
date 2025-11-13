import Foundation

struct MessageModel: Identifiable, Hashable {
    let id: String          // non-optional so ForEach never sees an optional
    let senderId: String
    let text: String
    let createdAt: Date?
}

extension MessageModel {
    /// Determine whether the payload likely represents a voice-note recording.
    static func isLikelyVoiceNotePayload(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("voice_note") || lower.contains("voicenote") || lower.contains("voice-note") {
            return true
        }
        if lower.contains("/voice") || lower.contains("/audio") { return true }
        let audioExtensions = [".m4a", ".aac", ".mp3", ".wav", ".caf"]
        return audioExtensions.contains { lower.contains($0) }
    }

    /// Collapse whitespace and limit payload length for diagnostics.
    static func logSnippet(from text: String, limit: Int = 160) -> String {
        guard !text.isEmpty else { return "" }
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= limit { return collapsed }
        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<index]) + "…"
    }

    /// A reusable ISO-8601 formatter with fractional seconds for log output.
    private static let logDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Human readable representation that is safe to print in debug builds.
    var logSummary: String {
        let snippet = Self.logSnippet(from: text)
        let timestamp = createdAt.map { Self.logDateFormatter.string(from: $0) } ?? "nil"
        let voice = Self.isLikelyVoiceNotePayload(text) ? "voice" : "text"
        return "id=\(id) sender=\(senderId) createdAt=\(timestamp) payloadType=\(voice) snippet=\"\(snippet)\""
    }
}
