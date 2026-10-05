import LearningCore
import SessionCore
import SwiftData
import SwiftUI

/// Where a scene session starts, and how much of the lesson to play.
struct SceneStart: Hashable {
    var scenarioID: String
    var startBeat: Int
    var mode: SceneMode
}

extension SceneMode {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .fullLesson: "Full lesson"
        case .practiseLines: "Practise my lines"
        case .conversationOnly: "Just the conversation"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "The full lesson the first time; after that, straight to the conversation."
        case .fullLesson: "Explanation, listen to the whole conversation, practise each line, then the conversation."
        case .practiseLines: "Repeat each of your lines after the model, then the conversation."
        case .conversationOnly: "No explanations: the colleague speaks and you answer."
        }
    }
}

/// Says a word or line in Japanese, from lists outside a session.
@MainActor
enum SayJapanese {
    static func play(_ text: String) {
        VoicePreview.shared.play(text, voice: AppleSpeechSynthesisProvider.voice(for: .japanese))
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

    var body: some View {
        List {
            ForEach([Track.work, .everyday], id: \.self) { track in
                let scenes = app.library.scenarios.filter { $0.track == track }.sorted { $0.level < $1.level }
                if !scenes.isEmpty {
                    Section(track == .work ? "Work" : "Everyday") {
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
                Picker("Lesson", selection: $modeRaw) {
                    ForEach(SceneMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Text(mode.detail).font(.caption).foregroundStyle(Palette.inkSecondary)
                Button {
                    session = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: 0, mode: mode))
                } label: {
                    Label("Start from the beginning", systemImage: "play.fill")
                }
                .accessibilityIdentifier("scene-start")
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
                            session = SceneSession(start: SceneStart(scenarioID: scenario.id, startBeat: index, mode: mode))
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
    }
}

/// A word with its reading and meaning; tap to hear it.
struct WordRow: View {
    let term: VocabularyTerm
    var detail: String = ""

    var body: some View {
        Button { SayJapanese.play(term.japanese) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(term.japanese).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                    if term.kana != term.japanese {
                        Text(term.kana).font(.caption).foregroundStyle(Palette.inkSecondary)
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
