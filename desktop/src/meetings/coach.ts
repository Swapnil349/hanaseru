import { updateMeeting, type MeetingLine } from './db';

/**
 * The AI coach (your own server on Render, which holds the Anthropic key): turns transcript lines into study
 * material — the line as most likely said, its kana, English, and the meaning of each word.
 */
export interface CoachSettings {
  url: string;
  token: string;
}

export class CoachError extends Error {}

const BATCH = 12;

export async function call(settings: CoachSettings, path: string, body?: unknown, timeoutMs = 120_000): Promise<unknown> {
  if (!settings.url || !settings.token) throw new CoachError('Add the AI coach passphrase in Settings first.');
  const controller = new AbortController();
  // The free server sleeps when unused and takes up to a minute to wake.
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(settings.url.replace(/\/$/, '') + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { Authorization: `Bearer ${settings.token}`, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });
    if (response.status === 401) throw new CoachError('The coach passphrase is wrong (Settings › AI coach).');
    if (response.status === 429) throw new CoachError('The coach is busy. Try again in a minute.');
    if (!response.ok) throw new CoachError(`The coach answered ${response.status}.`);
    return await response.json();
  } catch (error) {
    if (error instanceof CoachError) throw error;
    if ((error as Error)?.name === 'AbortError') throw new CoachError('The coach did not answer in time. Try again.');
    throw new CoachError('The coach could not be reached. Check the internet connection.');
  } finally {
    clearTimeout(timeout);
  }
}

export async function checkCoach(settings: CoachSettings): Promise<string> {
  const json = (await call(settings, '/health')) as { model?: string };
  return json.model ?? 'ok';
}

/** Explains every line that isn't explained yet, a few at a time; reports progress as lines are done. */
export async function explainLines(settings: CoachSettings, meetingId: string, lines: MeetingLine[], context: string,
                                   onProgress: (done: number, total: number) => void): Promise<void> {
  const todo = lines.filter((l) => !l.english);
  onProgress(0, todo.length);
  for (let at = 0; at < todo.length; at += BATCH) {
    const batch = todo.slice(at, at + BATCH);
    const json = (await call(settings, '/v1/annotate', { lines: batch.map((l) => l.japanese), context: context || undefined })) as {
      lines: { japanese: string; kana: string; english: string; words: { ja: string; kana: string; en: string }[] }[];
    };
    await updateMeeting(meetingId, (meeting) => {
      batch.forEach((line, index) => {
        const result = json.lines[index];
        const target = meeting.lines.find((l) => l.id === line.id);
        if (!result || !target) return;
        target.japanese = result.japanese || target.japanese;
        target.kana = result.kana;
        target.english = result.english;
        target.words = result.words;
      });
    });
    onProgress(Math.min(at + BATCH, todo.length), todo.length);
  }
}
