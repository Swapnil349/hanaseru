import { useEffect, useState } from 'preact/hooks';
import { englishVoices, japaneseVoices, voicesReady } from '../voice';
import { useApp } from './app';
import { Chip, PageHeader } from './common';

export function Settings() {
  const { prefs, setPrefs, speaker, listener } = useApp();
  const [, setLoaded] = useState(0);
  const [name, setName] = useState(prefs.name);
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
