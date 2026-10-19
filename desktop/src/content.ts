// The lessons, read from the same JSON files as the iPhone and Android apps.
import cuesJson from '../../Packages/HanaseruKit/Sources/LearningCore/Content/cues.json';
import glossaryJson from '../../Packages/HanaseruKit/Sources/LearningCore/Content/glossary.json';
import personasJson from '../../Packages/HanaseruKit/Sources/LearningCore/Content/personas.json';
import scenariosJson from '../../Packages/HanaseruKit/Sources/LearningCore/Content/scenarios.json';
import vocabularyJson from '../../Packages/HanaseruKit/Sources/LearningCore/Content/vocabulary.json';
import { fromKana, isHiragana, romajiOf, romanize, toHiragana } from './romaji';

export interface ModelLine {
  japanese: string;
  kana: string;
  english: string;
  noteEn?: string;
}

export interface ScenarioBeat {
  id?: string;
  line: string;
  kana: string;
  english: string;
  cueEn?: string;
  intentEn?: string;
  hintEn?: string;
  responses: ModelLine[];
}

export interface Scenario {
  id: string;
  title: string;
  titleJa: string;
  track: 'work' | 'everyday';
  level: number;
  personaID: string;
  situationEn: string;
  placeEn?: string;
  targetTerms: string[];
  beats: ScenarioBeat[];
  closingLine: string;
  closingKana: string;
  closingEnglish: string;
  /** The line of work ("finance"); work scenes without one are railway engineering. */
  field?: string;
}

export interface Persona {
  id: string;
  nameJa: string;
  nameEn: string;
  role: string;
  speakingRate: number;
  voiceGender?: 'male' | 'female';
}

export interface VocabularyTerm {
  id: string;
  japanese: string;
  kana: string;
  romaji: string;
  english: string;
  categories: string[];
  level: number;
  note?: string;
  forms?: string[];
}

export interface CoachCue {
  ja: string;
  kana: string;
  en: string;
}

/** One word (or set phrase) of a line, with its reading and its meaning in that line. */
export interface WordGloss {
  ja: string;
  kana: string;
  en: string;
}

/** The other person's line before one of the learner's. */
export interface PracticePartner {
  japanese: string;
  kana: string;
  english: string;
  nameJa: string;
  nameEn: string;
  isFemale: boolean;
  speakingRate: number;
}

/** One line the learner says, with the line before it. */
export interface PracticeLine {
  id: string;
  japanese: string;
  kana: string;
  english: string;
  cueEn: string;
  intentEn: string;
  partner: PracticePartner | null;
  noteEn?: string;
  references: string[];
}

export type WorkField = 'engineering' | 'finance';

/** "engineering" or "finance", or null for everyday life that suits anyone. */
export function workField(scenario: Scenario): WorkField | null {
  if (scenario.field) return scenario.field as WorkField;
  return scenario.track === 'work' ? 'engineering' : null;
}

export function lineRomaji(line: { japanese: string; kana: string }): string {
  return romajiOf(line.japanese, line.kana);
}

export function isQuestion(japanese: string): boolean {
  const text = japanese.trim();
  return text.endsWith('か。') || text.endsWith('か？') || text.endsWith('？') || text.endsWith('?');
}

/** The reading of a glossary word in English letters, with particles as they're said (は → wa). */
export function glossRomaji(word: WordGloss): string {
  return [...word.kana].some((c) => isHiragana(toHiragana(c))) ? romanize(word.kana) : word.kana;
}

export { fromKana };

export class ContentLibrary {
  scenarios: Scenario[];
  personas: Persona[];
  readonly vocabulary: VocabularyTerm[];
  readonly cues: Record<string, CoachCue>;
  glossary: Record<string, WordGloss[]>;
  private namedLines: [string, WordGloss[]][];
  private readonly bundled: { scenarios: Scenario[]; personas: Persona[]; glossary: Record<string, WordGloss[]> };

  constructor(data: {
    scenarios: Scenario[];
    personas: Persona[];
    vocabulary: VocabularyTerm[];
    cues: Record<string, CoachCue>;
    glossary: Record<string, WordGloss[]>;
  }) {
    this.scenarios = data.scenarios;
    this.personas = data.personas;
    this.vocabulary = data.vocabulary;
    this.cues = data.cues;
    this.glossary = data.glossary;
    this.namedLines = Object.entries(data.glossary).filter(([key]) => key.includes('{name}'));
    this.bundled = { scenarios: data.scenarios, personas: data.personas, glossary: data.glossary };
  }

  /** The learner's own scenes, added to the course (replacing any added before). */
  setOwn(own: { scenarios: Scenario[]; personas: Persona[]; glossary: Record<string, WordGloss[]> }) {
    this.scenarios = [...own.scenarios, ...this.bundled.scenarios];
    this.personas = [...this.bundled.personas, ...own.personas];
    this.glossary = { ...this.bundled.glossary, ...own.glossary };
    this.namedLines = Object.entries(this.glossary).filter(([key]) => key.includes('{name}'));
  }

  static bundled(): ContentLibrary {
    return new ContentLibrary({
      scenarios: scenariosJson as unknown as Scenario[],
      personas: personasJson as unknown as Persona[],
      vocabulary: vocabularyJson as unknown as VocabularyTerm[],
      cues: cuesJson as unknown as Record<string, CoachCue>,
      glossary: glossaryJson as unknown as Record<string, WordGloss[]>,
    });
  }

  persona(id: string): Persona | undefined {
    return this.personas.find((p) => p.id === id);
  }

  scenario(id: string): Scenario | undefined {
    return this.scenarios.find((s) => s.id === id);
  }

  term(id: string): VocabularyTerm | undefined {
    return this.vocabulary.find((t) => t.id === id);
  }

  cue(key: string): CoachCue {
    return this.cues[key] ?? { ja: '', kana: '', en: key };
  }

  /** Fills a cue's placeholders: {english}, {name}, {title}… */
  fill(template: string, values: Record<string, string>): string {
    return Object.entries(values).reduce((text, [key, value]) => text.split(`{${key}}`).join(value), template);
  }

  /** The words of a line in order, or empty. A line with the learner's name in it is found whatever the name. */
  words(japanese: string): WordGloss[] {
    const exact = this.glossary[japanese];
    if (exact) return exact;
    for (const [key, list] of this.namedLines) {
      const parts = key.split('{name}');
      if (parts.length !== 2 || japanese.length < parts[0].length + parts[1].length) continue;
      if (!japanese.startsWith(parts[0]) || !japanese.endsWith(parts[1])) continue;
      const name = japanese.slice(parts[0].length, japanese.length - parts[1].length);
      if (!name) continue;
      return list.map((w) => (w.ja === '{name}' ? { ja: name, kana: name, en: w.en } : w));
    }
    return [];
  }

  /** The learner's line in each beat of a scene (the first, most typical answer), with the partner's line. */
  lines(scenario: Scenario, learnerName: string): PracticeLine[] {
    const persona = this.persona(scenario.personaID);
    const result: PracticeLine[] = [];
    scenario.beats.forEach((beat, index) => {
      if (!beat.responses.length) return;
      const first = personalized(beat.responses[0], learnerName);
      const partner: PracticePartner | null = beat.line
        ? {
            japanese: beat.line, kana: beat.kana, english: beat.english,
            nameJa: persona?.nameJa ?? '', nameEn: persona?.nameEn ?? '',
            isFemale: persona?.voiceGender === 'female', speakingRate: persona?.speakingRate ?? 1,
          }
        : null;
      const references = [...new Set(beat.responses.map((r) => personalized(r, learnerName))
        .flatMap((r) => [r.japanese, r.kana]).filter(Boolean))];
      const cue = beat.cueEn ?? (isQuestion(first.japanese) ? 'Ask: ' : 'Say: ') + first.english;
      result.push({
        id: `${scenario.id}#${beat.id ?? `b${index + 1}`}`,
        japanese: first.japanese, kana: first.kana, english: first.english,
        cueEn: cue, intentEn: beat.intentEn ?? beat.hintEn ?? cue, partner, noteEn: first.noteEn, references,
      });
    });
    return result;
  }

  /**
   * The other role of a scene: the colleague's lines (and the closing line), for the learner to say, each after
   * the learner's usual line, which the app says instead.
   */
  partnerSideLines(scenario: Scenario, learnerName: string): PracticeLine[] {
    const result: PracticeLine[] = [];
    let before: ModelLine | null = null;
    const add = (id: string, japanese: string, kana: string, english: string) => {
      const usual: PracticePartner | null = before
        ? { japanese: before.japanese, kana: before.kana, english: before.english, nameJa: learnerName || 'あなた',
            nameEn: learnerName || 'You', isFemale: false, speakingRate: 1 }
        : null;
      const cue = (isQuestion(japanese) ? 'Ask: ' : 'Say: ') + english;
      result.push({ id, japanese, kana, english, cueEn: cue, intentEn: cue, partner: usual,
                    references: [...new Set([japanese, kana].filter(Boolean))] });
    };
    scenario.beats.forEach((beat, index) => {
      if (beat.line) add(`${scenario.id}#${beat.id ?? `b${index + 1}`}~them`, beat.line, beat.kana, beat.english);
      before = beat.responses[0] ? personalized(beat.responses[0], learnerName) : null;
    });
    if (scenario.closingLine) {
      add(`${scenario.id}#closing~them`, scenario.closingLine, scenario.closingKana, scenario.closingEnglish);
    }
    return result;
  }

  /** The words used in a scene: its target words first, then every listed word in its lines. */
  vocabularyIn(scenario: Scenario): VocabularyTerm[] {
    const text = [scenario.closingLine, ...scenario.beats.flatMap((b) => [b.line, ...b.responses.map((r) => r.japanese)])]
      .join(' ');
    const result = scenario.targetTerms.map((id) => this.term(id)).filter((t): t is VocabularyTerm => !!t);
    for (const candidate of this.vocabulary) {
      if (result.some((t) => t.id === candidate.id)) continue;
      if (candidate.forms?.some((f) => f && text.includes(f))) {
        result.push(candidate);
        continue;
      }
      // Kanji spellings, or kana-only words of 3+ characters: short kana would match inside other words.
      const form = candidate.japanese;
      const kanaOnly = form === candidate.kana;
      if (!form || (kanaOnly && [...form].length < 3)) continue;
      if (text.includes(form)) result.push(candidate);
    }
    return result;
  }
}

/** {name} in a line is the learner's own name. */
export function personalized(line: ModelLine, name: string): ModelLine {
  const who = name || '…';
  const fill = (text: string) => text.split('{name}').join(who);
  return { ...line, japanese: fill(line.japanese), kana: fill(line.kana), english: fill(line.english) };
}

export const library = ContentLibrary.bundled();
