# -*- coding: utf-8 -*-
"""Builds backend/data/tatoeba.sqlite (example sentences for /examples) from the official Tatoeba exports.

    .venv\\Scripts\\python.exe tatoeba_build.py            build if the DB is missing (idempotent)
    .venv\\Scripts\\python.exe tatoeba_build.py --force    rebuild
    options: --keep-raw (do not delete the downloads), --raw-dir DIR, --cap N (sentences kept per word, default 60)

Data: https://downloads.tatoeba.org/exports/per_language/  sentence text only (CC BY 2.0 FR, some CC0). Audio is NOT used.
Kept: English sentences of 3-14 words, Japanese sentences of 2-40 characters, with a direct Korean translation and
otherwise a direct English<->Japanese one. Index: English lower-case word forms (the query lemma is expanded to its
inflections through the `en_forms` table built from spaCy's lemma rules), Japanese unidic dictionary forms (fugashi).
For every word only the best `cap` sentences are kept (Korean translation first, then other translation, then shorter);
sentences that are nobody's top example are dropped, which keeps the file small.
"""
import os
import sys
import bz2
import csv
import time
import sqlite3
import argparse

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)
import reading  # noqa: E402  (shared tokenisation / lemma code; imports only the standard library at load time)

URL = "https://downloads.tatoeba.org/exports/per_language/"
FILES = {
    "eng": "eng/eng_sentences.tsv.bz2",
    "jpn": "jpn/jpn_sentences.tsv.bz2",
    "kor": "kor/kor_sentences.tsv.bz2",
    "eng-kor": "eng/eng-kor_links.tsv.bz2",
    "eng-jpn": "eng/eng-jpn_links.tsv.bz2",
    "jpn-kor": "jpn/jpn-kor_links.tsv.bz2",
}
SCHEMA_VERSION = "1"
T0 = time.time()


def say(msg):
    print("[tatoeba %5.0fs] %s" % (time.time() - T0, msg), flush=True)


def download(raw_dir):
    import requests
    os.makedirs(raw_dir, exist_ok=True)
    paths = {}
    for key, rel in FILES.items():
        dst = os.path.join(raw_dir, os.path.basename(rel))
        paths[key] = dst
        if os.path.isfile(dst) and os.path.getsize(dst) > 0:
            say("have %s" % os.path.basename(dst))
            continue
        part = dst + ".part"
        for attempt in range(3):
            try:
                with requests.get(URL + rel, stream=True, timeout=60) as r:
                    r.raise_for_status()
                    total = int(r.headers.get("content-length") or 0)
                    got, last = 0, 0
                    with open(part, "wb") as f:
                        for chunk in r.iter_content(1 << 20):
                            f.write(chunk)
                            got += len(chunk)
                            if got - last >= (8 << 20):
                                last = got
                                say("  %s %.0f / %.0f MB" % (os.path.basename(dst), got / 1e6, total / 1e6))
                os.replace(part, dst)
                say("downloaded %s (%.1f MB)" % (os.path.basename(dst), os.path.getsize(dst) / 1e6))
                break
            except Exception as e:
                say("download %s failed (%s)%s" % (rel, e, ", retrying" if attempt < 2 else ""))
                if attempt == 2:
                    raise
                time.sleep(3)
    return paths


def rows(path):
    with bz2.open(path, "rt", encoding="utf-8", newline="") as f:
        for line in f:
            p = line.rstrip("\r\n").split("\t")
            if len(p) >= 2:
                yield p


def read_sentences(path):
    out = {}
    for p in rows(path):
        if len(p) >= 3 and p[0].isdigit():
            out[int(p[0])] = " ".join(p[2].split())
    return out


def read_links(path, src_ids, dst_ids):
    """{src_id: [dst_id, ...]} for link rows in either column order"""
    m = {}
    for p in rows(path):
        if not (p[0].isdigit() and p[1].isdigit()):
            continue
        a, b = int(p[0]), int(p[1])
        if a in src_ids and b in dst_ids:
            m.setdefault(a, []).append(b)
        elif b in src_ids and a in dst_ids:
            m.setdefault(b, []).append(a)
    return m


def pick(ids, texts):
    """first (lowest id = usually the original / most reviewed) translation that exists"""
    for i in sorted(ids or ()):
        t = texts.get(i)
        if t:
            return t
    return ""


def build(db_path, raw_dir, cap, keep_raw):
    paths = download(raw_dir)
    say("reading Korean / Japanese sentences ...")
    kor = read_sentences(paths["kor"])
    jpn_all = read_sentences(paths["jpn"])
    say("  kor %d, jpn %d" % (len(kor), len(jpn_all)))

    # English ids: stream once to learn which ids exist (needed to read the link files)
    say("reading English sentences ...")
    eng_ok = {}  # id -> text, 3..14 words
    eng_ids = set()
    n_eng = 0
    for p in rows(paths["eng"]):
        if len(p) < 3 or not p[0].isdigit():
            continue
        n_eng += 1
        sid = int(p[0])
        eng_ids.add(sid)
        text = " ".join(p[2].split())
        nw = len(reading.EN_WORD_RE.findall(text))
        if 3 <= nw <= 14 and len(text) <= 120:
            eng_ok[sid] = text
    say("  eng %d, kept %d (3-14 words)" % (n_eng, len(eng_ok)))

    say("reading links ...")
    kor_ids = set(kor)
    jpn_ids = set(jpn_all)
    ek = read_links(paths["eng-kor"], eng_ids, kor_ids)
    jk = read_links(paths["jpn-kor"], jpn_ids, kor_ids)
    ej = read_links(paths["eng-jpn"], eng_ids, jpn_ids)
    je = read_links(paths["eng-jpn"], jpn_ids, eng_ids)
    say("  eng-kor %d, jpn-kor %d, eng-jpn %d, jpn-eng %d sentences linked" % (len(ek), len(jk), len(ej), len(je)))
    need_eng = {e for ids in je.values() for e in ids}
    eng_tr = {}
    for p in rows(paths["eng"]):
        if len(p) >= 3 and p[0].isdigit() and int(p[0]) in need_eng:
            eng_tr[int(p[0])] = " ".join(p[2].split())
    del eng_ids

    tmp = db_path + ".tmp"
    for f in (tmp, tmp + "-journal"):
        if os.path.exists(f):
            os.remove(f)
    con = sqlite3.connect(tmp)
    con.executescript("""
        PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-200000;
        CREATE TABLE sent(id INTEGER PRIMARY KEY, lang TEXT NOT NULL, text TEXT NOT NULL, ko TEXT, tr TEXT, k INTEGER NOT NULL);
        CREATE TABLE vocab(id INTEGER PRIMARY KEY, lang TEXT NOT NULL, w TEXT NOT NULL, UNIQUE(lang, w));
        CREATE TABLE post(wid INTEGER NOT NULL, k INTEGER NOT NULL, sid INTEGER NOT NULL, PRIMARY KEY(wid, k, sid)) WITHOUT ROWID;
        CREATE TABLE en_forms(lemma TEXT NOT NULL, form TEXT NOT NULL, PRIMARY KEY(lemma, form)) WITHOUT ROWID;
        CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT);
    """)

    def key(ko, tr, length):
        return (0 if ko else 1 if tr else 2) * 1000 + min(length, 999)

    say("writing candidate sentences ...")
    batch = []
    for sid, text in eng_ok.items():
        ko = pick(ek.get(sid), kor)
        tr = "" if ko else pick(ej.get(sid), jpn_all)
        batch.append((sid, "en", text, ko or None, tr or None, key(ko, tr, len(text))))
    n_ja = 0
    for sid, text in jpn_all.items():
        if not (2 <= len(text) <= 40):
            continue
        n_ja += 1
        ko = pick(jk.get(sid), kor)
        tr = "" if ko else pick(je.get(sid), eng_tr)
        batch.append((sid, "ja", text, ko or None, tr or None, key(ko, tr, len(text))))
    con.executemany("INSERT INTO sent VALUES (?,?,?,?,?,?)", batch)
    con.commit()
    say("  %d en + %d ja candidates" % (len(eng_ok), n_ja))
    del batch, eng_ok, jpn_all, eng_tr

    vocab = {}
    count = {}
    posts = []

    def index(lang, words, k, sid):
        for w in words:
            vk = (lang, w)
            c = count.get(vk, 0)
            if c >= cap:
                continue
            count[vk] = c + 1
            wid = vocab.get(vk)
            if wid is None:
                wid = vocab[vk] = len(vocab) + 1
            posts.append((wid, k, sid))

    say("indexing English (lower-case word forms) ...")
    n = 0
    for sid, text, k in con.execute("SELECT id, text, k FROM sent WHERE lang='en' ORDER BY k, id"):
        index("en", reading.en_index_words(text), k, sid)
        n += 1
        if n % 200000 == 0:
            say("  %d sentences" % n)
    say("indexing Japanese (fugashi dictionary forms) ...")
    n = 0
    for sid, text, k in con.execute("SELECT id, text, k FROM sent WHERE lang='ja' ORDER BY k, id"):
        index("ja", reading.ja_index_words(text), k, sid)
        n += 1
        if n % 50000 == 0:
            say("  %d sentences" % n)
    con.executemany("INSERT INTO vocab VALUES (?,?,?)", [(wid, l, w) for (l, w), wid in vocab.items()])
    con.executemany("INSERT INTO post VALUES (?,?,?)", posts)
    say("  vocab %d, postings %d" % (len(vocab), len(posts)))
    del posts, count

    say("English inflection table (spaCy lemma rules) ...")
    import spacy
    nlp = spacy.load("en_core_web_sm", exclude=["tok2vec", "tagger", "parser", "ner", "senter", "attribute_ruler"])
    tables = reading._lem_tables(nlp)
    forms = set()
    for (l, w) in vocab:
        if l == "en":
            for lem in reading.en_lemma_cands(w, tables):
                forms.add((lem, w))
    con.executemany("INSERT INTO en_forms VALUES (?,?)", sorted(forms))
    say("  %d (lemma, form) pairs" % len(forms))

    say("dropping sentences that are no word's top example ...")
    con.execute("CREATE TEMP TABLE used(id INTEGER PRIMARY KEY)")
    con.execute("INSERT INTO used SELECT DISTINCT sid FROM post")
    con.execute("DELETE FROM sent WHERE id NOT IN (SELECT id FROM used)")
    con.execute("CREATE INDEX sent_lang_k ON sent(lang, k)")
    stats = {r[0]: r[1] for r in con.execute("SELECT lang, COUNT(*) FROM sent GROUP BY lang")}
    stats_ko = {r[0]: r[1] for r in con.execute("SELECT lang, COUNT(*) FROM sent WHERE ko IS NOT NULL GROUP BY lang")}
    meta = {"version": SCHEMA_VERSION, "built": time.strftime("%Y-%m-%d %H:%M:%S"), "source": URL, "cap": str(cap),
            "license": "CC BY 2.0 FR (Tatoeba sentence text; some CC0)", "attribution": reading.ATTRIBUTION}
    con.executemany("INSERT INTO meta VALUES (?,?)", meta.items())
    con.commit()
    say("VACUUM ...")
    con.execute("VACUUM")
    con.close()
    os.replace(tmp, db_path)
    size = os.path.getsize(db_path) / 1e6
    say("DONE %s  %.1f MB  sentences en=%d (ko %d) ja=%d (ko %d)  vocab=%d" % (
        db_path, size, stats.get("en", 0), stats_ko.get("en", 0), stats.get("ja", 0), stats_ko.get("ja", 0), len(vocab)))
    if not keep_raw:
        for p in paths.values():
            try:
                os.remove(p)
            except OSError:
                pass
        try:
            os.rmdir(raw_dir)
        except OSError:
            pass
        say("raw downloads deleted")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--keep-raw", action="store_true")
    ap.add_argument("--raw-dir", default=os.path.join(reading.DATA_DIR, "_raw"))
    ap.add_argument("--cap", type=int, default=60)
    ap.add_argument("--db", default=reading.DB_PATH)
    a = ap.parse_args()
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if os.path.isfile(a.db) and not a.force:
        try:
            con = sqlite3.connect(a.db)
            v = con.execute("SELECT v FROM meta WHERE k='version'").fetchone()
            con.close()
            if v and v[0] == SCHEMA_VERSION:
                say("already built: %s (%.1f MB); use --force to rebuild" % (a.db, os.path.getsize(a.db) / 1e6))
                return 0
        except Exception:
            pass
        say("existing DB is outdated or unreadable, rebuilding")
    os.makedirs(os.path.dirname(a.db), exist_ok=True)
    build(a.db, a.raw_dir, a.cap, a.keep_raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
