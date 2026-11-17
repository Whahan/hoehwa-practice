# -*- coding: utf-8 -*-
"""--grammar / --lt-dir: LanguageTool through backend/grammar.py, tested with a stand-in module file (no Java is started)."""
import unittest
from pathlib import Path

import tool_support as ts
import check_course as chk

FAKE = '''
import os
LT_DIR = "unset"
TOOLS = "unset"
LOG_DIR = "unset"
LANG_CODE = {"en": "en-US", "ja": "ja-JP"}
SEEN = []
_state = {"proc": None, "port": None}

def find_jar():
    return os.path.join(LT_DIR, "languagetool-server.jar") if os.path.isfile(os.path.join(LT_DIR, "languagetool-server.jar")) else None

def find_java():
    return "java"

def installed():
    return bool(find_jar())

def start(wait=60.0):
    return None if os.path.isfile(os.path.join(LT_DIR, "no_start")) else "http://x"

def correct(lang, text, quiet=False):
    open(os.path.join(os.path.dirname(__file__), "calls.txt"), "a").write(LANG_CODE["en"] + " ")
    return {"fix": "x", "changes": []} if text == "Is it one?" else None

def stop():
    open(os.path.join(os.path.dirname(__file__), "stopped.txt"), "w").write("1")
'''


class GrammarOption(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)
        self.src = self.root / "m"
        ts.write_course(self.src)
        self.mod = self.root / "grammar_fake.py"
        self.mod.write_text(FAKE, encoding="utf-8")
        self.lt = self.root / "lt"
        self.lt.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *extra):
        return ts.check("--in", self.src, "--grammar", "--grammar-backend", self.mod, *extra)

    def test_no_jar_in_the_given_folder_is_skipped(self):
        code, lines = self.run_cli("--lt-dir", self.lt)
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(ln.startswith("GRAMMAR_SKIPPED") for ln in lines))
        self.assertFalse((self.root / "calls.txt").exists())

    def test_lt_dir_is_used_and_the_server_is_stopped(self):
        (self.lt / "languagetool-server.jar").write_text("x", encoding="utf-8")
        code, lines = self.run_cli("--lt-dir", self.lt)
        self.assertEqual(code, 1, lines)
        self.assertEqual(lines[0], "CHECK_FAIL GRAMMAR")
        self.assertTrue(any(ln.startswith("GRAMMAR_CHECKED sentences=") and "server stopped" in ln for ln in lines))
        self.assertTrue((self.root / "stopped.txt").exists())

    def test_canadian_english_is_requested(self):
        (self.lt / "languagetool-server.jar").write_text("x", encoding="utf-8")
        self.run_cli("--lt-dir", self.lt)
        self.assertEqual(set((self.root / "calls.txt").read_text().split()), {"en-CA"})

    def test_a_server_that_does_not_start_is_not_a_pass(self):
        (self.lt / "languagetool-server.jar").write_text("x", encoding="utf-8")
        (self.lt / "no_start").write_text("x", encoding="utf-8")
        code, lines = self.run_cli("--lt-dir", self.lt)
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(ln.startswith("GRAMMAR_SKIPPED reason=server_did_not_start") for ln in lines))
        self.assertFalse(any(ln.startswith("GRAMMAR_CHECKED") for ln in lines))
        code, lines = self.run_cli("--lt-dir", self.lt, "--strict")
        self.assertEqual(code, 0)          # skipped = not verified; the report says so (no violation is invented)

    def test_candidates_start_with_the_option_then_this_repo_then_the_main_checkout(self):
        c = chk._lt_dir_candidates(str(self.lt))
        self.assertEqual(c[0], self.lt)
        self.assertTrue(any(str(p).endswith(str(Path("backend") / "tools" / "languagetool")) for p in c[1:]))
        self.assertGreaterEqual(len(c), 4)


if __name__ == "__main__":
    unittest.main()
