#!/usr/bin/env python3
"""Checks the translation tables (flutter_ui/lib/src/l10n/l10n_*.dart) against each other and against the app's source.

  python3 tools/check_l10n.py          run from the repository root; exits 1 on any problem

What it checks:
  1. every language has exactly the same English keys
  2. no translation is empty, and each keeps the same {placeholders} as its key
  3. every 'text'.tr / 'text'.trp(...) in the app has an entry (a miss would silently stay English)
  4. every key appears as a string in the app (a typo in a key would never match, so it would never translate)
Edit the tables in tools/gen_l10n.py, then run it to regenerate the Dart files.
"""
import glob, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "flutter_ui", "lib", "src")
LANG_FILES = sorted(glob.glob(os.path.join(SRC, "l10n", "l10n_*.dart")))

STR = r"'((?:[^'\\\n]|\\.)*)'"

def unescape(s: str) -> str:
    s = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"\\(.)", r"\1", s)

def load(path):
    out = {}
    for m in re.finditer(r"^\s*" + STR + r"\s*:\s*" + STR + r",\s*$", open(path, encoding="utf-8").read(), re.M):
        k, v = unescape(m.group(1)), unescape(m.group(2))
        if k in out:
            print(f"{os.path.basename(path)}: duplicate key {k!r}")
            sys.exit(1)
        out[k] = v
    return out

def main():
    problems = []
    tables = {os.path.basename(p)[5:-5]: load(p) for p in LANG_FILES}
    if not tables:
        sys.exit("no l10n tables found")
    base_code = sorted(tables)[0]
    base = set(tables[base_code])
    for code, t in tables.items():
        if set(t) != base:
            problems.append(f"{code}: keys differ from {base_code}: missing {sorted(base - set(t))[:3]} extra {sorted(set(t) - base)[:3]}")
        for k, v in t.items():
            if not v.strip():
                problems.append(f"{code}: empty translation for {k!r}")
            if sorted(re.findall(r"\{\w+\}", k)) != sorted(re.findall(r"\{\w+\}", v)):
                problems.append(f"{code}: placeholders differ for {k!r}")

    used, literals = set(), set()
    for path in glob.glob(os.path.join(SRC, "**", "*.dart"), recursive=True):
        if os.sep + "l10n" + os.sep in path:
            continue
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(STR + r"\.trp?\b", text):
            used.add((unescape(m.group(1)), os.path.relpath(path, SRC)))
        for m in re.finditer(STR, text):
            literals.add(unescape(m.group(1)))
    for k, f in sorted(used):
        if k not in base:
            problems.append(f"{f}: '{k[:60]}'.tr has no translation")
    for k in sorted(base):
        if k not in literals:
            problems.append(f"table key never appears in the app: {k[:70]!r}")

    if problems:
        print("\n".join(problems))
        sys.exit(1)
    print(f"OK: {len(base)} strings x {len(tables)} languages ({', '.join(sorted(tables))}); {len(used)} .tr call sites checked")

main()
