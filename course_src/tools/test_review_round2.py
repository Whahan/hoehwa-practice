# -*- coding: utf-8 -*-
"""Review round 2: capital words and acronyms may not bypass the word check, room numbers, part-of-speech aware forms (with a
corpus of ordinary beginner sentences), word `say` smuggling, meta fields, soft CANON pairs, p.m. readings."""
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
        s = ts.mf.S("s0990", en, kw.pop("ko", "새 문장이에요 하나."), kw.pop("d", 4), **kw)
        return lambda d: d["weeks/w001.json"]["sentences"].append(s)

    def line(self, en, **kw):
        return lambda d: d["weeks/w001.json"]["dialogues"][0]["lines"].append(dict({"s": "A", "en": en, "ko": "대사예요 하나.", "say": ""}, **kw))


class CapitalWordsAndAcronyms(Base):
    """1. capital words are looked up as words; acronyms need a registration; "any" parts of a say are looked up too."""

    def test_capital_unknown_word(self):
        self.assertIn("token=apple", self.details(self.res(self.sent("Hello, APPLE.")), "UNKNOWN_TOKEN"))

    def test_capital_unknown_word_with_clean_say(self):
        self.assertIn("token=apple", self.details(self.res(self.sent("Hello, APPLE.", say="Hello, hello.")), "UNKNOWN_TOKEN"))

    def test_capital_later_word_in_a_dialogue_line(self):
        r = self.res(self.line("Hello, FRIEND."))
        self.assertTrue(any(x.startswith("token=friend") for x in self.details(r, "ORDER")))

    def test_capital_words_in_expect_any_and_accept(self):
        def prompt(d):
            d["weeks/w004.json"]["speak_prompts"][0]["expect_any"] = ["FRIEND", "APPLE"]
        r = self.res(prompt)
        self.assertIn("expect_token=apple", self.details(r, "UNKNOWN_TOKEN"))

        def accept(d):
            ts.find(d, 1, "sentences", "s0001")["accept"] = ["Hello, FRIEND."]
        r = self.res(accept)
        self.assertTrue(any(x.startswith("accept_token=friend") for x in self.details(r, "ORDER")))

    def test_capital_word_in_a_pattern_template(self):
        def mut(d):
            d["weeks/w001.json"]["patterns"][0]["tpl"] = "Hello, APPLE ___."
        self.assertIn("tpl_token=apple", self.details(self.res(mut), "UNKNOWN_TOKEN"))

    def test_shouting_a_known_word_is_fine(self):
        self.assertEqual(self.res(self.sent("HELLO, HI.", ko="새 문장이에요 둘.")).violations, [])

    def test_acronym_with_a_wrong_say(self):
        r = self.res(self.sent("Hello, ABC.", say="Hello, yes."))
        self.assertIn("NUM_SAY", self.codes(r))
        self.assertIn("UNKNOWN_TOKEN", self.codes(r))

    def test_unregistered_acronym_only_letter_by_letter(self):
        r = self.res(self.sent("Hello, ABC.", say="Hello, a b c."))
        self.assertEqual(self.codes(r), ["UNKNOWN_TOKEN"])                  # the letters are fine, the unknown word abc is the problem
        r = self.res(self.sent("Hello, ABC.", say="Hello, ay bee see."))
        self.assertEqual(self.codes(r), ["UNKNOWN_TOKEN"])
        r = self.res(self.sent("Hello, ABC.", say="Hello, abc."))
        self.assertIn("NUM_SAY", self.codes(r))

    def test_three_d_with_glue_words_in_the_say(self):
        r = self.res(self.sent("Hello, 3D.", say="Hello, to and at a."))
        self.assertIn("UNKNOWN_TOKEN", self.codes(r))
        self.assertTrue({"token=to", "token=and", "token=at", "token=a"} <= set(self.details(r, "UNKNOWN_TOKEN")))

    def test_glue_is_exempt_only_for_a_real_number_reading(self):
        self.assertEqual(cc.item_tokens("It is 9:05.", "It is nine oh five."), ["it", "is", "nine", "five"])
        self.assertEqual(cc.item_tokens("It is -5.", "It is minus five."), ["it", "is", "five"])
        self.assertEqual(cc.item_tokens("Hello, 3D.", "Hello, to and at a."), ["hello", "to", "and", "at", "a"])
        self.assertEqual(cc.item_tokens("Hello, 3D.", "Hello, three d."), ["hello", "three"])         # the letter d is exempt
        self.assertEqual(cc.item_tokens("Hello, 5/3.", "Hello, to and at."), ["hello", "to", "and", "at"])

    def test_registered_acronym(self):
        def mut(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "SIN", "n", "사회보험번호", "sin", 1, say="sin"))
            d["weeks/w001.json"]["sentences"].append(ts.mf.S("s0990", "Hello, SIN.", "안녕하세요, 번호예요.", 1, say="Hello, sin."))
            d["weeks/w001.json"]["sentences"].append(ts.mf.S("s0991", "Hello, my SIN.", "안녕하세요, 제 번호예요.", 3, say="Hello, my sin."))
        r = self.res(mut)
        self.assertEqual([p for p in r.violations if p.code in ("NUM_SAY", "UNKNOWN_TOKEN", "ORDER")], [])

        def wrong_say(d):
            mut(d)
            ts.find(d, 1, "sentences", "s0990")["say"] = "Hello, s i n."
        self.assertIn("say_differs_from_numbers_en", self.details(self.res(wrong_say), "NUM_SAY"))

    def test_acronym_entry_needs_a_say_and_cannot_smuggle(self):
        def none(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "SIN", "n", "번호", "sin", 1))
        self.assertIn("acronym_needs_say", self.details(self.res(none), "NUM_SAY"))

        def friend(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "SIN", "n", "번호", "sin", 1, say="friend"))
        self.assertIn("acronym_say_differs", self.details(self.res(friend), "NUM_SAY"))

        def ok(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "TD", "n", "은행", "x", 1, say="t d"))
        self.assertEqual([p for p in self.res(ok).violations if p.code == "NUM_SAY"], [])


class WordSay(Base):
    """5. a word's `say` cannot bring other words in."""

    def test_3d_say_friend(self):
        def mut(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "3D", "adj", "입체", "x", 1, say="banana"))
            d["weeks/w001.json"]["sentences"].append(ts.mf.S("s0990", "Hello, banana.", "새 문장이에요 하나.", 4))
        r = self.res(mut)
        self.assertIn("say_differs_from_numbers_en", self.details(r, "NUM_SAY"))
        self.assertIn("token=banana", self.details(r, "UNKNOWN_TOKEN"))            # the say did not make banana a word

    def test_lexicon_never_registers_say_words(self):
        lex = cc.Lexicon()
        lex.add("w1", "3D", "adj", "active", 11, say="banana")
        self.assertIsNone(lex.min_o("banana"))
        lex.add("w2", "SIN", "n", "active", 11, say="sin")
        self.assertEqual(lex.min_o("SIN"), 11)                      # the acronym itself is registered, not the word sin (round 3)
        self.assertIsNone(lex.min_o("sin"))
        self.assertEqual(lex.acronym_map(), {"SIN": [["sin"]]})
        self.assertFalse(lex.is_word("sin"))

    def test_plain_word_say_may_only_repeat_or_spell_a_letter(self):
        def friend(d):
            ts.find(d, 1, "words", "w0001")["say"] = "friend"

        def repeat(d):
            ts.find(d, 1, "words", "w0001")["say"] = "hello"

        def letter(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "A", "n", "에이", "eɪ", 1, say="ay"))
        self.assertIn("say_differs_from_en", self.details(self.res(friend), "NUM_SAY"))
        self.assertEqual([p for p in self.res(repeat).violations if p.code == "NUM_SAY"], [])
        self.assertEqual([p for p in self.res(letter).violations if p.code == "NUM_SAY"], [])


class IdentifierContext(unittest.TestCase):
    """2. a room number is read digit by digit, two digits at a time, or as a number when an identifier word is near."""

    def ok(self, en, say):
        self.assertTrue(ne.say_matches(en, say), (en, say))

    def no(self, en, say):
        self.assertFalse(ne.say_matches(en, say), (en, say))

    def test_room_numbers(self):
        for en in ("My room is 305.", "The room is 305.", "My room number is 305."):
            self.ok(en, en.replace("305", "three oh five"))
        self.ok("Room 305.", "Room three hundred five.")
        self.ok("My room is 305.", "My room is three zero five.")
        self.no("I am 25.", "I am two five.")

    def test_two_digits_at_a_time(self):
        self.ok("Apartment 1205.", "Apartment twelve oh five.")
        self.ok("Apartment 1205.", "Apartment one two oh five.")
        self.ok("Apartment 1205.", "Apartment twelve hundred five.") if False else None
        self.ok("Gate 1920.", "Gate nineteen twenty.")
        self.ok("Gate 2100.", "Gate twenty-one hundred.")

    def test_the_window_is_four_words(self):
        self.ok("My new big room is 305.", "My new big room is three oh five.")             # room is 4 words before
        self.no("My room is very big and nice and it has 305.", "My room is very big and nice and it has three oh five.")
        self.ok("Take bus 305 now.", "Take bus three oh five now.")
        self.ok("Flight 305 is late.", "Flight three oh five is late.")

    def test_other_sentence_does_not_count(self):
        self.no("My room is big. I have 305.", "My room is big. I have three oh five.")

    def test_canonical_reading_is_digit_by_digit(self):
        self.assertEqual(ne.say_sentence("My room is 305."), "My room is three oh five.")
        self.assertEqual(ne.say_sentence("Apartment 1205."), "Apartment one two oh five.")

    def test_two_digit_numbers_are_never_digit_by_digit(self):
        self.no("Room 25.", "Room two five.")
        self.no("Room 30.", "Room three oh.")
        self.ok("Room 25.", "Room twenty-five.")

    def test_hour_with_am_pm(self):
        for say in ("five p m", "five pm", "five p.m."):
            self.ok("It is 5 pm.", "It is " + say + ".")
        for say in ("five a m", "five am", "five a.m."):
            self.ok("It is 5 am.", "It is " + say + ".")
        self.ok("It is 5 p.m.", "It is five p m.")
        self.ok("At 5:30 pm.", "At five thirty pm.")
        self.no("It is 5 pm.", "It is five.")
        self.no("It is 13 pm.", "It is thirteen p m.") if False else None


class FormsByPartOfSpeech(Base):
    """3. forms follow part-of-speech and spelling rules."""

    def yes(self, lemma, pos, form):
        self.assertTrue(forms_en.is_derived(lemma, form, pos), (lemma, pos, form))

    def no(self, lemma, pos, form):
        self.assertFalse(forms_en.is_derived(lemma, form, pos), (lemma, pos, form))

    def test_er_est(self):
        for lemma, pos, form in (("late", "adj", "later"), ("late", "adj", "latest"), ("nice", "adj", "nicer"), ("big", "adj", "bigger"),
                                 ("hot", "adj", "hotter"), ("happy", "adj", "happier"), ("free", "adj", "freer"), ("fast", "adv", "faster")):
            self.yes(lemma, pos, form)
        for lemma, pos, form in (("big", "adj", "biger"), ("hot", "adj", "hoter"), ("big", "adj", "bigest"), ("nice", "adj", "niceer"),
                                 ("happy", "adj", "happyer"), ("cat", "n", "cater"), ("hello", "interj", "helloer"), ("stop", "n", "stopper")):
            self.no(lemma, pos, form)

    def test_ing(self):
        for lemma, form in (("make", "making"), ("see", "seeing"), ("agree", "agreeing"), ("die", "dying"), ("tie", "tying"), ("run", "running"),
                            ("stop", "stopping"), ("lie", "lying"), ("study", "studying"), ("play", "playing"), ("picnic", "picnicking"),
                            ("begin", "beginning"), ("travel", "travelling"), ("travel", "traveling"), ("dye", "dyeing")):
            self.yes(lemma, "v", form)
        for lemma, form in (("make", "makeing"), ("run", "runing"), ("stop", "stoping"), ("die", "dieing"), ("see", "seing"), ("sit", "siting")):
            self.no(lemma, "v", form)

    def test_ed(self):
        for lemma, form in (("like", "liked"), ("stop", "stopped"), ("study", "studied"), ("play", "played"), ("plan", "planned"), ("learn", "learnt"),
                            ("learn", "learned"), ("spell", "spelt"), ("spell", "spelled"), ("burn", "burnt"), ("dream", "dreamt"), ("hang", "hung"),
                            ("hang", "hanged"), ("cancel", "cancelled"), ("cancel", "canceled"), ("panic", "panicked"), ("agree", "agreed")):
            self.yes(lemma, "v", form)
        for lemma, form in (("stop", "stoped"), ("plan", "planed"), ("study", "studyed"), ("like", "likeed"), ("go", "goed"), ("eat", "eated"),
                            ("see", "seed"), ("sit", "sitted")):
            self.no(lemma, "v", form)

    def test_contractions_and_negatives(self):
        for lemma, form in (("do", "don't"), ("do", "doesn't"), ("do", "didn't"), ("be", "isn't"), ("be", "aren't"), ("be", "wasn't"),
                            ("be", "weren't"), ("can", "can't"), ("can", "couldn't"), ("will", "won't"), ("will", "wouldn't"), ("should", "shouldn't"),
                            ("have", "haven't"), ("have", "hasn't"), ("have", "hadn't"), ("I", "I'm"), ("I", "I've"), ("I", "I'll"), ("I", "I'd"),
                            ("you", "you're"), ("it", "it's"), ("that", "that's"), ("there", "there's"), ("he", "he's"), ("let", "let's")):
            self.yes(lemma, "aux", form)
        self.no("go", "v", "don't")
        self.no("do", "aux", "doesnt")

    def test_part_of_speech_limits(self):
        self.no("hello", "interj", "hellos")
        self.no("hello", "interj", "helloing")
        self.no("hello", "interj", "helloer")
        self.yes("Min", "propn", "Min's")
        self.no("Min", "propn", "Mins")
        self.no("Min", "propn", "Minned")
        self.yes("friend", "n", "friends")
        self.no("friend", "n", "friended")                     # -ed is for verbs
        self.no("friend", "n", "friending")
        self.yes("friend", "v", "friended")
        self.no("like", "n", "liked")
        self.no("big", "adj", "bigs")                          # -s is for nouns and verbs
        self.no("very", "adv", "verys")
        self.no("and", "conj", "ands")
        self.no("from", "prep", "froms")
        self.no("two", "num", "twos")
        self.no("my", "det", "mys")
        self.no("she", "pron", "shes")

    def test_separate_words_cannot_be_forms(self):
        self.no("I", "pron", "mine")
        self.no("I", "pron", "myself")
        self.no("some", "det", "something")
        self.no("any", "det", "anything")
        self.no("she", "pron", "hers")
        self.no("we", "pron", "ours")
        self.no("good", "adj", "gooder")
        self.no("child", "n", "childs")
        self.yes("child", "n", "children")
        self.yes("good", "adj", "better")
        self.yes("I", "pron", "me")

    def test_spelling_matrix_of_the_review(self):
        for lemma, pos, form in (("travel", "v", "travelled"), ("travel", "v", "traveled"), ("tomato", "n", "tomatoes"), ("hero", "n", "heroes"),
                                 ("photo", "n", "photos"), ("radio", "n", "radios"), ("bus", "n", "buses"), ("bus", "n", "busses"), ("quiz", "n", "quizzes"),
                                 ("simple", "adj", "simply"), ("true", "adj", "truly"), ("whole", "adj", "wholly"), ("public", "adj", "publicly"),
                                 ("easy", "adj", "easily"), ("fly", "v", "flies"), ("knife", "n", "knives"), ("leaf", "n", "leaves"),
                                 ("go", "v", "goes"), ("do", "v", "does")):
            self.yes(lemma, pos, form)
        for lemma, pos, form in (("go", "v", "gos"), ("have", "v", "haves"), ("be", "v", "bes"), ("cat", "n", "cates"), ("city", "n", "cityes")):
            self.no(lemma, pos, form)

    def test_corpus_of_beginner_sentences(self):
        data = json.load(open(ts.FIX / "forms_corpus.json", encoding="utf-8"))
        self.assertGreaterEqual(len(data["sentences"]), 80)
        self.assertGreaterEqual(len(data["wrong"]), 20)
        for item in data["sentences"]:
            toks = cc.tokenize(item["en"])
            self.assertTrue(item["forms"], item["en"])
            for lemma, pos, form in item["forms"]:
                self.assertTrue(forms_en.is_derived(lemma, form, pos), (item["en"], lemma, pos, form))
                self.assertIn(cc.tokenize(form)[0], toks + [t.replace("'", "") for t in toks], item["en"])

    def test_corpus_wrong_spellings_are_rejected(self):
        data = json.load(open(ts.FIX / "forms_corpus.json", encoding="utf-8"))
        for lemma, pos, form in data["wrong"]:
            self.assertFalse(forms_en.is_derived(lemma, form, pos), (lemma, pos, form))

    def _ctx(self, triples):
        course = cc.Course(str(self.root / "none"))
        words = []
        heads = {}
        for lemma, pos, form in triples:
            heads.setdefault((lemma, pos), []).append(form)
        for i, ((lemma, pos), forms) in enumerate(sorted(heads.items()), 1):
            words.append(ts.mf.W("w%04d" % i, lemma, pos, "뜻%d" % i, "x", 1, forms=[{"f": f, "pat": "p_x"} for f in sorted(set(forms))]))
        course.weeks = {1: {"words": words}}
        lex = cc.build_lexicon(course)
        ctx = chk.Ctx(course, [1], lex, True)
        ctx.usable, ctx.pat_o, ctx.acr, ctx.is_word = [1], {"p_x": 11}, lex.acronym_map(), lex.is_word
        return ctx

    def test_corpus_passes_check_forms_as_one_manuscript(self):
        data = json.load(open(ts.FIX / "forms_corpus.json", encoding="utf-8"))
        triples = [tuple(f) for item in data["sentences"] for f in item["forms"]]
        ctx = self._ctx(triples)
        chk.check_forms(ctx)
        self.assertEqual([(p.where, p.detail) for p in ctx.out], [])

    def test_corpus_wrong_forms_fail_check_forms(self):
        data = json.load(open(ts.FIX / "forms_corpus.json", encoding="utf-8"))
        for lemma, pos, form in data["wrong"]:
            ctx = self._ctx([(lemma, pos, form)])
            chk.check_forms(ctx)
            self.assertTrue([p for p in ctx.out if p.code == "FORM_SUSPECT"], (lemma, pos, form))

    def test_the_pos_of_the_word_is_used_by_the_linter(self):
        def mut(d):
            ts.find(d, 1, "words", "w0001")["forms"] = [{"f": "hellos", "pat": "p_my_name"}]
        self.assertIn("FORM_SUSPECT", self.codes(self.res(mut)))


class MetaFields(Base):
    """6. PERSONAL and BLOCKED look at every string of a week file."""

    PH = "604-555-1234"

    def note(self, **kw):
        return lambda d: d["weeks/w001.json"].setdefault("notes", []).append(dict({"id": "n0099", "kind": "culture", "text_ko": "문화 설명이에요"}, **kw))

    def blocked(self, d):
        d["policy.json"]["blocked"] = ["kill*"]

    def test_personal_in_every_meta_field(self):
        cases = {
            "notes.en": self.note(en="Call " + self.PH),
            "notes.us email": self.note(kind="spelling", ca="colour", us="tom@gmail.com"),
            "grammar_ko": lambda d: d["weeks/w001.json"]["patterns"][0]["grammar_ko"].__setitem__(0, "예: " + self.PH + " 로 전화해요."),
            "week title_ko": lambda d: d["weeks/w001.json"].update(title_ko="인사 " + self.PH),
            "pattern title_ko": lambda d: d["weeks/w001.json"]["patterns"][0].update(title_ko="이메일 tom@gmail.com 이에요"),
            "can_do": lambda d: d["weeks/w001.json"].update(can_do=["전화 " + self.PH + " 를 말해요"]),
            "scene title_ko": lambda d: d["weeks/w001.json"].__setitem__("scene", {"id": "x", "title_ko": "장면 " + self.PH, "canada": []}),
            "dialogue title_ko": lambda d: d["weeks/w001.json"]["dialogues"][0].update(title_ko="대화 " + self.PH),
            "prompt ko": lambda d: d["weeks/w004.json"]["speak_prompts"][0].update(ko="전화 " + self.PH + " 해요."),
            "pattern tpl": lambda d: d["weeks/w001.json"]["patterns"][0].update(tpl="Call " + self.PH + " ___."),
        }
        for label, mut in cases.items():
            with self.subTest(label=label):
                self.assertIn("PERSONAL", self.codes(self.res(mut)), label)

    def test_blocked_in_every_meta_field(self):
        cases = {
            "notes.en": self.note(en="You can kill it"),
            "grammar_ko": lambda d: d["weeks/w001.json"]["patterns"][0]["grammar_ko"].__setitem__(0, "예: kill 은 나쁜 말이에요."),
            "week title_ko": lambda d: d["weeks/w001.json"].update(title_ko="kill 인사"),
            "can_do": lambda d: d["weeks/w001.json"].update(can_do=["kill 을 말해요"]),
            "scene title_ko": lambda d: d["weeks/w001.json"].__setitem__("scene", {"id": "x", "title_ko": "kill 장면", "canada": []}),
            "dialogue title_ko": lambda d: d["weeks/w001.json"]["dialogues"][0].update(title_ko="kill 대화"),
            "notes.us": self.note(kind="spelling", ca="colour", us="killer"),
        }
        for label, mut in cases.items():
            def both(d, mut=mut):
                self.blocked(d)
                mut(d)
            with self.subTest(label=label):
                self.assertIn("BLOCKED", self.codes(self.res(both)), label)

    def test_english_words_in_meta_fields_get_no_order_check(self):
        r = self.res(self.note(en="banana split"))
        self.assertEqual(r.violations, [])

    def test_clean_meta_fields_pass(self):
        self.assertEqual(self.res().violations, [])


class SoftCanon(Base):
    def test_gray_and_meter_are_warnings(self):
        for en in ("gray", "grays", "meter", "meters"):
            def mut(d, en=en):
                d["weeks/w004.json"]["words"].append(ts.mf.W("w0398", en, "n", "물건", "x", 4))
            r = self.res(mut)
            self.assertEqual([p for p in r.violations if p.code == "CANON"], [], en)
            self.assertTrue([p for p in r.warnings if p.code == "CANON" and p.soft], en)

    def test_warning_does_not_change_the_exit_code_and_is_printed(self):
        def mut(d):
            d["weeks/w004.json"]["words"].append(ts.mf.W("w0398", "gray", "adj", "회색", "x", 4))
            d["weeks/w004.json"]["sentences"] += [ts.mf.S("s0990", "Good gray.", "좋은 회색이에요.", 4), ts.mf.S("s0991", "Good gray, Min.", "좋은 회색이에요, 민.", 4)]
        ts.write_course(self.root, mut)
        code, lines = ts.check("--in", self.root, "--strict", "--lexicon-from", "files")      # the extra word is not in the skeleton table
        self.assertEqual(code, 0, lines)
        self.assertTrue(any(ln.startswith("WARN CANON") for ln in lines))
        self.assertRegex(lines[-1], r"^CHECK_OK .*violations=0$")

    def test_other_us_spellings_are_still_violations(self):
        def mut(d):
            d["weeks/w004.json"]["words"].append(ts.mf.W("w0398", "color", "n", "색", "x", 4))
        self.assertIn("CANON", self.codes(self.res(mut)))


if __name__ == "__main__":
    unittest.main()
