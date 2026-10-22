import { useEffect, useState } from 'preact/hooks';
import { library } from '../content';
import { buildPlaylist, endingOf, ListenOptions, ListenPlayer, ListenState } from '../listen';
import { romajiOf } from '../romaji';
import { WebSpeaker } from '../voice';
import { useApp } from './app';
import { Chip, PageHeader } from './common';

const OPTIONS_KEY = 'listenOptions';
const RECENT_KEY = 'listenRecent';

function load<T>(key: string, fallback: T): T {
  try {
    const text = localStorage.getItem(key);
    return text ? { ...fallback, ...JSON.parse(text) } : fallback;
  } catch {
    return fallback;
  }
}

function recentScenes(): string[] {
  try {
    const list = JSON.parse(localStorage.getItem(RECENT_KEY) ?? '[]');
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

function remember(ids: string[]) {
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify([...ids, ...recentScenes().filter((id) => !ids.includes(id))].slice(0, 30)));
  } catch {
    // Only a preference.
  }
}

/** The one playlist playing, kept across pages so listening carries on while you look at something else. */
let player: ListenPlayer | null = null;
const listenSpeaker = new WebSpeaker(() => {
  const prefs = load('prefs', { japaneseVoice: '', englishVoice: '' });
  return { japanese: prefs.japaneseVoice, english: prefs.englishVoice };
});

export function isListening() {
  return !!player?.state.playing;
}

/** Windows' media controls and the keyboard's play/pause and next/previous keys. */
function connectMediaKeys(p: ListenPlayer) {
  const media = navigator.mediaSession;
  if (!media) return;
  media.setActionHandler('play', () => p.play());
  media.setActionHandler('pause', () => p.pause());
  media.setActionHandler('nexttrack', () => p.next());
  media.setActionHandler('previoustrack', () => p.previous());
  media.setActionHandler('stop', () => p.stop());
}

function updateMediaInfo(p: ListenPlayer, state: ListenState) {
  const media = navigator.mediaSession;
  if (!media) return;
  const scene = p.playlist[state.scene]?.scenario;
  media.metadata = new MediaMetadata({ title: scene ? scene.title : 'Done', artist: 'Hanaseru · Listen', album: scene?.titleJa ?? '' });
  media.playbackState = state.playing ? 'playing' : 'paused';
}

/** Hands-free scenes for driving or chores: Japanese only, or Japanese followed by English. */
export function Listen() {
  const { prefs } = useApp();
  const [options, setOptions] = useState<ListenOptions>(() => load(OPTIONS_KEY, { language: 'bilingual', minutes: 5, source: 'all', slower: false }));
  const [state, setState] = useState<ListenState | null>(player?.state ?? null);
  const [, setTick] = useState(0);

  useEffect(() => {
    if (!player) return;
    return player.subscribe((s) => { setState(s); updateMediaInfo(player!, s); });
  }, [player]);

  function choose(change: Partial<ListenOptions>) {
    const next = { ...options, ...change };
    setOptions(next);
    try { localStorage.setItem(OPTIONS_KEY, JSON.stringify(next)); } catch { /* only a preference */ }
  }

  function start() {
    player?.stop();
    const playlist = buildPlaylist(library, options, prefs.workField, prefs.name, recentScenes());
    remember(playlist.map((s) => s.scenario.id));
    player = new ListenPlayer(playlist, endingOf(options), listenSpeaker);
    connectMediaKeys(player);
    player.subscribe((s) => { setState(s); updateMediaInfo(player!, s); });
    player.play();
    setTick((t) => t + 1);
  }

  function stop() {
    player?.stop();
    player = null;
    setState(null);
    if (navigator.mediaSession) navigator.mediaSession.metadata = null;
  }

  // Space pauses and plays, arrows move by scene.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (!player || (event.target as HTMLElement).closest('input, select, textarea')) return;
      if (event.key === ' ') { event.preventDefault(); player.toggle(); }
      else if (event.key === 'ArrowRight') player.next();
      else if (event.key === 'ArrowLeft') player.previous();
    };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, []);

  const playing = player && state;
  const scene = playing ? player!.playlist[state!.scene] : undefined;
  const line = playing ? player!.current() : undefined;
  const total = player ? Math.round(player.playlist.reduce((s, x) => s + x.seconds, 0) / 60) : 0;

  return (
    <div class="page narrow">
      <PageHeader title="Listen" subtitle="Short scenes back to back, for driving or chores. Nothing to look at or say." />

      {!playing && (
        <section class="card form">
          <div class="label">Language</div>
          <div class="chips">
            <Chip selected={options.language === 'japanese'} onClick={() => choose({ language: 'japanese' })}>Japanese only</Chip>
            <Chip selected={options.language === 'bilingual'} onClick={() => choose({ language: 'bilingual' })}>Japanese + English</Chip>
          </div>
          <div class="label">Length</div>
          <div class="chips">
            <Chip selected={options.minutes === 5} onClick={() => choose({ minutes: 5 })}>About 5 minutes</Chip>
            <Chip selected={options.minutes === 10} onClick={() => choose({ minutes: 10 })}>About 10 minutes</Chip>
          </div>
          <div class="label">Scenes from</div>
          <div class="chips">
            <Chip selected={options.source === 'work'} onClick={() => choose({ source: 'work' })}>My work</Chip>
            <Chip selected={options.source === 'everyday'} onClick={() => choose({ source: 'everyday' })}>Everyday</Chip>
            <Chip selected={options.source === 'mine'} onClick={() => choose({ source: 'mine' })}>My scenes</Chip>
            <Chip selected={options.source === 'all'} onClick={() => choose({ source: 'all' })}>Everything</Chip>
          </div>
          <div class="label">Speed</div>
          <div class="chips">
            <Chip selected={!options.slower} onClick={() => choose({ slower: false })}>Natural</Chip>
            <Chip selected={options.slower} onClick={() => choose({ slower: true })}>Slower</Chip>
          </div>
          <div class="row">
            <button type="button" class="button primary big listen-play" onClick={start}>▶ Play</button>
          </div>
          <p class="muted small">
            It keeps playing when you switch to other pages or minimise the window. The keyboard's media keys (and
            Windows' media controls) pause, play and skip.
          </p>
        </section>
      )}

      {playing && (
        <section class="card listen-now">
          <div class="label">
            {state!.finished ? 'Finished' : scene ? `Scene ${state!.scene + 1} of ${player!.playlist.length} · about ${total} min` : 'The end'}
          </div>
          {scene && <h2 class="listen-title">{scene.scenario.title} <span class="muted" lang="ja">{scene.scenario.titleJa}</span></h2>}
          {line && !state!.finished && (
            <div class="listen-line">
              {line.speaker && <div class="speaker">{line.speaker}</div>}
              <div class="jp" lang="ja">{line.japanese}</div>
              {line.kana && line.kana !== line.japanese && <div class="kana" lang="ja">{line.kana}</div>}
              {prefs.showRomaji && line.kana && <div class="romaji">{romajiOf(line.japanese, line.kana)}</div>}
              {(options.language === 'bilingual' || prefs.showEnglish) && line.english && <div class="english">{line.english}</div>}
            </div>
          )}
          <div class="control-row listen-controls">
            <button type="button" class="button step" onClick={() => player!.previous()} title="Previous scene (←)">⏮<span>Previous</span></button>
            <button type="button" class="button primary play" onClick={() => player!.toggle()} title="Pause / play (Space)">
              {state!.playing ? '❚❚ Pause' : state!.finished ? '↺ Play again' : '▶ Play'}
            </button>
            <button type="button" class="button step" onClick={() => player!.next()} title="Next scene (→)">⏭<span>Next</span></button>
            <button type="button" class="button" onClick={stop}>■ Stop</button>
          </div>
          <ol class="listen-list">
            {player!.playlist.map((s, i) => (
              <li key={s.scenario.id} class={i === state!.scene ? 'current' : ''}>{s.scenario.title} <span class="muted small">{Math.max(1, Math.round(s.seconds / 60))} min</span></li>
            ))}
          </ol>
        </section>
      )}
    </div>
  );
}
