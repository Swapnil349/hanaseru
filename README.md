# Hanaseru（話せる）

A hands-free Japanese speaking coach for an engineer on India's high-speed rail project.
Listen → answer out loud → get feedback → try again, with the phone in your pocket.

- **Architecture & plan:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Status:** Milestone 1 — hands-free 2–30 minute sessions (listening, "say it naturally", role-play conversation, shadowing, closing phrase), mistake tracking, spaced repetition, adaptive difficulty, My Japanese, progress, privacy controls. Optional Claude-powered conversation via a small proxy.

## Repository layout

```
App/                      iOS app (SwiftUI, SwiftData, AVFoundation, Speech)
  Voice/                  audio session, mic engine + chime, speech recognition, TTS, AirPods controls
  Persistence/            SwiftData records, repository, settings, Keychain
  Session/                SessionViewModel (runner ⇄ UI ⇄ voice engine)
  Features/               Home, hands-free session, summary, My Japanese, Progress, Settings, Onboarding
  DesignSystem/           colours, buttons, cards, waveform, speaking indicator, feedback card…
Packages/HanaseruKit/     platform-neutral core (builds on macOS/Linux/Windows)
  LearningCore/           content model + JSON content, evaluator, knowledge model, SRS, difficulty, planner
  ConversationCore/       AIProvider protocol, offline provider, remote provider, fallback
  SessionCore/            hands-free session state machine + voice/persistence protocols
backend/                  optional Node proxy: holds the Anthropic key, calls Claude with structured outputs
project.yml               XcodeGen spec (the .xcodeproj is generated, not committed)
```

## Run the app (Mac required)

1. Install Xcode (16 or later) and XcodeGen: `brew install xcodegen`
2. Generate and open the project:

   ```bash
   xcodegen generate && open Hanaseru.xcodeproj
   ```

3. Select your team under *Signing & Capabilities*, pick your iPhone, Run.
   Speech recognition and the microphone need a **real device** for the hands-free test.
4. For a much better Japanese voice: iPhone *Settings › Accessibility › Spoken Content › Voices › Japanese* → download *Premium* or *Enhanced*.

> Milestone 1's Swift was written on Windows without a compiler. Expect a few compile errors on the first build; they should be small, local fixes.

### Core tests

```bash
cd Packages/HanaseruKit && swift test
```

Covers the evaluator, content integrity (every item's own sentence evaluates as natural, every reference resolves), spaced repetition, difficulty adaptation, planning, the offline conversation engine, fallback behaviour, the proxy wire format, and full scripted hands-free sessions (including pause, skip, stop, silence and 「もう一度」).

## Optional: AI coach (Claude)

Without it, sessions use the built-in scenarios and work fully offline. With it, role-play partners respond to what you actually say and answers get fuzzy semantic evaluation.

```bash
cd backend
npm install
export ANTHROPIC_API_KEY=sk-ant-...        # from console.anthropic.com
export APP_TOKEN=$(openssl rand -hex 24)   # the app's password for your proxy
npm start                                  # or: COACH_MOCK=1 npm start (no key, canned replies)
npm test                                   # proxy tests (mock coach, no network)
```

Deploy it anywhere that runs Node 22.18+ over HTTPS (Fly.io, Render, Railway, a small VPS). For a quick test on the same Wi-Fi, use your laptop's IP. Then in the app: *Settings › AI coach* → server URL + the same `APP_TOKEN` → *Save and test connection*.

Defaults: model `claude-opus-5-5`, `effort: low` (conversational latency), server-side refusal fallback enabled. Override with `COACH_MODEL` / `COACH_EFFORT`.

## The hands-free test (spec §62)

1. Open the app → **10 min** → **Start**.
2. Phone in pocket, AirPods in.
3. You hear 「今日は仕事の日本語を練習しましょう。」 → 「聞いてください。」 → a sentence → a question.
4. Chime + 「あなたの番です。」 → answer out loud. Stop talking and it moves on.
5. Feedback is spoken, communication first. A role-play follows, then shadowing.
6. 「今日の練習は終了です。」 → one phrase to remember → repeat it → 「お疲れさまでした。」
7. Press AirPods to pause/resume. Say 「もう一度」 to repeat, 「わかりません」 for the answer, 「スキップ」 to skip.

Lock the phone mid-session: it should keep going.

## Adding content

All Japanese lives in `Packages/HanaseruKit/Sources/LearningCore/Content/*.json` — never in views. Add phrases, vocabulary, scenarios or personas there; `swift test` checks references and that each item's own sentence evaluates as natural.

## Privacy

Audio is never recorded or stored. The mic is transcribed only during your turn (on-device when the Japanese model is installed, otherwise by Apple's speech service), and the screen always says which. Only the text of mistakes is kept, and *Settings › Privacy › Delete voice data* removes it. With the AI coach enabled, the text of your answers — never audio — goes to your proxy and to Anthropic.
