#!/usr/bin/env python3
"""Tests for official plugin signing (backend/pek_ed25519.py, pek_guard.verify_official, tools/pektool.py). Run: python3 tools/test_signing.py"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "backend"))
import pek_ed25519 as ed  # noqa: E402
import pek_guard as g  # noqa: E402

TOOL = os.path.join(ROOT, "tools", "pektool.py")


class Ed25519(unittest.TestCase):
    def test_rfc8032_vector_1(self):
        seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        self.assertEqual(ed.public_key(seed).hex(), "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        self.assertEqual(ed.sign(seed, b"").hex(),
                         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")

    def test_rejects_wrong_message_and_garbage(self):
        seed = os.urandom(32)
        pub, sig = ed.public_key(seed), ed.sign(seed, b"hello")
        self.assertTrue(ed.verify(pub, b"hello", sig))
        self.assertFalse(ed.verify(pub, b"hellp", sig))
        self.assertFalse(ed.verify(pub, b"hello", sig[:-1]))
        self.assertFalse(ed.verify(b"\0" * 32, b"hello", sig))


class Signing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.seed = os.urandom(32)
        self.keyfile = os.path.join(self.tmp, "k.key")
        with open(self.keyfile, "w") as f:
            f.write(self.seed.hex())
        self.pub = ed.public_key(self.seed)
        self.old_keys = g.official_keys
        g.official_keys = lambda: [self.pub]
        self.folder = os.path.join(self.tmp, "weather")
        os.makedirs(os.path.join(self.folder, "data"))
        for name, text in (("plugin.json", '{"name":"w","version":"1.0.0"}'), ("screen.py", "x = 1\n"), ("backend.py", "def run(): pass\n")):
            with open(os.path.join(self.folder, name), "w") as f:
                f.write(text)
        self.sign()

    def tearDown(self):
        g.official_keys = self.old_keys
        shutil.rmtree(self.tmp, ignore_errors=True)

    def sign(self):
        subprocess.run([sys.executable, TOOL, "--no-color", "sign", self.folder, "--key", self.keyfile], check=True, capture_output=True)

    def test_valid(self):
        self.assertTrue(g.verify_official("weather", self.folder))
        self.assertTrue(g.is_trusted("weather", self.folder))

    def test_runtime_data_folder_is_not_covered(self):
        with open(os.path.join(self.folder, "data", "cache.json"), "w") as f:
            f.write("{}")
        self.assertTrue(g.verify_official("weather", self.folder))

    def test_changed_or_added_file_breaks_it(self):
        with open(os.path.join(self.folder, "backend.py"), "a") as f:
            f.write("import os\n")
        self.assertFalse(g.verify_official("weather", self.folder))

    def test_added_file_breaks_it(self):
        with open(os.path.join(self.folder, "extra.py"), "w") as f:
            f.write("pass\n")
        self.assertFalse(g.verify_official("weather", self.folder))

    def test_name_alone_proves_nothing(self):
        shutil.copytree(self.folder, os.path.join(self.tmp, "evil"))
        self.assertFalse(g.verify_official("evil", os.path.join(self.tmp, "evil")))   # signed for 'weather', not 'evil'
        os.remove(os.path.join(self.folder, "PEK-SIGNATURE.json"))
        self.assertFalse(g.is_trusted("weather", self.folder))

    def test_other_key_is_refused(self):
        g.official_keys = lambda: [ed.public_key(os.urandom(32))]
        self.assertFalse(g.verify_official("weather", self.folder))

    def test_no_pinned_key_fails_closed(self):
        g.official_keys = lambda: []
        self.assertFalse(g.verify_official("weather", self.folder))

    def test_only_weather_gets_full_access(self):
        tdir = os.path.join(self.tmp, "tmdb-discover")
        shutil.copytree(self.folder, tdir)
        subprocess.run([sys.executable, TOOL, "--no-color", "sign", tdir, "--key", self.keyfile], check=True, capture_output=True)
        self.assertTrue(g.verify_official("tmdb-discover", tdir))
        self.assertFalse(g.is_trusted("tmdb-discover", tdir))   # still sandboxed, as before


if __name__ == "__main__":
    unittest.main()
