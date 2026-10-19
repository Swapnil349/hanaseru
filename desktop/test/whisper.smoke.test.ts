// Runs only in CI (WHISPER_AUDIO set): real Whisper on real Japanese speech, with the app's exact options.
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { Downsampler } from '../src/meetings/audio';
import { ASR_OPTIONS, chunksOf } from '../src/meetings/whisper';

const audioPath = process.env.WHISPER_AUDIO;

/** A 16-bit PCM WAV file as mono samples, and its sample rate. */
function readWav(path: string): { samples: Float32Array; rate: number } {
  const data = readFileSync(path);
  let at = 12;
  let rate = 16000;
  let channels = 1;
  while (at < data.length) {
    const id = data.toString('ascii', at, at + 4);
    const size = data.readUInt32LE(at + 4);
    if (id === 'fmt ') {
      channels = data.readUInt16LE(at + 10);
      rate = data.readUInt32LE(at + 12);
    } else if (id === 'data') {
      const count = Math.floor(size / 2 / channels);
      const samples = new Float32Array(count);
      for (let i = 0; i < count; i++) samples[i] = data.readInt16LE(at + 8 + i * 2 * channels) / 0x8000;
      return { samples, rate };
    }
    at += 8 + size + (size % 2);
  }
  throw new Error('No audio data in the WAV file');
}

describe.skipIf(!audioPath)('Whisper on Japanese speech', () => {
  it('transcribes it into timed Japanese lines', async () => {
    const { pipeline } = await import('@huggingface/transformers');
    const { samples, rate } = readWav(audioPath!);
    const audio = new Downsampler(rate).convert(samples);
    const create = pipeline as unknown as (task: string, model: string, options: Record<string, unknown>) => Promise<(a: Float32Array, o: unknown) => Promise<unknown>>;
    const recognizer = await create('automatic-speech-recognition', 'onnx-community/whisper-base', { dtype: 'q8' });
    const chunks = chunksOf(await recognizer(audio, ASR_OPTIONS), audio.length / 16000);
    console.log('Whisper heard:', JSON.stringify(chunks));
    expect(chunks.length).toBeGreaterThan(0);
    expect(chunks.map((c) => c.text).join('')).toMatch(/[぀-ヿ一-鿿]/);
    for (const chunk of chunks) expect(chunk.end).toBeGreaterThanOrEqual(chunk.start);
  }, 300_000);
});
