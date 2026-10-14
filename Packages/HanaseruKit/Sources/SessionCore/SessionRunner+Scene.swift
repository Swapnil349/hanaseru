import Foundation
import LearningCore
import ConversationCore

/// A scene broken into segments, one per line and step, so that pause, ⏮, ↺ and ⏭ work one line at a
/// time and a paused scene carries on from the same line instead of starting again.
struct SceneState {
    enum Segment: Equatable {
        /// The scene's title (in a full lesson also the situation and the three steps).
        case intro
        /// Step 1: one exchange of the screenplay, with the learner's line in English and Japanese.
        case listen(Int)
        /// Step 2: one of the learner's lines, repeated after the model.
        case practise(Int)
        /// Step 3: the partner speaks and the learner answers.
        case perform(Int)
        /// The partner's closing line.
        case ending
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
    /// How the learner's last answer in the conversation went: the partner reacts to a good one.
    var lastOutcome: TurnOutcome?

    init(scenario: Scenario, persona: Persona, lines: [PracticeLine], start: Int, mode: SceneMode) {
        self.scenario = scenario
        self.persona = persona
        self.lines = lines
        self.start = start
        self.mode = mode
        var segments: [Segment] = [.intro]
        if mode == .fullLesson {
            segments += lines.indices.map { Segment.listen($0) }
        }
        if mode == .fullLesson || mode == .practiseLines {
            segments += lines.indices.map { Segment.practise($0) }
        }
        segments += lines.indices.map { Segment.perform($0) }
        segments.append(.ending)
        self.segments = segments
    }

    /// The segment for a line of the scene (`line` counts from the scene's first line): in the step being
    /// played now, or the first step that has it.
    func segmentIndex(forLine line: Int, near cursor: Int) -> Int? {
        let index = line - start
        guard lines.indices.contains(index) else { return nil }
        let current = segments.indices.contains(cursor) ? segments[cursor] : .intro
        let wanted: [Segment]
        switch current {
        case .intro, .listen: wanted = [.listen(index), .practise(index), .perform(index)]
        case .practise: wanted = [.practise(index), .perform(index)]
        case .perform, .ending: wanted = [.perform(index)]
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
        while let state = sceneState, cursor < state.segments.count {
            try await playSegment(state.segments[cursor], of: state)
            // A move made while the segment was ending has already set the place.
            try Task.checkCancellation()
            cursor += 1
        }
    }

    private func makeSceneState(scenarioID: String, maxTurns: Int) async -> SceneState? {
        guard let scenario = library.scenario(id: scenarioID), let persona = library.persona(id: scenario.personaID) else { return nil }
        let all = library.lines(in: scenario, learnerName: learner.name)
        guard !all.isEmpty else { return nil }
        let start = min(max(0, options.sceneStartBeat), all.count - 1)
        let lines = Array(all.dropFirst(start).prefix(max(1, maxTurns)))
        // A scene already practised goes straight to the conversation: no explanations.
        var mode = options.sceneMode
        if mode == .automatic {
            let known = await repository.knowledge(for: all.map(\.id))
            mode = known.values.contains { $0.state(.spokenRecall).reviews > 0 } ? .conversationOnly : .fullLesson
        }
        return SceneState(scenario: scenario, persona: persona, lines: lines, start: start, mode: mode)
    }

    private func playSegment(_ segment: SceneState.Segment, of state: SceneState) async throws {
        let full = state.mode == .fullLesson
        switch segment {
        case .intro:
            emit(.line(ScriptLine(role: .instruction, japanese: state.scenario.titleJa, english: state.scenario.situationEn)))
            try await coach(.sceneIntro, ["title": state.scenario.title])
            if full {
                try await speakMixed(state.scenario.situationEn)
                try await coach(.sceneSteps)
            }

        case .listen(let index):
            // Step 1 — screenplay: both roles, with the learner's line given in English and Japanese.
            let line = state.lines[index]
            emit(.step("Step 1 of 3 · Listen to the conversation"))
            emit(.focus(focusInfo(line, level: .model)))
            if index == 0 { try await coach(.listenFirst) }
            if let partner = line.partner {
                try await partnerSays(partner, rate: 0.9)
                try await speak(partner.english, .english, pauseAfter: 0.3)
            }
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
            if index == 0 { try await coach(full ? .rehearseStart : .rehearseShort) }
            if let partner = line.partner { try await partnerSays(partner, rate: 0.9) }
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
            if index == 0 {
                let youStart = state.lines.first?.partner == nil
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
            if !state.scenario.closingLine.isEmpty {
                let rate = TurnTiming.partnerRate(level: .cued, profile: learner.difficulty, personaRate: state.persona.speakingRate)
                try await partnerSays(state.scenario.closingLine, kana: state.scenario.closingKana,
                                      english: state.scenario.closingEnglish, name: state.persona.nameJa,
                                      gender: state.persona.voiceGender, rate: rate)
            }
            try await coach(.conversationEnd)
        }
    }
}
