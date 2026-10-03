#!/usr/bin/env python3
"""Turn compiler errors and test failures in a build log into GitHub annotations.

Annotations show on the public run page without signing in, so build problems can be
diagnosed from anywhere. Usage: annotate.py <log file> <title>
"""
import os
import re
import sys

MAX_ANNOTATIONS = 10

COMPILER = re.compile(r"^(?P<file>/\S+?\.swift):(?P<line>\d+):(?:(?P<col>\d+):)?\s*(?:fatal )?error:\s*(?P<msg>.+)$")
SWIFT_TESTING = re.compile(r"✘ Test (?P<name>.+?) recorded an issue at (?P<file>\S+?\.swift):(?P<line>\d+):(?P<col>\d+):\s*(?P<msg>.+)$")
GENERIC = re.compile(r"(error:|\*\* (BUILD|TEST|ARCHIVE) FAILED \*\*|Testing failed|✘ )")


def escape(text: str) -> str:
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main() -> int:
    path, title = sys.argv[1], sys.argv[2]
    if not os.path.exists(path):
        return 0
    root = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    seen, emitted = set(), 0
    for raw in lines:
        line = raw.strip()
        match = COMPILER.match(line) or SWIFT_TESTING.search(line)
        if not match:
            continue
        file = match.group("file")
        rel = os.path.relpath(file, root) if file.startswith("/") else file
        key = (rel, match.group("line"), match.group("msg"))
        if key in seen:
            continue
        seen.add(key)
        col = match.groupdict().get("col") or "1"
        print(f"::error file={rel},line={match.group('line')},col={col},title={escape(title)}::{escape(match.group('msg')[:400])}")
        emitted += 1
        if emitted >= MAX_ANNOTATIONS:
            break
    if emitted == 0:
        # Nothing structured found: surface the last failure-looking lines so the cause is still visible.
        tail = [l.strip() for l in lines if GENERIC.search(l)][-6:]
        if tail:
            print(f"::error title={escape(title)}::{escape(' | '.join(t[:200] for t in tail))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
