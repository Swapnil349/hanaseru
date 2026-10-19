import { useEffect, useState } from 'preact/hooks';
import { listMeetings, watchMeetings, type Meeting } from '../meetings/db';
import { activeRecording, clock, importRecording, startRecording, watchRecording } from '../meetings/session';
import { MODELS, transcriber, TranscriberStatus } from '../meetings/transcriber';
import { go, useApp } from './app';
import { PageHeader } from './common';

/** Status of the speech model, shown wherever meetings are transcribed. */
export function TranscriberLine() {
  const [status, setStatus] = useState<TranscriberStatus>(transcriber.status);
  useEffect(() => transcriber.watch(setStatus), []);
  if (status.state === 'idle') return null;
  return (
    <div class="muted small transcriber-line" aria-live="polite">
      {status.state === 'loading' && (
        <span>Getting the speech model ready{status.download > 0 && status.download < 1 ? ` — downloading ${Math.round(status.download * 100)}% (only the first time)` : '…'}</span>
      )}
      {status.state === 'ready' && (
        <span>Transcribing on this computer's {status.device}{status.waiting ? ` · ${status.waiting} piece${status.waiting === 1 ? '' : 's'} waiting` : ' · up to date'}</span>
      )}
      {status.state === 'error' && <span class="error-text">{status.message}</span>}
      {status.state === 'ready' && status.message && <span class="error-text"> · {status.message}</span>}
    </div>
  );
}

export function Meetings() {
  const { prefs } = useApp();
  const [meetings, setMeetings] = useState<Meeting[]>([]);
  const [recording, setRecording] = useState(activeRecording());
  const [title, setTitle] = useState('');
  const [microphone, setMicrophone] = useState(true);
  const [computerSound, setComputerSound] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const load = () => void listMeetings().then(setMeetings);
    load();
    const unwatch = watchMeetings(load);
    const unwatchRecording = watchRecording(setRecording);
    return () => { unwatch(); unwatchRecording(); };
  }, []);

  async function start() {
    setBusy(true);
    setError('');
    try {
      const id = await startRecording(title, microphone, computerSound, prefs.whisperModel);
      go(`meeting/${id}`);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function importFile(event: Event) {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;
    setBusy(true);
    setError('');
    try {
      const id = await importRecording(file, prefs.whisperModel);
      go(`meeting/${id}`);
    } catch (e) {
      setError(`That file could not be read as audio (${(e as Error).message}).`);
    } finally {
      setBusy(false);
    }
  }

  const model = MODELS.find((m) => m.id === prefs.whisperModel) ?? MODELS[0];

  return (
    <div class="page">
      <PageHeader title="Meetings" subtitle="Record what Japanese colleagues say, get the script, and practise it." />
      <TranscriberLine />

      {recording ? (
        <a class="card recording-banner" href={`#/meeting/${recording.meetingId}`}>
          <span class="rec-dot" aria-hidden="true" /> Recording now — open the meeting
        </a>
      ) : (
        <section class="card form">
          <h2>Record a meeting</h2>
          <label>
            Name
            <input type="text" value={title} placeholder="e.g. Weekly progress meeting" onInput={(e) => setTitle((e.target as HTMLInputElement).value)} />
          </label>
          <div class="label">What to record</div>
          <label class="check">
            <input type="checkbox" checked={microphone} onChange={() => setMicrophone(!microphone)} />
            <span><b>Microphone</b> — people speaking in the room</span>
          </label>
          <label class="check">
            <input type="checkbox" checked={computerSound} onChange={() => setComputerSound(!computerSound)} />
            <span>
              <b>This computer's sound</b> — an online meeting (Teams, Zoom, Webex), even with headphones.
              When asked, choose <b>Entire screen</b> and switch on <b>Also share system audio</b>.
            </span>
          </label>
          <p class="muted small">
            Ask everyone's permission before you record. The recording stays on this computer; the speech is turned
            into Japanese text here too, with the {model.title.toLowerCase()} speech model ({model.detail.split('.')[0].replace('About', 'about')}).
          </p>
          {error && <p class="notice">{error}</p>}
          <div class="row">
            <button type="button" class="button record big" disabled={busy || (!microphone && !computerSound)} onClick={start}>
              <span class="rec-dot" aria-hidden="true" /> Start recording
            </button>
            <label class="button big file-button">
              Import a recording…
              <input type="file" accept="audio/*,video/*" onChange={importFile} disabled={busy} />
            </label>
          </div>
        </section>
      )}

      <h2 class="section-title">Your meetings</h2>
      {meetings.length === 0 && <p class="muted">No meetings yet.</p>}
      <div class="scene-grid">
        {meetings.map((m) => (
          <a key={m.id} class="card scene-card" href={`#/meeting/${m.id}`}>
            <span class="scene-title">{m.status === 'recording' && <span class="rec-dot" aria-hidden="true" />} {m.title}</span>
            <span class="muted small">
              {new Date(m.createdAt).toLocaleString(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
              {' · '}{clock(m.duration)} · {m.lines.length} lines
            </span>
            <span class="muted small">{m.lines.filter((l) => l.english).length} explained · {m.lines.filter((l) => l.starred).length} starred</span>
          </a>
        ))}
      </div>
    </div>
  );
}
