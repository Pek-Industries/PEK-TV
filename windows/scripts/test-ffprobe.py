#!/usr/bin/env python3
"""Checks a ffprobe.exe the way the scanner uses it: writes a 1 second WAV with title / artist tags, runs
`ffprobe -v quiet -print_format json -show_format <file>` with NOTHING but the Windows system folder on PATH (so a missing DLL shows up
as a failure here, not on a customer's PC) and checks the duration and the tags come back.
Usage: test-ffprobe.py <path to ffprobe.exe>      Exit 0 = good."""
import json, os, struct, subprocess, sys, tempfile

def chunk(cid, data):
    return cid + struct.pack("<I", len(data)) + data + (b"\0" if len(data) % 2 else b"")

def make_wav(path):
    sr = 8000
    fmt = struct.pack("<HHIIHH", 1, 1, sr, sr, 1, 8)
    info = b"INFO" + chunk(b"INAM", b"PEKTEST\0") + chunk(b"IART", b"PEKARTIST\0")
    body = b"WAVE" + chunk(b"fmt ", fmt) + chunk(b"data", b"\x80" * sr) + chunk(b"LIST", info)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", len(body)) + body)

def main():
    exe = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "t\u00e9st.wav")           # a non-ASCII name, like a real library
        make_wav(wav)
        env = {"SystemRoot": os.environ.get("SystemRoot", r"C:\Windows"), "PATH": os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32")}
        r = subprocess.run([exe, "-v", "quiet", "-print_format", "json", "-show_format", wav], env=env, capture_output=True, timeout=60)
    if r.returncode != 0:
        print("ffprobe exited with", r.returncode, r.stderr.decode("utf-8", "replace")); return 1
    fmt = json.loads(r.stdout.decode("utf-8"))["format"]
    tags = {k.lower(): v for k, v in fmt.get("tags", {}).items()}
    dur = float(fmt.get("duration", 0))
    print("duration", dur, "tags", tags)
    ok = abs(dur - 1.0) < 0.05 and tags.get("title") == "PEKTEST" and tags.get("artist") == "PEKARTIST"
    print("OK" if ok else "FAILED: duration or tags are wrong")
    return 0 if ok else 1

sys.exit(main())
