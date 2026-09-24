import SwiftUI

/// Bilingual label in the style of station signage: Japanese first, small-caps English beside it.
struct SectionLabel: View {
    let ja: String
    let en: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ja)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(en.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Palette.inkSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(en)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The thin blue line along a Shinkansen's body, used as a quiet accent.
struct LineStripe: View {
    var body: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(height: 3)
            .accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.line

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(tint.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Palette.surfaceMuted.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }
}

/// Large primary action (spec §73: PrimaryButton).
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = Palette.line
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(PrimaryButtonStyle(tint: tint))
    }
}

/// Card container (spec §73: PracticeCard).
struct PracticeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
    }
}

/// Selectable pill, used for time and focus choices.
struct ChoiceChip: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.headline.monospacedDigit())
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(isSelected ? .white.opacity(0.85) : Palette.inkSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 56, minHeight: 52)
            .foregroundStyle(isSelected ? .white : Palette.ink)
            .background(isSelected ? Palette.line : Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isSelected ? .clear : Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Circular progress (spec §73: ProgressRing).
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 4
    var tint: Color = Palette.line

    var body: some View {
        ZStack {
            Circle().stroke(Palette.hairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(progress * 100)) percent"))
    }
}

/// Subtle 1–8 indicator for the internal difficulty model (spec §73). Never framed as a game level.
struct DifficultyIndicator: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...8, id: \.self) { step in
                Capsule()
                    .fill(step <= level ? Palette.line : Palette.hairline)
                    .frame(width: 14, height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Challenge \(level) of 8")
    }
}

/// Elapsed time in a session (spec §73: SessionTimer).
struct SessionTimerView: View {
    let startedAt: Date
    let plannedMinutes: Int

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            Text(String(format: "%d:%02d / %d:00", elapsed / 60, elapsed % 60, plannedMinutes))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

struct MetricTile: View {
    let value: String
    let label: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.footnote).foregroundStyle(Palette.line)
            }
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(Palette.ink)
            Text(label).font(.caption).foregroundStyle(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
