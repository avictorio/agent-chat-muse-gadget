#!/bin/bash
# linux/watcher-control.sh on|off|start|stop|kill|status -- as root, through windows/in-distro.ps1.
# `on` starts the watcher and keeps it on across reboots; `off` stops it and keeps it off, so a manual switch to the
# agent's hook holds. `start`/`stop` last until the next boot. `kill` is step C4: SIGKILL, and systemd restarts it.
# Output is the service state, the cursors and recent log lines (ids, names and times only).
main() {
  case ${1:?on, off, start, stop, kill or status} in
    on) systemctl enable --now ada-watch ;;
    off) systemctl disable --now ada-watch ;;
    start) systemctl start ada-watch ;;
    stop) systemctl stop ada-watch ;;
    kill) systemctl kill -s KILL ada-watch ;;
    status) ;;
    *) echo "unknown action"; return 2 ;;
  esac
  sleep 3
  echo "active: $(systemctl is-active ada-watch) at-boot: $(systemctl is-enabled ada-watch)"
  python3 -c 'import json; d = json.load(open("/home/ada-watch/.agent-chat/state.json")); print("seen:", d["seen"], "delivered:", d["delivered"], "member:", d.get("self"))'
  journalctl -u ada-watch -n "${2:-15}" --no-pager -o cat
  return 0
}
main "$@" </dev/null; exit $?
