// The learner's own scenes: described in English, written by the AI coach, saved on this computer, and taught like
// the built-in ones. The format is shared with the phone apps (docs/MY-SCENES.md), so scenes can be exported and
// imported between them.
import { library, type Persona, type Scenario, type WordGloss } from './content';
import { call, type CoachSettings } from './meetings/coach';

export interface SceneLine {
  japanese: string;
  kana: string;
  english: string;
  words: WordGloss[];
}

export interface SceneResult {
  title: string;
  titleJa: string;
  situationEn: string;
  placeEn: string;
  partnerNameJa: string;
  partnerNameEn: string;
  partnerRole: string;
  partnerGender: 'male' | 'female';
  track: 'work' | 'everyday';
  beats: { partner: SceneLine; learner: SceneLine; hintEn: string }[];
  closing: SceneLine;
}

export type SceneKind = 'conversation' | 'monologue';

export interface SavedScene {
  id: string;
  kind: SceneKind;
  description: string;
  createdAt: number;
  updatedAt: number;
  result: SceneResult;
}

export interface SceneRequest {
  description: string;
  kind: SceneKind;
  learnerName: string;
  learnerLevel: number;
  politeness: 'casual' | 'professional' | 'veryPolite';
  length: number;
}

const KEY = 'myScenes';

export function loadScenes(): SavedScene[] {
  try {
    const list = JSON.parse(localStorage.getItem(KEY) ?? '[]') as SavedScene[];
    return Array.isArray(list) ? list.filter(isSavedScene) : [];
  } catch {
    return [];
  }
}

function store(scenes: SavedScene[]) {
  localStorage.setItem(KEY, JSON.stringify(scenes));
  applyScenes(scenes);
  watchers.forEach((w) => w());
}

const watchers = new Set<() => void>();

export function watchScenes(watcher: () => void): () => void {
  watchers.add(watcher);
  return () => watchers.delete(watcher);
}

export function savedScene(id: string): SavedScene | undefined {
  return loadScenes().find((s) => s.id === id);
}

export function saveScene(scene: SavedScene) {
  const scenes = loadScenes().filter((s) => s.id !== scene.id);
  store([scene, ...scenes]);
}

export function deleteScene(id: string) {
  store(loadScenes().filter((s) => s.id !== id));
}

/** Adds scenes from a file (one scene or a list); returns how many were added or updated. */
export function importScenes(json: string): number {
  const parsed = JSON.parse(json) as unknown;
  const incoming = (Array.isArray(parsed) ? parsed : [parsed]).filter(isSavedScene);
  if (!incoming.length) throw new Error('No scenes were found in that file.');
  const byID = new Map(loadScenes().map((s) => [s.id, s]));
  for (const scene of incoming) byID.set(scene.id, scene);
  store([...byID.values()].sort((a, b) => b.updatedAt - a.updatedAt));
  return incoming.length;
}

function isSavedScene(value: unknown): value is SavedScene {
  const scene = value as SavedScene;
  return !!scene && typeof scene.id === 'string' && scene.id.startsWith('my.') && !!scene.result
    && Array.isArray(scene.result.beats) && typeof scene.result.title === 'string';
}

/** Writes a new scene, or changes one (`previous`) as described. Takes up to a few minutes. */
export async function writeScene(settings: CoachSettings, request: SceneRequest, previous?: SavedScene): Promise<SavedScene> {
  const body = { ...request, previous: previous ? JSON.stringify(previous.result) : undefined };
  const result = (await call(settings, '/v1/scene', body, 200_000)) as SceneResult;
  if (!result?.beats?.length) throw new Error('The coach returned an empty scene. Try describing it again.');
  const now = Date.now();
  return {
    id: previous?.id ?? `my.${now.toString(36)}${Math.random().toString(36).slice(2, 6)}`,
    kind: request.kind,
    description: previous ? `${previous.description}\nChanged: ${request.description}` : request.description,
    createdAt: previous?.createdAt ?? now,
    updatedAt: now,
    result,
  };
}

// MARK: - As lessons

/** A saved scene as an ordinary scenario, its partner, and the word lists for its lines. */
export function toLesson(scene: SavedScene): { scenario: Scenario; persona: Persona; glossary: Record<string, WordGloss[]> } {
  const r = scene.result;
  const glossary: Record<string, WordGloss[]> = {};
  const words = (line: SceneLine) => {
    if (line.japanese && line.words?.length) glossary[line.japanese] = line.words;
  };
  const scenario: Scenario = {
    id: scene.id,
    title: r.title,
    titleJa: r.titleJa,
    track: r.track === 'work' ? 'work' : 'everyday',
    level: 3,
    personaID: `${scene.id}.partner`,
    situationEn: r.situationEn,
    placeEn: r.placeEn,
    targetTerms: [],
    beats: r.beats.map((beat, index) => {
      words(beat.partner);
      words(beat.learner);
      return {
        id: `b${index + 1}`,
        line: beat.partner.japanese,
        kana: beat.partner.kana,
        english: beat.partner.english,
        hintEn: beat.hintEn,
        intentEn: beat.hintEn,
        responses: [{ japanese: beat.learner.japanese, kana: beat.learner.kana, english: beat.learner.english }],
      };
    }),
    closingLine: r.closing?.japanese ?? '',
    closingKana: r.closing?.kana ?? '',
    closingEnglish: r.closing?.english ?? '',
    field: 'own',
  };
  if (r.closing) words(r.closing);
  const persona: Persona = {
    id: `${scene.id}.partner`,
    nameJa: r.partnerNameJa,
    nameEn: r.partnerNameEn,
    role: r.partnerRole,
    speakingRate: 1,
    voiceGender: r.partnerGender === 'female' ? 'female' : 'male',
  };
  return { scenario, persona, glossary };
}

/** Puts the saved scenes into the course, so every page and practice can use them. */
export function applyScenes(scenes = loadScenes()) {
  const lessons = scenes.map(toLesson);
  library.setOwn({
    scenarios: lessons.map((l) => l.scenario),
    personas: lessons.map((l) => l.persona),
    glossary: Object.assign({}, ...lessons.map((l) => l.glossary)),
  });
}

export function isOwn(scenarioID: string) {
  return scenarioID.startsWith('my.');
}

export function isMonologue(scenario: Scenario) {
  return scenario.beats.every((b) => !b.line);
}
