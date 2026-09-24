import Foundation
import Testing
@testable import LearningCore

@Suite("Spaced repetition and knowledge model")
struct KnowledgeTests {
    let scheduler = ReviewScheduler()
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func goodReviewsGrowTheInterval() {
        var state = DimensionState.new(at: start)
        var date = start
        var intervals: [Double] = []
        for _ in 0..<4 {
            state = scheduler.review(state, grade: .good, at: date)
            intervals.append(state.stabilityDays)
            date = state.due
        }
        #expect(intervals == intervals.sorted())
        #expect(intervals.last! > 10)
        #expect(state.strength > 0.8)
    }

    @Test func lapseShrinksIntervalAndCountsLapse() {
        var state = DimensionState.new(at: start)
        state = scheduler.review(state, grade: .good, at: start)
        state = scheduler.review(state, grade: .good, at: state.due)
        let before = state.stabilityDays
        state = scheduler.review(state, grade: .again, at: state.due)
        #expect(state.lapses == 1)
        #expect(state.stabilityDays < before)
        #expect(state.strength < 0.7)
    }

    @Test func slowCorrectAnswerIsGradedHard() {
        #expect(ReviewGrade(verdict: .natural, latency: 9) == .hard)
        #expect(ReviewGrade(verdict: .natural, latency: 1.5) == .easy)
        #expect(ReviewGrade(verdict: .acceptable, latency: 3) == .good)
        #expect(ReviewGrade(verdict: .noResponse, latency: nil) == .again)
        #expect(ReviewGrade(verdict: .understandable, latency: nil) == .hard)
    }

    @Test func dimensionsAreIndependent() {
        // Spec §32: recognition 95%, speaking 20% → practise speaking, not recognition.
        var knowledge = KnowledgeState(itemID: "w.progress.how", introducedAt: start)
        for _ in 0..<3 {
            knowledge = scheduler.record(knowledge, dimension: .listening, grade: .good, at: start)
        }
        knowledge = scheduler.record(knowledge, dimension: .spokenRecall, grade: .again, latency: 9, at: start)
        knowledge = scheduler.record(knowledge, dimension: .context, grade: .good, at: start)
        #expect(knowledge.weakestDimension == .spokenRecall)
        #expect(knowledge.state(.listening).strength > knowledge.state(.spokenRecall).strength)
        #expect(knowledge.averageLatency == 9)
    }

    @Test func latencyIsAveraged() {
        var knowledge = KnowledgeState(itemID: "x", introducedAt: start)
        knowledge = scheduler.record(knowledge, dimension: .spokenRecall, grade: .good, latency: 10, at: start)
        knowledge = scheduler.record(knowledge, dimension: .spokenRecall, grade: .good, latency: 2, at: start)
        #expect(abs(knowledge.averageLatency! - 7.6) < 0.001)
    }

    @Test func knowledgeRoundTripsThroughJSON() throws {
        var knowledge = KnowledgeState(itemID: "w.confirm.will", introducedAt: start)
        knowledge = scheduler.record(knowledge, dimension: .spokenRecall, grade: .good, latency: 3, at: start)
        let data = try JSONEncoder().encode(knowledge)
        let decoded = try JSONDecoder().decode(KnowledgeState.self, from: data)
        #expect(decoded == knowledge)
        // Dimension keys encode as readable strings, which keeps stored data inspectable.
        #expect(String(decoding: data, as: UTF8.self).contains("spokenRecall"))
    }
}

@Suite("Difficulty adaptation")
struct DifficultyTests {
    let adapter = DifficultyAdapter()

    func results(successes: Int, failures: Int, latency: Double) -> [ExerciseResult] {
        (0..<successes).map { _ in ExerciseResult(kind: .recall, itemID: nil, verdict: .natural, latency: latency, date: Date()) }
            + (0..<failures).map { _ in ExerciseResult(kind: .recall, itemID: nil, verdict: .incorrect, latency: latency, date: Date()) }
    }

    @Test func steadySuccessRaisesDifficulty() {
        let next = adapter.adapted(.starting, recent: results(successes: 9, failures: 1, latency: 2))
        #expect(next.level == DifficultyProfile.starting.level + 1)
        #expect(next.englishSupport < DifficultyProfile.starting.englishSupport)
        #expect(next.speechRate > DifficultyProfile.starting.speechRate)
    }

    @Test func strugglingLowersDifficulty() {
        let next = adapter.adapted(.starting, recent: results(successes: 2, failures: 6, latency: 6))
        #expect(next.level == DifficultyProfile.starting.level - 1)
        #expect(next.englishSupport > DifficultyProfile.starting.englishSupport)
        #expect(next.responseWindow > DifficultyProfile.starting.responseWindow)
    }

    @Test func needsEnoughEvidence() {
        #expect(adapter.adapted(.starting, recent: results(successes: 3, failures: 0, latency: 1)) == .starting)
    }

    @Test func staysWithinBounds() {
        var profile = DifficultyProfile(level: 8, englishSupport: 0, speechRate: 1.2, responseWindow: 5)
        profile = adapter.adapted(profile, recent: results(successes: 10, failures: 0, latency: 1))
        #expect(profile.level == 8)
        #expect(profile.englishSupport == 0)
        #expect(profile.speechRate <= 1.2)
        #expect(profile.responseWindow == 5)
    }
}
