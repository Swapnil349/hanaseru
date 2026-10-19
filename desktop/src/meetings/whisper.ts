// How Whisper is asked to transcribe, and how its answer becomes lines (shared by the app and its CI check).

export const ASR_OPTIONS = {
  language: 'japanese',
  task: 'transcribe',
  return_timestamps: true,
  chunk_length_s: 30,
};

export interface Chunk {
  text: string;
  start: number;
  end: number;
}

/** Whisper's output as timed pieces of text (seconds from the start of the audio). */
export function chunksOf(output: unknown, seconds: number): Chunk[] {
  const result = (Array.isArray(output) ? output[0] : output) as {
    text?: string;
    chunks?: { text: string; timestamp: [number | null, number | null] }[];
  };
  const chunks = (result?.chunks ?? [])
    .map((c) => ({ text: c.text.trim(), start: c.timestamp[0] ?? 0, end: c.timestamp[1] ?? c.timestamp[0] ?? seconds }))
    .filter((c) => c.text);
  if (chunks.length) return chunks;
  const text = result?.text?.trim() ?? '';
  return text ? [{ text, start: 0, end: seconds }] : [];
}
