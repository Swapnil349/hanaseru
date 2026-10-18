import LearningCore
import SwiftUI

/// A line whose words can be looked at one by one.
struct WordsLine: Hashable {
    var title: String
    var japanese: String
    var english: String
}

/// "Words": opens the meaning of every word in one or more lines. Hidden when none of them has a word list.
struct WordsButton: View {
    @Environment(AppEnvironment.self) private var app
    let lines: [WordsLine]
    /// Called as the list opens (a session pauses so you can read).
    var onOpen: (() -> Void)?
    var bordered = false
    @State private var showing = false

    private var available: [WordsLine] {
        lines.filter { !$0.japanese.isEmpty && !app.library.words(in: $0.japanese).isEmpty }
    }

    var body: some View {
        if !available.isEmpty {
            Group {
                if bordered {
                    Button { open() } label: { Label("Words", systemImage: "character.book.closed") }
                        .buttonStyle(.bordered)
                } else {
                    HearButton(title: "Words", systemImage: "character.book.closed") { open() }
                }
            }
            .accessibilityIdentifier("words")
            .accessibilityHint("Shows the meaning of each word")
            .sheet(isPresented: $showing) {
                WordsSheet(lines: available)
            }
        }
    }

    private func open() {
        onOpen?()
        showing = true
    }
}

/// Each word of the lines in order: the Japanese, its reading, and what it means here. Tap a word to hear it.
struct WordsSheet: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let lines: [WordsLine]

    var body: some View {
        NavigationStack {
            List {
                ForEach(lines, id: \.self) { line in
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.japanese).font(.title3.weight(.medium)).foregroundStyle(Palette.ink)
                            if !line.english.isEmpty {
                                Text(line.english).font(.callout).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                        .padding(.vertical, 2)
                        ForEach(Array(app.library.words(in: line.japanese).enumerated()), id: \.offset) { _, word in
                            Button { SayJapanese.play(word.ja) } label: { row(word) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text(line.title).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ word: WordGloss) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(word.ja).font(.title3).foregroundStyle(Palette.ink)
                Text(word.kana == word.ja ? word.romaji : "\(word.kana) · \(word.romaji)")
                    .font(.caption).foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            Text(word.en)
                .font(.callout)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Says the word")
    }
}
