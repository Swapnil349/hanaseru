import LearningCore
import SessionCore
import SwiftData
import SwiftUI

/// Where a scene session starts, and how much of the lesson to play.
struct SceneStart: Hashable {
    var scenarioID: String
    var startBeat: Int
    var mode: SceneMode
    /// You play the colleague; the app says your usual lines.
    var playAsPartner = false
    /// Continue from where you stopped last time.
    var resumeAt: SessionTimeline.Stop?
}

/// Where you stopped in a scene, to continue from there next time.
enum SceneResume {
    private static func key(_ scenarioID: String, _ asPartner: Bool) -> String {
        "sceneResume.\(scenarioID).\(asPartner ? "partner" : "you")"
    }

    static func save(_ stop: SessionTimeline.Stop, scenarioID: String, asPartner: Bool, atStart: Bool) {
        guard !atStart else { return }
        UserDefaults.standard.set(["step": stop.step, "line": stop.line ?? -1, "answer": stop.isAnswer] as [String: Any],
                                  forKey: key(scenarioID, asPartner))
    }

    static func load(scenarioID: String, asPartner: Bool) -> SessionTimeline.Stop? {
        guard let saved = UserDefaults.standard.dictionary(forKey: key(scenarioID, asPartner)),
              let step = saved["step"] as? String else { return nil }
        let line = saved["line"] as? Int ?? -1
        return SessionTimeline.Stop(step: step, line: line < 0 ? nil : line, isAnswer: saved["answer"] as? Bool ?? false,
                                    japanese: "")
    }

    static func clear(scenarioID: String, asPartner: Bool) {
        UserDefaults.standard.removeObject(forKey: key(scenarioID, asPartner))
    }

    /// "Conversation · line 5 · question"
    static func title(_ stop: SessionTimeline.Stop) -> String {
        guard let line = stop.line else { return stop.step }
        return "\(stop.step) · line \(line)" + (stop.isAnswer ? " · your answer" : "")
    }
}

extension SceneMode {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .fullLesson: "Full lesson"
        case .practiseLines: "Practise my lines"
        case .conversationOnly: "Just the conversation"
        case .watch: "Just watch"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "The full lesson the first time; after that, straight to the conversation."
        case .fullLesson: "Watch the whole conversation, go through it line by line with the meaning, practise each line, then the conversation."
        case .practiseLines: "Watch the conversation, repeat each of your lines after the model, then the conversation."
        case .conversationOnly: "No explanations: the colleague speaks and you answer."
        case .watch: "The characters act out the whole conversation; nothing is asked."
        }
    }
}

/// Says a word or line in Japanese, from lists outside a session.
@MainActor
enum SayJapanese {
    static func play(_ text: String) {
        VoicePreview.shared.play(text, voice: AppleSpeechSynthesisProvider.voice(for: .japanese))
    }

    /// A line of a script, in its speaker's voice (`slowly`: at a slower speed).
    static func play(_ requests: [SpeechRequest], slowly: Bool) {
        guard let request = requests.first else { return }
        let choice = AppleSpeechSynthesisProvider.voice(for: request.voice, language: request.language)
        VoicePreview.shared.play(request.text, voice: choice.voice, rate: slowly ? 0.7 : request.rate, pitch: choice.pitch)
    }
}

/// Every conversation, ready to start from any line.
struct ScenesView: View {
    @Environment(AppEnvironment.self) private var app
    @Query private var knowledge: [KnowledgeRecord]

    private var practisedScenes: Set<String> {
        Set(knowledge.compactMap { record in
            record.itemID.contains("#") ? String(record.itemID.split(separator: "#").first ?? "") : nil
        })
    }

    @AppStorage(SettingsKey.workField) private var workFieldRaw = WorkField.engineering.rawValue

    /// A group of scenes in the list.
    private struct SceneGroup: Hashable {
        var title: String
        var field: WorkField?
        var track: Track
    }

    /// Your own field's scenes first, then everyday life, then the other field's.
    private var groups: [SceneGroup] {
        let mine = WorkField(rawValue: workFieldRaw) ?? .engineering
        let railway = SceneGroup(title: "Railway work", field: .engineering, track: .work)
        let finance = [SceneGroup(title: "Finance at work", field: .finance, track: .work),
                       SceneGroup(title: "Money in Japan", field: .finance, track: .everyday)]
        let everyday = SceneGroup(title: "Everyday", field: nil, track: .everyday)
        return mine == .finance ? finance + [everyday, railway] : [railway, everyday] + finance
    }

    var body: some View {
        List {
            ForEach(groups, id: \.self) { group in
                let scenes = app.library.scenarios.filter { $0.track == group.track && $0.workField == group.field }
                    .sorted { $0.level < $1.level }
                if !scenes.isEmpty {
                    Section(group.title) {
                        ForEach(scenes) { scenario in
                            NavigationLink {
                                SceneDetailView(scenario: scenario)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(scenario.title).font(.body).foregroundStyle(Palette.ink)
                                        Text("\(scenario.titleJa) · \(scenario.beats.count) lines")
                                            .font(.caption).foregroundStyle(Palette.inkSecondary)
                                    }
                                    Spacer()
                                    if practisedScenes.contains(scenario.id) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.go)
                                            .accessibilityLabel("Practised")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Scenes")
    }
}

/// One scene: its words, its lines (start from any of them), and how much of the lesson to play.
struct SceneDetailView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage("sceneMode") private var modeRaw = SceneMode.automatic.rawValue
    @Query private var profiles: [LearnerProfileRecord]
    let scenario: Scenario
    @State private var session: SceneSession?
    @State private var showScript = false
    @State private var playAsPartner = false
    /// A start chosen in the script, opened once the script has closed.
    @State private var startAfterScript: SceneSession?

    private struct SceneSession: Identifiable {
        let id = UUID()
        let start: SceneStart
    }

    private var mode: SceneMode { SceneMode(rawValue: modeRaw) ?? .automatic }

    var body: some View {
        let lines = app.library.lines(in: scenario, learnerName: profiles.first?.name ?? "")
        let persona = app.library.persona(id: scenario.personaID)
        List {
            Section {
                Text(scenario.situationEn).font(.callout).foregroundStyle(Palette.ink)
                Picker("You play", selection: $playAsPartner) {
                    Text("Yourself").tag(false)
                    Text(persona?.nameEn ?? "The colleague").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("scene-role")
                Picker("Lesson", selection: $modeRaw) {
                    ForEach(SceneMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Text(mode.detail).font(.caption).foregroundStyle(Palette.inkSecondary)
                if let stopped = SceneResume.load(scenarioID: scenario.id, asPartner: playAsPartner) {
                    Button {
                        session = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: 0, mode: mode,
                                                                 playAsPartner: playAsPartner, resumeAt: stopped))
                    } label: {
                        Label("Continue where you stopped: \(SceneResume.title(stopped))", systemImage: "forward.fill")
                    }
                    .accessibilityIdentifier("scene-continue")
                }
                Button {
                    session = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: 0, mode: mode, playAsPartner: playAsPartner))
                } label: {
                    Label("Start from the beginning", systemImage: "play.fill")
                }
                .accessibilityIdentifier("scene-start")
                Button {
                    session = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: 0, mode: .watch, playAsPartner: playAsPartner))
                } label: {
                    Label("Watch the scene", systemImage: "theatermasks")
                }
                .accessibilityIdentifier("scene-watch")
                Button { showScript = true } label: {
                    Label("Read the script", systemImage: "doc.plaintext")
                }
                .accessibilityIdentifier("scene-script")
            }

            Section {
                ForEach(app.library.vocabulary(in: scenario)) { term in
                    WordRow(term: term)
                }
            } header: {
                Text("Words in this conversation")
            } footer: {
                Text("Tap a word to hear it.")
            }

            Section("Lines — start from any of them") {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    VStack(alignment: .leading, spacing: 6) {
                        if let partner = line.partner {
                            Button { SayJapanese.play(partner.japanese) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(persona?.nameEn ?? "Colleague"): \(partner.japanese)").font(.subheadline)
                                    Text(partner.english).font(.caption).foregroundStyle(Palette.inkSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Button { SayJapanese.play(line.japanese) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("You: \(line.japanese)").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.line)
                                Text(line.english).font(.caption).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            session = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: index, mode: mode, playAsPartner: playAsPartner))
                        } label: {
                            Label("Start here", systemImage: "play.circle")
                        }
                        .font(.footnote)
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(scenario.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $session) { session in
            SessionContainerView(minutes: 10, focus: .conversation, scene: session.start)
        }
        .sheet(isPresented: $showScript, onDismiss: {
            session = startAfterScript
            startAfterScript = nil
        }) {
            NavigationStack {
                ScriptView(parts: [app.library.script(of: scenario, learnerName: profiles.first?.name ?? "")],
                           onPlay: { requests, slowly in SayJapanese.play(requests, slowly: slowly) },
                           onStart: { _, line in
                               startAfterScript = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: line ?? 0,
                                                                                 mode: mode, playAsPartner: playAsPartner))
                               showScript = false
                           },
                           title: scenario.title,
                           onSay: { entry in await LineCheck.listen(app, references: entry.references) })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showScript = false }
                        }
                    }
            }
        }
    }
}

/// A word with its reading and meaning; tap to hear it.
struct WordRow: View {
    let term: VocabularyTerm
    var detail: String = ""
    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false

    var body: some View {
        Button { SayJapanese.play(term.japanese) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(term.japanese).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                    if term.kana != term.japanese {
                        Text(term.kana).font(.caption).foregroundStyle(Palette.inkSecondary)
                    }
                    if showRomaji {
                        Text(term.romaji.isEmpty ? Romaji.of(term.japanese, kana: term.kana) : term.romaji)
                            .font(.caption.italic()).foregroundStyle(Palette.inkSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(term.english).font(.footnote).foregroundStyle(Palette.ink).multilineTextAlignment(.trailing)
                    if !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays the word")
    }
}
