# -*- coding: utf-8 -*-
"""check_course.py with skeleton.json / policy.json in the layout of design 10.2 as K0 wrote it.

Week `patterns` are ids (bodies in the top-level `patterns`), the assignment table is the top-level `words`,
`scene.canada` are ids of the top-level `canada_notes`; policy blocked = {category: [..]}, blocked_prefix,
context_allowed, allowed_names {given, surnames, streets ...}, personal, stage0. The tests use small skeletons built
here from the design (K0's own files are not copied into the repository)."""
import json
import unittest
from pathlib import Path

import tool_support as ts
import tool_support_k0 as k0
import check_course as chk


def run(root, *args):
    return ts.check("--in", root, *args)


class SkeletonK0Layout(unittest.TestCase):
    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def sk(self, mutate=None):
        k0.write_k0_skeleton_course(self.root, mutate)
        return chk.run_check(str(self.root), skeleton=True, strict=True)

    def details(self, r, code):
        return [p.detail for p in r.violations if p.code == code]

    def test_valid_k0_layout_passes_via_cli(self):
        k0.write_k0_skeleton_course(self.root)
        code, lines = run(self.root, "--skeleton", "--strict")
        self.assertEqual(code, 0, lines[:8])
        self.assertRegex(lines[-1], r"^CHECK_OK weeks=1-72 .*violations=0$")

    def test_pattern_id_that_is_not_defined(self):
        def mut(sk):
            sk["weeks"][5]["patterns"][0] = "p_does_not_exist"
        r = self.sk(mut)
        self.assertIn("pattern_id_not_defined", self.details(r, "SCHEMA"))

    def test_nonexistent_pattern_id_fails_on_the_command_line(self):
        def mut(sk):
            sk["weeks"][5]["patterns"][0] = "p_does_not_exist"
        k0.write_k0_skeleton_course(self.root, mut)
        code, lines = run(self.root, "--skeleton", "--strict")
        self.assertEqual((code, lines[0]), (1, "CHECK_FAIL SCHEMA"))

    def test_pattern_defined_but_not_listed_and_listed_twice(self):
        def unlisted(sk):
            sk["patterns"].append({"id": "p_orphan", "w": 3, "d": 1, "tpl": "x ___."})

        def twice(sk):
            sk["weeks"][6]["patterns"].append(sk["weeks"][5]["patterns"][0])
        self.assertIn("pattern_not_listed_in_any_week", self.details(self.sk(unlisted), "SCHEMA"))
        self.assertTrue(any(x.startswith("pattern_listed_in_w") for x in self.details(self.sk(twice), "SCHEMA")))

    def test_pattern_body_problems(self):
        def mut(sk):
            sk["patterns"][0]["tpl"] = ""
            sk["patterns"][1]["w"] = 70
            sk["patterns"][2]["d"] = 9
            del sk["patterns"][3]["grammar_ko"]
        d = self.details(self.sk(mut), "SCHEMA")
        for want in ("tpl_missing", "pattern_w_differs_from_week", "pattern_d_out_of_range", "grammar_ko_must_be_2_to_4_short_lines"):
            self.assertIn(want, d)

    def test_pattern_template_without_blank_is_fine(self):
        def mut(sk):
            sk["patterns"][0]["tpl"] = "Hi! / Hello! / Thanks. / Sorry."
        self.assertEqual(self.sk(mut).violations, [])

    def test_duplicate_lemma_in_the_top_level_words(self):
        def mut(sk):
            sk["words"][5]["lemma"] = sk["words"][0]["lemma"]
        r = self.sk(mut)
        self.assertTrue(any(x.startswith("duplicate_lemma_with=") for x in self.details(r, "SCHEMA")))

    def test_counts_must_agree_with_the_table_and_the_week_lists(self):
        def counts(sk):
            sk["weeks"][5]["counts"]["active"] += 1

        def new_list(sk):
            sk["weeks"][5]["words"]["new"] = sk["weeks"][5]["words"]["new"][:-1]

        def day_list(sk):
            sk["weeks"][5]["days"][0]["words"] = sk["weeks"][5]["days"][0]["words"][1:]
        self.assertTrue(any(x.startswith("counts_") for x in self.details(self.sk(counts), "COUNT")))
        self.assertIn("words_new_differ_from_assignment", self.details(self.sk(new_list), "SCHEMA"))
        self.assertIn("day1_words_differ_from_assignment", self.details(self.sk(day_list), "SCHEMA"))

    def test_scene_canada_ids_must_exist(self):
        def mut(sk):
            sk["weeks"][9]["scene"]["canada"] = ["cn_nope"]
        self.assertIn("scene_canada_unknown_id=cn_nope", self.details(self.sk(mut), "SCHEMA"))

    def test_check_pass_must_be_a_percentage(self):
        def mut(sk):
            sk["weeks"][4]["check"] = {"items": 12, "pass": 180, "month": False}
        self.assertIn("check_pass_must_be_0_to_100", self.details(self.sk(mut), "SCHEMA"))

    def test_needs_are_checked_against_the_pattern_day(self):
        def later(sk):
            sk["patterns"][6]["needs"] = [sk["words"][-1]["lemma"]]

        def unknown(sk):
            sk["patterns"][6]["needs"] = ["zzyx"]

        def fine(sk):
            sk["patterns"][6]["needs"] = [sk["words"][0]["lemma"]]
        self.assertTrue(any("pattern_o" in x for x in self.details(self.sk(later), "ORDER")))
        self.assertTrue(any(x.startswith("needs=zzyx") for x in self.details(self.sk(unknown), "UNKNOWN_TOKEN")))
        self.assertEqual(self.sk(fine).violations, [])

    def test_k0_id_ranges_overlap_and_limits(self):
        def overlap(sk):
            sk["id_ranges"]["sentences"]["A2"] = ["s0200", "s0499"]

        def outside(sk):
            sk["id_ranges"]["dialogues"]["A4"] = ["d0013", "d1200"]

        def assigned_clash(sk):
            sk["id_ranges"]["words"]["A1"] = ["w0400", "w0600"]
        self.assertTrue(any(x.startswith("sentences_ranges_overlap") for x in self.details(self.sk(overlap), "SCHEMA")))
        self.assertTrue(any(x.startswith("dialogues_range_outside_R1_limits") for x in self.details(self.sk(outside), "SCHEMA")))
        self.assertTrue(any(x.startswith("words_ranges_overlap") for x in self.details(self.sk(assigned_clash), "SCHEMA")))

    def test_older_object_layout_is_still_accepted(self):
        ts.write_skeleton_course(self.root)
        self.assertEqual(chk.run_check(str(self.root), skeleton=True, strict=True).violations, [])

    def test_totals_and_ranges_still_apply(self):
        def mut(sk):
            sk["weeks"][30]["counts"]["active"] = 40
        self.assertTrue(any(x.startswith("active_words=40") for x in self.details(self.sk(mut), "COUNT")))


class PolicyK0Layout(unittest.TestCase):
    POL = {"v": 1,
           "blocked": {"profanity": ["damn"], "violence": ["kill"]}, "blocked_prefix": ["shit"],
           "context_allowed": [{"word": "friend", "from_w": 5, "why_ko": "시험"}],
           "allowed_names": {"given": [{"name": "Min", "from_w": 1}, {"name": "Anna", "from_w": 3}],
                             "streets": {"from_w": 2, "names": ["Main Street"]}},
           "personal": {"email_domains": ["example.com", "example.ca"]},
           "stage0": {"max_words_per_sentence": {"1": 4, "2": 6, "3": 6, "4": 8}},
           "limits": {"min_sentences": 8, "pattern_min_sentences": 2, "intro_active_range": [3, 28], "intro_pattern_range": [1, 2]}}

    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def res(self, mutate=None, pol=None):
        def mut(d):
            d["policy.json"] = json.loads(json.dumps(pol or self.POL))
            if mutate:
                mutate(d)
        ts.write_course(self.root, mut)
        return chk.run_check(str(self.root), strict=True)

    def details(self, r, code):
        return [p.detail for p in r.violations if p.code == code]

    def test_context_allowed_word_is_blocked_before_its_week(self):
        r = self.res()
        blocked = [p for p in r.violations if p.code == "BLOCKED"]
        self.assertTrue(blocked and all(p.where.startswith("w004") for p in blocked), "friend is blocked before week 5")
        pol = json.loads(json.dumps(self.POL))
        pol["context_allowed"][0]["from_w"] = 4
        self.assertEqual([p for p in self.res(None, pol).violations if p.code == "BLOCKED"], [])      # from week 4 on it is fine

    def test_category_lists_and_prefixes(self):
        def mut(d):
            d["weeks/w001.json"]["words"].append(ts.mf.W("w0090", "shitty", "adj", "나쁜", "ʃɪti", 4))
        r = self.res(mut)
        self.assertIn("token=shitty", self.details(r, "BLOCKED"))
        self.assertNotIn("token=damn", self.details(r, "BLOCKED"))

    def test_names_from_week(self):
        def early(d):
            ts.find(d, 1, "words", "w0010")["en"] = "Anna"
        r = self.res(early)
        self.assertIn("name_before_allowed_week=3", self.details(r, "PERSONAL"))

    def test_email_domains_and_streets(self):
        def mail(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "메일은 min@example.ca 이에요."

        def bad_mail(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "메일은 min@example.org.evil.com 이에요."

        def street(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "주소는 12 Main Street 이에요."

        def other_street(d):
            ts.find(d, 2, "sentences", "s0105")["ko"] = "주소는 12 Elm Street 이에요."
        self.assertEqual([p for p in self.res(mail).violations if p.code == "PERSONAL"], [])
        self.assertTrue(self.details(self.res(bad_mail), "PERSONAL"))
        self.assertEqual([p for p in self.res(street).violations if p.code == "PERSONAL"], [])
        self.assertTrue(self.details(self.res(other_street), "PERSONAL"))

    def test_stage0_max_words_per_sentence(self):
        def mut(d):
            ts.find(d, 1, "sentences", "s0010")["en"] = "Hello, my name is Min, hello."
        r = self.res(mut)
        self.assertTrue(any(x.startswith("sentence_words=6 want<=4") for x in self.details(r, "COUNT")))

    def test_contr_pos_and_template_without_blank_in_week_files(self):
        def mut(d):
            ts.find(d, 1, "words", "w0009")["pos"] = "contr"
            d["weeks/w001.json"]["patterns"][0]["tpl"] = "Hi! / Hello!"
        self.assertEqual([p for p in self.res(mut).violations if p.code == "SCHEMA"], [])


class ProperNounExtras(unittest.TestCase):
    """--lexicon-from skeleton: the table has no proper nouns; the week files add them (pos propn, author id range, policy)."""

    def setUp(self):
        self.tmp = ts.tmpdir()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def res(self, mutate):
        def mut(d):
            sk = d["skeleton.json"]
            d["skeleton.json"] = k0.to_k0_layout(sk)
            d["skeleton.json"]["words"] = [a for a in d["skeleton.json"]["words"] if a["id"] != "w0010"]
            d["skeleton.json"]["weeks"][0]["words"]["new"] = [i for i in d["skeleton.json"]["weeks"][0]["words"]["new"] if i != "w0010"]
            for dd in d["skeleton.json"]["weeks"][0]["days"]:
                if "words" in dd:
                    dd["words"] = [i for i in dd["words"] if i != "w0010"]
            d["skeleton.json"]["weeks"][0]["counts"]["active"] -= 1
            d["skeleton.json"]["id_ranges"]["words"]["A1"] = ["w0001", "w0100"]
            d["skeleton.json"]["id_ranges"]["words"]["assigned"] = ["w0101", "w0399"]
            if mutate:
                mutate(d)
        ts.write_course(self.root, mut)
        return chk.run_check(str(self.root), strict=True, lexicon_from="skeleton")

    def details(self, r):
        return [(p.code, p.detail) for p in r.violations]

    def test_name_outside_the_table_is_accepted(self):
        r = self.res(None)
        self.assertEqual([x for x in self.details(r) if x[1] in ("word_not_in_assignment", "name_not_in_policy")], [], self.details(r)[:5])

    def test_name_not_in_policy_is_rejected(self):
        def mut(d):
            d["policy.json"]["names"] = ["Anna"]
        self.assertIn(("PERSONAL", "name_not_in_policy"), self.details(self.res(mut)))

    def test_other_word_outside_the_table_is_rejected(self):
        def mut(d):
            ts.find(d, 1, "words", "w0010").update(pos="n")
        self.assertIn(("SCHEMA", "word_not_in_assignment"), self.details(self.res(mut)))

    def test_name_outside_the_author_range_is_rejected(self):
        def mut(d):
            d["skeleton.json"]["id_ranges"]["words"]["A1"] = ["w0001", "w0005"]
        self.assertIn(("SCHEMA", "id_outside_author_range"), self.details(self.res(mut)))


if __name__ == "__main__":
    unittest.main()
