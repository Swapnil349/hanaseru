import { isSilent, RATE, toFloat32 } from './audio';
import { addSegment, newID, PendingSegment, pendingSegments, removeSegment, updateMeeting, type MeetingLine } from './db';
import type { WorkerRequest, WorkerResponse } from './transcriber.worker';

export const MODELS = [
  { id: 'onnx-community/whisper-small', title: 'Standard', detail: 'About 250–400 MB, downloaded once. Good Japanese; fine on most laptops.' },
  { id: 'onnx-community/whisper-large-v3-turbo', title: 'Most accurate', detail: 'About 560 MB, downloaded once. Best Japanese; needs a graphics card, slow without one.' },
];

export interface TranscriberStatus {
  state: 'idle' | 'loading' | 'ready' | 'error';
  /** 0…1 while the model downloads. */
  download: number;
  device: string;
  waiting: number;
  message: string;
}

/**
 * Transcribes meeting audio in the background, one piece at a time, in recording order. Pieces wait in the
 * database, so nothing is lost if the app is closed: transcription carries on the next time it opens.
 */
class Transcriber {
  status: TranscriberStatus = { state: 'idle', download: 0, device: '', waiting: 0, message: '' };
  private worker: Worker | null = null;
  private model = '';
  private running = false;
  private resolvers = new Map<string, (r: WorkerResponse) => void>();
  private files = new Map<string, { loaded: number; total: number }>();
  private watchers = new Set<(s: TranscriberStatus) => void>();
  private failures = new Map<string, number>();

  watch(watcher: (s: TranscriberStatus) => void): () => void {
    this.watchers.add(watcher);
    watcher(this.status);
    return () => this.watchers.delete(watcher);
  }

  private set(change: Partial<TranscriberStatus>) {
    this.status = { ...this.status, ...change };
    this.watchers.forEach((w) => w(this.status));
  }

  /** Starts the model (downloading it the first time). */
  start(model: string) {
    if (this.worker && this.model === model) return;
    this.worker?.terminate();
    this.model = model;
    this.files.clear();
    this.worker = new Worker(new URL('./transcriber.worker.ts', import.meta.url), { type: 'module' });
    this.worker.onmessage = (event: MessageEvent<WorkerResponse>) => this.receive(event.data);
    this.set({ state: 'loading', download: 0, message: '' });
    this.post({ type: 'load', model });
    void this.drain();
  }

  private post(request: WorkerRequest, transfer: Transferable[] = []) {
    this.worker?.postMessage(request, transfer);
  }

  private receive(message: WorkerResponse) {
    switch (message.type) {
      case 'progress': {
        this.files.set(message.file, { loaded: message.loaded, total: message.total });
        let loaded = 0;
        let total = 0;
        this.files.forEach((f) => { loaded += f.loaded; total += f.total; });
        this.set({ download: total ? loaded / total : 0 });
        return;
      }
      case 'ready':
        this.set({ state: 'ready', device: message.device === 'webgpu' ? 'graphics card' : 'processor', download: 1 });
        void this.drain();
        return;
      case 'error':
        if (message.id) this.resolvers.get(message.id)?.(message);
        else this.set({ state: 'error', message: message.message });
        return;
      case 'result':
        this.resolvers.get(message.id)?.(message);
    }
  }

  /** Queues a piece of a meeting for transcription. */
  async add(meetingId: string, start: number, samples: Float32Array) {
    if (isSilent(samples)) return;
    const pcm = new Int16Array(samples.length);
    for (let i = 0; i < samples.length; i++) pcm[i] = Math.max(-1, Math.min(1, samples[i])) * 0x7fff;
    await addSegment({ key: `${meetingId}|${start.toFixed(2).padStart(9, '0')}`, meetingId, start, end: start + samples.length / RATE, pcm });
    this.set({ waiting: this.status.waiting + 1 });
    void this.drain();
  }

  private transcribe(audio: Float32Array): Promise<WorkerResponse> {
    const id = newID();
    return new Promise((resolve) => {
      this.resolvers.set(id, (response) => {
        this.resolvers.delete(id);
        resolve(response);
      });
      this.post({ type: 'transcribe', id, audio }, [audio.buffer]);
    });
  }

  /** Works through everything waiting, oldest first. */
  private async drain() {
    if (this.running || this.status.state !== 'ready') return;
    this.running = true;
    try {
      for (;;) {
        const waiting = await pendingSegments();
        this.set({ waiting: waiting.length });
        const next = waiting[0];
        if (!next) break;
        const response = await this.transcribe(toFloat32(next.pcm));
        if (response.type === 'error') {
          // Tried again next time; a piece that fails twice is skipped so the rest can go on.
          const failures = (this.failures.get(next.key) ?? 0) + 1;
          this.failures.set(next.key, failures);
          this.set({ message: `A piece could not be transcribed: ${response.message}` });
          if (failures < 2) break;
        } else if (response.type === 'result') {
          await this.store(next, response.chunks);
          this.set({ message: '' });
        }
        await removeSegment(next.key);
      }
    } finally {
      this.running = false;
      this.set({ waiting: (await pendingSegments()).length });
    }
  }

  private async store(segment: PendingSegment, chunks: { text: string; start: number; end: number }[]) {
    const lines: MeetingLine[] = chunks
      .filter((c) => c.text && !isHallucination(c.text))
      .map((c) => ({
        id: newID(),
        start: segment.start + c.start,
        end: Math.min(segment.end, segment.start + Math.max(c.end, c.start + 0.5)),
        japanese: c.text,
      }));
    if (!lines.length) return;
    await updateMeeting(segment.meetingId, (meeting) => {
      meeting.lines = [...meeting.lines, ...lines].sort((a, b) => a.start - b.start);
    });
  }
}

/** Phrases Whisper is known to invent over silence or music (from video subtitles it learnt from). */
const HALLUCINATIONS = ['ご視聴ありがとうございました', 'ご清聴ありがとうございました', 'チャンネル登録', 'お疲れ様でした。お疲れ様でした。', '字幕'];

export function isHallucination(text: string) {
  const plain = text.replace(/[\s。、！？!?.,]/g, '');
  return !plain || HALLUCINATIONS.some((h) => plain.includes(h.replace(/[。、]/g, ''))) || /^(.)\1{6,}$/.test(plain);
}

export const transcriber = new Transcriber();
