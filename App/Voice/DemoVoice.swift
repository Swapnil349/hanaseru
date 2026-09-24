import Foundation
import SessionCore

/// Scripted voice for the Simulator and CI, where there is no microphone (and often no audio device).
///
/// Enable with the launch arguments `-demoVoice YES` (UserDefaults argument domain). The session logic,
/// persistence and UI run for real; only speech in and out are simulated: the "learner" answers with
/// the vocabulary the exercise expects, so a whole session can be played through and screenshotted.
enum DemoVoice {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "demoVoice")
    }

    @MainActor
    static func makeVoice() -> SessionRunner.Voice {
        SessionRunner.Voice(synthesizer: DemoSynthesizer(), recognizer: DemoRecognizer(), feedback: SilentFeedback())
    }
}

@MainActor
private final class DemoSynthesizer: SpeechSynthesisProvider {
    func speak(_ request: SpeechRequest) async {
        // Roughly a fifth of real speaking time, so a 2-minute session plays through quickly.
        let seconds = min(1.2, 0.05 * Double(request.text.count) / max(request.rate, 0.5))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func stopSpeaking() {}
}

@MainActor
private final class DemoRecognizer: SpeechRecognitionProvider {
    let processingDescription = "Demo voice (no microphone)"
    private var turn = 0

    func listen(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult {
        turn += 1
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard !Task.isCancelled else { return .silence }
        // Every fourth turn stays silent, to exercise the "no answer" help path.
        if turn % 4 == 0 { return .silence }
        let answer = options.contextualStrings.first(where: { !$0.isEmpty }) ?? "はい、そうです。"
        onPartial(answer)
        try? await Task.sleep(nanoseconds: 300_000_000)
        return ListenResult(transcript: answer, confidence: 0.9, latency: 1.2, speakingDuration: 1.5, outcome: .speech)
    }

    func cancelListening() {}
}

@MainActor
private final class SilentFeedback: CueFeedbackProvider {
    func play(_ cue: HapticCue) {}
}
