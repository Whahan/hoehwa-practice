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
import sys
import json
import time
import random
import sqlite3
import zlib
import hashlib
import difflib
import threading

import reading

H = {}  # injected by server.py: log, ApiError, ja_reading, curriculum, plain

POOL_VERSION = "4"
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
    r"\b("
    # violence, death, weapons
    r"kill\w*|die[sd]?|dying|dead(ly)?|death\w*|murder\w*|suicid\w*|assassin\w*|massacre\w*|genocid\w*|slaughter\w*|lynch\w*|"
    r"strangl\w*|hostages?|abduct\w*|hanged|assault\w*|kidnap\w*|tortur\w*|violen\w*|"
    r"guns?|pistols?|rifles?|gun(man|men|fire|shot|shots|point|powder)|bomb(s|ed|er|ers|ing|ings|ard\w*|shells?)?|"
    r"wars?|warfare|weapons?|knife|knives|knifed|blood\w*|corpses?|"
    # sex, abuse, crime
    r"sex(es|y|ier|iest|ual\w*|ist\w*|ism)?|naked|nude[sd]?|nudity|porn\w*|rap(e|ed|es|ing|ist|ists)|molest\w*|pedophil\w*|paedophil\w*|"
    r"prostitut\w*|abus\w*|abortions?|condoms?|slave\w*|"
    # drugs, alcohol, tobacco
    r"drugs?|drugged|heroin|cocaine|meth|methamphetamine\w*|amphetamines?|marijuana|cannabis|opium|opiates?|narcotics?|overdos\w*|lsd|"
    r"addict\w*|alcoholics?|alcoholism|drunk\w*|vodka|whisk(e)?y|cigarettes?|smok\w*|"
    # insults, swearing, hatred
    r"damn\w*|goddamn\w*|hell|fuck\w*|shit\w*|bullshit\w*|bitch\w*|bastards?|ass(es|holes?)?|crap\w*|piss(ed|es|ing|y)?|cum|"
    r"stupid\w*|idiot\w*|hat(e[sd]?|ing|red)|ugl(y|ier|iest)|racis\w*|"
    # religion, politics, illness
    r"god|gods|goddess\w*|jesus|bible|bibles|church(es)?|devils?|nazis?|hitler|terror\w*|"
    r"prison\w*|imprison\w*|jail\w*|cancer\w*)\b", re.I)

# Japanese: a stem only counts when it sits on morpheme boundaries (fugashi), so 神戸 / 神社 / 神経 / ばかり / テロップ /
# ナチュラル / 死角 / 血液型 are fine while 神 / 死ね / バカ / テロ / 殺す are not. BLOCK_JA is only the cheap pre-filter
# (any stem occurs as a substring); blocked() confirms the hit on the morphemes.
JA_STEMS = (
    # death / killing
    "死 死亡 死体 死刑 死者 死人 死骸 死因 死去 死別 戦死 病死 溺死 餓死 焼死 変死 即死 急死 怪死 殉死 "
    "殺 殺人 殺し屋 人殺し 殺害 殺意 殺戮 暗殺 射殺 惨殺 毒殺 虐殺 絞殺 撲殺 刺殺 斬殺 自殺 遺体 "
    # blood, guns, war, bombs, terror
    "血 出血 流血 吐血 鮮血 銃 拳銃 銃声 機関銃 猟銃 銃弾 銃撃 小銃 散弾銃 戦争 "
    "爆弾 爆発 爆破 爆撃 テロ テロリスト テロリズム 刑務所 地獄 "
    # abuse, crime, drugs
    "虐待 誘拐 拷問 拉致 監禁 暴力 暴行 レイプ 強姦 痴漢 売春 "
    "麻薬 覚醒剤 覚せい剤 ヘロイン コカイン マリファナ 大麻 阿片 アヘン 中絶 堕胎 "
    "酔 酔っ払 タバコ たばこ 煙草 喫煙 "
    # sex
    "セックス エッチ ポルノ "
    # insults
    "クソ くそ バカ ばか 馬鹿 アホ あほ 阿呆 ブス うざい うざったい ウザイ ウザい 畜生 "
    # religion / politics
    "神 神々 ナチ ナチス ナチズム ヒトラー"
).split()
# stems that may be followed by hiragana okurigana inside the same morpheme (死んだ, 殺し, 酔っ払い, 血まみれ, 神さま)
JA_STEM_TAIL = {s for s in JA_STEMS if "\u4e00" <= s[-1] <= "\u9fff"}
BLOCK_JA = re.compile("|".join(re.escape(s) for s in sorted(JA_STEMS, key=len, reverse=True)))
_JA_STEM_SET = set(JA_STEMS)
_JA_BY_FIRST = {}
for _s in sorted(JA_STEMS, key=len, reverse=True):
    _JA_BY_FIRST.setdefault(_s[0], []).append(_s)
_HIRA = re.compile(r"[ぁ-ゟ]+")
_ja_cache = {}
BLOCK_RULES_VERSION = "3"  # bump when the matching logic (not the word lists) changes: it is part of the pool cache signature
# Korean: 총 / 죽 alone are NOT blocked (총장 총무 총 3개 / 호박죽 죽 한 그릇 are fine): only the weapon / killing / dying forms are.
# 죽 counts only at the start of a word (a preceding syllable means 호박죽 / 팥죽 ...) and only with a verb ending (죽이 / 죽을 먹다 pass).
BLOCK_KO = re.compile(
    r"살인|섹스|씨발|젠장|멍청|바보|마약|자살|전쟁|지옥|감옥|담배|테러|폭탄|포르노|강간"
    r"|총기|총격|총살|총탄|총알|총소리|총성|총질|총포|총잡이|총부리|총상(?!금)|권총|기관총|소총|엽총|총으로"
    r"|(?<![가-힣])총(?:이|을|를|은|는|과|와)(?![가-힣])"
    r"|총에 ?(?:맞|쏘|찔)|총 ?[을를]? ?(?:쏘|쏜|쐈|쏴|쏠|겨누|난사|맞(?:았|아|은|는|고|지|기))"
    r"|(?<![가-힣])죽(?:이[다고는지면려라며]|인|임|였|여|일|어|음|으(?!로)|고|는|자|지|기|도록|겠|었|다|나|네|습|게"
    r"|은(?! ?(?:맛|건강|먹|따뜻|뜨거|부드|소화|영양|아침|한 |한국)))"
    r"|(?<![가-힣])죽을(?! ?(?:먹|끓|쑤|만들|주문|시키|사|드|데우|좋아|싫어|한 |그릇))"
    r"|(?:굶어|얼어|맞아|빠져|따라|타|때려|쳐|치어|깔려|밟혀|눌려|말라|목매)죽")


def _ja_blocked(text):
    """True if the Japanese `text` contains a blocked word on morpheme boundaries (or a morpheme whose dictionary form is one)"""
    if not BLOCK_JA.search(text):
        return False
    hit = _ja_cache.get(text)
    if hit is not None:
        return hit
    try:
        tg = reading.ja_tagger()
        with reading._tagger_lock:
            nodes = [(n.surface, (n.feature.lemma or "").split("-")[0]) for n in tg(text)]
    except Exception:
        return True  # cannot analyse -> stay on the safe side
    starts, ends, lemmas, pos = {}, {}, set(), 0
    for surf, lem in nodes:
        i = text.find(surf, pos)
        if i < 0:
            continue
        pos = i + len(surf)
        starts[i] = pos
        ends[pos] = i
        lemmas.add(lem)
        for k in range(i, pos):
            ends.setdefault(("in", k), pos)
    hit = bool(lemmas & _JA_STEM_SET)
    if not hit:
        for i in range(len(text)):
            if i not in starts:
                continue
            for st in _JA_BY_FIRST.get(text[i], ()):
                if not text.startswith(st, i):
                    continue
                e = i + len(st)
                if e in ends:
                    hit = True
                elif st in JA_STEM_TAIL:
                    te = ends.get(("in", e - 1))   # end of the morpheme that contains the stem's last character
                    hit = te is not None and bool(_HIRA.fullmatch(text[e:te]))
                if hit:
                    break
            if hit:
                break
    if len(_ja_cache) > 20000:
        _ja_cache.clear()
    _ja_cache[text] = hit
    return hit


# English shoot / shot: blocked as violence, unless it is a harmless sense (shoot photos, a flu shot, give it a shot, a good shot ...)
BLOCK_EN_SHOOT = re.compile(r"\b(?:shoot\w*|shot|shots)\b", re.I)
_DET = r"(?:(?:a|an|the|some|any|my|your|his|her|our|their|more|many|good|nice|great|beautiful|new|few|lot|lots|of)\s+){0,3}"
# a person / group as the target: "a shot at him", "a good shot at the police" stay blocked
_TGT = (r"(?:him|her|them|me|you|us|people|someone|somebody|everyone|anyone|"
        r"(?:the|a|an)\s+(?:\w+\s+)?(?:man|men|woman|women|boy|girl|police\w*|cops?|guards?|officers?|enemy|enemies|soldiers?|"
        r"president|children|kids?|crowd|passers?-?by|students?|teachers?|neighbou?rs?))\b")
_EN_SHOOT_OK = re.compile(
    r"\b(?:shoot|shoots|shooting|shot)\s+" + _DET + r"(?:photos?|photographs?|pictures?|pics?|films?|videos?|movies?|scenes?|footage|"
    r"hoops?|baskets?|commercials?|portraits?|selfies?|documentar\w+|episodes?|trailers?|balls?|goals?|penalt\w+|free\s+throws?|pool|dice)\b"
    r"|\b(?:photo|film|video|fashion|wedding|magazine|movie|photography|commercial)\s+shoots?\b"
    r"|\b(?:bamboo|bean|pea|new|young|green)\s+shoots?\b"
    r"|\bshooting\s+stars?\b|\bshoots?\s+(?:the\s+)?breeze\b|\bshoot(?:s|ing)?\s+for\s+(?:the\s+)?(?:moon|stars|gold)\b"
    r"|\bshot\s+put\b|\bshot\s+clock\b|\bshot\s+glass(?:es)?\b|\bshots?\s+of\s+(?:espresso|coffee|syrup)\b"
    r"|\b(?:flu|covid|booster|vaccin\w*|tetanus|allergy|measles|polio|insulin|b12|\d+(?:st|nd|rd|th))\s+shots?\b"
    r"|\b(?:give|gave|giving|gives|take|took|taking|takes|have|had|having)\s+(?:it|this|that)\s+(?:a|one)\s+(?:good\s+)?shot\b"
    r"|\b(?:take|took|taking|takes)\s+" + _DET + r"(?:\w+\s+)?shots?\s+of\s+(?!" + _TGT + r")"
    r"|\ba\s+shot\s+at\s+(?!" + _TGT + r")"
    r"|\b(?:good|nice|great|best|long|big|hot|jump|slap|free|wide|close-up)\s+shots?\b(?!\s+(?:at|into|through|to)\s+" + _TGT + r")", re.I)


def _en_shoot_blocked(text):
    rest = _EN_SHOOT_OK.sub(" ", text)
    return bool(BLOCK_EN_SHOOT.search(rest))


def blocked(text):
    """True if `text` (a sentence, option, distractor word or tile in either language) is on the block list"""
    return bool(BLOCK_EN.search(text) or _en_shoot_blocked(text) or _ja_blocked(text))

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

# ---- English wrong options / extra tiles must be real, independent words
VOCAB_RULES_VERSION = "1"
VOCAB_MIN_ZIPF = 3.1       # surface form (not its lemma): "downed" 3.3 is caught by VOCAB_FORM_GAP, "tion" 2.8 is too rare
VOCAB_FORM_GAP = 1.8       # a rare inflection of a common word ("downed" of "down", "cools", "gon" of "gonna") is no good option
AFFIXES = set("""anti ante arch auto bi circum co contra counter cross de dis en em epi ex extra fore hetero homo hyper hypo il im in ir
infra inter intra iso macro mal mega meta micro mid mini mis mono multi neo non omni out over para peri photo poly post pre pro pseudo
quasi re retro self semi step sub super supra sur syn techno tele trans tri ultra un under uni up vice with""".split())
NOT_WORDS = set("gon wan ca sha ai ain isn gonna wanna gotta lemme gimme kinda sorta cuz tho thru til mapo".split())
_vocab_ok = {}


def _real_word(surf, lemma, wn):
    """True if `surf` can stand on its own as an English word: not an affix / contraction stub, common enough as written,
    not a rare inflection of a common word, and known to WordNet (when it is available)"""
    key = (surf, lemma)
    v = _vocab_ok.get(key)
    if v is not None:
        return v
    z, zl = reading.zipf(surf, "en"), reading.zipf(lemma, "en")
    ok = surf.isalpha() and surf not in AFFIXES and surf not in NOT_WORDS and z >= VOCAB_MIN_ZIPF         and not (zl - z > VOCAB_FORM_GAP and z < 4.0)
    if ok and wn is not None:
        with _wn_q_lock:
            try:
                ok = bool(wn.synsets(surf) or wn.synsets(lemma))
            except Exception:
                pass
    _vocab_ok[key] = ok
    return ok


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
        try:
            _prime_wordnet(pool("en"))
        except Exception:
            _log().exception("WordNet priming failed")
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
    # the block lists are part of the signature: editing them makes old pool caches refresh
    bl = hashlib.md5("".join((BLOCK_EN.pattern, BLOCK_EN_SHOOT.pattern, _EN_SHOOT_OK.pattern, BLOCK_JA.pattern, " ".join(JA_STEMS), BLOCK_KO.pattern, BLOCK_RULES_VERSION,
                                  VOCAB_RULES_VERSION)).encode("utf-8")).hexdigest()[:8]
    return "%s-%s-%d-%d" % (POOL_VERSION, bl, st.st_size, int(st.st_mtime))


# ----------------------------------------------------------------------------------------------
# "could this distractor also be right?" -- offline checks (no LLM)
#   English: WordNet (shared synset / direct hypernym / hyponym / similar-to), curated "never mix" groups, and the
#            whole English Tatoeba corpus (the sentence with the distractor, or the word triple around the blank, exists).
#   Japanese: shares a kanji with the answer, or is a near-synonym from a small table.
# ----------------------------------------------------------------------------------------------
NLTK_DIR = os.path.join(reading.BASE, "models", "nltk_data")
NLTK_PKGS = ("wordnet", "omw-1.4")
_wn_state = {"wn": None, "tried": False}
_wn_lock = threading.Lock()      # guards loading
_wn_q_lock = threading.Lock()    # NLTK's WordNet reader seeks in shared file handles: one query at a time
_rel_cache = {}


def ensure_wordnet_data():
    """Download wordnet + omw-1.4 into backend/models/nltk_data (only done by `server.py --prefetch`, never at run time)."""
    try:
        import nltk
        os.makedirs(NLTK_DIR, exist_ok=True)
        for pkg in NLTK_PKGS:
            have = os.path.exists(os.path.join(NLTK_DIR, "corpora", pkg + ".zip")) or os.path.isdir(os.path.join(NLTK_DIR, "corpora", pkg))
            if not have:
                nltk.download(pkg, download_dir=NLTK_DIR, quiet=True)
        # nltk.download() returns False instead of raising when offline: trust only what is on disk
        return all(os.path.exists(os.path.join(NLTK_DIR, "corpora", pkg + ".zip")) or os.path.isdir(os.path.join(NLTK_DIR, "corpora", pkg))
                   for pkg in NLTK_PKGS)
    except Exception:
        _log().exception("could not download the WordNet data for the lesson distractor check")
        return False


def wordnet():
    """the nltk WordNet reader, or None if nltk / the data is missing (the curated groups still apply then)"""
    if _wn_state["tried"]:
        return _wn_state["wn"]
    with _wn_lock:
        if _wn_state["tried"]:
            return _wn_state["wn"]
        try:
            import nltk
            if NLTK_DIR not in nltk.data.path:
                nltk.data.path.insert(0, NLTK_DIR)
            from nltk.corpus import wordnet as wn
            wn.synsets("test")  # loads the data (about 1.5 s)
            _wn_state["wn"] = wn
        except Exception:
            _log().warning("WordNet is not available (pip install nltk + server.py --prefetch); using the curated synonym groups only")
        _wn_state["tried"] = True
    return _wn_state["wn"]


def _groups(lines):
    out = {}
    for gi, line in enumerate(lines):
        for w in line.split():
            out.setdefault(w, set()).add(gi)
    return out


# Words of one line are interchangeable in many sentences ("never mix" them as answer + distractor).
EN_GROUP_LINES = [
    # evaluation adjectives
    "good great nice fine excellent wonderful lovely pleasant terrific fantastic awesome amazing marvelous superb splendid brilliant "
    "perfect super cool decent neat impressive outstanding beautiful pretty gorgeous sweet charming attractive handsome cute fabulous",
    "bad terrible awful horrible dreadful lousy poor nasty rotten",
    "big large huge enormous giant massive vast great tremendous gigantic",
    "small little tiny",
    "fast quick rapid swift speedy",
    "happy glad pleased delighted cheerful joyful content",
    "sad unhappy sorrowful miserable depressed",
    "angry mad upset furious annoyed irritated",
    "afraid scared frightened terrified fearful",
    "tired exhausted weary sleepy",
    "hard difficult tough challenging",
    "easy simple effortless",
    "strange odd weird unusual peculiar curious funny",
    "important essential crucial vital serious significant necessary",
    "sure certain positive confident",
    "real true actual genuine",
    "wrong incorrect mistaken false",
    "right correct proper accurate",
    "interesting fascinating exciting entertaining amusing funny",
    "boring dull tedious",
    "clever smart intelligent bright wise",
    "kind nice friendly gentle generous polite",
    "famous popular well-known",
    "rich wealthy",
    "cheap inexpensive",
    "expensive costly pricey",
    "old ancient elderly aged",
    "new fresh modern recent",
    "hot warm",
    "cold cool chilly freezing",
    "dirty filthy messy",
    "quiet silent calm peaceful still",
    "loud noisy",
    "dangerous risky unsafe",
    "safe secure",
    "careful cautious",
    "ready prepared",
    "different various",
    "same identical similar",
    "whole entire full complete total",
    "sick ill",
    "free available",
    "busy occupied",
    "clean tidy neat",
    "empty vacant",
    "beautiful pretty lovely gorgeous",
    # adverbs
    "very really quite extremely pretty so highly truly rather fairly",
    "quickly fast rapidly soon promptly",
    "usually normally generally typically often frequently commonly regularly",
    "always constantly forever",
    "sometimes occasionally",
    "almost nearly practically",
    "just only simply merely",
    "maybe perhaps possibly probably",
    "hardly barely scarcely rarely seldom",
    "well nicely fine",
    "badly poorly",
    "finally eventually lastly",
    "recently lately",
    "carefully cautiously",
    "slowly gradually",
    # mental / opinion verbs ("I ___ that ...")
    "think believe feel guess suppose imagine assume reckon expect hope suspect consider know realize understand find say see hear "
    "remember doubt mean figure notice learn",
    # verbs followed by "to ..." ("why Layla ___ to take off ...")
    "decide plan want need try choose refuse agree promise prefer wish intend hope begin start continue like love hate offer manage fail "
    "forget learn seem appear tend attempt dare expect threaten prepare arrange determine resolve hesitate aim ask afford bother claim demand deserve long pretend proceed seek swear volunteer struggle propose vow happen "
    "happen",
    "happen occur come",
    "say tell speak talk",
    "look seem appear sound",
    "see watch notice look",
    "hear listen",
    "buy purchase get",
    "make create build produce",
    "get receive obtain gain",
    "take bring carry",
    "give offer provide present",
    "show display demonstrate",
    "help assist aid",
    "use utilize employ",
    "stop quit cease finish end",
    "start begin commence",
    "keep hold retain",
    "leave depart",
    "arrive reach",
    "ask request",
    "answer reply respond",
    "call phone",
    "find discover",
    "lose miss",
    "stay remain",
    "live reside",
    "love like enjoy adore",
    "hate dislike",
    "go walk run drive ride travel fly sail move come hurry head",
    "eat have",
    "study learn",
    "put place set lay",
    "send mail",
    "win beat",
    "pick choose select",
    "fix repair mend",
    "break destroy",
    "allow let permit",
    "forbid ban prohibit",
    "need require",
    "cry weep",
    "laugh smile",
    "sleep rest",
    "wash clean",
    "change alter",
    "catch grab",
    "hit strike beat",
    "increase rise raise grow",
    "decrease drop fall reduce",
    "explain describe",
    "check examine",
    "buy pay",
    "wait stay",
    "open begin",
    "close shut",
    "do make",
    # nouns
    "people persons beings folks humans citizens",
    "today tonight",
    "company firm business corporation",
    "group team band crew",
    "story article",
    "weekend holiday vacation",
    "quick fast",
    "begin start",
    "live lead spend",
    "village town city",
    "doctor surgeon physician",
    "lawyer attorney",
    "student pupil",
    "hospital clinic",
    "stomach belly",
    "picture painting drawing",
    "supper dinner",
    "wife woman",
    "husband man",
    "man guy fellow gentleman male",
    "woman lady female",
    "boy lad",
    "child kid",
    "house home building",
    "car vehicle automobile",
    "job work occupation career",
    "problem trouble issue difficulty",
    "idea thought notion",
    "mistake error fault",
    "answer reply response",
    "trip journey voyage tour",
    "shop store market",
    "picture photo photograph image",
    "film movie",
    "friend pal buddy",
    "money cash",
    "price cost fee fare charge",
    "story tale",
    "reason cause",
    "city town",
    "country nation",
    "road street way path",
    "dinner supper meal",
    "sofa couch",
    "mom mother",
    "dad father",
    "teacher instructor",
    "doctor physician",
    "boss manager",
    "pain ache",
    "plan scheme",
    "gift present",
    "holiday vacation",
    "party celebration",
    "voice sound noise",
    "chance opportunity",
    "danger risk",
    "luck fortune",
    "habit custom",
    "coat jacket",
    "pants trousers",
    "ship boat",
    "bike bicycle",
    "letter mail",
]
EN_GROUP = _groups(EN_GROUP_LINES)

JA_GROUP_LINES = [
    "人 者 方 人間 人物",
    "物 もの 品 品物 やつ モノ 代物",
    "奴 やつ 野郎",
    "事 思い 考え",
    "事 こと 件",
    "時 頃 ころ とき 時間 時刻",
    "家 家庭 うち 住宅 自宅",
    "店 お店 商店 店舗 屋",
    "先生 教師 教授",
    "子供 子ども こども 児童 子",
    "女 女性 女の人",
    "男 男性 男の人",
    "車 自動車 クルマ",
    "道 道路 通り",
    "国 国家 祖国",
    "仕事 職 職業 業務 勤め",
    "会社 企業 商社",
    "言葉 言語 語 単語 ことば",
    "本 書物 書籍",
    "お金 金 金銭 おかね",
    "病気 疾患 病",
    "写真 画像 フォト",
    "勉強 学習",
    "問題 課題 トラブル",
    "意見 考え 見解 思い",
    "理由 訳 わけ 原因",
    "気持ち 気分 感情 心",
    "食べ物 食物 料理 食事 ご飯 ごはん",
    "部屋 室",
    "所 場所 ところ 所",
    "今日 本日",
    "昨日 きのう",
    "去年 昨年",
    "友達 友人 仲間 ともだち",
    "彼 彼女 彼ら",
    "君 あなた お前 貴方",
    "僕 私 俺 わたし",
    "話 お話 会話 物語",
    "音 音声 声",
    "夢 願い 希望",
    "朝 午前",
    "夜 晩 夕方",
    "駅 停車場",
    "お母さん 母 ママ 母親",
    "お父さん 父 パパ 父親",
    "兄 お兄さん 兄さん",
    "姉 お姉さん 姉さん",
    "犬 いぬ",
    "猫 ねこ",
    "水 お水",
    "雨 雨天",
    "天気 天候",
    "使い方 用法",
    "習慣 癖 慣習",
    "間違い ミス 誤り",
    "答え 返事 回答",
    "旅行 旅 ツアー",
    "海 海洋",
    "山 峰",
    "お茶 茶",
    "辞書 事典",
]
JA_GROUP = _groups(JA_GROUP_LINES)
KANJI = re.compile(r"[一-鿿々]")


def _pos_letter(tag):
    c = (tag or "")[:1]
    return {"V": "v", "N": "n", "J": "a", "R": "r"}.get(c)


def en_related(a, b, tag):
    """True if lemma `b` could replace lemma `a` (same word class `tag`) so that the sentence stays correct: same curated
    group, or in WordNet a shared synset / direct hypernym / hyponym / similar-to / also-see / verb-group link."""
    if a == b:
        return True
    key = (a, b, tag[:1])
    hit = _rel_cache.get(key)
    if hit is not None:
        return hit
    ga, gb = EN_GROUP.get(a), EN_GROUP.get(b)
    res = bool(ga and gb and ga & gb)
    if not res:
        wn = wordnet()
        pos = _pos_letter(tag)
        if wn is not None and pos:
            with _wn_q_lock:
                try:
                    sa = set(wn.synsets(a, pos))
                    sb = set(wn.synsets(b, pos))
                    if sa & sb:
                        res = True
                    else:
                        for s in sa:
                            near = set(s.hypernyms()) | set(s.hyponyms()) | set(s.similar_tos()) | set(s.also_sees()) | set(s.verb_groups())
                            if near & sb:
                                res = True
                                break
                except Exception:
                    res = False
    _rel_cache[key] = res
    return res


def _prime_wordnet(P):
    """read the WordNet entries of every candidate word once at start-up, so the first lessons are not slower"""
    wn = wordnet()
    if wn is None:
        return
    t0 = time.time()
    n = 0
    with _wn_q_lock:
        for tag, lst in P.vocab.items():
            pos = _pos_letter(tag)
            if not pos:
                continue
            for _surf, lemma, _z in lst:
                for s in wn.synsets(lemma, pos)[:6]:
                    s.hypernyms(), s.hyponyms(), s.similar_tos(), s.also_sees()
                n += 1
    _log().info("WordNet primed for %d candidate words (%.1fs)", n, time.time() - t0)


def ja_related(a_surf, a_lemma, c_surf, c_lemma):
    """Japanese: shares a kanji, or both in one near-synonym group (人/者/方, 物/もの, 事/こと, 時/頃 ...)"""
    if a_surf == c_surf or a_lemma == c_lemma:
        return True
    if set(KANJI.findall(a_surf + a_lemma)) & set(KANJI.findall(c_surf + c_lemma)):
        return True
    ga = JA_GROUP.get(a_surf, set()) | JA_GROUP.get(a_lemma, set())
    gc = JA_GROUP.get(c_surf, set()) | JA_GROUP.get(c_lemma, set())
    return bool(ga & gc)


# ---- the whole English Tatoeba corpus as a Bloom-style bit set of word triples around candidate words
_TOK = re.compile(r"[a-z]+(?:['-][a-z]+)*|[,;:.!?]")
BIT_BITS = 27
BIT_MASK = (1 << BIT_BITS) - 1


def _en_seq(text):
    """[(token, char offset)] of a lower-cased English sentence; the final . ! ? is dropped (it is the sentence end)"""
    toks = [(m.group(0), m.start()) for m in _TOK.finditer(text.lower().replace("’", "'"))]
    while toks and toks[-1][0] in (".", "!", "?"):
        toks.pop()
    return toks


def _bkey(l, m, r):
    return zlib.crc32(("%s\x1f%s\x1f%s" % (l, m, r)).encode("utf-8")) & BIT_MASK


def _bit_set(bits, k):
    bits[k >> 3] |= 1 << (k & 7)


def _bit_get(bits, k):
    return bool(bits[k >> 3] & (1 << (k & 7)))


def _load_bits(P):
    """bit set with (left, word, right), (left, word, *) and (*, word, right) of every English Tatoeba sentence, for the
    words that can be distractors (P.vocab). Cached in cache/lesson_tri_en.bin next to the pool."""
    want = {surf for lst in P.vocab.values() for surf, _l, _z in lst}
    sig = "%s-%d-%d" % (_db_sig(), len(want), BIT_BITS)
    path = os.path.join(CACHE_DIR, "lesson_tri_en.bin")
    try:
        with open(path, "rb") as f:
            head = f.readline().decode("utf-8").strip()
            if head == sig:
                data = f.read()
                if len(data) == 1 << (BIT_BITS - 3):
                    return bytearray(data)
    except FileNotFoundError:
        pass
    except Exception:
        _log().exception("lesson corpus bit set unreadable; rebuilding")
    t0 = time.time()
    bits = bytearray(1 << (BIT_BITS - 3))
    con = reading._db()
    n = 0
    try:
        for (text,) in con.execute("SELECT text FROM sent WHERE lang='en'"):
            words = ["<s>"] + [w for w, _p in _en_seq(text)] + ["</s>"]
            n += 1
            for i in range(1, len(words) - 1):
                m = words[i]
                if m in want:
                    l, r = words[i - 1], words[i + 1]
                    _bit_set(bits, _bkey(l, m, r))
                    _bit_set(bits, _bkey(l, m, "*"))
                    _bit_set(bits, _bkey("*", m, r))
    finally:
        con.close()
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(sig.encode("utf-8") + b"\n")
        f.write(bytes(bits))
    os.replace(tmp, path)
    _log().info("lesson corpus bit set: %d English sentences, %d candidate words (%.1fs)", n, len(want), time.time() - t0)
    return bits


def _ko_clean(ko):
    return bool(ko) and bool(re.search(r"[가-힣]", ko)) and not re.search(r"[一-鿿A-Za-z]", ko) and not BLOCK_KO.search(ko)


def _build_en(rows):
    nlp = reading.en_nlp()
    keep = []
    for sid, text, ko in rows:
        if not EN_CLEAN.fullmatch(text) or blocked(text) or not _ko_clean(ko) or "  " in text \
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
        if not 3 <= len(text) <= 40 or JA_BAD.search(text) or _ja_blocked(text) or not _ko_clean(ko) \
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
        self.bits = None      # en: bit set of word triples of the whole English corpus (see _load_bits)
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

    def refine_vocab(self, wn):
        """English: drop distractor / extra-tile candidates that are no independent words (see _real_word)"""
        if self.lang != "en":
            return
        for key in list(self.vocab):
            self.vocab[key] = [v for v in self.vocab[key] if _real_word(v[0], v[1], wn)]

    def corpus_taken(self, text, start, cand, loose=False, verb=False):
        """en: True if the sentence `text` with `cand` instead of the word starting at char `start` has the same
        (left word, word, right word) triple as some English Tatoeba sentence. loose: also true if both the
        (left, word) and (word, right) pairs exist."""
        if self.bits is None:
            return False
        seq = _en_seq(text)
        i = next((k for k, (_w, p) in enumerate(seq) if p == start), None)
        if i is None:
            return False
        l = seq[i - 1][0] if i > 0 else "<s>"
        r = seq[i + 1][0] if i + 1 < len(seq) else "</s>"
        if _bit_get(self.bits, _bkey(l, cand, r)):
            return True
        if verb and r in ("to", "that") and _bit_get(self.bits, _bkey("*", cand, r)):
            return True  # a verb that is followed by "to" / "that" somewhere in the corpus takes the same complement
        return bool(loose and _bit_get(self.bits, _bkey(l, cand, "*")) and _bit_get(self.bits, _bkey("*", cand, r)))

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
                np_ = Pool(lang, _load_pool(lang))
                if lang == "en":
                    if "--prefetch" in sys.argv:
                        ensure_wordnet_data()  # `server.py --prefetch` downloads wordnet + omw-1.4 into models/nltk_data
                    np_.refine_vocab(wordnet())  # loads WordNet now (about 1.5 s), not during the first lesson
                    try:
                        np_.bits = _load_bits(np_)
                    except Exception:
                        _log().exception("lesson corpus bit set failed; distractors are checked against the pool and the DB only")
                p = _pools[lang] = np_
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

    def bad_word(self, w):
        return blocked(w)

    def fits(self, it, t, cs, cl):
        """True if the word `cs` (lemma `cl`) could stand in for token `t` of sentence `it` and still give a correct
        sentence: a synonym / near relative (WordNet, curated groups, shared kanji), or the same neighbours occur in the corpus."""
        if self.lang == "en":
            if en_related(t[2], cl, t[3]) or en_related(t[0].lower(), cs, t[3]):
                return True
            return self.P.corpus_taken(it["text"], t[1], cs, loose=LOOSE_PAIRS, verb=t[3].startswith("VB"))
        return ja_related(t[0], t[2], cs, cl)

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
                # an extra tile must not be able to replace ANY word of its class in the sentence ("well maintained" / "well designed")
                same = [t for t in it["toks"] if t[3] == h[3] and t[0].isalpha()] or [h]
                self.rng.shuffle(pool)
                for v in pool[:25]:
                    if self.bad_word(v[0]) or any(self.fits(it, t, v[0], v[1]) for t in same):
                        continue
                    out.append(v[0])
                    break
                if len(out) == 2:
                    return out
            return None
        heads = [t for t in it["toks"] if t[3] in ("名詞", "動詞", "形容詞", "副詞") and t[6]]
        self.rng.shuffle(heads)
        for h in heads * 2:
            pool = [c for c in self.P.chunks.get(h[3], []) if c[1] not in lemmas and c[0] not in have and c[0] not in out]
            if not pool:
                continue
            same = [t for t in it["toks"] if t[3] == h[3] and t[6]] or [h]
            self.rng.shuffle(pool)
            for c in pool[:25]:
                if self.bad_word(c[0]) or any(ja_related(t[0], t[2], c[0], c[1]) for t in same):
                    continue
                out.append(c[0])
                break
            if len(out) == 2:
                return out
        return None

    def _texts_of(self, cand):
        key = (self.lang, cand)
        v = _texts_cache.get(key)
        if v is None:
            row = self.con.execute("SELECT id FROM vocab WHERE lang=? AND w=?", (self.lang, cand)).fetchone()
            v = [r[0] for r in self.con.execute("SELECT s.text FROM post p JOIN sent s ON s.id = p.sid WHERE p.wid=?", (row[0],))] if row else []
            if len(_texts_cache) > 1500:
                _texts_cache.clear()
            _texts_cache[key] = v
        return v

    def slot_taken(self, it, t, cand, left, right):
        """True if `cand` already appears between the same neighbours in a real sentence: it could fit the blank."""
        if (left, cand, right) in self.P.tri:
            return True
        texts = self._texts_of(cand)
        if not texts:
            return False
        if self.lang == "en":
            text = it["text"].replace("’", "'")
            s, e = t[1], t[1] + len(t[0])
            m = re.search(r"(\S+)\s*$", text[:s])
            if m:
                lp = r"(?<!\S)" + re.escape(m.group(1)).replace("'", "['’]") + r"\s+"
            else:
                lp = r"^"
            m2 = re.match(r"(\s*)(\S+)", text[e:])
            if not m2 or re.fullmatch(r"[.!?]+", m2.group(2)):
                rp = r"[.!?]*\s*$"
            else:
                rp = (r"\s+" if m2.group(1) else "") + re.escape(m2.group(2)).replace("'", "['’]") + \
                     (r"(?![A-Za-z'’])" if m2.group(2)[-1].isalnum() else "")
            rx = re.compile(lp + re.escape(cand) + rp, re.I)
        else:
            rx = re.compile((r"^" if left == "<s>" else re.escape(left)) + re.escape(cand) +
                            (r"[。！？!?]*$" if right == "</s>" else re.escape(right)))
        return any(rx.search(x) for x in texts)

    def fill_all(self, it):
        """yield every possible fill exercise of the sentence (one per usable blank, best target word first)"""
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
            yield {"type": "fill", "sentence": sentence, "reading": self.reading(sentence), "ko": it["ko"], "options": opts,
                   "answer": ans, "explain": self.explain_for(it, b[2])}

    def fill(self, it):
        return next(self.fill_all(it), None)

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
        for v in pool[:60]:
            # cheap checks first: block list, synonyms / near relatives, then the corpus lookups
            if v[0] in out or self.bad_word(v[0]) or self.fits(it, b, v[0], v[1]) or self.slot_taken(it, b, v[0], left, right):
                continue
            out.append(v[0])
            if len(out) == 3:
                return out
        return None


_texts_cache = {}
LOOSE_PAIRS = True  # also treat "(left, word) and (word, right) both exist in the corpus" as a fit (stricter, drops more items)


def make_items_for_id(lang, sid, seeds=range(40), stage=2, month=1, week=1):
    """Test hook: build the fill and build exercises for one Tatoeba sentence id with many random seeds, ignoring the
    lesson picker. Returns {"text": ..., "fills": {answer: set(distractors)}, "extras": set(tiles)}."""
    if not reading.tatoeba_ready():
        raise _err("예문 데이터가 아직 준비되지 않았어요.", 503)
    P = pool(lang)
    it = P.by_id.get(sid)
    if it is None:
        raise KeyError("sentence %s is not in the %s lesson pool" % (sid, lang))
    target = target_vocab(lang, month, week)
    out = {"text": it["text"], "fills": {}, "extras": set()}
    con = reading._db()
    try:
        for seed in seeds:
            mk = Maker(lang, stage, random.Random(seed), P, con, target, {})
            for ex in mk.fill_all(it):
                ans = ex["options"][ex["answer"]]
                out["fills"].setdefault(ans, set()).update(o for j, o in enumerate(ex["options"]) if j != ex["answer"])
            if it["bt"]:
                out["extras"].update(mk.build_extra(it) or [])
    finally:
        con.close()
    return out


def _eligible(P, stage):
    lens = EN_LEN if P.lang == "en" else JA_LEN
    for lo_z, (lo, hi) in ((MIN_ZIPF[stage], lens[stage]), (MIN_ZIPF[max(stage - 1, 1)] - 0.5, lens[stage]),
                           (0.0, (lens[1][0], lens[4][1]))):
        c = [it for it in P.items if lo <= it["n"] <= hi and it["dmin"] >= lo_z]
        if len(c) >= 80:
            return c
    return c


def make_lesson(lang, month, week, stage, seed=None):
    """a rule-based lesson; raises sqlite3.Error if the Tatoeba DB turned out to be unreadable (the caller falls back)"""
    try:
        return _make_lesson(lang, month, week, stage, seed)
    except sqlite3.Error:
        reading.invalidate_tatoeba_ready()
        _log().exception("Tatoeba DB unreadable while making a lesson")
        raise


def _make_lesson(lang, month, week, stage, seed=None):
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
