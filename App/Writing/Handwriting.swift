import LearningCore
import Observation
import PencilKit
import SwiftUI
import Vision

/// Writing instead of speaking (iPad and Apple Pencil, or a finger on iPhone).
///
/// While writing mode is on, the session's "listen" waits for a written answer instead of the microphone;
/// the pad hands over what was written with `submit`. Handwriting is read on the device by Vision and never
/// leaves it.
@Observable
@MainActor
final class WritingInput {
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: SettingsKey.writingMode) }
    }
    /// A listen is open: the coach is waiting for the written answer.
    private(set) var isWaiting = false
    /// What the answer could be (model first), to read untidy handwriting of the right answer.
    private(set) var expected: [String] = []
    private var submission: String?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: SettingsKey.writingMode)
    }

    func begin(expected: [String]) {
        self.expected = expected
        submission = nil
        isWaiting = true
    }

    func end() {
        isWaiting = false
    }

    /// The written answer; empty means "skip writing this one".
    func submit(_ text: String) {
        guard isWaiting else { return }
        submission = text
    }

    func take() -> String? {
        defer { submission = nil }
        return submission
    }
}

/// Reads Japanese handwriting with Vision.
enum HandwritingReader {
    /// The best reading of `drawing`. Among Vision's guesses for each written line it keeps the one closest
    /// to the expected answers, which makes the right answer readable even when written untidily.
    static func read(_ drawing: PKDrawing, expected: [String]) async -> String {
        guard !drawing.strokes.isEmpty, let image = render(drawing) else { return "" }
        let lines = await Task.detached(priority: .userInitiated) { () -> [[String]] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ja-JP"]
            request.usesLanguageCorrection = true
            request.customWords = Array(expected.prefix(50))
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return []
            }
            // Top to bottom, then left to right.
            let observations = (request.results ?? []).sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.05
                    ? a.boundingBox.midY > b.boundingBox.midY
                    : a.boundingBox.minX < b.boundingBox.minX
            }
            return observations.map { $0.topCandidates(5).map(\.string) }
        }.value

        var text = ""
        for candidates in lines {
            guard let first = candidates.first else { continue }
            guard !expected.isEmpty else {
                text += first
                continue
            }
            let best = candidates.max { a, b in
                JapaneseText.bestSimilarity(text + a, to: expected) < JapaneseText.bestSimilarity(text + b, to: expected)
            } ?? first
            text += best
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Black ink on white, whatever the screen's appearance, with a margin.
    private static func render(_ drawing: PKDrawing) -> CGImage? {
        let bounds = drawing.bounds.insetBy(dx: -30, dy: -30)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: bounds, scale: 2)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        return image.cgImage
    }
}

/// A PencilKit canvas. Black ink on a paper-coloured pad so it reads the same in dark mode.
struct HandwritingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 7)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if drawing.wrappedValue != canvasView.drawing { drawing.wrappedValue = canvasView.drawing }
        }
    }
}

/// The writing pad: a faint guide to trace (optional), the canvas, and Clear.
struct WritingPad: View {
    @Binding var drawing: PKDrawing
    var guide: String = ""
    var height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.98))
            // Writing lines.
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Spacer()
                    Rectangle().fill(Color.gray.opacity(0.15)).frame(height: 1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            if !guide.isEmpty {
                Text(guide)
                    .font(.system(size: min(96, height / 2.2)))
                    .minimumScaleFactor(0.2)
                    .lineLimit(2)
                    .foregroundStyle(Color.gray.opacity(0.22))
                    .padding(20)
                    .allowsHitTesting(false)
            }
            HandwritingCanvas(drawing: $drawing)
        }
        .frame(height: height)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        .environment(\.colorScheme, .light)
        .accessibilityIdentifier("writing-pad")
    }
}

/// Characters of `target` that appear, in order, in what was written (longest common subsequence),
/// so the right ones can be highlighted.
func matchedCharacters(target: String, written: String) -> [Bool] {
    let a = Array(target)
    let b = Array(JapaneseText.normalize(written))
    let aNormalized = a.map { JapaneseText.normalize(String($0)) }
    var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            table[i][j] = !aNormalized[i].isEmpty && aNormalized[i] == String(b[j])
                ? table[i + 1][j + 1] + 1
                : max(table[i + 1][j], table[i][j + 1])
        }
    }
    var matched = Array(repeating: false, count: a.count)
    var i = 0, j = 0
    while i < a.count && j < b.count {
        if !aNormalized[i].isEmpty && aNormalized[i] == String(b[j]) {
            matched[i] = true
            i += 1
            j += 1
        } else if table[i + 1][j] >= table[i][j + 1] {
            i += 1
        } else {
            j += 1
        }
    }
    // Punctuation never needs writing.
    for index in a.indices where aNormalized[index].isEmpty { matched[index] = true }
    return matched
}
