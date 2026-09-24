import LearningCore
import SessionCore
import SwiftUI

/// Japanese text honouring the Kanji Intensity and romaji settings (spec §41, §73: JapaneseText).
struct JapaneseTextView: View {
    let japanese: String
    var kana: String = ""
    var romaji: String = ""
    var english: String = ""
    var style: Font.TextStyle = .title2
    var showEnglish = true

    @AppStorage(SettingsKey.kanjiIntensity) private var intensityRaw = KanjiIntensity.minimal.rawValue
    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false

    private var intensity: KanjiIntensity { KanjiIntensity(rawValue: intensityRaw) ?? .minimal }
    private var hasDistinctKana: Bool { !kana.isEmpty && JapaneseText.normalize(kana) != JapaneseText.normalize(japanese) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch intensity {
            case .off:
                primary(hasDistinctKana ? kana : japanese)
            case .minimal:
                primary(hasDistinctKana ? kana : japanese)
                if hasDistinctKana { secondary(japanese) }
            case .normal:
                primary(japanese)
                if hasDistinctKana { secondary(kana) }
            }
            if showRomaji && !romaji.isEmpty {
                Text(romaji).font(.callout.italic()).foregroundStyle(Palette.inkSecondary)
            }
            if showEnglish && !english.isEmpty {
                Text(english).font(.callout).foregroundStyle(Palette.inkSecondary)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private func primary(_ text: String) -> some View {
        Text(text)
            .font(.system(style, weight: .medium))
            .foregroundStyle(Palette.ink)
            .environment(\.locale, Locale(identifier: "ja_JP"))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func secondary(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.inkSecondary)
            .environment(\.locale, Locale(identifier: "ja_JP"))
    }
}

/// Subtle animated waveform while the coach is speaking (spec §50). The phone can't tap
/// AVSpeechSynthesizer's output, so this is an indicator, not a measurement.
struct WaveformView: View {
    let isActive: Bool
    var tint: Color = Palette.line
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !isActive || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<24, id: \.self) { index in
                    let phase = t * 5 + Double(index) * 0.55
                    let height = isActive && !reduceMotion
                        ? 8 + 26 * abs(sin(phase) * cos(phase * 0.37 + Double(index)))
                        : 6
                    Capsule().fill(tint.opacity(isActive ? 0.9 : 0.3)).frame(width: 4, height: height)
                }
            }
            .frame(height: 44)
        }
        .accessibilityHidden(true)
    }
}

/// Pulsing ring driven by the microphone level while it's the learner's turn (spec §50).
struct SpeakingIndicator: View {
    let level: Float
    let isListening: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Palette.signal.opacity(0.15))
                .scaleEffect(isListening ? 1 + CGFloat(level) * 0.6 : 0.9)
                .animation(.easeOut(duration: 0.12), value: level)
            Circle()
                .fill(isListening ? Palette.signal : Palette.hairline)
                .frame(width: 72, height: 72)
            Image(systemName: "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 140, height: 140)
        .accessibilityElement()
        .accessibilityLabel(isListening ? "Listening. Your turn to speak." : "Microphone idle")
    }
}

/// A line in the session transcript (spec §73: ConversationBubble).
struct ConversationBubble: View {
    let line: ScriptLine

    var body: some View {
        switch line.role {
        case .learner:
            HStack {
                Spacer(minLength: 40)
                Text(line.japanese)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Palette.line, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .accessibilityLabel("You said: \(line.japanese)")
        case .partner(let name):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if !name.isEmpty {
                        Text(name).font(.caption.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                    }
                    JapaneseTextView(japanese: line.japanese, kana: line.kana, english: line.english, style: .body)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
                Spacer(minLength: 40)
            }
        case .coach, .instruction:
            JapaneseTextView(japanese: line.japanese, kana: line.kana, english: line.english, style: .footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Result of one attempt (spec §73: FeedbackCard). Communication first (spec §75).
struct FeedbackCard: View {
    let note: FeedbackNote

    private var tint: Color {
        switch note.verdict {
        case .natural, .acceptable: Palette.go
        case .understandable, .contextuallyInappropriate: Palette.signal
        case .incorrect, .unclear, .noResponse: Palette.caution
        }
    }

    private var symbol: String {
        switch note.verdict {
        case .natural, .acceptable: "checkmark.circle.fill"
        case .understandable, .contextuallyInappropriate: "bubble.left.and.text.bubble.right.fill"
        case .incorrect: "arrow.uturn.backward.circle.fill"
        case .unclear, .noResponse: "ear"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(note.headline, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            if !note.heard.isEmpty {
                Text("Heard: \(note.heard)").font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
            if !note.suggestion.isEmpty {
                Text(note.suggestion).font(.title3.weight(.medium)).foregroundStyle(Palette.ink)
            }
            if !note.detail.isEmpty {
                Text(note.detail).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Session transport controls (spec §73: AudioControl).
struct AudioControl: View {
    let isPaused: Bool
    let onTogglePause: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onTogglePause) {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(PrimaryButtonStyle(tint: isPaused ? Palette.go : Palette.line))

            Button(action: onSkip) {
                Label("Skip", systemImage: "forward.end.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: 120)
        }
    }
}
