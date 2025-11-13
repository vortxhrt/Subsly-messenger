import Foundation

struct MessageModel: Identifiable, Hashable {
    let id: String          // non-optional so ForEach never sees an optional
    let senderId: String
    let text: String
    let createdAt: Date?
    let audioURL: URL?
    let audioDuration: TimeInterval?
    let waveform: [Double]

    init(id: String,
         senderId: String,
         text: String,
         createdAt: Date?,
         audioURL: URL? = nil,
         audioDuration: TimeInterval? = nil,
         waveform: [Double] = []) {
        self.id = id
        self.senderId = senderId
        self.text = text
        self.createdAt = createdAt
        self.audioURL = audioURL
        self.audioDuration = audioDuration
        self.waveform = waveform
    }

    var isAudioMessage: Bool { audioURL != nil }
    var previewText: String {
        if isAudioMessage { return "Voice message" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Message" : trimmed
    }
}
