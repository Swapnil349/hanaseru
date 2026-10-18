import Testing
@testable import LearningCore

@Suite("Bundled content")
struct ContentTests {
    let library: ContentLibrary

    init() throws {
        library = try ContentLibrary.bundled()
    }

    @Test func loadsEveryContentFile() {
        #expect(library.items.count >= 30)
        #expect(library.vocabulary.count >= 60)
        #expect(library.scenarios.count >= 8)
        #expect(!library.personas.isEmpty)
        #expect(!library.grammar.isEmpty)
    }

    /// Every line of every scene has its words with meanings, and they spell the line.
    @Test func everySceneLineHasItsWords() {
        for scenario in library.scenarios {
            let lines = [scenario.closingLine] + scenario.beats.flatMap { [$0.line] + $0.responses.map(\.japanese) }
            for line in lines where !line.isEmpty {
                let words = library.words(in: line)
                #expect(!words.isEmpty, "\(scenario.id): no words for 「\(line)」")
                #expect(words.allSatisfy { !$0.en.isEmpty && !$0.romaji.isEmpty }, "\(scenario.id): 「\(line)」")
            }
        }
    }

    @Test func wordsAreFoundWithTheLearnersName() {
        let words = library.words(in: "お電話ありがとうございます。Swapnilです。いつもお世話になっております。")
        #expect(words.contains { $0.ja == "Swapnil" })
        #expect(words.first { $0.ja == "は" }?.romaji ?? "wa" == "wa")
        let topic = library.words(in: "はじめまして。財務部の山田です。")
        #expect(topic.map(\.ja) == ["はじめまして", "財務部", "の", "山田", "です"])
    }

    @Test func financeScenesAreKeptToTheirField() {
        let finance = library.forField(.finance).scenarios
        #expect(finance.contains { $0.id == "f.month.end" })
        #expect(!finance.contains { $0.id == "s.site.pier" })
        #expect(finance.contains { $0.id == "s.weekend.chat" })
        let engineering = library.forField(.engineering).scenarios
        #expect(!engineering.contains { $0.workField == .finance })
        #expect(engineering.contains { $0.id == "s.site.pier" })
    }

    @Test func everyCueHasText() {
        for key in CueKey.allCases {
            let cue = library.cue(key)
            #expect(!cue.ja.isEmpty, "missing cue \(key)")
            #expect(!cue.en.isEmpty, "missing English for cue \(key)")
        }
    }

    @Test func idsAreUnique() {
        #expect(Set(library.items.map(\.id)).count == library.items.count)
        #expect(Set(library.vocabulary.map(\.id)).count == library.vocabulary.count)
        #expect(Set(library.scenarios.map(\.id)).count == library.scenarios.count)
    }

    @Test func referencesResolve() {
        let termIDs = Set(library.vocabulary.map(\.id))
        let grammarIDs = Set(library.grammar.map(\.id))
        for item in library.items {
            for term in item.terms { #expect(termIDs.contains(term), "\(item.id) references unknown term \(term)") }
            for pattern in item.grammar { #expect(grammarIDs.contains(pattern), "\(item.id) references unknown grammar \(pattern)") }
            #expect((1...8).contains(item.level))
            #expect(!item.kana.isEmpty)
        }
        for scenario in library.scenarios {
            #expect(library.persona(id: scenario.personaID) != nil, "\(scenario.id) has unknown persona")
            #expect(!scenario.beats.isEmpty)
            for term in scenario.targetTerms { #expect(termIDs.contains(term), "\(scenario.id) references unknown term \(term)") }
            if !scenario.roleReversal { #expect(!scenario.beats[0].line.isEmpty) }
        }
    }

    /// Every item's own sentence must be judged natural — this catches over-eager mistake patterns.
    @Test func itemsEvaluateTheirOwnSentenceAsNatural() {
        let evaluator = ResponseEvaluator()
        for item in library.items {
            let result = evaluator.evaluate(item.japanese, against: EvaluationTarget(item: item))
            #expect(result.verdict == .natural, "\(item.id) evaluated as \(result.verdict)")
        }
    }

    @Test func listeningModelAnswersPassTheirOwnCheck() {
        let evaluator = ResponseEvaluator()
        for item in library.items {
            guard let check = item.listening else { continue }
            let result = evaluator.evaluate(check.modelAnswer, against: EvaluationTarget(listening: check))
            #expect(result.verdict.isSuccess, "\(item.id) model answer fails its own listening check")
        }
    }

    @Test func scenarioExamplesAreNotFlaggedAsMistakes() {
        let evaluator = ResponseEvaluator()
        for scenario in library.scenarios {
            for beat in scenario.beats {
                for example in beat.exampleResponses {
                    let result = evaluator.evaluate(example, against: EvaluationTarget(beat: beat))
                    #expect(result.matchedMistakes.isEmpty, "\(scenario.id): example 「\(example)」 flagged as a mistake")
                }
            }
        }
    }
}
