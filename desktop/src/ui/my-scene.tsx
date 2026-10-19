import { useEffect, useRef, useState } from 'preact/hooks';
import { savedScene, saveScene, SceneKind, SceneRequest, writeScene } from '../myScenes';
import { EnglishDictation } from '../voice';
import { go, useApp } from './app';
import { Chip, PageHeader } from './common';

const LEVELS = [
  { level: 2, title: 'Simple' },
  { level: 3, title: 'Everyday' },
  { level: 5, title: 'Advanced' },
];

const POLITENESS: { value: SceneRequest['politeness']; title: string }[] = [
  { value: 'casual', title: 'Casual (friends)' },
  { value: 'professional', title: 'Polite (work)' },
  { value: 'veryPolite', title: 'Very polite (clients, seniors)' },
];

/** Describe a conversation or a speech in English; the coach writes it as a scene to learn. With `editID`, change one. */
export function MySceneEditor(props: { editID?: string }) {
  const { prefs } = useApp();
  const editing = props.editID ? savedScene(props.editID) : undefined;
  const [kind, setKind] = useState<SceneKind>(editing?.kind ?? 'conversation');
  const [description, setDescription] = useState('');
  const [length, setLength] = useState(editing?.result.beats.length ?? 6);
  const [level, setLevel] = useState(3);
  const [politeness, setPoliteness] = useState<SceneRequest['politeness']>('professional');
  const [dictating, setDictating] = useState(false);
  const [busySince, setBusySince] = useState<number | null>(null);
  const [now, setNow] = useState(Date.now());
  const [error, setError] = useState('');
  const dictation = useRef<EnglishDictation | null>(null);
  const before = useRef('');

  useEffect(() => () => dictation.current?.stop(), []);
  useEffect(() => {
    if (busySince === null) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [busySince]);

  if (props.editID && !editing) return <div class="page"><PageHeader title="Scene not found" back="#/scenes" /></div>;

  function toggleDictation() {
    if (dictating) {
      dictation.current?.stop();
      return;
    }
    before.current = description.trim();
    const d = new EnglishDictation();
    dictation.current = d;
    setDictating(true);
    d.start((text) => setDescription(((before.current ? before.current + ' ' : '') + text).trim()), () => setDictating(false));
  }

  async function write() {
    dictation.current?.stop();
    if (!description.trim()) {
      setError(editing ? 'Say or type what to change.' : 'Say or type what the scene is about.');
      return;
    }
    setError('');
    setBusySince(Date.now());
    try {
      const scene = await writeScene({ url: prefs.coachURL, token: prefs.coachToken },
        { description: description.trim(), kind, learnerName: prefs.name, learnerLevel: level, politeness, length }, editing);
      saveScene(scene);
      go(`scene/${encodeURIComponent(scene.id)}`);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusySince(null);
    }
  }

  const seconds = busySince === null ? 0 : Math.round((now - busySince) / 1000);
  const examples = kind === 'conversation'
    ? ['Asking my manager for two days off next week for a family wedding in India.',
       'Ordering lunch for my team at a bento shop and asking about vegetarian options.',
       'Explaining to a client that the bank transfer will be delayed by one day.']
    : ['A short self-introduction for my first day: my name, that I am from Mumbai, my work and my hobbies.',
       'A two-minute status report on our project for the Monday meeting.',
       'A thank-you speech at my farewell party.'];

  return (
    <div class="page narrow">
      <PageHeader title={editing ? `Change “${editing.result.title}”` : 'New scene'} back={editing ? `#/scene/${encodeURIComponent(editing.id)}` : '#/scenes'}
                  subtitle={editing ? 'Describe what to change: add a line, make it more polite, change a detail…' : 'Describe a situation from your life in English. The coach writes it in Japanese for you to learn.'} />

      <section class="card form">
        {!editing && (
          <>
            <div class="label">What kind</div>
            <div class="chips">
              <Chip selected={kind === 'conversation'} onClick={() => setKind('conversation')}>💬 A conversation</Chip>
              <Chip selected={kind === 'monologue'} onClick={() => setKind('monologue')}>🎤 A speech (only you speak)</Chip>
            </div>
          </>
        )}

        <label>
          {editing ? 'What to change' : 'Describe it'}
          <textarea class="describe" rows={5} value={description} placeholder={examples[0]}
                    onInput={(e) => setDescription((e.target as HTMLTextAreaElement).value)} />
        </label>
        <div class="row">
          {EnglishDictation.isAvailable && (
            <button type="button" class={'button' + (dictating ? ' record' : '')} onClick={toggleDictation}>
              {dictating ? <><span class="rec-dot" aria-hidden="true" /> Stop</> : '🎙 Speak in English'}
            </button>
          )}
          {dictating && <span class="muted small">Listening… speak naturally; press Stop when you've finished.</span>}
        </div>
        {!editing && (
          <details class="examples">
            <summary class="muted small">Examples</summary>
            <ul>{examples.map((e) => <li key={e}><button type="button" class="link" onClick={() => setDescription(e)}>{e}</button></li>)}</ul>
          </details>
        )}

        <div class="label">{kind === 'monologue' ? 'Sentences' : 'Exchanges'}: {length}</div>
        <input type="range" min={2} max={12} step={1} value={length} class="scrubber"
               onInput={(e) => setLength(Number((e.target as HTMLInputElement).value))} aria-label="Length" />
        <div class="label">Japanese level</div>
        <div class="chips">
          {LEVELS.map((l) => <Chip key={l.level} selected={level === l.level} onClick={() => setLevel(l.level)}>{l.title}</Chip>)}
        </div>
        <div class="label">Politeness</div>
        <div class="chips">
          {POLITENESS.map((p) => <Chip key={p.value} selected={politeness === p.value} onClick={() => setPoliteness(p.value)}>{p.title}</Chip>)}
        </div>

        {error && <p class="notice">{error}{!prefs.coachToken && <> <a href="#/settings">Open Settings</a></>}</p>}
        <div class="row">
          <button type="button" class="button primary big" disabled={busySince !== null} onClick={write}>
            {busySince !== null ? `✨ Writing your scene… ${seconds} s` : editing ? '✨ Change my scene' : '✨ Write my scene'}
          </button>
        </div>
        {busySince !== null && (
          <p class="muted small">
            {seconds < 40 ? 'Claude is writing the Japanese, the kana, the English and every word’s meaning.'
              : 'Still writing — the coach server may have been asleep and takes a minute to wake up.'}
          </p>
        )}
        {!prefs.coachToken && !error && (
          <p class="muted small">This uses the AI coach: add its passphrase in <a href="#/settings">Settings › AI coach</a> first.</p>
        )}
      </section>
    </div>
  );
}
