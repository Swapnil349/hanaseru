import { useEffect, useRef, useState } from 'preact/hooks';
import { explainLines } from '../meetings/coach';
import { audioOf, deleteMeeting, getMeeting, updateMeeting, watchMeetings, type Meeting, type MeetingLine } from '../meetings/db';
import { activeRecording, clock, stopRecording, watchRecording } from '../meetings/session';
import { romajiOf } from '../romaji';
import { go, useApp } from './app';
import { PageHeader, WordsButton } from './common';
import { TranscriberLine } from './meetings';

/** One meeting: the recording, its Japanese script line by line, explanations, and practice. */
export function MeetingPage(props: { id: string }) {
  const { prefs, speaker, listener } = useApp();
  const [meeting, setMeeting] = useState<Meeting | null | undefined>(undefined);
  const [recording, setRecording] = useState(activeRecording());
  const [audioURL, setAudioURL] = useState('');
  const [playingLine, setPlayingLine] = useState('');
  const [editing, setEditing] = useState<{ id: string; text: string } | null>(null);
  const [explaining, setExplaining] = useState<{ done: number; total: number } | null>(null);
  const [error, setError] = useState('');
  const [onlyStarred, setOnlyStarred] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [level, setLevel] = useState(0);
  const [saying, setSaying] = useState('');
  const [heard, setHeard] = useState<Record<string, string>>({});
  const audio = useRef<HTMLAudioElement>(null);
  const stopAt = useRef<number | null>(null);
  const follow = useRef(true);
  const isRecording = recording?.meetingId === props.id;

  useEffect(() => {
    const load = () => void getMeeting(props.id).then((m) => setMeeting(m ?? null));
    load();
    const unwatch = watchMeetings((id) => { if (id === props.id) load(); });
    const unwatchRecording = watchRecording(setRecording);
    return () => { unwatch(); unwatchRecording(); };
  }, [props.id]);

  // The recording can be played once the meeting has stopped.
  useEffect(() => {
    if (!meeting || isRecording) return;
    let url = '';
    void audioOf(meeting.id, meeting.audioType).then((blob) => {
      if (!blob) return;
      url = URL.createObjectURL(blob);
      setAudioURL(url);
    });
    return () => { if (url) URL.revokeObjectURL(url); };
  }, [meeting?.id, meeting?.status, isRecording]);

  // While recording: the clock and the level meter.
  useEffect(() => {
    if (!isRecording || !recording) return;
    let frame = 0;
    const tick = () => {
      setElapsed(recording.recorder.elapsed);
      setLevel(recording.recorder.level());
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [isRecording, recording]);

  // New lines scroll into view while recording.
  const count = meeting?.lines.length ?? 0;
  useEffect(() => {
    if (isRecording && follow.current) document.getElementById('meeting-end')?.scrollIntoView({ block: 'end', behavior: 'smooth' });
  }, [count]);

  if (meeting === undefined) return <div class="page"><p class="muted">Loading…</p></div>;
  if (meeting === null) return <div class="page"><PageHeader title="Meeting not found" back="#/meetings" /></div>;
  const current = meeting;

  function playLine(line: MeetingLine, toEnd = true) {
    const player = audio.current;
    if (!player) return;
    speaker.stop();
    stopAt.current = toEnd ? line.end + 0.2 : null;
    player.currentTime = Math.max(0, line.start - 0.15);
    void player.play();
  }

  function onTime() {
    const player = audio.current;
    if (!player) return;
    const t = player.currentTime;
    if (stopAt.current !== null && t >= stopAt.current) {
      player.pause();
      stopAt.current = null;
    }
    const line = current.lines.find((l) => t >= l.start - 0.1 && t < l.end);
    setPlayingLine(line && !player.paused ? line.id : '');
  }

  async function change(lineId: string, edit: (line: MeetingLine, meeting: Meeting) => void) {
    await updateMeeting(current.id, (m) => {
      const line = m.lines.find((l) => l.id === lineId);
      if (line) edit(line, m);
    });
  }

  async function saveEdit() {
    if (!editing) return;
    const text = editing.text.trim();
    await change(editing.id, (line, m) => {
      if (!text) {
        m.lines = m.lines.filter((l) => l.id !== line.id);
      } else if (text !== line.japanese) {
        // Changed text needs explaining again.
        line.japanese = text;
        line.kana = undefined;
        line.english = undefined;
        line.words = undefined;
      }
    });
    setEditing(null);
  }

  async function explain() {
    setError('');
    try {
      await explainLines({ url: prefs.coachURL, token: prefs.coachToken }, current.id, current.lines, current.context ?? current.title,
                         (done, total) => setExplaining({ done, total }));
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setExplaining(null);
    }
  }

  async function say(line: MeetingLine) {
    speaker.stop();
    audio.current?.pause();
    setSaying(line.id);
    setHeard((h) => ({ ...h, [line.id]: '' }));
    const text = await listener.listen((partial) => setHeard((h) => ({ ...h, [line.id]: partial })));
    setHeard((h) => ({ ...h, [line.id]: text || '(nothing heard)' }));
    setSaying('');
  }

  function download(blob: Blob, name: string) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }

  function scriptText() {
    const parts = [current.title, new Date(current.createdAt).toLocaleString(), ''];
    for (const line of current.lines) {
      parts.push(`[${clock(line.start)}] ${line.japanese}`);
      if (line.kana && line.kana !== line.japanese) parts.push(`  ${line.kana}`);
      const romaji = romajiOf(line.japanese, line.kana ?? '');
      if (romaji) parts.push(`  ${romaji}`);
      if (line.english) parts.push(`  ${line.english}`);
      parts.push('');
    }
    return parts.join('\n');
  }

  async function saveRecording() {
    const blob = await audioOf(current.id, current.audioType);
    if (blob) download(blob, `${current.title}.${current.audioType.includes('ogg') ? 'ogg' : current.audioType.includes('mp4') ? 'm4a' : 'webm'}`);
  }

  async function remove() {
    if (!confirm(`Delete “${current.title}”, its recording and its script? This can't be undone.`)) return;
    await deleteMeeting(current.id);
    go('meetings');
  }

  const unexplained = current.lines.filter((l) => !l.english).length;
  const starred = current.lines.filter((l) => l.starred).length;
  const shown = onlyStarred ? current.lines.filter((l) => l.starred) : current.lines;

  return (
    <div class="page">
      <PageHeader title={current.title} back="#/meetings"
                  subtitle={`${new Date(current.createdAt).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })} · ${current.source} · ${clock(isRecording ? elapsed : current.duration)}`}>
        {!isRecording && (
          <>
            <button type="button" class="button" onClick={() => download(new Blob([scriptText()], { type: 'text/plain;charset=utf-8' }), `${current.title}.txt`)}>Save script</button>
            <button type="button" class="button" onClick={saveRecording}>Save recording</button>
            <button type="button" class="button danger" onClick={remove}>Delete</button>
          </>
        )}
      </PageHeader>
      <TranscriberLine />

      {isRecording && recording && (
        <section class="card recording-panel">
          <div class="row">
            <span class="rec-dot big" aria-hidden="true" />
            <b class="rec-time">{clock(elapsed)}</b>
            <div class="meter" aria-label="Sound level"><div style={{ width: `${Math.round(level * 100)}%` }} /></div>
            <button type="button" class="button" onClick={() => { if (recording.recorder.isPaused) recording.recorder.resume(); else recording.recorder.pause(); setRecording({ ...recording }); }}>
              {recording.recorder.isPaused ? '▶ Resume' : '❚❚ Pause'}
            </button>
            <button type="button" class="button primary" onClick={() => void stopRecording()}>■ Stop</button>
          </div>
          {recording.sourceEnded && <p class="notice">The computer's sound is no longer shared, so only the microphone is recording.</p>}
          <p class="muted small">
            The Japanese appears here about half a minute after it's said. You can switch to other pages; recording
            carries on. Keep this window open until you press Stop.
          </p>
        </section>
      )}

      {!isRecording && (
        <section class="card meeting-tools">
          {audioURL && (
            <audio ref={audio} src={audioURL} controls preload="auto" class="player" onTimeUpdate={onTime}
                   onPause={() => setPlayingLine('')} />
          )}
          <div class="row">
            <button type="button" class="button primary" disabled={!current.lines.length}
                    onClick={() => go(`meeting-practice/${current.id}/${starred ? 'starred' : 'all'}`)}>
              🎙 Practise {starred === 1 ? 'the starred line' : starred ? `the ${starred} starred lines` : 'all lines'}
            </button>
            {starred > 0 && (
              <button type="button" class="button" onClick={() => go(`meeting-practice/${current.id}/all`)}>Practise all lines</button>
            )}
            <button type="button" class="button" disabled={!unexplained || !!explaining} onClick={explain}
                    title="Kana, romaji, English and the meaning of every word, from the AI coach">
              ✨ {explaining ? `Explaining… ${explaining.done}/${explaining.total}` : unexplained ? `Explain ${unexplained} line${unexplained === 1 ? '' : 's'}` : 'All explained'}
            </button>
            {starred > 0 && (
              <label class="check inline">
                <input type="checkbox" checked={onlyStarred} onChange={() => setOnlyStarred(!onlyStarred)} /> Only starred
              </label>
            )}
          </div>
          <label class="context">
            <span class="muted small">What was the meeting about? (helps the explanations)</span>
            <input type="text" value={current.context ?? ''} placeholder="e.g. viaduct construction progress with the Japanese consultants"
                   onChange={(e) => void updateMeeting(current.id, (m) => { m.context = (e.target as HTMLInputElement).value; })} />
          </label>
          {error && <p class="notice">{error}</p>}
          <p class="muted small">
            Click a time to hear that line from the recording. Correct a line with ✎ if the transcription got it wrong,
            and star ☆ the lines you want to learn.
          </p>
        </section>
      )}

      <div class="script meeting-script" onWheel={() => { follow.current = false; }}>
        {shown.length === 0 && (
          <p class="muted">{isRecording ? 'Listening… the first lines appear in about half a minute.' : 'No lines yet.'}</p>
        )}
        {shown.map((line) => {
          const romaji = romajiOf(line.japanese, line.kana ?? '');
          return (
            <article key={line.id} class={'script-row' + (playingLine === line.id ? ' playing' : '') + (line.starred ? ' learner' : '')}>
              <div class="line-head">
                <button type="button" class="time" disabled={!audioURL} onClick={() => playLine(line)} title="Hear this line from the recording">
                  ▶ {clock(line.start)}
                </button>
                <button type="button" class={'star' + (line.starred ? ' on' : '')} aria-pressed={!!line.starred}
                        title={line.starred ? 'Starred to learn' : 'Star to learn'}
                        onClick={() => void change(line.id, (l) => { l.starred = !l.starred; })}>
                  {line.starred ? '★' : '☆'}
                </button>
              </div>
              {editing?.id === line.id ? (
                <div class="edit">
                  <textarea lang="ja" value={editing.text} rows={2} autoFocus
                            onInput={(e) => setEditing({ id: line.id, text: (e.target as HTMLTextAreaElement).value })}
                            onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); void saveEdit(); } if (e.key === 'Escape') setEditing(null); }} />
                  <div class="row">
                    <button type="button" class="button primary" onClick={() => void saveEdit()}>Save</button>
                    <button type="button" class="button" onClick={() => setEditing(null)}>Cancel</button>
                    <span class="muted small">Leave it empty to remove the line.</span>
                  </div>
                </div>
              ) : (
                <div class="jp-block">
                  <div class="jp" lang="ja">{line.japanese}</div>
                  {line.kana && line.kana !== line.japanese && <div class="kana" lang="ja">{line.kana}</div>}
                  {prefs.showRomaji && romaji && <div class="romaji">{romaji}</div>}
                  {prefs.showEnglish && line.english && <div class="english">{line.english}</div>}
                </div>
              )}
              {editing?.id !== line.id && (
                <div class="row">
                  <button type="button" class="button" onClick={() => { audio.current?.pause(); void speaker.speak(line.japanese, 'coach', 0.9); }} title="In a clear voice">🔊 Clear voice</button>
                  {listener.isAvailable && !isRecording && (
                    <button type="button" class="button signal" disabled={!!saying} onClick={() => void say(line)}>
                      🎙 {saying === line.id ? 'Listening…' : 'Say it'}
                    </button>
                  )}
                  {line.words && line.words.length > 0 && (
                    <WordsButton lines={[{ title: clock(line.start), japanese: line.japanese, english: line.english ?? '', words: line.words }]}
                                 onSay={(word) => void speaker.speak(word, 'coach', 0.9)} onOpen={() => audio.current?.pause()} />
                  )}
                  <button type="button" class="link" onClick={() => setEditing({ id: line.id, text: line.japanese })}>✎ Correct</button>
                </div>
              )}
              {heard[line.id] && <div class="feedback">Heard: <span lang="ja">{heard[line.id]}</span></div>}
            </article>
          );
        })}
        <div id="meeting-end" />
      </div>
    </div>
  );
}
