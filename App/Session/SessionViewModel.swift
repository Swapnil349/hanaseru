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

    private let app: AppEnvironment
    private var runner: SessionRunner?
    private var tornDown = false

    init(app: AppEnvironment, minutes: Int, focus: SessionFocus) {
        self.app = app
        self.minutes = minutes
        self.focus = focus
    }

    var usesCoach: Bool { app.isCoachConfigured }
    var processingDescription: String { app.voice.recognizer.processingDescription }

    // MARK: - Lifecycle

    func start() async {
        guard runner == nil, phase == .preparing else { return }
        var permitted = VoicePermissions.granted
        if !permitted { permitted = await VoicePermissions.request() }
        guard permitted else {
            phase = .failed("Hanaseru needs microphone and speech recognition access. You can allow them in Settings › Hanaseru.")
            return
        }
        do {
            try app.voice.beginSession()
        } catch {
            phase = .failed("Couldn't start audio: \(error.localizedDescription)")
            return
        }

        let prepared = await SessionPreparer(library: app.library, repository: app.repository)
            .prepare(minutes: minutes, focus: focus)
        let runner = SessionRunner(plan: prepared.plan, library: prepared.library, voice: app.voice.runnerVoice,
                                   ai: app.makeAIProvider(), repository: app.repository)
        runner.onEvent = { [weak self] event in self?.handle(event) }
        self.runner = runner
        wireVoiceControls(to: runner)

        startedAt = Date()
        phase = .running
        runner.start()
    }

    func togglePause() {
        runner?.togglePause()
        isPaused = runner?.isPaused ?? false
        updateNowPlaying()
    }

    func skip() {
        runner?.skip()
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
            feedback = nil
            instruction = nil
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
        case .finished(let summary):
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
        remote.onToggle = { [weak self] in self?.togglePause() }
        remote.onPause = { [weak self] in
            guard let self, !self.isPaused else { return }
            self.togglePause()
        }
        remote.onResume = { [weak self] in
            guard let self, self.isPaused else { return }
            self.togglePause()
        }
        remote.onSkip = { [weak self] in self?.skip() }
        // A phone call or AirPods coming out pauses the session; resuming is the learner's choice.
        app.voice.audioSession.onInterruption = { [weak self] began in
            guard let self, began, !self.isPaused else { return }
            self.togglePause()
        }
        app.voice.audioSession.onRouteLost = { [weak self] in
            guard let self, !self.isPaused else { return }
            self.togglePause()
        }
    }

    private func updateNowPlaying() {
        let status: String = switch activity {
        case .listening: "Your turn"
        case .paused: "Paused"
        case .finished: "Finished"
        default: exerciseTitle
        }
        app.voice.remote.updateNowPlaying(title: "\(minutes) min · \(focus.title)", detail: status, isPaused: isPaused)
    }
}
