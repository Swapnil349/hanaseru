import LearningCore
import SessionCore
import SwiftUI

/// Hosts one session: the live hands-free screen, then the summary.
struct SessionContainerView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    let minutes: Int
    let focus: SessionFocus
    var scene: SceneStart?
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
            let model = SessionViewModel(app: app, minutes: minutes, focus: focus, scene: scene)
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
    @AppStorage(SettingsKey.showRomaji) private var showRomaji = false
    @State private var showTranscript = false
    @State private var scriptParts: [ScriptPart]?

    var body: some View {
        VStack(spacing: 0) {
            header
            LineStripe()
            ScrollView {
                VStack(spacing: 24) {
                    if let stage = model.stage {
                        SceneStageView(stage: stage, voice: model.stageVoice, activity: model.activity,
                                       micLevel: model.micLevel, focus: model.focusInfo, reveal: model.reveal,
                                       partnerLine: model.partnerLine, showEnglish: showEnglish,
                                       onHearPartner: {
                                           guard let line = model.partnerLine else { return }
                                           model.listen(to: [SpeechRequest(text: line.japanese, language: .japanese, rate: 0.9,
                                                                           voice: .partner(stage.partnerGender))])
                                       },
                                       onHearYou: {
                                           if let focus = model.focusInfo { model.listen(to: focus.answerAudio) }
                                       })
                        compactStatus
                    } else {
                        statusVisual
                    }
                    currentLine
                    if let feedback = model.feedback {
                        FeedbackCard(note: feedback)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if showTranscript { transcript }
                }
                .padding(Metrics.padding)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.25), value: model.feedback)
            }
            if let writing = model.writing, writing.isEnabled {
                WritingAnswerPanel(model: model, writing: writing)
                    .padding(.horizontal, Metrics.padding)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
            footer
        }
        .background(Palette.background)
        .sheet(isPresented: Binding(get: { scriptParts != nil }, set: { if !$0 { scriptParts = nil } })) {
            NavigationStack {
                ScriptView(parts: scriptParts ?? [], currentLineID: model.focusInfo?.lineID, currentPart: model.exerciseIndex,
                           onPlay: { requests, slowly in model.listen(to: requests, slowly: slowly) },
                           onStart: { part, line in
                               scriptParts = nil
                               model.move(.to(part: part, line: line))
                           })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { scriptParts = nil }
                                .accessibilityIdentifier("script-done")
                        }
                    }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onEnd) {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("End session")

            VStack(alignment: .leading, spacing: 2) {
                if model.exerciseTotal > 1 && !model.exerciseTitle.isEmpty {
                    Text("Part \(model.exerciseIndex + 1) of \(model.exerciseTotal)")
                        .font(.caption.weight(.semibold)).foregroundStyle(Palette.line)
                }
                Text(model.exerciseTitle.isEmpty ? "Getting ready" : model.exerciseTitle)
                    .font(.headline).foregroundStyle(Palette.ink)
                if !model.stepTitle.isEmpty {
                    Text(model.stepTitle).font(.caption).foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("step-title")
                }
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
                Text("Tap a speaker button to hear a line as often as you like. Play carries on from this line.")
                    .font(.footnote).foregroundStyle(Palette.inkSecondary).multilineTextAlignment(.center)
            case .finished:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Palette.go)
            }
            privacyChip
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status-\(statusName)")
    }

    /// Under the stage: whose turn it is, in one line.
    private var compactStatus: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                switch model.activity {
                case .listening:
                    Image(systemName: "mic.fill").foregroundStyle(Palette.signal)
                    Text("あなたの番です · Your turn").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.signal)
                case .speaking, .preparing:
                    Image(systemName: "ear").foregroundStyle(Palette.line)
                    Text("聞いてください · Listen").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.line)
                case .thinking:
                    ProgressView()
                    Text("Thinking…").font(.subheadline).foregroundStyle(Palette.inkSecondary)
                case .paused:
                    Image(systemName: "pause.circle.fill").foregroundStyle(Palette.inkSecondary)
                    Text("Paused. Tap a bubble or a speaker button to hear a line.")
                        .font(.subheadline).foregroundStyle(Palette.inkSecondary)
                case .finished:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.go)
                }
                Spacer(minLength: 0)
            }
            if model.activity == .listening && !model.partialTranscript.isEmpty {
                Text(model.partialTranscript)
                    .font(.title3)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            privacyChip.frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("status-\(statusName)")
    }

    private var statusName: String {
        switch model.activity {
        case .preparing: "preparing"
        case .speaking: "speaking"
        case .listening: "listening"
        case .thinking: "thinking"
        case .paused: "paused"
        case .finished: "finished"
        }
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

    /// The script card: the English of what to say, as much Japanese as the level allows, then the answer.
    @ViewBuilder
    private var currentLine: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let instruction = model.instruction, !instruction.english.isEmpty, model.focusInfo == nil {
                Text(instruction.english)
                    .font(.callout)
                    .foregroundStyle(Palette.inkSecondary)
            }
            if let focus = model.focusInfo {
                // On a stage, the other person's line is in their speech bubble.
                if !focus.partnerJapanese.isEmpty && model.stage == nil {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            if !focus.partnerName.isEmpty {
                                Text(focus.partnerName).font(.caption.weight(.semibold)).foregroundStyle(Palette.inkSecondary)
                            }
                            JapaneseTextView(japanese: focus.partnerJapanese, kana: focus.partnerKana,
                                             english: focus.partnerEnglish, style: .body, showEnglish: showEnglish)
                        }
                        Spacer(minLength: 0)
                        Button { model.listen(to: focus.promptAudio) } label: {
                            Image(systemName: "speaker.wave.2.fill").font(.body).frame(width: 40, height: 40)
                        }
                        .foregroundStyle(Palette.line)
                        .accessibilityLabel("Hear the question again")
                        .accessibilityIdentifier("hear-question")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
                }
                scriptCard(focus)
            } else if let line = model.spokenLine, !line.japanese.isEmpty {
                JapaneseTextView(japanese: line.japanese, kana: line.kana, english: line.english,
                                 style: .title2, showEnglish: showEnglish)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func scriptCard(_ focus: FocusInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(!focus.heading.isEmpty ? focus.heading : (focus.level == .model ? "LEARN" : "YOUR LINE"))
                    .font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(Palette.line)
                Spacer()
                if focus.heading.isEmpty {
                    Text(focus.level.title).font(.caption2).foregroundStyle(Palette.inkSecondary)
                        .accessibilityIdentifier("line-mask-S\(focus.level.rawValue)")
                }
            }
            Text(focus.cueEn.isEmpty ? focus.english : focus.cueEn)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            if let reveal = model.reveal, reveal.lineID == focus.lineID {
                revealView(reveal)
            } else if focus.answerShown {
                JapaneseTextView(japanese: focus.japanese, kana: focus.kana, romaji: focus.romaji, style: .title2,
                                 showEnglish: false)
            } else if !focus.visibleJapanese.isEmpty {
                Text(focus.visibleJapanese + " " + focus.hiddenPlaceholder)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(Palette.ink)
            } else if model.peekedLineID == focus.lineID {
                JapaneseTextView(japanese: focus.japanese, kana: focus.kana, romaji: focus.romaji, style: .title3,
                                 showEnglish: false)
            } else if !focus.japanese.isEmpty {
                Button("Tap to see the Japanese") { model.peek() }
                    .font(.footnote)
                    .foregroundStyle(Palette.line)
            }
            hearButtons(focus)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.line.opacity(0.06), in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous).stroke(Palette.line.opacity(0.25), lineWidth: 1))
    }

    /// Hear the question (when there is no partner card) and the answer, at natural speed or slowly.
    private func hearButtons(_ focus: FocusInfo) -> some View {
        HStack(spacing: 8) {
            if focus.partnerJapanese.isEmpty && !focus.promptAudio.isEmpty {
                HearButton(title: "Question") { model.listen(to: focus.promptAudio) }
            }
            if !focus.answerAudio.isEmpty {
                HearButton(title: "Answer") { model.listen(to: focus.answerAudio) }
                    .accessibilityIdentifier("hear-answer")
                HearButton(title: "Slowly", systemImage: "tortoise.fill") { model.listen(to: focus.answerAudio, slowly: true) }
            }
        }
        .padding(.top, 2)
    }

    /// After the turn: the full line, what was heard, and which parts were right. No red, no "wrong".
    @ViewBuilder
    private func revealView(_ reveal: RevealInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JapaneseTextView(japanese: reveal.japanese, kana: reveal.kana, romaji: reveal.romaji, style: .title2,
                             showEnglish: false)
            if !reveal.matchedChunks.isEmpty && !reveal.outcome.isClean {
                Text("Right: " + reveal.matchedChunks.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Palette.go)
            }
            if !reveal.heard.isEmpty {
                Text("Heard: " + reveal.heard).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
            if !reveal.note.isEmpty {
                Text(reveal.note).font(.footnote).foregroundStyle(Palette.inkSecondary)
            }
        }
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
            helpBar
            if let timeline = model.timeline, timeline.stops.count > 1 {
                TimelineScrubber(timeline: timeline) { model.move(.seek($0)) }
            }
            AudioControl(isPaused: model.isPaused, onPrevious: { model.move(.previous) }, onAgain: { model.again() },
                         onTogglePause: { model.togglePause() }, onNext: { model.move(.next) })
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Toggle("English", isOn: $showEnglish).toggleStyle(.button).font(.caption)
                        Toggle("Romaji", isOn: $showRomaji).toggleStyle(.button).font(.caption)
                            .accessibilityIdentifier("romaji-toggle")
                        Toggle("Transcript", isOn: $showTranscript).toggleStyle(.button).font(.caption)
                        if let writing = model.writing {
                            Toggle(isOn: Binding(get: { writing.isEnabled }, set: { writing.isEnabled = $0 })) {
                                Label("Write", systemImage: "pencil.tip")
                            }
                            .toggleStyle(.button).font(.caption)
                            .accessibilityIdentifier("writing-toggle")
                        }
                    }
                }
                Button { scriptParts = model.script() } label: {
                    Label("Script", systemImage: "doc.plaintext")
                }
                .buttonStyle(.bordered).font(.caption)
                .accessibilityIdentifier("open-script")
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 12)
        .background(Palette.surface.shadow(.drop(color: .black.opacity(0.06), radius: 8, y: -2)))
    }

    /// Tappable help, each chip showing the Japanese you can also just say (もう一度 and 次へ are on the
    /// buttons below).
    private var helpBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                helpChip("ヒント", "Hint", .hint, id: "help-chip-hint")
                helpChip("答え", "Answer", .answer, id: "help-chip-answer")
                helpChip("ゆっくり", "Slower", .slower, id: "help-chip-slower")
                helpChip("英語で", "English", .english, id: "help-chip-english")
                helpChip("ちょっと待って", "More time", .moreTime, id: "help-chip-wait")
            }
        }
        .scrollClipDisabled()
    }

    private func helpChip(_ ja: String, _ en: String, _ command: VoiceCommand, id: String) -> some View {
        Button {
            model.command(command)
        } label: {
            VStack(spacing: 1) {
                Text(ja).font(.footnote.weight(.semibold))
                Text(en).font(.caption2).foregroundStyle(Palette.inkSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Palette.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ink)
        .accessibilityIdentifier(id)
        .accessibilityLabel("\(en), \(ja)")
    }
}
