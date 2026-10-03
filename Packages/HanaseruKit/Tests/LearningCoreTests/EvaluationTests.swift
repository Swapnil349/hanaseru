import Testing
@testable import LearningCore

@Suite("Japanese text")
struct JapaneseTextTests {
    @Test func normalizationFoldsKatakanaPunctuationAndWidth() {
        #expect(JapaneseText.normalize("カクニン、します。") == "かくにんします")
        #expect(JapaneseText.normalize("ＡＢＣ１２３？") == "abc123")
        #expect(JapaneseText.normalize("レール") == "れーる")
    }

    @Test func similarityIgnoresPunctuation() {
        #expect(JapaneseText.similarity("昨日、東京に行きました。", "昨日東京に行きました") == 1)
        #expect(JapaneseText.similarity("", "") == 1)
        #expect(JapaneseText.similarity("abc", "") == 0)
        #expect(JapaneseText.similarity("友達と出かけました", "友達と遊びました") > 0.5)
    }

    @Test func voiceCommandsNeedTheWholeUtterance() {
        #expect(VoiceCommand.detect(in: "もう一度") == .repeatPrompt)
        #expect(VoiceCommand.detect(in: "もう一度お願いします。") == .repeatPrompt)
        #expect(VoiceCommand.detect(in: "わかりません") == .answer)
        #expect(VoiceCommand.detect(in: "答え") == .answer)
        #expect(VoiceCommand.detect(in: "ヒント") == .hint)
        #expect(VoiceCommand.detect(in: "ゆっくりお願いします") == .slower)
        #expect(VoiceCommand.detect(in: "英語で") == .english)
        #expect(VoiceCommand.detect(in: "どういう意味ですか") == .english)
        #expect(VoiceCommand.detect(in: "スキップ") == .skip)
        #expect(VoiceCommand.detect(in: "ちょっと待ってください") == .moreTime)
        #expect(VoiceCommand.detect(in: "ストップ") == .pause)
        #expect(VoiceCommand.detect(in: "もう一度確認します") == nil)
        #expect(VoiceCommand.detect(in: "次の検査は金曜日です") == nil)
        #expect(VoiceCommand.detect(in: "") == nil)
    }

    @Test func practisingAHelpPhraseIsNotACommand() {
        // 「もう一度お願いします。」 is also a line the learner learns; saying it as an answer must count as the answer.
        #expect(VoiceCommand.detect(in: "もう一度お願いします", expected: ["もう一度お願いします。"]) == nil)
        #expect(VoiceCommand.detect(in: "もう一度お願いします", expected: ["確認しておきます。"]) == .repeatPrompt)
    }

    @Test func fillersHoldTheTurn() {
        #expect(JapaneseText.isFillerOnly("えーと"))
        #expect(JapaneseText.isFillerOnly("うーん、えっと"))
        #expect(!JapaneseText.isFillerOnly("えーと、順調です"))
        #expect(JapaneseText.stripLeadingFillers("えーと、順調です") == "順調です")
        #expect(!JapaneseText.isFillerOnly(""))
    }

    @Test func englishAnswersAreRecognisedAsLatin() {
        #expect(JapaneseText.isMostlyLatin("hello there"))
        #expect(!JapaneseText.isMostlyLatin("順調です OK"))
    }

    @Test func moraeAndSegments() {
        #expect(JapaneseText.firstMorae("じゅんちょうです", count: 2) == "じゅん")
        #expect(JapaneseText.moraCount("じゅんちょうです") == 6)
        let parts = JapaneseText.bilingualSegments("Stuck? Say 「ヒント」 for a hint.")
        #expect(parts.map(\.text) == ["Stuck? Say", "ヒント", "for a hint."])
        #expect(parts.map(\.isJapanese) == [false, true, false])
        #expect(JapaneseText.punctuationChunks("いいえ、特に問題はありません。") == ["いいえ、", "特に問題はありません。"])
    }

    @Test func punctuationAloneIsNotSpoken() {
        let parts = JapaneseText.bilingualSegments("Say 「お疲れさまでした」.")
        #expect(parts.map(\.text) == ["Say", "お疲れさまでした"])
        #expect(JapaneseText.isSpeakableInstruction("Say 「ました」, not 「ます」."))
        #expect(!JapaneseText.isSpeakableInstruction("忙しい becomes 忙しかったです."))
    }

    @Test func englishIsTidiedForSpeech() {
        #expect(JapaneseText.speakableEnglish("Understood. / Certainly.") == "Understood. or Certainly.")
        #expect(JapaneseText.speakableEnglish("Hi (to a colleague at work).") == "Hi, to a colleague at work.")
        #expect(JapaneseText.speakableEnglish("By when? (What's the deadline?)") == "By when? What's the deadline?")
        #expect(JapaneseText.speakableEnglish("km/h") == "km/h")
    }
}

@Suite("Fuzzy response evaluation")
struct ResponseEvaluatorTests {
    let evaluator = ResponseEvaluator()
    let library = try! ContentLibrary.bundled()

    func target(_ id: String) -> EvaluationTarget {
        EvaluationTarget(item: library.item(id: id)!)
    }

    @Test func differentButValidAnswersAreNotWrong() {
        // Spec §40: 「友達と遊びました」 is a valid answer to "what did you do at the weekend".
        let result = evaluator.evaluate("友達と遊びました", against: target("e.weekend.friends"))
        #expect(result.verdict.isSuccess)
    }

    @Test func pastTenseMistakeIsDetected() {
        let result = evaluator.evaluate("昨日、東京に行きます。", against: target("e.past.tokyo"))
        #expect(result.verdict == .incorrect)
        #expect(result.matchedMistakes.first?.type == .pastTense)
    }

    @Test func iAdjectivePastMistakeIsDetected() {
        let result = evaluator.evaluate("はい、ちょっと忙しいでした。", against: target("e.busy.answer"))
        #expect(result.matchedMistakes.contains { $0.type == .conjugation })
    }

    @Test func naAdjectivePastIsNotFlagged() {
        let target = EvaluationTarget(references: ["きれいでした"], keyTerms: [], commonMistakes: CommonMistakes.general, modelAnswer: "きれいでした")
        #expect(evaluator.evaluate("とてもきれいでした", against: target).matchedMistakes.isEmpty)
    }

    @Test func continuingStateSincePastIsNotFlagged() {
        let target = EvaluationTarget(references: [], keyTerms: [], commonMistakes: CommonMistakes.general, modelAnswer: "")
        #expect(evaluator.evaluate("先週からこのプロジェクトで働いています", against: target).matchedMistakes.isEmpty)
    }

    @Test func casualRegisterIsContextualNotIncorrect() {
        let result = evaluator.evaluate("わかりました", against: target("w.understood.polite"))
        #expect(result.verdict == .contextuallyInappropriate)
    }

    @Test func kanaTranscriptionMatchesKanjiReference() {
        let result = evaluator.evaluate("かくにんしておきます", against: target("w.confirm.will"))
        #expect(result.verdict == .natural)
    }

    @Test func silenceAndEnglishAreHandled() {
        #expect(evaluator.evaluate("", against: target("w.confirm.will")).verdict == .noResponse)
        #expect(evaluator.evaluate("I will check", against: target("w.confirm.will")).verdict == .unclear)
    }

    @Test func answersNamingTheWrongOptionAreWrong() throws {
        // 「いいえ」 contains 「いえ」 (home), but 出かけます is the other option.
        let weekend = try #require(library.item(id: "e.weekend.plan")?.listening)
        #expect(!evaluator.evaluate("いいえ、出かけます", against: EvaluationTarget(listening: weekend)).verdict.isSuccess)
        #expect(evaluator.evaluate("家です", against: EvaluationTarget(listening: weekend)).verdict.isSuccess)
        let progress = try #require(library.item(id: "w.progress.ontrack")?.listening)
        #expect(!evaluator.evaluate("はい、遅れています", against: EvaluationTarget(listening: progress)).verdict.isSuccess)
    }

    @Test func unrelatedJapaneseIsNotConfident() {
        let result = evaluator.evaluate("今日はいい天気ですね", against: target("w.progress.how"))
        #expect(!result.verdict.isSuccess)
        #expect(!result.isConfident)
    }
}
