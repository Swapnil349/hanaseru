# Listen — hands-free scenes for driving and chores

A playlist of 5–10 short scenes, played back to back as an audio drama, for listening without looking at the
screen (driving, walking, housework). Nothing is asked of the learner: no microphone, no taps needed.

## Choices (one screen, remembered between uses)

- **Language**: *Japanese only*, or *Japanese + English* (each line in Japanese, then its English translation).
- **Length**: about **5 minutes** or about **10 minutes**.
- **Scenes from**: *My work* (the learner's field), *Everyday* (everyday + "Money in Japan" when the field is
  finance), *My scenes*, or *Everything*. A source with no scenes falls back to Everything.
- **Speed**: *Natural* (default) or *Slower*.
- One big **Play** button. Once playing, the screen shows what is playing (scene title, the current line in
  Japanese, kana/romaji if on, English) — but nothing needs to be looked at.

## The playlist

1. Take the scenes from the chosen source, shuffle them, but put scenes not heard in the last listens first
   (remember the ids of the last 30 scenes played).
2. Add scenes until the estimated duration reaches the target (≥ 5 or ≥ 10 minutes), with at least 3 and at most
   10 scenes (5-minute playlists usually hold 4–6 scenes, 10-minute ones 7–10).
3. Estimated duration of a line: Japanese characters ÷ 6 per second ÷ rate, plus (Japanese + English) English
   words ÷ 2.5 per second, plus the pauses below.

## What is said

For each scene, in order:

1. **Scene announcement.** *Japanese only*: 「場面{n}。{titleJa}。」 in the coach's Japanese voice.
   *Japanese + English*: "Scene {n}: {title}." in English, then 「{titleJa}」, then the situation in English
   (`situationEn`).
2. **Every line of the scene's script, in order**: each beat's partner line (the partner's voice; skipped when
   empty), then the learner's first response (a different voice: the coach's Japanese voice), then the closing
   line (partner's voice). `{name}` is replaced with the learner's name (or left out if there is none).
   *Japanese + English*: after each Japanese line, a 0.4 s pause, then its English in the English voice.
3. Pauses: 0.8 s after each line, 2.5 s between scenes.
4. After the last scene: *Japanese only* 「おしまいです。お疲れさまでした。」; *Japanese + English* also "That's
   the end. Well done."

Slower = rate 0.8 for Japanese (English stays at normal speed).

## Controls

On screen and from outside the app (lock screen / notification, AirPods and headphone buttons, car controls):
**Play/Pause**, **Next scene**, **Previous scene** (restarts the current scene if more than ~3 s into it).
Pausing keeps the position (the line); playing again repeats that line from its start. Phone calls and other
interruptions pause; playback continues when iOS / Android says it may.

The phones keep playing with the screen locked (iOS: the app's background audio mode; Android: a foreground
media-playback service with a media notification). Now Playing shows the scene title and "Hanaseru · Listen".

Scenes played in Listen are not marked as practised (it's listening, not speaking).
