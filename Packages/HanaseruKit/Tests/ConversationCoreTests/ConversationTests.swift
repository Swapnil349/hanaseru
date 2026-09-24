import Foundation
import Testing
import LearningCore
@testable import ConversationCore

@Suite("Offline conversation engine")
struct OfflineProviderTests {
    let library = try! ContentLibrary.bundled()
    var provider: OfflineAIProvider { OfflineAIProvider(library: library) }

    func context(_ scenarioID: String, turn: Int, maxTurns: Int = 4, history: [DialogueTurn] = []) -> ConversationContext {
        let scenario = library.scenario(id: scenarioID)!
        return ConversationContext(
            scenarioID: scenarioID, scenarioTitle: scenario.title, situation: scenario.situationEn,
            persona: PersonaBrief(library.persona(id: scenario.personaID)!), learnerName: "Swapnil",
            learnerLevel: 3, englishSupport: 0.5, targetTerms: [], recurringMistakeTypes: [],
            history: history, turnIndex: turn, maxTurns: maxTurns
        )
    }

    @Test func conversationFollowsTheScenarioBeats() async throws {
        let response = try await provider.generateResponse(TurnRequest(context: context("s.progress.meeting", turn: 0), learnerUtterance: "順調です。"))
        let secondBeat = library.scenario(id: "s.progress.meeting")!.beats[1].line
        #expect(response.reply.japanese.hasSuffix(secondBeat))
        #expect(!response.shouldEnd)
        #expect(response.evaluation.verdict.isSuccess)
    }

    @Test func lastTurnClosesTheConversation() async throws {
        let scenario = library.scenario(id: "s.weekend.chat")!
        let response = try await provider.generateResponse(TurnRequest(context: context("s.weekend.chat", turn: 2, maxTurns: 3), learnerUtterance: "まだ決めていません。"))
        #expect(response.shouldEnd)
        #expect(response.reply.japanese == scenario.closingLine)
    }

    @Test func maxTurnsShorterThanScenarioEndsEarly() async throws {
        let response = try await provider.generateResponse(TurnRequest(context: context("s.site.pier", turn: 1, maxTurns: 2), learnerUtterance: "特に問題はありません。"))
        #expect(response.shouldEnd)
    }

    @Test func openAnswersGetTheBenefitOfTheDoubt() async throws {
        let response = try await provider.generateResponse(TurnRequest(context: context("s.delay", turn: 1), learnerUtterance: "クレーンが壊れました。"))
        #expect(response.evaluation.verdict != .incorrect)
        #expect(response.evaluation.understood)
    }

    @Test func pastTenseMistakeIsCaughtInConversation() async throws {
        let response = try await provider.generateResponse(TurnRequest(context: context("s.weekend.chat", turn: 0), learnerUtterance: "昨日、友達と出かけます。"))
        #expect(response.evaluation.mistakes.first?.type == .pastTense)
        #expect(!response.evaluation.feedbackEn.isEmpty)
    }

    @Test func roleReversalRepliesWithThePartnersFirstLine() async throws {
        let scenario = library.scenario(id: "s.first.meeting")!
        let response = try await provider.generateResponse(TurnRequest(
            context: context("s.first.meeting", turn: 0),
            learnerUtterance: "はじめまして。スワプニルです。高速鉄道のプロジェクトで働いています。よろしくお願いします。"))
        #expect(response.reply.japanese.contains(scenario.beats[1].line))
        #expect(response.evaluation.verdict.isSuccess)
    }

    @Test func unknownScenarioThrows() async {
        await #expect(throws: AIProviderError.self) {
            _ = try await provider.generateResponse(TurnRequest(context: context("s.progress.meeting", turn: 0).with(id: "nope"), learnerUtterance: "はい"))
        }
    }
}

private extension ConversationContext {
    func with(id: String) -> ConversationContext {
        var copy = self
        copy.scenarioID = id
        return copy
    }
}

@Suite("Resilient provider")
struct ResilientProviderTests {
    struct FailingProvider: AIProvider {
        let name = "Failing"
        func generateResponse(_ request: TurnRequest) async throws -> TurnResponse { throw AIProviderError.transport("down") }
        func evaluateResponse(_ request: EvaluationRequest) async throws -> TurnEvaluation { throw AIProviderError.transport("down") }
    }

    struct SlowProvider: AIProvider {
        let name = "Slow"
        func generateResponse(_ request: TurnRequest) async throws -> TurnResponse {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return TurnResponse(evaluation: TurnEvaluation(verdict: .natural, understood: true), reply: CoachLine(japanese: "遅い"), shouldEnd: false)
        }
        func evaluateResponse(_ request: EvaluationRequest) async throws -> TurnEvaluation {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return TurnEvaluation(verdict: .natural, understood: true)
        }
    }

    let library = try! ContentLibrary.bundled()

    func request() -> EvaluationRequest {
        EvaluationRequest(mode: .recall, prompt: "Say: I'll check on that.", examples: ["確認しておきます"],
                          learnerUtterance: "確認しておきます", learnerLevel: 2)
    }

    @Test func fallsBackWhenPrimaryFails() async throws {
        let provider = ResilientAIProvider(primary: FailingProvider(), fallback: OfflineAIProvider(library: library))
        let evaluation = try await provider.evaluateResponse(request())
        #expect(evaluation.verdict == .natural)
        #expect(provider.lastFailure == .transport("down"))
    }

    @Test func fallsBackWhenPrimaryIsTooSlow() async throws {
        let provider = ResilientAIProvider(primary: SlowProvider(), fallback: OfflineAIProvider(library: library), timeout: 0.2)
        let evaluation = try await provider.evaluateResponse(request())
        #expect(evaluation.verdict == .natural)
        #expect(provider.lastFailure == .timedOut)
    }
}

@Suite("Wire format")
struct WireFormatTests {
    /// Mirrors what backend/src/coach.ts returns, so the app and proxy can't drift silently.
    @Test func decodesProxyTurnResponse() throws {
        let json = """
        {
          "evaluation": {
            "verdict": "understandable",
            "understood": true,
            "feedbackEn": "Use the past tense for last weekend.",
            "naturalVersion": "友達と出かけました。",
            "mistakes": [{ "type": "pastTense", "said": "友達と出かけます", "correction": "出かけました", "explanation": "Past event." }]
          },
          "reply": { "japanese": "いいですね。どこに行きましたか？", "kana": "いいですね。どこにいきましたか？", "english": "Nice. Where did you go?" },
          "shouldEnd": false
        }
        """
        let response = try JSONDecoder().decode(TurnResponse.self, from: Data(json.utf8))
        #expect(response.evaluation.verdict == .understandable)
        #expect(response.evaluation.mistakes.first?.type == .pastTense)
        #expect(response.reply.english == "Nice. Where did you go?")
    }

    @Test func unknownEnumValuesDegradeGracefully() throws {
        let json = #"{ "verdict": "brilliant", "mistakes": [{ "type": "keigo", "said": "", "correction": "", "explanation": "" }] }"#
        let evaluation = try JSONDecoder().decode(TurnEvaluation.self, from: Data(json.utf8))
        #expect(evaluation.verdict == .understandable)
        #expect(evaluation.mistakes.first?.type == .other)
    }

    @Test func requestEncodesCamelCaseFields() throws {
        let request = EvaluationRequest(mode: .listening, prompt: "p", question: "q", examples: ["a"], learnerUtterance: "u", learnerLevel: 2)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(object["learnerUtterance"] as? String == "u")
        #expect(object["mode"] as? String == "listening")
        #expect(object["politeness"] as? String == "professional")
    }
}
