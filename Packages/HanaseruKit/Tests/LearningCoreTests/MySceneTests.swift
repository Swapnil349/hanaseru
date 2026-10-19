import Foundation
import Testing
@testable import LearningCore

/// Scenes in the shape of docs/MY-SCENES.md, as the coach and the other apps write them.
enum MySceneFixture {
    static let conversationJSON = """
    {
      "id": "my.k3x9a1b2",
      "kind": "conversation",
      "description": "Meeting my new team leader at the bank",
      "createdAt": 1760000000000,
      "updatedAt": 1760000500000,
      "result": {
        "title": "Meeting the team leader", "titleJa": "チームリーダーとの挨拶",
        "situationEn": "Your first morning on the new team.", "placeEn": "in the office",
        "partnerNameJa": "田中さん", "partnerNameEn": "Tanaka-san", "partnerRole": "Team leader",
        "partnerGender": "female", "track": "work",
        "beats": [
          {
            "partner": { "japanese": "{name}さん、はじめまして。田中です。", "kana": "{name}さん、はじめまして。たなかです。",
                         "english": "Nice to meet you, {name}. I'm Tanaka.",
                         "words": [{ "ja": "{name}", "kana": "{name}", "en": "(your name)" },
                                   { "ja": "はじめまして", "kana": "はじめまして", "en": "nice to meet you" }] },
            "learner": { "japanese": "はじめまして。{name}です。", "kana": "はじめまして。{name}です。",
                         "english": "Nice to meet you. I'm {name}.",
                         "words": [{ "ja": "はじめまして", "kana": "はじめまして", "en": "nice to meet you" },
                                   { "ja": "{name}", "kana": "{name}", "en": "(your name)" },
                                   { "ja": "です", "kana": "です", "en": "am" }] },
            "hintEn": "Say your name"
          },
          {
            "partner": { "japanese": "どの部署から来ましたか。", "kana": "どのぶしょからきましたか。",
                         "english": "Which department did you come from?", "words": [] },
            "learner": { "japanese": "財務部から来ました。", "kana": "ざいむぶからきました。",
                         "english": "I came from the finance department.",
                         "words": [{ "ja": "財務部", "kana": "ざいむぶ", "en": "finance department" }] },
            "hintEn": "Say where you worked before"
          }
        ],
        "closing": { "japanese": "よろしくお願いします。", "kana": "よろしくおねがいします。",
                     "english": "I look forward to working with you.", "words": [] }
      }
    }
    """

    static let monologueJSON = """
    {
      "id": "my.speech01",
      "kind": "monologue",
      "description": "Introduce myself at the morning meeting",
      "createdAt": 1760000000000,
      "updatedAt": 1760000000000,
      "result": {
        "title": "Introducing myself", "titleJa": "自己紹介", "situationEn": "The morning meeting.",
        "placeEn": "", "partnerNameJa": "", "partnerNameEn": "", "partnerRole": "", "partnerGender": "male",
        "track": "everyday",
        "beats": [
          { "partner": { "japanese": "", "kana": "", "english": "", "words": [] },
            "learner": { "japanese": "おはようございます。", "kana": "おはようございます。", "english": "Good morning.",
                         "words": [{ "ja": "おはようございます", "kana": "おはようございます", "en": "good morning" }] },
            "hintEn": "Greet everyone" },
          { "partner": { "japanese": "", "kana": "", "english": "", "words": [] },
            "learner": { "japanese": "インドから来ました。", "kana": "いんどからきました。", "english": "I'm from India.",
                         "words": [{ "ja": "インド", "kana": "いんど", "en": "India" }] },
            "hintEn": "Say where you're from" }
        ],
        "closing": { "japanese": "", "kana": "", "english": "", "words": [] }
      }
    }
    """

    static func conversation() throws -> MyScene {
        try JSONDecoder().decode(MyScene.self, from: Data(conversationJSON.utf8))
    }

    static func monologue() throws -> MyScene {
        try JSONDecoder().decode(MyScene.self, from: Data(monologueJSON.utf8))
    }
}

@Suite("My scenes: the learner's own scenes as lessons")
struct MySceneTests {
    @Test func readsTheSharedShape() throws {
        let scene = try MySceneFixture.conversation()
        #expect(scene.id == "my.k3x9a1b2")
        #expect(scene.kind == .conversation)
        #expect(scene.createdAt == 1_760_000_000_000)
        #expect(scene.updatedAt == 1_760_000_500_000)
        #expect(scene.result.beats.count == 2)
        #expect(scene.result.beats[0].learner.words.count == 3)
        #expect(!scene.isMonologue)
    }

    @Test func writesTheSameShapeBack() throws {
        let scene = try MySceneFixture.conversation()
        let data = try JSONEncoder().encode(scene)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "kind", "description", "createdAt", "updatedAt", "result"])
        #expect(object["createdAt"] as? Double == 1_760_000_000_000)
        #expect(try JSONDecoder().decode(MyScene.self, from: data) == scene)
    }

    @Test func becomesAnOrdinaryScenario() throws {
        let lesson = try MySceneFixture.conversation().lesson(learnerName: "Swapnil")
        let scenario = lesson.scenario
        #expect(scenario.id == "my.k3x9a1b2")
        #expect(scenario.title == "Meeting the team leader")
        #expect(scenario.titleJa == "チームリーダーとの挨拶")
        #expect(scenario.track == .work)
        #expect(scenario.personaID == "my.k3x9a1b2.partner")
        #expect(scenario.placeEn == "in the office")
        #expect(scenario.targetTerms.isEmpty)
        #expect(scenario.field == nil)
        #expect(scenario.beats.map(\.id) == ["b1", "b2"])
        #expect(scenario.beats[1].line == "どの部署から来ましたか。")
        #expect(scenario.beats[1].english == "Which department did you come from?")
        #expect(scenario.beats[1].responses.map(\.japanese) == ["財務部から来ました。"])
        #expect(scenario.beats[1].responses.first?.kana == "ざいむぶからきました。")
        #expect(scenario.beats[1].hintEn == "Say where you worked before")
        #expect(scenario.beats[1].intentEn == "Say where you worked before")
        #expect(scenario.closingLine == "よろしくお願いします。")
        #expect(scenario.closingEnglish == "I look forward to working with you.")
        #expect(!scenario.isMonologue)
        #expect(scenario.isLearnersOwn)

        let persona = lesson.persona
        #expect(persona.id == "my.k3x9a1b2.partner")
        #expect(persona.nameJa == "田中さん")
        #expect(persona.nameEn == "Tanaka-san")
        #expect(persona.role == "Team leader")
        #expect(persona.voiceGender == .female)
        #expect(persona.speakingRate == 1)
    }

    @Test func theOtherPersonSaysTheLearnersName() throws {
        let lesson = try MySceneFixture.conversation().lesson(learnerName: "Swapnil")
        let first = lesson.scenario.beats[0]
        #expect(first.line == "Swapnilさん、はじめまして。田中です。")
        #expect(first.english == "Nice to meet you, Swapnil. I'm Tanaka.")
        // The learner's own line keeps the placeholder, filled when it's practised, as in built-in scenes.
        #expect(first.responses.first?.japanese == "はじめまして。{name}です。")
        #expect(lesson.glossary["Swapnilさん、はじめまして。田中です。"]?.first?.ja == "Swapnil")

        let nameless = try MySceneFixture.conversation().lesson(learnerName: "")
        #expect(nameless.scenario.beats[0].line == "はじめまして。田中です。")
        #expect(!nameless.scenario.beats[0].line.contains("{name}"))
    }

    @Test func everyLineHasItsWords() throws {
        let scene = try MySceneFixture.conversation()
        let library = ContentLibrary(items: []).including([scene], learnerName: "Swapnil")
        let scenario = try #require(library.scenario(id: scene.id))
        #expect(library.persona(id: scenario.personaID)?.nameEn == "Tanaka-san")
        let lines = library.lines(in: scenario, learnerName: "Swapnil")
        #expect(lines.map(\.japanese) == ["はじめまして。Swapnilです。", "財務部から来ました。"])
        #expect(library.words(in: lines[0].japanese).map(\.ja) == ["はじめまして", "Swapnil", "です"])
        #expect(library.words(in: lines[1].japanese).first?.en == "finance department")
        #expect(lines[0].partner?.nameEn == "Tanaka-san")
        #expect(lines[0].partner?.gender == .female)
    }

    @Test func aSpeechHasNoOtherSpeaker() throws {
        let scene = try MySceneFixture.monologue()
        #expect(scene.isMonologue)
        let library = ContentLibrary(items: []).including([scene], learnerName: "")
        let scenario = try #require(library.scenario(id: scene.id))
        #expect(scenario.isMonologue)
        #expect(scenario.closingLine.isEmpty)
        #expect(scenario.roleReversal)
        #expect(library.persona(id: scenario.personaID)?.nameEn == "Audience")
        let lines = library.lines(in: scenario, learnerName: "")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.partner == nil })
        // What to say next stands in for the other person's line.
        #expect(lines.map(\.situationEn) == ["Greet everyone", "Say where you're from"])
        #expect(library.partnerSideLines(in: scenario, learnerName: "").isEmpty)
    }

    @Test func builtInScenesAreUnchanged() throws {
        let library = try ContentLibrary.bundled()
        let scenario = try #require(library.scenario(id: "s.weekend.chat"))
        #expect(!scenario.isMonologue)
        #expect(!scenario.isLearnersOwn)
        #expect(library.lines(in: scenario, learnerName: "").allSatisfy { $0.situationEn == nil })
    }

    @Test func theLibraryKeepsItsOwnContentAndAddsTheScenes() throws {
        let bundled = try ContentLibrary.bundled()
        let scene = try MySceneFixture.conversation()
        let library = bundled.including([scene, try MySceneFixture.monologue()], learnerName: "Swapnil")
        #expect(library.scenarios.count == bundled.scenarios.count + 2)
        #expect(library.personas.count == bundled.personas.count + 2)
        #expect(library.items.count == bundled.items.count)
        #expect(library.glossary.count > bundled.glossary.count)
        // A work scene of the learner's own is practised whatever their field.
        #expect(library.forField(.finance).scenario(id: scene.id) != nil)
        #expect(library.forField(.engineering).scenario(id: scene.id) != nil)
        // Changing a scene replaces it rather than adding another.
        var changed = scene
        changed.result.title = "Meeting Tanaka-san"
        let again = library.including([changed], learnerName: "Swapnil")
        #expect(again.scenarios.count == library.scenarios.count)
        #expect(again.scenario(id: scene.id)?.title == "Meeting Tanaka-san")
    }

    @Test func aChangeKeepsTheSceneAndAddsToItsDescription() throws {
        let scene = try MySceneFixture.conversation()
        let later = Date(timeIntervalSince1970: 1_770_000_000)
        let changed = MyScene.saved(scene.result, kind: .monologue, description: "make it more casual",
                                    replacing: scene, now: later)
        #expect(changed.id == scene.id)
        #expect(changed.kind == .conversation)
        #expect(changed.createdAt == scene.createdAt)
        #expect(changed.updatedAt == 1_770_000_000_000)
        #expect(changed.description == "Meeting my new team leader at the bank\nChanged: make it more casual")

        let new = MyScene.saved(scene.result, kind: .monologue, description: "  A speech  ")
        #expect(new.id.hasPrefix("my."))
        #expect(new.id != scene.id)
        #expect(new.kind == .monologue)
        #expect(new.description == "A speech")
    }

    @Test func filesHoldOneSceneOrAList() throws {
        let one = Data(MySceneFixture.conversationJSON.utf8)
        #expect(try MyScene.scenes(fromFile: one).map(\.id) == ["my.k3x9a1b2"])

        let list = Data("[\(MySceneFixture.conversationJSON), {\"id\": \"not-a-scene\"}, \(MySceneFixture.monologueJSON)]".utf8)
        #expect(try MyScene.scenes(fromFile: list).map(\.id) == ["my.k3x9a1b2", "my.speech01"])

        #expect(throws: MyScene.FileError.noScenes) { try MyScene.scenes(fromFile: Data("[]".utf8)) }
        #expect(throws: MyScene.FileError.noScenes) { try MyScene.scenes(fromFile: Data("{\"hello\": 1}".utf8)) }

        let scenes = [try MySceneFixture.conversation(), try MySceneFixture.monologue()]
        #expect(try MyScene.scenes(fromFile: MyScene.file(scenes)) == scenes)
        #expect(try MyScene.scenes(fromFile: MyScene.file([scenes[0]])) == [scenes[0]])
    }

    @Test func toleratesWhatOtherAppsLeaveOut() throws {
        let json = """
        { "id": "my.min", "createdAt": "2026-10-19T10:00:00Z",
          "result": { "title": "Short", "beats": [ { "learner": { "japanese": "はい。" } } ] } }
        """
        let scene = try JSONDecoder().decode(MyScene.self, from: Data(json.utf8))
        #expect(scene.kind == .monologue)
        #expect(scene.description.isEmpty)
        #expect(scene.updatedAt == scene.createdAt)
        #expect(scene.createdDate == ISO8601DateFormatter().date(from: "2026-10-19T10:00:00Z"))
        #expect(scene.result.closing.isEmpty)
        #expect(scene.lesson().scenario.beats.count == 1)
    }

    @Test func theCoachsSceneIsSentBackAsJSON() throws {
        let scene = try MySceneFixture.conversation()
        let json = try scene.resultJSON()
        let back = try JSONDecoder().decode(SceneResult.self, from: Data(json.utf8))
        #expect(back == scene.result)
        #expect(json.contains("\"partnerNameEn\":\"Tanaka-san\""))
    }
}
