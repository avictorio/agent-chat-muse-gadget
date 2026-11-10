#!/bin/bash
# linux/harden.sh -- step A2, as root inside the muse-gadget distro (windows/in-distro.ps1 -Script harden.sh).
# Rerunnable. Before anything is paired:
#   /etc/wsl.conf: systemd on; Windows interop, the Windows PATH and drive automount off; default user ada-watch.
#   ada-gadget: the SDK's --run-as account. No sudo, no password: Muse's commands run as it.
#   ada-watch:  runs the watcher; in group ada-gadget for the musegadget socket; its 0700 home keeps its room token
#               away from ada-gadget.
# There is no Linux admin account: maintenance is `wsl -d muse-gadget -u root`, which only the muse-gadget Windows
# account (driven by operator through its runner) can start. Takes effect after `wsl --terminate muse-gadget`.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

cat > /etc/wsl.conf <<'EOF'
# Written by linux/harden.sh. Interop and automount stay off: see the repo's README, Security.
[boot]
systemd=true

[interop]
enabled=false
appendWindowsPath=false

[automount]
enabled=false
mountFsTab=false

[user]
default=ada-watch
EOF
echo "wrote /etc/wsl.conf"

# With interop off, WSL still registers its binfmt hook for Windows programs; the hook then fails (no interop server),
# so nothing runs. Drop the hook at boot too, as a second layer.
cat > /etc/systemd/system/wsl-interop-off.service <<'EOF'
[Unit]
Description=Unregister WSL's binfmt hook for Windows programs (linux/harden.sh)
After=systemd-binfmt.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ] || echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop'

[Install]
WantedBy=multi-user.target
EOF
systemctl enable wsl-interop-off.service >/dev/null 2>&1 || ln -sf /etc/systemd/system/wsl-interop-off.service /etc/systemd/system/multi-user.target.wants/
echo "wsl-interop-off.service enabled"

# Mount points left by the first boot, before automount was off.
for d in /mnt/*; do
  case "$d" in /mnt/wsl|/mnt/wslg) continue ;; esac
  if ! mountpoint -q "$d"; then rmdir "$d" 2>/dev/null && echo "removed empty $d"; fi
done

for u in ada-gadget ada-watch; do
  if ! id "$u" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$u" >/dev/null
    echo "created $u"
  fi
  passwd -l "$u" >/dev/null
  for g in sudo adm admin; do
    if id -nG "$u" | tr ' ' '\n' | grep -qx "$g"; then gpasswd -d "$u" "$g" >/dev/null; fi
  done
  chmod 0700 "/home/$u"
done
usermod -aG ada-gadget ada-watch

# No sudoers entry may name either account.
if grep -rEq '^[^#]*\bada-(gadget|watch)\b' /etc/sudoers /etc/sudoers.d 2>/dev/null; then
  echo "FAIL: a sudoers rule names ada-gadget or ada-watch"; exit 1
fi
echo "accounts: $(id ada-gadget) | $(id ada-watch)"
echo "HARDEN DONE"
