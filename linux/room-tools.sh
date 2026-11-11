#!/bin/bash
# linux/room-tools.sh <origin> <room> [pattern] -- as ada-watch: the room's MCP tool catalog (tools/list), each tool's
# name, and the full description and input schema of those matching the pattern. Reads only; no token printed.
main() {
  local origin=${1:?origin} room=${2:?room} pat=${3:-upload} hdr=/home/ada-watch/.agent-chat/invite.header
  curl -sS -m 30 -H @"$hdr" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}' "$origin/api/rooms/$room/mcp" </dev/null |
  python3 -c '
import json, re, sys
raw = sys.stdin.read()
body = raw[raw.index("{"):] if "data:" in raw else raw
if "data:" in raw:
    body = [l[5:] for l in raw.splitlines() if l.startswith("data:")][0]
tools = json.loads(body)["result"]["tools"]
print("tools:", ", ".join(t["name"] for t in tools))
for t in tools:
    if re.search(sys.argv[1], t["name"] + " " + t.get("description", ""), re.I):
        print("\n==", t["name"]); print(t.get("description", "")); print(json.dumps(t.get("inputSchema"), indent=1))
' "$pat"
  return 0
}
main "$@"; exit $?
