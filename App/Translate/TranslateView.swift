import AVFoundation
import ConversationCore
import LearningCore
import Speech
import SwiftUI
import Translation

/// Say it in English, get the Japanese a Japanese colleague would actually say — with its reading, to hear,
/// and to save for practice.
///
/// With the AI coach configured, Claude translates with the right register and set phrases, explains the
/// choice and offers alternatives. Without it, Apple's on-device translator is used.
struct TranslateView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage("translatePoliteness") private var politenessRaw = Politeness.professional.rawValue

    @State private var english = ""
    @State private var situation = ""
    @State private var dictation = EnglishDictation()
    @State private var result: TranslationResult?
    @State private var engineName = ""
    @State private var translating = false
    @State private var message = ""
    @State private var saved = false
    /// Apple on-device translation is driven by this configuration (iOS 18).
    @State private var appleRequest: String?

    private var politeness: Politeness { Politeness(rawValue: politenessRaw) ?? .professional }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inputCard
                Picker("Politeness", selection: $politenessRaw) {
                    Text("Friends").tag(Politeness.casual.rawValue)
                    Text("Work").tag(Politeness.professional.rawValue)
                    Text("Very polite").tag(Politeness.veryPolite.rawValue)
                }
                .pickerStyle(.segmented)
                TextField("Who to? e.g. my senior engineer at the site (optional)", text: $situation)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)

                PrimaryButton(title: translating ? "Translating…" : "Translate", systemImage: "character.bubble") {
                    translate()
                }
                .disabled(english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || translating)
                .accessibilityIdentifier("translate-button")

                if !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(Palette.caution)
                }
                if let result { resultCard(result) }
            }
            .padding(Metrics.padding)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .navigationTitle("Translate")
        .modifier(AppleTranslation(request: $appleRequest) { japanese, error in
            translating = false
            if let japanese {
                show(TranslationResult(japanese: japanese, kana: JapaneseReading.kana(for: japanese)),
                     engine: "Apple on-device translation")
            } else {
                message = error ?? "Couldn't translate that."
            }
        })
        .task { app.wakeCoach() }
        .onDisappear { dictation.stop() }
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(ja: "英語で言ってください", en: "Say it in English")
            TextField("What do you want to say?", text: $english, axis: .vertical)
                .font(.title3)
                .lineLimit(2...5)
                .padding(12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            HStack {
                Button {
                    if dictation.isListening {
                        dictation.stop()
                    } else {
                        result = nil
                        message = ""
                        Task { await dictation.start { english = $0 } }
                    }
                } label: {
                    Label(dictation.isListening ? "Stop" : "Speak English",
                          systemImage: dictation.isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(dictation.isListening ? Palette.caution : Palette.line)
                .accessibilityIdentifier("dictate-english")
                Spacer()
                if !english.isEmpty {
                    Button("Clear") {
                        english = ""
                        result = nil
                    }
                    .font(.footnote)
                }
            }
            if !dictation.problem.isEmpty {
                Text(dictation.problem).font(.caption).foregroundStyle(Palette.caution)
            }
        }
    }

    // MARK: - Result

    private func resultCard(_ result: TranslationResult) -> some View {
        PracticeCard {
            SectionLabel(ja: "日本語では", en: "In Japanese")
            Text(result.japanese)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            if !result.kana.isEmpty && result.kana != result.japanese {
                Text(result.kana).font(.callout).foregroundStyle(Palette.inkSecondary)
            }
            if !result.backTranslation.isEmpty {
                Text("Literally: \(result.backTranslation)").font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
            if !result.notes.isEmpty {
                Text(result.notes).font(.footnote).foregroundStyle(Palette.ink)
            }
            HStack(spacing: 12) {
                Button { SayJapanese.play(result.japanese) } label: { Label("Listen", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(.bordered)
                Button { saveForPractice(result) } label: {
                    Label(saved ? "Saved" : "Practise this", systemImage: saved ? "checkmark" : "plus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(saved)
            }
            ForEach(result.alternatives, id: \.japanese) { alternative in
                Divider()
                Button { SayJapanese.play(alternative.japanese) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alternative.whenToUse).font(.caption.weight(.semibold)).foregroundStyle(Palette.line)
                        Text(alternative.japanese).font(.body).foregroundStyle(Palette.ink)
                        Text(alternative.kana).font(.caption).foregroundStyle(Palette.inkSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Text(engineName).font(.caption2).foregroundStyle(Palette.inkSecondary)
        }
    }

    // MARK: - Actions

    private func translate() {
        dictation.stop()
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        translating = true
        message = ""
        saved = false
        if let coach = app.makeRemoteProvider(timeout: 75) {
            let request = TranslationRequest(english: text, politeness: politeness,
                                             situation: situation.isEmpty ? nil : situation)
            Task {
                // A sleeping free server takes up to a minute to wake: say so rather than look stuck.
                let notice = Task {
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if !Task.isCancelled && translating { message = "Waking up the AI coach — up to a minute after a break…" }
                }
                defer { notice.cancel() }
                do {
                    let answer = try await coach.translate(request)
                    translating = false
                    message = ""
                    show(answer, engine: "AI coach (Claude): natural phrasing for the situation")
                } catch {
                    // Coach unreachable: Apple's translator still works.
                    useApple(text)
                }
            }
        } else {
            useApple(text)
        }
    }

    private func useApple(_ text: String) {
        message = ""
        if #available(iOS 18.0, *) {
            appleRequest = text
        } else {
            translating = false
            message = "Translation needs iOS 18 or an AI coach server (Settings)."
        }
    }

    private func show(_ answer: TranslationResult, engine: String) {
        result = answer
        engineName = engine
        SayJapanese.play(answer.japanese)
    }

    private func saveForPractice(_ result: TranslationResult) {
        app.repository.addPhrase(japanese: result.japanese, kana: result.kana, english: english, note: result.notes,
                                 source: .wantToRemember, track: .work)
        saved = true
    }
}

/// Runs Apple's on-device English → Japanese translation when `request` is set (iOS 18+).
private struct AppleTranslation: ViewModifier {
    @Binding var request: String?
    let completion: (String?, String?) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(AppleTranslationTask(request: $request, completion: completion))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct AppleTranslationTask: ViewModifier {
    @Binding var request: String?
    let completion: (String?, String?) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                guard let text = request else { return }
                do {
                    let response = try await session.translate(text)
                    await MainActor.run {
                        request = nil
                        completion(response.targetText, nil)
                    }
                } catch {
                    await MainActor.run {
                        request = nil
                        completion(nil, "Apple's translator couldn't do that: \(error.localizedDescription)")
                    }
                }
            }
            .onChange(of: request) {
                guard request != nil else { return }
                if configuration == nil {
                    configuration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"),
                                                                     target: Locale.Language(identifier: "ja"))
                } else {
                    configuration?.invalidate()
                }
            }
    }
}

/// The hiragana reading of Japanese text, from the system's Japanese tokenizer.
enum JapaneseReading {
    static func kana(for japanese: String) -> String {
        let text = japanese as NSString
        let tokenizer = CFStringTokenizerCreate(nil, japanese as CFString, CFRange(location: 0, length: text.length),
                                                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var reading = ""
        var position = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if range.location > position {
                reading += text.substring(with: NSRange(location: position, length: range.location - position))
            }
            let token = text.substring(with: NSRange(location: range.location, length: range.length))
            if JapaneseText.containsJapanese(token),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String,
               let kana = latin.applyingTransform(.latinToHiragana, reverse: false) {
                reading += kana
            } else {
                reading += token
            }
            position = range.location + range.length
        }
        if position < text.length { reading += text.substring(from: position) }
        return reading
    }
}

/// English speech to text, for the Translate screen (outside a session).
@Observable
@MainActor
final class EnglishDictation {
    private(set) var isListening = false
    private(set) var problem = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?

    func start(onText: @escaping @MainActor (String) -> Void) async {
        problem = ""
        if !VoicePermissions.granted, !(await VoicePermissions.request()) {
            problem = "Allow the microphone and speech recognition in Settings › Hanaseru."
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-IN")) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            problem = "English speech recognition isn't available right now — type instead."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            // Runs on the audio thread: must not be inferred as a main-actor closure.
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            problem = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        isListening = true
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self else { return }
                if let text, !text.isEmpty {
                    onText(text)
                    self.restartSilenceTimer()
                }
                if done { self.stop() }
            }
        }
        restartSilenceTimer(seconds: 8)
    }

    /// Stops after a pause in speech (or if nothing is said at all).
    private func restartSilenceTimer(seconds: Double = 2.0) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        silenceTimer?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
