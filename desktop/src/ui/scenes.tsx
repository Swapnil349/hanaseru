import { library, Scenario, workField, WorkField } from '../content';
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
