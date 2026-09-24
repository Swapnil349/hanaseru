import LearningCore
import SwiftData
import SwiftUI

/// "My Japanese" (spec §15): phrases from real life and recurring mistakes. Personal content is
/// prioritised over generic content when sessions are planned.
struct MyJapaneseView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PersonalPhraseRecord.createdAt, order: .reverse) private var phrases: [PersonalPhraseRecord]
    @Query(sort: \MistakeRecord.occurrences, order: .reverse) private var mistakes: [MistakeRecord]
    @State private var segment = Segment.phrases
    @State private var showCapture = false

    enum Segment: String, CaseIterable, Identifiable {
        case phrases = "Phrases"
        case mistakes = "Mistakes"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch segment {
                case .phrases: phraseRows
                case .mistakes: mistakeRows
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("My Japanese")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCapture = true } label: { Label("I heard this", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showCapture) {
                QuickCaptureView().presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var phraseRows: some View {
        if phrases.isEmpty {
            ContentUnavailableView("No phrases yet", systemImage: "ear",
                                   description: Text("When you hear Japanese at work, tap “I heard this” to capture it."))
        } else {
            ForEach(PhraseSource.allCases) { source in
                let group = phrases.filter { $0.source == source }
                if !group.isEmpty {
                    Section(source.title) {
                        ForEach(group) { phrase in
                            VStack(alignment: .leading, spacing: 4) {
                                JapaneseTextView(japanese: phrase.japanese, kana: phrase.kana, english: phrase.english, style: .body)
                                if !JapaneseText.containsJapanese(phrase.japanese) {
                                    Label("Add the Japanese spelling to practise this by voice", systemImage: "info.circle")
                                        .font(.caption2).foregroundStyle(Palette.inkSecondary)
                                }
                                if !phrase.note.isEmpty {
                                    Text(phrase.note).font(.caption).foregroundStyle(Palette.inkSecondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(group[index]) }
                            try? context.save()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var mistakeRows: some View {
        if mistakes.isEmpty {
            ContentUnavailableView("No recurring mistakes", systemImage: "checkmark.seal",
                                   description: Text("Mistakes from your sessions appear here, and come back as practice."))
        } else {
            Section("Most frequent first") {
                ForEach(mistakes) { mistake in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(mistake.type.displayName).font(.caption.weight(.semibold)).foregroundStyle(Palette.caution)
                            Spacer()
                            Text("×\(mistake.occurrences)").font(.caption.monospacedDigit()).foregroundStyle(Palette.inkSecondary)
                        }
                        if !mistake.lastSaid.isEmpty {
                            Text(mistake.lastSaid).font(.body).strikethrough(color: Palette.caution.opacity(0.6)).foregroundStyle(Palette.inkSecondary)
                        }
                        Text(mistake.correction).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                        Text(mistake.explanation).font(.footnote).foregroundStyle(Palette.inkSecondary)
                        Text("Last seen \(mistake.lastSeen, format: .relative(presentation: .named))")
                            .font(.caption2).foregroundStyle(Palette.inkSecondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
