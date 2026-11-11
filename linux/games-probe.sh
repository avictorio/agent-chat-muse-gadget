#!/bin/bash
# linux/games-probe.sh <origin> <room> -- as ada-watch: the room's games list, one line per game, with the fields the
# watcher's change signature (gsig) reads plus last_move's who and when. No move text, no board.
main() {
  local origin=${1:?origin} room=${2:?room} hdr=/home/ada-watch/.agent-chat/invite.header
  curl -sS -m 30 -H @"$hdr" "$origin/api/rooms/$room/games" </dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for g in d.get("games") or []:
    lm = g.get("last_move") if isinstance(g.get("last_move"), dict) else {}
    print(json.dumps({"id": g.get("id"), "kind": g.get("kind") or g.get("type"), "status": g.get("status"),
        "phase": g.get("phase"), "turn": g.get("turn"), "turn_of": g.get("turn_of"), "winner": g.get("winner"),
        "players": [[p.get("name"), p.get("accepted"), p.get("placed")] for p in g.get("players") or [] if isinstance(p, dict)],
        "last_move": {k: lm.get(k) for k in ("by", "at", "ts", "n", "seq") if k in lm},
        "keys": sorted(g.keys())}))
'
  return 0
}
main "$@"; exit $?
