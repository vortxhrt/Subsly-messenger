import Foundation

struct MessageModel: Identifiable, Hashable {
    let id: String          // non-optional so ForEach never sees an optional
    let senderId: String
    let text: String
    let createdAt: Date?
}

extension MessageModel {
    struct VoiceNotePayload: Hashable {
        let url: URL
        let duration: TimeInterval?
        let transcript: String?
    }

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

    static func voiceNotePayload(from text: String) -> VoiceNotePayload? {
        guard isLikelyVoiceNotePayload(text) else { return nil }

        if let data = text.data(using: .utf8) {
            if let object = try? JSONSerialization.jsonObject(with: data) {
                if let payload = VoiceNotePayloadExtractor.payload(from: object) {
                    return payload
                }
            }
        }

        if let url = VoiceNotePayloadExtractor.extractFirstURL(from: text) {
            let duration = VoiceNotePayloadExtractor.extractDuration(from: text)
            let transcript = VoiceNotePayloadExtractor.extractTranscript(from: text)
            return VoiceNotePayload(url: url, duration: duration, transcript: transcript)
        }

        return nil
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

private enum VoiceNotePayloadExtractor {
    static func payload(from object: Any) -> MessageModel.VoiceNotePayload? {
        if let dict = object as? [String: Any] {
            if let payload = payloadFromDictionary(dict) {
                return payload
            }
            for value in dict.values {
                if let payload = payload(from: value) {
                    return payload
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let payload = payload(from: value) {
                    return payload
                }
            }
        } else if let string = object as? String {
            if let url = extractFirstURL(from: string) {
                let duration = extractDuration(from: string)
                let transcript = extractTranscript(from: string)
                return MessageModel.VoiceNotePayload(url: url, duration: duration, transcript: transcript)
            }
        }
        return nil
    }

    private static func payloadFromDictionary(_ dict: [String: Any]) -> MessageModel.VoiceNotePayload? {
        if let urlString = firstURLString(in: dict), let url = URL(string: urlString) {
            let duration = durationValue(in: dict)
            let transcript = transcriptValue(in: dict)
            return MessageModel.VoiceNotePayload(url: url, duration: duration, transcript: transcript)
        }

        let nestedKeys = ["voice_note", "voiceNote", "voicenote", "voice-note", "voice", "audio", "data", "payload"]
        for key in nestedKeys {
            if let nested = dict[key], let payload = payload(from: nested) {
                return payload
            }
        }

        return nil
    }

    private static func firstURLString(in dict: [String: Any]) -> String? {
        let candidateKeys = [
            "url",
            "audioUrl",
            "audioURL",
            "audio",
            "fileUrl",
            "fileURL",
            "downloadURL",
            "downloadUrl",
            "href",
            "source",
            "mediaUrl",
            "mediaURL",
            "link"
        ]
        for key in candidateKeys {
            if let value = dict[key] as? String, let trimmed = trimmedURLString(value) {
                return trimmed
            }
        }
        return nil
    }

    private static func trimmedURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func durationValue(in dict: [String: Any]) -> TimeInterval? {
        let numberKeys = ["duration", "length", "seconds", "time", "audioDuration", "voiceDuration"]
        for key in numberKeys {
            if let value = dict[key] as? NSNumber { return value.doubleValue }
            if let value = dict[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }

    private static func transcriptValue(in dict: [String: Any]) -> String? {
        let textKeys = ["transcript", "transcription", "text", "caption", "summary"]
        for key in textKeys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    static func extractFirstURL(from text: String) -> URL? {
        let pattern = #"(https?|ftp)://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard let swiftRange = Range(match.range, in: text) else { return nil }
        let raw = String(text[swiftRange])
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return URL(string: trimmed)
    }

    static func extractDuration(from text: String) -> TimeInterval? {
        let patterns = [
            #"\"duration\"\s*[:=]\s*(\d+(?:\.\d+)?)"#,
            #"\"length\"\s*[:=]\s*(\d+(?:\.\d+)?)"#,
            #"\"seconds\"\s*[:=]\s*(\d+(?:\.\d+)?)"#,
            #"\"time\"\s*[:=]\s*(\d+(?:\.\d+)?)"#
        ]
        for pattern in patterns {
            if let value = firstCapture(in: text, pattern: pattern), let number = Double(value) {
                return number
            }
        }
        return nil
    }

    static func extractTranscript(from text: String) -> String? {
        let patterns = [
            #"\"transcript\"\s*[:=]\s*\"([^\"]+)\""#,
            #"\"transcription\"\s*[:=]\s*\"([^\"]+)\""#,
            #"\"caption\"\s*[:=]\s*\"([^\"]+)\""#
        ]
        for pattern in patterns {
            if let match = firstCapture(in: text, pattern: pattern) {
                let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard match.numberOfRanges > 1 else { return nil }
        let captureRange = match.range(at: 1)
        guard let swiftRange = Range(captureRange, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
