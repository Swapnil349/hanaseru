#!/usr/bin/env node
// Validates Hanaseru's learning content (Packages/HanaseruKit/Sources/LearningCore/Content).
// Runs on Windows/macOS/Linux with plain Node: `node tools/content-check.mjs`.
// It mirrors the Swift evaluator's normalisation so content problems are caught before a CI build.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.join(here, '..', 'Packages', 'HanaseruKit', 'Sources', 'LearningCore', 'Content');
const load = (name) => JSON.parse(fs.readFileSync(path.join(dir, `${name}.json`), 'utf8'));

const items = load('phrases');
const scenarios = load('scenarios');
const personas = load('personas');
const vocabulary = load('vocabulary');
const cues = load('cues');

const errors = [];
const warnings = [];
const fail = (msg) => errors.push(msg);
const warn = (msg) => warnings.push(msg);

// --- Text helpers (mirror JapaneseText.normalize) ---
const IGNORABLE = new Set([...'、。，．？！?!,.・「」『』（）()〜~…:：;；"\' 　\n\t']);
function normalize(text) {
  let out = '';
  for (const ch of text) {
    let v = ch.codePointAt(0);
    if (v >= 0xff01 && v <= 0xff5e) v -= 0xfee0;
    if (v >= 0x30a1 && v <= 0x30f6) v -= 0x60;
    const c = String.fromCodePoint(v);
    if (!IGNORABLE.has(c)) out += c;
  }
  return out.toLowerCase();
}
const hasJapanese = (t) => [...t].some((ch) => {
  const v = ch.codePointAt(0);
  return (v >= 0x3040 && v <= 0x30ff) || (v >= 0x4e00 && v <= 0x9fff) || (v >= 0x3400 && v <= 0x4dbf);
});
const contains = (t, cands) => {
  const h = normalize(t);
  return h.length > 0 && cands.some((c) => { const n = normalize(c); return n && h.includes(n); });
};
function similarity(a, b) {
  const x = [...normalize(a)], y = [...normalize(b)];
  if (!x.length && !y.length) return 1;
  if (!x.length || !y.length) return 0;
  let prev = [...Array(y.length + 1).keys()], cur = new Array(y.length + 1).fill(0);
  for (let i = 1; i <= x.length; i++) {
    cur[0] = i;
    for (let j = 1; j <= y.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
    [prev, cur] = [cur, prev];
  }
  return 1 - prev[y.length] / Math.max(x.length, y.length);
}
const groups = (g) => (Array.isArray(g) ? g : g.anyOf);
const GENERAL_MISTAKES = [
  { when: [['昨日', 'きのう', '先週', 'せんしゅう', '先月', 'せんげつ', '去年', 'きょねん', 'おととい'], ['ます']], unless: ['ました', 'でした', 'かった', 'から', 'ています', 'ている'] },
  { when: [['しいでした', 'かいでした', 'きいでした', 'さいでした', 'たいでした', 'ついでした', 'むいでした', 'いいでした', 'よいでした', 'くいでした', 'ないでした']], unless: [] },
];
const mistakeMatches = (m, t) => {
  const when = m.when ?? m.whenContainsAll.map(groups);
  const unless = m.unless ?? m.unlessContainsAny ?? [];
  return when.length > 0 && when.every((g) => contains(t, g)) && !contains(t, unless);
};

// --- Shared checks ---
function words(text) { return text.replace(/「[^」]*」/g, 'X').trim().split(/\s+/).filter(Boolean).length; }
function checkNote(where, note) {
  if (note == null) return;
  if (words(note) > 12) fail(`${where}: note has more than 12 words: ${note}`);
  if (hasJapanese(note.replace(/「[^」]*」/g, ''))) fail(`${where}: Japanese outside 「」 in note: ${note}`);
}
function chunkPair(c) { return typeof c === 'string' ? { ja: c, kana: c } : c; }
function checkChunks(where, japanese, kana, chunks, { required = false } = {}) {
  if (!chunks) { if (required) warn(`${where}: no chunks (the chunker fallback will be used)`); return; }
  if (!Array.isArray(chunks) || chunks.length === 0) return fail(`${where}: chunks must be a non-empty array`);
  const pairs = chunks.map(chunkPair);
  if (pairs.some((p) => !p.ja || !p.kana)) return fail(`${where}: every chunk needs ja and kana`);
  const ja = pairs.map((p) => p.ja).join('');
  const kn = pairs.map((p) => p.kana).join('');
  if (normalize(ja) !== normalize(japanese)) fail(`${where}: chunks join to 「${ja}」, expected 「${japanese}」`);
  if (kana && normalize(kn) !== normalize(kana)) fail(`${where}: chunk kana join to 「${kn}」, expected 「${kana}」`);
}
function checkModelLine(where, line, opts = {}) {
  if (!line.japanese) return fail(`${where}: missing japanese`);
  if (!line.kana) fail(`${where}: missing kana`);
  if (!line.english) fail(`${where}: missing english`);
  if (line.kana && hasJapanese(line.kana) && /[一-鿿]/.test(line.kana.replace(/\{name\}/g, ''))) fail(`${where}: kana contains kanji: ${line.kana}`);
  checkChunks(where, line.japanese, line.kana, line.chunks, opts);
  checkNote(`${where}.noteEn`, line.noteEn);
  if (line.level != null && !(line.level >= 1 && line.level <= 8)) fail(`${where}: level out of range`);
}

// --- Personas ---
const personaIDs = new Set(personas.map((p) => p.id));
for (const p of personas) {
  if (p.voiceGender != null && !['male', 'female'].includes(p.voiceGender)) fail(`${p.id}: voiceGender must be male or female`);
}

// --- Scenarios ---
const termIDs = new Set(vocabulary.map((v) => v.id));
const itemIDs = new Set(items.map((i) => i.id));
const scenarioIDs = new Set(scenarios.map((s) => s.id));
for (const s of scenarios) {
  if (!personaIDs.has(s.personaID)) fail(`${s.id}: unknown persona ${s.personaID}`);
  for (const t of s.targetTerms ?? []) if (!termIDs.has(t)) fail(`${s.id}: unknown term ${t}`);
  const beatIDs = s.beats.map((b, i) => b.id ?? `b${i + 1}`);
  if (new Set(beatIDs).size !== beatIDs.length) fail(`${s.id}: beat ids are not unique: ${beatIDs.join(', ')}`);
  if (s.beats.some((b) => !b.id)) warn(`${s.id}: some beats have no id`);
  for (const m of s.missionsEn ?? []) {
    if (!m.text) fail(`${s.id}: mission without text`);
    for (const id of m.beatIDs ?? []) if (!beatIDs.includes(id)) fail(`${s.id}: mission refers to unknown beat ${id}`);
  }
  if (s.unlocksScenarioID && !scenarioIDs.has(s.unlocksScenarioID)) warn(`${s.id}: unlocksScenarioID ${s.unlocksScenarioID} not found (future content)`);
  s.beats.forEach((b, i) => {
    const where = `${s.id}#${beatIDs[i]}`;
    if (!s.roleReversal || i > 0) {
      if (!b.line) fail(`${where}: empty partner line`);
    }
    if (b.line) checkChunks(`${where}.lineChunks`, b.line, b.kana, b.lineChunks);
    const responses = b.responses ?? (b.exampleResponses ?? []).map((j) => ({ japanese: j }));
    if (responses.length === 0) fail(`${where}: no responses`);
    responses.forEach((r, k) => checkModelLine(`${where}.responses[${k}]`, r, { required: k === 0 }));
    for (const r of responses) {
      const text = r.japanese.replace(/\{name\}/g, 'スワプニル');
      if (GENERAL_MISTAKES.some((m) => mistakeMatches(m, text))) fail(`${where}: model answer 「${r.japanese}」 trips a general mistake pattern`);
    }
    if (b.partnerItemID && !itemIDs.has(b.partnerItemID)) fail(`${where}: unknown partnerItemID ${b.partnerItemID}`);
    const choice = b.lineVariants?.choice;
    if (choice) {
      checkModelLine(`${where}.lineVariants.choice`, choice);
      const answerBits = (responses[0]?.chunks ?? []).map(chunkPair).map((c) => c.ja).filter((c) => normalize(c).length >= 2);
      const keys = (b.keyTerms ?? []).flatMap(groups);
      if (!contains(choice.japanese, [...keys, ...answerBits])) warn(`${where}: choice variant shares no answer word with responses[0]`);
    }
    if (b.lineVariants?.open) checkModelLine(`${where}.lineVariants.open`, b.lineVariants.open);
  });
}

// --- Items ---
for (const it of items) {
  const where = it.id;
  checkModelLine(where, it, { required: true });
  if (!it.situationEn && it.promptEn) warn(`${where}: no situationEn`);
  if (it.partner) {
    if (!it.partner.japanese || !it.partner.english) fail(`${where}: partner needs japanese and english`);
    if (it.partner.personaID && !personaIDs.has(it.partner.personaID)) fail(`${where}: unknown partner persona ${it.partner.personaID}`);
  }
  for (const t of it.terms ?? []) if (!termIDs.has(t)) fail(`${where}: unknown term ${t}`);
  for (const m of it.commonMistakes ?? []) checkNote(`${where}.${m.id}.spokenEn`, m.spokenEn);
  // Every taught line must evaluate as natural against itself.
  const refs = [it.japanese, ...(it.acceptableResponses ?? []), it.kana].filter(Boolean);
  const mistakes = [...(it.commonMistakes ?? []), ...GENERAL_MISTAKES];
  if (mistakes.some((m) => mistakeMatches(m, it.japanese))) fail(`${where}: its own sentence trips a mistake pattern`);
  if (Math.max(...refs.map((r) => similarity(it.japanese, r))) < 0.88) fail(`${where}: its own sentence is not natural against references`);
  const l = it.listening;
  if (l) {
    if (!l.modelAnswerEn || !l.modelAnswerKana) fail(`${where}: listening model answer needs kana and English`);
    if (!contains(l.modelAnswer, l.answerTerms.flatMap(groups))) fail(`${where}: listening model answer fails its own check`);
    if (l.choiceQuestionJa && !l.choiceQuestionEn) fail(`${where}: choice question needs English`);
  }
}

// --- Cues ---
const PLACEHOLDERS = new Set(['english', 'intent', 'name', 'nameJa', 'title', 'canDo', 'place', 'n', 'k', 'minutes', 'agenda', 'topic']);
for (const [key, cue] of Object.entries(cues)) {
  if (!cue.ja || !cue.en) fail(`cue ${key}: needs ja and en`);
  for (const m of `${cue.en} ${cue.ja}`.matchAll(/\{(\w+)\}/g)) if (!PLACEHOLDERS.has(m[1])) fail(`cue ${key}: unknown placeholder {${m[1]}}`);
}

for (const w of warnings) console.log(`warning: ${w}`);
for (const e of errors) console.log(`ERROR: ${e}`);
console.log(`\n${items.length} items, ${scenarios.length} scenarios, ${scenarios.reduce((n, s) => n + s.beats.length, 0)} beats, ${Object.keys(cues).length} cues — ${errors.length} errors, ${warnings.length} warnings`);
process.exit(errors.length ? 1 : 0);
