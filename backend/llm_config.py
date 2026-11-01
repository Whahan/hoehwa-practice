# -*- coding: utf-8 -*-
"""One-time move of an old config.json to the OpenCode-only engine list (contract: docs/onetouch_install_design.md 3.4.1/3.4.5).

The local Ollama engine was removed. A config written by an older version may still say llm_provider "ollama" and carry
llm_model / ollama_url / keep_alive / num_ctx. migrate() fixes that; the person's Ollama program and models are never touched.

No heavy imports: the test imports this module on its own.
"""
import copy

VALID_PROVIDERS = ("opencode", "openai_api")
OLD_KEYS = ("llm_model", "ollama_url", "keep_alive", "num_ctx")
NOTICE = "ollama_removed"
MARK = "llm_migrated_from"


def migrate(cfg):
    """(new cfg, notice). The input dict is not changed.

    notice is "ollama_removed" when the app should tell the person once (the engine was moved now, or an earlier move
    has not been acknowledged yet: cfg["llm_migrated_from"] is still there), else "".
    llm_provider "ollama" or an unknown text -> "opencode"; the four old keys are dropped; everything else stays.
    A missing llm_provider is left alone (the server's default is already opencode)."""
    new = copy.deepcopy(cfg) if isinstance(cfg, dict) else {}
    notice = ""
    if "llm_provider" in new and new["llm_provider"] not in VALID_PROVIDERS:
        new["llm_provider"] = "opencode"
        new[MARK] = "ollama"
        notice = NOTICE
    for k in OLD_KEYS:
        new.pop(k, None)
    if new.get(MARK):
        notice = NOTICE
    return new, notice


def apply(cfg):
    """Same as migrate() but changes cfg in place (modules that already hold a reference to CFG keep seeing it).
    Returns (notice, changed)."""
    new, notice = migrate(cfg)
    changed = new != cfg
    if changed:
        cfg.clear()
        cfg.update(new)
    return notice, changed


def ack(cfg):
    """The person has seen the notice: forget it. True if something was removed."""
    return cfg.pop(MARK, None) is not None
