import workletUrl from './pcm-worklet.js?url';
import { Downsampler, Segmenter } from './audio';

export interface RecorderOptions {
  /** People speaking in the room, through this computer's microphone. */
  microphone: boolean;
  /** This computer's own sound: an online meeting in Teams, Zoom or a browser tab (works with headphones). */
  computerSound: boolean;
  /** A piece of sound ready for transcription (seconds from the start, 16 kHz samples). */
  onPiece: (start: number, samples: Float32Array) => void;
  /** A chunk of the recording file, every few seconds, so a crash loses almost nothing. */
  onChunk: (chunk: Blob) => void;
  /** The computer's sound stopped being shared (the user pressed "Stop sharing"). */
  onSourceEnded?: () => void;
}

export class RecorderError extends Error {}

/** Records a meeting: the microphone and/or the computer's sound, mixed into one recording. */
export class MeetingRecorder {
  private context: AudioContext | null = null;
  private streams: MediaStream[] = [];
  private media: MediaRecorder | null = null;
  private tap: AudioWorkletNode | null = null;
  private segmenter: Segmenter;
  private analyser: AnalyserNode | null = null;
  private paused = false;
  readonly mimeType: string;

  constructor(private readonly options: RecorderOptions) {
    this.segmenter = new Segmenter(options.onPiece);
    this.mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus']
      .find((t) => typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(t)) ?? '';
  }

  /** Seconds recorded so far. */
  get elapsed() {
    return this.segmenter.elapsed;
  }

  async start() {
    const { microphone, computerSound } = this.options;
    if (!microphone && !computerSound) throw new RecorderError('Choose the microphone, the computer sound, or both.');
    try {
      if (computerSound) {
        // Browsers only share the computer's sound together with a screen or tab.
        const display = await navigator.mediaDevices.getDisplayMedia({
          video: true,
          audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
          systemAudio: 'include',
        } as DisplayMediaStreamOptions);
        if (!display.getAudioTracks().length) {
          display.getTracks().forEach((t) => t.stop());
          throw new RecorderError(
            'No sound was shared. Choose "Entire screen" (or the browser tab of the meeting) and switch on "Also share system audio".',
          );
        }
        display.getAudioTracks()[0].addEventListener('ended', () => this.options.onSourceEnded?.());
        this.streams.push(display);
      }
      if (microphone) {
        this.streams.push(await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        }));
      }
    } catch (error) {
      this.stopStreams();
      if (error instanceof RecorderError) throw error;
      const name = (error as DOMException)?.name;
      if (name === 'NotAllowedError') throw new RecorderError('Recording was not allowed. Allow the microphone or the screen share and try again.');
      if (name === 'NotFoundError') throw new RecorderError('No microphone was found.');
      throw new RecorderError(`Recording could not start (${name ?? String(error)}).`);
    }

    const context = new AudioContext();
    this.context = context;
    const mix = context.createGain();
    for (const stream of this.streams) {
      if (stream.getAudioTracks().length) context.createMediaStreamSource(stream).connect(mix);
    }
    this.analyser = context.createAnalyser();
    this.analyser.fftSize = 512;
    mix.connect(this.analyser);

    // The recording file.
    const destination = context.createMediaStreamDestination();
    mix.connect(destination);
    this.media = new MediaRecorder(destination.stream, this.mimeType ? { mimeType: this.mimeType, audioBitsPerSecond: 48000 } : undefined);
    this.media.ondataavailable = (event) => {
      if (event.data.size) this.options.onChunk(event.data);
    };
    this.media.start(5000);

    // The sound for transcription.
    await context.audioWorklet.addModule(workletUrl);
    this.tap = new AudioWorkletNode(context, 'pcm-tap');
    const downsampler = new Downsampler(context.sampleRate);
    this.tap.port.onmessage = (event: MessageEvent<Float32Array>) => {
      if (!this.paused) this.segmenter.push(downsampler.convert(event.data));
    };
    mix.connect(this.tap);
    // The tap must be connected onward to run; a silent gain keeps it from being heard.
    const silent = context.createGain();
    silent.gain.value = 0;
    this.tap.connect(silent).connect(context.destination);
  }

  /** How loud the meeting is right now, 0…1, for the level meter. */
  level(): number {
    if (!this.analyser) return 0;
    const data = new Float32Array(this.analyser.fftSize);
    this.analyser.getFloatTimeDomainData(data);
    let peak = 0;
    for (const value of data) peak = Math.max(peak, Math.abs(value));
    return Math.min(1, peak * 2);
  }

  pause() {
    this.paused = true;
    if (this.media?.state === 'recording') this.media.pause();
  }

  resume() {
    this.paused = false;
    if (this.media?.state === 'paused') this.media.resume();
  }

  get isPaused() {
    return this.paused;
  }

  /** Stops recording; resolves once the last chunk of the file has been handed over. */
  async stop() {
    this.paused = true;
    const media = this.media;
    if (media && media.state !== 'inactive') {
      await new Promise<void>((resolve) => {
        media.addEventListener('stop', () => resolve(), { once: true });
        media.stop();
      });
    }
    this.segmenter.flush();
    this.tap?.port.close();
    this.stopStreams();
    await this.context?.close().catch(() => undefined);
    this.context = null;
  }

  private stopStreams() {
    this.streams.forEach((s) => s.getTracks().forEach((t) => t.stop()));
    this.streams = [];
  }
}
