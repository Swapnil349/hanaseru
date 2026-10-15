import Foundation
import LearningCore
import ConversationCore

/// A scene broken into segments, one per line and step, so that pause, ⏮, ↺ and ⏭ work one line at a
/// time and a paused scene carries on from the same line instead of starting again. The scrubber has two
/// stops per segment: its question and its answer.
struct SceneState {
    enum Segment: Equatable {
        /// The scene's title (in a full lesson also the situation and the three steps).
        case intro
        /// Both characters act out one exchange at a natural pace, with nothing explained.
        case watch(Int)
        /// Step 1: one exchange of the screenplay, with the learner's line in English and Japanese.
        case listen(Int)
        /// Step 2: one of the learner's lines, repeated after the model.
        case practise(Int)
        /// Step 3: the partner speaks and the learner answers.
        case perform(Int)
        /// The partner's closing line.
        case ending
    }

    /// Where a stop of the scrubber plays from.
    struct StopTarget {
        var segment: Int
        var answer: Bool
    }

    let scenario: Scenario
    let persona: Persona
    /// The learner's lines being practised, from `start` on.
    let lines: [PracticeLine]
    /// Where `lines` begins in the scene (a scene can start at any line).
    let start: Int
    /// Resolved once (never `.automatic`), so a resumed scene keeps its steps.
    let mode: SceneMode
    let segments: [Segment]
    /// The learner plays the colleague; `lines` are the colleague's.
    let swapped: Bool
    let stops: [SessionTimeline.Stop]
    let targets: [StopTarget]
    /// How the learner's last answer in the conversation went: the partner reacts to a good one.
    var lastOutcome: TurnOutcome?

    init(scenario: Scenario, persona: Persona, lines: [PracticeLine], start: Int, mode: SceneMode, swapped: Bool = false) {
        self.scenario = scenario
        self.persona = persona
        self.lines = lines
        self.start = start
        self.mode = mode
        self.swapped = swapped
        var segments: [Segment] = [.intro]
        // Before any practice, the characters act out the whole conversation: the English is in the
        // bubbles, so it isn't explained line by line.
        if mode == .fullLesson || mode == .practiseLines || mode == .watch {
            segments += lines.indices.map { Segment.watch($0) }
        }
        if mode == .fullLesson || mode == .practiseLines {
            segments += lines.indices.map { Segment.practise($0) }
        }
        if mode != .watch {
            segments += lines.indices.map { Segment.perform($0) }
        }
        segments.append(.ending)
        self.segments = segments

        var stops: [SessionTimeline.Stop] = []
        var targets: [StopTarget] = []
        for (position, segment) in segments.enumerated() {
            switch segment {
            case .intro:
                stops.append(SessionTimeline.Stop(step: "Start", line: nil, isAnswer: false, japanese: scenario.titleJa))
                targets.append(StopTarget(segment: position, answer: false))
            case .watch(let index), .listen(let index), .practise(let index), .perform(let index):
                let line = lines[index]
                let step = Self.stepName(segment)
                stops.append(SessionTimeline.Stop(step: step, line: start + index + 1, isAnswer: false,
                                                  japanese: line.partner?.japanese ?? ""))
                targets.append(StopTarget(segment: position, answer: false))
                stops.append(SessionTimeline.Stop(step: step, line: start + index + 1, isAnswer: true, japanese: line.japanese))
                targets.append(StopTarget(segment: position, answer: true))
            case .ending:
                stops.append(SessionTimeline.Stop(step: "End", line: nil, isAnswer: false, japanese: scenario.closingLine))
                targets.append(StopTarget(segment: position, answer: false))
            }
        }
        self.stops = stops
        self.targets = targets
    }

    static func stepName(_ segment: Segment) -> String {
        switch segment {
        case .intro: "Start"
        case .watch: "Watch"
        case .listen: "Listen"
        case .practise: "Practise"
        case .perform: "Conversation"
        case .ending: "End"
        }
    }

    /// The scrubber stop for a segment, at its question or its answer.
    func stop(segment: Int, answer: Bool) -> Int {
        targets.firstIndex { $0.segment == segment && $0.answer == answer }
            ?? targets.firstIndex { $0.segment == segment } ?? 0
    }

    /// The segment for a line of the scene (`line` counts from the scene's first line): in the step being
    /// played now, or the first step that has it.
    func segmentIndex(forLine line: Int, near cursor: Int) -> Int? {
        let index = line - start
        guard lines.indices.contains(index) else { return nil }
        let current = segments.indices.contains(cursor) ? segments[cursor] : .intro
        let wanted: [Segment]
        switch current {
        case .watch: wanted = [.watch(index), .listen(index), .practise(index), .perform(index)]
        case .intro, .listen: wanted = [.listen(index), .practise(index), .perform(index), .watch(index)]
        case .practise: wanted = [.practise(index), .perform(index)]
        case .perform, .ending: wanted = [.perform(index), .watch(index)]
        }
        for segment in wanted {
            if let found = segments.firstIndex(of: segment) { return found }
        }
        return nil
    }
}

/// The scene, GABA-style: hear the whole screenplay with English, practise each line, then perform it.
extension SessionRunner {
    /// `startLine` (a line chosen in the script) starts the scene at that line.
    func runConversation(scenarioID: String, maxTurns: Int, startLine: Int? = nil) async throws {
        if sceneState == nil {
            guard let state = await makeSceneState(scenarioID: scenarioID, maxTurns: maxTurns) else { return }
            try Task.checkCancellation()
            sceneState = state
            segmentCount = state.segments.count
            cursor = startLine.flatMap { state.segmentIndex(forLine: $0, near: 0) } ?? 0
            if !scenarioIDs.contains(state.scenario.id) { scenarioIDs.append(state.scenario.id) }
        }
        if let state = sceneState {
            emit(.stage(StageInfo(scenarioID: state.scenario.id, place: state.scenario.placeEn ?? "",
                                  partnerID: state.persona.id, partnerName: state.persona.nameEn,
                                  partnerGender: state.persona.voiceGender, learnerName: learner.name,
                                  learnerPlaysPartner: state.swapped)))
        }
        while let state = sceneState, cursor < state.segments.count {
            // After its one explanation, the scene is in Japanese.
            japaneseOnly = state.segments[cursor] != .intro
            try await playSegment(state.segments[cursor], of: state, fromAnswer: answerFirst)
            // A move made while the segment was ending has already set the place.
            try Task.checkCancellation()
            cursor += 1
            answerFirst = false
        }
    }

    private func makeSceneState(scenarioID: String, maxTurns: Int) async -> SceneState? {
        guard let scenario = library.scenario(id: scenarioID), let persona = library.persona(id: scenario.personaID) else { return nil }
        let swapped = options.playAsPartner
        let all = swapped ? library.partnerSideLines(in: scenario, learnerName: learner.name)
            : library.lines(in: scenario, learnerName: learner.name)
        guard !all.isEmpty else { return nil }
        // A scene can start at any beat; playing the colleague, that's their first line from that beat on.
        let beat = max(0, options.sceneStartBeat)
        let first = swapped ? scenario.beats.prefix(beat).filter { !$0.line.isEmpty }.count : beat
        let start = min(first, all.count - 1)
        let lines = Array(all.dropFirst(start).prefix(swapped ? all.count : max(1, maxTurns)))
        // A scene already practised goes straight to the conversation: no explanations.
        var mode = options.sceneMode
        if mode == .automatic {
            let known = await repository.knowledge(for: all.map(\.id))
            mode = known.values.contains { $0.state(.spokenRecall).reviews > 0 } ? .conversationOnly : .fullLesson
        }
        return SceneState(scenario: scenario, persona: persona, lines: lines, start: start, mode: mode, swapped: swapped)
    }

    /// Moves the scrubber to the segment being played, at its question or its answer.
    private func showPlace(answer: Bool) {
        guard let state = sceneState else { return }
        emit(.timeline(SessionTimeline(stops: state.stops, position: state.stop(segment: cursor, answer: answer))))
    }

    /// `fromAnswer`: chosen on the scrubber — skip the question and go straight to the learner's line.
    private func playSegment(_ segment: SceneState.Segment, of state: SceneState, fromAnswer: Bool) async throws {
        let full = state.mode == .fullLesson
        showPlace(answer: fromAnswer)
        switch segment {
        case .intro:
            emit(.line(ScriptLine(role: .instruction, japanese: state.scenario.titleJa, english: state.scenario.situationEn)))
            try await coach(.sceneIntro, ["title": state.scenario.title])
            if state.swapped {
                emit(.line(ScriptLine(role: .instruction, japanese: "", english: "You play \(state.persona.nameEn).")))
                try await speakMixed("This time you play \(state.persona.nameEn).")
            }
            if full {
                try await speakMixed(state.scenario.situationEn)
                try await coach(.sceneSteps)
            }

        case .watch(let index):
            // Both characters act out the exchange at a natural pace; the bubbles carry the meaning.
            let line = state.lines[index]
            emit(.step(full ? "Step 1 of 3 · Watch the conversation" : "Watch the conversation"))
            emit(.focus(focusInfo(line, level: .model)))
            if !fromAnswer {
                if index == 0 { try await coach(full ? .listenFirst : .watchScene) }
                if let partner = line.partner {
                    let rate = TurnTiming.partnerRate(level: .intent, profile: learner.difficulty,
                                                      personaRate: state.persona.speakingRate)
                    try await partnerSays(partner, rate: rate)
                }
            }
            showPlace(answer: true)
            try await sayModel(line, rate: 0.95, pauseAfter: 0.7)

        case .listen(let index):
            // Step 1 — screenplay: both roles, with the learner's line given in English and Japanese.
            let line = state.lines[index]
            emit(.step("Step 1 of 3 · Line by line, with the meaning"))
            emit(.focus(focusInfo(line, level: .model)))
            if !fromAnswer {
                if index == 0 { try await coach(.lineByLine) }
                if let partner = line.partner {
                    try await partnerSays(partner, rate: 0.9)
                    try await speak(partner.english, .english, pauseAfter: 0.3)
                }
            }
            showPlace(answer: true)
            if index == 0 && state.start == 0 && state.scenario.roleReversal {
                try await coach(.youStart, ["english": line.english])
            } else {
                try await coach(.youLine, ["english": line.english])
            }
            try await sayModel(line, rate: 0.9, pauseAfter: 0.6)
            exposed.insert(line.id)

        case .practise(let index):
            // Step 2 — the partner's line, the meaning, the model, one echo.
            let line = state.lines[index]
            emit(.step(full ? "Step 2 of 3 · Practise your lines" : "Practise your lines"))
            emit(.focus(focusInfo(line, level: .model)))
            if !fromAnswer {
                if index == 0 { try await coach(full ? .rehearseStart : .rehearseShort) }
                if let partner = line.partner { try await partnerSays(partner, rate: 0.9) }
            }
            showPlace(answer: true)
            try await coach(.youSay, ["english": line.english])
            try await sayModel(line, rate: 0.85)
            _ = try await runEcho(line, window: 5, silentNote: false)
            exposed.insert(line.id)

        case .perform(let index):
            // Step 3 — the partner speaks, a whispered cue, the learner says the line.
            let line = state.lines[index]
            emit(.step(full ? "Step 3 of 3 · The real conversation" : "The conversation"))
            // A practised learner gets as little help as their history allows; the first time, the English cue.
            let stored = await entryLevel(for: line)
            let level: ScaffoldLevel = full ? .cued : max(.cued, stored ?? .cued)
            emit(.focus(focusInfo(line, level: level)))
            if fromAnswer {
                // Straight to the answer: hear it and say it once. Nothing is asked, so nothing is graded.
                emit(.reveal(RevealInfo(lineID: line.id, japanese: line.japanese, kana: line.kana, english: line.english,
                                        heard: "", outcome: .skipped, romaji: line.romaji)))
                try await coach(.youCouldSay)
                try await sayModel(line, rate: 0.85)
                _ = try await runEcho(line, window: 5, silentNote: false)
                exposed.insert(line.id)
                sceneState?.lastOutcome = nil
                return
            }
            if index == 0 {
                let youStart = state.lines[0].partner == nil
                if full {
                    try await coach(youStart ? .performYouStart : .performStart, youStart ? [:] : ["name": state.persona.nameEn])
                } else {
                    try await coach(youStart ? .goYouShort : .goShort, ["name": state.persona.nameEn])
                }
            }
            let rate = TurnTiming.partnerRate(level: level, profile: learner.difficulty, personaRate: state.persona.speakingRate)
            if let partner = line.partner {
                var prefix = ""
                if index > 0, sceneState?.lastOutcome?.communicated ?? false {
                    prefix = OfflineAIProvider.reaction(for: .acceptable, turn: index, nextLine: partner.japanese).ja
                }
                try await partnerSays(partner, rate: rate, prefix: prefix)
            }
            showPlace(answer: true)
            var outcome: TurnOutcome?
            if stored == nil && !exposed.contains(line.id) {
                // Never practised and the lesson was skipped: teach it here rather than ask for it.
                try await runIntroduce(line, contextSpoken: true)
            } else {
                outcome = try await runSayIt(line, level: level, mode: .perform, contextSpoken: true, kind: .conversation)
            }
            sceneState?.lastOutcome = outcome
            conversationTurns += 1

        case .ending:
            // Playing the colleague, the closing line was the learner's own last line.
            if !state.scenario.closingLine.isEmpty && !state.swapped {
                let rate = TurnTiming.partnerRate(level: .cued, profile: learner.difficulty, personaRate: state.persona.speakingRate)
                try await partnerSays(state.scenario.closingLine, kana: state.scenario.closingKana,
                                      english: state.scenario.closingEnglish, name: state.persona.nameJa,
                                      gender: state.persona.voiceGender, rate: rate)
            }
            try await coach(.conversationEnd)
        }
    }
}
