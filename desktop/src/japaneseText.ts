// Comparing what the learner said (as transcribed) with the Japanese expected — the same rules as the phone apps:
// punctuation, spaces, full-width letters and katakana/hiragana never count as differences.

const IGNORABLE = new Set([...'、。，．？！?!,.・「」『』（）()〜~…:：;；"\' 　\n\t']);

export function normalize(text: string): string {
  let out = '';
  for (const character of text) {
    let code = character.codePointAt(0) ?? 0;
    if (code >= 0xff01 && code <= 0xff5e) code -= 0xfee0;
    if (code >= 0x30a1 && code <= 0x30f6) code -= 0x60;
    const folded = String.fromCodePoint(code);
    if (!IGNORABLE.has(folded)) out += folded;
  }
  return out.toLowerCase();
}

/** Character-level similarity in 0…1 (1 − normalised Levenshtein distance). */
export function similarity(a: string, b: string): number {
  const x = [...normalize(a)];
  const y = [...normalize(b)];
  if (!x.length && !y.length) return 1;
  if (!x.length || !y.length) return 0;
  let previous = Array.from({ length: y.length + 1 }, (_, i) => i);
  let current = new Array<number>(y.length + 1).fill(0);
  for (let i = 1; i <= x.length; i++) {
    current[0] = i;
    for (let j = 1; j <= y.length; j++) {
      const cost = x[i - 1] === y[j - 1] ? 0 : 1;
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost);
    }
    [previous, current] = [current, previous];
  }
  return 1 - previous[y.length] / Math.max(x.length, y.length);
}

export function bestSimilarity(text: string, references: string[]): number {
  return references.reduce((best, reference) => Math.max(best, similarity(text, reference)), 0);
}
