import LearningCore
import SwiftData
import SwiftUI

/// "My vocabulary": every word, phrase and line practised so far, to go back to at any time.
struct VocabularyView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case words = "Words"
        case lines = "Phrases & lines"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var app
    @Query private var knowledge: [KnowledgeRecord]
    @Query private var profiles: [LearnerProfileRecord]
    @State private var segment = Segment.words
    @State private var showAllWords = false

    private var practised: Set<String> { Set(knowledge.map(\.itemID)) }

    private var practisedScenes: [Scenario] {
        let ids = Set(practised.compactMap { $0.contains("#") ? String($0.split(separator: "#").first ?? "") : nil })
        return app.library.scenarios.filter { ids.contains($0.id) }
    }

    private var practisedItems: [LearningItem] {
        app.library.items.filter { practised.contains($0.id) }
    }

    /// Each word met so far, with where it was met.
    private var words: [(term: VocabularyTerm, sources: [String])] {
        var sources: [String: [String]] = [:]
        var terms: [String: VocabularyTerm] = [:]
        for scenario in practisedScenes {
            for term in app.library.vocabulary(in: scenario) {
                terms[term.id] = term
                sources[term.id, default: []].append(scenario.title)
            }
        }
        for item in practisedItems {
            for term in app.library.vocabulary(in: item) {
                terms[term.id] = term
                if !(sources[term.id] ?? []).contains("Phrases") { sources[term.id, default: []].append("Phrases") }
            }
        }
        return terms.values.sorted { $0.kana < $1.kana }.map { ($0, sources[$0.id] ?? []) }
    }

    var body: some View {
        List {
            Picker("Show", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            switch segment {
            case .words: wordRows
            case .lines: lineRows
            }
        }
        .navigationTitle("My vocabulary")
    }

    @ViewBuilder
    private var wordRows: some View {
        let met = words
        if met.isEmpty {
            ContentUnavailableView("No words yet", systemImage: "character.book.closed.ja",
                                   description: Text("Words from the phrases and scenes you practise collect here."))
        } else {
            Section {
                ForEach(met, id: \.term.id) { entry in
                    WordRow(term: entry.term, detail: entry.sources.joined(separator: ", "))
                }
            } header: {
                Text("\(met.count) words met so far")
            } footer: {
                Text("Tap a word to hear it.")
            }
        }
        Section {
            Toggle("Show every word in the course", isOn: $showAllWords)
            if showAllWords {
                let metIDs = Set(met.map(\.term.id))
                ForEach(app.library.vocabulary.filter { !metIDs.contains($0.id) }.sorted { $0.kana < $1.kana }) { term in
                    WordRow(term: term, detail: "Not met yet")
                }
            }
        }
    }

    @ViewBuilder
    private var lineRows: some View {
        let items = practisedItems
        let scenes = practisedScenes
        if items.isEmpty && scenes.isEmpty {
            ContentUnavailableView("Nothing practised yet", systemImage: "text.bubble",
                                   description: Text("Phrases and scene lines you practise collect here."))
        }
        if !items.isEmpty {
            Section("Phrases (\(items.count))") {
                ForEach(items) { item in
                    lineRow(item.japanese, item.english)
                }
            }
        }
        ForEach(scenes) { scenario in
            let lines = app.library.lines(in: scenario, learnerName: profiles.first?.name ?? "")
                .filter { practised.contains($0.id) }
            Section(scenario.title) {
                ForEach(lines) { line in
                    lineRow(line.japanese, line.english)
                }
            }
        }
    }

    private func lineRow(_ japanese: String, _ english: String) -> some View {
        Button { SayJapanese.play(japanese) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(japanese).font(.body).foregroundStyle(Palette.ink)
                Text(english).font(.caption).foregroundStyle(Palette.inkSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}
