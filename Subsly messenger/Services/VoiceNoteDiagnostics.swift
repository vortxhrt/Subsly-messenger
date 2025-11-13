import Foundation
import os.log

struct VoiceNoteMetadata: Hashable, Sendable {
    let rawRepresentation: String
    let audioURL: String?
    let localReference: String?
    let durationSeconds: Double?
    let waveformSampleCount: Int?
    let fileSizeBytes: Double?
    let mimeType: String?
    let unrecognizedKeys: [String]
    let sourceDescription: String

    init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let jsonMetadata = VoiceNoteMetadata.parseJSONPayload(trimmed) {
            self = jsonMetadata
            return
        }

        guard let simpleMetadata = VoiceNoteMetadata.parseSimpleStringPayload(trimmed) else {
            return nil
        }
        self = simpleMetadata
    }

    private init(rawRepresentation: String,
                 audioURL: String?,
                 localReference: String?,
                 durationSeconds: Double?,
                 waveformSampleCount: Int?,
                 fileSizeBytes: Double?,
                 mimeType: String?,
                 unrecognizedKeys: [String],
                 sourceDescription: String) {
        self.rawRepresentation = rawRepresentation
        self.audioURL = audioURL
        self.localReference = localReference
        self.durationSeconds = durationSeconds
        self.waveformSampleCount = waveformSampleCount
        self.fileSizeBytes = fileSizeBytes
        self.mimeType = mimeType
        self.unrecognizedKeys = unrecognizedKeys
        self.sourceDescription = sourceDescription
    }

    // MARK: - Derived helpers

    var issues: [String] {
        var items: [String] = []
        if let audioURL, audioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append("empty_audio_url")
        } else if audioURL == nil {
            items.append("missing_audio_url")
        }
        if let durationSeconds {
            if durationSeconds <= 0 {
                items.append("duration_non_positive")
            }
        } else {
            items.append("missing_duration")
        }
        if let waveformSampleCount {
            if waveformSampleCount == 0 {
                items.append("waveform_empty")
            }
        } else {
            items.append("missing_waveform")
        }
        if let fileSizeBytes {
            if fileSizeBytes <= 0 {
                items.append("filesize_non_positive")
            }
        } else {
            items.append("missing_filesize")
        }
        return items
    }

    var metadataSummary: String {
        var parts: [String] = []
        parts.append("source=\(sourceDescription)")
        if let audioURL { parts.append("remote=\(audioURL)") }
        if let localReference { parts.append("local=\(localReference)") }
        if let durationSeconds {
            parts.append(String(format: "duration=%.3fs", durationSeconds))
        }
        if let waveformSampleCount {
            parts.append("waveformSamples=\(waveformSampleCount)")
        }
        if let fileSizeBytes {
            parts.append("size=\(VoiceNoteMetadata.format(bytes: fileSizeBytes))")
        }
        if let mimeType { parts.append("codec=\(mimeType)") }
        if !issues.isEmpty { parts.append("issues=\(issues.joined(separator: ","))") }
        if !unrecognizedKeys.isEmpty {
            parts.append("extraKeys=\(unrecognizedKeys.joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    var rawPreview: String {
        if rawRepresentation.count <= 400 {
            return rawRepresentation
        }
        let prefix = rawRepresentation.prefix(400)
        return "\(prefix)…(+\(rawRepresentation.count - 400) chars)"
    }

    // MARK: - Parsing helpers

    private static func parseJSONPayload(_ text: String) -> VoiceNoteMetadata? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dictionary = json as? [String: Any] else { return nil }

        let lowered = Self.lowercasedDictionary(dictionary)
        guard Self.looksLikeVoiceNotePayload(originalKeys: dictionary.keys, lowered: lowered) else { return nil }

        let remoteURL = Self.stringValue(for: remoteURLKeys, in: lowered)
        let localRef = Self.stringValue(for: localReferenceKeys, in: lowered)
        let duration = Self.doubleValue(for: durationKeys, in: lowered)
        let waveform = Self.waveformSampleCount(from: lowered)
        let fileSize = Self.doubleValue(for: fileSizeKeys, in: lowered)
        let mime = Self.stringValue(for: mimeTypeKeys, in: lowered)
        let unrecognized = dictionary.keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !recognizedKeys.contains($0.lowercased()) }
            .sorted()

        let compactJSON: String
        if JSONSerialization.isValidJSONObject(dictionary),
           let compactData = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
           let compactString = String(data: compactData, encoding: .utf8) {
            compactJSON = compactString
        } else {
            compactJSON = text
        }

        return VoiceNoteMetadata(
            rawRepresentation: compactJSON,
            audioURL: remoteURL,
            localReference: localRef,
            durationSeconds: duration,
            waveformSampleCount: waveform,
            fileSizeBytes: fileSize,
            mimeType: mime,
            unrecognizedKeys: unrecognized,
            sourceDescription: "json"
        )
    }

    private static func parseSimpleStringPayload(_ text: String) -> VoiceNoteMetadata? {
        let lower = text.lowercased()
        let hasAudioExtension = audioExtensions.contains { lower.contains($0) }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        let match = detector?.firstMatch(in: text, options: [], range: fullRange)
        let detectedURL = match.flatMap { Range($0.range, in: text).map { String(text[$0]) } }
        let detectedQualifies: Bool
        if let detectedURL {
            let lowerDetected = detectedURL.lowercased()
            detectedQualifies = audioExtensions.contains { lowerDetected.contains($0) }
        } else {
            detectedQualifies = false
        }

        guard hasAudioExtension || detectedQualifies else { return nil }

        let inferredURL: String?
        if let detectedURL {
            inferredURL = detectedURL
        } else if hasAudioExtension {
            inferredURL = text
        } else {
            inferredURL = nil
        }

        return VoiceNoteMetadata(
            rawRepresentation: text,
            audioURL: inferredURL,
            localReference: nil,
            durationSeconds: nil,
            waveformSampleCount: nil,
            fileSizeBytes: nil,
            mimeType: nil,
            unrecognizedKeys: [],
            sourceDescription: "text"
        )
    }

    // MARK: - Low-level extraction helpers

    private static func lowercasedDictionary(_ input: [String: Any]) -> [String: Any] {
        var lowered: [String: Any] = [:]
        for (key, value) in input {
            let lower = key.lowercased()
            if lowered[lower] == nil {
                lowered[lower] = value
            }
        }
        return lowered
    }

    private static func stringValue(for keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            let lower = key.lowercased()
            if let string = dictionary[lower] as? String, !string.isEmpty {
                return string
            }
            if let number = dictionary[lower] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func doubleValue(for keys: [String], in dictionary: [String: Any]) -> Double? {
        for key in keys {
            let lower = key.lowercased()
            if let number = dictionary[lower] as? NSNumber {
                return number.doubleValue
            }
            if let string = dictionary[lower] as? String,
               let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }

    private static func waveformSampleCount(from dictionary: [String: Any]) -> Int? {
        for key in waveformKeys {
            let lower = key.lowercased()
            guard let value = dictionary[lower] else { continue }
            if let array = value as? [Any] {
                return array.count
            }
            if let nestedDict = value as? [String: Any] {
                let loweredNested = lowercasedDictionary(nestedDict)
                if let nested = loweredNested["samples"] as? [Any] {
                    return nested.count
                }
                if let nested = loweredNested["points"] as? [Any] {
                    return nested.count
                }
            }
            if let string = value as? String {
                let separators = CharacterSet(charactersIn: ", ")
                let components = string.components(separatedBy: separators)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if components.count > 1 {
                    return components.count
                }
            }
        }
        return nil
    }

    private static func looksLikeVoiceNotePayload(originalKeys: Dictionary<String, Any>.Keys,
                                                   lowered: [String: Any]) -> Bool {
        if let typeValue = stringValue(for: typeKeys, in: lowered)?.lowercased() {
            if typeValue.contains("voice") || typeValue.contains("audio") {
                return true
            }
        }
        for key in originalKeys {
            let lower = key.lowercased()
            if lower.contains("voice") || lower.contains("audio") {
                return true
            }
        }
        if lowered["waveform"] != nil || lowered["samples"] != nil || lowered["amplitudes"] != nil {
            return true
        }
        if lowered["duration"] != nil || lowered["durationseconds"] != nil {
            return true
        }
        if lowered["audiourl"] != nil || lowered["voiceurl"] != nil || lowered["voicenoteurl"] != nil {
            return true
        }
        return false
    }

    private static func format(bytes: Double) -> String {
        guard bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = bytes
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.2f %@", value, units[index])
    }

    private static let remoteURLKeys: [String] = [
        "audiourl", "audio_url", "audiourl", "url", "remoteurl", "fileurl", "file_url",
        "voiceurl", "voicenoteurl", "downloadurl", "storageurl", "playbackurl"
    ]

    private static let localReferenceKeys: [String] = [
        "localurl", "local_url", "localfile", "filepath", "file_path", "tempurl", "cachepath"
    ]

    private static let durationKeys: [String] = [
        "duration", "durationseconds", "audioDuration", "voiceduration", "length", "lengthseconds"
    ]

    private static let waveformKeys: [String] = [
        "waveform", "waveformsamples", "samples", "amplitudes", "levels"
    ]

    private static let fileSizeKeys: [String] = [
        "filesize", "size", "bytes", "filebytes", "contentlength"
    ]

    private static let mimeTypeKeys: [String] = [
        "mimetype", "contenttype", "codec", "format", "uti"
    ]

    private static let typeKeys: [String] = [
        "type", "messageType", "kind", "category", "messagetype", "contentType"
    ]

    private static let recognizedKeys: Set<String> = {
        let collections: [[String]] = [
            remoteURLKeys, localReferenceKeys, durationKeys, waveformKeys, fileSizeKeys, mimeTypeKeys, typeKeys,
            ["metadata", "data", "payload", "waveformdata", "waveform_data", "id", "senderid", "sender_id"]
        ]
        return Set(collections.flatMap { $0.map { $0.lowercased() } })
    }()

    private static let audioExtensions: [String] = [
        ".m4a", ".aac", ".mp3", ".wav", ".caf", ".ogg", ".opus", ".mp4", ".3gp"
    ]
}

enum VoiceNoteDiagnostics {
    enum Stage: String {
        case outgoingPrepared = "outgoing_prepared"
        case sendRequested = "send_requested"
        case sendSucceeded = "send_succeeded"
        case sendFailed = "send_failed"
        case snapshotFirstSeen = "snapshot_first_seen"
        case snapshotUpdated = "snapshot_updated"
        case playbackTapped = "playback_tapped"
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SubslyMessenger",
        category: "VoiceNote"
    )

    static func log(stage: Stage,
                    messageId: String?,
                    metadata: VoiceNoteMetadata,
                    context: [String: String] = [:],
                    error: String? = nil) {
        var components: [String] = []
        components.append("stage=\(stage.rawValue)")
        if let messageId { components.append("messageId=\(messageId)") }
        if !context.isEmpty {
            let contextPairs = context
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: " ")
            components.append(contextPairs)
        }
        components.append(metadata.metadataSummary)
        components.append("raw=\(metadata.rawPreview)")
        if let error, !error.isEmpty {
            components.append("error=\(error)")
        }
        let message = components.joined(separator: " | ")
        logger.log("\(message, privacy: .public)")
        print("🔊 VoiceNote \(message)")
    }
}
