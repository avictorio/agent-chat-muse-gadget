#!/bin/bash
# linux/install-watcher.sh <origin> <room> <side-chat-id> -- step C2's inside half, as root. windows/install-watcher.ps1
# pipes this script into `bash -s` with watcher.py as base64 after a __FILE__ line. Installs the watcher and its systemd
# unit, writes its config, and primes the cursors. It doesn't change whether the watcher is on: linux/watcher-control.sh
# `on` starts it and keeps it on across reboots, `off` stops it and keeps it off.
main() {
  set -euo pipefail
  local origin=$1 room=$2 chat=$3 dir=/home/ada-watch/.agent-chat
  install -d -m 0755 /opt/ada-watch
  awk 'f; /^__FILE__$/ { f = 1 }' | tr -d '\r\n' | base64 -d > /opt/ada-watch/watcher.py
  chown root:root /opt/ada-watch/watcher.py
  chmod 0755 /opt/ada-watch/watcher.py
  python3 -m py_compile /opt/ada-watch/watcher.py
  rm -rf /opt/ada-watch/__pycache__
  printf '{"origin": "%s", "room": "%s", "chat": "%s"}\n' "$origin" "$room" "$chat" > "$dir/watcher.json"
  chown ada-watch:ada-watch "$dir/watcher.json"
  chmod 0600 "$dir/watcher.json"
  printf '%s\n' '[Unit]' 'Description=Agent Chat watcher' \
    'After=network-online.target musegadget.service' '' '[Service]' 'User=ada-watch' \
    'ExecStart=/usr/bin/python3 /opt/ada-watch/watcher.py' 'Restart=always' 'RestartSec=2' 'NoNewPrivileges=yes' \
    'ProtectSystem=strict' "ReadWritePaths=$dir" 'PrivateTmp=yes' '' '[Install]' 'WantedBy=multi-user.target' \
    > /etc/systemd/system/ada-watch.service
  systemctl daemon-reload
  runuser -u ada-watch -- /usr/bin/python3 /opt/ada-watch/watcher.py --prime </dev/null
  echo "installed; cursor file: $(stat -c '%a %U' "$dir/state.json")"
  echo "enabled at boot: $(systemctl is-enabled ada-watch 2>/dev/null || true)"
}
main "$@"; exit $?
