#!/bin/bash
# linux/watch-diag.sh <origin> [since] -- as root: summarises the watcher's journal (event counts, every event other than a
# wake, wake spacing, and how late each message wake was) and greps the room API's public docs for the wake-related
# fields. Ids, names and times only.
main() {
  local origin=${1:?origin} since=${2:--12h}
  echo "== journal since $since"
  journalctl -u ada-watch --since "$since" -o cat --no-pager </dev/null | python3 -c '
import json, sys, collections
ev = []
for line in sys.stdin:
    try: ev.append(json.loads(line))
    except ValueError: print("text:", line.strip()[:160])
print("counts:", dict(collections.Counter(e.get("event") for e in ev)))
for e in ev:
    if e.get("event") != "wake": print("event:", json.dumps(e))
w = [e for e in ev if e.get("event") == "wake"]
gaps = [round((b["t_send_ms"] - a["t_send_ms"]) / 1000, 1) for a, b in zip(w, w[1:])]
print("wake gaps (s):", gaps)
for e in w:
    if e.get("ids"):
        print("message wake: ids", e["ids"], "post->send s", [round((e["t_send_ms"] - t) / 1000, 1) for t in e["server_ts"] if t])
'
  echo "== api docs: wake-related lines"
  curl -sS -m 30 "$origin/api" </dev/null | grep -n -i -E 'awaiting_you|event: ?game|game frame|stream|ping|turn_of' | cut -c1-300 | head -n 60
  return 0
}
main "$@"; exit $?
