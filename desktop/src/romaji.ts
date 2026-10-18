// Japanese written in English letters — modified Hepburn with long vowels marked, as in the course content:
// 「いいえ、特に問題はありません。」 → "Iie, toku ni mondai wa arimasen." (The same rules as the iPhone app.)

/** Splits Japanese text into words (the browser's word breaker). */
let splitter: ((text: string) => string[]) | null = (() => {
  try {
    const segmenter = new Intl.Segmenter('ja', { granularity: 'word' });
    return (text: string) => [...segmenter.segment(text)].map((s) => s.segment);
  } catch {
    return null;
  }
})();

/** For tests: use another word breaker, or none. */
export function setWordSplitter(next: ((text: string) => string[]) | null) {
  splitter = next;
  cache.clear();
}

const cache = new Map<string, string>();

/**
 * A sentence in romaji, split into words, with particles as they're said (は → wa, へ → e, を → o).
 * `kana` is the reading of `japanese`; it can be empty when `japanese` is all kana. Returns "" when there is no
 * reading (kanji without kana).
 */
export function romajiOf(japanese: string, kana: string): string {
  const key = `${japanese}|${kana}`;
  const known = cache.get(key);
  if (known !== undefined) return known;
  const result = make(japanese, kana);
  cache.set(key, result);
  return result;
}

function make(japanese: string, kana: string): string {
  const reading = kana || japanese;
  if (!reading || [...reading].some(isKanji)) return '';
  return sentence(words(japanese || reading, reading));
}

interface Piece {
  kana: string;
  surface: string;
}

export function words(japanese: string, kana: string): string[] {
  if (splitter) {
    const aligned = alignedWords(splitter(japanese), kana);
    if (aligned) return glue(aligned);
  }
  return glue(fallbackWords(kana).map((w) => ({ kana: w, surface: w })));
}

/** Without a word breaker, words end at punctuation. */
function fallbackWords(kana: string): string[] {
  const result: string[] = [];
  let current = '';
  for (const character of kana) {
    if (isPunctuation(character) || character === ' ' || character === '　') {
      if (current) result.push(current);
      current = '';
      if (character !== ' ' && character !== '　') result.push(character);
    } else {
      current += character;
    }
  }
  if (current) result.push(current);
  return result;
}

/**
 * Words of `kana`, at the word boundaries found in the Japanese. Kana, punctuation and letters appear as they are
 * in the reading; kanji words take the reading up to the next of those. Null when the two can't be lined up.
 */
function alignedWords(tokens: string[], kana: string): Piece[] | null {
  const parts = tokens.flatMap((token) => {
    const trimmed = token.trim();
    if (!trimmed) return [];
    const characters = [...trimmed];
    if (characters.length > 1 && characters.every(isPunctuation)) return characters;
    return [trimmed];
  });
  if (parts.length === 0) return null;
  const reading = [...kana];
  const plain = reading.map(toHiragana);
  let position = 0;
  const result: Piece[] = [];

  const skipSpaces = () => {
    while (position < reading.length && (reading[position] === ' ' || reading[position] === '　')) position++;
  };
  const matches = (text: string, at: number) => {
    const wanted = [...text].map(toHiragana);
    if (wanted.length === 0 || at + wanted.length > plain.length) return false;
    return wanted.every((c, i) => plain[at + i] === c);
  };
  const find = (text: string, from: number): number | null => {
    for (let index = from; index < plain.length; index++) if (matches(text, index)) return index;
    return null;
  };
  const slice = (start: number, end: number) => reading.slice(start, end).join('');

  let index = 0;
  while (index < parts.length) {
    skipSpaces();
    const part = parts[index];
    const characters = [...part];
    if (!characters.some(isKanji)) {
      if (!matches(part, position)) return null;
      result.push({ kana: slice(position, position + characters.length), surface: part });
      position += characters.length;
      index++;
      continue;
    }
    // A word ending in kana (特に, 近く) ends where that kana is in the reading.
    let trailingStart = characters.length;
    while (trailingStart > 0 && !isKanji(characters[trailingStart - 1])) trailingStart--;
    const trailing = characters.slice(trailingStart).join('');
    if (trailing) {
      const found = find(trailing, position + 1);
      if (found !== null) {
        const end = found + [...trailing].length;
        result.push({ kana: slice(position, end), surface: part });
        position = end;
        index++;
        continue;
      }
    }
    let next = index + 1;
    while (next < parts.length && [...parts[next]].some(isKanji)) next++;
    let end: number;
    if (next < parts.length) {
      const found = find(parts[next], position + 1);
      if (found === null) return null;
      end = found;
    } else {
      end = reading.length;
    }
    if (end <= position) return null;
    result.push({ kana: slice(position, end), surface: parts.slice(index, next).join('') });
    position = end;
    index = next;
  }
  skipSpaces();
  if (position < reading.length) {
    const rest = slice(position, reading.length);
    result.push({ kana: rest, surface: rest });
  }
  return result;
}

/** Endings written together with the word before them (ari-masen, okut-te, tanoshikat-ta). */
const ENDINGS = new Set([
  'ます', 'まし', 'ませ', 'ましょ', 'ましょう', 'ん', 'た', 'て', 'ない', 'なかっ', 'なく', 'なけれ',
  'たい', 'たく', 'たかっ', 'う', 'よう', 'れ', 'られ', 'せ', 'させ', 'ば', 'ちゃ', 'ちゃう', 'たら', 'たり',
  'ず', 'ぬ',
]);

const hira = (text: string) => [...text].map(toHiragana).join('');

/** Joins endings to their word, and the polite prefixes お／ご to the word after them. */
function glue(pieces: Piece[]): string[] {
  const result: Piece[] = [];
  let prefix = null as Piece | null;
  for (const piece of pieces) {
    const plain = hira(piece.kana);
    if (plain === 'お' || plain === 'ご') {
      prefix = { kana: (prefix?.kana ?? '') + piece.kana, surface: (prefix?.surface ?? '') + piece.surface };
      continue;
    }
    const joined: Piece = { kana: (prefix?.kana ?? '') + piece.kana, surface: (prefix?.surface ?? '') + piece.surface };
    prefix = null;
    const last = result[result.length - 1];
    if (last && !isPunctuationWord(last.kana)) {
      const lastPlain = hira(last.kana);
      // で／だ after a verb stem ending in ん is the verb's ending (住んで); otherwise a particle.
      const verbalDe = (plain === 'で' || plain === 'だ') && last.surface.endsWith('ん') && [...last.surface].some(isKanji);
      if (ENDINGS.has(plain) || verbalDe || lastPlain.endsWith('っ')) {
        result[result.length - 1] = { kana: last.kana + joined.kana, surface: last.surface + joined.surface };
        continue;
      }
    }
    result.push(joined);
  }
  if (prefix) result.push(prefix);
  return result.map((p) => p.kana);
}

function sentence(list: string[]): string {
  let output = '';
  let capitalize = true;
  let quoteOpen = false;
  for (const word of list) {
    if (isPunctuationWord(word)) {
      const mark = punctuation(word);
      if (mark === '"') {
        if (!quoteOpen && output && !output.endsWith(' ')) output += ' ';
        output += '"';
        quoteOpen = !quoteOpen;
      } else if (mark === '(') {
        if (output && !output.endsWith(' ')) output += ' ';
        output += '(';
      } else {
        output += mark;
      }
      if (mark === '.' || mark === '?' || mark === '!') capitalize = true;
      continue;
    }
    let text = romanize(word);
    if (!text) continue;
    if (capitalize) {
      text = text[0].toUpperCase() + text.slice(1);
      capitalize = false;
    }
    const opening = output.endsWith('(') || (quoteOpen && output.endsWith('"'));
    if (output && !output.endsWith(' ') && !opening) output += ' ';
    output += text;
  }
  return output.trim();
}

/** One word, with particles as said, including a は that ends a word (では, 実は). */
export function romanize(word: string): string {
  const plain = hira(word);
  const characters = [...word];
  if (plain === 'は') return 'wa';
  if (plain === 'へ') return 'e';
  if (plain === 'を') return 'o';
  if ([...plain].length > 1 && plain.endsWith('は') && isHiragana(characters[characters.length - 1])) {
    return fromKana(characters.slice(0, -1).join('')) + 'wa';
  }
  return fromKana(word);
}

/** Kana to romaji, with no word splitting: 「しんかんせん」 → "shinkansen", 「きょう」 → "kyō". */
export function fromKana(kana: string): string {
  const syllables: string[] = [];
  const characters = [...kana].map(toHiragana);
  let index = 0;
  let doubleNext = false;
  while (index < characters.length) {
    const character = characters[index];
    if (character === 'っ') {
      doubleNext = true;
      index++;
      continue;
    }
    if (character === 'ー') {
      if (syllables.length) syllables[syllables.length - 1] = lengthened(syllables[syllables.length - 1]);
      index++;
      continue;
    }
    let syllable = BASE[character];
    if (syllable === undefined) {
      // Not kana: letters, digits and anything else pass through.
      syllables.push(halfWidth(character));
      doubleNext = false;
      index++;
      continue;
    }
    // Digraphs: きゃ → kya, しゃ → sha, ふぁ → fa, てぃ → ti.
    const small = index + 1 < characters.length ? SMALL[characters[index + 1]] : undefined;
    if (small !== undefined) {
      syllable = combine(syllable, small);
      index++;
    }
    if (doubleNext) {
      syllable = (syllable.startsWith('ch') ? 't' : syllable[0]) + syllable;
      doubleNext = false;
    }
    // Long vowels: おう and おお → ō, うう → ū.
    const last = syllables[syllables.length - 1];
    if (last !== undefined && isLongVowel(syllable, last)) {
      syllables[syllables.length - 1] = lengthened(last);
      index++;
      continue;
    }
    syllables.push(syllable);
    index++;
  }
  // ん before a vowel or y is written n' (kon'ya, gen'in).
  let output = '';
  syllables.forEach((syllable, position) => {
    output += syllable;
    const next = syllables[position + 1]?.[0];
    if (syllable === 'n' && next !== undefined && 'aeiouyāēīōū'.includes(next)) output += "'";
  });
  return output;
}

function isLongVowel(syllable: string, last: string): boolean {
  if (syllable === 'u') return last.endsWith('o') || last.endsWith('u');
  if (syllable === 'o') return last.endsWith('o');
  return false;
}

const MACRONS: Record<string, string> = { a: 'ā', i: 'ī', u: 'ū', e: 'ē', o: 'ō' };

function lengthened(syllable: string): string {
  const long = MACRONS[syllable[syllable.length - 1]];
  return long ? syllable.slice(0, -1) + long : syllable;
}

function combine(syllable: string, small: string): string {
  if (small.startsWith('y')) {
    // し, ち and じ drop their i (sha, cha, ja); others keep a y (kya, nyu, ryo).
    if (syllable === 'shi' || syllable === 'chi' || syllable === 'ji') return syllable.slice(0, -1) + small.slice(1);
    if (syllable.endsWith('i')) return syllable.slice(0, -1) + small;
    return syllable + small;
  }
  if (syllable === 'u') return 'w' + small;
  const last = syllable[syllable.length - 1];
  if (last === undefined) return small;
  return 'aiueo'.includes(last) ? syllable.slice(0, -1) + small : syllable + small;
}

const SMALL: Record<string, string> = {
  'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo', 'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o', 'ゎ': 'wa',
};

const BASE: Record<string, string> = {
  'あ': 'a', 'い': 'i', 'う': 'u', 'え': 'e', 'お': 'o',
  'か': 'ka', 'き': 'ki', 'く': 'ku', 'け': 'ke', 'こ': 'ko',
  'が': 'ga', 'ぎ': 'gi', 'ぐ': 'gu', 'げ': 'ge', 'ご': 'go',
  'さ': 'sa', 'し': 'shi', 'す': 'su', 'せ': 'se', 'そ': 'so',
  'ざ': 'za', 'じ': 'ji', 'ず': 'zu', 'ぜ': 'ze', 'ぞ': 'zo',
  'た': 'ta', 'ち': 'chi', 'つ': 'tsu', 'て': 'te', 'と': 'to',
  'だ': 'da', 'ぢ': 'ji', 'づ': 'zu', 'で': 'de', 'ど': 'do',
  'な': 'na', 'に': 'ni', 'ぬ': 'nu', 'ね': 'ne', 'の': 'no',
  'は': 'ha', 'ひ': 'hi', 'ふ': 'fu', 'へ': 'he', 'ほ': 'ho',
  'ば': 'ba', 'び': 'bi', 'ぶ': 'bu', 'べ': 'be', 'ぼ': 'bo',
  'ぱ': 'pa', 'ぴ': 'pi', 'ぷ': 'pu', 'ぺ': 'pe', 'ぽ': 'po',
  'ま': 'ma', 'み': 'mi', 'む': 'mu', 'め': 'me', 'も': 'mo',
  'や': 'ya', 'ゆ': 'yu', 'よ': 'yo',
  'ら': 'ra', 'り': 'ri', 'る': 'ru', 'れ': 're', 'ろ': 'ro',
  'わ': 'wa', 'ゐ': 'i', 'ゑ': 'e', 'を': 'o', 'ん': 'n', 'ゔ': 'vu',
  'ぁ': 'a', 'ぃ': 'i', 'ぅ': 'u', 'ぇ': 'e', 'ぉ': 'o', 'ゃ': 'ya', 'ゅ': 'yu', 'ょ': 'yo', 'ゎ': 'wa',
};

export function toHiragana(character: string): string {
  const code = character.codePointAt(0) ?? 0;
  return code >= 0x30a1 && code <= 0x30f6 ? String.fromCodePoint(code - 0x60) : character;
}

export function isHiragana(character: string | undefined): boolean {
  if (!character) return false;
  const code = character.codePointAt(0) ?? 0;
  return code >= 0x3041 && code <= 0x309f;
}

export function isKanji(character: string): boolean {
  const code = character.codePointAt(0) ?? 0;
  return (code >= 0x4e00 && code <= 0x9fff) || (code >= 0x3400 && code <= 0x4dbf) || character === '々';
}

const PUNCTUATION = '、。，．,.？?！!・「」『』（）()…〜~：:';

function isPunctuation(character: string): boolean {
  return PUNCTUATION.includes(character);
}

function isPunctuationWord(word: string): boolean {
  return [...word].length === 1 && isPunctuation(word);
}

function punctuation(character: string): string {
  switch (character) {
    case '、': case '，': case ',': case '・': return ',';
    case '。': case '．': case '.': return '.';
    case '？': case '?': return '?';
    case '！': case '!': return '!';
    case '「': case '」': case '『': case '』': return '"';
    case '（': case '(': return '(';
    case '）': case ')': return ')';
    case '…': return '...';
    case '〜': case '~': return '~';
    case '：': case ':': return ':';
    default: return character;
  }
}

/** Full-width letters and digits as ordinary ones. */
function halfWidth(character: string): string {
  const code = character.codePointAt(0) ?? 0;
  return code >= 0xff01 && code <= 0xff5e ? String.fromCodePoint(code - 0xfee0) : character;
}
