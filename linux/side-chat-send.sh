#!/bin/bash
# linux/side-chat-send.sh <side-chat-id> [count] [gap-seconds] -- step B2, as ada-watch, through windows/in-distro.ps1.
# Posts numbered test messages into one Muse side chat and prints each one's send-to-ack time. Count 0 sends nothing: it
# only prints the CLI's options and the distro's clock. The chat id is an argument so it stays out of the repo.
# Everything is inside main, which bash reads whole first; each command gets /dev/null so none can eat the piped script.
main() {
  local id=${1:?side-chat id} count=${2:-0} gap=${3:-60} i t0 t1 out rc
  [[ $id =~ ^[A-Za-z0-9-]{1,64}$ ]] || { echo "bad side-chat id"; return 2; }
  echo "user=$(id -un) now_ms=$(date +%s%3N)"
  if [ "$count" = 0 ]; then musegadget send-user-msg --help </dev/null; return $?; fi
  for ((i = 1; i <= count; i++)); do
    t0=$(date +%s%3N)
    out=$(musegadget send-user-msg --session-id "$id" "POC wake $i, t0=$t0, quote me and give your turn-start time in epoch ms" </dev/null 2>&1)
    rc=$?
    t1=$(date +%s%3N)
    echo "wake=$i t0=$t0 ack_ms=$((t1 - t0)) rc=$rc out=$out"
    [ "$i" -lt "$count" ] && sleep "$gap"
  done
  return 0
}
main "$@"; exit $?
