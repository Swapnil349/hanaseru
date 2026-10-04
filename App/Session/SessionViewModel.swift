import ConversationCore
import LearningCore
import SessionCore
import SwiftUI

/// Bridges a `SessionRunner` to SwiftUI and to the iOS voice engine.
@Observable
@MainActor
final class SessionViewModel {
    enum Phase: Equatable {
        case preparing
        case running
        case finished(SessionSummary)
        case failed(String)
    }

    let minutes: Int
    let focus: SessionFocus

    private(set) var phase: Phase = .preparing
    private(set) var activity: SessionActivity = .preparing
    private(set) var exerciseTitle = ""
    private(set) var exerciseIndex = 0
    private(set) var exerciseTotal = 0
    /// The step inside the current part ("Step 2 of 3 · Practise your lines").
    private(set) var stepTitle = ""
    /// The latest Japanese the learner heard (partner or coach).
    private(set) var spokenLine: ScriptLine?
    /// The English task or scene, when there is one.
    private(set) var instruction: ScriptLine?
    /// Partner, learner and revealed lines, for the scrollable transcript.
    private(set) var transcript: [ScriptLine] = []
    private(set) var partialTranscript = ""
    private(set) var feedback: FeedbackNote?
    private(set) var aiDegraded = false
    private(set) var micLevel: Float = 0
    private(set) var startedAt = Date()
    private(set) var isPaused = false
    /// What the learner is being asked to say right now (English cue, how much Japanese to show).
    private(set) var focusInfo: FocusInfo?
    /// The answer after the latest turn.
    private(set) var reveal: RevealInfo?
    /// Think time for the current listen, for the think ring.
    private(set) var thinkSeconds: Double = 0
    private(set) var listenStartedAt = Date()
    /// The line whose hidden Japanese the learner tapped to see (it counts as help for that turn).
    private(set) var peekedLineID: String?

    private let app: AppEnvironment
    private var runner: SessionRunner?
    private var tornDown = false
    private var pausedByInterruption = false
    /// Scripted voice for Simulator/CI runs (see `DemoVoice`).
    private let demo = DemoVoice.isEnabled

    init(app: AppEnvironment, minutes: Int, focus: SessionFocus) {
        self.app = app
        self.minutes = minutes
        self.focus = focus
    }

    var usesCoach: Bool { app.isCoachConfigured }
    var processingDescription: String { demo ? "Demo voice" : app.voice.recognizer.processingDescription }

    // MARK: - Lifecycle

    func start() async {
        guard runner == nil, phase == .preparing else { return }
        if !demo { guard await startRealVoice() else { return } }

        let prepared = await SessionPreparer(library: app.library, repository: app.repository)
            .prepare(minutes: minutes, focus: focus)
        let voice = demo ? DemoVoice.makeVoice() : app.voice.runnerVoice
        // The hands-free help words are taught once, in the first session of 5 minutes or more.
        let teachHelp = minutes >= 5 && !UserDefaults.standard.bool(forKey: SettingsKey.helpOnboardingDone)
        let runner = SessionRunner(plan: prepared.plan, library: prepared.library, voice: voice,
                                   ai: app.makeAIProvider(), repository: app.repository,
                                   options: SessionOptions(includeHelpOnboarding: teachHelp))
        runner.onEvent = { [weak self] event in self?.handle(event) }
        self.runner = runner
        if !demo { wireVoiceControls(to: runner) }

        startedAt = Date()
        phase = .running
        runner.start()
    }

    /// Permissions, audio session and microphone engine. Returns false (and sets `.failed`) if unavailable.
    private func startRealVoice() async -> Bool {
        var permitted = VoicePermissions.granted
        if !permitted { permitted = await VoicePermissions.request() }
        guard permitted else {
            phase = .failed("Hanaseru needs microphone and speech recognition access. You can allow them in Settings › Hanaseru.")
            return false
        }
        do {
            try app.voice.beginSession()
            return true
        } catch {
            phase = .failed("Couldn't start audio: \(error.localizedDescription)")
            return false
        }
    }

    func togglePause(reason: String = "pause button") {
        // Coming back from a call or an AirPods switch: make sure the audio session and mic run again.
        if isPaused && !demo { app.voice.recover() }
        runner?.togglePause()
        isPaused = runner?.isPaused ?? false
        VoiceLog.add("\(isPaused ? "paused" : "resumed") by \(reason)")
        updateNowPlaying()
    }

    func skip() {
        runner?.skip()
    }

    /// Help bar: ヒント, 答え, もう一度, ゆっくり, 英語で, スキップ.
    func command(_ command: VoiceCommand) {
        runner?.command(command)
    }

    /// AirPods "next": the answer during the learner's turn, otherwise skip.
    func answerAndNext() {
        runner?.answerAndNext()
    }

    /// Shows the hidden Japanese of the current line.
    func peek() {
        guard let lineID = focusInfo?.lineID else { return }
        peekedLineID = lineID
        runner?.notePeek()
    }

    func end() {
        if let runner, !runner.isFinished {
            runner.stop()
        } else {
            teardown()
        }
    }

    /// Called when the session screen goes away.
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        if let runner, !runner.isFinished { runner.stop() }
        guard !demo else { return }
        app.voice.onMicLevel = nil
        app.voice.endSession()
    }

    // MARK: - Events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .activity(let activity):
            self.activity = activity
            isPaused = activity == .paused
            if activity == .listening { partialTranscript = "" }
            updateNowPlaying()
        case .exerciseStarted(let index, let total, _, let title):
            exerciseIndex = index
            exerciseTotal = total
            exerciseTitle = title
            stepTitle = ""
            VoiceLog.add("part \(index + 1) of \(total): \(title)")
            feedback = nil
            instruction = nil
            focusInfo = nil
            reveal = nil
            updateNowPlaying()
        case .line(let line):
            switch line.role {
            case .coach:
                spokenLine = line
            case .partner:
                spokenLine = line
                transcript.append(line)
            case .learner:
                partialTranscript = ""
                transcript.append(line)
            case .instruction:
                instruction = line
                if !line.japanese.isEmpty && !line.english.isEmpty { transcript.append(line) }
            }
        case .partialTranscript(let text):
            partialTranscript = text
        case .feedback(let note):
            feedback = note
        case .aiDegraded(let degraded):
            aiDegraded = degraded
        case .focus(let info):
            peekedLineID = nil
            focusInfo = info
            reveal = nil
            feedback = nil
            updateNowPlaying()
        case .reveal(let info):
            reveal = info
            updateNowPlaying()
        case .turnWindow(let seconds, _):
            thinkSeconds = seconds
            listenStartedAt = Date()
        case .step(let title):
            stepTitle = title
            if !title.isEmpty { VoiceLog.add("step: \(title)") }
        case .finished(let summary):
            if summary.completedNormally && minutes >= 5 {
                UserDefaults.standard.set(true, forKey: SettingsKey.helpOnboardingDone)
            }
            phase = .finished(summary)
            teardown()
        }
    }

    private func wireVoiceControls(to runner: SessionRunner) {
        app.voice.onMicLevel = { [weak self] level in
            guard let self, self.activity == .listening else { return }
            self.micLevel = level
        }
        let remote = app.voice.remote
        remote.onToggle = { [weak self] in self?.togglePause(reason: "headphone play/pause") }
        remote.onPause = { [weak self] in
            guard let self, !self.isPaused else { return }
            self.togglePause(reason: "headphone pause")
        }
        remote.onResume = { [weak self] in
            guard let self, self.isPaused else { return }
            self.togglePause(reason: "headphone play")
        }
        remote.onSkip = { [weak self] in self?.answerAndNext() }
        remote.onPrevious = { [weak self] in self?.command(.repeatPrompt) }
        // A call or Siri pauses the session and it carries on by itself afterwards when iOS says so.
        // AirPods coming out pauses it until the learner presses play.
        app.voice.audioSession.onInterruption = { [weak self] event in
            guard let self else { return }
            switch event {
            case .began:
                guard !self.isPaused else { return }
                self.pausedByInterruption = true
                self.togglePause(reason: "audio interruption")
            case .ended(let shouldResume):
                guard self.isPaused, self.pausedByInterruption else { return }
                self.pausedByInterruption = false
                if shouldResume { self.togglePause(reason: "end of interruption") }
            }
        }
        app.voice.audioSession.onRouteLost = { [weak self] in
            guard let self, !self.isPaused else { return }
            self.togglePause(reason: "headphones disconnected")
        }
    }

    /// The lock screen shows the current English cue, so a glance is enough even with the phone locked.
    private func updateNowPlaying() {
        guard !demo else { return }
        let status: String = switch activity {
        case .listening: "Your turn"
        case .paused: "Paused"
        case .finished: "Finished"
        default: exerciseTitle
        }
        let title = focusInfo?.cueEn.isEmpty == false ? (focusInfo?.cueEn ?? "") : "\(minutes) min · \(focus.title)"
        let detail = reveal.map { "\($0.japanese) · \(status)" } ?? status
        app.voice.remote.updateNowPlaying(title: title, detail: detail, isPaused: isPaused)
    }
}
