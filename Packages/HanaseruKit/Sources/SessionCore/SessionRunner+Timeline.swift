import Foundation
import LearningCore

/// Where a stop of the session's scrubber plays from: a part, a segment in it, and whether at its answer.
struct SessionTarget: Equatable {
    var part: Int
    var segment: Int
    var answer: Bool
}

/// The scrubber over the whole session: every part's stops, in order — a scene's lines in every step, and
/// a question and an answer for each phrase or listening check.
extension SessionRunner {
    func buildTimeline() async {
        var stops: [SessionTimeline.Stop] = []
        var targets: [SessionTarget] = []
        var offsets: [Int] = []
        let numbered = plan.exercises.count > 1
        for (index, exercise) in plan.exercises.enumerated() {
            offsets.append(stops.count)
            let part = numbered ? index + 1 : nil
            if case .conversation(let id, let turns) = exercise {
                guard let state = await makeSceneState(scenarioID: id, maxTurns: turns) else { continue }
                sceneStates[index] = state
                for (position, stop) in state.stops.enumerated() {
                    var copy = stop
                    copy.part = part
                    stops.append(copy)
                    targets.append(SessionTarget(part: index, segment: state.targets[position].segment,
                                                 answer: state.targets[position].answer))
                }
                continue
            }
            let (question, answer) = partText(exercise)
            let step = title(for: exercise)
            stops.append(SessionTimeline.Stop(step: step, line: nil, isAnswer: false, japanese: question, part: part))
            targets.append(SessionTarget(part: index, segment: 0, answer: false))
            if case .shadowing = exercise { continue }
            stops.append(SessionTimeline.Stop(step: step, line: nil, isAnswer: true, japanese: answer, part: part))
            targets.append(SessionTarget(part: index, segment: 0, answer: true))
        }
        sessionStops = stops
        sessionTargets = targets
        partOffsets = offsets
        if !stops.isEmpty { emit(.timeline(SessionTimeline(stops: stops, position: 0))) }
    }

    /// What is heard at a phrase's or listening check's question and answer.
    private func partText(_ exercise: PlannedExercise) -> (question: String, answer: String) {
        switch exercise {
        case .recall(let id), .shadowing(let id):
            guard let item = library.item(id: id) else { return ("", "") }
            return (item.partner?.japanese ?? "", item.japanese)
        case .listening(let id):
            guard let item = library.item(id: id) else { return ("", "") }
            return (item.japanese, item.listening?.modelAnswer ?? "")
        case .conversation:
            return ("", "")
        }
    }

    /// Moves the scrubber: `local` is the stop within the part being played.
    func showPosition(local: Int) {
        guard !sessionStops.isEmpty, partOffsets.indices.contains(currentExerciseIndex) else { return }
        let position = min(sessionStops.count - 1, max(0, partOffsets[currentExerciseIndex] + local))
        emit(.timeline(SessionTimeline(stops: sessionStops, position: position)))
    }

    /// The stop that matches a place saved earlier (by step, line and side), or the same line in another step.
    func stopIndex(matching point: SessionTimeline.Stop) -> Int? {
        sessionStops.firstIndex { $0.step == point.step && $0.line == point.line && $0.isAnswer == point.isAnswer }
            ?? sessionStops.firstIndex { point.line != nil && $0.line == point.line && $0.isAnswer == point.isAnswer }
    }

    /// Straight to the answer of a phrase (from the scrubber): hear it and say it once. Nothing is asked, so
    /// nothing is graded.
    func playAnswer(_ line: PracticeLine) async throws {
        lastLineID = line.id
        emit(.focus(focusInfo(line, level: .model)))
        emit(.reveal(RevealInfo(lineID: line.id, japanese: line.japanese, kana: line.kana, english: line.english,
                                heard: "", outcome: .skipped, romaji: line.romaji)))
        try await coach(.youSay, ["english": line.english])
        try await sayModel(line, rate: 0.85)
        _ = try await runEcho(line, window: 5, silentNote: false)
        exposed.insert(line.id)
    }
}
