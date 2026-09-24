import LearningCore
import SessionCore
import SwiftUI

/// Hosts one session: the live hands-free screen, then the summary.
struct SessionContainerView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let minutes: Int
    let focus: SessionFocus
    @State private var model: SessionViewModel?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            if let model {
                switch model.phase {
                case .preparing:
                    ProgressView("Preparing your session…")
                case .running:
                    HandsFreeSessionView(model: model) { model.end() }
                case .finished(let summary):
                    SessionSummaryView(summary: summary) { dismiss() }
                case .failed(let message):
                    failure(message)
                }
            }
        }
        .task {
            let model = SessionViewModel(app: app, minutes: minutes, focus: focus)
            self.model = model
            await model.start()
        }
        .onDisappear { model?.teardown() }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.slash").font(.largeTitle).foregroundStyle(Palette.caution)
            Text(message).multilineTextAlignment(.center).foregroundStyle(Palette.ink)
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).frame(maxWidth: 200)
        }
        .padding(Metrics.padding)
    }
}

/// The screen is secondary (spec §24): large state, current line, feedback. Everything is also spoken.
struct HandsFreeSessionView: View {
    let model: SessionViewModel
    let onEnd: () -> Void

    @AppStorage(SettingsKey.showEnglish) private var showEnglish = true
    @State private var showTranscript = false

    var body: some View {
        VStack(spacing: 0) {
            header
            LineStripe()
            ScrollView {
                VStack(spacing: 24) {
                    statusVisual
                    currentLine
                    if let feedback = model.feedback {
                        FeedbackCard(note: feedback)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if showTranscript { transcript }
                }
                .padding(Metrics.padding)
                .animation(.easeOut(duration: 0.25), value: model.feedback)
            }
            footer
        }
        .background(Palette.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onEnd) {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("End session")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.exerciseTitle.isEmpty ? "Getting ready" : model.exerciseTitle)
                    .font(.headline).foregroundStyle(Palette.ink)
                SessionTimerView(startedAt: model.startedAt, plannedMinutes: model.minutes)
            }
            Spacer()
            if model.exerciseTotal > 0 {
                ProgressRing(progress: Double(model.exerciseIndex) / Double(model.exerciseTotal))
                    .frame(width: 28, height: 28)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(Palette.ink)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusVisual: some View {
        VStack(spacing: 12) {
            switch model.activity {
            case .listening:
                SpeakingIndicator(level: model.micLevel, isListening: true)
                Text("あなたの番です · Your turn").font(.headline).foregroundStyle(Palette.signal)
                if !model.partialTranscript.isEmpty {
                    Text(model.partialTranscript).font(.title3).foregroundStyle(Palette.ink).multilineTextAlignment(.center)
                }
            case .speaking, .preparing:
                WaveformView(isActive: model.activity == .speaking)
                Text("聞いてください · Listen").font(.headline).foregroundStyle(Palette.line)
            case .thinking:
                ProgressView().controlSize(.large).frame(height: 44)
                Text("Thinking…").font(.headline).foregroundStyle(Palette.inkSecondary)
            case .paused:
                Image(systemName: "pause.circle.fill").font(.system(size: 56)).foregroundStyle(Palette.inkSecondary)
                Text("Paused").font(.headline).foregroundStyle(Palette.inkSecondary)
            case .finished:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Palette.go)
            }
            privacyChip
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityElement(children: .combine)
    }

    /// Always shows whether the mic is being transcribed, where, and that nothing is recorded (spec §60).
    private var privacyChip: some View {
        let listening = model.activity == .listening
        return HStack(spacing: 6) {
            Image(systemName: listening ? "mic.fill" : "mic")
            Text(listening ? "\(model.processingDescription) · not recorded" : "Not transcribing · not recorded")
            if model.aiDegraded {
                Text("· offline coach").foregroundStyle(Palette.caution)
            }
        }
        .font(.caption2)
        .foregroundStyle(listening ? Palette.signal : Palette.inkSecondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Palette.surfaceMuted, in: Capsule())
    }

    @ViewBuilder
    private var currentLine: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let instruction = model.instruction, !instruction.english.isEmpty {
                Text(instruction.english)
                    .font(.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
            if let line = model.spokenLine, !line.japanese.isEmpty {
                JapaneseTextView(japanese: line.japanese, kana: line.kana, english: line.english,
                                 style: .title2, showEnglish: showEnglish)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(ja: "会話", en: "Transcript")
            ForEach(model.transcript) { line in
                ConversationBubble(line: line)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            AudioControl(isPaused: model.isPaused, onTogglePause: { model.togglePause() }, onSkip: { model.skip() })
            HStack {
                Toggle("English", isOn: $showEnglish).toggleStyle(.button).font(.caption)
                Toggle("Transcript", isOn: $showTranscript).toggleStyle(.button).font(.caption)
                Spacer()
                Text("Say 「もう一度」 to repeat").font(.caption2).foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 12)
        .background(Palette.surface.shadow(.drop(color: .black.opacity(0.06), radius: 8, y: -2)))
    }
}
