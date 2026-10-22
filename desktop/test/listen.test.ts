import { describe, expect, it } from 'vitest';
import { library } from '../src/content';
import { buildPlaylist, endingOf, ListenOptions, ListenPlayer, scenesFrom, utterancesOf } from '../src/listen';
import type { Speaker } from '../src/voice';

const options = (change: Partial<ListenOptions> = {}): ListenOptions => ({ language: 'bilingual', minutes: 5, source: 'all', slower: false, ...change });
const minutes = (playlist: { seconds: number }[]) => playlist.reduce((s, x) => s + x.seconds, 0) / 60;

describe('Listen playlists', () => {
  it('reach the length asked for, with 3 to 10 scenes', () => {
    for (const length of [5, 10] as const) {
      for (const language of ['japanese', 'bilingual'] as const) {
        const playlist = buildPlaylist(library, options({ minutes: length, language }), 'engineering', 'Swapnil', []);
        expect(playlist.length).toBeGreaterThanOrEqual(3);
        expect(playlist.length).toBeLessThanOrEqual(10);
        if (playlist.length < 10) expect(minutes(playlist)).toBeGreaterThanOrEqual(length);
      }
    }
  });

  it('play scenes not heard recently first', () => {
    const all = scenesFrom(library, 'all', 'engineering').map((s) => s.id);
    const recent = all.slice(0, all.length - 5);
    const playlist = buildPlaylist(library, options(), 'engineering', '', recent);
    const fresh = playlist.slice(0, 5).map((s) => s.scenario.id);
    expect(fresh.every((id) => !recent.includes(id))).toBe(true);
  });

  it('take scenes from the chosen source', () => {
    expect(scenesFrom(library, 'work', 'finance').every((s) => s.field === 'finance' && s.track === 'work')).toBe(true);
    expect(scenesFrom(library, 'everyday', 'engineering').every((s) => s.track === 'everyday' && !s.field)).toBe(true);
    // No scenes of my own yet: everything instead.
    expect(scenesFrom(library, 'mine', 'engineering').length).toBe(library.scenarios.length);
  });

  it('say English only in Japanese + English, and fill in the name', () => {
    const scene = library.scenario('f.first.day')!;
    const japanese = utterancesOf(library, scene, 0, options({ language: 'japanese' }), 'Swapnil');
    expect(japanese.every((u) => u.role !== 'english')).toBe(true);
    expect(japanese[0].text).toBe(`場面1。${scene.titleJa}。`);
    expect(japanese.some((u) => u.text.includes('Swapnil'))).toBe(true);
    expect(japanese.some((u) => u.text.includes('{name}'))).toBe(false);
    const bilingual = utterancesOf(library, scene, 2, options(), 'Swapnil');
    expect(bilingual[0].text).toBe(`Scene 3: ${scene.title}.`);
    const greeting = bilingual.findIndex((u) => u.text === scene.beats[0].line);
    expect(bilingual[greeting + 1]).toMatchObject({ role: 'english', text: scene.beats[0].english });
  });
});

describe('the Listen player', () => {
  it('plays every line and the ending, and pauses on the same line', async () => {
    const said: string[] = [];
    let release: (() => void) | null = null;
    let hold = false;
    const speaker: Speaker = {
      speak: (text) => {
        said.push(text);
        return hold ? new Promise<void>((r) => { release = r; }) : Promise.resolve();
      },
      stop: () => { release?.(); },
    };
    const playlist = buildPlaylist(library, options({ language: 'japanese' }), 'engineering', '', []).slice(0, 1);
    playlist[0].utterances = playlist[0].utterances.map((u) => ({ ...u, pauseAfter: 0 }));
    const player = new ListenPlayer(playlist, endingOf(options({ language: 'japanese' })).map((u) => ({ ...u, pauseAfter: 0 })), speaker);
    hold = true;
    player.play();
    await new Promise((r) => setTimeout(r, 5));
    player.pause();
    expect(player.state).toMatchObject({ playing: false, scene: 0, utterance: 0 });
    hold = false;
    player.play();
    for (let i = 0; i < 100 && !player.state.finished; i++) await new Promise((r) => setTimeout(r, 5));
    expect(player.state.finished).toBe(true);
    expect(said[0]).toBe(said[1]);
    expect(said[said.length - 1]).toBe('おしまいです。お疲れさまでした。');
  });
});
