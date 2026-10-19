import { bestSimilarity } from '../japaneseText';
import type { Listener, Speaker } from '../voice';
import type { MeetingLine } from './db';

/**
 * Practising a meeting's lines, one at a time: hear what was really said (the recording), hear it in a clear voice,
 * then say it yourself. Pause keeps the line; back, again, next and the scrubber move freely.
 */
export interface DrillOptions {
  /** Play the speaker's own voice from the recording. */
  original: boolean;
  /** Then the line in a clear Japanese voice. */
  clear: boolean;
  /** Then your turn to say it. */
  speak: boolean;
}

export interface DrillState {
  index: number;
  activity: 'original' | 'clear' | 'listening' | 'paused' | 'finished' | 'idle';
  heard: string;
  feedback: string;
}

class Cancelled extends Error {}

/** Plays a stretch of the recording. */
export interface ClipPlayer {
  play(start: number, end: number): Promise<void>;
  stop(): void;
}

export class AudioClipPlayer implements ClipPlayer {
  private finish: (() => void) | null = null;

  constructor(private readonly audio: HTMLAudioElement) {}

  play(start: number, end: number): Promise<void> {
    this.stop();
    const audio = this.audio;
    return new Promise((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        audio.removeEventListener('timeupdate', check);
        clearTimeout(watchdog);
        audio.pause();
        if (this.finish === finish) this.finish = null;
        resolve();
      };
      const check = () => {
        if (audio.currentTime >= end) finish();
      };
      // A little after the line ends, whatever the player reports.
      const watchdog = setTimeout(finish, (end - start) * 1000 + 1500);
      this.finish = finish;
      audio.addEventListener('timeupdate', check);
      audio.currentTime = Math.max(0, start - 0.15);
      audio.play().catch(finish);
    });
  }

  stop() {
    this.finish?.();
  }
}

export class MeetingDrill {
  state: DrillState = { index: 0, activity: 'idle', heard: '', feedback: '' };
  private watchers = new Set<(s: DrillState) => void>();
  private run: { cancelled: boolean } | null = null;

  constructor(
    readonly lines: MeetingLine[],
    private readonly speaker: Speaker,
    private readonly listener: Listener,
    private readonly clips: ClipPlayer,
    public options: DrillOptions,
  ) {}

  subscribe(watcher: (s: DrillState) => void): () => void {
    this.watchers.add(watcher);
    watcher(this.state);
    return () => this.watchers.delete(watcher);
  }

  private update(change: Partial<DrillState>) {
    this.state = { ...this.state, ...change };
    this.watchers.forEach((w) => w(this.state));
  }

  start() {
    this.launch();
  }

  pause() {
    this.cancel();
    this.update({ activity: 'paused' });
  }

  togglePause() {
    if (this.state.activity === 'paused' || this.state.activity === 'finished') this.launch();
    else this.pause();
  }

  next() {
    this.go(Math.min(this.state.index + 1, this.lines.length - 1));
  }

  previous() {
    this.go(Math.max(this.state.index - 1, 0));
  }

  again() {
    this.launch();
  }

  go(index: number) {
    this.update({ index, heard: '', feedback: '' });
    this.launch();
  }

  stop() {
    this.cancel();
  }

  private cancel() {
    if (this.run) this.run.cancelled = true;
    this.run = null;
    this.speaker.stop();
    this.listener.cancel();
    this.clips.stop();
  }

  private launch() {
    this.cancel();
    const run = { cancelled: false };
    this.run = run;
    void this.play(run).catch((error) => {
      if (!(error instanceof Cancelled)) throw error;
    });
  }

  private check(run: { cancelled: boolean }) {
    if (run.cancelled) throw new Cancelled();
  }

  private async play(run: { cancelled: boolean }) {
    if (this.state.activity === 'finished') this.update({ index: 0 });
    while (this.state.index < this.lines.length) {
      const line = this.lines[this.state.index];
      this.update({ heard: '', feedback: '' });
      if (this.options.original) {
        this.update({ activity: 'original' });
        await this.clips.play(line.start, line.end);
        this.check(run);
        await wait(300);
        this.check(run);
      }
      if (this.options.clear) {
        this.update({ activity: 'clear' });
        await this.speaker.speak(line.japanese, 'coach', 0.85);
        this.check(run);
      }
      if (this.options.speak) {
        this.update({ activity: 'listening' });
        const heard = await this.listener.listen((partial) => {
          if (!run.cancelled) this.update({ heard: partial });
        });
        this.check(run);
        if (this.listener.denied) {
          this.pause();
          throw new Cancelled();
        }
        const references = [line.japanese, line.kana ?? ''].filter(Boolean);
        const score = heard ? bestSimilarity(heard, references) : 0;
        this.update({
          heard,
          feedback: !heard ? 'Nothing heard.' : score >= 0.75 ? '✓ Clearly said' : score >= 0.5 ? 'Close. Hear it again and try.' : 'Hear it again and try.',
        });
        await wait(900);
        this.check(run);
      } else {
        await wait(600);
        this.check(run);
      }
      if (this.state.index + 1 >= this.lines.length) break;
      this.update({ index: this.state.index + 1 });
    }
    this.update({ activity: 'finished' });
  }
}

function wait(milliseconds: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}
