# My scenes — the learner's own conversations and speeches

The learner describes a situation in English (spoken or typed) and the AI coach writes a scene the app teaches
like any other: a **conversation** with someone, or a **monologue** (self-introduction, presentation, speech).
Scenes are saved on the device, can be changed later by describing the change, and can be deleted, exported and
imported (a `.json` file) so they move between the iPhone, Android and Windows apps.

## Coach endpoint

`POST /v1/scene` (Bearer token, like every coach call). It can take 20–90 s (and up to a minute more while the free
server wakes up): clients wait up to 3 minutes and show progress text meanwhile.

Request:

```json
{
  "description": "I want to introduce myself to my new team at the bank",
  "kind": "conversation" | "monologue",
  "learnerName": "Swapnil",
  "learnerLevel": 3,
  "politeness": "casual" | "professional" | "veryPolite",
  "length": 6,
  "previous": "<the scene JSON as returned before, when revising>"
}
```

Response (`SceneResult`):

```json
{
  "title": "Meeting the new team", "titleJa": "新しいチームへの挨拶",
  "situationEn": "…", "placeEn": "in the office",
  "partnerNameJa": "田中さん", "partnerNameEn": "Tanaka-san", "partnerRole": "Team leader", "partnerGender": "female",
  "track": "work" | "everyday",
  "beats": [
    { "partner": SceneLine, "learner": SceneLine, "hintEn": "Say your name" }
  ],
  "closing": SceneLine
}
```

`SceneLine` = `{ "japanese", "kana", "english", "words": [{ "ja", "kana", "en" }] }`. In a monologue every `partner`
and the `closing` have all fields empty. Lines may contain `{name}` (the learner's name), in `japanese`, `kana` and
as its own word.

## Saved scene (the same on every platform)

A saved scene is `{ "id": "my.<random>", "kind", "description", "createdAt", "updatedAt", "result": SceneResult }`,
stored as JSON on the device. Export and import use this exact shape (a single object, or an array of them).

To practise, it becomes an ordinary `Scenario` (the content format in `Packages/HanaseruKit/Sources/LearningCore/Content`):

| Scenario field | From |
|---|---|
| `id` | the saved id |
| `title`, `titleJa`, `situationEn`, `placeEn`, `track` | `result` |
| `personaID` | `<id>.partner`, a persona made from `partnerNameJa/En`, `partnerRole`, `partnerGender` (speakingRate 1) |
| `beats[i].line/kana/english` | `beats[i].partner` (empty strings in a monologue) |
| `beats[i].responses` | one response from `beats[i].learner` (`japanese`, `kana`, `english`) |
| `beats[i].hintEn`, `intentEn` | `hintEn` |
| `beats[i].id` | `b1`, `b2`, … |
| `closingLine/Kana/English` | `closing` |
| `targetTerms` | empty |
| `field` | none |

Every line's `words` go into the word list (glossary) so the **Words** button works, keyed by the line's Japanese.

A monologue has no partner lines: each beat is the learner speaking. Practice: watch (the model says each
sentence), practise (repeat each after the model), then say each from its English cue.
