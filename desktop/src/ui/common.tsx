import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import { glossRomaji, library, WordGloss } from '../content';
import { romajiOf } from '../romaji';

/** Japanese with its reading, romaji (if chosen) and English (if chosen). */
export function JapaneseBlock(props: {
  japanese: string;
  kana: string;
  romaji?: string;
  english?: string;
  showRomaji: boolean;
  showEnglish: boolean;
  large?: boolean;
}) {
  const romaji = props.romaji ?? romajiOf(props.japanese, props.kana);
  return (
    <div class={'jp-block' + (props.large ? ' large' : '')}>
      <div class="jp" lang="ja">{props.japanese}</div>
      {props.kana && props.kana !== props.japanese && <div class="kana" lang="ja">{props.kana}</div>}
      {props.showRomaji && romaji && <div class="romaji">{romaji}</div>}
      {props.showEnglish && props.english && <div class="english">{props.english}</div>}
    </div>
  );
}

export function PageHeader(props: { title: string; subtitle?: string; back?: string; children?: ComponentChildren }) {
  return (
    <header class="page-header">
      {props.back && <a class="back" href={props.back}>‹ Back</a>}
      <div class="page-title-row">
        <div>
          <h1>{props.title}</h1>
          {props.subtitle && <p class="subtitle">{props.subtitle}</p>}
        </div>
        {props.children && <div class="header-actions">{props.children}</div>}
      </div>
    </header>
  );
}

export function Chip(props: { selected: boolean; onClick: () => void; children: ComponentChildren; title?: string }) {
  return (
    <button type="button" class={'chip' + (props.selected ? ' selected' : '')} aria-pressed={props.selected}
            onClick={props.onClick} title={props.title}>
      {props.children}
    </button>
  );
}

/** A line whose words can be looked at one by one. */
export interface WordsLine {
  title: string;
  japanese: string;
  english: string;
  /** The words, when they don't come from the course's word lists (a recorded meeting's lines). */
  words?: WordGloss[];
}

const wordsOf = (line: WordsLine) => line.words ?? library.words(line.japanese);

/** "Words": opens the meaning of every word in the lines. Hidden when none of them has a word list. */
export function WordsButton(props: { lines: WordsLine[]; onSay: (word: string) => void; onOpen?: () => void }) {
  const [open, setOpen] = useState(false);
  const available = props.lines.filter((l) => l.japanese && wordsOf(l).length);
  if (!available.length) return null;
  return (
    <>
      <button type="button" class="button" onClick={() => { props.onOpen?.(); setOpen(true); }}
              title="The meaning of each word">
        <span aria-hidden="true">📘</span> Words
      </button>
      {open && <WordsDialog lines={available} onSay={props.onSay} onClose={() => setOpen(false)} />}
    </>
  );
}

function WordsDialog(props: { lines: WordsLine[]; onSay: (word: string) => void; onClose: () => void }) {
  return (
    <div class="overlay" role="presentation" onClick={props.onClose}>
      <div class="dialog" role="dialog" aria-modal="true" aria-label="Words" onClick={(e) => e.stopPropagation()}
           onKeyDown={(e) => { if (e.key === 'Escape') props.onClose(); }}>
        <div class="dialog-head">
          <h2>Words</h2>
          <button type="button" class="button primary" onClick={props.onClose} autoFocus>Done</button>
        </div>
        <div class="dialog-body">
          {props.lines.map((line) => (
            <section key={line.title + line.japanese} class="words-section">
              <div class="label">{line.title}</div>
              <div class="jp" lang="ja">{line.japanese}</div>
              {line.english && <div class="english">{line.english}</div>}
              <ul class="word-list">
                {wordsOf(line).map((word, index) => (
                  <li key={index}>
                    <button type="button" class="word-row" onClick={() => props.onSay(word.ja)} title="Hear the word">
                      <span class="word-ja">
                        <span lang="ja" class="jp-small">{word.ja}</span>
                        <span class="muted small">{word.kana === word.ja ? glossRomaji(word) : `${word.kana} · ${glossRomaji(word)}`}</span>
                      </span>
                      <span class="word-en">{word.en}</span>
                    </button>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </div>
  );
}
