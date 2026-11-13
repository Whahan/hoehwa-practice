# -*- coding: utf-8 -*-
"""Format check of the Korean gloss dictionaries godot/data/pack/gloss_en.json and gloss_ja.json (design §8 A2g-1, A2g-3)
and of the tool backend/tools/build_gloss_pack.py.

    backend\\.venv\\Scripts\\python.exe -I backend\\test_gloss_pack.py [--pack DIR]

Part 1 checks the pack: entry counts (en >= 10,000, ja >= 5,000), every entry's shape ({pos, ko, ipa} strings, a non-empty
word) and every `ko` (Hangul present, 1..60 characters), and the two manifest entries (size, SHA-256).
Part 2 runs the same checker on tampered copies (a ko without Hangul, a 61-character ko, a missing key), which must fail.
Part 3 unit-tests the tool's answer parser (bad positions, wrong words, empty answers are dropped) and runs the tool against
a closed port: it must exit != 0 and write nothing (A2g-3).
Part 4 checks the correction file backend/tools/gloss_fixes.tsv (the re-check of the dictionary): its parser rejects bad rows,
the fixes apply only to matching entries, `--from-pack` rewrites a base pack and refuses a bad fix file without writing, and every
row of the real file is reflected in the pack.
Last line: `== test_gloss_pack: N passed, 0 failed ==`. Nothing here starts a server or opens a port other than 127.0.0.1:9.
The real pack folder is only read; part 3 writes to temporary folders.
"""
import os
import re
import sys
import json
import shutil
import hashlib
import tempfile
import subprocess

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, "tools")
for _p in (HERE, TOOLS):
    if _p not in sys.path:
        sys.path.insert(0, _p)
import build_gloss_pack as B  # noqa: E402

MIN_COUNT = {"en": 10000, "ja": 5000}
FILES = {"en": "gloss_en.json", "ja": "gloss_ja.json"}
KEYS = {"pos", "ko", "ipa"}
# written independently of build_gloss_pack.valid_ko, so that a bug in the tool's check does not hide itself
HANGUL = re.compile(r"[가-힣ㄱ-ㆎ]")
# written independently of build_gloss_pack.KO_ALLOWED: Hangul, digits, spaces, and . , · ~ ( ) / - ' ! ?
KO_CHARS = re.compile(r"[가-힣ㄱ-ㆎ0-9\s.,·~()/\-'!?]+")
POS_TYPOS = {"부사사"}

passed = 0
failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print("PASS  %s" % name)
    else:
        failed += 1
        print("FAIL  %s  %s" % (name, detail))


def ko_problems(ko):
    if not isinstance(ko, str):
        return "ko 가 문자열이 아님"
    if not (1 <= len(ko) <= 60):
        return "ko 길이 %d" % len(ko)
    if not HANGUL.search(ko):
        return "ko 에 한글 없음 %r" % ko
    return ""


def check_file(path, lang):
    """problems of one gloss file (empty list = good)"""
    problems = []
    if not os.path.isfile(path):
        return ["파일 없음: %s" % path]
    try:
        with open(path, "r", encoding="utf-8") as f:
            d = json.load(f)
    except Exception as e:
        return ["JSON 을 읽지 못함: %s" % e]
    if not isinstance(d, dict):
        return ["최상위가 객체가 아님"]
    if len(d) < MIN_COUNT[lang]:
        problems.append("%s 항목 %d < %d" % (lang, len(d), MIN_COUNT[lang]))
    for w, v in d.items():
        if not isinstance(w, str) or not w or w != w.strip():
            problems.append("표제어 이상: %r" % (w,))
            break
        if not isinstance(v, dict) or set(v) != KEYS or not all(isinstance(v[k], str) for k in KEYS):
            problems.append("항목 모양 이상: %r" % (w,))
            break
        p = ko_problems(v["ko"])
        if not p and re.search(r"[A-Za-z]", v["ko"]):
            p = "ko 에 라틴 문자 섞임 %r" % v["ko"]
        if not p and not KO_CHARS.fullmatch(v["ko"]):
            p = "ko 에 한글·숫자·공백·일반 구두점 밖의 문자 %r" % v["ko"]
        if not p and v["pos"] in POS_TYPOS:
            p = "품사 오타 %r" % v["pos"]
        if not p and B.is_blocked(lang, w):
            p = "사전 차단 목록의 lemma (욕설·비하어)"
        if p:
            problems.append("%r: %s" % (w, p))
            if len(problems) >= 5:
                break
    return problems


def manifest_problems(pack_dir):
    mp = os.path.join(pack_dir, "manifest.json")
    try:
        with open(mp, "r", encoding="utf-8") as f:
            man = json.load(f)
    except Exception as e:
        return ["manifest.json 을 읽지 못함: %s" % e]
    entries = {e.get("path"): e for e in man.get("files", []) if isinstance(e, dict)}
    problems = []
    for lang, name in FILES.items():
        e = entries.get(name)
        fp = os.path.join(pack_dir, name)
        if e is None:
            problems.append("manifest 에 %s 항목 없음" % name)
            continue
        if not os.path.isfile(fp):
            problems.append("%s 파일 없음" % name)
            continue
        if e.get("bytes") != os.path.getsize(fp):
            problems.append("%s 크기 불일치" % name)
        with open(fp, "rb") as f:
            if e.get("sha256") != hashlib.sha256(f.read()).hexdigest():
                problems.append("%s sha256 불일치" % name)
        if e.get("records") is not None:
            with open(fp, "r", encoding="utf-8") as f:
                if e.get("records") != len(json.load(f)):
                    problems.append("%s records 불일치" % name)
    return problems


def part1(pack_dir):
    print("== part 1: pack ==")
    for lang in ("en", "ja"):
        p = check_file(os.path.join(pack_dir, FILES[lang]), lang)
        check("%s: 개수 %d 이상, 모양, ko 한글 1~60자" % (FILES[lang], MIN_COUNT[lang]), not p, "; ".join(p[:3]))
    mp = manifest_problems(pack_dir)
    check("manifest: 두 파일 항목의 크기·sha256·records 일치", not mp, "; ".join(mp))
    try:
        with open(os.path.join(pack_dir, FILES["en"]), "r", encoding="utf-8") as f:
            en_keys = json.load(f)
        gone = [w for w in ("war", "death", "die") if w not in en_keys]
        dict_bad = [w for w in en_keys if B.is_blocked("en", w)]
    except Exception as e:
        gone = ["읽기 실패: %s" % e]
        dict_bad = ["읽기 실패"]
    check("사전에 war·death·die 가 남아 있음 (일반 단어는 거르지 않음)", not gone, "빠짐: %r" % gone)
    check("팩에 사전 차단 목록 lemma 없음 (en)", not dict_bad, "있음: %r" % dict_bad[:10])
    try:
        with open(os.path.join(pack_dir, FILES["en"]), "r", encoding="utf-8") as f:
            en_d = json.load(f)
        fix_bad = [(w, en_d[w]["ko"], ko) for w, ko in B.MANUAL_FIX["en"].items() if w in en_d and en_d[w]["ko"] != ko]
        dropped_fix = [w for w in B.MANUAL_FIX["en"] if w not in en_d]
    except Exception as e:
        fix_bad = [("읽기 실패", str(e), "")]
        dropped_fix = []
    check("교정표 반영: 팩의 ko 가 MANUAL_FIX 와 같음 (팩에 있는 lemma 기준)", not fix_bad, "어긋남: %r" % fix_bad[:5])


def part2():
    print("== part 2: tampered copies must fail ==")
    tmp = tempfile.mkdtemp(prefix="gloss_test_")
    try:
        src = os.path.join(REPO_PACK, FILES["en"])
        with open(src, "r", encoding="utf-8") as f:
            d = json.load(f)
        keys = list(d)

        def variant(name, mutate):
            dd = json.loads(json.dumps(d, ensure_ascii=False))
            mutate(dd)
            fp = os.path.join(tmp, name)
            with open(fp, "w", encoding="utf-8") as f:
                json.dump(dd, f, ensure_ascii=False)
            return check_file(fp, "en")

        p = variant("no_hangul.json", lambda dd: dd[keys[5]].__setitem__("ko", "run"))
        check("변조 1: 한글 없는 ko 를 넣으면 실패", bool(p), "검사기가 통과시킴")
        p = variant("too_long.json", lambda dd: dd[keys[7]].__setitem__("ko", "가" * 61))
        check("변조 2: 61자 ko 를 넣으면 실패", bool(p), "검사기가 통과시킴")
        p = variant("latin.json", lambda dd: dd[keys[11]].__setitem__("ko", "아rlington"))
        check("변조 5: 라틴 문자가 섞인 ko 를 넣으면 실패", bool(p), "검사기가 통과시킴")
        p = variant("kana.json", lambda dd: dd[keys[13]].__setitem__("ko", "사ム"))
        check("변조 7: 가나가 섞인 ko(\"사ム\")를 넣으면 실패", bool(p), "검사기가 통과시킴")
        p = variant("pos_typo.json", lambda dd: dd[keys[15]].__setitem__("pos", "부사사"))
        check("변조 8: 품사 오타(\"부사사\")를 넣으면 실패", bool(p), "검사기가 통과시킴")
        blocked_key = "fuck"
        check("변조 6 준비: 'fuck' 은 사전 차단 목록에 있음", B.is_blocked("en", blocked_key))
        p = variant("blocked.json", lambda dd: dd.__setitem__(blocked_key, {"pos": "동사", "ko": "씨발", "ipa": ""}))
        check("변조 6: 사전 차단 목록 lemma 를 넣으면 실패", bool(p), "검사기가 통과시킴")
        # plain words must stay in the dictionary (not on the list)
        keep = [w for w in ("war", "death", "die", "sex", "drug", "kill", "blood", "cancer", "god", "church") if B.is_blocked("en", w)]
        check("일반 단어는 목록에 없음 (war, death, die, sex, drug, kill, blood, cancer, god, church)", not keep,
              "목록에 있음: %r" % keep)
        p = variant("missing_key.json", lambda dd: dd[keys[9]].pop("ipa"))
        check("변조 3: ipa 키가 없으면 실패", bool(p), "검사기가 통과시킴")
        p = variant("small.json", lambda dd: dd.clear())
        check("변조 4: 항목이 비면 실패", bool(p), "검사기가 통과시킴")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def part3():
    print("== part 3: tool unit checks and closed-port run ==")
    check("valid_ko: 한글 1~60자만 통과", B.valid_ko("사과") and not B.valid_ko("apple")
          and not B.valid_ko("") and not B.valid_ko("가" * 61) and B.valid_ko("가" * 60))
    asked = ["run", "cat", "dog"]
    answer = {"glosses": [
        {"i": 0, "lemma": "run", "pos": "동사", "ko": "달리다", "ipa": "rʌn", "note": ""},
        {"i": 1, "lemma": "cat", "pos": "명사", "ko": "cat", "ipa": "kæt", "note": ""},          # no Hangul: dropped
        {"i": 5, "lemma": "dog", "pos": "명사", "ko": "개", "ipa": "dɔɡ", "note": ""},          # position out of range
        {"i": 2, "lemma": "fox", "pos": "명사", "ko": "여우", "ipa": "fɑks", "note": ""},       # wrong word: dropped
    ]}
    got, rejected, missing = B.parse_glosses(answer, asked)
    check("parse: 정상 항목만 남기고 거른 수·빠진 수를 셈",
          set(got) == {"run"} and got["run"]["ko"] == "달리다" and rejected == 3 and missing == 2,
          "got=%r rejected=%r missing=%r" % (sorted(got), rejected, missing))
    got, rejected, missing = B.parse_glosses({"glosses": []}, asked)
    check("parse: 빈 응답은 아무것도 저장하지 않고 전부 빠진 것으로 셈", got == {} and missing == 3,
          "got=%r missing=%r" % (got, missing))
    got, rejected, missing = B.parse_glosses({"glosses": [{"i": 1, "lemma": "cat", "ko": "고양이"}]}, asked)
    check("parse: 0-base 인덱스 확인(1-base 응답이면 어긋남)", "cat" in got and got["cat"]["ko"] == "고양이")
    try:
        B.parse_glosses({"x": 1}, asked)
        shape_ok = False
    except ValueError:
        shape_ok = True
    check("parse: glosses 가 없는 응답은 오류(호출 실패로 재시도)", shape_ok)

    tmp = tempfile.mkdtemp(prefix="gloss_test_run_")
    try:
        vocab = os.path.join(tmp, "vocab")
        os.makedirs(vocab)
        for name in ("vocab_en.txt", "vocab_ja.txt"):
            with open(os.path.join(vocab, name), "w", encoding="utf-8") as f:
                f.write("run\ncat\n")
        out = os.path.join(tmp, "out")
        os.makedirs(out)
        with open(os.path.join(out, "manifest.json"), "w", encoding="utf-8") as f:
            f.write('{"v":1,"built":"x","files":[],"sources":[]}')
        cache = os.path.join(tmp, "cache")
        tool = os.path.join(TOOLS, "build_gloss_pack.py")
        r = subprocess.run([sys.executable, "-I", tool, "--vocab-dir", vocab, "--cache", cache, "--out", out,
                            "--url", "http://127.0.0.1:9"], capture_output=True, timeout=300)
        check("서버 없는 주소: 종료코드 3(0이 아님)", r.returncode == 3, "rc=%s" % r.returncode)
        nothing = not os.path.exists(os.path.join(out, "gloss_en.json")) and not os.path.exists(os.path.join(out, "gloss_ja.json"))
        mt = open(os.path.join(out, "manifest.json"), "r", encoding="utf-8").read()
        check("서버 없는 주소: 출력 파일과 manifest 를 쓰지 않음", nothing and mt.startswith('{"v":1,"built":"x"'))
        check("서버 없는 주소: 0건 성공으로 처리하지 않음(캐시 줄 없음)", not os.path.exists(cache) or not os.listdir(cache))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    words = ["w%03d" % i for i in range(20)]
    check("limit: N개는 앞에서부터, None 은 전부, 0 은 오류",
          B.limit_vocab(words, 5) == words[:5] and B.limit_vocab(words, None) == words
          and _raises(lambda: B.limit_vocab(words, 0), ValueError))

    # retry: only blank words are asked again (2 passes), answers already cached stay as they are
    tmp2 = tempfile.mkdtemp(prefix="gloss_test_retry_")
    real_call = B.call_gloss
    try:
        c = B.Cache(tmp2, "en")
        c.append(["a", "b", "c"], {"a": {"pos": "명사", "ko": "가", "ipa": ""}}, 0, 2)
        calls = []

        def fake_call(url, lang, words, timeout=900):
            calls.append(list(words))
            return {"glosses": [{"i": i, "lemma": w, "pos": "명사", "ko": "나", "ipa": ""}
                                for i, w in enumerate(words) if w == "b"]}

        B.call_gloss = fake_call
        run = B.Run("http://127.0.0.1:9", 4.0, False)
        run.estimated = True
        left = B.retry_missing(run, "en", ["a", "b", "c"], c, passes=2)
        check("retry: 빈칸만 다시 요청(첫 회차 [b,c], 둘째 회차 [c])",
              calls == [["b", "c"], ["c"]], "calls=%r" % (calls,))
        check("retry: 기존 응답은 그대로, 새 응답만 추가, 끝까지 빈 단어 반환",
              c.got["a"]["ko"] == "가" and c.got["b"]["ko"] == "나" and left == ["c"],
              "got=%r left=%r" % (c.got, left))
    finally:
        B.call_gloss = real_call
        shutil.rmtree(tmp2, ignore_errors=True)

    # rules of the output step
    check("품사 정규화: 부사사 -> 부사, 나머지는 그대로",
          B.normalize_pos({"a": {"pos": "부사사", "ko": "가", "ipa": ""}, "b": {"pos": "명사", "ko": "가", "ipa": ""}})[0]
          == {"a": {"pos": "부사", "ko": "가", "ipa": ""}, "b": {"pos": "명사", "ko": "가", "ipa": ""}})
    fixed, applied, absent = B.apply_manual_fix("en", {"calf": {"pos": "명사", "ko": "소년", "ipa": "kælf"},
                                                        "run": {"pos": "동사", "ko": "달리다", "ipa": ""}})
    check("교정표: calf -> 송아지 적용, 목록에 없는 lemma 는 absent 로 보고",
          fixed["calf"]["ko"] == "송아지" and fixed["calf"]["ipa"] == "kælf" and applied == 1 and "nothin" in absent)
    kept, counts, dropped = B.filter_entries("en", {
        "bt": {"pos": "명사", "ko": "브라", "ipa": ""},
        "sam": {"pos": "명사", "ko": "사ム", "ipa": ""},
        "fuckin": {"pos": "동사", "ko": "씨발", "ipa": ""},
        "war": {"pos": "명사", "ko": "전쟁", "ipa": ""},
        "rugby": {"pos": "명사", "ko": "rugby 경기", "ipa": ""},
        "percent": {"pos": "명사", "ko": "100%", "ipa": ""},
    })
    check("거르기 규칙: junk·other_char·blocked·latin 각 1, 일반 단어 war 는 남음",
          list(kept) == ["war"] and counts == {"junk": 1, "latin_in_ko": 1, "other_char_in_ko": 2, "blocked_word": 1},
          "kept=%r counts=%r" % (list(kept), counts))
    check("거르기 목록: 'fuckin', 'goddamn', 'negro' 가 사전 차단 목록에 있음",
          all(B.is_blocked("en", w) for w in ("fuckin", "goddamn", "negro")) and "bt" in B.DICT_DROP_EN)
    check("ko 허용 문자: 한글·숫자·공백·일반 구두점 통과, %·가나·한자·@ 는 거름",
          bool(B.KO_ALLOWED.fullmatch("가다 (동사) ~!?·10")) and not B.KO_ALLOWED.fullmatch("100%")
          and not B.KO_ALLOWED.fullmatch("사ム") and not B.KO_ALLOWED.fullmatch("漢字") and not B.KO_ALLOWED.fullmatch("a@b"))
    tmp3 = tempfile.mkdtemp(prefix="gloss_test_offline_")
    try:
        vocab3 = os.path.join(tmp3, "vocab")
        os.makedirs(vocab3)
        with open(os.path.join(vocab3, "vocab_en.txt"), "w", encoding="utf-8") as f:
            f.write("run\ncat\n")
        with open(os.path.join(vocab3, "vocab_ja.txt"), "w", encoding="utf-8") as f:
            f.write("猫\n")
        out3 = os.path.join(tmp3, "out")
        os.makedirs(out3)
        r = subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "build_gloss_pack.py"), "--vocab-dir", vocab3,
                            "--cache", os.path.join(tmp3, "cache"), "--out", out3, "--offline"],
                           capture_output=True, timeout=300)
        check("오프라인: 캐시에 없는 단어가 있으면 exit 1, 파일 미생성", r.returncode == 1
              and not os.path.exists(os.path.join(out3, "gloss_en.json")))
    finally:
        shutil.rmtree(tmp3, ignore_errors=True)

    pool = [("en", "w%03d" % i, "뜻%d" % i) for i in range(500)]
    s1 = B.make_sample(pool)
    s2 = B.make_sample(list(reversed(pool)))
    check("검수 목록: 100개이고 같은 입력이면 같은 결과(고정 시드)", len(s1) == 100 and s1 == s2)


def _write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def _fix_raises(path):
    try:
        B.load_fixes(path)
    except B.FixError:
        return True
    return False


def part4(pack_dir):
    print("== part 4: correction file (gloss_fixes.tsv) ==")
    tmp = tempfile.mkdtemp(prefix="gloss_test_fixes_")
    try:
        good = os.path.join(tmp, "good.tsv")
        _write(good, "# comment\n\nen\tmaze\t정글\t미로\nja\t姫\t여왕\t공주\n")
        fx = B.load_fixes(good)
        check("교정 파일: 정상 행 읽기(주석·빈 줄 건너뜀)",
              fx == {"en": {"maze": ("정글", "미로")}, "ja": {"姫": ("여왕", "공주")}}, "fx=%r" % (fx,))
        bad_rows = {
            "열 수가 3": "en\tmaze\t미로\n",
            "열 수가 5": "en\tmaze\t정글\t미로\t기타\n",
            "모르는 언어": "ko\tmaze\t정글\t미로\n",
            "빈 새 뜻": "en\tmaze\t정글\t\n",
            "한글 없는 새 뜻": "en\tmaze\t정글\t123\n",
            "라틴 문자 새 뜻": "en\tmaze\t정글\tmaze 미로\n",
            "가나 섞인 새 뜻": "en\tmaze\t정글\t미ロ\n",
            "61자 새 뜻": "en\tmaze\t정글\t" + "가" * 61 + "\n",
            "빈 옛 뜻": "en\tmaze\t\t미로\n",
            "빈 단어": "en\t\t정글\t미로\n",
            "옛 뜻과 같음": "en\tmaze\t정글\t정글\n",
            "같은 단어 중복": "en\tmaze\t정글\t미로\nen\tmaze\t정글\t미궁\n",
        }
        for name, text in bad_rows.items():
            bp = os.path.join(tmp, "bad.tsv")
            _write(bp, text)
            check("교정 파일: %s 이면 거부" % name, _fix_raises(bp))

        base = {"maze": {"pos": "명사", "ko": "정글", "ipa": "meɪz"}, "dog": {"pos": "명사", "ko": "개", "ipa": "dɔɡ"}}
        out, n = B.apply_fixes("en", base, fx)
        check("교정 적용: 맞는 행만 ko 를 바꾸고 pos·ipa·다른 단어는 그대로",
              n == 1 and out["maze"] == {"pos": "명사", "ko": "미로", "ipa": "meɪz"} and out["dog"] == base["dog"]
              and base["maze"]["ko"] == "정글")
        check("교정 적용: pack 에 없는 단어 행은 오류",
              _raises(lambda: B.apply_fixes("en", base, {"en": {"nosuchword": ("가", "나")}}), B.FixError))
        check("교정 적용: 옛 뜻이 pack 과 다른 행은 오류",
              _raises(lambda: B.apply_fixes("en", base, {"en": {"maze": ("다른 뜻", "미로")}}), B.FixError))

        # --from-pack end to end: tiny base pack + manifest
        bdir = os.path.join(tmp, "base")
        odir = os.path.join(tmp, "out")
        os.makedirs(bdir)
        os.makedirs(odir)
        B.write_json_atomic(os.path.join(bdir, "gloss_en.json"), base)
        B.write_json_atomic(os.path.join(bdir, "gloss_ja.json"), {"姫": {"pos": "명사", "ko": "여왕", "ipa": "ヒメ"}})
        man = '{"v":1,"built":"x","files":[],"sources":[]}'
        _write(os.path.join(odir, "manifest.json"), man)
        tool = os.path.join(TOOLS, "build_gloss_pack.py")

        def run(fixes_path):
            return subprocess.run([sys.executable, "-I", tool, "--from-pack", bdir, "--out", odir, "--fixes", fixes_path],
                                  capture_output=True, timeout=300)

        r = run(good)
        ok_files = os.path.isfile(os.path.join(odir, "gloss_en.json")) and os.path.isfile(os.path.join(odir, "gloss_ja.json"))
        check("--from-pack: 정상 교정 파일이면 exit 0, 두 gloss 파일과 manifest 항목을 씀", r.returncode == 0 and ok_files,
              "rc=%s out=%s" % (r.returncode, r.stdout[-300:]))
        check("--from-pack: 출력 pack 의 뜻이 교정되고 manifest 해시·records 가 맞음",
              ok_files and not manifest_problems_for(odir)
              and json.load(open(os.path.join(odir, "gloss_en.json"), encoding="utf-8"))["maze"]["ko"] == "미로"
              and json.load(open(os.path.join(odir, "gloss_ja.json"), encoding="utf-8"))["姫"]["ko"] == "공주")
        before = {n: open(os.path.join(odir, n), "rb").read() for n in os.listdir(odir)}
        for name, text in (("없는 단어", "en\tnosuchword\t개\t고양이\n"),
                           ("옛 뜻 불일치", "en\tmaze\t다른 뜻\t미로\n"),
                           ("빈 뜻", "en\tmaze\t정글\t\n"),
                           ("형식 깨진 줄", "en maze 정글 미로\n")):
            bp = os.path.join(tmp, "bad2.tsv")
            _write(bp, text)
            r = run(bp)
            after = {n: open(os.path.join(odir, n), "rb").read() for n in os.listdir(odir)}
            check("--from-pack: %s 교정 행이면 exit 2 이고 출력 파일을 바꾸지 않음" % name,
                  r.returncode == 2 and after == before, "rc=%s" % r.returncode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    fp = B.DEFAULT_FIXES
    if not os.path.isfile(fp):
        check("교정 파일: backend/tools/gloss_fixes.tsv 가 있음", False, fp)
        return
    try:
        fx = B.load_fixes(fp)
    except B.FixError as e:
        check("교정 파일: 실제 파일이 읽힘", False, str(e))
        return
    total = sum(len(v) for v in fx.values())
    check("교정 파일: 실제 파일이 읽히고 행이 있음", total > 0, "rows=%d" % total)
    wrong = []
    for lang in ("en", "ja"):
        with open(os.path.join(pack_dir, FILES[lang]), "r", encoding="utf-8") as f:
            d = json.load(f)
        for w, (old, new) in fx[lang].items():
            if w not in d:
                wrong.append("%s %s 없음" % (lang, w))
            elif d[w]["ko"] != new:
                wrong.append("%s %s: pack 뜻 %r != 교정 %r" % (lang, w, d[w]["ko"], new))
    check("교정 파일: 모든 행이 pack 에 반영됨(뜻이 새 뜻과 같음)", not wrong, "; ".join(wrong[:5]))


def manifest_problems_for(d):
    """manifest check of a pack folder that holds only the two gloss files (records, bytes, sha256)"""
    return manifest_problems(d)


REPO_PACK = None


def _raises(fn, exc):
    try:
        fn()
    except exc:
        return True
    return False


def main(argv):
    global REPO_PACK
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    pack = os.path.join(os.path.dirname(HERE), "godot", "data", "pack")
    if "--pack" in argv:
        pack = argv[argv.index("--pack") + 1]
    REPO_PACK = pack
    part1(pack)
    part2()
    part3()
    part4(pack)
    print("== test_gloss_pack: %d passed, %d failed ==" % (passed, failed))
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
