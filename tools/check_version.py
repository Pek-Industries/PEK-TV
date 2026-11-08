#!/usr/bin/env python3
"""Fails when the release numbers disagree.

Checked (all must match, or the build is refused):
  * flutter_ui/pubspec.yaml            version: X.Y.Z+N
  * android/app/build.gradle           def pekBaseCode = N     and the local-build versionName fallback ('X.Y.Z')
  * flutter_ui/lib/src/whats_new.dart  the TOP ReleaseNotes('X.Y.Z', ...) entry
  * the git tag (when --tag is given)  vX.Y.Z

Why: Android refuses an update whose versionCode is not higher than the installed one, and the app's "What's new" screen
and update check both go by the version name. A tag that disagrees with the files ships an apk that cannot update.

Usage:  python3 tools/check_version.py            (local: files must agree with each other)
        python3 tools/check_version.py --tag v2.2.4   (CI on a tag push: the tag must agree too)
Run from anywhere; paths are relative to the repository root (the parent of tools/).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def collect():
    found = {}
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$", read("flutter_ui/pubspec.yaml"), re.M)
    if not m:
        raise SystemExit("pubspec.yaml: no 'version: X.Y.Z+N' line")
    found["pubspec version"], found["pubspec build number"] = m.group(1), m.group(2)

    g = read("android/app/build.gradle")
    m = re.search(r"def\s+pekBaseCode\s*=\s*(\d+)", g)
    if not m:
        raise SystemExit("build.gradle: no 'def pekBaseCode = N' line")
    found["build.gradle pekBaseCode"] = m.group(1)
    m = re.search(r"project\.property\('pekVersionName'\)\s*:\s*'(\d+\.\d+\.\d+)'", g)
    if not m:
        raise SystemExit("build.gradle: no local versionName fallback 'X.Y.Z'")
    found["build.gradle local versionName"] = m.group(1)

    m = re.search(r"static const releases = <ReleaseNotes>\[\s*ReleaseNotes\('(\d+\.\d+\.\d+)'", read("flutter_ui/lib/src/whats_new.dart"))
    if not m:
        raise SystemExit("whats_new.dart: could not find the top ReleaseNotes entry")
    found["What's New top entry"] = m.group(1)
    return found


def main(argv):
    f = collect()
    tag = None
    if "--tag" in argv:
        i = argv.index("--tag")
        tag = argv[i + 1].lstrip("vV") if i + 1 < len(argv) else ""
        if not re.fullmatch(r"\d+\.\d+\.\d+", tag):
            raise SystemExit("tag '%s' is not vX.Y.Z (pre-release suffixes are not allowed on a release tag)" % tag)
        f["git tag"] = tag

    names = [k for k in f if "build number" not in k and "pekBaseCode" not in k]
    versions = {f[k] for k in names}
    codes = {f["pubspec build number"], f["build.gradle pekBaseCode"]}

    width = max(len(k) for k in f)
    for k, v in f.items():
        print("  %-*s  %s" % (width, k, v))

    errors = []
    if len(versions) != 1:
        errors.append("version names disagree: " + ", ".join("%s=%s" % (k, f[k]) for k in names))
    if len(codes) != 1:
        errors.append("build number disagrees: pubspec +%s vs pekBaseCode %s (Android refuses an update whose versionCode is not higher)"
                      % (f["pubspec build number"], f["build.gradle pekBaseCode"]))
    if errors:
        print()
        for e in errors:
            print("ERROR:", e)
        return 1
    print("OK: %s (build %s)" % (versions.pop(), codes.pop()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
