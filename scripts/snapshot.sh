#!/bin/bash
# Emits one JSON object describing Hermes agent status:
#   { "active": {...}|null, "sessions": [ ... ] }
# Sessions come out of the Hermes SQLite store (~/.hermes/state.db), locally
# or over ssh when a remote host is given as $1 (key-based auth required).
# Only stdout JSON matters; everything else goes to stderr.
#
# Bounded by design: the query caps rows (8) and the local python caps the
# consumed bytes at MAX_BYTES.

REMOTE="${1:-}"
if [[ -n "$REMOTE" ]]; then
  # Remote fetch: sqlite3 CLI may not exist on the server, but python3's
  # sqlite3 module is always there. Emits the same JSON rows as the CLI.
  # (No single quotes allowed inside REMOTE_PY — it is shell-quoted below.)
  REMOTE_PY='import json,sqlite3,os
con=sqlite3.connect(os.path.expanduser("~/.hermes/state.db"))
con.row_factory=sqlite3.Row
q="SELECT id, substr(title,1,60) AS title, substr(cwd,1,120) AS cwd, substr(model,1,40) AS model, message_count AS messages, last_activity_at AS last_active, (ended_at IS NULL OR last_activity_at > ended_at) AS open FROM sessions WHERE hidden=0 AND archived=0 ORDER BY last_activity_at DESC LIMIT 8"
print(json.dumps([dict(r) for r in con.execute(q)]))'
  FETCH=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" "python3 -c '$REMOTE_PY'")
else
  if [[ ! -f "$HOME/.hermes/state.db" ]]; then
    printf '{"active": null, "sessions": []}\n'
    exit 0
  fi
  QUERY="
SELECT id,
       substr(COALESCE(title,''),1,60)  AS title,
       substr(COALESCE(cwd,''),1,120)   AS cwd,
       substr(COALESCE(model,''),1,40)  AS model,
       message_count AS messages,
       last_activity_at AS last_active,
       ended_at IS NULL OR last_activity_at > ended_at AS open
FROM sessions
WHERE hidden = 0 AND archived = 0
ORDER BY last_activity_at DESC
LIMIT 8;
"
  FETCH=(sqlite3 -json "$HOME/.hermes/state.db" "$QUERY")
fi

exec "${FETCH[@]}" 2>/dev/null | python3 -c '
import json, sys, time

now = time.time()
LIVE_WINDOW = 60    # seconds of fresh activity that counts as "working"
MAX_BYTES = 4096    # hard ceiling on consumed query output

raw = sys.stdin.buffer.read(MAX_BYTES).decode("utf-8", "replace").strip()
if not raw:
    print("{\"active\": null, \"sessions\": []}")
    sys.exit(0)

try:
    rows = json.loads(raw)
except Exception:
    # Truncated mid-row by the byte cap: drop the trailing partial row.
    trimmed = raw.rsplit("}", 1)[0]
    try:
        rows = json.loads(trimmed + "}]")
    except Exception:
        rows = []

def plain(text):
    # Strip markup-significant characters so nothing that reaches the QML
    # layer can be interpreted as rich text (Text.AutoText renders <img>
    # and friends; tooltips have no PlainText override available).
    return str(text or "").replace("<", "‹").replace(">", "›").replace("&", "+")

sessions = []
for r in rows[:8]:
    sessions.append({
        "id": str(r.get("id") or ""),
        "title": plain(r.get("title")) or "(untitled)",
        "cwd": plain(r.get("cwd")),
        "model": plain(r.get("model")),
        "messages": int(r.get("messages") or 0),
        "lastActiveTs": float(r.get("last_active") or 0),
        # Live = still open (never ended, or activity continued past an end
        # marker — resumed sessions keep a stale ended_at) AND heartbeat fresh.
        "live": bool(r.get("open")) and now - float(r.get("last_active") or 0) < LIVE_WINDOW,
    })

# The live record is whichever session most recently did anything at all;
# it only reads as "working" when that heartbeat is fresh.
active = next((s for s in sessions if s["live"]), None)
if active is None and sessions and now - sessions[0]["lastActiveTs"] < 900:
    active = sessions[0]

print(json.dumps({"active": active, "sessions": sessions}))
'
