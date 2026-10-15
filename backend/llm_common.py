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


def extract_json(text):
    """The JSON object in a model's text answer (tolerates code fences and text around it)."""
    text = (text or "").strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if m:
        text = m.group(1).strip()
    try:
        return json.loads(text)
    except Exception:
        pass
    a, b = text.find("{"), text.rfind("}")
    if a != -1 and b > a:
        return json.loads(text[a:b + 1])
    raise ValueError("no JSON in the answer")
