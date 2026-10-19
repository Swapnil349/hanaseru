import { piecesOfFile } from './audio';
import { appendAudio, newID, saveMeeting, updateMeeting, type Meeting } from './db';
import { MeetingRecorder } from './recorder';
import { transcriber } from './transcriber';

/** The meeting being recorded now (one at a time); it keeps recording while you look at other pages. */
export interface ActiveRecording {
  meetingId: string;
  recorder: MeetingRecorder;
  startedAt: number;
  sourceEnded: boolean;
  /** Recording chunks still being saved. */
  saving: Promise<unknown>[];
}

let active: ActiveRecording | null = null;
const watchers = new Set<(a: ActiveRecording | null) => void>();
let wakeLock: { release(): Promise<void> } | null = null;

export function activeRecording() {
  return active;
}

export function watchRecording(watcher: (a: ActiveRecording | null) => void): () => void {
  watchers.add(watcher);
  return () => watchers.delete(watcher);
}

function changed() {
  watchers.forEach((w) => w(active));
}

function beforeUnload(event: BeforeUnloadEvent) {
  event.preventDefault();
  event.returnValue = '';
}

export async function startRecording(title: string, microphone: boolean, computerSound: boolean, model: string): Promise<string> {
  if (active) throw new Error('A meeting is already being recorded.');
  const id = newID();
  let chunk = 0;
  const pending: Promise<unknown>[] = [];
  const recorder = new MeetingRecorder({
    microphone,
    computerSound,
    onPiece: (start, samples) => void transcriber.add(id, start, samples),
    onChunk: (blob) => pending.push(appendAudio(id, chunk++, blob)),
    onSourceEnded: () => {
      if (active?.meetingId === id) {
        active.sourceEnded = true;
        changed();
      }
    },
  });
  await recorder.start();
  const source = [microphone && 'microphone', computerSound && 'computer sound'].filter(Boolean).join(' + ');
  await saveMeeting({
    id, title: title.trim() || defaultTitle(), createdAt: Date.now(), duration: 0, status: 'recording', source,
    audioType: recorder.mimeType.split(';')[0] || 'audio/webm', lines: [],
  });
  active = { meetingId: id, recorder, startedAt: Date.now(), sourceEnded: false, saving: pending };
  transcriber.start(model);
  addEventListener('beforeunload', beforeUnload);
  try {
    wakeLock = await (navigator as unknown as { wakeLock?: { request(t: string): Promise<{ release(): Promise<void> }> } })
      .wakeLock?.request('screen') ?? null;
  } catch {
    wakeLock = null;
  }
  changed();
  // Keep the meeting's length up to date while it records.
  const timer = setInterval(() => {
    if (active?.meetingId !== id) return clearInterval(timer);
    void updateMeeting(id, (m) => { m.duration = recorder.elapsed; });
  }, 10_000);
  return id;
}

export async function stopRecording() {
  const recording = active;
  if (!recording) return;
  await recording.recorder.stop();
  await Promise.all(recording.saving);
  await updateMeeting(recording.meetingId, (m) => {
    m.status = 'done';
    m.duration = recording.recorder.elapsed;
  });
  active = null;
  removeEventListener('beforeunload', beforeUnload);
  await wakeLock?.release().catch(() => undefined);
  wakeLock = null;
  changed();
}

/** A recording made elsewhere (Teams, a phone, a voice recorder): kept and transcribed like a meeting. */
export async function importRecording(file: File, model: string): Promise<string> {
  const id = newID();
  await saveMeeting({
    id, title: file.name.replace(/\.[^.]+$/, ''), createdAt: Date.now(), duration: 0, status: 'done', source: 'imported file',
    audioType: file.type || 'audio/webm', lines: [],
  });
  await appendAudio(id, 0, file);
  transcriber.start(model);
  const duration = await piecesOfFile(file, (start, samples) => void transcriber.add(id, start, samples));
  await updateMeeting(id, (m) => { m.duration = duration; });
  return id;
}

function defaultTitle() {
  const now = new Date();
  return `Meeting ${now.toLocaleDateString(undefined, { day: 'numeric', month: 'short' })} ${now.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}`;
}

export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const rest = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${rest}` : `${m}:${rest}`;
}

export type { Meeting };
