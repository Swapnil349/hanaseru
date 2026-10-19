// Recorded meetings, kept on this computer in the browser's database (IndexedDB): the recording, its transcript
// and anything still waiting to be transcribed. Nothing is uploaded except lines you choose to have explained.

export interface MeetingWord {
  ja: string;
  kana: string;
  en: string;
}

export interface MeetingLine {
  id: string;
  /** Seconds from the start of the recording. */
  start: number;
  end: number;
  japanese: string;
  /** Filled in by "Explain" (the AI coach). */
  kana?: string;
  english?: string;
  words?: MeetingWord[];
  starred?: boolean;
}

export interface Meeting {
  id: string;
  title: string;
  createdAt: number;
  /** Seconds recorded. */
  duration: number;
  /** "recording" while it runs; "done" once stopped (transcription may still be catching up). */
  status: 'recording' | 'done';
  source: string;
  audioType: string;
  lines: MeetingLine[];
  context?: string;
}

/** A stretch of audio waiting for transcription: 16 kHz mono, as 16-bit samples. */
export interface PendingSegment {
  key: string;
  meetingId: string;
  start: number;
  end: number;
  pcm: Int16Array;
}

const NAME = 'hanaseru-meetings';
let opening: Promise<IDBDatabase> | null = null;

function database(): Promise<IDBDatabase> {
  opening ??= new Promise((resolve, reject) => {
    const request = indexedDB.open(NAME, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      db.createObjectStore('meetings', { keyPath: 'id' });
      db.createObjectStore('audio');
      db.createObjectStore('segments', { keyPath: 'key' }).createIndex('meeting', 'meetingId');
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => {
      opening = null;
      reject(request.error);
    };
  });
  return opening;
}

function done<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function store(name: string, mode: IDBTransactionMode = 'readonly') {
  return (await database()).transaction(name, mode).objectStore(name);
}

export async function listMeetings(): Promise<Meeting[]> {
  const all = await done((await store('meetings')).getAll() as IDBRequest<Meeting[]>);
  return all.sort((a, b) => b.createdAt - a.createdAt);
}

export async function getMeeting(id: string): Promise<Meeting | undefined> {
  return done((await store('meetings')).get(id) as IDBRequest<Meeting | undefined>);
}

export async function saveMeeting(meeting: Meeting): Promise<void> {
  await done((await store('meetings', 'readwrite')).put(meeting));
  notify(meeting.id);
}

/** Changes one meeting safely (reads the latest copy first). */
export async function updateMeeting(id: string, change: (meeting: Meeting) => void): Promise<Meeting | undefined> {
  const meeting = await getMeeting(id);
  if (!meeting) return undefined;
  change(meeting);
  await saveMeeting(meeting);
  return meeting;
}

/** Keys sort in recording order: meeting id, then a zero-padded chunk number. */
const audioKey = (id: string, index: number) => `${id}:${String(index).padStart(6, '0')}`;

export async function appendAudio(id: string, index: number, chunk: Blob): Promise<void> {
  await done((await store('audio', 'readwrite')).put(chunk, audioKey(id, index)));
}

export async function audioOf(id: string, type: string): Promise<Blob | null> {
  const range = IDBKeyRange.bound(`${id}:`, `${id}:￿`);
  const chunks = await done((await store('audio')).getAll(range) as IDBRequest<Blob[]>);
  return chunks.length ? new Blob(chunks, { type }) : null;
}

export async function addSegment(segment: PendingSegment): Promise<void> {
  await done((await store('segments', 'readwrite')).put(segment));
}

export async function pendingSegments(): Promise<PendingSegment[]> {
  const all = await done((await store('segments')).getAll() as IDBRequest<PendingSegment[]>);
  return all.sort((a, b) => (a.key < b.key ? -1 : 1));
}

export async function removeSegment(key: string): Promise<void> {
  await done((await store('segments', 'readwrite')).delete(key));
}

export async function deleteMeeting(id: string): Promise<void> {
  const db = await database();
  const transaction = db.transaction(['meetings', 'audio', 'segments'], 'readwrite');
  transaction.objectStore('meetings').delete(id);
  transaction.objectStore('audio').delete(IDBKeyRange.bound(`${id}:`, `${id}:￿`));
  const segments = transaction.objectStore('segments');
  const keys = await done(segments.index('meeting').getAllKeys(id));
  for (const key of keys) segments.delete(key);
  await new Promise<void>((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  notify(id);
}

// MARK: - Change notifications (the screens redraw when a meeting changes)

const watchers = new Set<(id: string) => void>();

export function watchMeetings(watcher: (id: string) => void): () => void {
  watchers.add(watcher);
  return () => watchers.delete(watcher);
}

function notify(id: string) {
  watchers.forEach((w) => w(id));
}

export function newID(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}
