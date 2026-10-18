import { describe, expect, it } from 'vitest';
import { fromKana, romajiOf, romanize, setWordSplitter } from '../src/romaji';

// The same expectations as the iPhone and Android apps.
describe('romaji', () => {
  it('reads kana', () => {
    const cases: Record<string, string> = {
      'しんかんせん': 'shinkansen', 'きょう': 'kyō', 'がっこう': 'gakkō', 'まっちゃ': 'matcha', 'こんや': "kon'ya",
      'げんいん': "gen'in", 'コーヒー': 'kōhī', 'ちゅうい': 'chūi', 'おおきい': 'ōkii', 'しゃしん': 'shashin',
      'じゅんちょう': 'junchō', 'ありがとう': 'arigatō', 'ファイル': 'fairu',
    };
    for (const [kana, expected] of Object.entries(cases)) expect(fromKana(kana), kana).toBe(expected);
  });

  it('writes particles as they are said', () => {
    expect(romanize('は')).toBe('wa');
    expect(romanize('を')).toBe('o');
    expect(romanize('へ')).toBe('e');
    expect(romanize('では')).toBe('dewa');
    expect(romanize('はい')).toBe('hai');
  });

  it('lines words up with the kana', () => {
    setWordSplitter(() => ['いいえ', '、', '特に', '問題', 'は', 'ありません', '。']);
    expect(romajiOf('いいえ、特に問題はありません。', 'いいえ、とくにもんだいはありません。')).toBe('Iie, tokuni mondai wa arimasen.');
    setWordSplitter(null);
    expect(romajiOf('はい、そうです。', 'はい、そうです。')).toBe('Hai, sōdesu.');
  });

  it('gives nothing for kanji without a reading', () => {
    expect(romajiOf('問題', '')).toBe('');
  });
});
