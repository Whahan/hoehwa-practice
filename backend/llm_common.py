# -*- coding: utf-8 -*-
"""Shared pieces of the remote AI engines (llm_opencode.py, llm_api.py)."""
import json
import re


class LlmError(Exception):
    """A remote engine failed. .kind ("limit" | "auth" | "overload" | None, see llm_fallback.classify) decides whether
    server.py answers with the local model instead; .raw is the engine's own text (the reset time is parsed from it)."""

    def __init__(self, msg, status=502, kind=None, raw=""):
        super().__init__(msg)
        self.msg = msg
        self.status = status
        self.kind = kind
        self.raw = raw


# Test hook (server.py /debug/engine_limit, only with HOEHWA_TEST_HOOKS=1): when non-empty, every remote engine call
# fails at once as if the engine had answered with this text, e.g. "429 Too Many Requests, retry in 600 seconds".
SIMULATE_LIMIT = ""


def split(messages):
    """(system text, one prompt) from a chat message list; earlier turns are written out as a transcript."""
    system = "\n\n".join(m["content"] for m in messages if m["role"] == "system")
    rest = [m for m in messages if m["role"] != "system"]
    if len(rest) == 1:
        return system, rest[0]["content"]
    lines = ["Conversation so far (you are the assistant; reply to the LAST user message):"]
    for m in rest:
        who = "USER" if m["role"] == "user" else "ASSISTANT (you, earlier)"
        lines.append("[%s]\n%s" % (who, m["content"]))
    return system, "\n\n".join(lines)


FORMAT_MSG = "AI가 올바른 형식으로 답하지 못했어요. 다시 시도해 주세요."


def is_format_error(e):
    """True for the LlmError the engines raise when the answer held no usable JSON object (server.py then asks once more)."""
    return isinstance(e, LlmError) and e.kind is None and e.status == 502 and e.msg == FORMAT_MSG


_FENCE = re.compile(r"```[A-Za-z0-9_-]*[ \t]*\r?\n?(.*?)```", re.S)
_UNCLOSED_FENCE = re.compile(r"```[A-Za-z0-9_-]*[ \t]*\r?\n?(.*)$", re.S)
_OBJ_START = re.compile(r"\{\s*[\"}“”]")
_ARR_START = re.compile(r"\[\s*\{")
_TRAILING_COMMA = re.compile(r",(\s*[}\]])")
_SMART_QUOTES = str.maketrans({"“": '"', "”": '"'})


def _top_level_spans(text):
    """[(start, end)] of every TOP-LEVEL {...} in text (depth-0 scan that understands strings and escapes, so braces and
    quotes inside a string do not count). end is None for an object that is still open at the end of the text, i.e. a
    cut-off answer. Objects nested inside a top-level object are never candidates."""
    spans, stack, start, in_str, esc = [], [], 0, False, False
    for i, ch in enumerate(text):
        depth = len(stack)
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = depth > 0       # a quote outside any object is prose
        elif ch in "{[":
            if depth == 0:
                # prose braces ("{note}", "{ text") do not open an object; a top-level list of objects is tracked only so
                # that the objects inside it are never taken for the answer (and a cut-off list counts as cut off)
                if not (_OBJ_START.match(text, i) if ch == "{" else _ARR_START.match(text, i)):
                    continue
                start = i
            stack.append(ch)
        elif ch in "}]" and depth > 0:
            opener = stack.pop()
            if not stack and opener == "{":
                spans.append((start, i + 1))
    if stack:
        spans.append((start, None))
    return spans


def _parse_object(seg):
    """json.loads of one top-level {...} segment, with the usual model slips repaired (trailing comma, curly quotes)"""
    for fix in (lambda t: t, lambda t: _TRAILING_COMMA.sub(r"\1", t), lambda t: _TRAILING_COMMA.sub(r"\1", t.translate(_SMART_QUOTES))):
        try:
            v = json.loads(fix(seg), strict=False)
        except ValueError:
            continue
        if isinstance(v, dict):
            return v
    return None


def _objects_in(text):
    """the parsable top-level objects of text (an open, cut-off object yields nothing)"""
    out = []
    for a, b in _top_level_spans(text):
        if b is not None:
            v = _parse_object(text[a:b])
            if v is not None:
                out.append(v)
    return out


def extract_json(text):
    """The JSON object in a model's text answer. Tolerates a <think> block, code fences (several, or an unclosed one),
    explanation text before/after the object, a trailing comma and curly double quotes. Only TOP-LEVEL objects are
    candidates: an object nested in a broken or cut-off one is never returned in its place. Candidates: the contents of
    code fences first, then the whole text; the biggest parsable object wins. Raises ValueError if there is none; a
    top-level list or scalar is not an answer."""
    text = (text or "").strip().lstrip("﻿")
    if "</think>" in text:
        text = text.split("</think>")[-1].strip()
    elif "<think>" in text:              # still thinking when the answer was cut off: a draft object there is not the answer
        text = text.split("<think>")[0].strip()
    fenced = [m.strip() for m in _FENCE.findall(text)]
    unclosed = _UNCLOSED_FENCE.search(text)
    if unclosed:
        fenced.append(unclosed.group(1).strip())
    for group in (fenced, [text]):
        objs = [o for cand in group for o in _objects_in(cand)]
        if objs:
            return max(objs, key=lambda o: len(json.dumps(o, ensure_ascii=False)))
    raise ValueError("no JSON object in the answer")
