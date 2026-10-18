import { ContentLibrary, isQuestion, PracticeLine, Scenario } from './content';
import { bestSimilarity } from './japaneseText';
import type { VoiceRole } from './script';
import type { Progress } from './store';
import type { Listener, Speaker } from './voice';

/**
 * A scene practised hands-free, as on the phones: the characters act it out (watch), you repeat your lines after
 * the model (practise), then the real conversation. The scene is explained once in English; after that the coach
 * speaks Japanese only and the English is on screen.
 *
 * It keeps its place line by line: pause, ⏮ ↺ ⏭ and the scrubber carry on from the right line.
 */
export type Mode = 'automatic' | 'full' | 'practise' | 'conversation' | 'watch';

export const MODES: { mode: Mode; title: string; detail: string }[] = [
  { mode: 'automatic', title: 'Automatic', detail: 'The full lesson the first time; after that, straight to the conversation.' },
  { mode: 'full', title: 'Full lesson', detail: 'Watch the conversation, practise each of your lines, then the conversation.' },
  { mode: 'practise', title: 'Practise my lines', detail: 'Watch, then repeat each of your lines after the model.' },
  { mode: 'conversation', title: 'Just the conversation', detail: 'No explanations: the colleague speaks and you answer.' },
  { mode: 'watch', title: 'Just watch', detail: 'The characters act out the whole conversation; nothing is asked.' },
];

export type Activity = 'speaking' | 'listening' | 'paused' | 'finished';
/** Who is speaking: the other side, your side (the model of your line, or you), or the coach. */
export type Who = 'other' | 'you' | 'coach';

type Segment =
  | { kind: 'intro' }
  | { kind: 'watch' | 'practise' | 'perform'; index: number }
  | { kind: 'ending' };

/** A point on the scrubber: a line's question or its answer, in one step. */
export interface Stop {
  step: string;
  line: number | null;
  isAnswer: boolean;
  japanese: string;
}

export function stopTitle(stop: Stop): string {
  return stop.line === null ? stop.step : `${stop.step} · line ${stop.line} · ${stop.isAnswer ? 'your answer' : 'question'}`;
}

export interface PracticeState {
  step: string;
  activity: Activity;
  speaking: Who | null;
  /** Your current line, and whether its Japanese is on screen yet. */
  line: PracticeLine | null;
  answerShown: boolean;
  /** The other side's latest line. */
  otherJapanese: string;
  otherKana: string;
  otherEnglish: string;
  heard: string;
  feedback: string;
  position: number;
  turns: number;
}

class Cancelled extends Error {}

export class ScenePractice {
  readonly persona;
  readonly lines: PracticeLine[];
  readonly mode: Exclude<Mode, 'automatic'>;
  readonly stops: Stop[] = [];
  private readonly segments: Segment[] = [];
  private readonly targets: [number, boolean][] = [];

  state: PracticeState = {
    step: '', activity: 'speaking', speaking: null, line: null, answerShown: true, otherJapanese: '', otherKana: '',
    otherEnglish: '', heard: '', feedback: '', position: 0, turns: 0,
  };
  private listeners = new Set<(state: PracticeState) => void>();

  private cursor = 0;
  private answerFirst = false;
  private run: { cancelled: boolean; done: Promise<void> } | null = null;
  private readonly otherVoice: VoiceRole;

  constructor(
    private readonly library: ContentLibrary,
    private readonly scenario: Scenario,
    private readonly speaker: Speaker,
    private readonly listener: Listener,
    private readonly progress: Progress,
    requestedMode: Mode,
    /** You play the colleague; the app says your usual lines. */
    readonly playAsPartner: boolean,
    learnerName: string,
  ) {
    this.persona = library.persona(scenario.personaID);
    this.lines = playAsPartner ? library.partnerSideLines(scenario, learnerName) : library.lines(scenario, learnerName);
    // A scene already practised goes straight to the conversation.
    this.mode = requestedMode === 'automatic'
      ? (this.lines.some((l) => progress.isKnown(l.id)) ? 'conversation' : 'full')
      : requestedMode;
    const indices = this.lines.map((_, i) => i);
    this.segments.push({ kind: 'intro' });
    if (this.mode === 'full' || this.mode === 'practise' || this.mode === 'watch') {
      indices.forEach((index) => this.segments.push({ kind: 'watch', index }));
    }
    if (this.mode === 'full' || this.mode === 'practise') indices.forEach((index) => this.segments.push({ kind: 'practise', index }));
    if (this.mode !== 'watch') indices.forEach((index) => this.segments.push({ kind: 'perform', index }));
    this.segments.push({ kind: 'ending' });

    this.segments.forEach((segment, position) => {
      if (segment.kind === 'intro' || segment.kind === 'ending') {
        this.stops.push({ step: segment.kind === 'intro' ? 'Start' : 'End', line: null, isAnswer: false, japanese: '' });
        this.targets.push([position, false]);
      } else {
        const line = this.lines[segment.index];
        this.stops.push({ step: this.stepName(segment), line: segment.index + 1, isAnswer: false, japanese: line.partner?.japanese ?? '' });
        this.targets.push([position, false]);
        this.stops.push({ step: this.stepName(segment), line: segment.index + 1, isAnswer: true, japanese: line.japanese });
        this.targets.push([position, true]);
      }
    });
    this.otherVoice = playAsPartner ? 'partnerMale' : this.persona?.voiceGender === 'female' ? 'partnerFemale' : 'partnerMale';
  }

  subscribe(listener: (state: PracticeState) => void): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }

  private update(change: Partial<PracticeState>) {
    this.state = { ...this.state, ...change };
    this.listeners.forEach((l) => l(this.state));
  }

  private get full() {
    return this.mode === 'full';
  }

  // MARK: Control

  start(fromStop?: number) {
    if (fromStop !== undefined && this.targets[fromStop]) {
      [this.cursor, this.answerFirst] = this.targets[fromStop];
    }
    this.launch();
  }

  pause() {
    this.cancelRun();
    this.update({ activity: 'paused', speaking: null });
  }

  /** Carries on from the line that was playing (from its beginning). */
  resume() {
    this.launch();
  }

  togglePause() {
    if (this.state.activity === 'paused') this.resume();
    else this.pause();
  }

  next() {
    this.cursor = Math.min(this.cursor + 1, this.segments.length);
    this.answerFirst = false;
    this.launch();
  }

  previous() {
    this.cursor = Math.max(this.cursor - 1, 0);
    this.answerFirst = false;
    this.launch();
  }

  again() {
    this.answerFirst = false;
    this.launch();
  }

  seek(stop: number) {
    const target = this.targets[stop];
    if (!target) return;
    [this.cursor, this.answerFirst] = target;
    this.launch();
  }

  /** Plays a line on request; the session pauses so it can be heard as often as you like. */
  hear(text: string, yours: boolean, slowly = false) {
    this.pause();
    void this.speaker.speak(text, yours ? 'coach' : this.otherVoice, slowly ? 0.7 : 0.9);
  }

  stop() {
    this.cancelRun();
  }

  /** Stops whatever is playing; it never blocks the screen. */
  private cancelRun() {
    if (this.run) this.run.cancelled = true;
    this.run = null;
    this.speaker.stop();
    this.listener.cancel();
  }

  private launch() {
    const previous = this.run;
    this.cancelRun();
    const run = { cancelled: false, done: Promise.resolve() };
    this.run = run;
    run.done = (async () => {
      // Never wait long for the last step to wind down.
      if (previous) await Promise.race([previous.done, wait(1500)]);
      try {
        await this.play(run);
      } catch (error) {
        if (!(error instanceof Cancelled)) throw error;
      }
    })();
  }

  private check(run: { cancelled: boolean }) {
    if (run.cancelled) throw new Cancelled();
  }

  private async play(run: { cancelled: boolean }) {
    this.update({ activity: 'speaking' });
    while (this.cursor < this.segments.length) {
      await this.playSegment(run, this.segments[this.cursor], this.answerFirst);
      this.check(run);
      this.cursor++;
      this.answerFirst = false;
    }
    this.progress.markPractised(this.scenario.id);
    this.update({ activity: 'finished', speaking: null, position: this.stops.length - 1 });
  }

  // MARK: Speaking

  private async say(run: { cancelled: boolean }, text: string, voice: VoiceRole, who: Who, rate = 0.95) {
    this.check(run);
    this.update({ activity: 'speaking', speaking: who });
    await this.speaker.speak(text, voice, rate);
    this.check(run);
    this.update({ speaking: null });
  }

  /** A coach phrase in Japanese (inside the scene). */
  private coach(run: { cancelled: boolean }, key: string, values: Record<string, string> = {}) {
    return this.say(run, this.library.fill(this.library.cue(key).ja, values), 'coach', 'coach');
  }

  /** A coach phrase in English (only in the scene's one explanation). */
  private coachEnglish(run: { cancelled: boolean }, key: string, values: Record<string, string> = {}) {
    return this.say(run, this.library.fill(this.library.cue(key).en, values), 'english', 'coach');
  }

  private otherSays(run: { cancelled: boolean }, japanese: string, kana: string, english: string) {
    this.update({ otherJapanese: japanese, otherKana: kana, otherEnglish: english });
    return this.say(run, japanese, this.otherVoice, 'other', (this.persona?.speakingRate ?? 1) * 0.92);
  }

  private model(run: { cancelled: boolean }, line: PracticeLine, rate = 0.9) {
    return this.say(run, line.japanese, 'coach', 'you', rate);
  }

  private async pauseFor(run: { cancelled: boolean }, milliseconds: number) {
    await wait(milliseconds);
    this.check(run);
  }

  private place(answer: boolean) {
    let position = this.targets.findIndex(([c, a]) => c === this.cursor && a === answer);
    if (position < 0) position = Math.max(0, this.targets.findIndex(([c]) => c === this.cursor));
    this.update({ position });
  }

  private focus(line: PracticeLine, step: string, answerShown: boolean) {
    this.update({
      line, step, answerShown, heard: '', feedback: '',
      otherJapanese: line.partner?.japanese ?? '', otherKana: line.partner?.kana ?? '', otherEnglish: line.partner?.english ?? '',
    });
  }

  /** One listen; the heard text goes on screen as it comes. */
  private async listen(run: { cancelled: boolean }): Promise<string> {
    this.check(run);
    this.update({ activity: 'listening', speaking: 'you', heard: '' });
    const heard = await this.listener.listen((partial) => {
      if (!run.cancelled) this.update({ heard: partial });
    });
    this.check(run);
    if (this.listener.denied) {
      // Without the microphone the turns would rush past: wait here until it's allowed.
      this.pause();
      throw new Cancelled();
    }
    this.update({ activity: 'speaking', speaking: null, heard });
    return heard;
  }

  /** Repeat after the model once. Never failed, never retried. */
  private async echo(run: { cancelled: boolean }, line: PracticeLine) {
    const heard = await this.listen(run);
    const close = !!heard && bestSimilarity(heard, line.references) >= 0.7;
    this.update({ feedback: !heard ? '' : close ? '✓ Clearly said' : `Heard: ${heard}` });
  }

  // MARK: Segments

  private stepName(segment: Segment): string {
    switch (segment.kind) {
      case 'watch': return 'Watch';
      case 'practise': return 'Practise';
      case 'perform': return 'Conversation';
      case 'intro': return 'Start';
      case 'ending': return 'End';
    }
  }

  private async playSegment(run: { cancelled: boolean }, segment: Segment, fromAnswer: boolean) {
    this.place(fromAnswer);
    const name = this.persona?.nameEn ?? '';
    switch (segment.kind) {
      case 'intro': {
        this.update({ step: this.scenario.title, line: null });
        await this.coachEnglish(run, 'sceneIntro', { title: this.scenario.title });
        if (this.playAsPartner) await this.say(run, `This time you play ${name || 'the colleague'}.`, 'english', 'coach');
        if (this.full) {
          await this.say(run, this.scenario.situationEn, 'english', 'coach');
          await this.coachEnglish(run, 'sceneSteps');
        }
        return;
      }
      case 'watch': {
        const line = this.lines[segment.index];
        this.focus(line, this.full ? 'Step 1 of 3 · Watch the conversation' : 'Watch the conversation', true);
        if (!fromAnswer) {
          if (segment.index === 0) await this.coach(run, this.full ? 'listenFirst' : 'watchScene');
          if (line.partner) await this.otherSays(run, line.partner.japanese, line.partner.kana, line.partner.english);
        }
        this.place(true);
        await this.model(run, line, 0.95);
        await this.pauseFor(run, 600);
        return;
      }
      case 'practise': {
        const line = this.lines[segment.index];
        this.focus(line, this.full ? 'Step 2 of 3 · Practise your lines' : 'Practise your lines', true);
        if (!fromAnswer) {
          if (segment.index === 0) await this.coach(run, this.full ? 'rehearseStart' : 'rehearseShort');
          if (line.partner) await this.otherSays(run, line.partner.japanese, line.partner.kana, line.partner.english);
        }
        this.place(true);
        await this.coach(run, isQuestion(line.japanese) ? 'ask' : 'youSay');
        await this.model(run, line, 0.85);
        await this.echo(run, line);
        return;
      }
      case 'perform': {
        const line = this.lines[segment.index];
        // While you're learning a line its Japanese is on screen; once you know it, it's hidden.
        const known = this.progress.isKnown(line.id);
        this.focus(line, this.full ? 'Step 3 of 3 · The real conversation' : 'The conversation', this.full || !known);
        if (fromAnswer) {
          this.update({ answerShown: true });
          await this.coach(run, 'youCouldSay');
          await this.model(run, line, 0.85);
          await this.echo(run, line);
          return;
        }
        if (segment.index === 0) {
          const youStart = this.lines[0].partner === null;
          if (this.full) await this.coach(run, youStart ? 'performYouStart' : 'performStart', { name });
          else await this.coach(run, youStart ? 'goYouShort' : 'goShort', { name });
        }
        if (line.partner) await this.otherSays(run, line.partner.japanese, line.partner.kana, line.partner.english);
        this.place(true);
        const heard = await this.listen(run);
        const score = heard ? bestSimilarity(heard, line.references) : 0;
        if (score >= 0.75) {
          this.progress.markKnown(line.id);
          this.update({ feedback: '✓ Nice', answerShown: true });
          await this.pauseFor(run, 500);
        } else {
          this.update({ answerShown: true, feedback: heard ? "Close. Here's how to say it" : "Here's how to say it" });
          await this.coach(run, 'youCouldSay');
          await this.model(run, line, 0.85);
          await this.echo(run, line);
        }
        this.update({ turns: this.state.turns + 1 });
        return;
      }
      case 'ending': {
        this.update({ step: 'End', line: null });
        // Playing the colleague, the closing line was your own last line.
        if (!this.playAsPartner && this.scenario.closingLine) {
          await this.otherSays(run, this.scenario.closingLine, this.scenario.closingKana, this.scenario.closingEnglish);
        }
        await this.coach(run, 'conversationEnd');
        return;
      }
    }
  }
}

function wait(milliseconds: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}
