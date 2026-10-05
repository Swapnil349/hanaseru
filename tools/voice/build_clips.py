#!/usr/bin/env python3
"""Pre-records the coach's English with a neural voice (Kokoro, Apache-2.0), so the app speaks natural
English instead of the robotic iOS voice.

Every English sentence the session can say is known in advance: coach cues, and the meanings, cues,
intents, notes and partner glosses in the content. This script lists them exactly as the app will ask
for them (same clean-up and splitting as JapaneseText.speakableEnglish / bilingualSegments and
NaturalEnglishVoice in the app), records each once, and writes an index the app looks clips up in.

  python tools/voice/build_clips.py --list          # just count and show the sentences
  python tools/voice/build_clips.py <output folder> # record (needs: pip install kokoro soundfile; ffmpeg)

Existing clips are kept (file names are content hashes), so re-runs only record what changed.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CONTENT = os.path.join(ROOT, "Packages", "HanaseruKit", "Sources", "LearningCore", "Content")
VOICE = "af_heart"  # Kokoro's most natural English voice
SPEED = 0.95
INDEX_NAME = "english-voice-index.json"

PLACEHOLDER = re.compile(r"\{(\w+)\}")


# --- Mirrors of the app's text handling -------------------------------------------------------------

def speakable(text):
    """JapaneseText.speakableEnglish"""
    spoken = re.sub(r"\s+/\s+", " or ", text)
    spoken = re.sub(r"\s*\(\s*", ", ", spoken)
    spoken = re.sub(r"\s*\)", "", spoken)
    spoken = re.sub(r"([.?!:]),\s", r"\1 ", spoken)
    spoken = re.sub(r"^,\s*", "", spoken)
    spoken = re.sub(r"\s{2,}", " ", spoken)
    trimmed = spoken.strip(" ")
    return trimmed or text


def english_segments(text):
    """The English parts of JapaneseText.bilingualSegments (text inside 「」 is Japanese)."""
    parts, current, japanese = [], "", False
    def flush():
        trimmed = current.strip(" ")
        if not japanese and any(ch.isalnum() for ch in trimmed):
            parts.append(trimmed)
    for ch in text:
        if ch == "「":
            flush(); current = ""; japanese = True
        elif ch == "」":
            flush(); current = ""; japanese = False
        else:
            current += ch
    flush()
    return parts


def key(text):
    """NaturalEnglishVoice.key"""
    t = text.lower().replace("’", "'")
    t = re.sub(r"\s+", " ", t)
    return t.strip(" .!?:,;…—-\"")


# --- What the app can say -----------------------------------------------------------------------------

def load(name):
    with open(os.path.join(CONTENT, name), encoding="utf-8") as f:
        return json.load(f)


def content_strings():
    """Every English string in phrases and scenarios (meanings, cues, intents, notes, glosses, titles)."""
    found = []
    def walk(node, parent_key=""):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, k)
        elif isinstance(node, list):
            for v in node:
                walk(v, parent_key)
        elif isinstance(node, str):
            if parent_key in ("english", "title", "closingEnglish") or parent_key.endswith("En"):
                if re.search(r"[A-Za-z]", node):
                    found.append(node)
    walk(load("phrases.json"))
    walk(load("scenarios.json"))
    return found


def main():
    cues = load("cues.json")
    personas = load("personas.json")
    personas = personas if isinstance(personas, list) else personas.get("personas", [])
    scenarios = load("scenarios.json")
    scenarios = scenarios if isinstance(scenarios, list) else scenarios.get("scenarios", [])
    names = [p.get("nameEn", "") for p in personas if p.get("nameEn")] + ["a senior colleague"]
    titles = [s.get("title", "") for s in scenarios if s.get("title")]

    sentences = []  # texts as the app would hand them to the English voice
    def say(text):
        for segment in english_segments(speakable(text)):
            # Japanese outside 「」 is never sent to the English voice by the app.
            if not re.search(r"[぀-ヿ一-鿿]", segment):
                sentences.append(segment)

    # Content: the whole string, plus "Say:"/"Ask:" heads and tails are added through the cues below.
    for text in content_strings():
        say(text)

    # Coach cues. A placeholder in the middle gets every value; a trailing one is split off, because the
    # app looks up "Say:" and the meaning as two recordings.
    for name, cue in cues.items():
        en = cue["en"]
        fields = PLACEHOLDER.findall(en)
        if not fields:
            say(en)
            continue
        head = en[: en.index("{")].strip()
        if fields in (["name"],):
            for value in names:
                say(en.replace("{name}", value))
        elif name == "part":
            for k in range(2, 13):
                for n in range(1, k + 1):
                    say(f"Part {n} of {k}:")
        elif head:
            say(head)

    # Fixed English the session builds in code.
    for text in ["Then I'll ask:", "Like:", "Your move:", "Could you say that again, please?", "Slowly, please.",
                 "It's in the past, so end with 「ました」, not 「ます」.", "For the past, say 「かったです」, not 「いでした」."]:
        say(text)
    # Parts and the agenda ("Today: 3 phrases, a listening check and a scene, …").
    atoms = ["a listening check", "a phrase", "say it with me", "one line to say with me"]
    atoms += [f"{n} phrases" for n in range(2, 13)] + [f"{n} listening checks" for n in range(2, 7)]
    atoms += [f"{n} lines to say with me" for n in range(2, 7)]
    atoms += [f"a scene, {t}" for t in titles] + titles
    for atom in atoms:
        say(atom)

    unique = {}
    for text in sentences:
        k = key(text)
        if k and k not in unique:
            unique[k] = text
    return unique


def record(unique, out):
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline

    os.makedirs(out, exist_ok=True)
    pipeline = KPipeline(lang_code="a")
    index, made = {}, 0
    for k, text in sorted(unique.items()):
        name = hashlib.sha1(f"{VOICE}|{SPEED}|{text}".encode("utf-8")).hexdigest()[:20] + ".m4a"
        path = os.path.join(out, name)
        if not os.path.exists(path):
            chunks = [audio for _, _, audio in pipeline(text, voice=VOICE, speed=SPEED)]
            if not chunks:
                continue
            audio = np.concatenate([np.asarray(c, dtype=np.float32) for c in chunks])
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as wav:
                sf.write(wav.name, audio, 24000)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", wav.name, "-ac", "1", "-c:a", "aac",
                            "-b:a", "48k", path], check=True)
            os.unlink(wav.name)
            made += 1
        index[k] = name
    # Forget recordings of sentences the app no longer says.
    keep = set(index.values()) | {INDEX_NAME}
    for file in os.listdir(out):
        if file not in keep:
            os.unlink(os.path.join(out, file))
    with open(os.path.join(out, INDEX_NAME), "w", encoding="utf-8") as f:
        json.dump({"voice": f"Kokoro {VOICE}", "clips": index}, f, ensure_ascii=False, indent=0, sort_keys=True)
    print(f"{len(index)} sentences, {made} newly recorded")


if __name__ == "__main__":
    sentences = main()
    if len(sys.argv) > 1 and sys.argv[1] != "--list":
        record(sentences, sys.argv[1])
    else:
        print(len(sentences), "sentences")
        for k in list(sentences)[:40]:
            print("  ", sentences[k])
