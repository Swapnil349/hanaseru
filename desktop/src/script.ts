import { ContentLibrary, lineRomaji, Scenario } from './content';
import { romajiOf } from './romaji';

export type VoiceRole = 'coach' | 'partnerMale' | 'partnerFemale' | 'english';

/** One line of a scene's script, with its reading, meaning and voice. */
export interface ScriptEntry {
  id: string;
  speaker: string;
  isLearner: boolean;
  japanese: string;
  kana: string;
  romaji: string;
  english: string;
  voice: VoiceRole;
  /** The learner's lines: their place in the scene. */
  line?: number;
}

/** A scene's complete script: each line of the other person and your answer, then the closing line. */
export function script(library: ContentLibrary, scenario: Scenario, learnerName: string): ScriptEntry[] {
  const persona = library.persona(scenario.personaID);
  const name = persona?.nameEn || 'Colleague';
  const partnerVoice: VoiceRole = persona?.voiceGender === 'female' ? 'partnerFemale' : 'partnerMale';
  const entries: ScriptEntry[] = [];
  library.lines(scenario, learnerName).forEach((line, index) => {
    if (line.partner) {
      const p = line.partner;
      entries.push({ id: `p|${line.id}`, speaker: name, isLearner: false, japanese: p.japanese, kana: p.kana,
                     romaji: romajiOf(p.japanese, p.kana), english: p.english, voice: partnerVoice });
    }
    entries.push({ id: line.id, speaker: 'You', isLearner: true, japanese: line.japanese, kana: line.kana,
                   romaji: lineRomaji(line), english: line.english, voice: 'coach', line: index });
  });
  if (scenario.closingLine) {
    entries.push({ id: 'closing', speaker: name, isLearner: false, japanese: scenario.closingLine,
                   kana: scenario.closingKana, romaji: romajiOf(scenario.closingLine, scenario.closingKana),
                   english: scenario.closingEnglish, voice: partnerVoice });
  }
  return entries;
}

/** The script as text in three ways — Japanese (with its kana), English letters and English — to copy or save. */
export function scriptText(title: string, situation: string, entries: ScriptEntry[]): string {
  const lines = [title];
  if (situation) lines.push(situation);
  for (const entry of entries) {
    lines.push('', `${entry.speaker}:`, `  ${entry.japanese}`);
    if (entry.kana && entry.kana !== entry.japanese) lines.push(`  ${entry.kana}`);
    if (entry.romaji) lines.push(`  ${entry.romaji}`);
    if (entry.english) lines.push(`  ${entry.english}`);
  }
  return lines.join('\n') + '\n';
}
