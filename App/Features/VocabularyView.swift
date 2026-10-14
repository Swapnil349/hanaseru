import LearningCore
import SwiftData
import SwiftUI

/// "My vocabulary": every word, phrase and line practised so far — in every session and scene, ever — to go
/// back to at any time.
struct VocabularyView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case words = "Words"
        case lines = "Phrases & lines"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var app
    @Query private var knowledge: [KnowledgeRecord]
    @Query private var profiles: [LearnerProfileRecord]
    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false
    @State private var segment = Segment.words
    @State private var showAllWords = false
    @State private var query = ""

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

    private func romaji(_ term: VocabularyTerm) -> String {
        term.romaji.isEmpty ? Romaji.of(term.japanese, kana: term.kana) : term.romaji
    }

    /// Search matches the Japanese, the kana, the romaji (with or without long-vowel marks) or the English.
    private func matches(_ texts: [String]) -> Bool {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return texts.contains { $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
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
        .searchable(text: $query, prompt: "Japanese, romaji or English")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Toggle(isOn: $showRomaji) { Text("Romaji") }
                    .toggleStyle(.button)
                ShareLink(item: listText(), subject: Text("My Japanese vocabulary")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private var wordRows: some View {
        let met = words.filter { matches([$0.term.japanese, $0.term.kana, romaji($0.term), $0.term.english]) }
        if met.isEmpty {
            if query.isEmpty {
                ContentUnavailableView("No words yet", systemImage: "character.book.closed.ja",
                                       description: Text("Words from the phrases and scenes you practise collect here."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            Section {
                ForEach(met, id: \.term.id) { entry in
                    WordRow(term: entry.term, detail: entry.sources.joined(separator: ", "))
                }
            } header: {
                Text("\(met.count) words met so far")
            } footer: {
                Text("Every word from the scenes and phrases you have practised, in every session. Tap a word to hear it.")
            }
        }
        Section {
            Toggle("Show every word in the course", isOn: $showAllWords)
            if showAllWords {
                let metIDs = Set(words.map(\.term.id))
                ForEach(app.library.vocabulary.filter { !metIDs.contains($0.id) && matches([$0.japanese, $0.kana, romaji($0), $0.english]) }
                    .sorted { $0.kana < $1.kana }) { term in
                    WordRow(term: term, detail: "Not met yet")
                }
            }
        }
    }

    @ViewBuilder
    private var lineRows: some View {
        let items = practisedItems.filter { matches([$0.japanese, $0.kana, $0.romaji, $0.english]) }
        let scenes = practisedScenes
        if practisedItems.isEmpty && scenes.isEmpty {
            ContentUnavailableView("Nothing practised yet", systemImage: "text.bubble",
                                   description: Text("Phrases and scene lines you practise collect here."))
        }
        if !items.isEmpty {
            Section("Phrases (\(items.count))") {
                ForEach(items) { item in
                    lineRow(item.japanese, kana: item.kana, romaji: item.romaji, english: item.english)
                }
            }
        }
        ForEach(scenes) { scenario in
            let lines = app.library.lines(in: scenario, learnerName: profiles.first?.name ?? "")
                .filter { practised.contains($0.id) && matches([$0.japanese, $0.kana, $0.romaji, $0.english]) }
            if !lines.isEmpty {
                Section(scenario.title) {
                    ForEach(lines) { line in
                        lineRow(line.japanese, kana: line.kana, romaji: line.romaji, english: line.english)
                    }
                }
            }
        }
    }

    private func lineRow(_ japanese: String, kana: String, romaji: String, english: String) -> some View {
        Button { SayJapanese.play(japanese) } label: {
            JapaneseTextView(japanese: japanese, kana: kana, romaji: romaji, english: english, style: .body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// The word list as text, to share or keep.
    private func listText() -> String {
        var lines = ["My Japanese vocabulary", ""]
        for entry in words {
            var line = entry.term.japanese
            if entry.term.kana != entry.term.japanese { line += " (\(entry.term.kana))" }
            line += " — " + romaji(entry.term) + " — " + entry.term.english
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
