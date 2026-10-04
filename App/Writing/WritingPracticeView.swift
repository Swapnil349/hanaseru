import LearningCore
import PencilKit
import SwiftData
import SwiftUI

/// The Write tab: practise writing the lines by hand — trace, copy, then from memory.
struct WritingPracticeView: View {
    @Environment(AppEnvironment.self) private var app
    @Query private var knowledge: [KnowledgeRecord]
    @Query(sort: \PersonalPhraseRecord.createdAt, order: .reverse) private var phrases: [PersonalPhraseRecord]

    /// Phrases practised in sessions first, then My Japanese, then the rest by level.
    private var lines: [LearningItem] {
        let practised = Set(knowledge.map(\.itemID))
        let personal = phrases.filter { JapaneseText.containsJapanese($0.japanese) }.map(\.learningItem)
        let library = app.library.items.filter { $0.listening == nil || !$0.japanese.isEmpty }
        let ordered = library.filter { practised.contains($0.id) } + personal
            + library.filter { !practised.contains($0.id) }.sorted { $0.level < $1.level }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            WritingDrillView(lines: lines, index: index)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.japanese).font(.body).foregroundStyle(Palette.ink)
                                Text(item.english).font(.caption).foregroundStyle(Palette.inkSecondary)
                            }
                        }
                    }
                } footer: {
                    Text("Write with Apple Pencil or a finger. Handwriting is read on this device and never leaves it.")
                }
            }
            .navigationTitle("Write")
        }
    }
}

/// One line at a time: the meaning, the model (faint to trace, beside to copy, or hidden), the pad, Check.
struct WritingDrillView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case trace = "Trace"
        case copy = "Copy"
        case memory = "From memory"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("writingDrillMode") private var modeRaw = Mode.trace.rawValue
    @AppStorage("writingDrillKanji") private var useKanji = false

    let lines: [LearningItem]
    @State var index: Int
    @State private var drawing = PKDrawing()
    @State private var result: String?
    @State private var matched: [Bool] = []
    @State private var reading = false
    @State private var showAnswer = false

    init(lines: [LearningItem], index: Int) {
        self.lines = lines
        _index = State(initialValue: index)
    }

    private var item: LearningItem { lines[index] }
    private var mode: Mode { Mode(rawValue: modeRaw) ?? .trace }
    private var target: String { useKanji ? item.japanese : item.kana }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Mode", selection: $modeRaw) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Kanji", isOn: $useKanji)
                    .font(.subheadline)

                Text(item.english)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if mode == .copy || showAnswer || result != nil {
                    modelLine
                } else if mode == .memory {
                    Button("Show the Japanese") { showAnswer = true }
                        .font(.footnote)
                }

                WritingPad(drawing: $drawing, guide: mode == .trace ? target : "",
                           height: sizeClass == .regular ? 340 : 220)

                HStack(spacing: 12) {
                    Button("Clear") { reset() }
                    Spacer()
                    if result != nil {
                        Button("Next line") { next() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            check()
                        } label: {
                            if reading { ProgressView() } else { Label("Check", systemImage: "checkmark.circle.fill") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(drawing.strokes.isEmpty || reading)
                    }
                }

                if let result {
                    feedback(result)
                }
            }
            .padding(Metrics.padding)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.background)
        .navigationTitle("Line \(index + 1) of \(lines.count)")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: useKanji) { reset() }
    }

    /// The model, with the characters written correctly highlighted after a check.
    private var modelLine: some View {
        var line = AttributedString()
        for (i, character) in target.enumerated() {
            var run = AttributedString(String(character))
            run.foregroundColor = matched.indices.contains(i) ? (matched[i] ? Palette.go : Palette.caution) : Palette.ink
            line += run
        }
        return Text(line)
            .font(.system(size: 30, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(target)
    }

    private func feedback(_ written: String) -> some View {
        let score = matched.isEmpty ? 0 : Double(matched.filter { $0 }.count) / Double(matched.count)
        let headline = score >= 0.95 ? "Well written" : score >= 0.6 ? "Nearly — the orange characters need another look" : "Compare with the model and try again"
        return VStack(alignment: .leading, spacing: 4) {
            Text(headline).font(.headline).foregroundStyle(score >= 0.95 ? Palette.go : Palette.ink)
            Text("Read as: \(written.isEmpty ? "—" : written)").font(.footnote).foregroundStyle(Palette.inkSecondary)
            if score < 0.95 {
                Button("Try this line again") { reset() }.font(.footnote)
            }
        }
    }

    private func check() {
        reading = true
        let current = drawing
        let expected = [target, item.japanese, item.kana]
        Task {
            let written = await HandwritingReader.read(current, expected: expected)
            reading = false
            matched = matchedCharacters(target: target, written: written)
            result = written
            await record(score: matched.isEmpty ? 0 : Double(matched.filter { $0 }.count) / Double(matched.count))
        }
    }

    /// Writing is its own skill in the learner's knowledge; from memory counts most.
    private func record(score: Double) async {
        let grade: ReviewGrade = switch (mode, score) {
        case (.memory, 0.95...): .good
        case (_, 0.95...): .hard
        case (_, 0.6...): .hard
        default: .again
        }
        let now = Date()
        let existing = await app.repository.knowledge(for: [item.id])[item.id] ?? KnowledgeState(itemID: item.id, introducedAt: now)
        await app.repository.save(ReviewScheduler().record(existing, dimension: .writing, grade: grade, at: now))
    }

    private func reset() {
        drawing = PKDrawing()
        result = nil
        matched = []
        showAnswer = false
    }

    private func next() {
        reset()
        index = (index + 1) % lines.count
    }
}
