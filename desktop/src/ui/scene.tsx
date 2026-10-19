import { useEffect, useMemo, useRef, useState } from 'preact/hooks';
import { library } from '../content';
import { bestSimilarity } from '../japaneseText';
import { Mode, MODES } from '../practice';
import { romajiOf } from '../romaji';
import { script, ScriptEntry, scriptText } from '../script';
import { deleteScene, isMonologue, isOwn, savedScene } from '../myScenes';
import { resumePoint } from '../store';
import { go, practicePath, useApp } from './app';
import { Chip, JapaneseBlock, PageHeader, WordsButton } from './common';

/** One scene: practise it, or read and hear its whole script, line by line. */
export function SceneDetail(props: { id: string }) {
  const { prefs, setPrefs, speaker, listener } = useApp();
  const scenario = library.scenario(props.id);
  const entries = useMemo(() => (scenario ? script(library, scenario, prefs.name) : []), [scenario, prefs.name]);
  const words = useMemo(() => (scenario ? library.vocabularyIn(scenario) : []), [scenario]);
  const [asPartner, setAsPartner] = useState(false);
  const [mode, setMode] = useState<Mode>('automatic');
  const [playing, setPlaying] = useState<string | null>(null);
  const [testMe, setTestMe] = useState(false);
  const [slowly, setSlowly] = useState(false);
  const [revealed, setRevealed] = useState<Set<string>>(new Set());
  const [saying, setSaying] = useState<string | null>(null);
  const [heard, setHeard] = useState<Record<string, string>>({});
  const [copied, setCopied] = useState(false);
  const playToken = useRef(0);

  useEffect(() => () => {
    playToken.current++;
    speaker.stop();
    listener.cancel();
  }, []);

  if (!scenario) {
    return <div class="page"><PageHeader title="Scene not found" back="#/scenes" /></div>;
  }
  const persona = library.persona(scenario.personaID);
  const colleague = persona?.nameEn || 'the colleague';
  const own = isOwn(scenario.id);
  const monologue = isMonologue(scenario);

  function exportScene() {
    const saved = savedScene(scenario!.id);
    if (!saved) return;
    const url = URL.createObjectURL(new Blob([JSON.stringify(saved, null, 2)], { type: 'application/json' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = `${scenario!.title}.json`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  function removeScene() {
    if (!confirm(`Delete your scene “${scenario!.title}”? This can't be undone.`)) return;
    deleteScene(scenario!.id);
    go('scenes');
  }
  const resume = resumePoint.load(scenario.id, asPartner);

  // Plays lines one after another in their speakers' voices, like the conversation itself.
  async function play(lines: ScriptEntry[]) {
    const token = ++playToken.current;
    listener.cancel();
    speaker.stop();
    for (const entry of lines) {
      if (token !== playToken.current) return;
      setPlaying(entry.id);
      await speaker.speak(entry.japanese, entry.voice, slowly ? 0.7 : 0.95);
      await new Promise((r) => setTimeout(r, 350));
    }
    if (token === playToken.current) setPlaying(null);
  }

  function stopPlaying() {
    playToken.current++;
    speaker.stop();
    setPlaying(null);
  }

  async function say(entry: ScriptEntry) {
    stopPlaying();
    setSaying(entry.id);
    setHeard((h) => ({ ...h, [entry.id]: '' }));
    const text = await listener.listen((partial) => setHeard((h) => ({ ...h, [entry.id]: partial })));
    setHeard((h) => ({ ...h, [entry.id]: text }));
    setSaying(null);
  }

  const text = scriptText(scenario.title, scenario.situationEn, entries);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      setCopied(false);
    }
  }

  function save() {
    const url = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = `${scenario!.title}.txt`;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  return (
    <div class="page">
      <PageHeader title={scenario.title} subtitle={scenario.titleJa} back="#/scenes">
        <button type="button" class="button" onClick={copy} title="Japanese, romaji and English, to paste anywhere">
          {copied ? '✓ Copied' : 'Copy script'}
        </button>
        <button type="button" class="button" onClick={save}>Save as text</button>
        {own && (
          <>
            <a class="button" href={`#/my-scene/edit/${encodeURIComponent(scenario.id)}`}>✎ Change this scene</a>
            <button type="button" class="button" onClick={exportScene}>Export</button>
            <button type="button" class="button danger" onClick={removeScene}>Delete</button>
          </>
        )}
      </PageHeader>
      <p class="lead">{scenario.situationEn}</p>

      <div class="two-column">
        <section class="card practise-card">
          <h2>Practise speaking</h2>
          {!monologue && (
            <>
              <div class="label">You play</div>
              <div class="chips">
                <Chip selected={!asPartner} onClick={() => setAsPartner(false)}>Yourself</Chip>
                <Chip selected={asPartner} onClick={() => setAsPartner(true)}>{colleague}</Chip>
              </div>
            </>
          )}
          <div class="label">Lesson</div>
          <div class="chips">
            {MODES.map((option) => (
              <Chip key={option.mode} selected={mode === option.mode} onClick={() => setMode(option.mode)} title={option.detail}>
                {option.title}
              </Chip>
            ))}
          </div>
          <p class="muted small">{MODES.find((m) => m.mode === mode)?.detail}</p>
          <div class="row">
            <button type="button" class="button primary big" onClick={() => go(practicePath(scenario.id, mode, asPartner))}>
              🎙 Start practising
            </button>
            {resume !== null && (
              <button type="button" class="button big" onClick={() => go(practicePath(scenario.id, mode, asPartner, resume))}>
                Continue where you stopped
              </button>
            )}
          </div>
        </section>

        <section class="card">
          <h2>Listen and read</h2>
          <button type="button" class="button primary big" onClick={() => (playing ? stopPlaying() : play(entries))}>
            {playing ? '■ Stop' : '▶ Play the whole conversation'}
          </button>
          <div class="chips">
            <Chip selected={prefs.showEnglish} onClick={() => setPrefs({ showEnglish: !prefs.showEnglish })}>English</Chip>
            <Chip selected={prefs.showRomaji} onClick={() => setPrefs({ showRomaji: !prefs.showRomaji })}>Romaji</Chip>
            <Chip selected={testMe} onClick={() => { setTestMe(!testMe); setRevealed(new Set()); }}
                  title="Hide your lines; say them from the English">Test me</Chip>
            <Chip selected={slowly} onClick={() => setSlowly(!slowly)}>Slowly</Chip>
          </div>
        </section>
      </div>

      <h2 class="section-title">The conversation</h2>
      <div class="script">
        {entries.map((entry) => {
          const hidden = testMe && entry.isLearner && !revealed.has(entry.id);
          const result = heard[entry.id];
          const score = result ? bestSimilarity(result, [entry.japanese, entry.kana]) : 0;
          return (
            <article key={entry.id} class={'script-row' + (entry.isLearner ? ' learner' : '') + (playing === entry.id ? ' playing' : '')}>
              <div class="speaker">{entry.speaker}</div>
              {hidden ? (
                <div>
                  <div class="english">{entry.english}</div>
                  <button type="button" class="link" onClick={() => setRevealed(new Set([...revealed, entry.id]))}>
                    Show the Japanese
                  </button>
                </div>
              ) : (
                <JapaneseBlock japanese={entry.japanese} kana={entry.kana} romaji={entry.romaji} english={entry.english}
                               showRomaji={prefs.showRomaji} showEnglish={prefs.showEnglish} />
              )}
              <div class="row">
                <button type="button" class="button" onClick={() => play([entry])}>🔊 Hear</button>
                {listener.isAvailable && (
                  <button type="button" class="button signal" disabled={saying !== null} onClick={() => say(entry)}>
                    🎙 {saying === entry.id ? 'Listening…' : 'Say it'}
                  </button>
                )}
                {!hidden && (
                  <WordsButton lines={[{ title: entry.isLearner ? 'Your line' : 'Their line', japanese: entry.japanese, english: entry.english }]}
                               onSay={(word) => void speaker.speak(word, 'coach', 0.9)} />
                )}
                {entry.isLearner && entry.line !== undefined && (
                  <button type="button" class="link" title="Practise the conversation from this line"
                          onClick={() => go(practicePath(scenario.id, 'conversation', false, 1 + 2 * entry.line!))}>
                    ▶ From here
                  </button>
                )}
              </div>
              {result !== undefined && saying !== entry.id && (
                <div class={'feedback' + (score >= 0.8 ? ' good' : '')}>
                  {!result ? 'Nothing heard. Press Say it and speak after the chime.'
                    : score >= 0.8 ? `✓ That's it: 「${result}」`
                    : score >= 0.5 ? `Close. Heard 「${result}」. Hear it and try again.`
                    : `Heard 「${result}」. Hear it and try again.`}
                </div>
              )}
              {saying === entry.id && result && <div class="feedback">「{result}」</div>}
            </article>
          );
        })}
      </div>

      {words.length > 0 && (
        <>
          <h2 class="section-title">Words in this conversation</h2>
          <ul class="word-table">
            {words.map((term) => (
              <li key={term.id}>
                <button type="button" class="word-row" onClick={() => void speaker.speak(term.japanese, 'coach', 0.9)}>
                  <span class="word-ja">
                    <span lang="ja" class="jp-small">{term.japanese}</span>
                    <span class="muted small">
                      {term.kana !== term.japanese ? `${term.kana} · ` : ''}{term.romaji || romajiOf(term.japanese, term.kana)}
                    </span>
                  </span>
                  <span class="word-en">{term.english}</span>
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
