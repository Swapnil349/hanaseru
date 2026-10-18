import { useEffect, useState } from 'preact/hooks';
import { library, workField } from '../content';
import { japaneseVoices, voicesReady } from '../voice';
import { useApp } from './app';

export function Home() {
  const { prefs, listener, progress } = useApp();
  const [hasVoice, setHasVoice] = useState(true);
  useEffect(() => {
    void voicesReady().then(() => setHasVoice(japaneseVoices().length > 0));
  }, []);
  const hour = new Date().getHours();
  const [ja, en] = hour >= 4 && hour <= 10 ? ['おはようございます', 'Good morning']
    : hour <= 17 && hour > 10 ? ['こんにちは', 'Good afternoon'] : ['こんばんは', 'Good evening'];
  const mine = library.scenarios.filter((s) => workField(s) === prefs.workField);
  const practised = library.scenarios.filter((s) => progress.hasPractised(s.id)).length;

  return (
    <div class="page">
      <div class="rule" aria-hidden="true" />
      <p class="muted" lang="ja">{ja}</p>
      <h1 class="greeting">{en}{prefs.name ? `, ${prefs.name}` : ''}</h1>

      {!hasVoice && (
        <div class="notice">
          No Japanese voice found. Open this app in <b>Microsoft Edge</b>, which includes Microsoft's natural Japanese
          voices, or add Japanese in Windows Settings › Time &amp; language › Speech.
        </div>
      )}
      {!listener.isAvailable && (
        <div class="notice">
          Speaking practice needs <b>Microsoft Edge</b> (or Google Chrome) for Japanese speech recognition. Reading,
          listening and the word lists work everywhere.
        </div>
      )}

      <div class="cards">
        <a class="card link-card" href="#/scenes">
          <span class="card-icon" aria-hidden="true">💬</span>
          <span>
            <b>Scenes</b>
            <span class="muted">{library.scenarios.length} conversations: read, hear and learn every line</span>
          </span>
        </a>
        <a class="card link-card" href="#/scenes">
          <span class="card-icon" aria-hidden="true">🎙</span>
          <span>
            <b>Speaking practice</b>
            <span class="muted">Open a scene and press Start: watch, repeat, then the real conversation</span>
          </span>
        </a>
        <a class="card link-card" href="#/vocabulary">
          <span class="card-icon" aria-hidden="true">📖</span>
          <span>
            <b>My vocabulary</b>
            <span class="muted">All {library.vocabulary.length} words in the course, with romaji</span>
          </span>
        </a>
      </div>

      <div class="stats">
        <div><b>{practised}</b><span class="muted">scenes practised</span></div>
        <div><b>{mine.length}</b><span class="muted">{prefs.workField === 'finance' ? 'finance' : 'railway'} work scenes</span></div>
      </div>

      <p class="muted small">
        Keyboard in practice: Space pause / play · ← back · → next · R again. Your voice is turned into text by the
        browser's speech service and never recorded by Hanaseru.
      </p>
    </div>
  );
}
