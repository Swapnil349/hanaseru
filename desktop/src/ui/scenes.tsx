import { useEffect, useState } from 'preact/hooks';
import { library, Scenario, workField, WorkField } from '../content';
import { importScenes, isOwn, loadScenes, watchScenes } from '../myScenes';
import { useApp } from './app';
import { Chip, PageHeader } from './common';

interface SceneGroup {
  title: string;
  field: WorkField | null;
  track: 'work' | 'everyday';
}

/** Every conversation, grouped: your own field's scenes first, then everyday life, then the other field's. */
export function Scenes() {
  const { prefs, setPrefs, progress } = useApp();
  const [, setVersion] = useState(0);
  const [message, setMessage] = useState('');
  useEffect(() => watchScenes(() => setVersion((v) => v + 1)), []);
  const own = library.scenarios.filter((s) => isOwn(s.id));

  async function importFile(event: Event) {
    const input = event.target as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (!file) return;
    try {
      const count = importScenes(await file.text());
      setMessage(`✓ Added ${count} scene${count === 1 ? '' : 's'}.`);
    } catch (e) {
      setMessage(`That file has no scenes Hanaseru can read (${(e as Error).message}).`);
    }
  }

  function exportAll() {
    const url = URL.createObjectURL(new Blob([JSON.stringify(loadScenes(), null, 2)], { type: 'application/json' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'Hanaseru my scenes.json';
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 2000);
  }
  const railway: SceneGroup = { title: 'Railway work', field: 'engineering', track: 'work' };
  const finance: SceneGroup[] = [
    { title: 'Finance at work', field: 'finance', track: 'work' },
    { title: 'Money in Japan', field: 'finance', track: 'everyday' },
  ];
  const everyday: SceneGroup = { title: 'Everyday', field: null, track: 'everyday' };
  const groups = prefs.workField === 'finance' ? [...finance, everyday, railway] : [railway, everyday, ...finance];

  return (
    <div class="page">
      <PageHeader title="Scenes" subtitle="Read, hear and practise every conversation.">
        <span class="muted small">My work:</span>
        <Chip selected={prefs.workField === 'engineering'} onClick={() => setPrefs({ workField: 'engineering' })}>Railway</Chip>
        <Chip selected={prefs.workField === 'finance'} onClick={() => setPrefs({ workField: 'finance' })}>Finance</Chip>
      </PageHeader>
      <section class="group">
        <div class="page-title-row">
          <h2 class="section-title">My scenes</h2>
          <div class="header-actions">
            <a class="button primary" href="#/my-scene/new">✨ New scene</a>
            <label class="button file-button">Import…<input type="file" accept="application/json,.json" onChange={importFile} /></label>
            {own.length > 0 && <button type="button" class="button" onClick={exportAll}>Export all</button>}
          </div>
        </div>
        {message && <p class="muted small">{message}</p>}
        {own.length === 0 ? (
          <p class="muted">
            Your own conversations and speeches: describe a situation in English, by voice or typing, and the coach
            writes it in Japanese for you to learn — asking for leave, ordering lunch, your self-introduction…
          </p>
        ) : (
          <div class="scene-grid">
            {own.map((scene) => <SceneCard key={scene.id} scene={scene} practised={progress.hasPractised(scene.id)} />)}
          </div>
        )}
      </section>
      {groups.map((group) => {
        const scenes = library.scenarios
          .filter((s) => s.track === group.track && workField(s) === group.field)
          .sort((a, b) => a.level - b.level);
        if (!scenes.length) return null;
        return (
          <section key={group.title} class="group">
            <h2 class="section-title">{group.title}</h2>
            <div class="scene-grid">
              {scenes.map((scene) => <SceneCard key={scene.id} scene={scene} practised={progress.hasPractised(scene.id)} />)}
            </div>
          </section>
        );
      })}
    </div>
  );
}

function SceneCard(props: { scene: Scenario; practised: boolean }) {
  const { scene } = props;
  const persona = library.persona(scene.personaID);
  return (
    <a class="card scene-card" href={`#/scene/${encodeURIComponent(scene.id)}`}>
      <span class="scene-title">{scene.title}{props.practised && <span class="done" title="Practised"> ✓</span>}</span>
      <span class="muted" lang="ja">{scene.titleJa}</span>
      <span class="muted small">{persona?.nameEn ?? ''} · {scene.beats.length} lines · level {scene.level}</span>
    </a>
  );
}
