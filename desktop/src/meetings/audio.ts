// Turning sound into 16 kHz mono pieces of under 30 seconds (what Whisper reads), cut where people pause.

export const RATE = 16000;
const MIN_SECONDS = 12;
const MAX_SECONDS = 28;
const WINDOW = RATE / 10; // 100 ms

/** Collects samples and hands out a piece at a pause after 12 s, or at 28 s regardless. */
export class Segmenter {
  private buffer: Float32Array[] = [];
  private length = 0;
  /** Samples handed out so far: where the next piece starts. */
  private offset = 0;
  private quietWindows = 0;
  private windowEnergy = 0;
  private windowCount = 0;

  constructor(private readonly onPiece: (start: number, samples: Float32Array) => void) {}

  /** Seconds of sound received. */
  get elapsed() {
    return (this.offset + this.length) / RATE;
  }

  push(samples: Float32Array) {
    this.buffer.push(samples);
    this.length += samples.length;
    for (const sample of samples) {
      this.windowEnergy += sample * sample;
      if (++this.windowCount === WINDOW) {
        const rms = Math.sqrt(this.windowEnergy / WINDOW);
        this.quietWindows = rms < 0.008 ? this.quietWindows + 1 : 0;
        this.windowEnergy = 0;
        this.windowCount = 0;
      }
    }
    const seconds = this.length / RATE;
    if ((seconds >= MIN_SECONDS && this.quietWindows >= 4) || seconds >= MAX_SECONDS) this.flush();
  }

  /** Hands out whatever is collected (at the end of a recording). */
  flush() {
    if (!this.length) return;
    const samples = new Float32Array(this.length);
    let at = 0;
    for (const part of this.buffer) {
      samples.set(part, at);
      at += part.length;
    }
    const start = this.offset / RATE;
    this.offset += this.length;
    this.buffer = [];
    this.length = 0;
    this.quietWindows = 0;
    this.onPiece(start, samples);
  }
}

/** Averages blocks of samples down to 16 kHz (the recording runs at the sound card's rate, usually 48 kHz). */
export class Downsampler {
  private carry: number[] = [];

  constructor(private readonly fromRate: number) {}

  convert(input: Float32Array): Float32Array {
    if (this.fromRate === RATE) return input;
    const ratio = this.fromRate / RATE;
    const samples = this.carry.length ? Float32Array.from([...this.carry, ...input]) : input;
    const count = Math.floor(samples.length / ratio);
    const output = new Float32Array(count);
    for (let i = 0; i < count; i++) {
      const from = Math.floor(i * ratio);
      const to = Math.floor((i + 1) * ratio);
      let sum = 0;
      for (let j = from; j < to; j++) sum += samples[j];
      output[i] = sum / Math.max(1, to - from);
    }
    this.carry = Array.from(samples.subarray(Math.floor(count * ratio)));
    return output;
  }
}

/** True when a piece is (almost) silent: Whisper invents words for silence, so it isn't transcribed. */
export function isSilent(samples: Float32Array): boolean {
  let energy = 0;
  for (const sample of samples) energy += sample * sample;
  return Math.sqrt(energy / Math.max(1, samples.length)) < 0.004;
}

export function toInt16(samples: Float32Array): Int16Array {
  const output = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) output[i] = Math.max(-1, Math.min(1, samples[i])) * 0x7fff;
  return output;
}

export function toFloat32(samples: Int16Array): Float32Array {
  const output = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) output[i] = samples[i] / 0x7fff;
  return output;
}

/** An audio or video file (e.g. a Teams recording) as 16 kHz pieces, for transcription. */
export async function piecesOfFile(file: Blob, onPiece: (start: number, samples: Float32Array) => void): Promise<number> {
  const context = new OfflineAudioContext(1, RATE, RATE);
  const decoded = await context.decodeAudioData(await file.arrayBuffer());
  const mono = new Float32Array(decoded.length);
  for (let c = 0; c < decoded.numberOfChannels; c++) {
    const channel = decoded.getChannelData(c);
    for (let i = 0; i < channel.length; i++) mono[i] += channel[i] / decoded.numberOfChannels;
  }
  const segmenter = new Segmenter(onPiece);
  for (let at = 0; at < mono.length; at += 4096) segmenter.push(mono.subarray(at, at + 4096));
  segmenter.flush();
  return mono.length / RATE;
}
