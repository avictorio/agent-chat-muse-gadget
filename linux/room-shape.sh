#!/bin/bash
# linux/room-shape.sh <origin> <room> [stream-seconds] [raw] -- as ada-watch: shows the shape of the room API's answers, for
# designing the wake. Prints the last two messages (REST) and any stream frames within the window, with every string
# longer than 24 characters replaced by its length, so message text doesn't print.
main() {
  local origin=${1:?origin} room=${2:?room} secs=${3:-20} hdr=/home/ada-watch/.agent-chat/invite.header
  [ "${4:-}" = raw ] && export RAW=1   # print strings in full: for the owner's eyes, never for a log or the repo
  local shape='
import json, os, sys
import re
TOKENISH = re.compile(r"(invite=|X-Invite-Token: ?|rooms\.txt[^\n]*\n\s*\S+ )\S+")
def s(v):   # agent_onboarding carries this member invite token, so it never prints, raw or not
    if isinstance(v, dict): return {k: ("<withheld>" if k == "agent_onboarding" else s(x)) for k, x in v.items()}
    if isinstance(v, str): v = TOKENISH.sub(lambda m: m.group(1) + "<token>", v)
    if isinstance(v, list): return [s(x) for x in v[:6]] + (["...%d more" % (len(v) - 6)] if len(v) > 6 else [])
    if isinstance(v, str) and len(v) > 24 and not os.environ.get("RAW"): return "<%d chars>" % len(v)
    return v
if sys.argv[1:] == ["rest"]:
    print(json.dumps(s(json.load(sys.stdin)), indent=1)); sys.exit()
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("data:"):
        try: print("data:", json.dumps(s(json.loads(line[5:])), indent=1))
        except ValueError: print("data: <not json>")
    elif line.startswith("{"):
        print(json.dumps(s(json.loads(line)), indent=1))
    elif line.startswith("event:"):
        print(line)
'
  echo "== REST messages?limit=2"
  curl -sS -m 30 -H @"$hdr" "$origin/api/rooms/$room/messages?limit=2" </dev/null | python3 -c "$shape" rest
  echo "== REST games (live first, then recent finished)"
  curl -sS -m 30 -H @"$hdr" "$origin/api/rooms/$room/games" </dev/null | python3 -c "$shape" rest
  echo "== stream for ${secs}s (live frames only)"
  curl -sS -N -m "$secs" -H @"$hdr" "$origin/api/rooms/$room/stream?after=999999999&events=all" </dev/null | python3 -c "$shape"
  return 0
}
main "$@"; exit $?
