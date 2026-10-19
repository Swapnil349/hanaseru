import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { audioOf, getMeeting, type Meeting } from '../meetings/db';
import { AudioClipPlayer, DrillState, MeetingDrill } from '../meetings/drill';
import { clock } from '../meetings/session';
import { romajiOf } from '../romaji';
import { useApp } from './app';
import { Chip, PageHeader, WordsButton } from './common';

/** Practising a meeting's lines: the real voice, a clear voice, then you. */
export function MeetingPractice(props: { id: string; which: 'all' | 'starred' }) {
  const [meeting, setMeeting] = useState<Meeting | null | undefined>(undefined);
  const [audioURL, setAudioURL] = useState('');
  useEffect(() => {
    let url = '';
    void getMeeting(props.id).then(async (m) => {
      setMeeting(m ?? null);
      const blob = m ? await audioOf(m.id, m.audioType) : null;
      if (blob) {
        url = URL.createObjectURL(blob);
        setAudioURL(url);
      }
    });
    return () => { if (url) URL.revokeObjectURL(url); };
  }, [props.id]);

  if (meeting === undefined || (meeting && !audioURL)) return <div class="page"><p class="muted">Loading…</p></div>;
  if (!meeting) return <div class="page"><PageHeader title="Meeting not found" back="#/meetings" /></div>;
  const lines = props.which === 'starred' ? meeting.lines.filter((l) => l.starred) : meeting.lines;
  if (!lines.length) return <div class="page"><PageHeader title={meeting.title} back={`#/meeting/${meeting.id}`} /><p>No lines to practise.</p></div>;
  return <Drill meeting={meeting} lines={lines} audioURL={audioURL} />;
}

function Drill(props: { meeting: Meeting; lines: Meeting['lines']; audioURL: string }) {
  const { prefs, setPrefs, speaker, listener } = useApp();
  const audio = useRef<HTMLAudioElement>(null);
  const [options, setOptions] = useState({ original: true, clear: true, speak: listener.isAvailable });
  const [hideJapanese, setHideJapanese] = useState(false);
  const clips = useRef<AudioClipPlayer | null>(null);
  const clip = () => (clips.current ??= new AudioClipPlayer(audio.current!));
  const drill = useMemo(() => new MeetingDrill(props.lines, speaker, listener, {
    play: (start, end) => (audio.current ? clip().play(start, end) : Promise.resolve()),
    stop: () => clips.current?.stop(),
  }, options), []);
  const [state, setState] = useState<DrillState>(drill.state);

  useEffect(() => {
    const unsubscribe = drill.subscribe(setState);
    return () => { unsubscribe(); drill.stop(); };
  }, [drill]);

  useEffect(() => {
    drill.options = options;
  }, [options]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if ((event.target as HTMLElement).closest('input, select, textarea, [role="dialog"]')) return;
      if (event.key === ' ') { event.preventDefault(); drill.togglePause(); }
      else if (event.key === 'ArrowRight') drill.next();
      else if (event.key === 'ArrowLeft') drill.previous();
      else if (event.key === 'r' || event.key === 'R') drill.again();
    };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [drill]);

  const line = props.lines[state.index];
  const revealed = !hideJapanese || state.activity === 'clear' || !!state.feedback || state.activity === 'paused';
  const romaji = romajiOf(line.japanese, line.kana ?? '');
  const idle = state.activity === 'idle';
  const paused = state.activity === 'paused' || state.activity === 'finished' || idle;
  const toggle = (key: keyof typeof options) => setOptions({ ...options, [key]: !options[key] });

  return (
    <div class="page practice-page">
      <PageHeader title={props.meeting.title} subtitle={`Line ${state.index + 1} of ${props.lines.length} · ${clock(line.start)}`}
                  back={`#/meeting/${props.meeting.id}`} />
      <audio ref={audio} src={props.audioURL} preload="auto" />

      <section class={'card drill-card' + (state.activity === 'listening' ? ' your-turn' : '')}>
        <div class="label">
          {state.activity === 'original' && '🔉 What was said'}
          {state.activity === 'clear' && '🔊 In a clear voice'}
          {state.activity === 'listening' && '🎙 Your turn — say it'}
          {(state.activity === 'paused' || idle) && 'Paused'}
          {state.activity === 'finished' && 'お疲れさまでした · Done'}
        </div>
        {revealed ? (
          <div class="jp-block large">
            <div class="jp" lang="ja">{line.japanese}</div>
            {line.kana && line.kana !== line.japanese && <div class="kana" lang="ja">{line.kana}</div>}
            {prefs.showRomaji && romaji && <div class="romaji">{romaji}</div>}
          </div>
        ) : (
          <p class="muted">Listen, then say what you heard. The Japanese shows after your turn.</p>
        )}
        {prefs.showEnglish && line.english && <div class="english">{line.english}</div>}
        {state.heard && <div>Heard: <span lang="ja">{state.heard}</span></div>}
        {state.feedback && <div class={'feedback' + (state.feedback.startsWith('✓') ? ' good' : '')}>{state.feedback}</div>}
        <div class="row">
          <button type="button" class="button" onClick={() => { drill.pause(); void clip().play(line.start, line.end); }}>🔉 Recording</button>
          <button type="button" class="button" onClick={() => { drill.pause(); void speaker.speak(line.japanese, 'coach', 0.85); }}>🔊 Clear voice</button>
          <button type="button" class="button" onClick={() => { drill.pause(); void speaker.speak(line.japanese, 'coach', 0.65); }}>🐢 Slowly</button>
          {line.words && line.words.length > 0 && (
            <WordsButton lines={[{ title: 'This line', japanese: line.japanese, english: line.english ?? '', words: line.words }]}
                         onSay={(word) => void speaker.speak(word, 'coach', 0.9)} onOpen={() => drill.pause()} />
          )}
        </div>
      </section>

      <div class="chips drill-options">
        <Chip selected={options.original} onClick={() => toggle('original')}>Play the recording</Chip>
        <Chip selected={options.clear} onClick={() => toggle('clear')}>Clear voice</Chip>
        {listener.isAvailable && <Chip selected={options.speak} onClick={() => toggle('speak')}>I say it</Chip>}
        <Chip selected={hideJapanese} onClick={() => setHideJapanese(!hideJapanese)}>Hide the Japanese first</Chip>
      </div>
      {listener.denied && <p class="notice">The microphone is blocked. Allow it from the lock icon by the address, then press Again.</p>}

      <div class="controls">
        <div class="scrub-head"><span class="line-text small">Line {state.index + 1} of {props.lines.length}</span></div>
        <input type="range" class="scrubber" min={0} max={props.lines.length - 1} step={1} value={state.index}
               aria-label="Which line" onChange={(e) => drill.go(Number((e.target as HTMLInputElement).value))} />
        <div class="control-row">
          <button type="button" class="button step" onClick={() => drill.previous()} title="Back (←)">⏮<span>Back</span></button>
          <button type="button" class="button step" onClick={() => drill.again()} title="Again (R)">↺<span>Again</span></button>
          <button type="button" class="button primary play" onClick={() => (idle ? drill.start() : drill.togglePause())} title="Play / pause (Space)">
            {paused ? '▶ Play' : '❚❚ Pause'}
          </button>
          <button type="button" class="button step" onClick={() => drill.next()} title="Next (→)">⏭<span>Next</span></button>
          <div class="chips">
            <Chip selected={prefs.showEnglish} onClick={() => setPrefs({ showEnglish: !prefs.showEnglish })}>English</Chip>
            <Chip selected={prefs.showRomaji} onClick={() => setPrefs({ showRomaji: !prefs.showRomaji })}>Romaji</Chip>
          </div>
        </div>
      </div>
    </div>
  );
}
