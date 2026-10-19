import { createContext } from 'preact';
import { useContext, useEffect, useMemo, useState } from 'preact/hooks';
import { library } from '../content';
import type { Mode } from '../practice';
import { loadPrefs, Prefs, savePrefs, StoredProgress } from '../store';
import { voicesReady, WebListener, WebSpeaker } from '../voice';
import { pendingSegments, listMeetings, saveMeeting } from '../meetings/db';
import { activeRecording } from '../meetings/session';
import { transcriber } from '../meetings/transcriber';
import { Home } from './home';
import { MeetingPage } from './meeting';
import { MeetingPractice } from './meeting-practice';
import { Meetings } from './meetings';
import { applyScenes } from '../myScenes';
import { MySceneEditor } from './my-scene';
import { Practice } from './practice';
import { SceneDetail } from './scene';
import { Scenes } from './scenes';
import { Settings } from './settings';
import { Vocabulary } from './vocabulary';

interface AppServices {
  prefs: Prefs;
  setPrefs: (change: Partial<Prefs>) => void;
  speaker: WebSpeaker;
  listener: WebListener;
  progress: StoredProgress;
}

const AppContext = createContext<AppServices | null>(null);

export function useApp(): AppServices {
  const app = useContext(AppContext);
  if (!app) throw new Error('No app context');
  return app;
}

let currentPrefs = loadPrefs();
// The learner's own scenes join the course before anything is shown.
applyScenes();
const speaker = new WebSpeaker(() => ({ japanese: currentPrefs.japaneseVoice, english: currentPrefs.englishVoice }));
const listener = new WebListener();
const progress = new StoredProgress();

/** Pages, by the part of the address after #. */
type Route =
  | { page: 'home' }
  | { page: 'scenes' }
  | { page: 'scene'; id: string }
  | { page: 'practice'; id: string; mode: Mode; partner: boolean; from: number | null }
  | { page: 'vocabulary' }
  | { page: 'myScene'; editID?: string }
  | { page: 'meetings' }
  | { page: 'meeting'; id: string }
  | { page: 'meetingPractice'; id: string; which: 'all' | 'starred' }
  | { page: 'settings' };

function parse(hash: string): Route {
  const parts = hash.replace(/^#\/?/, '').split('/').map(decodeURIComponent);
  switch (parts[0]) {
    case 'scenes': return { page: 'scenes' };
    case 'scene': return parts[1] ? { page: 'scene', id: parts[1] } : { page: 'scenes' };
    case 'practice': {
      const from = parts[4] !== undefined && parts[4] !== '' ? Number(parts[4]) : null;
      return parts[1]
        ? { page: 'practice', id: parts[1], mode: (parts[2] as Mode) || 'automatic', partner: parts[3] === 'partner',
            from: from !== null && Number.isFinite(from) ? from : null }
        : { page: 'scenes' };
    }
    case 'vocabulary': return { page: 'vocabulary' };
    case 'my-scene': return { page: 'myScene', editID: parts[1] === 'edit' ? parts[2] : undefined };
    case 'meetings': return { page: 'meetings' };
    case 'meeting': return parts[1] ? { page: 'meeting', id: parts[1] } : { page: 'meetings' };
    case 'meeting-practice':
      return parts[1] ? { page: 'meetingPractice', id: parts[1], which: parts[2] === 'starred' ? 'starred' : 'all' } : { page: 'meetings' };
    case 'settings': return { page: 'settings' };
    default: return { page: 'home' };
  }
}

export function go(path: string) {
  location.hash = '#/' + path;
}

export function practicePath(id: string, mode: Mode, partner: boolean, from?: number | null) {
  return `practice/${encodeURIComponent(id)}/${mode}/${partner ? 'partner' : 'you'}` + (from != null ? `/${from}` : '');
}

/**
 * When the app opens: a meeting left "recording" (the window was closed) is closed off, and anything still waiting
 * to be transcribed carries on.
 */
async function resumeMeetings() {
  try {
    for (const meeting of await listMeetings()) {
      if (meeting.status === 'recording' && activeRecording()?.meetingId !== meeting.id) {
        await saveMeeting({ ...meeting, status: 'done' });
      }
    }
    if ((await pendingSegments()).length) transcriber.start(currentPrefs.whisperModel);
  } catch {
    // No database (private window): meetings simply aren't available.
  }
}

export function App() {
  const [route, setRoute] = useState(() => parse(location.hash));
  const [prefs, setPrefsState] = useState(currentPrefs);
  const [, setVoicesLoaded] = useState(0);

  useEffect(() => {
    const onHash = () => setRoute(parse(location.hash));
    addEventListener('hashchange', onHash);
    void voicesReady().then((list) => setVoicesLoaded(list.length));
    void resumeMeetings();
    return () => removeEventListener('hashchange', onHash);
  }, []);

  useEffect(() => {
    // Leaving a page stops whatever it was saying.
    speaker.stop();
    listener.cancel();
    document.querySelector('main')?.scrollTo({ top: 0 });
  }, [route.page, (route as { id?: string }).id]);

  const services = useMemo<AppServices>(() => ({
    prefs,
    setPrefs: (change) => {
      currentPrefs = { ...currentPrefs, ...change };
      savePrefs(currentPrefs);
      setPrefsState(currentPrefs);
    },
    speaker, listener, progress,
  }), [prefs]);

  const nav = (page: string, label: string, icon: string) => {
    const active = route.page === page || (page === 'scenes' && (route.page === 'scene' || route.page === 'practice' || route.page === 'myScene'))
      || (page === 'meetings' && (route.page === 'meeting' || route.page === 'meetingPractice'));
    return (
      <a class={'nav-item' + (active ? ' active' : '')} href={`#/${page === 'home' ? '' : page}`} aria-current={active ? 'page' : undefined}>
        <span class="nav-icon" aria-hidden="true">{icon}</span>
        <span>{label}</span>
      </a>
    );
  };

  let page;
  switch (route.page) {
    case 'home': page = <Home />; break;
    case 'scenes': page = <Scenes />; break;
    case 'scene': page = <SceneDetail id={route.id} key={route.id} />; break;
    case 'practice':
      page = <Practice key={`${route.id}/${route.mode}/${route.partner}/${route.from}`} id={route.id} mode={route.mode}
                       partner={route.partner} from={route.from} />;
      break;
    case 'vocabulary': page = <Vocabulary />; break;
    case 'myScene': page = <MySceneEditor key={route.editID ?? 'new'} editID={route.editID} />; break;
    case 'meetings': page = <Meetings />; break;
    case 'meeting': page = <MeetingPage id={route.id} key={route.id} />; break;
    case 'meetingPractice': page = <MeetingPractice id={route.id} which={route.which} key={route.id + route.which} />; break;
    case 'settings': page = <Settings />; break;
  }

  return (
    <AppContext.Provider value={services}>
      <div class="shell">
        <nav class="sidebar" aria-label="Sections">
          <div class="brand">
            <span class="brand-mark" aria-hidden="true">話</span>
            <span class="brand-name">Hanaseru</span>
          </div>
          {nav('home', 'Home', '⌂')}
          {nav('scenes', 'Scenes', '💬')}
          {nav('vocabulary', 'Vocabulary', '📖')}
          {nav('meetings', 'Meetings', '⏺')}
          {nav('settings', 'Settings', '⚙')}
          <div class="sidebar-foot">{library.scenarios.length} scenes · {library.vocabulary.length} words</div>
        </nav>
        <main>{page}</main>
      </div>
    </AppContext.Provider>
  );
}
