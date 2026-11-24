#!/usr/bin/env python3
"""The factory's ONE scrub rule set (cmdemo1-system#838): the shared secret pattern and scrub(), imported by everyone
so a log line, a comment and a Pi prompt are redacted by the same rules.

    from scrub import scrub                       run-task: the rule set directly, no item_loop import
    from scrub import SECRET_RE, scrub            item_loop: re-exports both, so every existing call site keeps working

    add_secret_source(fn)                         register a zero-arg callable whose value scrub() must redact

This file is rule text only and never holds a secret value: values reach it only through the caller-registered sources
(item_loop registers its cached GitHub App token there, since scrub.py must not import item_loop) and through the
environment. Nothing here logs, prints or returns a value it redacts.
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gpu as G

# Tokens, temporary and named tunnel hosts (the GPUs' clearmeasure.ai tunnels, with or without a scheme), bearer headers.
SECRET_RE = re.compile(r"(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|https?://[^\s'\"]*trycloudflare\.com[^\s'\"]*"
                       r"|(?:https?://)?[A-Za-z0-9.-]*\b(?:pro\d{4}|\d{4}ti)\.clearmeasure\.ai\b[^\s'\"]*"
                       r"|Bearer\s+\S+|(?i:(?:password|secret|token|apikey|api_key)\s*[=:]\s*)\S+)")

# A registered / environmental value this long or shorter is left alone (it is too short to be a real token, and redacting
# it would eat ordinary words); the cutoff lives here once so the source pass and the environment pass can never drift.
MIN_SECRET_LEN = 6

# The GitHub-token env names beyond gpu.secret_env_names(): the ones gh and the bot's own project access read.
GH_TOKEN_ENV_NAMES = ("GH_TOKEN", "GITHUB_TOKEN", "CM_AI_OPS_BOT_GH_TOKEN", "GH_PROJECT_TOKEN")

# Callers' own secret values (the cached GitHub App token and anything else a module holds): each is a zero-arg callable
# returning the value, asked for on every scrub() and before the environment pass. A source that raises is skipped.
SECRET_SOURCES = []

def add_secret_source(fn):
    """Register a zero-arg callable returning a value scrub() replaces with '[redacted]'. Idempotent: registering the
    same callable twice keeps one entry; None registers nothing."""
    if fn is not None and fn not in SECRET_SOURCES: SECRET_SOURCES.append(fn)
    return fn

def scrub(s):
    s = SECRET_RE.sub("[redacted]", s or "")
    for src in list(SECRET_SOURCES):                       # the caller-owned values first, the environment second
        try: v = src()
        except Exception: continue                         # a broken source is skipped, never fatal
        if v and len(v) > MIN_SECRET_LEN: s = s.replace(v, "[redacted]")
    for name in (*G.secret_env_names(), *GH_TOKEN_ENV_NAMES):
        v = os.environ.get(name)
        if v and len(v) > MIN_SECRET_LEN: s = s.replace(v, "[redacted]")
    return s
