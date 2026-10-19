// What the app remembers between launches, kept in this computer's browser storage.
import type { WorkField } from './content';

function read<T>(key: string, fallback: T): T {
  try {
    const text = localStorage.getItem(key);
    return text === null ? fallback : (JSON.parse(text) as T);
  } catch {
    return fallback;
  }
}

function write(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage can be unavailable (private windows); the app still works for this visit.
  }
}

export interface Prefs {
  name: string;
  workField: WorkField;
  showEnglish: boolean;
  showRomaji: boolean;
  japaneseVoice: string;
  englishVoice: string;
  /** The AI coach server and its passphrase (kept on this computer only). */
  coachURL: string;
  coachToken: string;
  /** The Whisper model used to transcribe meetings. */
  whisperModel: string;
}

const DEFAULT_PREFS: Prefs = {
  name: '', workField: 'engineering', showEnglish: true, showRomaji: false, japaneseVoice: '', englishVoice: '',
  coachURL: 'https://hanaseru-coach.onrender.com', coachToken: '', whisperModel: 'onnx-community/whisper-small',
};

export function loadPrefs(): Prefs {
  return { ...DEFAULT_PREFS, ...read<Partial<Prefs>>('prefs', {}) };
}

export function savePrefs(prefs: Prefs) {
  write('prefs', prefs);
}

/** Which lines you've said well and which scenes you've practised. */
export interface Progress {
  isKnown(lineID: string): boolean;
  markKnown(lineID: string): void;
  hasPractised(scenarioID: string): boolean;
  markPractised(scenarioID: string): void;
}

export class StoredProgress implements Progress {
  private known = new Set(read<string[]>('knownLines', []));
  private scenes = new Set(read<string[]>('practisedScenes', []));

  isKnown(lineID: string) {
    return this.known.has(lineID);
  }

  markKnown(lineID: string) {
    if (this.known.has(lineID)) return;
    this.known.add(lineID);
    write('knownLines', [...this.known]);
  }

  hasPractised(scenarioID: string) {
    return this.scenes.has(scenarioID);
  }

  markPractised(scenarioID: string) {
    if (this.scenes.has(scenarioID)) return;
    this.scenes.add(scenarioID);
    write('practisedScenes', [...this.scenes]);
  }
}

/** Where you stopped in a scene, to continue from there next time. */
export const resumePoint = {
  load(scenarioID: string, asPartner: boolean): number | null {
    return read<number | null>(`resume.${scenarioID}.${asPartner ? 'partner' : 'you'}`, null);
  },
  save(scenarioID: string, asPartner: boolean, stop: number) {
    write(`resume.${scenarioID}.${asPartner ? 'partner' : 'you'}`, stop);
  },
  clear(scenarioID: string, asPartner: boolean) {
    try { localStorage.removeItem(`resume.${scenarioID}.${asPartner ? 'partner' : 'you'}`); } catch { /* ignore */ }
  },
};
