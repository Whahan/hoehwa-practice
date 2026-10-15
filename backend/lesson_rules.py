# -*- coding: utf-8 -*-
"""Rule-based lessons from real Tatoeba sentences (POST /lesson with "source": "tatoeba", the default).

No LLM: every exercise is cut out of a real sentence that has a human Korean translation, so the answers are correct
by construction. Same response shape as the LLM lesson (API.md "POST /lesson"), plus "source", per-exercise
"tatoeba_id" and the CC BY "attribution".

The sentence pool (sentences with a Korean translation, analysed with spaCy / fugashi) is built once from
data/tatoeba.sqlite and cached in cache/lesson_pool_<lang>.json (rebuilt when the DB changes).
"""
import os
import re
import json
import time
import random
import sqlite3
import difflib
import threading

import reading

H = {}  # injected by server.py: log, ApiError, ja_reading, curriculum, plain

POOL_VERSION = "3"
CACHE_DIR = os.path.join(reading.BASE, "cache")
TYPES = ["choice", "build", "listen", "fill", "build", "choice", "listen", "fill", "build", "speak"]

# stage -> (min, max) words (en) / characters (ja), and the rarest content word allowed (zipf)
EN_LEN = {1: (3, 7), 2: (3, 9), 3: (4, 12), 4: (5, 14)}
JA_LEN = {1: (4, 12), 2: (5, 16), 3: (6, 22), 4: (8, 30)}
MIN_ZIPF = {1: 4.0, 2: 3.5, 3: 3.0, 4: 0.0}
BUILD_MAX = {"en": 10, "ja": 7}

EN_CONTENT = {"NOUN", "VERB", "ADJ", "ADV"}
EN_EDGE = ".,!?;:"
EN_TILE = re.compile(r"[A-Za-z]+(?:['’-][A-Za-z]+)*")
EN_CLEAN = re.compile(r"[A-Za-z',.!?;:’ -]+")
JA_BAD = re.compile(r"[「」『』“”\"（）()A-Za-zＡ-Ｚａ-ｚ0-9０-９〜~]|\s")
JA_HEAD = {"名詞", "動詞", "形容詞", "形状詞", "副詞", "代名詞", "連体詞", "接続詞", "感動詞", "接頭辞"}
JA_ATTACH = {"助詞", "助動詞", "接尾辞", "補助記号", "記号"}

BLOCK_EN = re.compile(
    r"\b(kill\w*|die|dies|died|dying|dead|death|murder\w*|suicide|guns?|shoot\w*|shot|blood\w*|damn\w*|hell|fuck\w*|shit\w*|"
    r"sex\w*|naked|drunk|vodka|whisk(e)?y|drugs?|stupid|idiots?|hate[sd]?|ugly|bitch\w*|bastards?|ass|asshole|crap|piss\w*|"
    r"wars?|bombs?|rape\w*|slaves?|god|jesus|bible|church|prison|jail|devil|nazis?|hitler|weapons?|knife|corpse|"
    r"cigarettes?|smok\w*)\b", re.I)
BLOCK_JA = re.compile(r"死|殺|クソ|くそ|バカ|ばか|馬鹿|アホ|あほ|ブス|酔|血|銃|戦争|自殺|セックス|エッチ|うざ|畜生|地獄|神|麻薬|タバコ|煙草|刑務所")
BLOCK_KO = re.compile(r"죽|살인|섹스|씨발|젠장|멍청|바보|마약|자살|총|전쟁|지옥|감옥|담배")

SEED = {
    "en": {1: "name meet from student work like brother sister family hobby thank sorry nice",
           2: "every usually morning yesterday weekend tomorrow plan breakfast wake early late",
           3: "could please help borrow sure invite party free mean again",
           4: "coffee order menu restaurant buy price shop eat delicious cheap expensive",
           5: "travel airport hotel ticket station train bus map room trip",
           6: "phone call doctor sick medicine hospital house apartment headache fix",
           7: "ever never already yet since happen remember story experience",
           8: "think opinion agree better prefer reason because important",
           9: "should advice would dream future goal hope wish",
           10: "job company meeting office boss schedule report project email",
           11: "news problem government decide discuss change world",
           12: "favorite describe recently experience best explain"},
    "ja": {1: "名前 学生 先生 韓国 日本 人 何 これ それ ください",
           2: "起きる 食べる 行く 毎日 朝 学校 会社 ある いる 店 高い 安い",
           3: "待つ 見る 書く 読む 使う 入る 写真 窓 開ける 住む",
           4: "来る する 飲む 好き 一緒 映画 昨日 友達",
           5: "話す 泳ぐ できる 思う 予定 休み 旅行 来年",
           6: "雨 時間 早い 暑い 寒い 病気 薬 天気",
           7: "あげる くれる もらう 教える 貸す 借りる 母 父",
           8: "いらっしゃる 申す 参る 伺う 召し上がる 客 電話",
           9: "経験 意見 子供 頃 変わる 習慣 始める",
           10: "原因 理由 結果 事故 遅れる 必要 気",
           11: "本当 少し 大丈夫 無理 断る 頼む",
           12: "駅 道 計画 将来 旅行 意見"},
}

_pools = {}
_pool_lock = threading.Lock()


def init(**helpers):
    H.update(helpers)


def _log():
    return reading._log()


def _err(msg, status=400):
    return reading._err(msg, status)


def warmup():
    if reading.tatoeba_ready():
        for lang in ("en", "ja"):
            pool(lang)
            for m in range(1, 13):
                for w in range(1, 5):
                    target_vocab(lang, m, w)
        # The pools (and the models loaded before this warmup step) are long-lived: move them out of the cyclic
        # GC's reach, otherwise an occasional full collection pauses a request for 0.3-0.7 s.
        import gc
        gc.collect()
        gc.freeze()


# ----------------------------------------------------------------------------------------------
# sentence pool
# ----------------------------------------------------------------------------------------------
def _db_sig():
    st = os.stat(reading.DB_PATH)
    return "%s-%d-%d" % (POOL_VERSION, st.st_size, int(st.st_mtime))


def _ko_clean(ko):
    return bool(ko) and bool(re.search(r"[가-힣]", ko)) and not re.search(r"[一-鿿A-Za-z]", ko) and not BLOCK_KO.search(ko)


def _build_en(rows):
    nlp = reading.en_nlp()
    keep = []
    for sid, text, ko in rows:
        if not EN_CLEAN.fullmatch(text) or BLOCK_EN.search(text) or not _ko_clean(ko) or "  " in text \
                or re.search(r"[.!?;]\s+\S", text):  # one sentence only
            continue
        words = text.split()
        if not 3 <= len(words) <= 14:
            continue
        keep.append((sid, text, ko, words))
    out = []
    with reading._en_run_lock:
        docs = list(nlp.pipe([k[1] for k in keep], batch_size=512))
    for (sid, text, ko, words), doc in zip(keep, docs):
        toks = []
        for t in doc:
            if t.is_punct or t.is_space:
                continue
            lemma = (t.lemma_ or t.text).lower().replace("’", "'")
            if lemma.startswith("'"):
                lemma = reading.CLITIC.get(lemma, lemma.lstrip("'"))
            z = max(reading.zipf(lemma, "en"), reading.zipf(t.text, "en"))
            toks.append([t.text, t.idx, lemma, t.tag_, t.pos_, z, int(t.is_stop)])
        tiles = [w.strip(EN_EDGE) for w in words]
        if not all(EN_TILE.fullmatch(w) for w in tiles):
            tiles = None
        out.append({"id": sid, "text": text, "ko": ko, "n": len(words), "toks": toks, "bt": tiles})
    return out


def _ja_chunks(toks):
    """bunsetsu-like chunks: 毎朝 / 七時に / 起きます"""
    chunks = []
    prev = None
    for surf, _i, lemma, p1, p2, _z, _w in toks:
        new = p1 in JA_HEAD and p1 not in JA_ATTACH
        if prev is not None:
            pp1, pp2, plem, psurf = prev
            if pp1 == "接頭辞":
                new = False
            elif p1 == "動詞" and lemma in ("する", "できる", "致す", "いたす") and pp1 == "名詞":
                new = False
            elif p2 == "非自立可能" and pp1 in ("助詞", "助動詞") and psurf in ("て", "で"):
                new = False  # 〜ている / 〜てください / 〜てみる
            elif p1 == "形状詞" and pp1 == "接頭辞":
                new = False
        if new or not chunks:
            chunks.append(surf)
        else:
            chunks[-1] += surf
        prev = (p1, p2, lemma, surf)
    return chunks


def _build_ja(rows):
    tg = reading.ja_tagger()
    out = []
    for sid, text, ko in rows:
        if not 3 <= len(text) <= 40 or JA_BAD.search(text) or BLOCK_JA.search(text) or not _ko_clean(ko) \
                or re.search(r"[。！？!?．]+[^。！？!?．]", text):  # one sentence only
            continue
        with reading._tagger_lock:
            nodes = [(n.surface, n.feature.pos1, n.feature.pos2, reading.ja_lemma(n), reading.ja_is_word(n)) for n in tg(text)]
        if "".join(n[0] for n in nodes) != text:
            continue
        toks, i = [], 0
        for surf, p1, p2, lemma, isw in nodes:
            z = max(reading.zipf(lemma, "ja"), reading.zipf(surf, "ja")) if isw else 0.0
            toks.append([surf, i, lemma, p1, p2, z, int(isw)])
            i += len(surf)
        if sum(t[6] for t in toks) < 2:
            continue
        chunks = _ja_chunks(toks)
        last = chunks[-1].rstrip("".join(reading.JA_SENT_END) + "、")
        chunks = chunks[:-1] + ([last] if last else [])
        tail = text[len("".join(chunks)):]
        ok = all(c and c[0] not in "、。！？!?" for c in chunks) and all(ch in reading.JA_SENT_END for ch in tail)
        out.append({"id": sid, "text": text, "ko": ko, "n": len(text), "toks": toks, "bt": chunks if ok else None})
    return out


def _load_pool(lang):
    sig = _db_sig()
    path = os.path.join(CACHE_DIR, "lesson_pool_%s.json" % lang)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("sig") == sig:
            return data["items"]
    except FileNotFoundError:
        pass
    except Exception:
        _log().exception("lesson pool cache unreadable; rebuilding")
    t0 = time.time()
    con = reading._db()
    try:
        rows = con.execute("SELECT id, text, ko FROM sent WHERE lang=? AND ko IS NOT NULL ORDER BY id", (lang,)).fetchall()
    finally:
        con.close()
    items = _build_en(rows) if lang == "en" else _build_ja(rows)
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"sig": sig, "items": items}, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)
    _log().info("lesson pool %s: %d of %d sentences (%.1fs)", lang, len(items), len(rows), time.time() - t0)
    return items


class Pool:
    def __init__(self, lang, items):
        self.lang = lang
        self.items = items
        self.by_id = {it["id"]: it for it in items}
        self.vocab = {}       # (tag) -> [(surface, lemma, zipf)]   (en: fine tag; ja: "名詞-普通名詞")
        self.chunks = {}      # ja: head pos1 -> [(chunk, head lemma)]
        self.by_n = {}        # length -> items
        self.tri = set()      # (left, word, right) seen in the pool
        seen = set()
        for it in items:
            toks = it["toks"]
            words = ["<s>"] + [self.norm(t[0]) for t in toks if self.is_wordtok(t)] + ["</s>"]
            for k in range(1, len(words) - 1):
                self.tri.add((words[k - 1], words[k], words[k + 1]))
            it["lemmas"] = sorted({t[2] for t in toks if self.content(t) or self.funcword(t)})
            cz = [t[5] for t in toks if self.content(t)]
            it["dmin"] = min(cz) if cz else 7.0
            self.by_n.setdefault(it["n"], []).append(it)
            for t in toks:
                if not self.content(t):
                    continue
                key = self.vkey(t)
                surf = self.norm(t[0])
                if key and (key, surf) not in seen and (lang == "ja" or (t[0].islower() and len(surf) >= 3)):
                    seen.add((key, surf))
                    self.vocab.setdefault(key, []).append((surf, t[2], t[5]))
            if lang == "ja" and it["bt"]:
                for ch in it["bt"]:
                    head = next((t for t in toks if ch.startswith(t[0]) and t[3] in JA_HEAD), None)
                    if head and len(ch) <= 6 and not re.search(r"[、。！？!?]", ch):
                        self.chunks.setdefault(head[3], []).append((ch, head[2]))

    def norm(self, s):
        return s.lower().replace("’", "'") if self.lang == "en" else s

    def is_wordtok(self, t):
        return True if self.lang == "en" else t[3] not in ("補助記号", "記号", "空白")

    def content(self, t):
        if self.lang == "en":
            return t[4] in EN_CONTENT and not t[6] and t[0].isalpha()
        return bool(t[6]) and t[3] in ("名詞", "動詞", "形容詞", "形状詞", "副詞")

    def funcword(self, t):
        return bool(t[6]) if self.lang == "ja" else t[0].isalpha()

    def vkey(self, t):
        if self.lang == "en":
            return t[3]
        return "%s-%s" % (t[3], t[4])


def pool(lang):
    p = _pools.get(lang)
    if p is None:
        with _pool_lock:
            p = _pools.get(lang)
            if p is None:
                p = _pools[lang] = Pool(lang, _load_pool(lang))
    return p


# ----------------------------------------------------------------------------------------------
# target vocabulary from the curriculum
# ----------------------------------------------------------------------------------------------
_tv_cache = {}


def target_vocab(lang, month, week):
    key = (lang, month, week)
    if key in _tv_cache:
        return _tv_cache[key]
    plain = H.get("plain") or (lambda s: str(s or ""))
    months = H["curriculum"]()[lang]["months"]
    m = next((x for x in months if x["n"] == month), months[0])
    wk = m["weeks"][week - 1] if 0 <= week - 1 < len(m["weeks"]) else m["weeks"][0]
    weights = {}

    def add(text, w):
        text = plain(text)
        if lang == "en":
            from spacy.lang.en.stop_words import STOP_WORDS
            for f in reading.en_index_words(text):
                if len(f) < 2:
                    continue
                ww = w * (0.3 if f in STOP_WORDS else 1.0)
                for lem in [f] + reading.en_lemma_cands(f):
                    weights[lem] = max(weights.get(lem, 0), ww)
        else:
            tg = reading.ja_tagger()
            with reading._tagger_lock:
                nodes = [(reading.ja_lemma(n), n.feature.pos1, reading.ja_is_word(n)) for n in tg(text)]
            for lem, p1, isw in nodes:
                if isw and reading.JA_CHARS.search(lem):
                    ww = w * (0.3 if p1 in ("助詞", "助動詞") else 1.0)
                    weights[lem] = max(weights.get(lem, 0), ww)

    for c in m.get("content") or []:
        add(c.get("v", ""), 1.0)
    add(m.get("title", ""), 1.0)
    add(SEED[lang].get(month, ""), 2.0)
    add(wk.get("topic", "") + " " + wk.get("act", ""), 3.0)
    _tv_cache[key] = weights
    return weights


# ----------------------------------------------------------------------------------------------
# glosses already cached by /reading/gloss (used for explanations; never calls the LLM)
# ----------------------------------------------------------------------------------------------
def _gloss_meanings(lang):
    out = {}
    with reading._gcache_lock:
        cache = reading._gload()
        for k, v in cache.items():
            parts = k.split("\t")
            if len(parts) == 3 and parts[0] == lang and parts[1] not in out and v.get("ko"):
                out[parts[1]] = v["ko"]
    return out


def _copula(ko):
    hs = [c for c in ko if "가" <= c <= "힣"]
    if not hs:
        return "예요"
    return "이에요" if (ord(hs[-1]) - 0xAC00) % 28 else "예요"


def _explain(word, meanings):
    m = meanings.get(word)
    if not m:
        return ""
    return "'%s'의 뜻은 '%s'%s." % (word, m, _copula(m))


# ----------------------------------------------------------------------------------------------
# lesson
# ----------------------------------------------------------------------------------------------
def _sim(a, b):
    return difflib.SequenceMatcher(None, a, b).ratio()


class Maker:
    def __init__(self, lang, stage, rng, P, con, target, meanings):
        self.lang, self.stage, self.rng, self.P, self.con = lang, stage, rng, P, con
        self.target, self.meanings = target, meanings
        self.used = set()        # sentence ids used anywhere in this lesson (main or distractor)
        self.used_text = set()

    # ---- helpers
    def use(self, it):
        self.used.add(it["id"])
        self.used_text.add(it["text"])
        self.used_text.add(it["ko"])

    def free(self, it):
        return it["id"] not in self.used and it["text"] not in self.used_text and it["ko"] not in self.used_text

    def reading(self, s):
        return H["ja_reading"](s) if self.lang == "ja" else ""

    def explain_for(self, it, word=None):
        if word:
            return _explain(word, self.meanings)
        content = [t[2] for t in it["toks"] if self.P.content(t)]
        content.sort(key=lambda l: -self.target.get(l, 0))
        for l in content:
            e = _explain(l, self.meanings)
            if e:
                return e
        return ""

    def similar_len(self, it, k, extra_ok=None):
        """k other free sentences of similar length whose Korean and target text are clearly different"""
        tol = 2 if self.lang == "en" else 5
        cands = [o for n in range(it["n"] - tol, it["n"] + tol + 1) for o in self.P.by_n.get(n, ())]
        out = []
        for o in self.rng.sample(cands, min(len(cands), 400)):
            if o["id"] == it["id"] or not self.free(o):
                continue
            if _sim(o["ko"], it["ko"]) >= 0.5 or _sim(o["text"].lower(), it["text"].lower()) >= 0.6:
                continue
            if any(_sim(o["ko"], x["ko"]) >= 0.6 or _sim(o["text"], x["text"]) >= 0.7 for x in out):
                continue
            if extra_ok and not extra_ok(o):
                continue
            out.append(o)
            if len(out) == k:
                return out
        return None

    def options(self, correct, others):
        opts = [correct] + others
        self.rng.shuffle(opts)
        return opts, opts.index(correct)

    # ---- exercise types
    def choice(self, it):
        reverse = self.rng.random() < 0.4
        ds = self.similar_len(it, 3)
        if not ds:
            return None
        if reverse:
            q = "다음 뜻의 %s 문장은?\n%s" % ("영어" if self.lang == "en" else "일본어", it["ko"])
            opts, ans = self.options(it["text"], [d["text"] for d in ds])
        else:
            q = "다음 문장의 뜻은?\n%s" % it["text"]
            opts, ans = self.options(it["ko"], [d["ko"] for d in ds])
        for d in ds:
            self.use(d)
        return {"type": "choice", "question": q, "options": opts, "answer": ans, "explain": self.explain_for(it)}

    def listen(self, it):
        ds = self.similar_len(it, 3)
        if not ds:
            return None
        for d in ds:
            self.use(d)
        opts, ans = self.options(it["ko"], [d["ko"] for d in ds])
        return {"type": "listen", "audio": it["text"], "reading": self.reading(it["text"]), "options": opts, "answer": ans,
                "explain": self.explain_for(it)}

    def speak(self, it):
        return {"type": "speak", "text": it["text"], "reading": self.reading(it["text"]), "ko": it["ko"]}

    def build(self, it):
        bt = it["bt"]
        if not bt or not 3 <= len(bt) <= BUILD_MAX[self.lang]:
            return None
        extra = self.build_extra(it)
        if not extra:
            return None
        joined = "".join(bt) if self.lang == "ja" else " ".join(bt)
        return {"type": "build", "ko": it["ko"], "answer": list(bt), "extra": extra, "reading": self.reading(joined),
                "explain": self.explain_for(it)}

    def build_extra(self, it):
        lemmas = set(it["lemmas"])
        have = {x.lower() for x in it["bt"]}
        out = []
        if self.lang == "en":
            heads = [t for t in it["toks"] if self.P.content(t)] or [t for t in it["toks"] if t[4] in ("PRON", "AUX", "VERB")]
            self.rng.shuffle(heads)
            for h in heads * 2:
                pool = [v for v in self.P.vocab.get(h[3], []) if abs(v[2] - h[5]) <= 1.0 and v[1] not in lemmas
                        and v[0] not in have and v[0] not in out and v[0].isalpha()]
                if not pool:
                    continue
                v = self.rng.choice(pool)
                out.append(v[0])
                if len(out) == 2:
                    return out
            return None
        heads = [t for t in it["toks"] if t[3] in ("名詞", "動詞", "形容詞", "副詞") and t[6]]
        self.rng.shuffle(heads)
        for h in heads * 2:
            pool = [c for c in self.P.chunks.get(h[3], []) if c[1] not in lemmas and c[0] not in have and c[0] not in out]
            if not pool:
                continue
            out.append(self.rng.choice(pool)[0])
            if len(out) == 2:
                return out
        return None

    def slot_taken(self, left, cand, right):
        """True if `cand` already appears between the same neighbours in a real sentence: it could fit the blank."""
        if (left, cand, right) in self.P.tri:
            return True
        row = self.con.execute("SELECT id FROM vocab WHERE lang=? AND w=?", (self.lang, cand)).fetchone()
        if not row:
            return False
        texts = [r[0] for r in self.con.execute("SELECT s.text FROM post p JOIN sent s ON s.id = p.sid WHERE p.wid=?", (row[0],))]
        if self.lang == "en":
            l = r"^\W*" if left == "<s>" else r"(?<![A-Za-z'])" + re.escape(left) + r"\W+"
            r_ = r"\W*$" if right == "</s>" else r"\W+" + re.escape(right) + r"(?![A-Za-z'])"
            rx = re.compile(l + re.escape(cand) + r_, re.I)
        else:
            rx = re.compile((r"^" if left == "<s>" else re.escape(left)) + re.escape(cand) +
                            (r"[。！？!?]*$" if right == "</s>" else re.escape(right)))
        return any(rx.search(t) for t in texts)

    def fill(self, it):
        toks = it["toks"]
        words = [t for t in toks if self.P.is_wordtok(t)]
        blanks = []
        for k, t in enumerate(words):
            if not self.P.content(t) or not 3.0 <= t[5] <= 6.6:
                continue
            if self.lang == "en":
                if not t[0].isalpha() or not t[0].islower():
                    continue
                nxt = words[k + 1][0] if k + 1 < len(words) else ""
                if nxt.startswith("'") or nxt.startswith("’") or nxt.lower() == "n't":
                    continue
                s, e = t[1], t[1] + len(t[0])
                if (s > 0 and it["text"][s - 1] in "-'’") or (e < len(it["text"]) and it["text"][e] in "-'’"):
                    continue
            else:
                if t[3] != "名詞" or t[4] != "普通名詞":
                    continue
                prev = words[k - 1] if k > 0 else None
                nxt = words[k + 1] if k + 1 < len(words) else None
                if (prev and prev[3] in ("名詞", "接頭辞")) or (nxt and nxt[3] in ("名詞", "接尾辞")):
                    continue
            blanks.append(k)
        self.rng.shuffle(blanks)
        blanks.sort(key=lambda k: -self.target.get(words[k][2], 0))
        for k in blanks:
            b = words[k]
            left = self.P.norm(words[k - 1][0]) if k > 0 else "<s>"
            right = self.P.norm(words[k + 1][0]) if k + 1 < len(words) else "</s>"
            ds = self.fill_distractors(it, b, left, right)
            if not ds:
                continue
            sentence = it["text"][:b[1]] + "___" + it["text"][b[1] + len(b[0]):]
            opts, ans = self.options(b[0], ds)
            return {"type": "fill", "sentence": sentence, "reading": self.reading(sentence), "ko": it["ko"], "options": opts,
                    "answer": ans, "explain": self.explain_for(it, b[2])}
        return None

    def fill_distractors(self, it, b, left, right):
        lemmas = set(it["lemmas"])
        bsurf = self.P.norm(b[0])
        family = {b[2]} | set(reading.en_lemma_cands(bsurf) if self.lang == "en" else [])
        for tol in (0.7, 1.1):
            pool = [v for v in self.P.vocab.get(self.P.vkey(b), []) if abs(v[2] - b[5]) <= tol and v[0] != bsurf
                    and v[1] not in family and v[1] not in lemmas]
            if self.lang == "ja":  # same kind of spelling: 父 -> 母/先生, not とき/ただ
                kanji = bool(re.search(r"[一-鿿]", bsurf))
                pool = [v for v in pool if bool(re.search(r"[一-鿿]", v[0])) == kanji]
            if self.lang == "en" and left in ("a", "an"):
                vowel = bsurf[0] in "aeiou"
                pool = [v for v in pool if (v[0][0] in "aeiou") == vowel]
            if len(pool) >= 3:
                break
        if len(pool) < 3:
            return None
        self.rng.shuffle(pool)
        out = []
        for v in pool[:30]:
            if v[0] in out or self.slot_taken(left, v[0], right):
                continue
            out.append(v[0])
            if len(out) == 3:
                return out
        return None


def _eligible(P, stage):
    lens = EN_LEN if P.lang == "en" else JA_LEN
    for lo_z, (lo, hi) in ((MIN_ZIPF[stage], lens[stage]), (MIN_ZIPF[max(stage - 1, 1)] - 0.5, lens[stage]),
                           (0.0, (lens[1][0], lens[4][1]))):
        c = [it for it in P.items if lo <= it["n"] <= hi and it["dmin"] >= lo_z]
        if len(c) >= 80:
            return c
    return c


def make_lesson(lang, month, week, stage, seed=None):
    t0 = time.time()
    if not reading.tatoeba_ready():
        raise _err("예문 데이터가 아직 준비되지 않았어요.", 503)
    P = pool(lang)
    rng = random.Random(seed)
    target = target_vocab(lang, month, week)
    cands = _eligible(P, stage)
    scored = []
    for it in cands:
        s = sum(target.get(l, 0) for l in it["lemmas"])
        scored.append((min(s, 8.0) * rng.uniform(0.5, 1.5) + rng.random() * 2.5, it))
    scored.sort(key=lambda x: -x[0])
    order = [it for _s, it in scored]
    con = reading._db()
    try:
        mk = Maker(lang, stage, rng, P, con, target, _gloss_meanings(lang))
        exs = []
        for typ in TYPES:
            ex = None
            for attempt_type in ([typ, "build", "listen"] if typ == "fill" else [typ, "listen"]):
                fn = getattr(mk, attempt_type)
                tries = 0
                for it in order:
                    if not mk.free(it):
                        continue
                    tries += 1
                    if tries > 40:
                        break
                    ex = fn(it)
                    if ex:
                        ex["tatoeba_id"] = it["id"]
                        mk.use(it)
                        break
                if ex:
                    break
            if ex:
                exs.append(ex)
    finally:
        con.close()
    if len(exs) < 4:
        raise _err("예문으로 레슨을 만들지 못했어요. 다시 시도해 주세요.", 502)
    plain = H.get("plain") or (lambda s: str(s or ""))
    months = H["curriculum"]()[lang]["months"]
    m = next((x for x in months if x["n"] == month), months[0])
    wk = m["weeks"][week - 1] if 0 <= week - 1 < len(m["weeks"]) else m["weeks"][0]
    _log().info("tatoeba lesson %s m%d w%d s%d: %d exercises (%.2fs)", lang, month, week, stage, len(exs), time.time() - t0)
    return {"title": "%s · 예문 레슨" % plain(wk.get("topic") or m.get("title") or "오늘의 레슨"), "exercises": exs,
            "source": "tatoeba", "attribution": reading.ATTRIBUTION}
