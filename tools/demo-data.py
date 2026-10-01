#!/usr/bin/env python3
"""Write 30 days of synthetic agent logs into a fake home directory, for screenshots.

    tools/demo-data.py /tmp/demo-home

Every agent gets logs in its real on-disk format, so the screenshots exercise the same parsers
as real use. Seeded, so the same day always produces the same picture. Timestamps are relative
to now, so "today" and "active now" are always populated.
"""
import json, random, sqlite3, sys, uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

home = Path(sys.argv[1])
rng = random.Random(7)
now = datetime.now(timezone.utc).replace(microsecond=0)
local_midnight = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)

def iso(t): return t.astimezone(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

def day_times(day, n):
    """n timestamps spread over working hours of `day` days ago (0 = today, never in the future)."""
    start = local_midnight - timedelta(days=day) + timedelta(hours=9)
    # earlier work today ended a while ago; only the explicit sessions below are "active now"
    end = min(start + timedelta(hours=10), now - timedelta(minutes=45)) if day == 0 else start + timedelta(hours=10)
    if end <= start: return []
    span = (end - start).total_seconds()
    return sorted(start + timedelta(seconds=rng.random() * span) for _ in range(n))

def weekday_factor(day):
    wd = (local_midnight - timedelta(days=day)).weekday()
    return 0.25 if wd >= 5 else 1.0

PROJECTS = "/Users/you/code"

# ── Claude Code ──────────────────────────────────────────────────────────────
TITLES = [
    "Add OAuth login to the web app", "Fix flaky checkout test", "Migrate settings to SQLite",
    "Speed up image pipeline", "Refactor billing webhooks", "Dark mode for dashboard",
    "Write onboarding docs", "Upgrade to React 20", "Investigate memory leak in worker",
]
claude_projects = ["webapp", "webapp", "billing-service", "mobile-app"]

def claude_session(project, title, times, model):
    sid = str(uuid.UUID(int=rng.getrandbits(128)))
    cwd = f"{PROJECTS}/{project}"
    d = home / ".claude/projects" / cwd.replace("/", "-")
    d.mkdir(parents=True, exist_ok=True)
    lines = [{"type": "user", "cwd": cwd, "sessionId": sid, "timestamp": iso(times[0])},
             {"type": "ai-title", "aiTitle": title, "sessionId": sid}]
    for t in times:
        lines.append({
            "type": "assistant", "cwd": cwd, "sessionId": sid, "timestamp": iso(t),
            "message": {"id": "msg_" + uuid.UUID(int=rng.getrandbits(128)).hex, "model": model, "usage": {
                "input_tokens": rng.randint(2, 40), "output_tokens": rng.randint(300, 2500),
                "cache_read_input_tokens": rng.randint(40_000, 160_000),
                "cache_creation_input_tokens": rng.randint(500, 6000)}}})
    (d / f"{sid}.jsonl").write_text("".join(json.dumps(l, separators=(",", ":")) + "\n" for l in lines))

for day in range(30, 0, -1):
    for _ in range(rng.randint(2, 4)):
        n = int(rng.randint(60, 180) * weekday_factor(day))
        if n:
            claude_session(rng.choice(claude_projects), rng.choice(TITLES), day_times(day, n),
                           rng.choice(["claude-opus-5-5", "claude-opus-5-5", "claude-sonnet-5"]))
# today: two finished sessions, two still running
claude_session("billing-service", "Refactor billing webhooks", day_times(0, 120), "claude-opus-5-5")
claude_session("webapp", "Fix flaky checkout test", day_times(0, 60), "claude-sonnet-5")
claude_session("webapp", "Add OAuth login to the web app",
               [now - timedelta(minutes=m) for m in range(160, 0, -2)], "claude-opus-5-5")
claude_session("mobile-app", "Dark mode for dashboard",
               [now - timedelta(minutes=m, seconds=30) for m in range(70, 3, -1)], "claude-sonnet-5")

# ── Codex CLI ────────────────────────────────────────────────────────────────
def codex_session(project, times):
    sid = str(uuid.UUID(int=rng.getrandbits(128)))
    t0 = times[0]
    d = home / ".codex/sessions" / t0.strftime("%Y/%m/%d")
    d.mkdir(parents=True, exist_ok=True)
    lines = [{"timestamp": iso(t0), "type": "session_meta", "payload": {"id": sid, "cwd": f"{PROJECTS}/{project}"}},
             {"timestamp": iso(t0), "type": "turn_context", "payload": {"model": "gpt-5.5", "cwd": f"{PROJECTS}/{project}"}}]
    for t in times:
        inp = rng.randint(30_000, 90_000)
        lines.append({"timestamp": iso(t), "type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"input_tokens": inp, "cached_input_tokens": int(inp * 0.85),
                                 "output_tokens": rng.randint(400, 2200), "reasoning_output_tokens": rng.randint(0, 800)}}}})
    name = f"rollout-{t0.strftime('%Y-%m-%dT%H-%M-%S')}-{sid}.jsonl"
    (d / name).write_text("".join(json.dumps(l, separators=(",", ":")) + "\n" for l in lines))

for day in range(30, -1, -1):
    if rng.random() < 0.6 * weekday_factor(day):
        codex_session(rng.choice(["api-server", "webapp"]), day_times(day, rng.randint(30, 90)) or [now])
codex_session("api-server", [now - timedelta(minutes=m) for m in range(40, 5, -3)])

# ── Gemini CLI ───────────────────────────────────────────────────────────────
for day in range(30, -1, -1):
    if rng.random() < 0.35 * weekday_factor(day):
        times = day_times(day, rng.randint(20, 60))
        if not times: continue
        sid = str(uuid.UUID(int=rng.getrandbits(128)))
        d = home / ".gemini/tmp" / uuid.UUID(int=rng.getrandbits(128)).hex / "chats"
        d.mkdir(parents=True, exist_ok=True)
        lines = [{"sessionId": sid, "projectHash": "x", "directories": [f"{PROJECTS}/docs-site"]}]
        for i, t in enumerate(times):
            inp = rng.randint(20_000, 80_000)
            lines.append({"id": f"m{i}", "type": "gemini", "model": "gemini-2.5-pro", "timestamp": iso(t),
                          "tokens": {"input": inp, "cached": int(inp * 0.7), "output": rng.randint(300, 1500)}})
        (d / f"session-{sid}.jsonl").write_text("".join(json.dumps(l, separators=(",", ":")) + "\n" for l in lines))

# ── Grok CLI ─────────────────────────────────────────────────────────────────
for day in range(30, 0, -1):
    if rng.random() < 0.3 * weekday_factor(day):
        times = day_times(day, rng.randint(20, 50))
        sid = str(uuid.UUID(int=rng.getrandbits(128)))
        d = home / ".grok/sessions" / quote(f"{PROJECTS}/cli-tool", safe="") / sid
        d.mkdir(parents=True, exist_ok=True)
        lines = [{"timestamp": times[0].timestamp(), "params": {"sessionId": sid, "update": {
            "sessionUpdate": "user_message_chunk", "_meta": {"modelId": "grok-code-fast-1"}}}}]
        for t in times:
            inp = rng.randint(30_000, 70_000)
            lines.append({"timestamp": t.timestamp(), "params": {"sessionId": sid, "update": {
                "sessionUpdate": "turn_completed", "usage": {"inputTokens": inp, "cachedReadTokens": int(inp * 0.8),
                                                             "outputTokens": rng.randint(300, 1500)}}}})
        (d / "updates.jsonl").write_text("".join(json.dumps(l, separators=(",", ":")) + "\n" for l in lines))

# ── opencode ─────────────────────────────────────────────────────────────────
oc = home / ".local/share/opencode"
oc.mkdir(parents=True, exist_ok=True)
db = sqlite3.connect(oc / "opencode.db")
db.executescript("""
CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, title TEXT, parent_id TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
""")
for day in range(30, -1, -1):
    if rng.random() < 0.4 * weekday_factor(day):
        times = day_times(day, rng.randint(15, 40))
        if not times: continue
        sid = "ses_" + uuid.UUID(int=rng.getrandbits(128)).hex[:12]
        db.execute("INSERT INTO session VALUES (?,?,?,NULL)", (sid, f"{PROJECTS}/infra", "Terraform cleanup"))
        for i, t in enumerate(times):
            ms = int(t.timestamp() * 1000)
            data = {"role": "assistant", "modelID": "claude-sonnet-5", "cost": round(rng.uniform(0.01, 0.06), 4),
                    "tokens": {"input": rng.randint(5, 50), "output": rng.randint(300, 1500),
                               "cache": {"read": rng.randint(20_000, 60_000), "write": rng.randint(0, 3000)}},
                    "time": {"created": ms}}
            db.execute("INSERT INTO message VALUES (?,?,?,?,?)", (f"msg_{sid}_{i}", sid, ms, ms, json.dumps(data)))
db.commit()
print(f"demo home → {home}")
