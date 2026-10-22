import AVFoundation

/// Every activation and deactivation of the audio session runs here, one after another and in the order asked: a
/// session ending just as Listen starts (or the other way round) can't switch the new one's audio off.
private let audioSessionQueue = DispatchQueue(label: "hanaseru.audio-session", qos: .userInitiated)

/// Owns the app's audio session for a hands-free session (spec §61), and for Listen.
///
/// `.playAndRecord` with Bluetooth enabled lets AirPods carry both directions; `.duckOthers` lowers
/// music rather than stopping it. Haptics are explicitly allowed during recording — iOS silences them otherwise.
@MainActor
final class AudioSessionController {
    /// An interruption (a phone call, Siri, an alarm) began, or ended — `shouldResume` says iOS expects
    /// the app to carry on by itself.
    enum Interruption {
        case began
        case ended(shouldResume: Bool)
    }

    var onInterruption: ((Interruption) -> Void)?
    /// Called when the current output route disappears (AirPods taken out, headphones unplugged).
    var onRouteLost: (() -> Void)?
    /// Called when a new output appears (AirPods connected): what was being said may have been lost in the switch.
    var onRouteAdded: (() -> Void)?
    /// Called when iOS restarted its media services: every audio object must be brought back.
    var onMediaReset: (() -> Void)?

    private var observers: [NSObjectProtocol] = []

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
        )
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        observe()
    }

    /// The same, away from the main thread: activating the audio session is a blocking call that can take a
    /// moment (after a call, or when headphones change), and the screen must stay responsive meanwhile.
    func activateInBackground() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
                    try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        observe()
    }

    /// Audio for Listen (docs/LISTEN.md), away from the main thread: playback only, no microphone. Spoken audio that
    /// doesn't mix with other apps, so the lock screen, AirPods and the car show and control it (Now Playing), and
    /// music or a podcast playing before pauses and is told when it may carry on.
    func activateForListeningInBackground() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSessionQueue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .spokenAudio, options: [])
                    try session.setActive(true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        observe()
    }

    func deactivate() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // Blocking, so away from the main thread.
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Whether audio is going to headphones (the intended hands-free setup).
    var isUsingHeadphones: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay].contains(output.portType)
        }
    }

    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            let event: Interruption = type == .began ? .began : .ended(shouldResume: shouldResume)
            VoiceLog.add(type == .began ? "audio interruption began" : "audio interruption ended (resume: \(shouldResume))")
            Task { @MainActor in self?.onInterruption?(event) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
            VoiceLog.add("audio route changed (reason \(reason.rawValue)) → \(outputs)")
            switch reason {
            case .oldDeviceUnavailable:
                Task { @MainActor in self?.onRouteLost?() }
            case .newDeviceAvailable:
                Task { @MainActor in self?.onRouteAdded?() }
            default:
                break
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            VoiceLog.add("audio media services were reset")
            Task { @MainActor in self?.onMediaReset?() }
        })
    }
}
