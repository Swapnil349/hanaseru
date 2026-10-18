import { useEffect, useMemo, useState } from 'preact/hooks';
import { library } from '../content';
import { Mode, PracticeState, ScenePractice, stopTitle } from '../practice';
import { romajiOf } from '../romaji';
import { resumePoint } from '../store';
import { go, useApp } from './app';
import { Chip, JapaneseBlock, PageHeader, WordsButton } from './common';
import { Stage } from './stage';

/** A scene practised hands-free, with the characters, the lines on screen, and full control of where you are. */
export function Practice(props: { id: string; mode: Mode; partner: boolean; from: number | null }) {
  const { prefs, setPrefs, speaker, listener, progress } = useApp();
  const scenario = library.scenario(props.id);
  const practice = useMemo(
    () => (scenario ? new ScenePractice(library, scenario, speaker, listener, progress, props.mode, props.partner, prefs.name) : null),
    [],
  );
  const [state, setState] = useState<PracticeState | null>(practice?.state ?? null);
  const [dragging, setDragging] = useState<number | null>(null);
  // Browsers only speak after a click on the page; opened from a link it waits for one.
  const [started, setStarted] = useState(() => (navigator as { userActivation?: { hasBeenActive: boolean } }).userActivation?.hasBeenActive ?? true);

  useEffect(() => {
    if (!practice) return;
    const unsubscribe = practice.subscribe(setState);
    return () => {
      unsubscribe();
      practice.stop();
    };
  }, [practice]);

  useEffect(() => {
    if (practice && started) practice.start(props.from ?? undefined);
  }, [practice, started]);

  // Where you are is kept, so next time you can continue from there.
  useEffect(() => {
    if (!practice || !state || !scenario) return;
    if (state.activity === 'finished') resumePoint.clear(scenario.id, props.partner);
    else if (state.position > 0) resumePoint.save(scenario.id, props.partner, state.position);
  }, [state?.position, state?.activity]);

  // Keyboard: Space pause / play, ← back, → next, R again.
  useEffect(() => {
    if (!practice) return;
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement;
      if (target.closest('input, select, textarea, [role="dialog"]')) return;
      if (event.key === ' ') { event.preventDefault(); practice.togglePause(); }
      else if (event.key === 'ArrowRight') practice.next();
      else if (event.key === 'ArrowLeft') practice.previous();
      else if (event.key === 'r' || event.key === 'R') practice.again();
    };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [practice]);

  if (!scenario || !practice || !state) {
    return <div class="page"><PageHeader title="Scene not found" back="#/scenes" /></div>;
  }

  const persona = practice.persona;
  const other = props.partner ? 'Your usual part' : persona?.nameEn || 'Colleague';
  const you = props.partner ? `${persona?.nameEn || 'Colleague'} · you` : 'You';
  const line = state.line;
  const paused = state.activity === 'paused';
  const finished = state.activity === 'finished';
  const stops = practice.stops;
  const shown = Math.min(Math.max(dragging ?? state.position, 0), stops.length - 1);
  const pauseForWords = () => { if (!paused) practice.pause(); };

  const bubble = (japanese: string, kana: string, english: string, active: boolean, onClick: () => void) => (
    <button type="button" class={'bubble' + (active ? ' active' : '')} onClick={onClick} title="Hear it again">
      <span lang="ja" class="jp-small">{japanese}</span>
      {prefs.showRomaji && <span class="romaji small">{romajiOf(japanese, kana)}</span>}
      {prefs.showEnglish && english && <span class="english small">{english}</span>}
    </button>
  );
  const otherBubble = state.otherJapanese
    ? bubble(state.otherJapanese, state.otherKana, state.otherEnglish, state.speaking === 'other',
             () => practice.hear(state.otherJapanese, false))
    : null;
  const learnerBubble = line
    ? state.answerShown
      ? bubble(line.japanese, line.kana, line.english, state.speaking === 'you', () => practice.hear(line.japanese, true))
      : <div class="bubble thought">💭 {line.cueEn}</div>
    : null;

  return (
    <div class="page practice-page">
      <PageHeader title={scenario.title} subtitle={state.step} back={`#/scene/${encodeURIComponent(scenario.id)}`} />

      <Stage persona={persona} place={scenario.placeEn ?? ''} otherTalking={state.speaking === 'other'}
             learnerTalking={state.speaking === 'you' && state.activity !== 'listening'}
             yourTurn={state.activity === 'listening'} swapped={props.partner}
             otherBubble={otherBubble} learnerBubble={learnerBubble} />

      {!started && (
        <div class="notice center">
          <button type="button" class="button primary big" onClick={() => setStarted(true)}>▶ Start</button>
        </div>
      )}

      <div class="speaker-cards">
        {state.otherJapanese && (
          <section class={'card speaker-card' + (state.speaking === 'other' ? ' active' : '')}>
            <div class="speaker">{other}</div>
            <JapaneseBlock japanese={state.otherJapanese} kana={state.otherKana} english={state.otherEnglish}
                           showRomaji={prefs.showRomaji} showEnglish={prefs.showEnglish} />
            <div class="row">
              <button type="button" class="button" onClick={() => practice.hear(state.otherJapanese, false)}>🔊 Hear</button>
              <WordsButton lines={[{ title: other, japanese: state.otherJapanese, english: state.otherEnglish }]}
                           onSay={(word) => practice.hear(word, true)} onOpen={pauseForWords} />
            </div>
          </section>
        )}
        {line && (
          <section class={'card speaker-card' + (state.speaking === 'you' || state.activity === 'listening' ? ' active you' : '')}>
            <div class="speaker">{you}</div>
            <div class="cue">{line.cueEn}</div>
            {state.answerShown
              ? <JapaneseBlock japanese={line.japanese} kana={line.kana} showRomaji={prefs.showRomaji} showEnglish={false} large />
              : <p class="muted small">Your turn: the Japanese shows after you answer.</p>}
            <div class="row">
              <button type="button" class="button" onClick={() => practice.hear(line.japanese, true)}>🔊 Hear</button>
              <button type="button" class="button" onClick={() => practice.hear(line.japanese, true, true)}>🐢 Slowly</button>
              {state.answerShown && (
                <WordsButton lines={[{ title: 'Your line', japanese: line.japanese, english: line.english }]}
                             onSay={(word) => practice.hear(word, true)} onOpen={pauseForWords} />
              )}
            </div>
          </section>
        )}
      </div>

      <div class="status" aria-live="polite">
        {state.activity === 'listening' && <b class="signal-text">🎙 あなたの番です · Your turn — speak now</b>}
        {state.activity === 'speaking' && <b class="line-text">聞いてください · Listen</b>}
        {paused && <span class="muted">Paused. Hear any line as often as you like, then press Play.</span>}
        {finished && <b class="go-text">お疲れさまでした · Well done</b>}
        {state.heard && <div>Heard: <span lang="ja">{state.heard}</span></div>}
        {state.feedback && <div class="muted">{state.feedback}</div>}
        {listener.denied && <div class="notice">The microphone is blocked. Allow it from the lock icon by the address, then press Again.</div>}
      </div>

      <div class="controls">
        <div class="scrub-head">
          <span class="line-text small">{stopTitle(stops[shown])}</span>
          {dragging === null && !stops[shown].isAnswer && stops[shown].line !== null && (
            <button type="button" class="link small" onClick={() => practice.seek(shown + 1)}>Go to the answer</button>
          )}
        </div>
        <input type="range" class="scrubber" min={0} max={stops.length - 1} step={1} value={shown}
               aria-label="Where you are in the scene" aria-valuetext={stopTitle(stops[shown])}
               onInput={(e) => setDragging(Number((e.target as HTMLInputElement).value))}
               onChange={(e) => { practice.seek(Number((e.target as HTMLInputElement).value)); setDragging(null); }} />
        <div class="control-row">
          <button type="button" class="button step" onClick={() => practice.previous()} title="Back (←)">⏮<span>Back</span></button>
          <button type="button" class="button step" onClick={() => practice.again()} title="Again (R)">↺<span>Again</span></button>
          <button type="button" class="button primary play" onClick={() => (finished ? go(`scene/${encodeURIComponent(scenario.id)}`) : practice.togglePause())}
                  title="Pause / play (Space)">
            {finished ? 'Done' : paused ? '▶ Play' : '❚❚ Pause'}
          </button>
          <button type="button" class="button step" onClick={() => practice.next()} title="Next (→)">⏭<span>Next</span></button>
          <div class="chips">
            <Chip selected={prefs.showEnglish} onClick={() => setPrefs({ showEnglish: !prefs.showEnglish })}>English</Chip>
            <Chip selected={prefs.showRomaji} onClick={() => setPrefs({ showRomaji: !prefs.showRomaji })}>Romaji</Chip>
          </div>
        </div>
      </div>
    </div>
  );
}
