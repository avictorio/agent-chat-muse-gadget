#!/bin/bash
# linux/auth-probe.sh <origin> <room> -- as ada-watch, read-only: why a room read is refused. Prints the HTTP status, the
# response's content type and server headers, and the reply body's first 300 characters for the room's last message
# read, made with and then without the saved invite. Never prints the token.
main() {
  local origin=${1:?origin} room=${2:?room} hdr=/home/ada-watch/.agent-chat/invite.header tmp
  tmp=$(mktemp -d) || return 1
  for mode in with-invite no-invite; do
    local args=(-sS -m 30 -o "$tmp/body" -D "$tmp/head" -w '%{http_code}')
    [[ $mode == with-invite ]] && args+=(-H @"$hdr")
    echo "== $mode: http $(curl "${args[@]}" "$origin/api/rooms/$room/messages?limit=1" </dev/null)"
    grep -i -E '^(content-type|server|cf-mitigated|cf-ray|www-authenticate):' "$tmp/head" | cut -c1-120
    head -c 300 "$tmp/body" | tr -d '\r' | grep -v -i -E 'token|invite=' ; echo
  done
  rm -rf "$tmp"
  return 0
}
main "$@"; exit $?
