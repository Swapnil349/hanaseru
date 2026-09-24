import AVFoundation

/// Owns the app's audio session for a hands-free session (spec §61).
///
/// `.playAndRecord` with Bluetooth enabled lets AirPods carry both directions; `.duckOthers` lowers
/// music rather than stopping it. Haptics are explicitly allowed during recording — iOS silences them otherwise.
@MainActor
final class AudioSessionController {
    /// Called with `true` when an interruption (e.g. a phone call) begins, `false` when it ends.
    var onInterruption: ((Bool) -> Void)?
    /// Called when the current output route disappears (AirPods taken out, headphones unplugged).
    var onRouteLost: (() -> Void)?

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

    func deactivate() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
            let began = type == .began
            Task { @MainActor in self?.onInterruption?(began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.onRouteLost?() }
        })
    }
}
