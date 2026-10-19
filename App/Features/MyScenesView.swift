import ConversationCore
import LearningCore
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// "My scenes", first in Scenes: the learner's own conversations and speeches, a new one, and importing a file.
struct MyScenesSection: View {
    @Environment(AppEnvironment.self) private var app
    let practised: Set<String>
    /// "New scene" was tapped.
    let onNew: () -> Void
    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        Section {
            ForEach(app.myScenes.scenes) { scene in
                if let scenario = app.library.scenario(id: scene.id) {
                    NavigationLink {
                        SceneDetailView(scenario: scenario)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(scenario.title).font(.body).foregroundStyle(Palette.ink)
                                Text(detail(scene, scenario)).font(.caption).foregroundStyle(Palette.inkSecondary)
                            }
                            Spacer()
                            if practised.contains(scenario.id) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.go)
                                    .accessibilityLabel("Practised")
                            }
                        }
                    }
                }
            }
            Button(action: onNew) {
                Label("New scene", systemImage: "plus.circle.fill")
            }
            .accessibilityIdentifier("my-scene-new")
            Button { showImporter = true } label: {
                Label("Import a scene…", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("my-scene-import")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                importFile(result)
            }
            if let importMessage {
                Text(importMessage).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
        } header: {
            Text("My scenes")
        } footer: {
            Text("Describe a conversation or a speech in English and the AI coach writes it for you, ready to practise like any scene.")
        }
    }

    /// "新しいチームへの挨拶 · Speech · 6 lines"
    private func detail(_ scene: MyScene, _ scenario: Scenario) -> String {
        let kind = scenario.isMonologue ? "Speech" : "Conversation"
        let parts = [scenario.titleJa, kind, "\(scenario.beats.count) lines"].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let count = try app.myScenes.importFile(Data(contentsOf: url))
                importMessage = count == 1 ? "Imported 1 scene." : "Imported \(count) scenes."
            } catch {
                importMessage = error.localizedDescription
            }
        case .failure(let error):
            importMessage = error.localizedDescription
        }
    }
}

/// On one of the learner's own scenes: what was asked for, its words, and changing, sharing or deleting it.
struct MySceneActionsSection: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let scene: MyScene
    let scenario: Scenario
    @State private var changing = false
    @State private var confirmDelete = false
    @State private var exportURL: URL?

    var body: some View {
        Section {
            if !scene.description.isEmpty {
                Text(scene.description).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
            WordsButton(lines: wordsLines, bordered: true)
            Button { changing = true } label: {
                Label("Change this scene", systemImage: "wand.and.stars")
            }
            .accessibilityIdentifier("my-scene-change")
            .task(id: scene.updatedAt) { exportURL = app.myScenes.exportFile(for: scene) }
            .sheet(isPresented: $changing) {
                NavigationStack {
                    MySceneEditorView(previous: scene) { _ in changing = false }
                }
            }
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Export (.json)", systemImage: "square.and.arrow.up")
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Delete this scene", systemImage: "trash")
            }
            .accessibilityIdentifier("my-scene-delete")
            .confirmationDialog("Delete “\(scenario.title)”? This can't be undone.", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    SceneResume.clear(scenarioID: scene.id, asPartner: false)
                    SceneResume.clear(scenarioID: scene.id, asPartner: true)
                    app.myScenes.delete(id: scene.id)
                    dismiss()
                }
            }
        } header: {
            Text(scenario.isMonologue ? "Your speech" : "Your scene")
        } footer: {
            Text("Written by the AI coach " + scene.updatedDate.formatted(date: .abbreviated, time: .omitted)
                 + ". Export it to use it on your other devices.")
        }
    }

    /// Every line of the scene, for the Words list.
    private var wordsLines: [WordsLine] {
        let lines = app.library.lines(in: scenario, learnerName: "")
        var result: [WordsLine] = []
        for line in lines {
            if let partner = line.partner {
                result.append(WordsLine(title: partner.nameEn, japanese: partner.japanese, english: partner.english))
            }
            result.append(WordsLine(title: "You", japanese: line.japanese, english: line.english))
        }
        if !scenario.closingLine.isEmpty {
            let name = app.library.persona(id: scenario.personaID)?.nameEn ?? ""
            result.append(WordsLine(title: name, japanese: scenario.closingLine, english: scenario.closingEnglish))
        }
        return result
    }
}

/// Describing a new scene (or a change to one) in English, by voice or typing, and having the AI coach write it.
struct MySceneEditorView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [LearnerProfileRecord]
    /// The scene to change; nil for a new one.
    let previous: MyScene?
    /// The scene was written and saved.
    let onSaved: (MyScene) -> Void

    @AppStorage("mySceneKind") private var kindRaw = MyScene.Kind.conversation.rawValue
    @AppStorage("mySceneLength") private var length = 6
    @State private var changeLength = 6
    @AppStorage("myScenePoliteness") private var politenessRaw = Politeness.professional.rawValue
    @State private var english = ""
    @State private var dictation = EnglishDictation()
    @State private var writing = false
    @State private var progress = ""
    @State private var problem = ""
    @State private var job: Task<Void, Never>?

    private var kind: MyScene.Kind { previous?.kind ?? MyScene.Kind(rawValue: kindRaw) ?? .conversation }
    private var politeness: Politeness { Politeness(rawValue: politenessRaw) ?? .professional }
    private var lengthBinding: Binding<Int> { previous == nil ? $length : $changeLength }

    var body: some View {
        Form {
            if previous == nil {
                Section {
                    Picker("Kind", selection: $kindRaw) {
                        Text("Conversation").tag(MyScene.Kind.conversation.rawValue)
                        Text("Speech").tag(MyScene.Kind.monologue.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("my-scene-kind")
                } footer: {
                    Text(kind == .conversation
                         ? "You and someone else take turns: you'll practise your side, or theirs."
                         : "You speak alone: a self-introduction, a short presentation, a speech.")
                }
            }

            Section {
                TextField(placeholder, text: $english, axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityIdentifier("my-scene-description")
                Button {
                    if dictation.isListening {
                        dictation.stop()
                    } else {
                        problem = ""
                        Task { await dictation.start { english = $0 } }
                    }
                } label: {
                    Label(dictation.isListening ? "Stop" : "Speak English",
                          systemImage: dictation.isListening ? "stop.circle.fill" : "mic.circle.fill")
                }
                .disabled(writing)
                if !dictation.problem.isEmpty {
                    Text(dictation.problem).font(.caption).foregroundStyle(Palette.caution)
                }
            } header: {
                Text(previous == nil ? "Describe it in English" : "What should change?")
            } footer: {
                Text(previous == nil
                     ? "Who you're talking to, where, and what you want to say. The more you say, the closer it fits."
                     : "For example: “make it more casual”, “add a line about my weekend”, “she should ask about my family”.")
            }

            Section {
                Stepper(value: lengthBinding, in: 2...12) {
                    LabeledContent(kind == .monologue ? "Sentences" : "Exchanges", value: "\(lengthBinding.wrappedValue)")
                }
                Picker("Politeness", selection: $politenessRaw) {
                    Text("Friends").tag(Politeness.casual.rawValue)
                    Text("Work").tag(Politeness.professional.rawValue)
                    Text("Very polite").tag(Politeness.veryPolite.rawValue)
                }
            }

            Section {
                Button { write() } label: {
                    HStack(spacing: 10) {
                        if writing { ProgressView() }
                        Text(writing ? "Writing…" : (previous == nil ? "Write my scene" : "Change my scene"))
                            .font(.headline)
                    }
                }
                .disabled(!canWrite)
                .accessibilityIdentifier("my-scene-write")
                if !progress.isEmpty {
                    Text(progress).font(.footnote).foregroundStyle(Palette.inkSecondary)
                }
                if !problem.isEmpty {
                    Text(problem).font(.footnote).foregroundStyle(Palette.caution)
                }
            } footer: {
                if !app.isCoachConfigured {
                    Text("Writing scenes needs the AI coach. Add your coach server in Settings › AI coach.")
                }
            }
        }
        .navigationTitle(previous == nil ? "New scene" : "Change this scene")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    job?.cancel()
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(writing)
        .onAppear {
            if let previous { changeLength = min(max(previous.result.beats.count, 2), 12) }
            app.wakeCoach()
        }
        .onDisappear {
            dictation.stop()
            job?.cancel()
        }
    }

    private var placeholder: String {
        if previous != nil { return "Describe the change" }
        return kind == .conversation
            ? "e.g. Asking my landlord to fix the heater in my flat"
            : "e.g. Introducing myself to my new team at the bank"
    }

    private var canWrite: Bool {
        !writing && app.isCoachConfigured && !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func write() {
        dictation.stop()
        let text = english.trimmingCharacters(in: .whitespacesAndNewlines)
        // A free server may first have to wake up, then the coach writes every line with its words: up to minutes.
        guard !text.isEmpty, let coach = app.makeRemoteProvider(timeout: 180) else { return }
        var earlier: String?
        if let previous {
            do {
                earlier = try previous.resultJSON()
            } catch {
                problem = "This scene couldn't be read to change it."
                return
            }
        }
        let request = SceneRequest(description: text, kind: kind, learnerName: profiles.first?.name ?? "",
                                   learnerLevel: profiles.first?.difficulty.level ?? 3, politeness: politeness,
                                   length: lengthBinding.wrappedValue, previous: earlier)
        let original = self.previous
        writing = true
        problem = ""
        progress = original == nil ? "Writing your scene…" : "Changing your scene…"
        job = Task {
            // Say what's happening rather than look stuck.
            let notices = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                progress = "Waking up the AI coach — a free server can take a minute after a break…"
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                guard !Task.isCancelled else { return }
                progress = "Still writing — a long scene with every word explained can take up to two minutes."
            }
            defer { notices.cancel() }
            do {
                let result = try await coach.writeScene(request)
                let scene = MyScene.saved(result, kind: request.kind, description: text, replacing: original)
                app.myScenes.save(scene)
                writing = false
                progress = ""
                onSaved(scene)
            } catch {
                writing = false
                progress = ""
                if !(error is CancellationError) { problem = Self.message(for: error) }
            }
        }
    }

    /// Plain English for what went wrong.
    static func message(for error: Error) -> String {
        guard let error = error as? AIProviderError else {
            return "Couldn't write the scene: \(error.localizedDescription)"
        }
        switch error {
        case .timedOut:
            return "The AI coach took too long. Try again — once it's awake it's quicker."
        case .transport(let detail):
            return "Couldn't reach the AI coach (\(detail)). Check the connection and try again."
        case .badResponse:
            return "The coach's scene couldn't be read. Try again, perhaps describing it a little differently."
        case .notAvailable, .unknownScenario:
            return "The AI coach can't write scenes right now."
        }
    }
}
