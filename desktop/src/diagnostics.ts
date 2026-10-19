// A small log of what the voice did (silences caught, retries, recognition errors), so a session that went quiet
// can be explained afterwards. It never contains what you said, only timings and what the app tried. Settings ›
// Diagnostics copies it.

const KEY = 'voiceLog';
const MAX = 400;

let lines: string[] = (() => {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? '[]') as string[];
  } catch {
    return [];
  }
})();
let saveTimer: ReturnType<typeof setTimeout> | null = null;

export function voiceLog(message: string) {
  const time = new Date().toISOString().replace('T', ' ').slice(5, 23);
  lines.push(`${time}  ${message}`);
  if (lines.length > MAX) lines = lines.slice(-MAX);
  saveTimer ??= setTimeout(() => {
    saveTimer = null;
    try {
      localStorage.setItem(KEY, JSON.stringify(lines));
    } catch {
      // Storage full or unavailable: the log is only a help.
    }
  }, 1000);
}

export function voiceLogText(): string {
  return lines.join('\n');
}
