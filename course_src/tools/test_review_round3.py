# -*- coding: utf-8 -*-
"""Review round 3 (K1 follow-up): registered acronyms read letter by letter, CLI default `--lexicon-from skeleton` and the
acronym-entry bypass (FRIEND), the identifier context of numbers, pos chunk/phr on one-word headwords, pronunciation hints in a
word's `say`, FORM_SUSPECT of multi-word headwords. Every bypass attempt must be a violation, every honest case must pass."""
import json
import unittest
from pathlib import Path

import tool_support as ts
import check_course as chk
import course_common as cc
import forms_en
import numbers_en as ne


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def res(self, mutate=None, **kw):
        ts.write_course(self.root, mutate)
        return chk.run_check(str(self.root), strict=True, **kw)

    def codes(self, r):
        return sorted({p.code for p in r.violations})

    def details(self, r, code):
        return [p.detail for p in r.violations if p.code == code]

    def sent(self, en, **kw):
        w = kw.pop("w", 1)
        s = ts.mf.S("s0990", en, kw.pop("ko", "새 문장이에요 하나."), kw.pop("d", 4), **kw)
        return lambda d: d["weeks/w%03d.json" % w]["sentences"].append(s)

    def word(self, en, say="", pos="n", w=1, d=1, wid="w0090", ko="새 낱말"):
        return lambda dd: dd["weeks/w%03d.json" % w]["words"].append(ts.mf.W(wid, en, pos, ko, "x", d, say=say))

    @staticmethod
    def both(*muts):
        def mut(d):
            for m in muts:
                m(d)
        return mut

    def acronym_course(self, en, say, say1, say2, w=1, d=1, sent_w=1):
        """the acronym entry (week w, day d) and two sentences (week sent_w, day 4) that use it with the readings say1 / say2."""
        sents = [ts.mf.S("s0990", "Hello, %s." % en, "새 문장이에요 하나.", 4, say=say1),
                 ts.mf.S("s0991", "Hi, %s." % en, "새 문장이에요 둘.", 4, say=say2)]

        def mut(dd):
            dd["weeks/w%03d.json" % w]["words"].append(ts.mf.W("w0090", en, "n", "새 낱말", "x", d, say=say))
            dd["weeks/w%03d.json" % sent_w]["sentences"].extend(sents)
        return mut


class AcronymLetterReadings(Base):
    """1. a registered acronym (en in capitals) may be read letter by letter in a sentence; its letters need no lexicon words."""

    def test_atm_and_sin_letter_readings_pass_in_sentences(self):
        for en, say in (("ATM", "ay tee em"), ("ATM", "a t m"), ("SIN", "ess eye en"), ("SIN", "s i n"), ("ATM", "a tee m")):
            r = self.res(self.acronym_course(en, say, "Hello, %s." % say, "Hi, %s." % say))
            self.assertEqual([(p.code, p.where, p.detail) for p in r.violations], [], (en, say))

    def test_letter_names_that_are_later_words_are_exempt(self):
        # "eye" is a word of week 4 (day 4); the letter reading "ess eye en" in week 1 is no use of that word
        late = lambda d: d["weeks/w004.json"]["words"].append(ts.mf.W("w0399", "eye", "n", "눈", "aɪ", 4))  # noqa: E731
        r = self.res(self.both(late, self.acronym_course("SIN", "ess eye en", "Hello, ess eye en.", "Hi, ess eye en.")))
        self.assertEqual([p for p in r.violations if p.code == "ORDER"], [])
        # ... but the word reading of an acronym is: SIN read as "eye" (one word, other letter) is not even a reading
        r = self.res(self.both(late, self.acronym_course("EYE", "eye", "Hello, eye.", "Hi, eye.")))
        self.assertTrue(any(x.startswith("acronym_reading_token=eye") for x in self.details(r, "ORDER")), self.codes(r))

    def test_a_word_reading_of_an_acronym_still_passes(self):
        r = self.res(self.acronym_course("SIN", "sin", "Hello, sin.", "Hi, sin."))
        self.assertEqual([(p.code, p.where, p.detail) for p in r.violations], [])

    def test_the_letter_reading_is_not_exempt_for_other_words(self):
        r = self.res(self.acronym_course("ATM", "ay tee em", "Hello, ay tee em.", "Hi, ay tee eye."))
        self.assertIn("NUM_SAY", self.codes(r))                         # eye is not the name of the letter m
        r = self.res(self.acronym_course("ATM", "ay tee em", "Hello, ay tee em.", "Hi, friend."))
        self.assertIn("NUM_SAY", self.codes(r))

    def test_item_tokens_exempt_letters_and_keep_the_acronym(self):
        lex = cc.Lexicon()
        lex.add("w1", "ATM", "n", "active", 11, say="ay tee em")
        acr = lex.acronym_map()
        self.assertEqual(cc.item_tokens("Hello, ATM.", "Hello, ay tee em.", acr, lex.is_word), ["hello", "ATM"])
        soft = []
        cc.item_tokens("Hello, ATM.", "Hello, ay tee em.", acr, lex.is_word, soft)
        self.assertEqual(soft, [])                                      # the letters are no words at all, not even softly
        lex.add("w3", "TV", "n", "active", 11, say="t v")
        self.assertEqual(cc.item_tokens("Hello, TV.", "Hello, t v.", lex.acronym_map(), lex.is_word), ["hello", "TV"])
        # a reading that is not the entry's say is no reading of the acronym: nothing is exempt (and NUM_SAY says so)
        self.assertEqual(cc.item_tokens("Hello, ATM.", "Hello, a t m.", acr, lex.is_word), ["hello", "ATM", "a", "t", "m"])
        lex.add("w2", "SIN", "n", "active", 11, say="sin")
        soft = []
        self.assertEqual(cc.item_tokens("Hello, SIN.", "Hello, sin.", lex.acronym_map(), lex.is_word, soft), ["hello", "SIN"])
        self.assertEqual(soft, ["sin"])                                 # the word reading is checked softly, never registered

    def test_acronym_not_assigned_yet_is_order(self):
        # files mode: the entry is on day 3 of week 4, the sentences are on day 4 of week 1
        r = self.res(self.acronym_course("ATM", "ay tee em", "Hello, ay tee em.", "Hi, ay tee em.", w=4, d=3))
        self.assertIn("token=ATM", [x.split(" ")[0] for x in self.details(r, "ORDER")])
        self.assertNotIn("UNKNOWN_TOKEN", self.codes(r))
        # the same with the letters a t m
        r = self.res(self.acronym_course("SIN", "ess eye en", "Hello, a t m.".replace("a t m", "ess eye en"), "Hi, s i n.", w=4, d=3))
        self.assertTrue(any(x.startswith("token=SIN") for x in self.details(r, "ORDER")))

    def test_acronym_assigned_in_the_skeleton_only_is_order_too(self):
        def mut(d):
            d["skeleton.json"]["assign"].append({"id": "w0097", "lemma": "ATM", "pos": "n", "role": "active", "w": 4, "d": 3})
            for m in (self.sent("Hello, ATM.", say="Hello, ay tee em.", ko="새 문장이에요 하나."),
                      self.sent("Hi, ATM.", say="Hi, a t m.", ko="새 문장이에요 둘.")):
                m(d)
            d["weeks/w001.json"]["sentences"][-1]["id"] = "s0991"
        ts.write_course(self.root, mut)
        r = chk.run_check(str(self.root), (1, 1), True, False, "skeleton")
        self.assertIn("token=ATM", [x.split(" ")[0] for x in self.details(r, "ORDER")])
        self.assertNotIn("UNKNOWN_TOKEN", self.codes(r))

    def test_unregistered_acronym_is_still_unknown(self):
        r = self.res(self.sent("Hello, ABC.", say="Hello, a b c."))
        self.assertEqual(self.codes(r), ["UNKNOWN_TOKEN"])

    def test_corpus_of_registered_acronym_sentences(self):
        with open(ts.FIX / "forms_corpus.json", encoding="utf-8") as f:
            data = json.load(f)
        self.assertGreaterEqual(len(data["acronym_sentences"]), 4)
        self.assertGreaterEqual(len(data["acronym_wrong"]), 3)
        for kind, items in (("pass", data["acronym_sentences"]), ("fail", data["acronym_wrong"])):
            for it in items:
                lex = cc.Lexicon()
                lex.add("w1", it["acronym"], "n", "active", 11, say=it["acronym_say"])
                acr = lex.acronym_map()
                toks = cc.item_tokens(it["en"], it["say"], acr, lex.is_word)
                ok = ne.say_matches(it["en"], it["say"], acr, lex.is_word)
                if kind == "pass":
                    self.assertTrue(ok, it)
                    self.assertIn(it["acronym"], toks, it)
                    self.assertEqual([t for t in toks if t != it["acronym"] and t not in ("hello", "hi", "use", "the", "is", "here", "my")], [], it)
                else:
                    self.assertFalse(ok, it)


class LexiconFromDefaultAndAcronymEntryBypass(Base):
    """2. CLI default `--lexicon-from skeleton` (files only without skeleton.json); an acronym entry registers the acronym only."""

    def test_default_is_skeleton_for_check_and_build(self):
        def extra(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "cat", "n", "고양이", "kæt", 1))     # not in the assignment table
        ts.write_course(self.root, extra)
        code, lines = ts.check("--in", self.root, "--strict")
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "CHECK_FAIL SCHEMA")
        self.assertTrue(any("word_not_in_assignment" in ln for ln in lines), lines)
        code, lines = ts.check("--in", self.root, "--strict", "--lexicon-from", "files")
        self.assertFalse(any("word_not_in_assignment" in ln for ln in lines), lines)
        code, lines, _ = ts.cli("build_course.py", "--in", self.root, "--check")
        self.assertEqual(code, 1)
        self.assertTrue(any("word_not_in_assignment" in ln for ln in lines), lines)

    def test_without_skeleton_json_it_falls_back_to_files_and_says_so(self):
        ts.write_course(self.root)
        (self.root / "skeleton.json").unlink()
        code, lines = ts.check("--in", self.root, "--strict")
        self.assertEqual(code, 0, lines)
        self.assertEqual([ln for ln in lines if ln.startswith("LEXICON_FROM")], [lines[-2]])
        self.assertIn("files", lines[-2])
        self.assertTrue(lines[-1].startswith("CHECK_OK"))
        code, lines, _ = ts.cli("build_course.py", "--in", self.root, "--check")
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(ln.startswith("LEXICON_FROM files") for ln in lines))

    def test_the_fallback_note_never_comes_before_check_fail(self):
        ts.write_course(self.root, lambda d: d["weeks/w001.json"]["sentences"].__setitem__(0, ts.mf.S("s0001", "Hello, zzyx.", "안녕하세요.", 1)))
        (self.root / "skeleton.json").unlink()
        code, lines = ts.check("--in", self.root, "--strict")
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "CHECK_FAIL UNKNOWN_TOKEN")

    def test_explicit_skeleton_without_the_file_still_fails(self):
        ts.write_course(self.root)
        (self.root / "skeleton.json").unlink()
        code, lines = ts.check("--in", self.root, "--strict", "--lexicon-from", "skeleton")
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "CHECK_FAIL SCHEMA")

    def test_good_mini_has_no_fallback_note(self):
        code, lines = ts.check("--in", ts.FIX / "good_mini", "--strict")
        self.assertEqual(code, 0, lines)
        self.assertFalse(any(ln.startswith("LEXICON_FROM") for ln in lines))

    def test_friend_as_an_acronym_entry_does_not_bring_the_word_in(self):
        # FRIEND (a word of week 4) registered early as an acronym with the reading "friend"
        for say in ("friend", "f r i e n d"):
            r = self.res(self.both(self.word("FRIEND", say, wid="w0098"), self.sent("Hello, friend, Min.")))
            self.assertTrue(any(x.startswith("token=friend") for x in self.details(r, "ORDER")), (say, self.codes(r)))
        r = self.res(self.both(self.word("FRIEND", "friend", wid="w0098"), self.sent("Hello, FRIEND.", say="Hello, friend.")))
        self.assertTrue(any(x.startswith("acronym_reading_token=friend") for x in self.details(r, "ORDER")), self.codes(r))

    def test_friend_acronym_entry_itself_is_order_when_the_word_is_later(self):
        r = self.res(self.word("FRIEND", "friend", wid="w0098"))
        self.assertTrue(any(x.startswith("acronym_reading_token=friend") for x in self.details(r, "ORDER")), self.codes(r))

    def test_apple_as_an_acronym_entry_does_not_bring_the_word_in(self):
        r = self.res(self.both(self.word("APPLE", "apple", wid="w0098"), self.sent("Hello, apple.")))
        self.assertIn("token=apple", self.details(r, "UNKNOWN_TOKEN"))

    def test_lexicon_registers_the_acronym_itself_only(self):
        lex = cc.Lexicon()
        lex.add("w1", "FRIEND", "n", "active", 11, say="friend")
        self.assertEqual(lex.min_o("FRIEND"), 11)
        self.assertIsNone(lex.min_o("friend"))
        self.assertFalse(lex.is_word("friend"))
        self.assertEqual(lex.used_words(["hello", "FRIEND"], 99), {"w1"})
        self.assertEqual(lex.used_words(["friend"], 99), set())


class IdentifierContext(unittest.TestCase):
    """3. an identifier word counts only when no verb / determiner stands between it and the number."""

    def ok(self, en, say):
        self.assertTrue(ne.say_matches(en, say), (en, say))

    def no(self, en, say):
        self.assertFalse(ne.say_matches(en, say), (en, say))

    def test_verb_between_is_no_identifier_context(self):
        self.no("The bus has 100 seats.", "The bus has one oh oh seats.")
        self.ok("The bus has 100 seats.", "The bus has one hundred seats.")
        self.no("The room has 305 chairs.", "The room has three oh five chairs.")
        self.no("The flight has 305 seats.", "The flight has three zero five seats.")
        self.no("Bus 305 has 100 seats.", "Bus three oh five has one oh oh seats.")
        self.ok("Bus 305 has 100 seats.", "Bus three oh five has one hundred seats.")

    def test_determiner_between_is_no_identifier_context(self):
        self.no("My room is the 305.", "My room is the three oh five.")
        self.no("Room, a 305.", "Room, a three oh five.")
        self.no("The code has many 305.", "The code has many three oh five.")

    def test_no_at_the_start_of_a_sentence_is_not_an_identifier(self):
        self.no("No, 305 people.", "No, three oh five people.")
        self.ok("No, 305 people.", "No, three hundred five people.")
        self.no("No 305 people.", "No three oh five people.")
        self.no("Yes. No, 305 people.", "Yes. No, three oh five people.")

    def test_no_dot_and_hash_are_identifiers(self):
        self.ok("Room No. 305 is big.", "Room No. three oh five is big.")
        self.ok("Room #305.", "Room number three oh five.")
        self.ok("Take No. 305.", "Take No. three oh five.")
        self.ok("It is #305.", "It is number three hundred five.")

    def test_one_be_verb_is_allowed(self):
        self.ok("My room is 305.", "My room is three oh five.")
        self.ok("My room number is 305.", "My room number is three oh five.")
        self.ok("The room is 305.", "The room is three oh five.")
        self.ok("The code is 4821.", "The code is four eight two one.")
        self.ok("My room is not 305.", "My room is not three oh five.")
        self.no("My room is is 305.", "My room is is three oh five.")
        self.ok("Room 305.", "Room three oh five.")
        self.ok("Take bus 305 now.", "Take bus three oh five now.")

    def test_say_sentence_follows_the_same_context(self):
        self.assertEqual(ne.say_sentence("My room is 305."), "My room is three oh five.")
        self.assertEqual(ne.say_sentence("The bus has 100 seats."), "The bus has one hundred seats.")
        self.assertEqual(ne.say_sentence("No, 305 people."), "No, three hundred five people.")


class MultiWordPos(Base):
    """4. pos chunk / phr only for headwords of several words."""

    def test_chunk_and_phr_on_one_word_are_a_schema_violation(self):
        for pos in ("chunk", "phr"):
            r = self.res(lambda d, pos=pos: ts.find(d, 1, "words", "w0001").update(pos=pos, forms=[{"f": "helloing", "pat": "p_my_name"}]))
            self.assertIn("pos_%s_needs_a_multi_word_headword" % pos, self.details(r, "SCHEMA"))

    def test_chunk_and_phr_on_several_words_are_fine(self):
        for pos in ("chunk", "phr"):
            r = self.res(self.word("good evening", pos=pos, w=4, d=2, wid="w0399", ko="좋은 저녁"))
            self.assertEqual(self.details(r, "SCHEMA"), [], pos)

    def test_forms_en_gives_a_one_word_chunk_no_regular_form(self):
        self.assertFalse(forms_en.is_derived("hello", "helloing", "chunk"))
        self.assertFalse(forms_en.is_derived("hello", "hellos", "phr"))
        self.assertTrue(forms_en.is_derived("good morning", "good mornings", "chunk"))
        self.assertTrue(forms_en.is_derived("cat", "cats", "n"))

    def test_skeleton_assignment_too(self):
        def mut(sk):
            sk["assign"][0]["pos"] = "chunk"
            sk["assign"][0]["lemma"] = "hello"
        ts.write_skeleton_course(self.root, mut)
        r = chk.run_check(str(self.root), skeleton=True, strict=True)
        self.assertTrue(any("needs_a_multi_word_headword" in p.detail for p in r.violations))


class WordSayHints(Base):
    """5. a word's `say` may be a pronunciation hint: its letters, itself (OK -> okay) or words that are learned by then."""

    def say_bad(self, r):
        return "say_differs_from_en" in self.details(r, "NUM_SAY")

    def test_ok_okay_and_pm_p_m(self):
        self.assertFalse(self.say_bad(self.res(self.word("OK", "okay", "interj"))))
        self.assertFalse(self.say_bad(self.res(self.word("pm", "p m", "adv"))))
        self.assertFalse(self.say_bad(self.res(self.word("pm", "pee em", "adv"))))
        self.assertFalse(self.say_bad(self.res(self.word("hello", "hello hello", "interj", wid="w0091"))))

    def test_no_other_word_rides_along(self):
        self.assertTrue(self.say_bad(self.res(self.word("OK", "friend", "interj"))))
        self.assertTrue(self.say_bad(self.res(self.word("OK", "okay friend", "interj"))))
        self.assertTrue(self.say_bad(self.res(self.word("pm", "p friend", "adv"))))
        self.assertTrue(self.say_bad(self.res(self.word("hello", "banana", "interj", wid="w0091"))))

    def test_spelling_hint_of_another_word_must_be_assigned_by_then(self):
        # read -> red: red is no word of the course (unknown), a later word (week 4 day 4), the same day, or an earlier one
        r = self.res(self.word("read", "red", "v"))
        self.assertTrue(self.say_bad(r), "red unknown")
        late = self.both(self.word("red", "", "adj", w=4, d=4, wid="w0398", ko="빨간"), self.word("read", "red", "v"))
        self.assertTrue(self.say_bad(self.res(late)), "red later")
        early = self.both(self.word("red", "", "adj", w=1, d=1, wid="w0099", ko="빨간"), self.word("read", "red", "v", w=1, d=2, wid="w0098", ko="읽다"))
        self.assertFalse(self.say_bad(self.res(early)), "red learned before")
        later_read = self.both(self.word("red", "", "adj", w=1, d=3, wid="w0099", ko="빨간"), self.word("read", "red", "v", w=1, d=2, wid="w0098", ko="읽다"))
        self.assertTrue(self.say_bad(self.res(later_read)), "red one day later")

    def test_the_hint_never_registers_a_word(self):
        r = self.res(self.both(self.word("OK", "okay", "interj"), self.sent("Hello, okay.")))
        self.assertIn("token=okay", self.details(r, "UNKNOWN_TOKEN"))

    def test_existing_letter_rule_and_numbers_still_hold(self):
        self.assertFalse(self.say_bad(self.res(self.word("A", "ay", "n"))))
        self.assertTrue(self.say_bad(self.res(self.word("A", "bee", "n"))))


class MultiWordFormSuspect(Base):
    """6. a form of a multi-word headword that keeps the other words is no FORM_SUSPECT because of those words."""

    def chunk(self, forms, lemma="good morning"):
        return lambda d: d["weeks/w004.json"]["words"].append(
            ts.mf.W("w0399", lemma, "chunk", "좋은 아침이", "", 4, forms=[{"f": f, "pat": "p_good_x"} for f in forms]))

    def test_good_mornings(self):
        r = self.res(self.chunk(["good mornings"]))
        self.assertEqual(self.details(r, "FORM_SUSPECT"), [])

    def test_the_changed_word_is_still_checked(self):
        r = self.res(self.chunk(["good banana"]))
        self.assertIn("FORM_SUSPECT", self.codes(r))
        r = self.res(self.chunk(["bad morning"]))
        self.assertIn("FORM_SUSPECT", self.codes(r))
        r = self.res(self.chunk(["good names"]))                         # name is a headword of another word
        self.assertIn("FORM_SUSPECT", self.codes(r))

    def test_the_constituent_is_not_registered_as_a_form_of_the_chunk_in_check_forms(self):
        # a word whose alt is the spelling "good" would clash with the form of "good morning" only through `mornings`
        r = self.res(self.chunk(["good mornings"]))
        self.assertEqual([x for x in self.details(r, "FORM_SUSPECT") if "good" in x], [])


if __name__ == "__main__":
    unittest.main()
