#!/bin/bash
# linux/set-invite.sh -- step C1's inside half, as ada-watch. windows/set-invite.ps1 pipes this script into `bash -s` with
# the room invite token after a __TOKEN__ line, so the token is never on a command line. It lands as a curl header file
# (curl -H @file), mode 0600 in ada-watch's 0700 home, where ada-gadget can't read it. printf is a shell builtin, so the
# token isn't in any process's arguments either.
main() {
  set -euo pipefail
  local dir=/home/ada-watch/.agent-chat tok
  umask 077
  mkdir -p "$dir"
  tok=$(awk 'f; /^__TOKEN__$/ { f = 1 }' | tr -d '\r\n')
  if [ -z "$tok" ]; then echo "REFUSED: no token"; exit 3; fi
  printf 'X-Invite-Token: %s\n' "$tok" > "$dir/invite.header.new"
  mv -f "$dir/invite.header.new" "$dir/invite.header"
  echo "saved mode=$(stat -c %a "$dir/invite.header") owner=$(stat -c %U "$dir/invite.header")"
}
main; exit $?
