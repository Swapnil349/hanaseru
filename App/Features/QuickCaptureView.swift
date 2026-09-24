import LearningCore
import SwiftUI

/// "I heard this" (spec §13–14): capture a phrase from work in under ten seconds.
///
/// M1 saves what you type (Japanese, kana or romaji — whatever you caught). M2 adds dictation and an
/// AI lookup that proposes the likely phrase, meaning and related expressions.
struct QuickCaptureView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var japanese = ""
    @State private var english = ""
    @State private var note = ""
    @State private var source: PhraseSource = .heard
    @State private var track: Track = .work
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did you hear? e.g. 工程, こうてい, kōtei", text: $japanese, axis: .vertical)
                        .focused($focused)
                        .font(.title3)
                    TextField("Meaning, if you know it", text: $english)
                } footer: {
                    Text("Write it however you caught it. It becomes part of your practice sessions.")
                }
                Section {
                    Picker("Type", selection: $source) {
                        ForEach(PhraseSource.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Track", selection: $track) {
                        Text("Work").tag(Track.work)
                        Text("Everyday").tag(Track.everyday)
                    }
                    TextField("Where / who said it (optional)", text: $note)
                }
            }
            .navigationTitle("I heard this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let text = japanese.trimmingCharacters(in: .whitespacesAndNewlines)
                        app.repository.addPhrase(japanese: text, kana: "", english: english.trimmingCharacters(in: .whitespaces),
                                                 note: note, source: source, track: track)
                        dismiss()
                    }
                    .disabled(japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
