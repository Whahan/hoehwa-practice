# -*- coding: utf-8 -*-
"""Builds the Korean gloss dictionaries godot/data/pack/gloss_en.json and gloss_ja.json (design: docs/phone_standalone_design.md
§5.5 and §8 A2g). It asks the PC backend (POST /reading/gloss, 30 words per call) for a Korean meaning of every word in the
vocabulary lists, and writes the answers into the pack.

    backend\\.venv\\Scripts\\python.exe -I backend\\tools\\build_gloss_pack.py --vocab-dir DIR [options]

    --vocab-dir DIR   folder with vocab_en.txt and vocab_ja.txt (one lemma per line; written by build_phone_pack.py --vocab-dir)
    --cache DIR       progress cache, one JSON line per answered call (default backend\\cache\\gloss_pack); a stopped run resumes
    --url URL         backend base URL (default http://127.0.0.1:18799)
    --out DIR         pack folder (default godot\\data\\pack): gloss_*.json and the two manifest entries are written there
    --lang en,ja      languages to build (default en,ja)
    --limit-en N      use only the first N English lemmas of vocab_en.txt (the list is in frequency order); default all
    --limit-ja N      use only the first N Japanese lemmas of vocab_ja.txt; default all
    --max-hours H     when the estimate for the rest of the run is longer than H hours, stop (exit 4) (default 4)
    --no-limit        run even when the estimate is longer than --max-hours
    --sample FILE     write the fixed-seed 100-word review list (word / ko / empty check column) from the built files

Flow: the first 100 words computed in this run are timed, the estimate is printed, and the run goes on only when the estimate
fits --max-hours. Every call is appended to the cache at once. The gloss files and the manifest are written only when every
word of the selected languages has been asked.
Exit codes: 0 ok, 1 some calls failed for good (nothing written, rerun resumes), 2 missing input, 3 backend not reachable
(the first call failed, or 3 calls in a row failed), 4 estimate above --max-hours (the full run was not started).
A pack entry is {"<lemma>": {"pos", "ko", "ipa"}}; an answer is dropped when its ko has no Hangul or is not 1..60 characters,
when its position does not match the word sent, or when the backend gives no answer for the word.
"""
import os
import re
import sys
import json
import time
import random
import hashlib
import argparse
import urllib.request

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.dirname(HERE)
REPO = os.path.dirname(BACKEND)

BATCH = 30            # backend/reading.py MAX_GLOSS
TIMING_WORDS = 100    # words timed before the estimate
SAMPLE_SEED = 20261024
SAMPLE_N = 100
MAX_KO = 60
LANGS = ("en", "ja")
VOCAB_FILE = {"en": "vocab_en.txt", "ja": "vocab_ja.txt"}
PACK_FILE = {"en": "gloss_en.json", "ja": "gloss_ja.json"}
DEFAULT_URL = "http://127.0.0.1:18799"

HANGUL = re.compile(r"[가-힣ㄱ-ㆎ]")


class BackendDown(Exception):
    pass


class OverLimit(Exception):
    pass


def say(msg):
    print(msg, flush=True)


def valid_ko(ko):
    """a Korean meaning: at least one Hangul character, 1..60 characters"""
    return isinstance(ko, str) and 1 <= len(ko) <= MAX_KO and HANGUL.search(ko) is not None


def read_vocab(path):
    """lemmas in file order, stripped, without empty lines or repeats"""
    seen = set()
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            w = line.strip()
            if w and w not in seen:
                seen.add(w)
                out.append(w)
    return out


def limit_vocab(words, n):
    """the first n words (the lists are in frequency order); n None = all"""
    if n is None:
        return words
    if n < 1:
        raise ValueError("limit must be >= 1")
    return words[:n]


def call_gloss(url, lang, words, timeout=900):
    """one POST /reading/gloss; returns the parsed JSON answer (raises on any HTTP / network / JSON error)"""
    body = json.dumps({"lang": lang, "items": [{"lemma": w, "sentence": ""} for w in words]},
                      ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url.rstrip("/") + "/reading/gloss", data=body, method="POST",
                                 headers={"Content-Type": "application/json; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def parse_glosses(data, asked):
    """one answer -> (got, rejected, missing). got = {word: {pos, ko, ipa}} for the words sent in `asked`;
    rejected = answered entries that were dropped; missing = words of `asked` without an accepted entry (incl. empty answer)"""
    items = data.get("glosses") if isinstance(data, dict) else None
    if not isinstance(items, list):
        raise ValueError("answer without a glosses list")
    got = {}
    rejected = 0
    for g in items:
        if not isinstance(g, dict):
            rejected += 1
            continue
        i = g.get("i")
        if not isinstance(i, int) or isinstance(i, bool) or not (0 <= i < len(asked)) or asked[i] in got:
            rejected += 1
            continue
        w = asked[i]
        lemma = g.get("lemma")
        if not isinstance(lemma, str) or lemma.strip().lower() != w.lower():
            rejected += 1
            continue
        ko = " ".join(str(g.get("ko") or "").split())
        if not valid_ko(ko):
            rejected += 1
            continue
        pos = " ".join(str(g.get("pos") or "").split())[:12]
        ipa = str(g.get("ipa") or "").strip()
        got[w] = {"pos": pos, "ko": ko, "ipa": ipa}
    missing = sum(1 for w in asked if w not in got)
    return got, rejected, missing


class Cache:
    """per language: <cache>/gloss_<lang>.jsonl, one line per answered call: {"asked", "got", "rejected", "missing"}"""

    def __init__(self, folder, lang):
        self.folder = folder
        self.path = os.path.join(folder, "gloss_%s.jsonl" % lang)
        self.asked = set()
        self.got = {}
        self.rejected = 0
        self.missing = 0
        self.bad_lines = 0
        if os.path.isfile(self.path):
            with open(self.path, "r", encoding="utf-8") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                        asked = rec["asked"]
                        got = rec["got"]
                        rejected = int(rec["rejected"])
                        missing = int(rec["missing"])
                    except Exception:
                        self.bad_lines += 1  # a line cut short by a stop; its words are asked again
                        continue
                    self.asked.update(asked)
                    self.got.update(got)
                    self.rejected += rejected
                    self.missing += missing

    def append(self, asked, got, rejected, missing):
        os.makedirs(self.folder, exist_ok=True)
        line = json.dumps({"asked": asked, "got": got, "rejected": rejected, "missing": missing},
                          ensure_ascii=False, separators=(",", ":")) + "\n"
        need_newline = False
        if os.path.isfile(self.path) and os.path.getsize(self.path) > 0:
            with open(self.path, "rb") as fb:
                fb.seek(-1, os.SEEK_END)
                need_newline = fb.read(1) != b"\n"  # the last line was cut short by a stop: start a new line
        with open(self.path, "a", encoding="utf-8", newline="\n") as f:
            if need_newline:
                f.write("\n")
            f.write(line)
            f.flush()
        self.asked.update(asked)
        self.got.update(got)
        self.rejected += rejected
        self.missing += missing


class Run:
    def __init__(self, url, max_hours, no_limit):
        self.url = url
        self.max_hours = max_hours
        self.no_limit = no_limit
        self.calls_ok = 0
        self.consec_fail = 0
        self.failed_batches = 0
        self.done_words = 0
        self.timed_words = 0
        self.timed_secs = 0.0
        self.estimated = False
        self.total_todo = 0
        self.t0 = time.time()


def estimate(run):
    rate = run.timed_words / run.timed_secs if run.timed_secs > 0 else 0.0
    remaining = max(0, run.total_todo - run.done_words)
    if rate <= 0:
        raise BackendDown("timing gave no speed")
    secs = remaining / rate
    hours = secs / 3600.0
    say("[측정] 처음 %d단어: %.1f초, 속도 %.3f 단어/초" % (run.timed_words, run.timed_secs, rate))
    say("[예상] 남은 %d단어 전체 약 %.2f 시간 (%.0f초)" % (remaining, hours, secs))
    run.estimated = True
    if hours > run.max_hours and not run.no_limit:
        raise OverLimit("예상 %.2f 시간이 한도 %.2f 시간을 넘어 전체 실행을 시작하지 않음" % (hours, run.max_hours))
    say("[진행] 예상이 한도 안이라 전체 실행을 계속함")


def run_batch(run, lang, batch, cache):
    """one call with retries (the very first call of the run gets no retry); True when its answer was cached"""
    attempts = 1 if run.calls_ok == 0 else 3
    last_err = None
    for a in range(attempts):
        t0 = time.time()
        try:
            data = call_gloss(run.url, lang, batch)
            got, rejected, missing = parse_glosses(data, batch)
        except Exception as e:  # network, HTTP 4xx/5xx, bad JSON, bad shape
            last_err = e
            if a + 1 < attempts:
                time.sleep(5 * (a + 1))
            continue
        secs = time.time() - t0
        cache.append(batch, got, rejected, missing)
        run.calls_ok += 1
        run.consec_fail = 0
        run.done_words += len(batch)
        if not run.estimated and run.timed_words < TIMING_WORDS:
            run.timed_words += len(batch)
            run.timed_secs += secs
            if run.timed_words >= TIMING_WORDS:
                estimate(run)
        return True
    if run.calls_ok == 0:
        raise BackendDown("첫 호출 실패(백엔드가 꺼져 있거나 주소가 틀림): %s" % last_err)
    run.failed_batches += 1
    run.consec_fail += 1
    say("[경고] %s %d개 묶음 실패(%d회 시도): %s" % (lang, len(batch), attempts, last_err))
    if run.consec_fail >= 3:
        raise BackendDown("3회 연속 실패, 중단(진행분은 캐시에 남음): %s" % last_err)
    return False


def run_lang(run, lang, todo, cache, total):
    calls = 0
    pos = 0
    while pos < len(todo):
        n = BATCH
        if not run.estimated and run.timed_words < TIMING_WORDS:
            n = min(BATCH, TIMING_WORDS - run.timed_words)  # the timing ends exactly at TIMING_WORDS
        batch = todo[pos:pos + n]
        pos += len(batch)
        run_batch(run, lang, batch, cache)
        calls += 1
        if calls % 10 == 0 or pos >= len(todo):
            say("[%s] 요청 %d/%d단어, 응답 %d개, 거름 %d, 빈칸 %d, 경과 %.0f초" % (
                lang, len(cache.asked), total, len(cache.got), cache.rejected, cache.missing, time.time() - run.t0))


def write_json_atomic(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")
    os.replace(tmp, path)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def update_manifest(out_dir, entries):
    """adds (or replaces) the entries of the gloss files in manifest.json; every other entry and key is kept as it is"""
    mp = os.path.join(out_dir, "manifest.json")
    with open(mp, "r", encoding="utf-8") as f:
        man = json.load(f)
    keep = [e for e in man.get("files", []) if e.get("path") not in entries]
    for name, e in entries.items():
        keep.append({"path": name, "bytes": e["bytes"], "sha256": e["sha256"], "records": e["records"]})
    keep.sort(key=lambda e: e["path"])
    man["files"] = keep
    # indent=1 is the layout of the existing manifest (build_phone_pack.py write_json), so only the new lines differ
    tmp = mp + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(man, indent=1, ensure_ascii=False) + "\n")
    os.replace(tmp, mp)


def make_sample(pool, seed=SAMPLE_SEED, n=SAMPLE_N):
    """fixed-seed draw of n (lang, word, ko) rows from pool (pool is sorted first, so the draw depends only on the content)"""
    rows = sorted(pool)
    return random.Random(seed).sample(rows, min(n, len(rows)))


def write_sample(out_dir, path):
    pool = []
    for lang in LANGS:
        fp = os.path.join(out_dir, PACK_FILE[lang])
        if not os.path.isfile(fp):
            raise FileNotFoundError(fp)
        with open(fp, "r", encoding="utf-8") as f:
            d = json.load(f)
        pool.extend((lang, w, v["ko"]) for w, v in d.items())
    rows = make_sample(pool)
    lines = ["# 뜻 사전 무작위 검수 목록 (A2g-2)", "",
             "무작위 %d개, 고정 시드 %d, 대상: gloss_en.json + gloss_ja.json." % (len(rows), SAMPLE_SEED),
             "검수 칸은 비워 둔다. 검수는 오케스트레이터가 한다 (O 맞음 / X 틀림 / 메모).", "",
             "| # | 언어 | 단어 | ko | 검수 |", "|---|---|---|---|---|"]
    for k, (lang, w, ko) in enumerate(rows, 1):
        lines.append("| %d | %s | %s | %s | |" % (k, lang, w.replace("|", "\\|"), ko.replace("|", "\\|")))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return len(rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the Korean gloss packs from the PC backend")
    ap.add_argument("--vocab-dir", default=None)
    ap.add_argument("--cache", default=os.path.join(BACKEND, "cache", "gloss_pack"))
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--out", default=os.path.join(REPO, "godot", "data", "pack"))
    ap.add_argument("--lang", default="en,ja")
    ap.add_argument("--limit-en", type=int, default=None)
    ap.add_argument("--limit-ja", type=int, default=None)
    ap.add_argument("--max-hours", type=float, default=4.0)
    ap.add_argument("--no-limit", action="store_true")
    ap.add_argument("--sample", default=None)
    args = ap.parse_args(argv)
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    langs = [x.strip() for x in args.lang.split(",") if x.strip()]
    if not langs or any(x not in LANGS for x in langs):
        say("[오류] --lang 은 en, ja 중에서 고른다")
        return 2

    if args.vocab_dir is None:
        if args.sample:
            vocab = {}
        else:
            say("[오류] --vocab-dir 을 지정하라 (vocab_en.txt, vocab_ja.txt 가 있는 폴더)")
            return 2
    else:
        vocab = {}
        limits = {"en": args.limit_en, "ja": args.limit_ja}
        for lang in langs:
            vp = os.path.join(args.vocab_dir, VOCAB_FILE[lang])
            if not os.path.isfile(vp):
                say("[오류] 어휘 목록이 없음: %s" % vp)
                return 2
            try:
                vocab[lang] = limit_vocab(read_vocab(vp), limits[lang])
            except ValueError as e:
                say("[오류] --limit-%s: %s" % (lang, e))
                return 2

    if vocab:
        caches = {lang: Cache(args.cache, lang) for lang in langs}
        todo = {lang: [w for w in vocab[lang] if w not in caches[lang].asked] for lang in langs}
        for lang in langs:
            say("[%s] 어휘 %d, 이미 처리 %d, 남음 %d (캐시 깨진 줄 %d)" % (
                lang, len(vocab[lang]), len(caches[lang].asked), len(todo[lang]), caches[lang].bad_lines))
        run = Run(args.url, args.max_hours, args.no_limit)
        run.total_todo = sum(len(todo[lang]) for lang in langs)
        try:
            for lang in langs:
                if todo[lang]:
                    run_lang(run, lang, todo[lang], caches[lang], len(vocab[lang]))
            if not run.estimated and run.total_todo:
                say("[측정] 이번 실행에서 %d단어 미만만 처리해 속도를 재지 못함" % run.done_words)
        except BackendDown as e:
            say("[실패] %s" % e)
            return 3
        except OverLimit as e:
            say("[중단] %s" % e)
            return 4
        if run.failed_batches:
            say("[실패] %d개 묶음이 끝내 실패함. 파일은 쓰지 않음. 같은 명령으로 다시 실행하면 이어서 처리" % run.failed_batches)
            return 1
        for lang in langs:
            c = caches[lang]
            missing_words = [w for w in vocab[lang] if w not in c.asked]
            if missing_words:
                say("[실패] %s: 아직 요청하지 않은 단어 %d개" % (lang, len(missing_words)))
                return 1
        entries = {}
        for lang in langs:
            c = caches[lang]
            out_obj = {w: c.got[w] for w in vocab[lang] if w in c.got}
            fp = os.path.join(args.out, PACK_FILE[lang])
            write_json_atomic(fp, out_obj)
            entries[PACK_FILE[lang]] = {"bytes": os.path.getsize(fp), "sha256": sha256_file(fp), "records": len(out_obj)}
            say("[결과] %s: 어휘 %d, 뜻 %d개 저장, 거른 응답 %d, 빈칸 %d (%s)" % (
                lang, len(vocab[lang]), len(out_obj), c.rejected, c.missing, fp))
        update_manifest(args.out, entries)
        say("[결과] manifest.json 항목 추가: %s" % ", ".join(sorted(entries)))

    if args.sample:
        n = write_sample(args.out, args.sample)
        say("[결과] 검수 목록 %d행: %s" % (n, args.sample))
    say("[완료]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
