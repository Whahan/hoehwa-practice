# -*- coding: utf-8 -*-
"""Which word forms may a headword claim as its own (code FORM_SUSPECT of check_course.py)? Standard library only.

A `forms[].f` entry of a manuscript word makes the form known from the day of the word (or of the pattern that teaches it).
So it must really be a form of that word, by part of speech and spelling rule:
  n          plural (-s, -es, -ies, -ves via the irregular table), possessive 's / s'
  v          -s/-es/-ies, -ing, -ed (e: -d, y: -ied, one-syllable CVC: doubled consonant), agent noun -er/-ers, irregular forms
  adj, adv   -er/-est (e: -r/-st, y: -ier/-iest, one-syllable CVC: doubled consonant), -ly (adj), irregular forms
  propn      possessive only
  interj pron det prep conj num aux ...   no regular forms; only the listed irregular / contracted forms
  chunk, phr, part, or no pos at all        every class (a multi-word headword changes exactly one token)
Irregular forms and contractions come from the tables below. A headword with an irregular form does not also get the regular
one (goed, childs, gooder) unless the table lists both (learnt/learned, hanged/hung). Small on purpose: a missing irregular
form is added here, not waved through.
"""
import re

from course_common import tokenize

_V = "aeiou"

# --- irregular forms ---------------------------------------------------------------------------------------------------
IRR_VERBS = {
    "be": "am is are was were been being", "have": "has had having", "do": "does did done doing", "go": "goes went gone going",
    "eat": "ate eaten", "see": "saw seen", "take": "took taken", "make": "made", "get": "got gotten", "give": "gave given",
    "come": "came", "know": "knew known", "think": "thought", "buy": "bought", "bring": "brought", "find": "found",
    "tell": "told", "say": "said", "leave": "left", "feel": "felt", "keep": "kept", "meet": "met", "pay": "paid",
    "sit": "sat", "stand": "stood", "run": "ran", "write": "wrote written", "read": "read", "drink": "drank drunk",
    "speak": "spoke spoken", "sleep": "slept", "wake": "woke woken", "sell": "sold", "send": "sent", "spend": "spent",
    "lose": "lost", "wear": "wore worn", "begin": "began begun", "break": "broke broken", "choose": "chose chosen",
    "drive": "drove driven", "fall": "fell fallen", "forget": "forgot forgotten", "hear": "heard", "hold": "held",
    "lend": "lent", "build": "built", "catch": "caught", "teach": "taught", "understand": "understood", "win": "won",
    "sing": "sang sung", "swim": "swam swum", "fly": "flew flown flies", "draw": "drew drawn", "grow": "grew grown",
    "throw": "threw thrown", "ride": "rode ridden", "rise": "rose risen", "show": "showed shown", "put": "put",
    "cut": "cut", "hit": "hit", "set": "set", "let": "let", "hurt": "hurt", "shut": "shut", "quit": "quit", "cost": "cost",
    "lead": "led", "mean": "meant", "shake": "shook shaken", "steal": "stole stolen", "hide": "hid hidden",
    "bite": "bit bitten", "blow": "blew blown", "deal": "dealt", "dig": "dug", "feed": "fed", "fight": "fought",
    "forgive": "forgave forgiven", "freeze": "froze frozen", "lay": "laid", "lie": "lay lain lying", "ring": "rang rung",
    "seek": "sought", "shoot": "shot", "slide": "slid", "swear": "swore sworn", "tear": "tore torn", "wind": "wound",
    # both an irregular and a regular past (Canadian / British -t forms and double forms)
    "learn": "learnt learned", "burn": "burnt burned", "spell": "spelt spelled", "dream": "dreamt dreamed", "smell": "smelt smelled",
    "spill": "spilt spilled", "hang": "hung hanged", "light": "lit lighted", "kneel": "knelt kneeled", "lean": "leant leaned",
    "leap": "leapt leaped", "prove": "proved proven", "sew": "sewed sewn", "shine": "shone shined", "get up": "got up",
}
IRR_NOUNS = {
    "man": "men", "woman": "women", "child": "children", "person": "people", "foot": "feet", "tooth": "teeth", "mouse": "mice",
    "wife": "wives", "knife": "knives", "life": "lives", "leaf": "leaves", "shelf": "shelves", "half": "halves", "loaf": "loaves",
    "thief": "thieves", "wolf": "wolves", "goose": "geese", "ox": "oxen", "sheep": "sheep", "fish": "fish fishes", "deer": "deer",
    "series": "series", "species": "species", "self": "selves", "calf": "calves", "elf": "elves",
}
IRR_ADJ = {
    "good": "better best", "bad": "worse worst", "well": "better best", "far": "farther further farthest furthest",
    "much": "more most", "many": "more most", "little": "less least", "old": "elder eldest", "late": "latter last",
}
# pronouns / determiners: only the object case and a few function-word pairs; possessives (my, your, his ...) and compounds
# (something, myself, mine ...) are separate words and must not be smuggled in as forms
IRR_OTHER = {
    "i": "me", "he": "him", "she": "her", "we": "us", "they": "them", "this": "these", "that": "those",
    "who": "whom", "a": "an", "one": "ones", "other": "others",
}
# contractions: base word -> its contracted forms ('m 're 's tokenise as "m" "re" "s" and are not forms)
CONTRACTIONS = {
    "do": "don't doesn't didn't", "be": "isn't aren't wasn't weren't ain't", "have": "haven't hasn't hadn't", "can": "can't couldn't cannot",
    "will": "won't wouldn't", "should": "shouldn't", "must": "mustn't", "need": "needn't", "might": "mightn't", "shall": "shan't",
    "could": "couldn't", "would": "wouldn't", "is": "isn't", "are": "aren't", "was": "wasn't", "were": "weren't", "does": "doesn't",
    "did": "didn't", "has": "hasn't", "had": "hadn't",
    "i": "i'm i've i'll i'd", "you": "you're you've you'll you'd", "he": "he's he'll he'd", "she": "she's she'll she'd",
    "it": "it's it'll", "we": "we're we've we'll we'd", "they": "they're they've they'll they'd", "that": "that's that'll",
    "there": "there's there'll there're", "here": "here's", "who": "who's who'll", "what": "what's what'll", "let": "let's",
}
# the whole irregular table by lemma (lower case), used as a flat lookup
IRREGULAR = {}
for _d in (IRR_VERBS, IRR_NOUNS, IRR_ADJ, IRR_OTHER):
    for _k, _v in _d.items():
        IRREGULAR.setdefault(_k, set()).update(_v.split())
CONTR = {k: set(v.split()) for k, v in CONTRACTIONS.items()}

_NO_REGULAR = {"have", "be", "can", "will", "shall", "may", "must", "should", "would", "could", "might"}      # has / is ... only
_BLOCK_REGULAR_ADJ = {"good", "bad", "well", "much", "many", "little", "far"}                                  # gooder, littler
_O_PLURAL_S = {"photo", "piano", "solo", "memo", "logo", "kilo", "auto", "taco", "avocado", "burrito", "video", "radio", "zoo", "studio"}
_NEG_CONTR = re.compile(r"^[a-z]+n't$|^cannot$")


# --- spelling rules ------------------------------------------------------------------------------------------------------
def _syllables(w):
    return len(re.findall(r"[aeiouy]+", w.replace("qu", "q")))


def _cvc(w):
    """consonant + single vowel + consonant (not w, x, y) at the end: stop, run, big, hot, plan, chat, quit (qu = one consonant)."""
    w = w.replace("qu", "q")
    return len(w) >= 3 and w[-1] not in _V + "wxy" and w[-2] in _V and w[-3] not in _V + "y"


def _stems(w, kind):
    """stems that take a vowel suffix (-ed -ing -er -est): e dropped, y -> i, CVC doubled (always for one syllable, either way for
    longer words: begin / beginning, travel / travelled / traveled), c -> ck. Never the bare word when a rule applies."""
    if kind == "ing":
        if w.endswith("ie"):
            return {w[:-2] + "y"}                              # die -> dying
        if w.endswith("e") and not w.endswith(("ee", "ye", "oe")) and len(w) > 2:
            return {w[:-1]}                                    # make -> making; see / agree / dye / toe keep the e
    else:
        if w.endswith("e"):
            return {w[:-1]}                                    # like -> liked, nice -> nicer
        if w.endswith("y") and len(w) > 1 and w[-2] not in _V:
            return {w[:-1] + "i"}                              # study -> studied, happy -> happier
    if w.endswith("c") and len(w) > 2 and w[-2] in _V:
        return {w + "k"}                                       # picnic -> picnicking, panic -> panicked
    if _cvc(w):
        return {w + w[-1]} if _syllables(w) <= 1 else {w + w[-1], w}
    return {w}


def _plural_s(w):
    if w.endswith(("s", "x", "z", "ch", "sh")):
        out = {w + "es"}
        if w.endswith(("s", "z")) and not w.endswith(("ss", "zz")):
            out.add(w + w[-1] + "es")                           # bus -> busses, quiz -> quizzes
        return out
    if w.endswith("y") and len(w) > 1 and w[-2] not in _V:
        return {w[:-1] + "ies"}
    if w.endswith("o"):
        return {w + "s"} if (w[-2:-1] in _V or w in _O_PLURAL_S) else {w + "es"}
    return {w + "s"}


def _past(w):
    return {s + "ed" for s in _stems(w, "ed")}


def _forms_for(w, cls):
    """regular forms of token `w` in class cls: n, v, adj, adv, propn, any."""
    out = set()
    if cls in ("n", "any"):
        out |= _plural_s(w) | {w + "'s", w + "s'"}
    if cls == "propn":
        out |= {w + "'s", w + "s'"}
    if cls in ("v", "any"):
        out |= _plural_s(w) | _past(w)
        out |= {s + "ing" for s in _stems(w, "ing")}
        out |= {s + "er" for s in _stems(w, "ed")} | {s + "ers" for s in _stems(w, "ed")}        # teacher, runner, driver
    if cls in ("adj", "adv", "any"):
        for s in _stems(w, "ed"):
            out |= {s + "er", s + "est"}
    if cls in ("adj", "any"):
        if w.endswith("y") and len(w) > 1 and w[-2] not in _V:
            out.add(w[:-1] + "ily")
        elif w.endswith("ole"):
            out.add(w[:-2] + "lly")                             # whole -> wholly
        elif w.endswith("le"):
            out.add(w[:-1] + "y")                               # simple -> simply
        elif w.endswith("ue"):
            out.add(w[:-2] + "uly")                             # true -> truly
        elif w.endswith("ic"):
            out |= {w + "ally", w + "ly"}                       # basic -> basically, public -> publicly
        else:
            out.add(w + "ly")
    return out


_CLASS = {"n": "n", "v": "v", "adj": "adj", "adv": "adv", "propn": "propn", None: "any", "": "any", "chunk": "any", "phr": "any", "part": "any"}


def regular_forms(lemma, pos=None):
    """Regular derivations of one lower-case token for the part of speech (pos None / chunk / phr = every class)."""
    cls = _CLASS.get(pos)
    if cls is None or lemma in _NO_REGULAR or lemma in IRR_OTHER:          # interj, pron, det, prep, conj, num, aux ... get none
        return set()
    out = _forms_for(lemma, cls)
    if lemma in IRR_VERBS:
        out -= _past(lemma)                                                   # goed, eated: the irregular past replaces -ed
    if lemma in IRR_NOUNS:
        out = {f for f in out if "'" in f}                                    # childs, mans
    if lemma in _BLOCK_REGULAR_ADJ:
        out = {f for f in out if not f.endswith(("er", "est", "ier", "iest"))}  # gooder, farer
    return out


def is_derived(lemma_text, form_text, pos=None):
    """True when `form_text` is a regular or listed irregular form (or contraction) of `lemma_text` for that part of speech.
    A form that differs from the headword only in case, hyphen, space or apostrophe counts as the same word. A multi-word
    headword must keep its token count and change exactly one token."""
    lt, ft = tokenize(lemma_text), tokenize(form_text)
    if not lt or not ft:
        return False
    if "".join(lt) == "".join(ft):
        return True
    if len(lt) != len(ft):
        return False
    diff = [(a, b) for a, b in zip(lt, ft) if a != b]
    if len(diff) != 1:
        return False
    a, b = diff[0]
    if b in IRREGULAR.get(a, ()) or b in CONTR.get(a, ()):
        return True
    if len(lt) == 1 and pos in ("chunk", "phr"):
        return False                      # chunk / phr belong to headwords of several words; a one-word headword gets no regular form
    return b in regular_forms(a, pos if len(lt) == 1 else None)
