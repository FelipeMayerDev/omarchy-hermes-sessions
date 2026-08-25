#!/bin/bash
# Emits one JSON object describing Hermes agent status:
#   { "active": {...}|null, "sessions": [ ... ] }
# Sessions come straight out of the Hermes SQLite store (~/.hermes/state.db).
# Only stdout JSON matters; everything else goes to stderr.

DB="$HOME/.hermes/state.db"

if [[ ! -f "$DB" ]]; then
  printf '{"active": null, "sessions": []}\n'
  exit 0
fi

QUERY="
SELECT id, COALESCE(title,'') AS title, COALESCE(cwd,'') AS cwd,
       COALESCE(model,'') AS model, message_count AS messages,
       tool_call_count AS tools, source,
       started_at AS started_at, last_activity_at AS last_active,
       ended_at IS NULL AND last_activity_at > $(( $(date +%s) - 180 )) AS live,
       hidden, archived
FROM sessions
WHERE hidden = 0 AND archived = 0
ORDER BY last_activity_at DESC
LIMIT 60;
"

ROWS="$(sqlite3 -json "$DB" "$QUERY" 2>/dev/null)"
[[ -z "$ROWS" ]] && ROWS='[]'

python3 - "$ROWS" <<'PYEOF'
import json, sys, time

try:
    rows = json.loads(sys.argv[1])
except Exception:
    rows = []

now = time.time()

def age(ts):
    try:
        d = now - float(ts)
    except Exception:
        return "?"
    if d < 90: return "just now"
    if d < 3600: return f"{int(d//60)}m ago"
    if d < 86400: return f"{int(d//3600)}h ago"
    return f"{int(d//86400)}d ago"

sessions = []
for r in rows[:60]:
    sessions.append({
        "id": str(r.get("id") or ""),
        "title": str(r.get("title") or "(untitled)"),
        "cwd": str(r.get("cwd") or ""),
        "model": str(r.get("model") or ""),
        "messages": int(r.get("messages") or 0),
        "tools": int(r.get("tools") or 0),
        "source": str(r.get("source") or ""),
        "lastActive": age(r.get("last_active")),
        "lastActiveTs": float(r.get("last_active") or 0),
        "live": bool(r.get("live")),
    })

# The live record is whichever session most recently did anything at all;
# it only reads as "working" when that heartbeat is fresh.
active = next((s for s in sessions if s["live"]), None)
if active is None and sessions and now - sessions[0]["lastActiveTs"] < 900:
    active = sessions[0]

print(json.dumps({"now": now, "active": active, "sessions": sessions}))
PYEOF
