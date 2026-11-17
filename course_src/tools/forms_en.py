# -*- coding: utf-8 -*-
"""Which word forms may a headword claim as its own (code FORM_SUSPECT of check_course.py)? Standard library only.

A `forms[].f` entry of a manuscript word makes the form known from the day of the word (or the pattern that teaches it).
So it must really be a form of that word: a regular derivation of the headword (-s/-es/-ies, -ed/-d/-ied, -ing, -er/-est/-ier/-iest,
-ly/-ily, possessive 's, doubled final consonant) or one of the irregular forms listed here. Anything else (another word,
"went" for "hello") is suspect. Small on purpose: an irregular form that is missing is added here, not waved through.
"""
import re

from course_common import tokenize

IRREGULAR = {
    # verbs
    "be": "am is are was were been being", "have": "has had having", "do": "does did done doing", "go": "goes went gone going",
    "eat": "ate eaten", "see": "saw seen", "take": "took taken", "make": "made", "get": "got gotten", "give": "gave given",
    "come": "came", "know": "knew known", "think": "thought", "buy": "bought", "bring": "brought", "find": "found",
    "tell": "told", "say": "said says", "leave": "left", "feel": "felt", "keep": "kept", "meet": "met", "pay": "paid",
    "sit": "sat", "stand": "stood", "run": "ran", "write": "wrote written", "read": "read", "drink": "drank drunk",
    "speak": "spoke spoken", "sleep": "slept", "wake": "woke woken", "sell": "sold", "send": "sent", "spend": "spent",
    "lose": "lost", "wear": "wore worn", "begin": "began begun", "break": "broke broken", "choose": "chose chosen",
    "drive": "drove driven", "fall": "fell fallen", "forget": "forgot forgotten", "hear": "heard", "hold": "held",
    "lend": "lent", "build": "built", "catch": "caught", "teach": "taught", "understand": "understood", "win": "won",
    "sing": "sang sung", "swim": "swam swum", "fly": "flew flown", "draw": "drew drawn", "grow": "grew grown",
    "throw": "threw thrown", "ride": "rode ridden", "rise": "rose risen", "show": "showed shown", "put": "put",
    "cut": "cut", "hit": "hit", "set": "set", "let": "let", "hurt": "hurt", "shut": "shut", "quit": "quit", "cost": "cost",
    "lead": "led", "mean": "meant", "pick": "picked", "shake": "shook shaken", "steal": "stole stolen", "hide": "hid hidden",
    "bite": "bit bitten", "blow": "blew blown", "burn": "burnt", "deal": "dealt", "dig": "dug", "feed": "fed", "fight": "fought",
    "forgive": "forgave forgiven", "freeze": "froze frozen", "hang": "hung", "lay": "laid", "lie": "lay lain lying", "light": "lit",
    "ring": "rang rung", "seek": "sought", "shoot": "shot", "shine": "shone", "slide": "slid", "spell": "spelt", "swear": "swore sworn",
    "tear": "tore torn", "wind": "wound", "can": "could can't cannot", "will": "would won't", "shall": "should", "may": "might", "must": "must",
    # nouns
    "man": "men", "woman": "women", "child": "children", "person": "people", "foot": "feet", "tooth": "teeth", "mouse": "mice",
    "wife": "wives", "knife": "knives", "life": "lives", "leaf": "leaves", "shelf": "shelves", "half": "halves", "loaf": "loaves",
    "thief": "thieves", "wolf": "wolves", "goose": "geese", "ox": "oxen", "sheep": "sheep", "fish": "fish", "deer": "deer",
    "series": "series", "species": "species",
    # adjectives / adverbs
    "good": "better best", "bad": "worse worst", "well": "better best", "far": "farther further farthest furthest",
    "much": "more most", "many": "more most", "little": "less least", "old": "elder eldest", "late": "latter last",
    # pronouns and determiners
    "i": "me my mine myself i'm i've i'll i'd", "you": "your yours yourself yourselves you're you've you'll you'd",
    "he": "him his himself he's he'll he'd", "she": "her hers herself she's she'll she'd", "it": "its itself it's it'll",
    "we": "us our ours ourselves we're we've we'll we'd", "they": "them their theirs themselves they're they've they'll they'd",
    "this": "these", "that": "those that's", "who": "whom whose who's", "a": "an", "one": "ones", "other": "others another",
    "no": "none", "some": "something someone somebody", "any": "anything anyone anybody", "every": "everything everyone everybody",
    "what": "what's", "there": "there's there're", "here": "here's", "let's": "", "do not": "don't", "is not": "isn't",
}
IRREGULAR = {k: set(v.split()) for k, v in IRREGULAR.items()}
# which regular derivations a headword with an irregular form must NOT use ("goed", "childs", "gooder")
_NOUNS = set("man woman child person foot tooth mouse wife knife life leaf shelf half loaf thief wolf goose ox sheep fish deer series species".split())
_ADJ = set("good bad well far much many little old late".split())
_PRON = set("i you he she it we they this that who a one other no some any every what there here".split())
CONTRACTION_NEG = re.compile(r"^(?:is|are|was|were|do|does|did|have|has|had|can|could|would|should|will|must)n't$|^won't$|^can't$|^cannot$")


def regular_forms(lemma):
    """Regular derivations of one lower-case token."""
    out = {lemma + "'s", lemma + "s'", lemma + "s"}
    vowels = "aeiou"
    if lemma.endswith(("s", "x", "z", "ch", "sh", "o")):
        out.add(lemma + "es")
    if lemma.endswith("y") and len(lemma) > 1 and lemma[-2] not in vowels:
        stem = lemma[:-1]
        out |= {stem + "ies", stem + "ied", stem + "ier", stem + "iest", stem + "ily", stem + "iness"}
    if lemma.endswith("e"):
        stem = lemma[:-1]
        out |= {lemma + "d", lemma + "r", lemma + "st", lemma + "ly", stem + "ing", stem + "ier"}
    else:
        out |= {lemma + "ed", lemma + "ing", lemma + "er", lemma + "est", lemma + "ly", lemma + "ers"}
    if lemma.endswith("le"):
        out.add(lemma[:-1] + "y")
    if lemma.endswith("ic"):
        out.add(lemma + "ally")
    if len(lemma) >= 3 and lemma[-1] not in vowels + "wxy" and lemma[-2] in vowels and lemma[-3] not in vowels:
        out |= {lemma + lemma[-1] + suf for suf in ("ed", "ing", "er", "est", "y", "ers")}
    if lemma in IRREGULAR:
        if lemma in _NOUNS:
            out = {f for f in out if "'" in f}
        elif lemma in _ADJ:
            out = {f for f in out if not f.endswith(("er", "est", "r", "st", "ier", "iest"))}
        elif lemma in _PRON:
            out = {f for f in out if "'" in f and f.endswith(("'s", "s'"))} if lemma in ("who", "it", "that", "there", "here", "what") else set()
        else:                                           # verbs: the irregular past forms replace -ed / -d / -ied
            out = {f for f in out if not f.endswith(("ed", "d", "ier", "iest", "er", "est", "ers"))}
    return out


def is_derived(lemma_text, form_text):
    """True when `form_text` is a regular or listed irregular form of `lemma_text` (same number of tokens, all tokens but
    one equal, the differing one derived; a pure change of case, hyphen or apostrophe counts as the same word)."""
    lt, ft = tokenize(lemma_text), tokenize(form_text)
    if not lt or not ft:
        return False
    if "".join(lt) == "".join(ft):
        return True
    if len(lt) != len(ft):
        # "do not" -> "don't" style contractions of a two-word headword
        return len(lt) == 2 and " ".join(lt) in IRREGULAR and ft[0] in IRREGULAR[" ".join(lt)] and len(ft) == 1
    diff = [(a, b) for a, b in zip(lt, ft) if a != b]
    if len(diff) != 1:
        return False
    a, b = diff[0]
    if b in regular_forms(a) or b in IRREGULAR.get(a, ()):
        return True
    return bool(CONTRACTION_NEG.match(b)) and (b == a + "n't" or b[:-3] == a or (a in IRREGULAR and b in IRREGULAR[a]))
