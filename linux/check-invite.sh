#!/bin/bash
# linux/check-invite.sh <origin> <room> -- step C1's check, as ada-watch: the room's API answers with the saved invite and
# names the member it belongs to. Prints the member name and the last message id, never message text or the token. The
# origin and room are arguments so they stay out of the repo.
main() {
  local origin=${1:?origin} room=${2:?room} hdr=/home/ada-watch/.agent-chat/invite.header t code rc
  [ -r "$hdr" ] || { echo "FAIL no invite saved"; echo "RESULT FAIL"; return 1; }
  t=$(mktemp)
  code=$(curl -sS -m 30 -o "$t" -w '%{http_code}' -H @"$hdr" "$origin/api/rooms/$room/messages?limit=1" </dev/null) || code=no-answer
  if [ "$code" != 200 ]; then rm -f "$t"; echo "FAIL http=$code"; echo "RESULT FAIL"; return 1; fi
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("member:", d.get("you") or "(none)")
print("last_id:", d.get("last_id"))
sys.exit(0 if d.get("you") else 1)' "$t" </dev/null
  rc=$?
  rm -f "$t"
  if [ "$rc" = 0 ]; then echo "RESULT PASS: the invite resolves to a member"; else echo "RESULT FAIL"; fi
  return "$rc"
}
main "$@"; exit $?
