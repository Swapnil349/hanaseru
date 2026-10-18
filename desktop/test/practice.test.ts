import { describe, expect, it } from 'vitest';
import { glossRomaji, library, lineRomaji, workField } from '../src/content';
import { ScenePractice } from '../src/practice';
import type { Progress } from '../src/store';
import type { Listener, Speaker } from '../src/voice';

class MemoryProgress implements Progress {
  known = new Set<string>();
  scenes = new Set<string>();
  isKnown(id: string) { return this.known.has(id); }
  markKnown(id: string) { this.known.add(id); }
  hasPractised(id: string) { return this.scenes.has(id); }
  markPractised(id: string) { this.scenes.add(id); }
}

/** Speaks instantly and records what was said. */
class FakeSpeaker implements Speaker {
  said: string[] = [];
  async speak(text: string) { this.said.push(text); await Promise.resolve(); }
  stop() {}
}

/** Always answers with the right line, or with nothing. */
class FakeListener implements Listener {
  isAvailable = true;
  constructor(private answer: (said: string[]) => string, private speaker: FakeSpeaker) {}
  async listen() { await Promise.resolve(); return this.answer(this.speaker.said); }
  cancel() {}
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

async function untilFinished(practice: ScenePractice) {
  for (let i = 0; i < 400 && practice.state.activity !== 'finished'; i++) await new Promise((r) => setTimeout(r, 20));
}

describe('content', () => {
  it('loads every scene, word and word list', () => {
    expect(library.scenarios.length).toBeGreaterThanOrEqual(40);
    expect(library.vocabulary.length).toBeGreaterThanOrEqual(300);
    expect(library.scenarios.some((s) => workField(s) === 'finance')).toBe(true);
  });

  it('has romaji and words for every line', () => {
    for (const scenario of library.scenarios) {
      for (const line of library.lines(scenario, 'Swapnil')) {
        expect(lineRomaji(line), line.id).not.toBe('');
        const words = library.words(line.japanese);
        expect(words.length, `${line.id}: ${line.japanese}`).toBeGreaterThan(0);
        expect(words.every((w) => w.en && glossRomaji(w))).toBe(true);
      }
    }
  });

  it('finds the words of a line with the learner name', () => {
    const words = library.words('お電話ありがとうございます。Swapnilです。いつもお世話になっております。');
    expect(words.some((w) => w.ja === 'Swapnil')).toBe(true);
    expect(glossRomaji({ ja: 'は', kana: 'は', en: '' })).toBe('wa');
  });
});

describe('scene practice', () => {
  const scenario = library.scenario('f.expense')!;

  it('plays the whole scene and learns the lines said well', async () => {
    const speaker = new FakeSpeaker();
    const progress = new MemoryProgress();
    const lines = library.lines(scenario, '');
    const listener = new FakeListener(() => lines[0].japanese, speaker);
    const practice = new ScenePractice(library, scenario, speaker, listener, progress, 'conversation', false, '');
    practice.start();
    await untilFinished(practice);
    expect(practice.state.activity).toBe('finished');
    expect(progress.hasPractised(scenario.id)).toBe(true);
    expect(progress.isKnown(lines[0].id)).toBe(true);
    expect(speaker.said).toContain(scenario.beats[1].line);
    // After the one English explanation, the coach speaks Japanese only.
    const english = speaker.said.filter((s) => /^[\x20-\x7E’—…]+$/.test(s));
    expect(english.length).toBe(1);
  });

  it('pauses where it is and goes on from the same line', async () => {
    const speaker = new FakeSpeaker();
    const listener = new FakeListener(() => '', speaker);
    const practice = new ScenePractice(library, scenario, speaker, listener, new MemoryProgress(), 'conversation', false, '');
    practice.seek(5);
    await settle();
    practice.pause();
    const position = practice.state.position;
    expect(practice.state.activity).toBe('paused');
    practice.resume();
    await settle();
    expect(practice.state.position).toBeGreaterThanOrEqual(position - 1);
    expect(practice.state.position).toBeLessThanOrEqual(position + 1);
    practice.stop();
  });

  it('can be played as the colleague', () => {
    const practice = new ScenePractice(library, scenario, new FakeSpeaker(), new FakeListener(() => '', new FakeSpeaker()),
                                       new MemoryProgress(), 'conversation', true, '');
    expect(practice.lines[0].japanese).toBe(scenario.beats[0].line);
    expect(practice.stops.length).toBe(2 + practice.lines.length * 2);
  });
});
