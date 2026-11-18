# -*- coding: utf-8 -*-
"""check_course.py: the 14 deliberately wrong manuscripts, the good one, and the individual rules (K1-2, K1-3, K1-8)."""
import json
import re
import sqlite3
import tempfile
import unittest
from pathlib import Path

import tool_support as ts
import check_course as chk
import course_common as cc


def run(root, *args):
    return ts.check("--in", root, *args)


class Fixtures(unittest.TestCase):
    def test_good_mini_passes_strict(self):
        code, lines = ts.check("--in", ts.FIX / "good_mini", "--strict")
        self.assertEqual(code, 0, lines)
        self.assertRegex(lines[-1], r"^CHECK_OK weeks=1-4 .*violations=0$")

    def test_each_bad_fixture_fails_with_its_own_code(self):
        self.assertEqual(len(ts.mf.BAD), 15)
        for name, code in ts.mf.BAD.items():
            with self.subTest(name=name):
                rc, lines = ts.check("--in", ts.FIX / name, "--strict")
                self.assertEqual(rc, 1, lines)
                self.assertEqual(lines[0], "CHECK_FAIL " + code)
                self.assertEqual(set(ts.codes_of(lines)), {code}, lines)
                self.assertRegex(lines[-1], r"^CHECK_FAIL weeks=\S+ .*violations=\d+ codes=" + code)

    def test_thirteen_required_codes_are_covered(self):
        required = {"SCHEMA", "ORDER", "UNKNOWN_TOKEN", "NUM_SAY", "KO_HANGUL", "KO_HANJA", "DUP_EN", "SAME_KO_OPTIONS", "BLOCKED",
                    "PERSONAL", "COUNT", "CANON", "TATOEBA"}
        self.assertTrue(required <= set(ts.mf.BAD.values()))

    def test_output_never_contains_manuscript_text(self):
        for name in ["good_mini"] + list(ts.mf.BAD):
            rc, lines = ts.check("--in", ts.FIX / name, "--strict")
            text = "\n".join(lines)
            self.assertIsNone(re.search(r"[가-힣]", text), name)
            for frag in ("Hello, my name is", "Good morning", "My number is"):
                self.assertNotIn(frag, text, name)


class Basics(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def mk(self, mutate=None, files=None):
        return ts.write_course(self.root, mutate, files)

    def res(self, mutate=None, files=None, **kw):
        root = self.mk(mutate, files)
        return chk.run_check(str(root), **kw)

    def codes(self, r):
        return sorted({p.code for p in r.violations})

    def details(self, r, code):
        return [p.detail for p in r.violations if p.code == code]

    def test_broken_json_is_schema(self):
        self.mk()
        (self.root / "weeks" / "w002.json").write_text("{ not json", encoding="utf-8")
        code, lines = run(self.root)
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "CHECK_FAIL SCHEMA")

    def test_missing_in_dir_is_schema(self):
        code, lines = ts.check("--in", self.root / "nope")
        self.assertEqual((code, lines[0]), (1, "CHECK_FAIL SCHEMA"))

    def test_bad_weeks_argument(self):
        self.mk()
        for bad in ("0", "73", "5-3", "x"):
            code, lines = run(self.root, "--weeks", bad)
            self.assertEqual((code, lines[0]), (1, "CHECK_FAIL SCHEMA bad_weeks_argument"), bad)

    def test_weeks_range_with_missing_file(self):
        self.mk()
        r = chk.run_check(str(self.root), (1, 3))
        self.assertIn("week_file_missing", self.details(r, "SCHEMA"))

    def test_weeks_range_only_checks_those_weeks(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0102")["en"] = "It is zzyx."
        r = self.res(mut, weeks_arg=(1, 1))
        self.assertEqual(r.violations, [])
        r = self.res(None, weeks_arg=(2, 2))
        self.assertEqual(r.violations, [])
        self.mk(mut)
        r = chk.run_check(str(self.root), (2, 2))
        self.assertEqual(self.codes(r), ["UNKNOWN_TOKEN"])

    def test_outside_range_invalid_file_is_ignored_with_warning(self):
        self.mk()
        (self.root / "weeks" / "w004.json").write_text(json.dumps({"v": 1, "w": 4, "words": "x"}), encoding="utf-8")
        r = chk.run_check(str(self.root), (1, 2))
        self.assertEqual(r.violations, [])
        self.assertTrue(any("outside_range" in p.detail for p in r.warnings))
        r = chk.run_check(str(self.root), (1, 2), strict=True)
        self.assertTrue(r.violations)

    def test_file_name_and_w_mismatch(self):
        def mut(d):
            d["weeks/w002.json"]["w"] = 3
        self.assertIn("w_does_not_match_file_name", self.details(self.res(mut), "SCHEMA"))

    def test_unknown_key_is_warning_and_strict_fails(self):
        def mut(d):
            ts.find(d, 1, "words", "w0001")["colour"] = "x"
        self.mk(mut)
        r = chk.run_check(str(self.root))
        self.assertEqual(r.violations, [])
        self.assertTrue(any("unknown_key=colour" in p.detail for p in r.warnings))
        self.assertEqual(self.codes(chk.run_check(str(self.root), strict=True)), ["SCHEMA"])

    def test_underscore_keys_are_allowed(self):
        def mut(d):
            ts.find(d, 1, "words", "w0001")["_memo"] = "x"
        self.assertEqual(self.res(mut, strict=True).violations, [])

    def test_ko_style_plain_ending_is_a_strict_violation(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0001")["ko"] = "안녕하세요 그래."
        self.mk(mut)
        self.assertEqual(chk.run_check(str(self.root)).violations, [])
        r = chk.run_check(str(self.root), strict=True)
        self.assertIn("ko_style_not_haeyo", self.details(r, "SCHEMA"))

    def test_missing_policy_warns_and_strict_fails(self):
        self.mk()
        (self.root / "policy.json").unlink()
        r = chk.run_check(str(self.root))
        self.assertTrue(any(p.where == "policy.json" and p.detail == "missing" for p in r.warnings))
        self.assertFalse(any(p.where == "policy.json" for p in r.violations))
        r = chk.run_check(str(self.root), strict=True)
        self.assertIn("missing", self.details(r, "SCHEMA"))

    def test_duplicate_id_across_weeks(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0101")["id"] = "s0001"
        r = self.res(mut)
        self.assertTrue(any(x.startswith("duplicate_id_also_in") for x in self.details(r, "SCHEMA")))

    def test_word_ko_longer_than_12_chars(self):
        def mut(d):
            ts.find(d, 1, "words", "w0001")["ko"] = "가" * 13
        self.assertIn("ko_longer_than_12", self.details(self.res(mut), "SCHEMA"))

    def test_grammar_ko_needs_two_to_four_short_lines(self):
        def one(d):
            d["weeks/w001.json"]["patterns"][0]["grammar_ko"] = ["하나뿐이에요."]

        def five(d):
            d["weeks/w001.json"]["patterns"][0]["grammar_ko"] = ["가."] * 5

        def long(d):
            d["weeks/w001.json"]["patterns"][0]["grammar_ko"] = ["가" * 91, "나."]
        self.assertIn("grammar_ko_must_be_2_to_4_lines", self.details(self.res(one), "SCHEMA"))
        self.assertIn("grammar_ko_must_be_2_to_4_lines", self.details(self.res(five), "SCHEMA"))
        self.assertIn("grammar_ko_line_empty_or_longer_than_90", self.details(self.res(long), "SCHEMA"))

    def test_word_day_beyond_d4_is_count(self):
        def mut(d):
            ts.find(d, 1, "words", "w0013")["d"] = 5
        self.assertIn("new_word_day_out_of_range", self.details(self.res(mut), "COUNT"))

    def test_o_that_disagrees_with_w_d(self):
        def mut(d):
            ts.find(d, 1, "words", "w0013")["o"] = 99
        self.assertIn("o_does_not_match_w_d", self.details(self.res(mut), "SCHEMA"))

    def test_english_field_with_hangul_is_schema(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hello 안녕."
        self.assertIn("en_has_non_english_letters", self.details(self.res(mut), "SCHEMA"))

    def test_sentence_without_d_using_a_later_weeks_word(self):
        def mut(d):
            s = ts.find(d, 1, "sentences", "s0001")
            del s["d"]
            s["en"] = "Thanks, bye."
            s["ko"] = "고마워요, 잘 가요."
        self.assertEqual(self.codes(self.res(mut)), ["ORDER"])

    def test_sentence_without_d_is_fine_when_words_are_this_weeks(self):
        def mut(d):
            del ts.find(d, 1, "sentences", "s0017")["d"]
        self.assertEqual(self.res(mut).violations, [])

    def test_item_before_its_word_day_is_order(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0009")["d"] = 2   # "name" is taught on d3
        self.assertIn("ORDER", self.codes(self.res(mut)))

    def test_same_day_word_is_allowed(self):
        self.assertEqual(self.res(None).violations, [])

    def test_passive_word_in_scope_all_is_order(self):
        def mut(d):
            ts.find(d, 1, "words", "w0013")["role"] = "passive"
        r = self.res(mut)
        self.assertTrue(any(x.startswith("passive_token_in_scope_all") for x in self.details(r, "ORDER")))

    def test_passive_word_in_listen_scope_is_fine(self):
        def mut(d):
            ts.find(d, 1, "words", "w0013")["role"] = "passive"
            for wk in ("weeks/w001.json", "weeks/w004.json"):
                for s in d[wk]["sentences"]:
                    if "morning" in s["en"].lower():
                        s["scope"] = "listen"
        r = self.res(mut)
        self.assertFalse([x for x in self.details(r, "ORDER") if x.startswith("passive")])

    def test_passive_word_needs_a_sentence(self):
        """COUNT passive_word_sentences: a passive word that no sentence of its week contains never reaches the learner."""
        def listen_only(d):
            ts.find(d, 1, "words", "w0013")["role"] = "passive"
            for s in d["weeks/w001.json"]["sentences"]:
                if "morning" in s["en"].lower():
                    s["scope"] = "listen"

        def without_sentence(d):
            listen_only(d)
            wk = d["weeks/w001.json"]
            wk["sentences"] = [s for s in wk["sentences"] if "morning" not in s["en"].lower()]
        wk = self.res(listen_only)
        self.assertFalse([x for x in self.details(wk, "COUNT") if x.startswith("passive_word_sentences")], self.details(wk, "COUNT"))
        bad = self.res(without_sentence)
        self.assertTrue(any(x.startswith("passive_word_sentences=0") for x in self.details(bad, "COUNT")), self.details(bad, "COUNT"))

    def test_declared_words_are_verified(self):
        def unknown(d):
            ts.find(d, 1, "sentences", "s0001")["words"] = ["w9999"]

        def later(d):
            ts.find(d, 1, "sentences", "s0001")["words"] = ["w0001", "w0013"]

        def absent(d):
            ts.find(d, 1, "sentences", "s0003")["words"] = ["w0003", "w0001"]
        self.assertIn("words_unknown_id=w9999", self.details(self.res(unknown), "SCHEMA"))
        self.assertTrue(any(x.startswith("declared_word=w0013") for x in self.details(self.res(later), "ORDER")))
        self.assertIn("words_id_not_in_text=w0001", self.details(self.res(absent), "SCHEMA"))

    def test_form_of_a_word_is_known_only_from_its_pattern(self):
        def mut(d):
            w = ts.find(d, 1, "words", "w0008")      # name (d3)
            w["forms"] = [{"f": "names", "pat": "p_good_x"}]   # pattern p_good_x is d4
            ts.find(d, 1, "sentences", "s0013")["en"] = "Sorry, names."
            ts.find(d, 1, "sentences", "s0013")["ko"] = "미안해요, 이름들."
        r = self.res(mut)
        self.assertTrue(any(x.startswith("token=names") for x in self.details(r, "ORDER")), r.violations and [p.detail for p in r.violations])

    def test_form_with_unknown_pattern_is_schema(self):
        def mut(d):
            ts.find(d, 1, "words", "w0008")["forms"] = [{"f": "names", "pat": "p_nope"}]
        self.assertIn("form_pattern_unknown=p_nope", self.details(self.res(mut), "SCHEMA"))

    def test_chunk_tokens_count_at_the_chunk_day(self):
        def mut(d):
            d["weeks/w002.json"]["words"].append(ts.mf.W("w0199", "see you", "chunk", "또 봐요", "", 4))
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hello, see."
        r = self.res(mut)
        self.assertTrue(any(x.startswith("token=see") for x in self.details(r, "ORDER")))

    def test_accept_tokens_are_checked(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0001")["accept"] = ["Hello, friend."]
        self.assertIn("ORDER", self.codes(self.res(mut)))

    def test_digit_without_say_is_num_say_not_unknown_token(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0108")["say"] = ""
        r = self.res(mut)
        self.assertEqual(self.codes(r), ["NUM_SAY"])

    def test_say_that_differs_from_the_numbers_is_num_say(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0107")["say"] = "My number is two."
        self.assertIn("say_differs_from_numbers_en", self.details(self.res(mut), "NUM_SAY"))

    def test_say_keeps_digits_is_num_say(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0107")["say"] = "My number is 3."
        self.assertIn("say_has_digits_or_symbols", self.details(self.res(mut), "NUM_SAY"))

    def test_acronym_and_abbreviation_need_say(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hello, XYZ."          # an unregistered acronym needs a letter-by-letter say
        self.assertIn("say_missing", self.details(self.res(mut), "NUM_SAY"))

    def test_acronym_ok_list_in_policy(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hello, XYZ."
            d["policy.json"]["acronym_ok"] = ["XYZ"]
        self.assertNotIn("NUM_SAY", self.codes(self.res(mut)))

    def test_say_text_is_the_token_source(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0107")["say"] = "My number is zzyx."
        r = self.res(mut)
        self.assertIn("UNKNOWN_TOKEN", self.codes(r))

    def test_blocked_exception_week_and_wildcard(self):
        def mut(d):
            d["policy.json"]["blocked"] = ["thank*"]
            d["policy.json"]["allow"] = {"thanks": [1]}
        r = self.res(mut)
        self.assertEqual({p.where.split(":")[0] for p in r.violations if p.code == "BLOCKED"}, {"w004"})

    def test_blocked_headword(self):
        def mut(d):
            d["policy.json"]["blocked"] = ["room"]
        r = self.res(mut)
        self.assertTrue(any(p.where.endswith("w0106") for p in r.violations if p.code == "BLOCKED"))

    def test_personal_variants(self):
        def real_phone(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "전화는 604-555-1234예요."

        def fake_phone(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "전화는 604-555-0123예요."

        def seven(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "전화는 5551234예요."

        def email(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "메일은 min@gmail.com 이에요."

        def example_mail(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "메일은 min@example.com 이에요."

        def address(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "주소는 12 Maple Street 이에요."

        def postal(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "우편번호는 V6B 1A1 이에요."
        self.assertEqual(self.codes(self.res(real_phone)), ["PERSONAL"])
        self.assertEqual(self.res(fake_phone).violations, [])
        self.assertEqual(self.codes(self.res(seven)), ["PERSONAL"])
        self.assertEqual(self.codes(self.res(email)), ["PERSONAL"])
        self.assertEqual(self.res(example_mail).violations, [])
        self.assertEqual(self.codes(self.res(address)), ["PERSONAL"])
        self.assertEqual(self.codes(self.res(postal)), ["PERSONAL"])

    def test_street_allowed_by_policy(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "주소는 12 Maple Street 이에요."
            d["policy.json"]["fake_streets"] = ["Maple"]
        self.assertEqual(self.res(mut).violations, [])

    def test_name_outside_policy(self):
        def mut(d):
            d["policy.json"]["names"] = ["Anna"]
        r = self.res(mut)
        self.assertIn("name_not_in_policy", self.details(r, "PERSONAL"))

    def test_name_with_place_tag_is_not_a_name(self):
        def mut(d):
            d["policy.json"]["names"] = ["Anna"]
            ts.find(d, 1, "words", "w0010")["tags"] = ["place"]
        self.assertEqual(self.res(mut).violations, [])

    def test_canon_us_spelling_in_a_sentence_and_headword(self):
        def sentence(d):
            ts.find(d, 4, "sentences", "s0409")["en"] = "Good color."
        def headword(d):
            ts.find(d, 4, "words", "w0304")["en"] = "color"
        r = self.res(sentence)
        self.assertTrue(any(x.startswith("us_spelling=color") for x in self.details(r, "CANON")))
        r = self.res(headword)
        self.assertTrue(any(x.startswith("us_spelling_as_headword=color") for x in self.details(r, "CANON")))

    def test_canon_uses_notes_of_the_manuscript(self):
        def mut(d):
            d["weeks/w004.json"]["notes"].append({"id": "n0002", "kind": "spelling", "ca": "hello", "us": "hullo", "text_ko": "철자 노트예요."})
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hullo."
        r = self.res(mut)
        self.assertIn("CANON", self.codes(r))

    def test_tatoeba_ratio_per_week(self):
        def mut(d):
            for sid in ("s0409", "s0410"):
                s = ts.find(d, 4, "sentences", sid)
                s["src"], s["tid"] = "tatoeba", 90001
        r = self.res(mut)
        self.assertTrue(any(x.startswith("ratio_over_limit") for x in self.details(r, "TATOEBA")))

    def test_tatoeba_text_must_match_the_database(self):
        def mut(d):
            d["tatoeba_mini.json"] = {"90001": "Yes, thanks, Anna."}
        r = self.res(mut)
        self.assertIn("text_differs_from_database", self.details(r, "TATOEBA"))

    def test_tatoeba_tid_must_exist(self):
        def mut(d):
            d["tatoeba_mini.json"] = {"5": "x"}
        self.assertIn("tid_not_in_database", self.details(self.res(mut), "TATOEBA"))

    def test_tatoeba_own_sentence_must_not_have_tid(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0001")["tid"] = 7
        self.assertIn("own_sentence_has_tid", self.details(self.res(mut), "TATOEBA"))

    def test_tatoeba_sqlite_database(self):
        self.mk()
        db = self.root / "t.sqlite"
        con = sqlite3.connect(str(db))
        con.execute("CREATE TABLE sent(id INTEGER PRIMARY KEY, lang TEXT NOT NULL, text TEXT NOT NULL, ko TEXT, tr TEXT, k INTEGER NOT NULL)")
        con.execute("INSERT INTO sent VALUES (90001,'en','Yes, thanks, Min.','네',NULL,1)")
        con.commit()
        con.close()
        (self.root / "policy.json").write_text(json.dumps({"v": 1, "tatoeba_db": "none.json", "names": ["Min"],
                                                           "limits": {"min_sentences": 8, "pattern_min_sentences": 2,
                                                                      "intro_active_range": [3, 28], "intro_pattern_range": [1, 2]}}), encoding="utf-8")
        r = chk.run_check(str(self.root), tatoeba_db=str(db))
        self.assertEqual(r.violations, [])
        con = sqlite3.connect(str(db))
        con.execute("UPDATE sent SET text='Other.' WHERE id=90001")
        con.commit()
        con.close()
        r = chk.run_check(str(self.root), tatoeba_db=str(db))
        self.assertIn("text_differs_from_database", self.details(r, "TATOEBA"))

    def test_tatoeba_without_database_is_not_verified(self):
        self.mk()
        (self.root / "tatoeba_mini.json").unlink()
        r = chk.run_check(str(self.root), tatoeba_db=str(self.root / "missing.sqlite"))
        self.assertEqual(r.violations, [])
        self.assertTrue(any(n.startswith("TATOEBA_SKIPPED") for n in r.notes))
        r = chk.run_check(str(self.root), strict=True, tatoeba_db=str(self.root / "missing.sqlite"))
        self.assertEqual(self.codes(r), ["TATOEBA"])

    def test_count_rules(self):
        def few_sentences(d):
            d["weeks/w002.json"]["sentences"] = d["weeks/w002.json"]["sentences"][:5]

        def pattern_sentences(d):
            d["policy.json"]["limits"]["pattern_min_sentences"] = 4

        def word_sentences(d):
            d["policy.json"]["limits"]["word_min_sentences"] = 4

        def active(d):
            d["policy.json"]["limits"]["intro_active_range"] = [20, 28]

        def lines(d):
            d["weeks/w001.json"]["dialogues"][0]["lines"] += [ts.mf.L("A", "Hello.", "안녕하세요.")] * 2

        def two_dialogues(d):
            d["weeks/w001.json"]["dialogues"].append(dict(d["weeks/w001.json"]["dialogues"][0], id="d0009"))
        for fn, want in ((few_sentences, "sentences="), (pattern_sentences, "pattern_sentences="), (word_sentences, "word_sentences="),
                         (active, "active_words="), (lines, "dialogue_lines="), (two_dialogues, "dialogues=2")):
            with self.subTest(fn=fn.__name__):
                r = self.res(fn)
                self.assertTrue(any(x.startswith(want) for x in self.details(r, "COUNT")), self.details(r, "COUNT"))

    def test_speak_prompts_only_in_month_weeks(self):
        def mut(d):
            d["weeks/w004.json"]["speak_prompts"] = d["weeks/w004.json"]["speak_prompts"][:2]
        self.assertTrue(any(x.startswith("speak_prompts=2") for x in self.details(self.res(mut), "COUNT")))

    def test_dup_ko_ignores_punctuation(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0012")["ko"] = "안녕하세요 민!"
        self.assertEqual(self.codes(self.res(mut)), ["DUP_KO"])

    def test_dup_en_ignores_case_and_punctuation(self):
        def mut(d):
            d["weeks/w002.json"]["sentences"].append(ts.mf.S("s0111", "hello!!", "안녕하세요 (인사)", 4))
        self.assertEqual(self.codes(self.res(mut)), ["DUP_EN"])

    def test_same_ko_pair_can_be_declared_as_synonyms(self):
        def mut(d):
            ts.find(d, 1, "words", "w0002")["ko"] = "안녕하세요"
            ts.find(d, 1, "words", "w0002")["syn"] = ["w0001"]
        self.assertEqual(self.res(mut).violations, [])

    def test_same_ko_overlap_through_slash_list(self):
        def mut(d):
            ts.find(d, 1, "words", "w0002")["ko"] = "안녕/반가워요"
            ts.find(d, 1, "words", "w0001")["ko"] = "반가워요"
        self.assertIn("SAME_KO_OPTIONS", self.codes(self.res(mut)))

    def test_ko_foreign_scripts(self):
        for ch in ("谢", "я", "ع", "あ"):
            def mut(d, ch=ch):
                ts.find(d, 1, "sentences", "s0003")["ko"] = "고마워요 " + ch + "."
            with self.subTest(ch=ch):
                self.assertEqual(self.codes(self.res(mut)), ["KO_HANJA"])

    def test_ko_checks_cover_every_korean_field(self):
        def mut(d):
            d["weeks/w001.json"]["patterns"][0]["title_ko"] = "title"
            d["weeks/w001.json"]["dialogues"][0]["lines"][0]["ko"] = "Hello"
            d["weeks/w004.json"]["speak_prompts"][0]["ko"] = "Hello"
            d["weeks/w004.json"]["notes"][0]["text_ko"] = "notes"
            d["weeks/w001.json"]["patterns"][1]["grammar_ko"] = ["abc", "def"]
        r = self.res(mut)
        self.assertEqual(self.codes(r), ["KO_HANGUL"])
        self.assertGreaterEqual(len(r.violations), 6)

    def test_grammar_option_with_fake_languagetool(self):
        class Fake:
            def __init__(self, ok, fix):
                self.ok, self.fix, self.calls, self.stopped = ok, fix, 0, False

            def installed(self):
                return self.ok

            def find_java(self):
                return "java" if self.ok else None

            def correct(self, lang, text, quiet=False):
                self.calls += 1
                return {"fix": "x", "changes": []} if (self.fix and text == "Is it one?") else None

            def stop(self):
                self.stopped = True
        self.mk()
        skipped = Fake(False, False)
        r = chk.run_check(str(self.root), grammar=True, grammar_module=skipped)
        self.assertEqual(r.violations, [])
        self.assertTrue(any(n.startswith("GRAMMAR_SKIPPED") for n in r.notes))
        self.assertEqual(skipped.calls, 0)
        clean = Fake(True, False)
        r = chk.run_check(str(self.root), grammar=True, grammar_module=clean)
        self.assertEqual(r.violations, [])
        self.assertTrue(clean.stopped and clean.calls > 20)
        flagged = Fake(True, True)
        r = chk.run_check(str(self.root), grammar=True, grammar_module=flagged)
        self.assertEqual(self.codes(r), ["GRAMMAR"])

    def test_grammar_cli_prints_skipped_and_exits_0_when_the_tool_is_missing(self):
        self.mk()
        code, lines = run(self.root, "--grammar", "--grammar-backend", self.root / "no_such_grammar.py")
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(ln.startswith("GRAMMAR_SKIPPED") for ln in lines))
        self.assertRegex(lines[-1], r"^CHECK_OK .*violations=0$")

    def test_schema_problems_stop_the_content_checks(self):
        def mut(d):
            del ts.find(d, 1, "words", "w0001")["ko"]
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hello, zzyx."
        self.assertEqual(self.codes(self.res(mut)), ["SCHEMA"])

    def test_malformed_items_never_crash(self):
        def mut(d):
            d["weeks/w001.json"]["words"].append(None)
            d["weeks/w001.json"]["sentences"].append(5)
            d["weeks/w001.json"]["dialogues"][0]["lines"].append("x")
            d["weeks/w001.json"]["patterns"] = {"a": 1}
        r = self.res(mut)
        self.assertEqual(self.codes(r), ["SCHEMA"])

    def test_exit_code_and_usage(self):
        code, lines, err = ts.cli("check_course.py")
        self.assertEqual(code, 2)
        self.assertIn("--in", err)


class Skeleton(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def sk(self, mutate=None):
        ts.write_skeleton_course(self.root, mutate)
        return chk.run_check(str(self.root), skeleton=True, strict=True)

    def details(self, r, code):
        return [p.detail for p in r.violations if p.code == code]

    def test_valid_skeleton_passes_via_cli(self):
        ts.write_skeleton_course(self.root)
        code, lines = run(self.root, "--skeleton", "--strict")
        self.assertEqual(code, 0, lines[:10])
        self.assertRegex(lines[-1], r"^CHECK_OK weeks=1-72 .*violations=0$")

    def test_duplicate_lemma_is_schema(self):
        def mut(sk):
            sk["assign"][5]["lemma"] = sk["assign"][0]["lemma"]
        r = self.sk(mut)
        self.assertTrue(any(x.startswith("duplicate_lemma_with=") for x in self.details(r, "SCHEMA")))

    def test_duplicate_lemma_cli_first_line(self):
        def mut(sk):
            sk["assign"][5]["lemma"] = sk["assign"][0]["lemma"]
        ts.write_skeleton_course(self.root, mut)
        code, lines = run(self.root, "--skeleton", "--strict")
        self.assertEqual((code, lines[0]), (1, "CHECK_FAIL SCHEMA"))

    def test_missing_and_duplicate_weeks(self):
        def mut(sk):
            del sk["weeks"][10]
            sk["weeks"].append(dict(sk["weeks"][0]))
        r = self.sk(mut)
        self.assertIn("week_missing", self.details(r, "SCHEMA"))
        self.assertIn("duplicate_week", self.details(r, "SCHEMA"))

    def test_wrong_stage_n_k_and_legacy_stage(self):
        def mut(sk):
            sk["weeks"][4]["stage"] = 2
            sk["weeks"][5]["k"] = 4
            sk["weeks"][20]["legacy_stage"] = 1
        r = self.sk(mut)
        for want in ("stage_wrong", "n_k_wrong", "legacy_stage_wrong"):
            self.assertIn(want, self.details(r, "SCHEMA"))

    def test_stage_boundaries_follow_the_design(self):
        got = [cc.stage_of_week(w) for w in (1, 4, 5, 16, 17, 32, 33, 48, 49, 60, 61, 68, 69, 72)]
        self.assertEqual(got, [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6])
        got = [cc.legacy_stage(w) for w in (1, 16, 17, 36, 37, 56, 57, 72)]
        self.assertEqual(got, [1, 1, 2, 2, 3, 3, 4, 4])

    def test_count_rules_per_week_and_total(self):
        def week_active(sk):
            sk["weeks"][30]["counts"]["active"] = 40

        def total(sk):
            for wk in sk["weeks"][16:]:
                wk["counts"]["active"] = min(wk["counts"]["active"], 12) if wk["w"] not in (32, 48, 60, 68) else wk["counts"]["active"]
        r = self.sk(week_active)
        self.assertTrue(any(x.startswith("active_words=40") for x in self.details(r, "COUNT")))
        r = self.sk(total)
        self.assertTrue(any(x.startswith("active_words=") for p in r.violations if p.where == "total" for x in [p.detail]))

    def test_intro_and_synthesis_ranges(self):
        def mut(sk):
            sk["assign"] = [a for a in sk["assign"] if not (a["w"] == 2 and a["role"] == "active" and a["d"] == 4)]
        r = self.sk(mut)
        self.assertTrue(any(p.where == "w002" and p.detail.startswith("active_words=19") for p in r.violations))

    def test_assignment_weeks_1_to_16_totals(self):
        def mut(sk):
            for a in sk["assign"]:
                if a["w"] in (5, 6, 7, 8) and a["role"] == "passive":
                    a["role"] = "active"
        r = self.sk(mut)
        self.assertTrue(any(p.where == "assign_1_16" for p in r.violations if p.code == "COUNT"))

    def test_day_split(self):
        def mut(sk):
            for a in sk["assign"]:
                if a["w"] == 6 and a["role"] == "active" and a["d"] == 2:
                    a["d"] = 1
        r = self.sk(mut)
        self.assertTrue(any(x.startswith("day1_active=8") or x.startswith("day2_active") for x in self.details(r, "COUNT")), self.details(r, "COUNT"))

    def test_pattern_needs_order_and_unknown(self):
        def later(sk):
            sk["weeks"][4]["patterns"][0]["needs"] = [sk["assign"][-1]["lemma"]]

        def unknown(sk):
            sk["weeks"][4]["patterns"][0]["needs"] = ["zzyx"]

        def fine(sk):
            sk["weeks"][4]["patterns"][0]["needs"] = [sk["assign"][0]["lemma"], "lemma0100"]
        self.assertTrue(any(x.startswith("needs=") and "pattern_o" in x for x in self.details(self.sk(later), "ORDER")))
        self.assertTrue(any(x.startswith("needs=zzyx") for x in self.details(self.sk(unknown), "UNKNOWN_TOKEN")))
        self.assertEqual(self.sk(fine).violations, [])

    def test_canada_note_every_two_weeks_from_week_8(self):
        def mut(sk):
            for w in (10, 11):
                sk["weeks"][w - 1]["scene"]["canada"] = []
        r = self.sk(mut)
        self.assertIn("no_canada_note_in_weeks_10_11", self.details(r, "SCHEMA"))

    def test_can_do_and_pattern_text_for_weeks_1_to_16(self):
        def mut(sk):
            sk["weeks"][2]["can_do"] = ["한 줄뿐"]
            del sk["weeks"][3]["patterns"][0]["grammar_ko"]
        r = self.sk(mut)
        self.assertIn("can_do_needs_2_korean_lines", self.details(r, "SCHEMA"))
        self.assertIn("grammar_ko_must_be_2_to_4_short_lines", self.details(r, "SCHEMA"))

    def test_id_ranges_overlap_and_limits(self):
        def overlap(sk):
            sk["id_ranges"]["A2"]["words"] = ["w0090", "w0250"]

        def limit(sk):
            sk["id_ranges"]["A4"]["sentences"] = ["s0750", "s1200"]
        self.assertTrue(any(x.startswith("words_ranges_overlap") for x in self.details(self.sk(overlap), "SCHEMA")))
        self.assertTrue(any(x.startswith("sentences_range_outside_R1_limits") for x in self.details(self.sk(limit), "SCHEMA")))

    def test_missing_id_ranges_is_schema(self):
        def mut(sk):
            del sk["id_ranges"]
        self.assertIn("id_ranges_missing", self.details(self.sk(mut), "SCHEMA"))

    def test_skeleton_missing_file(self):
        self.root.mkdir(exist_ok=True)
        r = chk.run_check(str(self.root), skeleton=True)
        self.assertIn("missing", self.details(r, "SCHEMA"))


class Assignment(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def res(self, mutate=None):
        ts.write_course(self.root, mutate)
        return chk.run_check(str(self.root), strict=True, lexicon_from="skeleton")

    def details(self, r, code="SCHEMA"):
        return [p.detail for p in r.violations if p.code == code]

    def test_good_mini_passes_with_lexicon_from_skeleton(self):
        code, lines = ts.check("--in", ts.FIX / "good_mini", "--strict", "--lexicon-from", "skeleton")
        self.assertEqual(code, 0, lines)

    def test_extra_and_missing_words(self):
        def extra(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0050", "bus", "n", "버스", "bʌs", 4))

        def missing(d):
            d["weeks/w001.json"]["words"] = d["weeks/w001.json"]["words"][:-1]
        self.assertIn("word_not_in_assignment", self.details(self.res(extra)))
        self.assertIn("assigned_word_missing", self.details(self.res(missing)))

    def test_lemma_pos_role_day_must_match(self):
        def lemma(d):
            ts.find(d, 1, "words", "w0001")["en"] = "hullo"

        def day(d):
            ts.find(d, 1, "words", "w0001")["d"] = 2
        self.assertIn("lemma_differs_from_assignment", self.details(self.res(lemma)))
        self.assertIn("pos_role_or_day_differs_from_assignment", self.details(self.res(day)))

    def test_ids_must_be_in_the_authors_range(self):
        def mut(d):
            d["weeks/w001.json"]["sentences"][0]["id"] = "s0900"
        self.assertIn("id_outside_author_range", self.details(self.res(mut)))

    def test_lexicon_from_skeleton_needs_the_skeleton(self):
        ts.write_course(self.root)
        (self.root / "skeleton.json").unlink()
        r = chk.run_check(str(self.root), lexicon_from="skeleton")
        self.assertIn("needed_for_lexicon_from_skeleton", self.details(r))


class ItemsAndReview(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name) / "m"
        ts.write_course(self.root)
        self.tsv = Path(self.tmp.name) / "r.tsv"

    def tearDown(self):
        self.tmp.cleanup()

    def rows(self):
        course = cc.Course(str(self.root)).load()
        return cc.count_items(course, sorted(course.weeks))

    def write(self, rows, header="id\ttype\tverdict\tissue\tfix"):
        self.tsv.write_text(header + "\n" + "\n".join("\t".join(r) for r in rows) + "\n", encoding="utf-8")

    def full(self, verdict="OK"):
        return [(i, k, verdict, "", "") for k, i in self.rows()]

    def test_count_items(self):
        code, lines = run(self.root, "--count-items")
        self.assertEqual(code, 0)
        self.assertEqual(lines[0], "ITEMS weeks=1-4 word=23 pattern=5 sentence=38 dialogue_line=9 total=75")

    def test_count_items_with_weeks(self):
        code, lines = run(self.root, "--count-items", "--weeks", "1-1")
        self.assertEqual(lines[0], "ITEMS weeks=1-1 word=13 pattern=2 sentence=17 dialogue_line=3 total=35")

    def test_review_ok_counts_c_and_m(self):
        rows = self.full()
        rows[0] = (rows[0][0], rows[0][1], "M", "x", "")
        self.write(rows)
        code, lines = run(self.root, "--review", self.tsv)
        self.assertEqual((code, lines[-1]), (0, "REVIEW_OK rows=75 C=0 M=1"))

    def test_review_strict_fails_on_c(self):
        rows = self.full()
        rows[3] = (rows[3][0], rows[3][1], "C", "x", "")
        self.write(rows)
        code, lines = run(self.root, "--review", self.tsv)
        self.assertEqual(code, 0)
        code, lines = run(self.root, "--review", self.tsv, "--strict")
        self.assertEqual(code, 1)
        self.assertTrue(lines[0].startswith("REVIEW_FAIL"))

    def test_review_missing_extra_duplicate_bad_verdict_wrong_type(self):
        full = self.full()
        cases = {
            "missing": full[:-1],
            "extra": full + [("s9999", "sentence", "OK", "", "")],
            "duplicate": full + [full[0]],
            "verdict": [(full[0][0], full[0][1], "FINE", "", "")] + full[1:],
            "type": [(full[0][0], "sentence", "OK", "", "")] + full[1:],
        }
        for name, rows in cases.items():
            with self.subTest(name=name):
                self.write(rows)
                code, lines = run(self.root, "--review", self.tsv)
                self.assertEqual(code, 1, lines)
                self.assertTrue(lines[0].startswith("REVIEW_FAIL"), lines)

    def test_review_bad_header_and_unreadable(self):
        self.write(self.full(), header="a\tb\tc")
        self.assertEqual(run(self.root, "--review", self.tsv)[0], 1)
        code, lines = run(self.root, "--review", Path(self.tmp.name) / "nope.tsv")
        self.assertEqual((code, lines[0]), (1, "REVIEW_FAIL tsv_unreadable"))

    def test_review_weeks_selects_rows(self):
        course = cc.Course(str(self.root)).load()
        rows = [(i, k, "OK", "", "") for k, i in cc.count_items(course, [1])]
        self.write(rows)
        code, lines = run(self.root, "--review", self.tsv, "--weeks", "1-1")
        self.assertEqual((code, lines[-1]), (0, "REVIEW_OK rows=35 C=0 M=0"))
        code, lines = run(self.root, "--review", self.tsv)
        self.assertEqual(code, 1)


class Static(unittest.TestCase):
    def test_tools_are_offline_and_stdlib_only(self):
        # the words are assembled so that this file does not contain them itself (a grep over *.py must find 0 lines)
        pat = re.compile("|".join(["req" + "uests", "url" + "lib", "http" + r"\.cli" + "ent", "sock" + "et"]))
        for p in ts.TOOLS.glob("*.py"):
            if p.name.startswith("test_") or p.name == "tool_support.py":
                continue
            self.assertIsNone(pat.search(p.read_text(encoding="utf-8")), p.name)

    def test_tatoeba_database_is_opened_read_only(self):
        for name in ("tatoeba_fit.py", "check_course.py"):
            self.assertIn("mode=ro", (ts.TOOLS / name).read_text(encoding="utf-8"))

    def test_fixtures_are_in_sync_with_the_generator(self):
        code, lines, _ = ts.cli("make_fixtures.py", "--check")
        self.assertEqual(code, 0, lines)

    def test_fixture_folders_exist(self):
        for name in ["good_mini"] + list(ts.mf.BAD):
            self.assertTrue((ts.FIX / name / "weeks" / "w001.json").is_file(), name)


if __name__ == "__main__":
    unittest.main()
