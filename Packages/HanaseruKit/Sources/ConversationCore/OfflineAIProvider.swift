import Foundation
import LearningCore

/// Works with no network. Scenarios follow their scripted beats; answers are judged with the local
/// fuzzy evaluator.
///
/// It is deliberately honest about its limits: a free-form answer that doesn't resemble any example is
/// treated as "understandable" rather than wrong, because offline we can't tell a creative correct
/// answer from an incorrect one.
public struct OfflineAIProvider: AIProvider {
    public let name = "Offline"
    private let library: ContentLibrary
    private let evaluator = ResponseEvaluator()

    public init(library: ContentLibrary) {
        self.library = library
    }

    public func generateResponse(_ request: TurnRequest) async throws -> TurnResponse {
        let context = request.context
        guard let scenario = library.scenario(id: context.scenarioID), !scenario.beats.isEmpty else {
            throw AIProviderError.unknownScenario(context.scenarioID)
        }
        let beatIndex = min(max(context.turnIndex, 0), scenario.beats.count - 1)
        let beat = scenario.beats[beatIndex]
        let evaluation = evaluateConversational(request.learnerUtterance, beat: beat, learnerName: context.learnerName)

        let nextIndex = context.turnIndex + 1
        let reachedLimit = nextIndex >= min(context.maxTurns, scenario.beats.count)
        if reachedLimit {
            return TurnResponse(
                evaluation: evaluation,
                reply: CoachLine(japanese: scenario.closingLine, kana: scenario.closingKana, english: scenario.closingEnglish),
                shouldEnd: true
            )
        }

        let next = scenario.beats[nextIndex]
        let reaction = Self.reaction(for: evaluation.verdict, turn: nextIndex, nextLine: next.line)
        return TurnResponse(
            evaluation: evaluation,
            reply: CoachLine(
                japanese: reaction.ja + next.line,
                kana: reaction.kana + next.kana,
                english: [reaction.en, next.english].filter { !$0.isEmpty }.joined(separator: " ")
            ),
            shouldEnd: false
        )
    }

    public func evaluateResponse(_ request: EvaluationRequest) async throws -> TurnEvaluation {
        let target = EvaluationTarget(references: request.examples, keyTerms: [], commonMistakes: CommonMistakes.general,
                                      modelAnswer: request.examples.first ?? "")
        return TurnEvaluation(local: evaluator.evaluate(request.learnerUtterance, against: target), said: request.learnerUtterance)
    }

    // MARK: - Helpers

    private func evaluateConversational(_ utterance: String, beat: ScenarioBeat, learnerName: String) -> TurnEvaluation {
        var target = EvaluationTarget(beat: beat)
        target.references = target.references.map { $0.replacingOccurrences(of: "{name}", with: learnerName) }
        target.modelAnswer = target.modelAnswer.replacingOccurrences(of: "{name}", with: learnerName)
        var local = evaluator.evaluate(utterance, against: target)
        // Offline we can't judge open answers: anything in Japanese that isn't a known mistake gets the benefit of the doubt.
        if local.verdict == .incorrect && local.matchedMistakes.isEmpty {
            local.verdict = .understandable
        }
        var evaluation = TurnEvaluation(local: local, said: utterance)
        // Scenario examples are possible answers, not corrections of what the learner said, so offline
        // conversation feedback is limited to the explanation of a detected mistake.
        evaluation.naturalVersion = ""
        return evaluation
    }

    /// A short, natural reaction before the next question (spec §78).
    public static func reaction(for verdict: ResponseVerdict, turn: Int, nextLine: String) -> (ja: String, kana: String, en: String) {
        // Scripted lines that already open with a reaction or a greeting don't need another one.
        let opensWithReaction = ["そう", "なるほど", "へえ", "いいですね", "わかりました", "はじめまして", "おはよう", "お疲れ"]
            .contains { nextLine.hasPrefix($0) }
        guard !opensWithReaction else { return ("", "", "") }
        switch verdict {
        case .noResponse, .unclear:
            return ("", "", "")
        default:
            let options: [(ja: String, kana: String, en: String)] = [
                ("なるほど。", "なるほど。", "I see."),
                ("そうですか。", "そうですか。", "Is that so."),
                ("わかりました。", "わかりました。", "Got it."),
            ]
            return options[turn % options.count]
        }
    }
}
