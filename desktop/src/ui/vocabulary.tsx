import { useMemo, useState } from 'preact/hooks';
import { library } from '../content';
import { romajiOf } from '../romaji';
import { useApp } from './app';
import { PageHeader } from './common';

const CATEGORY_TITLES: Record<string, string> = {
  railway: 'Railway', civil: 'Civil engineering', safety: 'Safety', quality: 'Quality', meetings: 'Meetings',
  projectManagement: 'Project management', everyday: 'Everyday', finance: 'Finance',
};

/** Every word in the course, searchable in Japanese, kana, romaji or English. Click a word to hear it. */
export function Vocabulary() {
  const { speaker } = useApp();
  const [query, setQuery] = useState('');
  const [category, setCategory] = useState('');
  const categories = useMemo(() => [...new Set(library.vocabulary.flatMap((t) => t.categories))], []);
  const needle = query.trim().toLowerCase();
  const terms = library.vocabulary.filter((term) => {
    if (category && !term.categories.includes(category)) return false;
    if (!needle) return true;
    const romaji = (term.romaji || romajiOf(term.japanese, term.kana)).toLowerCase();
    const plain = romaji.normalize('NFD').replace(/[̀-ͯ]/g, '');
    return term.japanese.includes(query.trim()) || term.kana.includes(query.trim()) || romaji.includes(needle)
      || plain.includes(needle) || term.english.toLowerCase().includes(needle);
  });

  return (
    <div class="page">
      <PageHeader title="My vocabulary" subtitle={`${library.vocabulary.length} words in the course. Click a word to hear it.`} />
      <div class="toolbar">
        <input class="search" type="search" placeholder="Search Japanese, romaji or English" value={query}
               onInput={(e) => setQuery((e.target as HTMLInputElement).value)} aria-label="Search words" />
        <select value={category} onChange={(e) => setCategory((e.target as HTMLSelectElement).value)} aria-label="Category">
          <option value="">All topics</option>
          {categories.map((c) => <option key={c} value={c}>{CATEGORY_TITLES[c] ?? c}</option>)}
        </select>
      </div>
      <p class="muted small">{terms.length} words</p>
      <ul class="word-table">
        {terms.map((term) => (
          <li key={term.id}>
            <button type="button" class="word-row" onClick={() => void speaker.speak(term.japanese, 'coach', 0.9)}>
              <span class="word-ja">
                <span lang="ja" class="jp-small">{term.japanese}</span>
                <span class="muted small">
                  {term.kana !== term.japanese ? `${term.kana} · ` : ''}{term.romaji || romajiOf(term.japanese, term.kana)}
                </span>
              </span>
              <span class="word-en">{term.english}{term.note && <span class="muted small block">{term.note}</span>}</span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
