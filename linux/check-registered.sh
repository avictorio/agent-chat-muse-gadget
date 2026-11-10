#!/bin/bash
# linux/check-registered.sh -- step A7's Done when, as root (windows/in-distro.ps1 -Script check-registered.sh).
pass=0; total=0
point() { total=$((total + 1)); if [ "$1" = 0 ]; then pass=$((pass + 1)); echo "PASS $2"; else echo "FAIL $2"; fi; }
info=$(musegadget info)
echo "$info" | grep -E '^(node id|paired):'
echo "$info" | grep -qE '^paired:\s+yes'; point $? "musegadget info: paired: yes"
systemctl is-active -q musegadget; point $? "the musegadget service is active"
log=$(journalctl -u musegadget -b --no-pager -o cat)
echo "$log" | grep -q 'Noise session established'; point $? "the log shows a Noise session"
echo "$log" | grep -q 'registered with the Muse'; point $? "the log shows: registered with the Muse"
echo "RESULT $([ $pass = $total ] && echo PASS || echo FAIL): $pass/$total"
[ $pass = $total ]
