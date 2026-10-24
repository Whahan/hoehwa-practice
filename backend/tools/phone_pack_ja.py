# -*- coding: utf-8 -*-
"""Japanese readings for the phone data pack (build tool helper; no server import).

`ja_reading` / `ja_pron` do the same as the functions of the same name in backend/server.py (pyopenjtalk through
`run_frontend`, hiragana spelling form / katakana pronunciation form). server.py cannot be imported here (it loads the
configuration and the models), so the logic is copied; backend/test_phone_pack.py compares the two on sample sentences
by extracting the original functions from server.py's source.
"""
import re
import unicodedata
import functools

KATA_PRON_RE = re.compile(r"[ァ-ヶー]+")
KATA_FULL = re.compile(r"[ァ-ヶー]+")
HIRA_FULL = re.compile(r"[ぁ-ゖゝゞー]+")

SIMP_TO_JA = {
    "买": "買", "卖": "売", "说": "説", "话": "話", "请": "請", "谢": "謝", "对": "対", "时": "時", "间": "間", "开": "開",
    "关": "関", "问": "問", "题": "題", "觉": "覚", "见": "見", "现": "現", "样": "様", "电": "電", "车": "車", "东": "東",
    "饭": "飯", "书": "書", "读": "読", "写": "写", "听": "聞", "钱": "銭", "国": "国", "学": "学", "来": "来", "个": "個",
    "们": "達", "为": "為", "运": "運", "动": "動", "难": "難", "过": "過", "还": "", "这": "", "那": "", "么": "", "什": "",
    "吗": "か", "呢": "ね", "吧": "ね", "啊": "ね", "喝": "飲", "吃": "食", "没": "", "会": "会", "页": "頁", "机": "機",
    "热": "熱", "爱": "愛", "两": "両", "岁": "歳", "实": "実", "际": "際", "业": "業", "务": "務", "发": "発",
}
HAN_ANY = re.compile(r"[㐀-䶿一-鿿豈-﫿\U00020000-\U0003134f]")
VARIANT_TO_STD = {"髙": "高", "﨑": "崎", "𠮷": "吉", "邉": "辺", "邊": "辺", "濵": "浜", "德": "徳", "栁": "柳", "冨": "富", "桒": "桑",
                  "圓": "円", "眞": "真", "說": "説", "渕": "淵", "彅": "剛", "曻": "昇", "槇": "槙", "增": "増"}
SIMP_EXTRA = "气怎你您她们这吗呢吧啊么没还请说话谢对时间开关问题觉见现样电车东饭书读听钱为运动难过热爱两岁实际业务发吃喝买卖"

_ojt = None


def ojt():
    global _ojt
    if _ojt is None:
        import pyopenjtalk
        pyopenjtalk.g2p("テスト", kana=True)
        _ojt = pyopenjtalk
    return _ojt


def _encodes(c, codec):
    try:
        c.encode(codec)
        return True
    except UnicodeEncodeError:
        return False


def is_chinese_only(c):
    if not ("一" <= c <= "鿿") or c in VARIANT_TO_STD:
        return False
    return c in SIMP_TO_JA or c in SIMP_EXTRA or (_encodes(c, "gb2312") and not _encodes(c, "cp932") and not _encodes(c, "euc_jis_2004"))


def ja_text_foreign(text):
    text = unicodedata.normalize("NFKC", text or "")
    bad = []
    if not HAN_ANY.search(text):
        return bad
    try:
        for m in ojt().run_frontend(text):
            st, r = m.get("string", ""), m.get("read") or ""
            if HAN_ANY.search(st) and not re.fullmatch(r"[ァ-ヶー]+", r):
                bad.extend(c for c in st if is_chinese_only(c))
    except Exception:
        pass
    return bad


def ja_fix_foreign(text):
    bad = set(ja_text_foreign(text))
    if not bad:
        return text
    return "".join((SIMP_TO_JA.get(c, "") if c in bad else c) for c in text)


@functools.lru_cache(maxsize=65536)
def _ja_pair(text):
    """(reading, pron) from ONE OpenJTalk pass; see server.py `_ja_pair`"""
    import jaconv
    text = text or ""
    if not text.strip():
        return "", ""
    parts = []
    prons = []
    for seg in re.split(r"(___)", text):
        if seg == "___":
            parts.append("___")
            prons.append("___")
            continue
        if not seg.strip():
            continue
        try:
            seg = "".join(VARIANT_TO_STD.get(c, c) for c in unicodedata.normalize("NFKC", seg))
            seg = ja_fix_foreign(seg)
            for m in ojt().run_frontend(seg):
                r = m.get("read") or ""
                st = m.get("string", "")
                if re.fullmatch(r"[ァ-ヶー]+", r):
                    parts.append(jaconv.kata2hira(r))
                    p = (m.get("pron") or "").replace("’", "")
                    p = p if KATA_PRON_RE.fullmatch(p) else r
                    if p == "イウ" and m.get("orig") in ("言う", "いう"):
                        p = "ユー"
                    prons.append(p)
                elif st.strip():
                    s2 = HAN_ANY.sub("", st.strip())
                    parts.append(s2)
                    prons.append(s2)
        except Exception:
            pass
    fix = lambda s: s.replace(",", "、").replace(".", "。").replace("!", "！").replace("?", "？")
    return fix("".join(parts)), fix("".join(prons))


def ja_reading(text):
    return _ja_pair(text or "")[0]


def ja_pron(text):
    return _ja_pair(text or "")[1]


KANA_ONLY = re.compile(r"^[ぁ-ゖゝゞァ-ヺヽヾー・、。！？!?\s]+$")


def kana_only(s):
    """True for a surface form that is only kana / punctuation (no entry needed in the reading map)"""
    return bool(KANA_ONLY.match(s or ""))
