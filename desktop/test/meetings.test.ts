import { describe, expect, it } from 'vitest';
import { Downsampler, isSilent, RATE, Segmenter } from '../src/meetings/audio';
import { MeetingDrill, type ClipPlayer } from '../src/meetings/drill';
import { isHallucination } from '../src/meetings/transcriber';
import { chunksOf } from '../src/meetings/whisper';
import type { Listener, Speaker } from '../src/voice';

/** A tone (someone speaking) or silence, at 16 kHz. */
function sound(seconds: number, loud: boolean): Float32Array {
  const samples = new Float32Array(Math.round(seconds * RATE));
  if (loud) for (let i = 0; i < samples.length; i++) samples[i] = 0.3 * Math.sin(i / 8);
  return samples;
}

describe('cutting a meeting into pieces for Whisper', () => {
  it('cuts at a pause after 12 seconds', () => {
    const pieces: [number, number][] = [];
    const segmenter = new Segmenter((start, samples) => pieces.push([start, samples.length / RATE]));
    segmenter.push(sound(14, true));
    segmenter.push(sound(0.6, false));
    segmenter.push(sound(5, true));
    segmenter.flush();
    expect(pieces.length).toBe(2);
    expect(pieces[0][0]).toBe(0);
    expect(pieces[0][1]).toBeGreaterThan(14);
    expect(pieces[0][1]).toBeLessThan(15);
    expect(pieces[1][0]).toBeCloseTo(pieces[0][1], 5);
  });

  it('never makes a piece longer than 28 seconds, even without pauses', () => {
    const pieces: number[] = [];
    const segmenter = new Segmenter((_, samples) => pieces.push(samples.length / RATE));
    for (let i = 0; i < 70; i++) segmenter.push(sound(1, true));
    segmenter.flush();
    expect(Math.max(...pieces)).toBeLessThanOrEqual(28.1);
    expect(pieces.reduce((a, b) => a + b, 0)).toBeCloseTo(70, 3);
  });

  it('converts 48 kHz sound to 16 kHz', () => {
    const downsampler = new Downsampler(48000);
    let total = 0;
    for (let i = 0; i < 10; i++) total += downsampler.convert(new Float32Array(4800)).length;
    expect(total).toBe(16000);
  });

  it('skips silence (Whisper invents words for it)', () => {
    expect(isSilent(sound(5, false))).toBe(true);
    expect(isSilent(sound(5, true))).toBe(false);
    expect(isHallucination('ご視聴ありがとうございました')).toBe(true);
    expect(isHallucination('来週の工程について説明します。')).toBe(false);
  });

  it("reads Whisper's answer as timed lines", () => {
    const output = { text: 'はい。わかりました。', chunks: [
      { text: ' はい。', timestamp: [0, 1.2] }, { text: 'わかりました。', timestamp: [1.2, null] }, { text: ' ', timestamp: [3, 3.1] },
    ] };
    expect(chunksOf(output, 4)).toEqual([{ text: 'はい。', start: 0, end: 1.2 }, { text: 'わかりました。', start: 1.2, end: 1.2 }]);
    expect(chunksOf({ text: 'こんにちは' }, 2)).toEqual([{ text: 'こんにちは', start: 0, end: 2 }]);
    expect(chunksOf({ text: '' }, 2)).toEqual([]);
  });
});

describe('practising a meeting', () => {
  const lines = [
    { id: 'a', start: 0, end: 2, japanese: '来週の工程について説明します。' },
    { id: 'b', start: 2, end: 4, japanese: 'よろしくお願いします。' },
  ];

  it('plays the recording, the clear voice and listens, line by line', async () => {
    const events: string[] = [];
    const speaker: Speaker = { speak: async (text) => { events.push(`clear:${text}`); }, stop: () => {} };
    const listener: Listener = { isAvailable: true, listen: async () => { events.push('listen'); return 'よろしくお願いします'; }, cancel: () => {} };
    const clips: ClipPlayer = { play: async (start) => { events.push(`clip:${start}`); }, stop: () => {} };
    const drill = new MeetingDrill(lines, speaker, listener, clips, { original: true, clear: true, speak: true });
    drill.start();
    for (let i = 0; i < 100 && drill.state.activity !== 'finished'; i++) await new Promise((r) => setTimeout(r, 50));
    expect(drill.state.activity).toBe('finished');
    expect(events).toEqual(['clip:0', `clear:${lines[0].japanese}`, 'listen', 'clip:2', `clear:${lines[1].japanese}`, 'listen']);
    expect(drill.state.feedback).toBe('✓ Clearly said');
  }, 10_000);

  it('pauses on the same line', async () => {
    const speaker: Speaker = { speak: () => new Promise(() => {}), stop: () => {} };
    const listener: Listener = { isAvailable: true, listen: async () => '', cancel: () => {} };
    const clips: ClipPlayer = { play: async () => {}, stop: () => {} };
    const drill = new MeetingDrill(lines, speaker, listener, clips, { original: false, clear: true, speak: true });
    drill.go(1);
    await new Promise((r) => setTimeout(r, 10));
    drill.pause();
    expect(drill.state).toMatchObject({ index: 1, activity: 'paused' });
  });
});
