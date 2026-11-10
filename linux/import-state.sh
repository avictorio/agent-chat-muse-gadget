#!/bin/bash
# linux/import-state.sh -- step A7's inside half, as root. windows/import-state.ps1 pipes this script into `bash -s`
# with the paired state appended as base64 after a __STATE__ line, so nothing passes through a command line. Everything
# is inside main, which bash reads whole before it runs; main's awk then reads the rest of stdin (the state).
# Refuses state whose identity (its mac, from which the node id is derived) isn't this gadget's.
main() {
  set -euo pipefail
  local dir=/var/lib/musegadget mine theirs f
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT   # global: the trap runs after main returns
  awk 'f; /^__STATE__$/ { f = 1 }' | tr -d '\r\n' | base64 -d | tar -C "$t" -xf - identity.json pairing.json sdk_token
  mine=$(mac "$dir/identity.json"); theirs=$(mac "$t/identity.json")
  if [ -z "$mine" ] || [ "$mine" != "$theirs" ]; then echo "REFUSED: that state belongs to another device"; exit 3; fi
  for f in identity.json pairing.json sdk_token; do install -m 0600 -o root -g root "$t/$f" "$dir/$f"; done
  systemctl restart musegadget
  echo imported
}
mac() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("mac", ""))' "$1"; }
main; exit $?
