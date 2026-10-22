import LearningCore
import SessionCore
import SwiftUI

/// What "Say it" heard, and how close it was to the line (0…1).
struct SayResult {
    var heard: String
    var similarity: Double
    var problem: String?

    init(heard: String, similarity: Double, problem: String? = nil) {
        self.heard = heard
        self.similarity = similarity
        self.problem = problem
    }
}

/// "Say it" outside a session: the microphone is on just for this one line.
@MainActor
enum LineCheck {
    static func listen(_ app: AppEnvironment, references: [String]) async -> SayResult {
        var permitted = VoicePermissions.granted
        if !permitted { permitted = await VoicePermissions.request() }
        guard permitted else {
            return SayResult(heard: "", similarity: 0, problem: "Allow the microphone and speech recognition in Settings › Hanaseru.")
        }
        // The microphone and Listen never share the audio.
        app.listen.stop(reason: "Say it")
        do {
            try await app.voice.beginSession()
        } catch {
            return SayResult(heard: "", similarity: 0, problem: error.localizedDescription)
        }
        // Spoken, even when answers are usually written.
        let wasWriting = app.voice.writing.isEnabled
        app.voice.writing.isEnabled = false
        app.voice.cues.play(.yourTurn)
        let options = ListenOptions(startTimeout: 6, endSilence: 1.2, maxDuration: 15, contextualStrings: references)
        let result = await app.voice.recognizer.listen(options) { _ in }
        app.voice.writing.isEnabled = wasWriting
        app.voice.endSession()
        let heard = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return SayResult(heard: heard, similarity: heard.isEmpty ? 0 : JapaneseText.bestSimilarity(heard, to: references))
    }
}

/// The complete script: every line with its reading and meaning, to read, hear, say and learn by heart.
/// "Test me" hides your own lines until you tap them, so you can check you know what to say.
struct ScriptView: View {
    let parts: [ScriptPart]
    /// Where the session is, to mark that line and open the script there.
    var currentLineID: String?
    var currentPart: Int?
    /// Plays a line; the flag asks for it slowly.
    let onPlay: ([SpeechRequest], Bool) -> Void
    /// Starts practising at a part and, in a scene, at a line. Nil: no start buttons.
    var onStart: ((Int, Int?) -> Void)?
    var title = "Script"
    /// "Say it": listens for a line and says how close it was. Nil: no Say it buttons.
    var onSay: ((ScriptEntry) async -> SayResult)?

    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false
    @State private var saying: String?
    @State private var results: [String: SayResult] = [:]
    @State private var slowly = false
    @State private var showEnglish = true
    @State private var testMe = false
    @State private var revealed: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(parts) { part in
                    Section {
                        if !part.situation.isEmpty {
                            Text(part.situation).font(.callout).foregroundStyle(Palette.inkSecondary)
                        }
                        ForEach(part.entries) { entry in
                            row(entry, part: part).id(entry.id)
                        }
                    } header: {
                        header(part)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .onAppear {
                if let current = currentEntryID { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .safeAreaInset(edge: .bottom) { options }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // The whole conversation in writing: Japanese, English letters and English.
                ShareLink(item: ScriptPart.text(of: parts), subject: Text(title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("script-share")
            }
        }
    }

    private var currentEntryID: String? {
        guard let currentLineID else { return nil }
        let part = parts.first { $0.index == currentPart } ?? parts.first
        return part?.entries.first { $0.lineID == currentLineID && $0.isLearner }?.id
    }

    private func header(_ part: ScriptPart) -> some View {
        HStack {
            Text(parts.count > 1 ? "Part \(part.index + 1) · \(part.title)" : part.title)
            Spacer()
            if let onStart, parts.count > 1 {
                Button("Start this part") { onStart(part.index, nil) }
                    .font(.caption.weight(.semibold))
            }
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func row(_ entry: ScriptEntry, part: ScriptPart) -> some View {
        let isCurrent = entry.isLearner && entry.lineID != nil && entry.lineID == currentLineID && part.index == currentPart
        let hidden = testMe && entry.isLearner && !revealed.contains(entry.id)
        VStack(alignment: .leading, spacing: 6) {
                let name = entry.label ?? speaker(entry)
                if !name.isEmpty {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.isLearner ? Palette.line : Palette.inkSecondary)
                }
                if hidden {
                    // Test me: the meaning is the cue; the Japanese stays hidden until tapped.
                    Text(entry.english).font(.callout).foregroundStyle(Palette.ink)
                    Button("Tap to see the Japanese") { revealed.insert(entry.id) }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                } else {
                    JapaneseTextView(japanese: entry.japanese, kana: entry.kana, romaji: entry.romaji,
                                     english: showEnglish ? entry.english : "", style: .body)
                }
                HStack(spacing: 8) {
                    Button { onPlay(entry.audio, slowly) } label: {
                        Label("Hear", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("script-hear")
                    if let onSay {
                        Button {
                            say(entry, with: onSay)
                        } label: {
                            Label(saying == entry.id ? "Listening…" : "Say it", systemImage: "mic.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(Palette.signal)
                        .disabled(saying != nil)
                        .accessibilityIdentifier("script-say")
                    }
                    if !hidden {
                        WordsButton(lines: [WordsLine(title: entry.isLearner ? "Your line" : "Their line",
                                                      japanese: entry.japanese, english: entry.english)],
                                    bordered: true)
                    }
                    if let line = entry.startLine, let onStart {
                        Button { onStart(part.index, line) } label: {
                            Label("From here", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .font(.footnote.weight(.semibold))
                if let result = results[entry.id] {
                    sayFeedback(result)
                }
        }
        .padding(.vertical, 4)
        .listRowBackground(isCurrent ? Palette.line.opacity(0.1) : Palette.surface)
    }

    private func say(_ entry: ScriptEntry, with check: @escaping (ScriptEntry) async -> SayResult) {
        saying = entry.id
        results[entry.id] = nil
        Task {
            let result = await check(entry)
            results[entry.id] = result
            saying = nil
        }
    }

    /// Never "wrong": what was heard, and whether it matched the line.
    @ViewBuilder
    private func sayFeedback(_ result: SayResult) -> some View {
        if let problem = result.problem {
            Text(problem).font(.footnote).foregroundStyle(Palette.caution)
        } else if result.heard.isEmpty {
            Label("Nothing heard. Tap Say it and speak after the chime.", systemImage: "ear")
                .font(.footnote).foregroundStyle(Palette.inkSecondary)
        } else if result.similarity >= 0.8 {
            Label("That's it: 「\(result.heard)」", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(Palette.go)
        } else if result.similarity >= 0.5 {
            Label("Close. Heard 「\(result.heard)」. Hear it and try again.", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Palette.signal)
        } else {
            Label("Heard 「\(result.heard)」. Hear it and try again.", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Palette.inkSecondary)
        }
    }

    private func speaker(_ entry: ScriptEntry) -> String {
        switch entry.speaker {
        case .partner(let name): name.isEmpty ? "Colleague" : name
        case .learner: "You"
        case .narrator: ""
        }
    }

    private var options: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $showEnglish) { Text("English") }
            Toggle(isOn: $showRomaji) { Text("Romaji") }
            Toggle(isOn: $testMe) { Label("Test me", systemImage: "eye.slash") }
                .onChange(of: testMe) { revealed.removeAll() }
            Toggle(isOn: $slowly) { Label("Slowly", systemImage: "tortoise") }
            Spacer(minLength: 0)
        }
        .toggleStyle(.button)
        .font(.caption)
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
