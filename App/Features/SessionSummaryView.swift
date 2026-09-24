import LearningCore
import SessionCore
import SwiftUI

/// End of session: meaningful metrics, what went well, what to practise, one phrase (spec §9, §52, §89).
struct SessionSummaryView: View {
    let summary: SessionSummary
    let onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    LineStripe().frame(width: 36)
                    Text("お疲れさまでした").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                    Text(summary.completedNormally ? "Session complete" : "Session ended early")
                        .font(.largeTitle.weight(.semibold)).foregroundStyle(Palette.ink)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricTile(value: minutes(summary.secondsListening), label: "Japanese heard", systemImage: "ear")
                    MetricTile(value: minutes(summary.secondsSpeaking), label: "You spoke", systemImage: "mic")
                    MetricTile(value: "\(summary.exercisesCompleted)", label: "Exercises", systemImage: "checklist")
                    MetricTile(value: "\(summary.conversationTurns)", label: "Conversation turns", systemImage: "bubble.left.and.bubble.right")
                }

                if !summary.phraseJapanese.isEmpty {
                    PracticeCard {
                        SectionLabel(ja: "今日のフレーズ", en: "One phrase to remember")
                        JapaneseTextView(japanese: summary.phraseJapanese, english: summary.phraseEnglish, style: .title2)
                    }
                }

                if !summary.wentWell.isEmpty {
                    list(title: "What went well", ja: "よくできました", items: summary.wentWell, symbol: "checkmark.circle", tint: Palette.go)
                }
                if !summary.toPractise.isEmpty {
                    list(title: "To practise", ja: "練習しましょう", items: summary.toPractise, symbol: "arrow.clockwise", tint: Palette.signal)
                }
                if !summary.mistakes.isEmpty {
                    PracticeCard {
                        SectionLabel(ja: "気をつけること", en: "Watch out for")
                        ForEach(Array(summary.mistakes.prefix(3).enumerated()), id: \.offset) { _, mistake in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mistake.type.displayName).font(.caption.weight(.semibold)).foregroundStyle(Palette.caution)
                                Text(mistake.explanation).font(.footnote).foregroundStyle(Palette.ink)
                            }
                        }
                    }
                }

                PrimaryButton(title: "Done", action: onDone)
                    .accessibilityIdentifier("summary-done")
            }
            .padding(Metrics.padding)
        }
        .background(Palette.background)
    }

    private func list(title: String, ja: String, items: [String], symbol: String, tint: Color) -> some View {
        PracticeCard {
            SectionLabel(ja: ja, en: title)
            ForEach(items, id: \.self) { item in
                Label { Text(item).foregroundStyle(Palette.ink) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
            }
        }
    }

    private func minutes(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : String(format: "%.1f min", seconds / 60)
    }
}
