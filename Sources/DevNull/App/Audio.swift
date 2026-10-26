import AppKit
import AVFoundation
import Foundation
import Observation

/// A recorded voice note, as the API takes it: 16 kHz mono 16-bit WAV, with its 48-bar waveform from 0 to 100.
struct VoiceRecording: Hashable {
    static let bars = 48

    let data: Data
    let waveform: [Int]
    let duration: TimeInterval
}

/// Records voice notes from the microphone, up to a minute, like the web's composer.
@MainActor
@Observable
final class VoiceRecorder {
    nonisolated static let maxDuration: TimeInterval = 60
    nonisolated static let sampleRate = 16000.0

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var meter: Task<Void, Never>?
    private let url = FileManager.default.temporaryDirectory.appending(path: "devnull-voice-\(UUID().uuidString).wav")

    func start() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)

        guard granted else {
            presentAlert("Allow /dev/null to use the microphone in System Settings → Privacy & Security → Microphone to record voice notes.")
            return false
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            return false
        }

        recorder.isMeteringEnabled = true
        recorder.record(forDuration: Self.maxDuration)

        self.recorder = recorder
        isRecording = true
        elapsed = 0
        levels = []

        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let recorder = self.recorder else { return }

                recorder.updateMeters()
                self.elapsed = recorder.currentTime
                self.levels.append(max(0, min(1, (recorder.averagePower(forChannel: 0) + 50) / 50)))

                if !recorder.isRecording {
                    return
                }
            }
        }

        return true
    }

    /// Stops and hands back the recording, or nil when it is too short to send.
    func stop() -> VoiceRecording? {
        meter?.cancel()
        recorder?.stop()
        recorder = nil
        isRecording = false

        defer { try? FileManager.default.removeItem(at: url) }

        return Self.encode(fileAt: url)
    }

    func cancel() {
        meter?.cancel()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        isRecording = false
    }

    /// Reads the recording back and writes it as a plain WAV with nothing but its format and samples, so the server
    /// takes it whatever chunks the recorder added.
    nonisolated static func encode(fileAt url: URL) -> VoiceRecording? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.int16ChannelData?[0],
              file.processingFormat.sampleRate == sampleRate
        else {
            return nil
        }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let duration = Double(samples.count) / sampleRate

        guard duration >= 0.5 else { return nil }

        return VoiceRecording(data: wav(samples), waveform: waveform(samples), duration: duration)
    }

    nonisolated static func wav(_ samples: [Int16]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data()

        func uint32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func uint16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        data.append(Data("RIFF".utf8))
        uint32(36 + dataSize)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        uint32(16)
        uint16(1)
        uint16(1)
        uint32(UInt32(sampleRate))
        uint32(UInt32(sampleRate) * 2)
        uint16(2)
        uint16(16)
        data.append(Data("data".utf8))
        uint32(dataSize)
        samples.forEach { sample in var le = sample.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        return data
    }

    /// The peak of each of 48 slices, scaled so the loudest is 100.
    nonisolated static func waveform(_ samples: [Int16]) -> [Int] {
        let size = max(1, samples.count / VoiceRecording.bars)
        let peaks = (0 ..< VoiceRecording.bars).map { bar -> Double in
            let slice = samples.dropFirst(bar * size).prefix(size)
            return Double(slice.map { abs(Int($0)) }.max() ?? 0)
        }
        let loudest = max(peaks.max() ?? 1, 1)

        return peaks.map { Int(($0 / loudest * 100).rounded()) }
    }
}

/// Plays one voice note at a time like Telegram: it pauses and resumes where it was, seeks by dragging the waveform,
/// plays at 1×, 1.5× or 2× (remembered on this Mac), and moves on to the next voice note of the thread when one ends.
@MainActor
@Observable
final class VoicePlayer {
    static let shared = VoicePlayer()

    private(set) var currentId: String?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var rate: Float = UserDefaults.standard.object(forKey: "voice-rate") as? Float ?? 1

    /// How loud voice notes play on this Mac, from 0 to 1, as the web keeps it per device.
    var volume: Float = UserDefaults.standard.object(forKey: "voice-volume") as? Float ?? 1 {
        didSet {
            player?.volume = volume
            UserDefaults.standard.set(volume, forKey: "voice-volume")
        }
    }

    private var player: AVPlayer?
    private var duration: TimeInterval = 0
    private var upcoming: [MessageVoice] = []
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    func toggle(_ voice: MessageVoice, url: URL, upcoming: [MessageVoice]) {
        guard currentId == voice.id, let player else {
            start(voice, url: url, at: 0, upcoming: upcoming)
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: rate)
            isPlaying = true
        }
    }

    /// Jumps to a point of a voice note, starting it there if another one was playing.
    func seek(_ voice: MessageVoice, url: URL, to fraction: Double, upcoming: [MessageVoice]) {
        let fraction = min(max(fraction, 0), 1)

        guard currentId == voice.id, let player else {
            start(voice, url: url, at: fraction, upcoming: upcoming)
            return
        }

        progress = fraction
        elapsed = fraction * duration
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func cycleRate() {
        rate = switch rate {
        case 1: 1.5
        case 1.5: 2
        default: 1
        }

        UserDefaults.standard.set(rate, forKey: "voice-rate")

        if isPlaying {
            player?.rate = rate
        }
    }

    func stop() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }

        player?.pause()
        player = nil
        observer = nil
        endObserver = nil
        currentId = nil
        isPlaying = false
        progress = 0
        elapsed = 0
    }

    private func start(_ voice: MessageVoice, url: URL, at fraction: Double, upcoming: [MessageVoice]) {
        stop()

        let player = AVPlayer(url: url)
        player.volume = volume
        self.player = player
        self.upcoming = upcoming
        duration = Double(voice.durationMs) / 1000
        currentId = voice.id
        progress = fraction
        elapsed = fraction * duration

        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.duration > 0, self.isPlaying else { return }
                self.elapsed = min(time.seconds, self.duration)
                self.progress = self.elapsed / self.duration
            }
        }

        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playNext() }
        }

        if fraction > 0 {
            player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }

        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    /// The voice note ended: the next one in the thread plays, as in Telegram, or the player rests.
    private func playNext() {
        var queue = upcoming

        while !queue.isEmpty {
            let next = queue.removeFirst()

            if let url = URL(string: next.url), !next.url.isEmpty {
                start(next, url: url, at: 0, upcoming: queue)
                return
            }
        }

        stop()
    }
}

/// The sound the web plays when a message comes in, played for every new message in a remote that isn't muted, the
/// open one included, like MSN chimed for each one. Messages arriving together chime once.
@MainActor
enum Sounds {
    private static var lastPlayedAt = Date.distantPast
    private static var lastPingedAt = Date.distantPast

    private static let message = sound("remote")
    private static let pingSound = sound("ping")

    private static func sound(_ name: String) -> NSSound? {
        let file = Bundle.main.url(forResource: name, withExtension: "mp3")
            ?? URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/\(name).mp3")

        return NSSound(contentsOf: file, byReference: false)
    }

    static func newMessage() {
        guard Preferences.soundEnabled, Date().timeIntervalSince(lastPlayedAt) > 2 else { return }

        lastPlayedAt = Date()
        message?.stop()
        message?.play()

        // Behind other windows, the Dock icon bounces once too.
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// A ping coming in or going out: MSN's ping sound, and the window shakes like MSN's conversation window did.
    static func ping() {
        guard Date().timeIntervalSince(lastPingedAt) > 2 else { return }

        lastPingedAt = Date()

        if Preferences.soundEnabled {
            pingSound?.stop()
            pingSound?.play()
        }

        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              !window.styleMask.contains(.fullScreen)
        else { return }

        let origin = window.frame.origin
        let path = CGMutablePath()
        path.move(to: origin)
        for offset in [-10.0, 10, -8, 8, -5, 5, 0] {
            path.addLine(to: CGPoint(x: origin.x + offset, y: origin.y))
        }

        let shake = CAKeyframeAnimation()
        shake.path = path
        shake.duration = 0.5
        window.animations = ["frameOrigin": shake]
        window.animator().setFrameOrigin(origin)
    }
}
