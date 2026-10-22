// Listen: playlists of short scenes for hands-free listening (driving, chores), Japanese only or Japanese + English.
// The rules are shared with the phone apps (docs/LISTEN.md).
import { ContentLibrary, personalized, Scenario, workField, WorkField } from './content';
import { isOwn } from './myScenes';
import type { VoiceRole } from './script';
import type { Speaker } from './voice';

export type ListenLanguage = 'japanese' | 'bilingual';
export type ListenSource = 'work' | 'everyday' | 'mine' | 'all';

export interface ListenOptions {
  language: ListenLanguage;
  minutes: 5 | 10;
  source: ListenSource;
  slower: boolean;
}

/** One thing said: its text, voice and the pause after it, and what the screen shows meanwhile. */
export interface Utterance {
  text: string;
  role: VoiceRole;
  rate: number;
  pauseAfter: number;
  /** The Japanese line this belongs to (its translation shows the same line). */
  japanese: string;
  kana: string;
  english: string;
  speaker: string;
}

export interface ListenScene {
  scenario: Scenario;
  utterances: Utterance[];
  seconds: number;
}

const JAPANESE_PER_SECOND = 6;
const ENGLISH_WORDS_PER_SECOND = 2.5;

function seconds(u: Utterance): number {
  const japanese = u.role !== 'english';
  const length = japanese ? [...u.text].length / JAPANESE_PER_SECOND / u.rate : u.text.split(/\s+/).length / ENGLISH_WORDS_PER_SECOND;
  return length + u.pauseAfter;
}

/** The scenes a source offers. An empty source offers everything instead. */
export function scenesFrom(library: ContentLibrary, source: ListenSource, field: WorkField): Scenario[] {
  const all = library.scenarios.filter((s) => s.beats.length > 0);
  const picked = all.filter((s) => {
    switch (source) {
      case 'work': return !isOwn(s.id) && s.track === 'work' && workField(s) === field;
      case 'everyday': return !isOwn(s.id) && s.track === 'everyday' && (workField(s) === null || workField(s) === field);
      case 'mine': return isOwn(s.id);
      case 'all': return true;
    }
  });
  return picked.length ? picked : all;
}

/** What is said for one scene, in order (docs/LISTEN.md › What is said). */
export function utterancesOf(library: ContentLibrary, scenario: Scenario, index: number, options: ListenOptions, learnerName: string): Utterance[] {
  const out: Utterance[] = [];
  const bilingual = options.language === 'bilingual';
  const rate = options.slower ? 0.8 : 0.95;
  const persona = library.persona(scenario.personaID);
  const partnerRole: VoiceRole = persona?.voiceGender === 'female' ? 'partnerFemale' : 'partnerMale';
  const partnerName = persona?.nameEn || 'Colleague';
  const you = learnerName || 'You';
  const fill = (text: string) => (learnerName ? text.split('{name}').join(learnerName) : text.split('{name}').join(''));

  const say = (japanese: string, kana: string, english: string, role: VoiceRole, speaker: string) => {
    if (!japanese.trim()) return;
    const ja = fill(japanese);
    const en = fill(english);
    out.push({ text: ja, role, rate, pauseAfter: bilingual && en ? 0.4 : 0.8, japanese: ja, kana: fill(kana), english: en, speaker });
    if (bilingual && en) out.push({ text: en, role: 'english', rate: 1, pauseAfter: 0.8, japanese: ja, kana: fill(kana), english: en, speaker });
  };

  // The announcement.
  if (bilingual) {
    out.push({ text: `Scene ${index + 1}: ${scenario.title}.`, role: 'english', rate: 1, pauseAfter: 0.3, japanese: scenario.titleJa, kana: '', english: scenario.title, speaker: '' });
    out.push({ text: scenario.titleJa, role: 'coach', rate, pauseAfter: 0.4, japanese: scenario.titleJa, kana: '', english: scenario.title, speaker: '' });
    if (scenario.situationEn) out.push({ text: scenario.situationEn, role: 'english', rate: 1, pauseAfter: 0.8, japanese: scenario.titleJa, kana: '', english: scenario.situationEn, speaker: '' });
  } else {
    out.push({ text: `場面${index + 1}。${scenario.titleJa}。`, role: 'coach', rate, pauseAfter: 0.8, japanese: scenario.titleJa, kana: '', english: scenario.title, speaker: '' });
  }

  // Every line of the script.
  for (const beat of scenario.beats) {
    say(beat.line, beat.kana, beat.english, partnerRole, partnerName);
    const answer = beat.responses[0] ? personalized(beat.responses[0], learnerName) : null;
    if (answer) say(answer.japanese, answer.kana, answer.english, 'coach', you);
  }
  say(scenario.closingLine, scenario.closingKana, scenario.closingEnglish, partnerRole, partnerName);
  if (out.length) out[out.length - 1] = { ...out[out.length - 1], pauseAfter: 2.5 };
  return out;
}

/**
 * The playlist: shuffled scenes from the source, those not heard recently first, until the target length
 * (at least 3 scenes, at most 10).
 */
export function buildPlaylist(library: ContentLibrary, options: ListenOptions, field: WorkField, learnerName: string,
                              recent: string[], random: () => number = Math.random): ListenScene[] {
  const pool = scenesFrom(library, options.source, field);
  const shuffled = pool.map((s) => ({ s, k: random() })).sort((a, b) => a.k - b.k).map((x) => x.s);
  const order = [...shuffled.filter((s) => !recent.includes(s.id)), ...shuffled.filter((s) => recent.includes(s.id))];
  const target = options.minutes * 60;
  const playlist: ListenScene[] = [];
  let total = 0;
  for (const scenario of order) {
    if (playlist.length >= 10 || (total >= target && playlist.length >= 3)) break;
    const utterances = utterancesOf(library, scenario, playlist.length, options, learnerName);
    const length = utterances.reduce((sum, u) => sum + seconds(u), 0);
    playlist.push({ scenario, utterances, seconds: length });
    total += length;
  }
  return playlist;
}

export function endingOf(options: ListenOptions): Utterance[] {
  const end: Utterance = { text: 'おしまいです。お疲れさまでした。', role: 'coach', rate: 0.95, pauseAfter: 0.4, japanese: 'おしまいです。お疲れさまでした。', kana: '', english: "That's the end. Well done.", speaker: '' };
  return options.language === 'bilingual' ? [end, { ...end, text: "That's the end. Well done.", role: 'english', rate: 1 }] : [end];
}

// MARK: - Playing

export interface ListenState {
  scene: number;
  utterance: number;
  playing: boolean;
  finished: boolean;
}

/** Plays a playlist line by line; pause keeps the line, next and previous move by scene. */
export class ListenPlayer {
  state: ListenState = { scene: 0, utterance: 0, playing: false, finished: false };
  private watchers = new Set<(s: ListenState) => void>();
  private run = 0;
  private sceneStartedAt = 0;

  constructor(readonly playlist: ListenScene[], private readonly ending: Utterance[], private readonly speaker: Speaker) {}

  subscribe(watcher: (s: ListenState) => void): () => void {
    this.watchers.add(watcher);
    watcher(this.state);
    return () => this.watchers.delete(watcher);
  }

  private set(change: Partial<ListenState>) {
    this.state = { ...this.state, ...change };
    this.watchers.forEach((w) => w(this.state));
  }

  /** What is being said now (the ending after the last scene). */
  current(): Utterance | undefined {
    const scene = this.playlist[this.state.scene];
    return scene ? scene.utterances[this.state.utterance] : this.ending[this.state.utterance];
  }

  play() {
    if (this.state.finished) this.set({ scene: 0, utterance: 0, finished: false });
    this.launch();
  }

  pause() {
    this.run++;
    this.speaker.stop();
    this.set({ playing: false });
  }

  toggle() {
    if (this.state.playing) this.pause();
    else this.play();
  }

  next() {
    if (this.state.scene >= this.playlist.length) return;
    this.set({ scene: this.state.scene + 1, utterance: 0, finished: false });
    this.launch();
  }

  /** The previous scene, or the start of this one if it has been playing for more than 3 s. */
  previous() {
    const restart = Date.now() - this.sceneStartedAt > 3000 && this.state.utterance > 0;
    this.set({ scene: restart ? this.state.scene : Math.max(0, this.state.scene - 1), utterance: 0, finished: false });
    this.launch();
  }

  stop() {
    this.run++;
    this.speaker.stop();
    this.set({ playing: false });
  }

  private launch() {
    const run = ++this.run;
    this.speaker.stop();
    this.set({ playing: true });
    void this.loop(run);
  }

  private async loop(run: number) {
    if (this.state.utterance === 0) this.sceneStartedAt = Date.now();
    for (;;) {
      if (run !== this.run) return;
      const scene = this.playlist[this.state.scene];
      const list = scene ? scene.utterances : this.ending;
      if (this.state.utterance >= list.length) {
        if (!scene) {
          this.set({ playing: false, finished: true });
          return;
        }
        this.set({ scene: this.state.scene + 1, utterance: 0 });
        this.sceneStartedAt = Date.now();
        continue;
      }
      const u = list[this.state.utterance];
      await this.speaker.speak(u.text, u.role, u.rate);
      if (run !== this.run) return;
      await new Promise((r) => setTimeout(r, u.pauseAfter * 1000));
      if (run !== this.run) return;
      this.set({ utterance: this.state.utterance + 1 });
    }
  }
}
