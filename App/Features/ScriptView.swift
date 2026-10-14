import LearningCore
import SessionCore
import SwiftUI

/// The complete script: every line with its reading and meaning, to read, hear and learn by heart.
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

    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false
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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                let name = speaker(entry)
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
                if let line = entry.startLine, let onStart {
                    Button { onStart(part.index, line) } label: {
                        Label("Practise from here", systemImage: "play.circle")
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                }
            }
            Spacer(minLength: 0)
            Button { onPlay(entry.audio, slowly) } label: {
                Image(systemName: "speaker.wave.2.fill").font(.body).frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.line)
            .accessibilityLabel("Hear this line")
        }
        .padding(.vertical, 4)
        .listRowBackground(isCurrent ? Palette.line.opacity(0.1) : Palette.surface)
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
