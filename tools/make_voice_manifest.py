#!/usr/bin/env python3
"""
Builds the voice/v1 folder for PEK TV's OPTIONAL spoken replies (Piper), ready to upload to R2.
Speech to text is not hosted: Moonshine is bundled in the app (tools/fetch-voice-model.sh).

  python3 make_voice_manifest.py                      # download + build (needs internet)
  python3 make_voice_manifest.py --voice en_US-amy-medium
  python3 make_voice_manifest.py --bucket my-bucket   # bucket name written into upload.sh

Result (in ./voice_build/voice/v1):
  manifest.json, tts/..., and ../../upload.sh (wrangler commands)

Only the Python standard library is used, so it runs in Termux.
Check each model's licence before you host it (see the notes printed at the end).
"""
import argparse, hashlib, json, os, shutil, sys, tarfile, urllib.request, zipfile

REL = "https://github.com/k2-fsa/sherpa-onnx/releases/download"


def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print(f"  have {os.path.basename(dest)}")
        return
    print(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "pek-voice-build"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest + ".part", "wb") as f:
        shutil.copyfileobj(r, f)
    os.replace(dest + ".part", dest)


def untar(path, into):
    with tarfile.open(path, "r:bz2") as t:
        for m in t.getmembers():  # never let an archive write outside `into`
            target = os.path.realpath(os.path.join(into, m.name))
            if not target.startswith(os.path.realpath(into) + os.sep) and target != os.path.realpath(into):
                sys.exit(f"unsafe path in archive: {m.name}")
        t.extractall(into)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_folder_contents(folder, zip_path):
    # Entries are relative to the folder itself: the app unzips straight into tts/espeak-ng-data.
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(folder):
            for name in files:
                full = os.path.join(root, name)
                z.write(full, os.path.relpath(full, folder))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="en_US-lessac-medium", help="Piper voice name, e.g. en_US-lessac-medium")
    ap.add_argument("--work", default="voice_build", help="working folder")
    ap.add_argument("--bucket", default="pek-models", help="R2 bucket name used in upload.sh")
    a = ap.parse_args()

    work = os.path.abspath(a.work)
    dl = os.path.join(work, "downloads")
    ex = os.path.join(work, "extracted")
    out = os.path.join(work, "voice", "v1")
    os.makedirs(dl, exist_ok=True)
    os.makedirs(ex, exist_ok=True)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "tts"))

    tts_name = f"vits-piper-{a.voice}"
    tts_tar = f"{REL}/tts-models/{tts_name}.tar.bz2"

    print("1/4 download")
    fetch(tts_tar, os.path.join(dl, "piper.tar.bz2"))

    print("2/4 unpack")
    untar(os.path.join(dl, "piper.tar.bz2"), ex)
    tts_dir = os.path.join(ex, tts_name)

    print("3/4 arrange")
    shutil.copyfile(os.path.join(tts_dir, f"{a.voice}.onnx"), os.path.join(out, "tts", "voice.onnx"))
    shutil.copyfile(os.path.join(tts_dir, "tokens.txt"), os.path.join(out, "tts", "tokens.txt"))
    zip_folder_contents(os.path.join(tts_dir, "espeak-ng-data"), os.path.join(out, "tts", "espeak-ng-data.zip"))

    print("4/4 manifest")
    entries = [
        ("tts/voice.onnx", None),
        ("tts/tokens.txt", None),
        ("tts/espeak-ng-data.zip", "tts/espeak-ng-data"),
    ]
    files = []
    for rel, unzip_to in entries:
        p = os.path.join(out, rel)
        e = {"path": rel, "size": os.path.getsize(p), "sha256": sha256(p)}
        if unzip_to:
            e["unzipTo"] = unzip_to
        files.append(e)
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump({"version": 1, "files": files}, f, indent=2)
        f.write("\n")

    # wrangler upload script: long cache on the model files, short on the manifest.
    long_cc = "public, max-age=31536000, immutable"
    lines = ["#!/bin/sh", "set -e", f'BUCKET="{a.bucket}"', f'cd "{work}"']
    for e in files:
        lines.append(f'npx wrangler r2 object put "$BUCKET/voice/v1/{e["path"]}" --file "voice/v1/{e["path"]}" '
                     f'--cache-control "{long_cc}" --remote')
    lines.append('npx wrangler r2 object put "$BUCKET/voice/v1/manifest.json" --file "voice/v1/manifest.json" '
                 '--content-type "application/json" --cache-control "public, max-age=300" --remote')
    up = os.path.join(work, "upload.sh")
    with open(up, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(up, 0o755)

    total = sum(e["size"] for e in files)
    print(f"\nDone. {len(files)} files, {total / 1e6:.1f} MB total.")
    print(f"Folder:  {out}")
    print(f"Upload:  sh {up}   (bucket '{a.bucket}'; change with --bucket)")
    print("\nLicences to check before hosting:")
    print(f"  - Piper voice {a.voice}: see its MODEL_CARD on https://huggingface.co/rhasspy/piper-voices")
    print("    (each voice has its own dataset licence; confirm it allows your use, including commercial).")


if __name__ == "__main__":
    main()
