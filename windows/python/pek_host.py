"""PEK TV's Python plugin host for Windows (the counterpart of Boot.startPythonPlugins + FlutterHostActivity.pythonCall on Android).

Started by windows/runner/pek_host.cpp as:   python.exe -u -X utf8 pek_host.py <plugins folder>
  - stdin / stdout carry a tiny length-prefixed protocol with the runner, nothing else:
        runner -> here:  "T <token>\\n"                (first line: the per-launch server token, never put in the environment)
                         "C <id> <len>\\n<len bytes>"     a request for pek_flutter.call() (UTF-8 JSON)
        here -> runner:  "R <id> <len>\\n<len bytes>"     the answer (UTF-8 JSON)
  - anything plugins print goes to stderr's log file (python.log), and plugins cannot read the protocol pipes.
The plugins themselves (plugins/<n>/backend.py, screen.py) run unchanged, through the same pek_runner / pek_flutter modules Android uses.
"""
import json
import os
import sys
import threading

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# Take the protocol pipes for ourselves, then point fd 0 / fd 1 at NUL / the log so plugin code (print, input) cannot touch them.
_proto_in = os.fdopen(os.dup(0), "rb", buffering=0)
_proto_out = os.fdopen(os.dup(1), "wb", buffering=0)
os.dup2(2, 1)
_nul = os.open(os.devnull, os.O_RDONLY)
os.dup2(_nul, 0)
os.close(_nul)

_write_lock = threading.Lock()


def _read_line():
    out = bytearray()
    while True:
        b = _proto_in.read(1)
        if not b:
            return None
        if b == b"\n":
            return bytes(out).decode("utf-8", "replace")
        out += b


def _read_exact(n):
    buf = bytearray()
    while len(buf) < n:
        chunk = _proto_in.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def _answer(req_id, text):
    data = text.encode("utf-8")
    with _write_lock:
        _proto_out.write(("R %d %d\n" % (req_id, len(data))).encode("ascii") + data)


def _serve(req_id, text):
    try:
        import pek_flutter
        _answer(req_id, pek_flutter.call(text))
    except BaseException as e:  # never let one request take the host down
        _answer(req_id, json.dumps({"ok": False, "error": "plugin host error: %s" % e}))


def main():
    plugins_dir = sys.argv[1] if len(sys.argv) > 1 else ""
    hello = _read_line() or ""
    token = hello[2:] if hello.startswith("T ") else ""

    import pek_runner
    pek_runner.PLUGINS_DIR = plugins_dir
    threading.Thread(target=pek_runner.run_all, args=(plugins_dir, token), daemon=True).start()

    while True:
        head = _read_line()
        if head is None:
            break  # the app closed the pipe: we are done
        parts = head.split()
        if len(parts) != 3 or parts[0] != "C":
            continue
        body = _read_exact(int(parts[2]))
        if body is None:
            break
        threading.Thread(target=_serve, args=(int(parts[1]), body.decode("utf-8", "replace")), daemon=True).start()


if __name__ == "__main__":
    main()
