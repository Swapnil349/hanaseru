import { describe, expect, it } from 'vitest';
import { library } from '../src/content';
import { isMonologue, toLesson, type SavedScene, type SceneLine } from '../src/myScenes';
import { ScenePractice } from '../src/practice';
import { script } from '../src/script';
import type { Progress } from '../src/store';
import { endedTooFast, type Listener, type Speaker } from '../src/voice';

const line = (japanese: string, english: string, words = [{ ja: japanese.replace(/[。、？]/g, ''), kana: japanese, en: english }]): SceneLine =>
  ({ japanese, kana: japanese, english, words });
const empty: SceneLine = { japanese: '', kana: '', english: '', words: [] };

function scene(monologue: boolean): SavedScene {
  return {
    id: monologue ? 'my.speech' : 'my.leave',
    kind: monologue ? 'monologue' : 'conversation',
    description: 'test',
    createdAt: 1,
    updatedAt: 1,
    result: {
      title: monologue ? 'Self-introduction' : 'Asking for leave', titleJa: '自己紹介', situationEn: 'You meet the team.', placeEn: 'in the office',
      partnerNameJa: '田中さん', partnerNameEn: 'Tanaka-san', partnerRole: 'Manager', partnerGender: 'female', track: 'work',
      beats: [
        { partner: monologue ? empty : line('どうしましたか。', 'What is it?'),
          learner: line('{name}です。', "I'm {name}.", [{ ja: '{name}', kana: '{name}', en: 'your name' }, { ja: 'です', kana: 'です', en: 'am (polite)' }]),
          hintEn: 'Say your name' },
        { partner: monologue ? empty : line('わかりました。', 'Understood.'), learner: line('よろしくお願いします。', 'Nice to work with you.'), hintEn: 'Greet them' },
      ],
      closing: monologue ? empty : line('はい、どうぞ。', 'Yes, go ahead.'),
    },
  };
}

class MemoryProgress implements Progress {
  known = new Set<string>();
  isKnown(id: string) { return this.known.has(id); }
  markKnown(id: string) { this.known.add(id); }
  hasPractised() { return false; }
  markPractised() {}
}

describe('my scenes', () => {
  it('become ordinary lessons with their partner and word lists', () => {
    const { scenario, persona, glossary } = toLesson(scene(false));
    expect(scenario.beats.map((b) => b.line)).toEqual(['どうしましたか。', 'わかりました。']);
    expect(scenario.beats[0].responses[0].japanese).toBe('{name}です。');
    expect(scenario.closingLine).toBe('はい、どうぞ。');
    expect(persona).toMatchObject({ id: 'my.leave.partner', nameEn: 'Tanaka-san', voiceGender: 'female' });
    expect(glossary['{name}です。'].map((w) => w.ja)).toEqual(['{name}', 'です']);
    expect(isMonologue(scenario)).toBe(false);
  });

  it('join the course: script, words and practice work, also for a speech', async () => {
    const lessons = [toLesson(scene(false)), toLesson(scene(true))];
    library.setOwn({ scenarios: lessons.map((l) => l.scenario), personas: lessons.map((l) => l.persona),
                     glossary: Object.assign({}, ...lessons.map((l) => l.glossary)) });
    const speech = library.scenario('my.speech')!;
    expect(isMonologue(speech)).toBe(true);
    expect(library.words('Swapnilです。').map((w) => w.ja)).toEqual(['Swapnil', 'です']);
    // A speech's script is only your lines.
    expect(script(library, speech, 'Swapnil').every((e) => e.isLearner)).toBe(true);

    const said: string[] = [];
    const speaker: Speaker = { speak: async (text) => { said.push(text); }, stop: () => {} };
    const listener: Listener = { isAvailable: true, listen: async () => 'よろしくお願いします', cancel: () => {} };
    const practice = new ScenePractice(library, speech, speaker, listener, new MemoryProgress(), 'full', false, 'Swapnil');
    practice.start();
    for (let i = 0; i < 200 && practice.state.activity !== 'finished'; i++) await new Promise((r) => setTimeout(r, 20));
    expect(practice.state.activity).toBe('finished');
    expect(said).toContain('Swapnilです。');
    library.setOwn({ scenarios: [], personas: [], glossary: {} });
  });
});

describe('the speech guard', () => {
  it('notices a voice that "finished" before anything could be heard', () => {
    expect(endedTooFast('来週の工程について説明します。', 0.9, 80)).toBe(true);
    expect(endedTooFast('来週の工程について説明します。', 0.9, 2400)).toBe(false);
    expect(endedTooFast('はい。', 1, 60)).toBe(false);
  });
});
