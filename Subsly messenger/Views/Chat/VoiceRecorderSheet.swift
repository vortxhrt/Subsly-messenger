import SwiftUI
import AVFoundation

struct VoiceRecorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onComplete: (PendingAttachment) -> Void

    @StateObject private var model = VoiceRecorderViewModel()
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Text(titleText)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)

                    Text(subtitleText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(timeDisplay)
                    .font(.system(size: 48, weight: .medium, design: .monospaced))
                    .foregroundStyle(model.state == .recording ? Color.red : Color.primary)
                    .padding(.vertical, 8)

                controls

                if let error = model.errorMessage ?? exportError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Voice Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        handleSend()
                    }
                    .disabled(!model.canSend)
                }
            }
        }
        .interactiveDismissDisabled(model.state == .recording)
        .onDisappear {
            model.cleanup()
        }
    }

    private var titleText: String {
        switch model.state {
        case .idle:
            return "Record a voice message"
        case .recording:
            return "Recording"
        case .reviewing:
            return model.isPlayingBack ? "Playing back" : "Review your message"
        }
    }

    private var subtitleText: String {
        switch model.state {
        case .idle:
            return "Tap the record button to start."
        case .recording:
            return "Tap stop when you’re finished."
        case .reviewing:
            return "Play it back or record again before sending."
        }
    }

    private var timeDisplay: String {
        switch model.state {
        case .idle:
            return VoiceRecorderViewModel.format(model.elapsed)
        case .recording:
            return VoiceRecorderViewModel.format(model.elapsed)
        case .reviewing:
            let current = model.isPlayingBack ? model.playbackPosition : model.recordingDuration
            return VoiceRecorderViewModel.format(current)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .idle:
            RecordButton(isRecording: false) {
                Task { await model.startRecording() }
            }

        case .recording:
            VStack(spacing: 16) {
                RecordButton(isRecording: true) {
                    model.stopRecording()
                }
                Button("Cancel recording", role: .destructive) {
                    model.reset()
                }
            }

        case .reviewing:
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Button {
                            model.togglePlayback()
                        } label: {
                            Image(systemName: model.isPlayingBack ? "pause.fill" : "play.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .frame(width: 64, height: 64)
                                .background(Circle().fill(Color.accentColor.opacity(0.2)))
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.isPlayingBack ? "Playing" : "Ready to send")
                                .font(.headline)
                            Text("\(VoiceRecorderViewModel.format(model.playbackPosition)) / \(VoiceRecorderViewModel.format(model.recordingDuration))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    ProgressView(value: model.playbackProgress)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                }

                Button("Record again", role: .destructive) {
                    model.reset()
                }
            }
        }
    }

    private func handleSend() {
        exportError = nil
        do {
            let attachment = try model.exportAttachment()
            onComplete(attachment)
            dismiss()
        } catch {
            exportError = error.localizedDescription
        }
    }
}

private struct RecordButton: View {
    var isRecording: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? Color.red : Color.accentColor)
                    .frame(width: 88, height: 88)

                if isRecording {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 26, height: 26)
                        .cornerRadius(6)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 32, height: 32)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

@MainActor
final class VoiceRecorderViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum State {
        case idle
        case recording
        case reviewing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var playbackPosition: TimeInterval = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var isPlayingBack = false
    @Published var errorMessage: String?

    var canSend: Bool {
        state == .reviewing && recordingDuration >= minimumDuration
    }

    var playbackProgress: Double {
        guard recordingDuration > 0 else { return 0 }
        return max(0, min(1, playbackPosition / recordingDuration))
    }

    private let minimumDuration: TimeInterval = 0.5
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var recordTimer: Timer?
    private var playbackTimer: Timer?

    func startRecording() async {
        guard state != .recording else { return }
        errorMessage = nil
        stopPlayback()
        cleanupRecordingFile()

        let session = AVAudioSession.sharedInstance()
        let granted = await Self.requestPermission()
        guard granted else {
            errorMessage = "Microphone access is required to record voice messages."
            return
        }

        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-temp-\(UUID().uuidString).m4a")
            recordingURL = url

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.prepareToRecord()
            guard recorder?.record() == true else {
                throw NSError(domain: "VoiceRecorder", code: -1)
            }

            state = .recording
            elapsed = 0
            playbackPosition = 0
            recordingDuration = 0
            startRecordTimer()
        } catch {
            cleanupRecordingFile()
            recorder?.stop()
            recorder = nil
            errorMessage = "We couldn’t start recording. Please try again."
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        recorder?.stop()
        recordingDuration = recorder?.currentTime ?? elapsed
        elapsed = recordingDuration
        stopRecordTimer()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        if recordingDuration < minimumDuration {
            errorMessage = "Recording was too short. Try again."
            cleanupRecordingFile()
            state = .idle
            recordingDuration = 0
            elapsed = 0
            return
        }

        playbackPosition = 0
        state = .reviewing
    }

    func togglePlayback() {
        guard state == .reviewing else { return }
        if isPlayingBack {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    func reset() {
        stopPlayback()
        stopRecordTimer()
        recorder?.stop()
        recorder = nil
        cleanupRecordingFile()
        state = .idle
        elapsed = 0
        playbackPosition = 0
        recordingDuration = 0
        errorMessage = nil
    }

    func cleanup() {
        stopPlayback()
        stopRecordTimer()
        recorder?.stop()
        recorder = nil
        cleanupRecordingFile()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func exportAttachment() throws -> PendingAttachment {
        guard state == .reviewing, let sourceURL = recordingURL else {
            throw RecorderError.noRecording
        }

        stopPlayback()

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-msg-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return PendingAttachment(kind: .audio(fileURL: destination, duration: recordingDuration))
    }

    private func startPlayback() {
        guard let url = recordingURL else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: [])

            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()

            self.player = player
            isPlayingBack = true
            startPlaybackTimer()
        } catch {
            errorMessage = "We couldn’t play back the recording."
            isPlayingBack = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlayingBack = false
        stopPlaybackTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func cleanupRecordingFile() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    private func startRecordTimer() {
        stopRecordTimer()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed += 0.1
        }
    }

    private func stopRecordTimer() {
        recordTimer?.invalidate()
        recordTimer = nil
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.playbackPosition = player.currentTime
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        if !isPlayingBack {
            playbackPosition = min(playbackPosition, recordingDuration)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlayingBack = false
        playbackPosition = recordingDuration
        stopPlaybackTimer()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Helpers

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func format(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(round(value)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    enum RecorderError: LocalizedError {
        case noRecording

        var errorDescription: String? {
            switch self {
            case .noRecording:
                return "You need to record a message before sending."
            }
        }
    }
}
