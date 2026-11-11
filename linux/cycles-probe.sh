#!/bin/bash
# linux/cycles-probe.sh <origin> <room> [game-id] -- as ada-watch: a light-cycles match's timing fields (status, tick,
# tick_seconds, deadline, mode, moves' shape) and the API docs' light-cycles lines. No board.
main() {
  local origin=${1:?origin} room=${2:?room} gid=${3:-} hdr=/home/ada-watch/.agent-chat/invite.header
  curl -sS -m 30 -H @"$hdr" "$origin/api/rooms/$room/games" </dev/null | GID="$gid" python3 -c '
import json, os, sys, time
gid = os.environ.get("GID")
for g in json.load(sys.stdin).get("games") or []:
    if g.get("type") != "lightcycles" or (gid and str(g.get("id")) != gid) or (not gid and g.get("status") != "running"): continue
    mv = g.get("moves")
    print(json.dumps({k: g.get(k) for k in ("id", "status", "mode", "tick", "tick_seconds", "deadline", "lobby_deadline", "winner", "record_keeper")}))
    print("now_ms", int(time.time() * 1000), "players", [{k: p.get(k) for k in p if k not in ("trail", "path", "cells")} for p in g.get("players") or []])
    print("moves type", type(mv).__name__, (sorted(mv.keys()) if isinstance(mv, dict) else (len(mv) if isinstance(mv, list) else mv)))
'
  echo "== docs"
  curl -sS -m 30 "$origin/api" </dev/null | grep -n -i -E 'cycle|tick' | cut -c1-260 | head -n 40
  return 0
}
main "$@"; exit $?
