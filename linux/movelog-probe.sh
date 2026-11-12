#!/bin/bash
# linux/movelog-probe.sh <origin> <room> <game-id> -- as ada-watch, read-only: a Light Cycles match's move_log, one line
# per tick: when it resolved and, per rider, the direction's source (submitted or clock default) and how long after the
# tick opened the move arrived. No board. The first lines show the log's raw shape (keys only).
main() {
  local origin=${1:?origin} room=${2:?room} gid=${3:?game id} hdr=/home/ada-watch/.agent-chat/invite.header
  curl -sS -m 30 -H @"$hdr" "$origin/api/rooms/$room/games/$gid" </dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
g = d.get("game") if isinstance(d.get("game"), dict) else d
ml = g.get("move_log")
print("top keys:", sorted(g.keys()))
print("move_log type:", type(ml).__name__, "len", len(ml) if hasattr(ml, "__len__") else "-")
if isinstance(ml, list) and ml:
    print("entry keys:", sorted(ml[0].keys()) if isinstance(ml[0], dict) else type(ml[0]).__name__)
    print("first entry:", json.dumps(ml[0])[:600])
elif isinstance(ml, dict) and ml:
    k = next(iter(ml)); print("first key:", k, "value:", json.dumps(ml[k])[:600])
print("moves:", json.dumps(g.get("moves"))[:400])
# Per rider: seconds from the tick opening (the previous tick resolving) to that rider move arriving.
if isinstance(ml, list):
    opened, lat = {}, {}
    for e in ml:
        if isinstance(e, dict) and e.get("resolved_at"):
            opened[int(e["tick"]) + 1] = e["resolved_at"]
    for e in ml:
        if not isinstance(e, dict) or not e.get("submitted") or int(e.get("tick") or 0) not in opened: continue
        lat.setdefault(e.get("name"), []).append((int(e["tick"]), round((e["at"] - opened[int(e["tick"])]) / 1000, 1)))
    import time as _t
    hm = lambda ms: _t.strftime("%H:%M:%S", _t.localtime(ms / 1000)) + ".%d" % (ms % 1000 // 100) if ms else "-"
    for e in ml[-12:]:
        print("  tick %s %s: %s at %s, resolved %s" % (e.get("tick"), e.get("name"), "submitted" if e.get("submitted") else "clock default", hm(e.get("at")), hm(e.get("resolved_at"))))
    for name, xs in lat.items():
        v = sorted(x for _, x in xs)
        print(f"{name}: n={len(v)} median={v[len(v)//2]}s max={v[-1]}s per tick: " + " ".join(f"{t}:{x}" for t, x in xs))
'
  return 0
}
main "$@"; exit $?
