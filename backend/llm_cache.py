# -*- coding: utf-8 -*-
"""Persistent cache of AI results for deterministic tasks, so the same request never costs twice.

Used by server.ollama_json(..., cache_key_kind="fix"). Only callers that pass a kind are cached
(fix, translate, verify, gloss, ...); chat turns and feedback never are.
Key = sha256 of (kind, provider, model, schema, messages, options). Value = the parsed JSON object.
Storage: backend/cache/llm_cache.sqlite (one table; oldest rows pruned beyond MAX_ROWS).
"""
import hashlib
import json
import os
import sqlite3
import threading
import time

BASE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(BASE, "cache", "llm_cache.sqlite")
MAX_ROWS = 50000

_lock = threading.Lock()
_conn = None
_stats = {"hits": 0, "misses": 0, "stores": 0}


def _db():
    global _conn
    if _conn is None:
        os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
        c = sqlite3.connect(DB_PATH, check_same_thread=False, timeout=10)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=NORMAL")
        c.execute("CREATE TABLE IF NOT EXISTS llm_cache (k TEXT PRIMARY KEY, kind TEXT, provider TEXT, model TEXT,"
                  " created REAL, used REAL, hits INTEGER DEFAULT 0, value TEXT)")
        c.execute("CREATE INDEX IF NOT EXISTS llm_cache_used ON llm_cache(used)")
        c.commit()
        _conn = c
    return _conn


def make_key(kind, provider, model, schema, messages, options=None):
    blob = json.dumps([kind, provider, model, schema, messages, options or {}], ensure_ascii=False,
                      sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def get(key):
    """Cached value or None."""
    try:
        with _lock:
            c = _db()
            row = c.execute("SELECT value FROM llm_cache WHERE k=?", (key,)).fetchone()
            if row is None:
                _stats["misses"] += 1
                return None
            c.execute("UPDATE llm_cache SET hits=hits+1, used=? WHERE k=?", (time.time(), key))
            c.commit()
            _stats["hits"] += 1
        return json.loads(row[0])
    except Exception:
        return None


def put(key, kind, provider, model, value):
    try:
        now = time.time()
        with _lock:
            c = _db()
            c.execute("INSERT OR REPLACE INTO llm_cache (k, kind, provider, model, created, used, hits, value)"
                      " VALUES (?, ?, ?, ?, ?, ?, 0, ?)",
                      (key, kind, provider, model, now, now, json.dumps(value, ensure_ascii=False)))
            _stats["stores"] += 1
            if _stats["stores"] % 500 == 0:
                n = c.execute("SELECT COUNT(*) FROM llm_cache").fetchone()[0]
                if n > MAX_ROWS:
                    c.execute("DELETE FROM llm_cache WHERE k IN (SELECT k FROM llm_cache ORDER BY used LIMIT ?)",
                              (n - MAX_ROWS,))
            c.commit()
    except Exception:
        pass


def stats():
    out = dict(_stats)
    try:
        with _lock:
            out["rows"] = _db().execute("SELECT COUNT(*) FROM llm_cache").fetchone()[0]
    except Exception:
        out["rows"] = None
    return out
