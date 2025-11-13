import Foundation
import Combine
import AVFoundation
import CryptoKit

@MainActor
final class VoiceMessagePlaybackController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.playing, .playing), (.paused, .paused):
                return true
            case let (.failed(le), .failed(re)):
                return le == re
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var isLoading: Bool { state == .loading }
    var isPlaying: Bool { state == .playing }
    var isPaused: Bool { state == .paused }
    var errorMessage: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func togglePlayback(for url: URL, cacheKey: String, expectedDuration: TimeInterval?) {
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .loading:
            break
        case .idle, .failed:
            Task { [weak self] in
                guard let self else { return }
                await self.startPlayback(url: url, cacheKey: cacheKey, expectedDuration: expectedDuration)
            }
        }
    }

    func pause() {
        guard let player else { return }
        player.pause()
        stopTimer()
        state = .paused
    }

    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        currentTime = 0
        state = .idle
        deactivateSession()
    }

    private func resume() {
        guard let player else { return }
        do {
            try configureSession()
            player.play()
            startTimer()
            state = .playing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func startPlayback(url: URL, cacheKey: String, expectedDuration: TimeInterval?) async {
        stopTimer()
        currentTime = 0
        state = .loading
        do {
            let localURL = try await VoiceMessageFileCache.shared.localURL(for: url, key: cacheKey)
            try configureSession()
            let player = try AVAudioPlayer(contentsOf: localURL)
            player.delegate = self
            player.prepareToPlay()
            player.currentTime = 0
            self.duration = max(expectedDuration ?? 0, player.duration)
            self.player = player
            player.play()
            startTimer()
            state = .playing
        } catch {
            state = .failed(error.localizedDescription)
            self.player?.stop()
            self.player = nil
            deactivateSession()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(handleTimer(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleTimer(_ timer: Timer) {
        guard let player else { return }
        currentTime = player.currentTime
        if player.duration > 0 {
            duration = max(duration, player.duration)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
    }

    private func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    var displayDuration: String {
        formatTime(duration)
    }

    var displayCurrentTime: String {
        formatTime(currentTime)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN else { return "0:00" }
        let total = Int(round(time))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    deinit {
        stopTimer()
        player?.stop()
        deactivateSession()
    }
}

extension VoiceMessagePlaybackController: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTimer()
        currentTime = duration
        state = .idle
        self.player = nil
        deactivateSession()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopTimer()
        state = .failed(error?.localizedDescription ?? "Playback error")
        self.player = nil
        deactivateSession()
    }
}

private actor VoiceMessageFileCache {
    static let shared = VoiceMessageFileCache()

    private var cache: [String: URL] = [:]
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("voice-messages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        directory = dir
    }

    func localURL(for remoteURL: URL, key: String) async throws -> URL {
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
        let fileName = cacheFileName(for: key, remoteURL: remoteURL)
        let destination = directory.appendingPathComponent(fileName, isDirectory: false)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tempURL, to: destination)
        cache[key] = destination
        return destination
    }

    private func cacheFileName(for key: String, remoteURL: URL) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let ext = remoteURL.pathExtension.isEmpty ? "m4a" : remoteURL.pathExtension
        return "\(hash).\(ext)"
    }
}
