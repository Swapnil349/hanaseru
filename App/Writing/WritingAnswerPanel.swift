import PencilKit
import SessionCore
import SwiftUI

/// In a session with writing mode on: write the answer instead of saying it. When a model line is being
/// taught or has just been revealed, it shows faintly on the pad to trace.
struct WritingAnswerPanel: View {
    let model: SessionViewModel
    let writing: WritingInput

    @AppStorage(SettingsKey.kanjiIntensity) private var kanjiIntensity = KanjiIntensity.minimal.rawValue
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var drawing = PKDrawing()
    @State private var reading = false
    @State private var status = ""

    /// The model to trace: only when it's already been given (teaching, or after the answer).
    private var guide: String {
        guard let focus = model.focusInfo else { return "" }
        let revealed = model.reveal.flatMap { $0.lineID == focus.lineID ? $0 : nil }
        guard focus.level == .model || revealed != nil else { return "" }
        let japanese = revealed?.japanese ?? focus.japanese
        let kana = revealed?.kana ?? focus.kana
        return kanjiIntensity == KanjiIntensity.normal.rawValue || kana.isEmpty ? japanese : kana
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(writing.isWaiting ? (guide.isEmpty ? "Write your answer" : "Copy the line") : "Write when it's your turn",
                      systemImage: "pencil.tip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(writing.isWaiting ? Palette.signal : Palette.inkSecondary)
                Spacer()
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                }
            }
            WritingPad(drawing: $drawing, guide: guide, height: sizeClass == .regular ? 300 : 190)
            HStack(spacing: 12) {
                Button("Clear") { drawing = PKDrawing() }
                    .disabled(drawing.strokes.isEmpty)
                Button("Skip") {
                    writing.submit("")
                    drawing = PKDrawing()
                    status = ""
                }
                .disabled(!writing.isWaiting)
                Spacer()
                Button {
                    check()
                } label: {
                    if reading {
                        ProgressView()
                    } else {
                        Label("Check", systemImage: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!writing.isWaiting || drawing.strokes.isEmpty || reading)
                .accessibilityIdentifier("writing-check")
            }
            .font(.subheadline)
        }
        .onChange(of: model.focusInfo?.lineID) {
            drawing = PKDrawing()
            status = ""
        }
    }

    private func check() {
        reading = true
        let current = drawing
        let expected = writing.expected
        Task {
            let text = await HandwritingReader.read(current, expected: expected)
            reading = false
            if text.isEmpty {
                status = "Couldn't read that — try writing a little larger."
            } else {
                status = "Read: \(text)"
                writing.submit(text)
                drawing = PKDrawing()
            }
        }
    }
}
