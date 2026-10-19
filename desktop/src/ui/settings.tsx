import { useEffect, useState } from 'preact/hooks';
import { voiceLogText } from '../diagnostics';
import { checkCoach } from '../meetings/coach';
import { MODELS } from '../meetings/transcriber';
import { englishVoices, japaneseVoices, voicesReady } from '../voice';
import { useApp } from './app';
import { Chip, PageHeader } from './common';

export function Settings() {
  const { prefs, setPrefs, speaker, listener } = useApp();
  const [, setLoaded] = useState(0);
  const [name, setName] = useState(prefs.name);
  const [token, setToken] = useState(prefs.coachToken);
  const [coachStatus, setCoachStatus] = useState('');
  const [copied, setCopied] = useState(false);
  useEffect(() => {
    void voicesReady().then((list) => setLoaded(list.length));
  }, []);
  const japanese = japaneseVoices();
  const english = englishVoices();

  return (
    <div class="page narrow">
      <PageHeader title="Settings" />

      <section class="card form">
        <h2>You</h2>
        <label>
          Your name
          <input type="text" value={name} placeholder="Used in lines like 「…です」"
                 onInput={(e) => setName((e.target as HTMLInputElement).value)}
                 onBlur={() => setPrefs({ name: name.trim() })}
                 onKeyDown={(e) => { if (e.key === 'Enter') setPrefs({ name: name.trim() }); }} />
        </label>
        <div class="label">My work</div>
        <div class="chips">
          <Chip selected={prefs.workField === 'engineering'} onClick={() => setPrefs({ workField: 'engineering' })}>Railway engineering</Chip>
          <Chip selected={prefs.workField === 'finance'} onClick={() => setPrefs({ workField: 'finance' })}>Finance</Chip>
        </div>
        <p class="muted small">Your field's scenes come first in Scenes.</p>
      </section>

      <section class="card form">
        <h2>Display</h2>
        <div class="chips">
          <Chip selected={prefs.showEnglish} onClick={() => setPrefs({ showEnglish: !prefs.showEnglish })}>Show English</Chip>
          <Chip selected={prefs.showRomaji} onClick={() => setPrefs({ showRomaji: !prefs.showRomaji })}>Japanese in English letters (romaji)</Chip>
        </div>
      </section>

      <section class="card form">
        <h2>Voices</h2>
        <label>
          Japanese voice
          <select value={prefs.japaneseVoice} onChange={(e) => setPrefs({ japaneseVoice: (e.target as HTMLSelectElement).value })}>
            <option value="">Most natural ({japanese[0]?.name ?? 'none found'})</option>
            {japanese.map((v) => <option key={v.name} value={v.name}>{v.name}</option>)}
          </select>
        </label>
        <label>
          English voice
          <select value={prefs.englishVoice} onChange={(e) => setPrefs({ englishVoice: (e.target as HTMLSelectElement).value })}>
            <option value="">Most natural ({english[0]?.name ?? 'none found'})</option>
            {english.map((v) => <option key={v.name} value={v.name}>{v.name}</option>)}
          </select>
        </label>
        <div class="row">
          <button type="button" class="button" onClick={() => void speaker.speak('おはようございます。今日もよろしくお願いします。', 'coach')}>
            🔊 Try the Japanese voice
          </button>
          <button type="button" class="button" onClick={() => void speaker.speak("Good morning. Let's practise some Japanese.", 'english')}>
            🔊 Try the English voice
          </button>
        </div>
        <p class="muted small">
          Microsoft Edge has the most natural voices (the ones marked "Online (Natural)"). They need an internet
          connection; the voices installed in Windows work offline.
        </p>
      </section>

      <section class="card form">
        <h2>Meetings</h2>
        <div class="label">Speech model for transcribing meetings</div>
        <div class="chips">
          {MODELS.map((m) => (
            <Chip key={m.id} selected={prefs.whisperModel === m.id} onClick={() => setPrefs({ whisperModel: m.id })} title={m.detail}>{m.title}</Chip>
          ))}
        </div>
        <p class="muted small">{MODELS.find((m) => m.id === prefs.whisperModel)?.detail} It runs on this computer; the meeting audio is never uploaded.</p>
      </section>

      <section class="card form">
        <h2>AI coach</h2>
        <p class="muted small">
          Explains meeting lines (kana, English and the meaning of each word) with Claude, through your own coach
          server. Use the same passphrase as on the iPhone. It is kept on this computer only.
        </p>
        <label>
          Passphrase
          <input type="password" value={token} autoComplete="off" onInput={(e) => setToken((e.target as HTMLInputElement).value)}
                 onBlur={() => setPrefs({ coachToken: token.trim() })} />
        </label>
        <div class="row">
          <button type="button" class="button" onClick={async () => {
            setPrefs({ coachToken: token.trim() });
            setCoachStatus('Checking… (the server can take a minute to wake up)');
            try {
              setCoachStatus(`✓ Connected (${await checkCoach({ url: prefs.coachURL, token: token.trim() })})`);
            } catch (e) {
              setCoachStatus((e as Error).message);
            }
          }}>Check the connection</button>
          <span class="muted small">{coachStatus}</span>
        </div>
      </section>

      <section class="card form">
        <h2>Diagnostics</h2>
        <p class="muted small">
          If the app goes quiet, the voice log shows what happened (silences caught, retries, microphone errors). It
          never contains what you said.
        </p>
        <div class="row">
          <button type="button" class="button" onClick={async () => {
            try {
              await navigator.clipboard.writeText(voiceLogText() || '(the log is empty)');
              setCopied(true);
              setTimeout(() => setCopied(false), 2000);
            } catch {
              setCopied(false);
            }
          }}>{copied ? '✓ Copied' : 'Copy the voice log'}</button>
        </div>
      </section>

      <section class="card form">
        <h2>Microphone</h2>
        <p>
          {listener.isAvailable
            ? 'Japanese speech recognition is available. The first time you speak, allow the microphone.'
            : 'This browser has no speech recognition. Use Microsoft Edge or Google Chrome to practise speaking.'}
        </p>
        {listener.denied && (
          <p class="notice">
            The microphone was blocked. Click the lock icon next to the address (or the app's ⋯ menu › App info) and
            allow the microphone.
          </p>
        )}
      </section>
    </div>
  );
}
