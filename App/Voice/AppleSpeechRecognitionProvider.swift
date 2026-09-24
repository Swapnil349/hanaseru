import AVFoundation
import Speech
import SessionCore

/// Japanese speech recognition with `SFSpeechRecognizer` (spec §35).
///
/// * On-device when the Japanese model is available; otherwise Apple's servers (shown in the UI).
/// * Silence-based end-pointing, so the learner never has to press a button.
/// * Contextual strings bias recognition towards the vocabulary being practised.
///
/// This is one implementation of `SpeechRecognitionProvider`; an iOS 26 `SpeechAnalyzer` or a cloud
/// recogniser can replace it without touching the session logic.
@MainActor
final class AppleSpeechRecognitionProvider: SpeechRecognitionProvider {
    private let engine: AudioEngineHost
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var cancelled = false

    init(engine: AudioEngineHost) {
        self.engine = engine
    }

    var isOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    var processingDescription: String {
        isOnDevice ? "Transcribed on this iPhone" : "Transcribed by Apple's speech service"
    }

    func listen(_ options: ListenOptions, onPartial: @escaping @MainActor (String) -> Void) async -> ListenResult {
        guard let recognizer, recognizer.isAvailable else {
            return ListenResult(transcript: "", outcome: .failed("Japanese speech recognition isn't available right now."))
        }
        cancelled = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = Array(options.contextualStrings.prefix(100))
        request.addsPunctuation = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let state = ListenState()
        let startedAt = Date()
        engine.setConsumer { buffer in request.append(buffer) }

        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            var confidence: Double?
            if let segments = result?.bestTranscription.segments, isFinal, !segments.isEmpty {
                confidence = Double(segments.map(\.confidence).reduce(0, +)) / Double(segments.count)
            }
            let failed = error != nil
            Task { @MainActor in
                state.update(text: text, isFinal: isFinal, confidence: confidence, failed: failed)
                if let text, !text.isEmpty, !isFinal { onPartial(text) }
            }
        }

        // End-pointing: stop after enough silence following speech, or if speech never starts.
        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled || cancelled || state.isFinal || state.failed { break }
            let now = Date()
            if let first = state.firstSpeechAt {
                if now.timeIntervalSince(state.lastChangeAt) >= options.endSilence { break }
                if now.timeIntervalSince(first) >= options.maxDuration { break }
            } else if now.timeIntervalSince(startedAt) >= options.startTimeout {
                break
            }
        }

        engine.setConsumer(nil)
        request.endAudio()
        // Let the recogniser settle on its final transcription.
        if !(Task.isCancelled || cancelled), !state.isFinal, !state.transcript.isEmpty {
            for _ in 0..<8 where !state.isFinal {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        task?.cancel()
        task = nil
        self.request = nil

        if Task.isCancelled || cancelled { return .silence }
        let transcript = state.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, let firstSpeechAt = state.firstSpeechAt else {
            return ListenResult(transcript: "", outcome: .noSpeech)
        }
        return ListenResult(
            transcript: transcript,
            confidence: state.confidence,
            latency: firstSpeechAt.timeIntervalSince(startedAt),
            speakingDuration: max(0, state.lastChangeAt.timeIntervalSince(firstSpeechAt)),
            outcome: .speech
        )
    }

    func cancelListening() {
        cancelled = true
        engine.setConsumer(nil)
        request?.endAudio()
        task?.cancel()
    }
}

@MainActor
private final class ListenState {
    var transcript = ""
    var firstSpeechAt: Date?
    var lastChangeAt = Date()
    var isFinal = false
    var failed = false
    var confidence: Double?

    func update(text: String?, isFinal: Bool, confidence: Double?, failed: Bool) {
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            lastChangeAt = Date()
            if firstSpeechAt == nil { firstSpeechAt = lastChangeAt }
        }
        if isFinal { self.isFinal = true }
        if let confidence { self.confidence = confidence }
        // "No speech detected" arrives as an error; it just ends the turn.
        if failed { self.failed = true }
    }
}

enum VoicePermissions {
    static var granted: Bool {
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func request() async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return microphone && speech
    }
}
