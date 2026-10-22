import { voiceLog } from './diagnostics';
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

type Attempt = 'ok' | 'stopped' | 'never-started' | 'too-fast' | 'error' | 'timeout';

/** Ended so soon after starting that nothing can have been heard (a voice that failed without saying so). */
export function endedTooFast(text: string, rate: number, milliseconds: number): boolean {
  const characters = [...text.replace(/[\s、。，．？！?!,.「」]/g, '')].length;
  return characters >= 6 && milliseconds < Math.max(250, (characters * 25) / Math.max(rate, 0.5));
}

/**
 * Keeps the sound device awake while the app is speaking. Bluetooth headphones, car audio and many PC sound cards
 * go to sleep in the gaps between lines and wake a moment late, so the first syllables of the next line are lost.
 * A faint noise (about 68 dB below full volume, inaudible) keeps the device on; it stops after 30 s of quiet.
 */
const keepAwake = (() => {
  let context: AudioContext | null = null;
  let source: AudioBufferSourceNode | null = null;
  let idle: ReturnType<typeof setTimeout> | null = null;
  const stop = () => {
    try { source?.stop(); } catch { /* already stopped */ }
    void context?.close().catch(() => undefined);
    context = null;
    source = null;
  };
  return {
    /** Starts or extends it; true when it just started (the device may need a moment to wake). */
    touch(): boolean {
      let started = false;
      try {
        if (!context) {
          context = new AudioContext();
          const buffer = context.createBuffer(1, context.sampleRate, context.sampleRate);
          const data = buffer.getChannelData(0);
          for (let i = 0; i < data.length; i++) data[i] = (Math.random() * 2 - 1) * 0.0004;
          source = context.createBufferSource();
          source.buffer = buffer;
          source.loop = true;
          source.connect(context.destination);
          source.start();
          started = true;
        }
        if (context.state === 'suspended') void context.resume();
      } catch {
        // Without Web Audio the voice still works; only the first syllable may be clipped.
      }
      if (idle) clearTimeout(idle);
      idle = setTimeout(stop, 30_000);
      return started;
    },
  };
})();

/** A voice installed in Windows (works offline), for when an online voice fails. */
function localVoice(role: VoiceRole): SpeechSynthesisVoice | undefined {
  const list = role === 'english' ? englishVoices() : japaneseVoices();
  return list.find((v) => v.localService) ?? list[list.length - 1];
}

/**
 * Speaks through the browser's voices, guarding against the ways they go silent: a line spoken right after a stop
 * is dropped, an online voice fails on a network blip, a voice never starts or "finishes" at once, or long speech
 * stalls. Each time it notices, it tries once more (with a voice installed in Windows if the online one failed),
 * logs it, and never waits for ever.
 */
export class WebSpeaker implements Speaker {
  private pending: ((result: Attempt) => void) | null = null;
  /** Keeps the line being spoken alive: browsers lose its events if it's garbage-collected. */
  private current: SpeechSynthesisUtterance | null = null;
  private generation = 0;

  constructor(private readonly choice: () => VoiceChoice) {}

  get isAvailable() {
    return typeof speechSynthesis !== 'undefined';
  }

  async speak(text: string, role: VoiceRole, rate = 1): Promise<void> {
    if (!text.trim() || !this.isAvailable) return;
    await voicesReady();
    this.stop();
    const generation = this.generation;
    // Chromium drops a line spoken straight after cancel(): give it a moment. If the sound device was asleep,
    // give it time to wake so the first words aren't cut off.
    await wait(keepAwake.touch() ? 450 : 60);
    if (generation !== this.generation) return;
    const { voice, pitch } = voiceFor(role, this.choice());
    let result = await this.attempt(text, role, rate, voice, pitch);
    if (result === 'ok' || result === 'stopped' || generation !== this.generation) return;
    voiceLog(`speech ${result} with ${voice?.name ?? 'the default voice'}; trying again`);
    speechSynthesis.cancel();
    speechSynthesis.resume();
    await wait(200);
    if (generation !== this.generation) return;
    // Second try: a voice installed in Windows if the first was an online one that failed.
    const second = result === 'error' || result === 'never-started' ? localVoice(role) ?? voice : voice;
    result = await this.attempt(text, role, rate, second, pitch);
    if (result !== 'ok' && result !== 'stopped') voiceLog(`speech ${result} again with ${second?.name ?? 'the default voice'}; carrying on`);
  }

  private attempt(text: string, role: VoiceRole, rate: number, voice: SpeechSynthesisVoice | undefined, pitch: number): Promise<Attempt> {
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = role === 'english' ? (voice?.lang ?? 'en-US') : 'ja-JP';
    if (voice) utterance.voice = voice;
    utterance.pitch = pitch;
    utterance.rate = rate;
    this.current = utterance;
    return new Promise<Attempt>((resolve) => {
      let finished = false;
      let startedAt = 0;
      const timers: ReturnType<typeof setTimeout>[] = [];
      const finish = (result: Attempt) => {
        if (finished) return;
        finished = true;
        timers.forEach(clearTimeout);
        if (this.pending === finish) this.pending = null;
        if (this.current === utterance) this.current = null;
        resolve(result);
      };
      utterance.onstart = () => {
        startedAt = performance.now();
      };
      utterance.onend = () => {
        if (!startedAt) finish('never-started');
        else finish(endedTooFast(text, rate, performance.now() - startedAt) ? 'too-fast' : 'ok');
      };
      utterance.onerror = (event) => {
        finish(event.error === 'interrupted' || event.error === 'canceled' ? 'stopped' : 'error');
      };
      // Never started: the voice is stuck or the line was dropped. Edge's online voices fetch the speech first, which
      // can take a few seconds on a slow connection; cutting in too early would chop the line.
      timers.push(setTimeout(() => {
        if (!startedAt) {
          speechSynthesis.cancel();
          finish('never-started');
        }
      }, voice && !voice.localService ? 6000 : 3000));
      // Never finished: carry on anyway.
      timers.push(setTimeout(() => {
        speechSynthesis.cancel();
        finish('timeout');
      }, (text.length * 400) / Math.max(rate, 0.5) + 6000));
      this.pending = finish;
      speechSynthesis.speak(utterance);
    });
  }

  stop() {
    if (!this.isAvailable) return;
    this.generation++;
    const pending = this.pending;
    this.pending = null;
    speechSynthesis.cancel();
    pending?.('stopped');
  }
}

function wait(milliseconds: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
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
  private generation = 0;
  /** The microphone was refused; the browser's site settings can allow it again. */
  denied = false;

  get isAvailable() {
    return !!recognitionClass();
  }

  async listen(onPartial?: (text: string) => void): Promise<string> {
    const Recognition = recognitionClass();
    if (!Recognition) return '';
    this.cancel();
    this.denied = false;
    const generation = ++this.generation;
    chime();
    // A moment for the chime, and for a recognition that was just stopped to let go of the microphone.
    await wait(250);
    if (generation !== this.generation) return '';
    let result = await this.attempt(Recognition, onPartial);
    // The speech service dropped (network) or the microphone wasn't free yet: one more try, so the turn isn't lost.
    if (result.retry && generation === this.generation) {
      voiceLog(`listening ended early (${result.reason}); trying again`);
      await wait(400);
      if (generation !== this.generation) return '';
      result = await this.attempt(Recognition, onPartial);
      if (result.retry) voiceLog(`listening ended early again (${result.reason})`);
    }
    return result.text;
  }

  private attempt(Recognition: RecognitionConstructor, onPartial?: (text: string) => void): Promise<{ text: string; retry: boolean; reason: string }> {
    return new Promise((resolve) => {
      const recognition = new Recognition();
      this.current = recognition;
      recognition.lang = 'ja-JP';
      recognition.interimResults = true;
      recognition.continuous = false;
      recognition.maxAlternatives = 3;
      let best = '';
      let done = false;
      let error = '';
      const startedAt = performance.now();
      const finish = (cancelled = false) => {
        if (done) return;
        done = true;
        clearTimeout(timeout);
        if (this.current === recognition) this.current = null;
        const quick = performance.now() - startedAt < 1500;
        const retry = !cancelled && !best && quick && ['network', 'start-failed', 'aborted', ''].includes(error);
        resolve({ text: best.trim(), retry, reason: error || 'no sound' });
      };
      // Never listen for ever: stop after 25 s and take what was heard.
      const timeout = setTimeout(() => {
        try { recognition.stop(); } catch { /* already stopped */ }
        setTimeout(() => finish(), 800);
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
        error = event.error;
        if (['not-allowed', 'service-not-allowed', 'audio-capture'].includes(event.error)) this.denied = true;
        if (event.error !== 'no-speech' && event.error !== 'aborted') voiceLog(`listening error: ${event.error}`);
        finish();
      };
      recognition.onend = () => finish();
      (recognition as unknown as { cancelled?: () => void }).cancelled = () => finish(true);
      try {
        recognition.start();
      } catch (e) {
        error = 'start-failed';
        voiceLog(`listening could not start: ${(e as Error)?.name ?? e}`);
        finish();
      }
    });
  }

  cancel() {
    this.generation++;
    const recognition = this.current;
    this.current = null;
    (recognition as unknown as { cancelled?: () => void } | null)?.cancelled?.();
    try { recognition?.abort(); } catch { /* not started */ }
  }
}

// MARK: - English dictation

/** English speech to text, for describing your own scene: keeps listening until stopped. */
export class EnglishDictation {
  private recognition: Recognition | null = null;
  private stopped = false;

  static get isAvailable() {
    return !!recognitionClass();
  }

  /** `onText` gets what was said so far in this dictation (final and in progress). */
  start(onText: (text: string) => void, onEnd: () => void) {
    const Recognition = recognitionClass();
    if (!Recognition) return onEnd();
    this.stopped = false;
    let finals = '';
    const begin = () => {
      const recognition = new Recognition();
      this.recognition = recognition;
      recognition.lang = 'en-IN';
      recognition.interimResults = true;
      recognition.continuous = true;
      recognition.maxAlternatives = 1;
      let committed = finals;
      recognition.onresult = (event) => {
        let interim = '';
        let final = '';
        for (let i = 0; i < event.results.length; i++) {
          const text = event.results[i][0]?.transcript ?? '';
          if (event.results[i].isFinal) final += text;
          else interim += text;
        }
        finals = (committed + ' ' + final).trim();
        onText((finals + ' ' + interim).trim());
      };
      recognition.onerror = (event) => {
        if (event.error !== 'no-speech' && event.error !== 'aborted') voiceLog(`dictation error: ${event.error}`);
        if (event.error === 'not-allowed' || event.error === 'audio-capture') this.stopped = true;
      };
      // Browsers end dictation after a pause; it carries on until you press Stop.
      recognition.onend = () => {
        committed = finals;
        if (this.stopped) onEnd();
        else setTimeout(begin, 150);
      };
      try {
        recognition.start();
      } catch {
        this.stopped = true;
        onEnd();
      }
    };
    begin();
  }

  stop() {
    this.stopped = true;
    try { this.recognition?.stop(); } catch { /* not started */ }
  }
}
