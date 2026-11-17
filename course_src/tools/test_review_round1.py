# -*- coding: utf-8 -*-
"""Review round 1: `say` may not hide `en`, forms/alt may not smuggle words in, number readings, and the smaller gaps
(CANON, PERSONAL, Korean heuristics, tatoeba_fit, acronyms). Every case must FAIL with the named code; the good fixture
stays CHECK_OK."""
import sqlite3
import unittest
from pathlib import Path

import tool_support as ts
import check_course as chk
import course_common as cc
import forms_en
import numbers_en as ne
import tatoeba_fit as tf


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

    def line(self, en, **kw):
        return lambda d: d["weeks/w001.json"]["dialogues"][0]["lines"].append(dict({"s": "A", "en": en, "ko": "대사예요 하나.", "say": ""}, **kw))

    def prompt(self, en, say=""):
        def mut(d):
            d["weeks/w004.json"]["speak_prompts"][0]["en"] = en
            d["weeks/w004.json"]["speak_prompts"][0]["say"] = say
        return mut


class SayDoesNotHideEn(Base):
    """1. the words of `en` are checked even when `say` is present."""

    def test_unknown_word_in_en_with_clean_say(self):
        r = self.res(self.sent("Hello, apple.", say="Hello."))
        self.assertIn("token=apple", self.details(r, "UNKNOWN_TOKEN"))

    def test_later_word_in_en_with_clean_say(self):
        r = self.res(self.sent("Hello, friend.", say="Hello."))
        self.assertTrue(any(x.startswith("token=friend") for x in self.details(r, "ORDER")))

    def test_dialogue_line_with_say(self):
        self.assertIn("token=apple", self.details(self.res(self.line("Hello, apple.", say="Hello.")), "UNKNOWN_TOKEN"))
        self.assertTrue(any(x.startswith("token=friend") for x in self.details(self.res(self.line("Hello, friend.", say="Hello.")), "ORDER")))

    def test_speak_prompt_with_say(self):
        self.assertIn("token=apple", self.details(self.res(self.prompt("Hello, apple.", say="Hello.")), "UNKNOWN_TOKEN"))

    def test_say_words_are_checked_too(self):
        r = self.res(self.sent("Hello.", say="Hello, apple."))
        self.assertIn("token=apple", self.details(r, "UNKNOWN_TOKEN"))
        r = self.res(self.sent("Hello.", say="Hello, friend."))
        self.assertTrue(any(x.startswith("token=friend") for x in self.details(r, "ORDER")))

    def test_say_in_a_dialogue_line_is_checked(self):
        r = self.res(self.line("Hello.", say="Hello, apple."))
        self.assertIn("token=apple", self.details(r, "UNKNOWN_TOKEN"))

    def test_word_usage_counts_use_both_texts(self):
        self.assertEqual(cc.item_tokens("Hello, hi.", "Hello."), ["hello", "hi"])
        self.assertEqual(cc.item_tokens("Hello.", "Hello, hi."), ["hello", "hi"])

    def test_numbers_symbols_and_acronyms_are_read_through_say(self):
        self.assertEqual(cc.item_tokens("My number is 3.", "My number is three."), ["my", "number", "is", "three"])
        self.assertEqual(cc.item_tokens("It is 9:05.", "It is nine oh five."), ["it", "is", "nine", "five"])   # "oh" is reading glue
        self.assertEqual(cc.item_tokens("Hello, ATM.", "Hello, a t m."), ["hello", "atm"])     # letters of the reading are exempt

    def test_the_good_fixture_with_say_still_passes(self):
        self.assertEqual(self.res().violations, [])

    def test_ordinary_words_beside_a_number_are_still_checked(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0107").update(en="My zzyx is 3.", say="My number is three.")
        self.assertIn("token=zzyx", self.details(self.res(mut), "UNKNOWN_TOKEN"))


class FormsAndAlt(Base):
    """2. forms / alt cannot make arbitrary words known."""

    def word(self, wid, **kw):
        return lambda d: ts.find(d, 1, "words", wid).update(kw)

    def test_form_that_is_another_later_headword(self):
        r = self.res(self.word("w0001", forms=[{"f": "friend", "pat": "p_my_name"}]))
        self.assertIn("FORM_SUSPECT", self.codes(r))

    def test_form_that_is_no_form_of_the_word(self):
        for f in ("went", "banana", "hellod", "hellos hi"):
            with self.subTest(f=f):
                r = self.res(self.word("w0001", forms=[{"f": f, "pat": "p_my_name"}]))
                self.assertIn("FORM_SUSPECT", self.codes(r))

    def test_form_that_is_another_words_headword(self):
        r = self.res(self.word("w0007", forms=[{"f": "name", "pat": "p_my_name"}]))
        self.assertTrue(any(x.startswith(("form_is_another_headword", "form_not_derived")) for x in self.details(r, "FORM_SUSPECT")))

    def test_alt_banana(self):
        r = self.res(self.word("w0001", alt=["banana"]))
        self.assertIn("alt_not_a_spelling_variant=banana", self.details(r, "FORM_SUSPECT"))

    def test_alt_that_is_another_headword(self):
        r = self.res(self.word("w0001", alt=["hi"]))
        self.assertIn("alt_is_another_word=hi", self.details(r, "FORM_SUSPECT"))

    def test_alt_must_be_the_same_word(self):
        r = self.res(self.word("w0001", alt=["hellos"]))
        self.assertIn("alt_not_a_spelling_variant=hellos", self.details(r, "FORM_SUSPECT"))

    def test_empty_pat_is_schema(self):
        r = self.res(self.word("w0008", forms=[{"f": "names", "pat": ""}]))
        self.assertEqual(self.codes(r), ["SCHEMA"])
        self.assertIn("form_pat_empty", self.details(r, "SCHEMA"))

    def test_missing_pat_is_schema(self):
        r = self.res(self.word("w0008", forms=[{"f": "names"}]))
        self.assertEqual(self.codes(r), ["SCHEMA"])

    def test_legitimate_forms_and_alts_pass(self):
        def mut(d):
            ts.find(d, 1, "words", "w0008")["forms"] = [{"f": "names", "pat": "p_good_x"}]
            ts.find(d, 1, "words", "w0012")["forms"] = [{"f": "better", "pat": "p_good_x"}, {"f": "best", "pat": "p_good_x"}]
            ts.find(d, 1, "words", "w0010")["forms"] = [{"f": "Min's", "pat": "p_good_x"}]
            ts.find(d, 4, "words", "w0304")["alt"] = ["color"]
        self.assertEqual(self.res(mut).violations, [])

    def test_hyphen_and_space_variants_of_an_alt(self):
        def mut(d):
            d["weeks/w004.json"]["words"].append(ts.mf.W("w0399", "take away", "chunk", "포장", "", 4, alt=["takeaway", "take-away"]))
        self.assertEqual([p for p in self.res(mut).violations if p.code == "FORM_SUSPECT"], [])

    def test_the_same_checks_with_the_lexicon_from_the_skeleton(self):
        ts.write_course(self.root, self.word("w0001", forms=[{"f": "friend", "pat": "p_my_name"}]))
        r = chk.run_check(str(self.root), strict=True, lexicon_from="skeleton")
        self.assertIn("FORM_SUSPECT", self.codes(r))
        ts.write_course(self.root, self.word("w0001", alt=["banana"]))
        r = chk.run_check(str(self.root), strict=True, lexicon_from="skeleton")
        self.assertIn("FORM_SUSPECT", self.codes(r))

    def test_the_form_still_unlocks_the_word_only_at_its_own_day(self):
        def mut(d):
            ts.find(d, 1, "words", "w0008")["forms"] = [{"f": "names", "pat": "p_good_x"}]       # pattern is taught on d4
            ts.find(d, 1, "sentences", "s0013").update(en="Sorry, names.", ko="미안해요, 이름들.")
        self.assertTrue(any(x.startswith("token=names") for x in self.details(self.res(mut), "ORDER")))

    def test_forms_en_table(self):
        yes = [("apple", "apples"), ("box", "boxes"), ("city", "cities"), ("study", "studied"), ("make", "making"), ("make", "makes"),
               ("stop", "stopped"), ("run", "running"), ("go", "went"), ("go", "gone"), ("child", "children"), ("good", "better"),
               ("big", "bigger"), ("happy", "happier"), ("quick", "quickly"), ("I", "me"), ("be", "was"), ("can", "can't"), ("do", "don't"),
               ("take away", "takeaway"), ("Min", "Min's"), ("is", "isn't"), ("see", "saw"), ("knife", "knives"), ("work", "worked"),
               ("like", "liked"), ("love", "loving")]
        no = [("hello", "friend"), ("hello", "went"), ("apple", "banana"), ("go", "goed"), ("child", "childs"), ("man", "mans"),
              ("run", "ran away"), ("name", "nominee"), ("see", "seed"), ("go", "going on"), ("hi", "high"), ("cat", "dog")]
        for a, b in yes:
            self.assertTrue(forms_en.is_derived(a, b), (a, b))
        for a, b in no:
            self.assertFalse(forms_en.is_derived(a, b), (a, b))

    def test_fixture_bad_form_suspect_exists(self):
        self.assertEqual(ts.mf.BAD["bad_form_suspect"], "FORM_SUSPECT")


class NumberReadings(unittest.TestCase):
    """3. number readings."""

    def ok(self, en, say):
        self.assertTrue(ne.say_matches(en, say), (en, say))

    def no(self, en, say):
        self.assertFalse(ne.say_matches(en, say), (en, say))

    def test_years(self):
        for say in ("twenty oh five", "two thousand five", "two thousand and five"):
            self.ok("In 2005.", "In " + say + ".")
        self.no("In 2005.", "In twenty five.")
        self.ok("In 1905.", "In nineteen oh five.")
        self.no("In 1905.", "In nineteen five.")
        self.ok("In 2010.", "In twenty ten.")
        self.ok("In 2010.", "In two thousand ten.")
        self.ok("In 2000.", "In two thousand.")
        self.ok("In 1900.", "In nineteen hundred.")
        self.ok("In 1999.", "In nineteen ninety-nine.")
        self.ok("In 2024.", "In twenty twenty-four.")
        self.ok("In 2024.", "In two thousand and twenty-four.")
        self.no("In 1999.", "In nineteen ninety.")
        self.no("In 2025.", "In two zero two five.")

    def test_negative_numbers(self):
        self.ok("It is -5.", "It is minus five.")
        self.ok("It is -5.", "It is negative five.")
        self.no("It is -5.", "It is five.")
        self.no("It is -5.", "It is minus.")
        self.ok("It is −5.", "It is minus five.")
        self.ok("It is 5 - 3.", "It is five to three.")

    def test_temperatures(self):
        self.ok("It is 5°C.", "It is five degrees Celsius.")
        self.ok("It is 5°C.", "It is five degrees.")
        self.no("It is 5°C.", "It is five c.")
        self.no("It is 5°C.", "It is five.")
        self.ok("It is 41°F.", "It is forty-one degrees Fahrenheit.")
        self.ok("It is 41°F.", "It is forty-one degrees.")
        self.no("It is 41°F.", "It is forty-one f.")
        self.ok("It is -5°C.", "It is minus five degrees Celsius.")
        self.ok("It is -5°C.", "It is negative five degrees.")
        self.no("It is -5°C.", "It is five degrees Celsius.")
        self.ok("It is 5℃.", "It is five degrees Celsius.")           # the single character is normalised

    def test_ranges(self):
        self.ok("Wait 5-10 minutes.", "Wait five to ten minutes.")
        self.ok("Wait 5-10 minutes.", "Wait five through ten minutes.")
        self.no("Wait 5-10 minutes.", "Wait five ten minutes.")
        self.no("Wait 5-10 minutes.", "Wait five minus ten minutes.")
        self.ok("Open 9–5.", "Open nine to five.")
        self.ok("Open 9-5.", "Open nine to five.")

    def test_digit_by_digit_is_for_codes_only(self):
        self.no("I am 25.", "I am two five.")
        self.ok("I am 25.", "I am twenty-five.")
        self.no("I am 30.", "I am three oh.")
        self.ok("I am 30.", "I am thirty.")
        self.no("I have 205.", "I have two oh five.")                     # a plain number, no identifier word before it
        self.ok("I have 205.", "I have two hundred five.")
        self.ok("Room 205.", "Room two oh five.")
        self.ok("Room 205.", "Room two zero five.")
        self.ok("Room 205.", "Room two hundred five.")
        self.ok("Flight 1234.", "Flight one two three four.")
        self.ok("My code is 4821.", "My code is four eight two one.")      # 4+ digits, no year: identifier
        self.ok("My code is 4821.", "My code is four thousand eight hundred twenty-one.")
        self.ok("Call 0123.", "Call oh one two three.")                    # leading zero: always digits
        self.no("Call 0123.", "Call one hundred twenty-three.")
        self.no("It is 12.", "It is one two.")

    def test_911(self):
        self.ok("Call 911.", "Call nine one one.")
        self.no("Call 911.", "Call nine eleven.")
        self.no("Call 911.", "Call nine hundred eleven.")

    def test_phone_numbers_are_read_digit_by_digit(self):
        self.ok("Call 555-0123.", "Call five five five oh one two three.")
        self.ok("Call 604-555-0123.", "Call six oh four five five five oh one two three.")
        self.ok("Dial 1-800-555-0100.", "Dial one eight oh oh five five five oh one oh oh.")
        self.no("Call 555-0123.", "Call five hundred fifty-five oh one two three.")

    def test_tokens_like_3d_and_2x_need_say(self):
        for t in ("3D", "2x", "4K", "B2", "COVID-19"):
            self.assertTrue(ne.needs_say("It is " + t + "."), t)
        self.ok("A 3D movie.", "A three d movie.")
        self.no("A 3D movie.", "A movie.")

    def test_acronym_say_has_the_right_number_of_words(self):
        self.ok("Say ABC.", "Say a b c.")
        self.no("Say ABC.", "Say abc.")                                   # an unregistered acronym is never read as a word
        self.no("Say ABC.", "Say a b.")
        self.no("Say ABC.", "Say a b c d.")
        self.ok("Use the ATM.", "Use the a t m.")
        self.no("Use the ATM.", "Use the cash machine.")
        self.assertTrue(ne.say_matches("Go to SIN office.", "Go to sin office.", acronyms={"SIN": [["sin"]]}))     # registered
        self.assertFalse(ne.say_matches("Go to SIN office.", "Go to s i n office.", acronyms={"SIN": [["sin"]]}))

    def test_year_readings_only_between_1000_and_2099(self):
        self.no("I have 2105.", "I have twenty one oh five.")
        self.assertEqual(ne.readings("2005")[:1], ["two thousand five"])
        self.assertNotIn("twenty five", ne.readings("2005"))
        self.assertNotIn("nineteen five", ne.readings("1905"))

    def test_say_sentence_follows_the_same_rules(self):
        self.assertEqual(ne.say_sentence("It is -5°C."), "It is minus five degrees celsius.")
        self.assertEqual(ne.say_sentence("Wait 5-10 minutes."), "Wait five to ten minutes.")


class SmallerGaps(Base):
    def test_canon_forms_say_accept_and_inflections(self):
        def forms(d):
            ts.find(d, 4, "words", "w0304")["forms"] = [{"f": "colors", "pat": "p_greet_name"}]

        def say(d):
            ts.find(d, 4, "sentences", "s0409").update(en="Good colour.", say="Good color.")

        def accept(d):
            ts.find(d, 4, "sentences", "s0409")["accept"] = ["Good color."]

        def plural(d):
            ts.find(d, 4, "sentences", "s0409")["en"] = "Good colors."
        for fn in (forms, say, accept, plural):
            with self.subTest(fn=fn.__name__):
                self.assertIn("CANON", self.codes(self.res(fn)))

    def test_canon_inflected_headwords(self):
        for en in ("centers", "neighbors", "favorites", "colored", "gray", "theaters"):
            with self.subTest(en=en):
                def mut(d, en=en):
                    d["weeks/w004.json"]["words"].append(ts.mf.W("w0398", en, "n", "물건", "x", 4))
                r = self.res(mut)
                if en == "gray":                    # Canada uses gray as well: a warning only
                    self.assertFalse(self.details(r, "CANON"))
                    self.assertTrue(any(p.code == "CANON" and p.warn for p in r.warnings))
                else:
                    self.assertTrue(any(x.startswith("us_spelling_as_headword=") for x in self.details(r, "CANON")), en)

    def test_canon_ca_spelling_is_fine(self):
        def mut(d):
            d["weeks/w004.json"]["words"].append(ts.mf.W("w0398", "centres", "n", "중심", "x", 4, alt=["centers"]))
        self.assertNotIn("CANON", self.codes(self.res(mut)))

    def test_personal_normalisation_and_dashes(self):
        for label, ko in (("en dash", "전화는 604–555–1234예요."), ("em dash", "전화는 604—555—1234예요."),
                          ("U+2011", "전화는 604‑555‑1234예요."), ("minus sign", "전화는 604−555−1234예요."),
                          ("fullwidth", "전화는 ６０４-５５５-１２３４예요.")):
            with self.subTest(label=label):
                def mut(d, ko=ko):
                    ts.find(d, 2, "sentences", "s0105")["ko"] = ko
                self.assertIn("phone_number", self.details(self.res(mut), "PERSONAL"))

    def test_personal_fictional_number_with_dashes_is_fine(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "전화는 604–555–0123예요."
        self.assertEqual(self.res(mut).violations, [])

    def test_personal_web_addresses_without_www(self):
        for ko in ("사이트는 granville.com 이에요.", "사이트는 shop.example2.ca/menu 이에요.", "사이트는 my-cafe.net 이에요.", "사이트는 vancouver.org 이에요."):
            with self.subTest(ko=ko):
                def mut(d, ko=ko):
                    ts.find(d, 2, "sentences", "s0105")["ko"] = ko
                self.assertIn("web_address", self.details(self.res(mut), "PERSONAL"))

        def ok(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "사이트는 example.com 이에요."
        self.assertEqual(self.res(ok).violations, [])

    def test_personal_lower_case_street_address(self):
        def mut(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "주소는 1234 granville street 이에요."
        self.assertIn("street_address", self.details(self.res(mut), "PERSONAL"))

        def drive(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "5 minute drive 예요."
        self.assertEqual(self.res(drive).violations, [])

    def test_personal_in_forms_alt_and_say(self):
        def mut(d):
            ts.find(d, 1, "words", "w0001")["alt"] = ["hello 604-555-1234"]
        self.assertIn("PERSONAL", self.codes(self.res(mut)))

    def test_blocked_in_forms_alt_and_tpl(self):
        def mut(d):
            d["policy.json"]["blocked"] = ["names"]
            ts.find(d, 1, "words", "w0008")["forms"] = [{"f": "names", "pat": "p_good_x"}]
        self.assertIn("BLOCKED", self.codes(self.res(mut)))

        def tpl(d):
            d["policy.json"]["blocked"] = ["good"]
        self.assertIn("BLOCKED", self.codes(self.res(tpl)))

    def test_ko_single_noun_is_not_plain_style(self):
        for ko in ("어머니.", "의자.", "모자.", "휴지."):
            with self.subTest(ko=ko):
                def mut(d, ko=ko):
                    ts.find(d, 1, "sentences", "s0017")["ko"] = ko
                self.assertEqual([p for p in self.res(mut).violations if p.detail == "ko_style_not_haeyo"], [], ko)

    def test_ko_plain_style_sentence_is_still_flagged(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0017")["ko"] = "좋은 아침이다."
        self.assertIn("ko_style_not_haeyo", self.details(self.res(mut), "SCHEMA"))

    def test_han_outside_the_bmp(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0003")["ko"] = "고마워요 \U00020000."
        self.assertEqual(self.codes(self.res(mut)), ["KO_HANJA"])
        self.assertTrue(cc.HAN.search("\U0002a6d6"))

    def test_scene_title_is_checked_for_foreign_scripts(self):
        def mut(d):
            d["weeks/w001.json"]["scene"] = {"id": "x", "title_ko": "인사 谢", "canada": []}
        self.assertIn("KO_HANJA", self.codes(self.res(mut)))

    def test_num_say_for_3d_tokens_and_acronym_words(self):
        def no_say(d):
            ts.find(d, 1, "sentences", "s0001")["en"] = "Hello, 3D."
        self.assertIn("say_missing", self.details(self.res(no_say), "NUM_SAY"))

        def too_few(d):
            ts.find(d, 1, "sentences", "s0001").update(en="Hello, ABC.", say="Hello, a b.")
        self.assertIn("UNKNOWN_TOKEN", self.codes(self.res(too_few)))          # abc is neither a word nor a registered acronym

    def test_word_say_with_digits(self):
        def mut(d):
            ts.find(d, 1, "words", "w0001")["say"] = "hello 2"
        self.assertIn("say_has_digits_or_symbols", self.details(self.res(mut), "NUM_SAY"))


class TatoebaFitPassive(unittest.TestCase):
    def test_sentences_with_a_passive_word_are_not_candidates(self):
        tmp = ts.tmpdir()
        try:
            root = Path(tmp.name)
            ts.write_course(root / "m", lambda d: ts.find(d, 1, "words", "w0013").update(role="passive"))
            db = root / "t.sqlite"
            con = sqlite3.connect(str(db))
            con.execute("CREATE TABLE sent(id INTEGER PRIMARY KEY, lang TEXT NOT NULL, text TEXT NOT NULL, ko TEXT, tr TEXT, k INTEGER NOT NULL)")
            con.executemany("INSERT INTO sent VALUES (?,?,?,?,?,?)", [(1, "en", "Hello.", "안녕하세요.", None, 1), (2, "en", "Good morning.", "좋은 아침이에요.", None, 1)])
            con.commit()
            con.close()
            course = cc.Course(str(root / "m")).load()
            res = tf.fit(tf.load_sentences(db), cc.build_lexicon(course), [1])
            self.assertEqual(res[1]["cum"], 1)
            code, lines, _ = ts.cli("tatoeba_fit.py", "--in", root / "m", "--db", db, "--weeks", "1-1", "--lexicon-from", "skeleton")
            self.assertTrue(any(ln.startswith("FIT_NOTE") and "inflected forms" in ln for ln in lines), lines)
        finally:
            tmp.cleanup()


if __name__ == "__main__":
    unittest.main()
