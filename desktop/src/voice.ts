import type { VoiceRole } from './script';

/** Speaks a line and resolves when it has been said (or stopped). */
export interface Speaker {
  speak(text: string, role: VoiceRole, rate?: number): Promise<void>;
  stop(): void;
}

/** One turn of Japanese speech, turned into text. Resolves "" when nothing was heard. */
export interface Listener {
  readonly isAvailable: boolean;
  /** The microphone was refused. */
  readonly denied?: boolean;
  listen(onPartial?: (text: string) => void): Promise<string>;
  cancel(): void;
}

// MARK: - Voices

const FEMALE = ['nanami', 'aoi', 'mayu', 'shiori', 'ayumi', 'haruka', 'sayaka', 'kyoko', 'o-ren', 'google 日本語'];
const MALE = ['keita', 'daichi', 'naoki', 'ichiro', 'otoya', 'hattori'];

function quality(voice: SpeechSynthesisVoice): number {
  const name = voice.name.toLowerCase();
  let score = 0;
  if (name.includes('natural')) score += 4;
  if (name.includes('online')) score += 2;
  if (name.includes('neural') || name.includes('premium') || name.includes('enhanced')) score += 2;
  if (!voice.localService) score += 1;
  return score;
}

function isJapanese(voice: SpeechSynthesisVoice) {
  return voice.lang.toLowerCase().replace('_', '-').startsWith('ja');
}

function hasName(voice: SpeechSynthesisVoice, names: string[]) {
  const name = voice.name.toLowerCase();
  return names.some((n) => name.includes(n));
}

let cachedVoices: SpeechSynthesisVoice[] = [];

/** The voices installed in Windows and offered by Edge (Edge adds Microsoft's natural online voices). */
export function voices(): SpeechSynthesisVoice[] {
  if (typeof speechSynthesis === 'undefined') return [];
  const list = speechSynthesis.getVoices();
  if (list.length) cachedVoices = list;
  return cachedVoices;
}

/** Waits (briefly) for the voice list, which browsers load after start-up. */
export function voicesReady(): Promise<SpeechSynthesisVoice[]> {
  if (typeof speechSynthesis === 'undefined') return Promise.resolve([]);
  if (voices().length) return Promise.resolve(cachedVoices);
  return new Promise((resolve) => {
    const done = () => resolve(voices());
    speechSynthesis.addEventListener('voiceschanged', done, { once: true });
    setTimeout(done, 2500);
  });
}

export function japaneseVoices(): SpeechSynthesisVoice[] {
  return voices().filter(isJapanese).sort((a, b) => quality(b) - quality(a));
}

export function englishVoices(): SpeechSynthesisVoice[] {
  // An Indian English voice first when there is one, then the most natural.
  const rank = (v: SpeechSynthesisVoice) => quality(v) + (v.lang.toLowerCase().includes('in') ? 1 : 0);
  return voices().filter((v) => v.lang.toLowerCase().startsWith('en')).sort((a, b) => rank(b) - rank(a));
}

export interface VoiceChoice {
  /** A voice name chosen in Settings, or "" for the best one. */
  japanese: string;
  english: string;
}

/** The voice for a role, and a pitch: with a single Japanese voice, people are told apart by pitch. */
export function voiceFor(role: VoiceRole, choice: VoiceChoice): { voice?: SpeechSynthesisVoice; pitch: number } {
  if (role === 'english') {
    const list = englishVoices();
    return { voice: list.find((v) => v.name === choice.english) ?? list[0], pitch: 1 };
  }
  const list = japaneseVoices();
  const coach = list.find((v) => v.name === choice.japanese) ?? list.find((v) => hasName(v, FEMALE)) ?? list[0];
  if (role === 'coach') return { voice: coach, pitch: 1 };
  const wanted = role === 'partnerMale' ? MALE : FEMALE;
  const other = list.find((v) => hasName(v, wanted) && v !== coach);
  if (other) return { voice: other, pitch: 1 };
  return { voice: coach, pitch: role === 'partnerMale' ? 0.86 : 1.14 };
}

// MARK: - Speaking

export class WebSpeaker implements Speaker {
  private pending: (() => void) | null = null;

  constructor(private readonly choice: () => VoiceChoice) {}

  get isAvailable() {
    return typeof speechSynthesis !== 'undefined';
  }

  async speak(text: string, role: VoiceRole, rate = 1): Promise<void> {
    if (!text.trim() || !this.isAvailable) return;
    await voicesReady();
    this.stop();
    const utterance = new SpeechSynthesisUtterance(text);
    const { voice, pitch } = voiceFor(role, this.choice());
    utterance.lang = role === 'english' ? (voice?.lang ?? 'en-US') : 'ja-JP';
    if (voice) utterance.voice = voice;
    utterance.pitch = pitch;
    utterance.rate = rate;
    await new Promise<void>((resolve) => {
      let finished = false;
      const finish = () => {
        if (finished) return;
        finished = true;
        clearTimeout(watchdog);
        if (this.pending === finish) this.pending = null;
        resolve();
      };
      // A watchdog: if the voice never says it finished, carry on anyway.
      const watchdog = setTimeout(finish, (text.length * 400) / Math.max(rate, 0.5) + 4000);
      utterance.onend = finish;
      utterance.onerror = finish;
      this.pending = finish;
      speechSynthesis.speak(utterance);
    });
  }

  stop() {
    if (!this.isAvailable) return;
    const pending = this.pending;
    this.pending = null;
    speechSynthesis.cancel();
    pending?.();
  }
}

// MARK: - Listening

interface RecognitionResultEvent {
  resultIndex: number;
  results: ArrayLike<ArrayLike<{ transcript: string }> & { isFinal: boolean }>;
}

interface Recognition {
  lang: string;
  interimResults: boolean;
  continuous: boolean;
  maxAlternatives: number;
  onresult: ((event: RecognitionResultEvent) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
  abort(): void;
}

type RecognitionConstructor = new () => Recognition;

function recognitionClass(): RecognitionConstructor | undefined {
  const scope = globalThis as unknown as { SpeechRecognition?: RecognitionConstructor; webkitSpeechRecognition?: RecognitionConstructor };
  return scope.SpeechRecognition ?? scope.webkitSpeechRecognition;
}

/** A short chime: now it's your turn to speak. */
function chime() {
  try {
    const AudioContextClass = (globalThis as unknown as { AudioContext?: typeof AudioContext }).AudioContext;
    if (!AudioContextClass) return;
    const context = new AudioContextClass();
    const tone = context.createOscillator();
    const gain = context.createGain();
    tone.frequency.value = 880;
    gain.gain.setValueAtTime(0.0001, context.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.18, context.currentTime + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, context.currentTime + 0.18);
    tone.connect(gain).connect(context.destination);
    tone.start();
    tone.stop(context.currentTime + 0.2);
    tone.onended = () => void context.close();
  } catch {
    // No sound is fine.
  }
}

/** Japanese speech recognition in Microsoft Edge (and Chrome). What you say becomes text; nothing is recorded. */
export class WebListener implements Listener {
  private current: Recognition | null = null;
  /** The microphone was refused; the browser's site settings can allow it again. */
  denied = false;

  get isAvailable() {
    return !!recognitionClass();
  }

  listen(onPartial?: (text: string) => void): Promise<string> {
    const Recognition = recognitionClass();
    if (!Recognition) return Promise.resolve('');
    this.cancel();
    this.denied = false;
    chime();
    return new Promise((resolve) => {
      const recognition = new Recognition();
      this.current = recognition;
      recognition.lang = 'ja-JP';
      recognition.interimResults = true;
      recognition.continuous = false;
      recognition.maxAlternatives = 3;
      let best = '';
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        clearTimeout(timeout);
        if (this.current === recognition) this.current = null;
        resolve(best.trim());
      };
      const timeout = setTimeout(() => {
        try { recognition.stop(); } catch { /* already stopped */ }
        setTimeout(finish, 800);
      }, 25_000);
      recognition.onresult = (event) => {
        let text = '';
        for (let i = 0; i < event.results.length; i++) text += event.results[i][0]?.transcript ?? '';
        if (text.trim()) {
          best = text;
          onPartial?.(text.trim());
        }
      };
      recognition.onerror = (event) => {
        if (['not-allowed', 'service-not-allowed', 'audio-capture'].includes(event.error)) this.denied = true;
        finish();
      };
      recognition.onend = finish;
      try {
        // A moment for the chime before the microphone opens.
        setTimeout(() => {
          if (!done) recognition.start();
        }, 220);
      } catch {
        finish();
      }
    });
  }

  cancel() {
    const recognition = this.current;
    this.current = null;
    try { recognition?.abort(); } catch { /* not started */ }
  }
}
