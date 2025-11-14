import SwiftUI
import AVFoundation

struct VoiceNoteBubbleView: View {
    let payload: MessageModel.VoiceNotePayload
    let isMe: Bool

    @State private var player: AVPlayer?
    @State private var isPreparing = false
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval?
    @State private var pendingPlay = false
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var failureObserver: NSObjectProtocol?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                playButton
                VStack(alignment: .leading, spacing: 6) {
                    if let transcript = payload.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.subheadline)
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(2)
                            .accessibilityLabel("Transcription: \(transcript)")
                    }

                    progressView

                    Text(timeDescription)
                        .font(.caption2)
                        .foregroundStyle(secondaryTextColor)
                        .accessibilityLabel(accessibilityTimeDescription)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear(perform: configurePlayerIfNeeded)
        .onDisappear(perform: teardownPlayer)
        .alert("Playback Unavailable", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .accessibilityElement(children: .combine)
    }

    private var playButton: some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .bold))
                .frame(width: 40, height: 40)
                .foregroundStyle(buttonIconColor)
                .background(
                    Circle()
                        .fill(buttonBackgroundColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(isPreparing)
        .accessibilityLabel(isPlaying ? "Pause voice note" : "Play voice note")
        .accessibilityHint("Double-tap to \(isPlaying ? "pause" : "play") the recording")
    }

    private var progressView: some View {
        Group {
            if let progress = progressValue {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(progressTintColor)
                    .accessibilityLabel("Playback progress")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(progressTintColor)
                    .accessibilityLabel("Preparing audio")
            }
        }
    }

    private var buttonIconColor: Color { Color.accentColor }

    private var buttonBackgroundColor: Color {
        isMe ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.18)
    }

    private var primaryTextColor: Color {
        isMe ? Color.white : Color.primary
    }

    private var secondaryTextColor: Color {
        isMe ? Color.white.opacity(0.8) : Color.secondary
    }

    private var progressTintColor: Color {
        isMe ? Color.white : Color.accentColor
    }

    private var totalDuration: TimeInterval? {
        if let duration, duration > 0 { return duration }
        if let payloadDuration = payload.duration, payloadDuration > 0 { return payloadDuration }
        if let time = player?.currentItem?.duration.asSeconds, time > 0 { return time }
        return nil
    }

    private var progressValue: Double? {
        guard let total = totalDuration, total > 0 else { return nil }
        let ratio = max(0, min(1, currentTime / total))
        return ratio.isFinite ? ratio : nil
    }

    private var timeDescription: String {
        let current = format(time: currentTime)
        guard let total = totalDuration else { return current }
        return "\(current) / \(format(time: total))"
    }

    private var accessibilityTimeDescription: String {
        let current = format(time: currentTime)
        guard let total = totalDuration else {
            return "Playback position \(current)"
        }
        return "Playback position \(current) of \(format(time: total))"
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        if let player {
            beginPlaying(player)
        } else {
            pendingPlay = true
            configurePlayerIfNeeded(force: true)
        }
    }

    private func stopPlayback() {
        guard let player else { return }
        player.pause()
        isPlaying = false
    }

    private func configurePlayerIfNeeded(force: Bool = false) {
        guard force || player == nil else { return }
        isPreparing = true

        let asset = AVURLAsset(url: payload.url)
        let requiredKeys = ["playable", "duration"]

        asset.loadValuesAsynchronously(forKeys: requiredKeys) {
            var error: NSError?
            for key in requiredKeys {
                let status = asset.statusOfValue(forKey: key, error: &error)
                if status == .failed || status == .cancelled {
                    DispatchQueue.main.async {
                        present(error: error)
                    }
                    return
                }
            }

            if asset.hasProtectedContent {
                DispatchQueue.main.async {
                    present(error: NSError(domain: "VoiceNote", code: -1, userInfo: [NSLocalizedDescriptionKey: "This recording is protected and cannot be played back."]))
                }
                return
            }

            let item = AVPlayerItem(asset: asset)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.automaticallyWaitsToMinimizeStalling = true

            DispatchQueue.main.async {
                self.replacePlayer(with: newPlayer)
                self.isPreparing = false
                if let assetDuration = item.asset.duration.asSeconds, assetDuration > 0 {
                    self.duration = assetDuration
                }
                if self.pendingPlay {
                    self.beginPlaying(newPlayer)
                }
            }
        }
    }

    private func replacePlayer(with newPlayer: AVPlayer) {
        removeCurrentPlayer(resetPending: false)
        player = newPlayer
        addObservers(to: newPlayer)
    }

    private func beginPlaying(_ player: AVPlayer) {
        prepareAudioSession()
        if let total = totalDuration, total > 0, currentTime >= total - 0.1 {
            player.seek(to: .zero)
            currentTime = 0
        }
        player.play()
        isPlaying = true
        pendingPlay = false
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowAirPlay]
            if session.category != .playAndRecord || session.mode != .voiceChat {
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            }
            try session.setActive(true, options: [])
            if session.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) {
                try session.overrideOutputAudioPort(.speaker)
            }
        } catch {
            present(error: error as NSError)
        }
    }

    private func addObservers(to player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            self.currentTime = seconds
            if self.duration == nil, let total = player.currentItem?.duration.asSeconds, total > 0 {
                self.duration = total
            }
        }

        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                self.player?.seek(to: .zero)
                self.currentTime = 0
                self.isPlaying = false
            }

            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { notification in
                let nsError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self.present(error: nsError ?? NSError(domain: "VoiceNote", code: -2, userInfo: [NSLocalizedDescriptionKey: "The recording could not be played. "]))
            }
        }
    }

    private func teardownPlayer() {
        removeCurrentPlayer(resetPending: true)
    }

    private func removeCurrentPlayer(resetPending: Bool) {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = failureObserver {
            NotificationCenter.default.removeObserver(observer)
            failureObserver = nil
        }
        player?.pause()
        player = nil
        isPlaying = false
        if resetPending {
            pendingPlay = false
        }
    }

    private func present(error: NSError?) {
        self.isPreparing = false
        self.isPlaying = false
        self.pendingPlay = false
        if let error = error {
            self.errorMessage = error.localizedDescription
        } else {
            self.errorMessage = "An unknown error occurred while trying to play this recording."
        }
    }

    private func format(time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(round(time))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension CMTime {
    var asSeconds: TimeInterval? {
        guard isNumeric else { return nil }
        let value = CMTimeGetSeconds(self)
        return value.isFinite ? value : nil
    }
}
