# -*- coding: utf-8 -*-
"""--grammar with policy.json `lt_ignore_words`: a word of the list is not a spelling error for LanguageTool (loonie, toonie),
a misspelling that is not on the list still fails. LanguageTool is replaced by a stand-in module (no Java is started)."""
import unittest
from pathlib import Path

import tool_support as ts
import check_course as chk

# The stand-in dictionary: every word of unknown.txt is "unknown" (a spelling match like MORFOLOGIK_RULE_EN_CA). `correct`
# works like backend/grammar.py: it calls the module-level `check` and returns a fix when a match is left.
FAKE = '''
import os, re
LT_DIR = "unset"
TOOLS = "unset"
LOG_DIR = "unset"
LANG_CODE = {"en": "en-US"}
_state = {"proc": None, "port": None}
HERE = os.path.dirname(__file__)

def find_jar():
    return os.path.join(LT_DIR, "languagetool-server.jar") if os.path.isfile(os.path.join(LT_DIR, "languagetool-server.jar")) else None

def find_java():
    return "java"

def installed():
    return bool(find_jar())

def start(wait=60.0):
    return "http://x"

def stop():
    open(os.path.join(HERE, "stopped.txt"), "w").write("1")

def check(lang, text, timeout=8.0, quiet=False):
    unknown = set(open(os.path.join(HERE, "unknown.txt")).read().split())
    out = []
    for m in re.finditer(r"[A-Za-z]+", text):
        if m.group(0).lower() in unknown:
            out.append({"offset": m.start(), "length": len(m.group(0)), "replacements": [{"value": "xyz"}],
                        "rule": {"id": "MORFOLOGIK_RULE_EN_CA", "category": {"id": "TYPOS"}}})
    return out

def correct(lang, text, quiet=False):
    return {"fix": "x", "changes": []} if check(lang, text, quiet=quiet) else None
'''


class LtIgnoreWords(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)
        self.mod = self.root / "grammar_fake.py"
        self.mod.write_text(FAKE, encoding="utf-8")
        self.lt = self.root / "lt"
        self.lt.mkdir()
        (self.lt / "languagetool-server.jar").write_text("x", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def run_case(self, unknown, ignore):
        """Course with policy `lt_ignore_words` = ignore (None: no key); the stand-in flags the words of `unknown`."""
        (self.root / "unknown.txt").write_text(" ".join(unknown), encoding="utf-8")

        def mutate(d):
            if ignore is not None:
                d["policy.json"]["lt_ignore_words"] = ignore
        src = self.root / "m"
        ts.write_course(src, mutate)
        return ts.check("--in", src, "--grammar", "--grammar-backend", self.mod, "--lt-dir", self.lt)

    def test_a_listed_word_passes(self):
        code, lines = self.run_case(["thanks"], ["Thanks"])          # case does not matter
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(ln.startswith("GRAMMAR_CHECKED sentences=") for ln in lines), lines)
        self.assertEqual([ln for ln in lines if "GRAMMAR" in ln and ln.startswith("  ")], [])

    def test_the_same_word_without_the_list_fails(self):
        code, lines = self.run_case(["thanks"], None)
        self.assertEqual(code, 1, lines)
        self.assertEqual(lines[0], "CHECK_FAIL GRAMMAR")
        self.assertTrue(any("s0003" in ln for ln in lines), lines)

    def test_a_misspelling_that_is_not_listed_still_fails(self):
        code, lines = self.run_case(["thanks", "sorry"], ["thanks"])
        self.assertEqual(code, 1, lines)
        self.assertEqual(lines[0], "CHECK_FAIL GRAMMAR")
        bad = [ln for ln in lines if ln.startswith("  GRAMMAR")]
        self.assertTrue(any("s0004" in ln for ln in bad), lines)          # Sorry.
        self.assertFalse(any("s0003" in ln or "s0007" in ln for ln in bad), lines)   # Thanks. / Yes, thanks.

    def test_an_empty_list_changes_nothing(self):
        code, lines = self.run_case(["thanks"], [])
        self.assertEqual(code, 1, lines)

    def test_the_filter_keeps_grammar_matches_and_passes_none_through(self):
        spelling = {"offset": 2, "length": 6, "rule": {"id": "MORFOLOGIK_RULE_EN_CA", "category": {"id": "TYPOS"}}}
        grammar = {"offset": 2, "length": 6, "rule": {"id": "EN_A_VS_AN", "category": {"id": "MISC"}}}
        other = {"offset": 12, "length": 3, "rule": {"id": "MORFOLOGIK_RULE_EN_CA", "category": {"id": "TYPOS"}}}
        text = "A loonie is teh one."
        wrapped = chk._lt_ignoring(lambda lang, t, *a, **k: [spelling, grammar, other], {"loonie"})
        self.assertEqual(wrapped("en", text), [grammar, other])          # only the listed spelling match is dropped
        self.assertIsNone(chk._lt_ignoring(lambda lang, t, *a, **k: None, {"loonie"})("en", text))


if __name__ == "__main__":
    unittest.main()
