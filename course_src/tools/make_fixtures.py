# -*- coding: utf-8 -*-
"""Generates the committed test fixtures (fixtures\\good_mini and fixtures\\bad_<name>) from one description.

    python -X utf8 course_src\\tools\\make_fixtures.py            # (re)write course_src\\tools\\fixtures\\
    python -X utf8 course_src\\tools\\make_fixtures.py --check    # exit 1 when the committed files differ (test_fixtures does this)

good_mini = weeks 1, 2 and 4 of a tiny made-up course (a few words per week, real limits relaxed in policy.json).
Each bad_<name> is good_mini with exactly one deliberate mistake; the expected first line `CHECK_FAIL <CODE>` is in BAD.
"""
import copy
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIX = HERE / "fixtures"

# fixture folder -> the code check_course.py must print on its first line
BAD = {
    "bad_order": "ORDER",
    "bad_unknown_token": "UNKNOWN_TOKEN",
    "bad_num_say": "NUM_SAY",
    "bad_ko_hangul": "KO_HANGUL",
    "bad_ko_hanja": "KO_HANJA",
    "bad_dup_en": "DUP_EN",
    "bad_dup_ko": "DUP_KO",
    "bad_same_ko": "SAME_KO_OPTIONS",
    "bad_blocked": "BLOCKED",
    "bad_personal": "PERSONAL",
    "bad_count": "COUNT",
    "bad_schema": "SCHEMA",
    "bad_canon": "CANON",
    "bad_form_suspect": "FORM_SUSPECT",
    "bad_tatoeba": "TATOEBA",
}


def W(i, en, pos, ko, ipa, d, role="active", **kw):
    x = {"id": i, "en": en, "pos": pos, "ko": ko, "ipa": ipa, "say": "", "tags": [], "role": role, "d": d,
         "forms": [], "alt": [], "syn": [], "ca": False, "src": "own"}
    x.update(kw)
    return x


def S(i, en, ko, d, pat="", say="", **kw):
    x = {"id": i, "en": en, "ko": ko, "say": say, "pat": pat, "d": d, "scope": "all", "accept": [], "src": "own", "tid": 0}
    x.update(kw)
    return x


def P(i, tpl, title, g, d, slot_pos):
    return {"id": i, "tpl": tpl, "slots": [{"name": "x", "pos": slot_pos}], "title_ko": title, "grammar_ko": g, "d": d}


def L(s, en, ko, say=""):
    return {"s": s, "en": en, "ko": ko, "say": say}


def good():
    w1 = {"v": 1, "w": 1, "title_ko": "인사하기", "can_do": ["인사를 할 수 있다", "이름을 말할 수 있다"],
          "words": [
              W("w0001", "hello", "interj", "안녕하세요", "həˈloʊ", 1),
              W("w0002", "hi", "interj", "안녕", "haɪ", 1),
              W("w0003", "thanks", "interj", "고마워요", "θæŋks", 1),
              W("w0004", "sorry", "interj", "미안해요", "ˈsɑːri", 2),
              W("w0005", "yes", "interj", "네", "jɛs", 2),
              W("w0006", "no", "interj", "아니요", "noʊ", 2),
              W("w0007", "my", "det", "나의", "maɪ", 3),
              W("w0008", "name", "n", "이름", "neɪm", 3),
              W("w0009", "is", "v", "이다", "ɪz", 3),
              W("w0010", "Min", "propn", "민", "mɪn", 3, tags=["name"]),
              W("w0011", "your", "det", "당신의", "jɔːr", 4),
              W("w0012", "good", "adj", "좋은", "ɡʊd", 4),
              W("w0013", "morning", "n", "아침", "ˈmɔːrnɪŋ", 4),
          ],
          "patterns": [
              P("p_my_name", "My name is ___.", "My name is ~ (제 이름은 ~예요)",
                ["영어는 'My name is' 바로 뒤에 이름이 와요.", "한국어의 '은/는' 같은 조사는 필요 없어요."], 3, ["propn"]),
              P("p_good_x", "Good ___.", "Good ~ (좋은 ~이에요)",
                ["'Good' 뒤에 때를 나타내는 말을 붙여 인사해요.", "Good morning 은 아침에 하는 인사예요."], 4, ["n"]),
          ],
          "sentences": [
              S("s0001", "Hello.", "안녕하세요.", 1),
              S("s0002", "Hi.", "안녕.", 1),
              S("s0003", "Thanks.", "고마워요.", 1),
              S("s0004", "Sorry.", "미안해요.", 2),
              S("s0005", "Yes.", "네.", 2),
              S("s0006", "No.", "아니요.", 2),
              S("s0007", "Yes, thanks.", "네, 고마워요.", 2),
              S("s0008", "No, thanks.", "아니요, 괜찮아요.", 2),
              S("s0009", "My name is Min.", "제 이름은 민이에요.", 3, "p_my_name"),
              S("s0010", "Hello, my name is Min.", "안녕하세요, 제 이름은 민이에요.", 3, "p_my_name"),
              S("s0011", "Hello, Min.", "안녕하세요, 민.", 3),
              S("s0012", "Hi, Min.", "안녕, 민.", 3),
              S("s0013", "Sorry, Min.", "미안해요, 민.", 3),
              S("s0014", "Your name is Min.", "당신의 이름은 민이에요.", 4),
              S("s0015", "Is your name Min?", "당신의 이름이 민인가요?", 4),
              S("s0016", "Good morning.", "좋은 아침이에요.", 4, "p_good_x"),
              S("s0017", "Good morning, Min.", "좋은 아침이에요, 민.", 4, "p_good_x"),
          ],
          "dialogues": [{"id": "d0001", "title_ko": "첫 인사", "scene": "intro", "user": "B", "lines": [
              L("A", "Hello, my name is Min.", "안녕하세요, 제 이름은 민이에요."),
              L("B", "Hello, Min.", "안녕하세요, 민."),
              L("A", "Thanks.", "고마워요.")]}],
          "speak_prompts": [], "notes": []}
    w2 = {"v": 1, "w": 2, "title_ko": "숫자 1~3", "can_do": ["1부터 3까지 셀 수 있다", "번호를 말할 수 있다"],
          "words": [
              W("w0101", "one", "num", "하나", "wʌn", 1),
              W("w0102", "two", "num", "둘", "tuː", 1),
              W("w0103", "three", "num", "셋", "θriː", 1),
              W("w0104", "it", "pron", "그것", "ɪt", 2),
              W("w0105", "number", "n", "번호", "ˈnʌmbər", 3),
              W("w0106", "room", "n", "방", "ruːm", 3),
          ],
          "patterns": [
              P("p_it_is", "It is ___.", "It is ~ (그것은 ~예요)",
                ["영어는 'It is' 뒤에 말하려는 것이 와요.", "한국어처럼 주어를 빼지 않고 'It' 을 꼭 써요."], 2, ["num"]),
              P("p_my_x_is", "My ___ is ___.", "My ~ is ~ (제 ~은 ~예요)",
                ["'My' 와 'is' 사이에 말하려는 대상을 넣어요.", "번호는 숫자로 써도 소리 내어 읽을 때는 단어로 읽어요."], 3, ["n"]),
          ],
          "sentences": [
              S("s0101", "One, two, three.", "하나, 둘, 셋.", 1),
              S("s0102", "It is one.", "그것은 하나예요.", 2, "p_it_is"),
              S("s0103", "It is two.", "그것은 둘이에요.", 2, "p_it_is"),
              S("s0104", "It is three.", "그것은 셋이에요.", 2, "p_it_is"),
              S("s0105", "My number is three.", "제 번호는 셋이에요.", 3, "p_my_x_is"),
              S("s0106", "My room is two.", "제 방은 둘이에요.", 3, "p_my_x_is"),
              S("s0107", "My number is 3.", "제 번호는 3번이에요.", 3, "p_my_x_is", say="My number is three."),
              S("s0108", "My room is 2.", "제 방은 2호예요.", 3, "", say="My room is two."),
              S("s0109", "Is it one?", "그것은 하나인가요?", 4),
              S("s0110", "Is your room two?", "당신의 방은 둘인가요?", 4),
          ],
          "dialogues": [{"id": "d0002", "title_ko": "번호 묻기", "scene": "number", "user": "B", "lines": [
              L("A", "My number is three.", "제 번호는 셋이에요."),
              L("B", "Is it three?", "셋인가요?"),
              L("A", "Yes.", "네.")]}],
          "speak_prompts": [], "notes": []}
    w4 = {"v": 1, "w": 4, "title_ko": "친구에게 인사", "can_do": ["친구에게 인사할 수 있다", "작별 인사를 할 수 있다"],
          "words": [
              W("w0301", "friend", "n", "친구", "frɛnd", 1),
              W("w0302", "welcome", "interj", "환영해요", "ˈwɛlkəm", 2),
              W("w0303", "bye", "interj", "안녕히 가세요", "baɪ", 2),
              W("w0304", "colour", "n", "색깔", "ˈkʌlər", 4, alt=["color"], ca=True),
          ],
          "patterns": [
              P("p_greet_name", "Hello, ___.", "Hello, ~ (안녕하세요, ~)",
                ["이름이나 호칭을 부를 때는 쉼표 뒤에 붙여요.", "한국어의 '~야', '~씨' 같은 호칭 대신 이름만 써요."], 2, ["n", "propn"]),
          ],
          "sentences": [
              S("s0401", "Hello, friend.", "안녕하세요, 친구.", 1, "p_greet_name"),
              S("s0402", "Hi, friend.", "안녕, 친구.", 1, "p_greet_name"),
              S("s0403", "Good morning, friend.", "좋은 아침이에요, 친구.", 1),
              S("s0404", "Thanks, friend.", "고마워요, 친구.", 1),
              S("s0405", "Welcome, friend.", "환영해요, 친구.", 2),
              S("s0406", "Welcome, Min.", "환영해요, 민.", 2),
              S("s0407", "Bye, friend.", "안녕히 가세요, 친구.", 2),
              S("s0408", "Bye, Min.", "안녕히 가세요, 민.", 2),
              S("s0409", "Good colour.", "좋은 색깔이에요.", 4),
              S("s0410", "Good colour, Min.", "좋은 색깔이에요, 민.", 4),
              S("s0411", "Yes, thanks, Min.", "네, 고마워요, 민.", 4, src="tatoeba", tid=90001),
          ],
          "dialogues": [{"id": "d0004", "title_ko": "작별 인사", "scene": "bye", "user": "B", "lines": [
              L("A", "Good morning, friend.", "좋은 아침이에요, 친구."),
              L("B", "Good morning, Min.", "좋은 아침이에요, 민."),
              L("A", "Bye, friend.", "안녕히 가세요, 친구.")]}],
          "speak_prompts": [
              {"id": "sp0401", "kind": "read", "en": "Hello, my name is Min.", "ko": "안녕하세요, 제 이름은 민이에요.", "expect_any": ["name"]},
              {"id": "sp0402", "kind": "answer", "en": "Is your name Min?", "ko": "당신의 이름이 민인가요?", "expect_any": ["yes", "no"]},
              {"id": "sp0403", "kind": "intro", "en": "My name is Min.", "ko": "제 이름은 민이에요.", "expect_any": ["name", "min"]}],
          "notes": [{"id": "n0001", "kind": "spelling", "ca": "colour", "us": "color", "text_ko": "캐나다에서는 colour 라고 써요."}]}
    weeks = {1: w1, 2: w2, 4: w4}
    assign = []
    for w, wk in weeks.items():
        for x in wk["words"]:
            assign.append({"id": x["id"], "lemma": x["en"], "pos": x["pos"], "role": x["role"], "w": w, "d": x["d"]})
    skeleton = {"v": 1, "lang": "en",
                "id_ranges": {"A1": {"weeks": [1, 4], "words": ["w0001", "w0399"], "sentences": ["s0001", "s0499"],
                                     "dialogues": ["d0001", "d0099"]}},
                "weeks": [{"w": w, "n": 1, "k": w, "stage": 0, "legacy_stage": 1, "title_ko": wk["title_ko"], "can_do": wk["can_do"],
                           "scene": {"id": "mini", "title_ko": "시험용", "canada": []}, "ladder": {}, "check": {}, "minutes": {}}
                          for w, wk in weeks.items()],
                "assign": assign}
    policy = {"v": 1,
              "blocked": ["kill*", "sex*", "fuck*", "shit*", "knife"],
              "allow": {"knife": [3]},
              "names": ["Min", "Anna"], "places": [], "allowed_propn": [],
              "canon_pairs": [], "acronym_ok": [],
              "tatoeba_db": "tatoeba_mini.json",
              "limits": {"min_sentences": 8, "pattern_min_sentences": 2, "word_min_sentences": 2,
                         "intro_active_range": [3, 28], "intro_pattern_range": [1, 2], "intro_passive_range": [0, 16]}}
    return {"policy.json": policy, "skeleton.json": skeleton, "tatoeba_mini.json": {"90001": "Yes, thanks, Min."},
            "weeks/w001.json": w1, "weeks/w002.json": w2, "weeks/w004.json": w4}


def _sent(d, w, sid):
    return next(s for s in d["weeks/w%03d.json" % w]["sentences"] if s["id"] == sid)


def _word(d, w, wid):
    return next(s for s in d["weeks/w%03d.json" % w]["words"] if s["id"] == wid)


def mutate(name, d):
    if name == "bad_order":
        _sent(d, 1, "s0001").update(en="Hello, bye.", ko="안녕하세요, 안녕히 가세요.")
    elif name == "bad_unknown_token":
        _sent(d, 1, "s0001")["en"] = "Hello, zzyx."
    elif name == "bad_num_say":
        _sent(d, 2, "s0107")["say"] = ""
    elif name == "bad_ko_hangul":
        _sent(d, 1, "s0003")["ko"] = "Thanks."
    elif name == "bad_ko_hanja":
        _sent(d, 1, "s0003")["ko"] = "고마워요 謝."
    elif name == "bad_dup_en":
        d["weeks/w002.json"]["sentences"].append(S("s0111", "Hello.", "안녕하세요 (인사)", 4))
    elif name == "bad_dup_ko":
        _sent(d, 1, "s0012")["ko"] = "안녕하세요, 민."
    elif name == "bad_same_ko":
        _word(d, 1, "w0002")["ko"] = "안녕하세요"
    elif name == "bad_blocked":
        d["policy.json"]["blocked"].append("bye")
    elif name == "bad_personal":
        _sent(d, 2, "s0105")["ko"] = "제 번호는 604-555-1234예요."
    elif name == "bad_count":
        d["weeks/w001.json"]["speak_prompts"] = [
            {"id": "sp0101", "kind": "read", "en": "Hello.", "ko": "안녕하세요.", "expect_any": ["hello"]},
            {"id": "sp0102", "kind": "answer", "en": "Thanks.", "ko": "고마워요.", "expect_any": ["thanks"]},
            {"id": "sp0103", "kind": "intro", "en": "Sorry.", "ko": "미안해요.", "expect_any": ["sorry"]}]
    elif name == "bad_schema":
        del _word(d, 1, "w0001")["ko"]
    elif name == "bad_canon":
        _word(d, 4, "w0304")["alt"] = []
    elif name == "bad_form_suspect":
        _word(d, 1, "w0001")["forms"] = [{"f": "went", "pat": "p_my_name"}]
    elif name == "bad_tatoeba":
        _sent(d, 4, "s0411")["tid"] = 0
    else:
        raise KeyError(name)


def dump(obj):
    return json.dumps(obj, ensure_ascii=False, indent=1) + "\n"


def build_all():
    """-> {relative path under fixtures\\: text}"""
    files = {}
    g = good()
    for rel, obj in g.items():
        files["good_mini/" + rel] = dump(obj)
    for name in BAD:
        d = copy.deepcopy(g)
        mutate(name, d)
        for rel, obj in d.items():
            files[name + "/" + rel] = dump(obj)
    return files


def main(argv):
    files = build_all()
    if "--check" in argv:
        bad = []
        for rel, text in files.items():
            p = FIX / rel
            if not p.is_file() or p.read_bytes().decode("utf-8").replace("\r\n", "\n") != text:
                bad.append(rel)
        for p in FIX.rglob("*.json"):
            if p.relative_to(FIX).as_posix() not in files and p.name != "forms_corpus.json":     # forms_corpus.json is hand-made
                bad.append(p.relative_to(FIX).as_posix() + " (unexpected)")
        print("FIXTURES_OUT_OF_DATE " + ",".join(bad) if bad else "FIXTURES_OK files=%d" % len(files))
        return 1 if bad else 0
    for rel, text in files.items():
        p = FIX / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode("utf-8"))
    print("wrote %d files under %s" % (len(files), FIX))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
