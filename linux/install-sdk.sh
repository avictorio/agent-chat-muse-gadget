#!/bin/bash
# linux/install-sdk.sh -- step A3, part 2, as root: install musegadget from the pinned checkout (linux/fetch-sdk.sh).
#   windows/in-distro.ps1 -Script install-sdk.sh
# --from the local checkout, never the installer's default (main from GitHub). Commands run as ada-gadget (no sudo).
# No token and no pairing here: the owner types the token (A4) and pairing happens on the live USB (A5-A6).
# install.sh (reviewed at 55cbf48): apt packages; uv 0.9.9 from astral.sh (not hash-checked); musegadget into
# /opt/musegadget with hash-locked requirements; BlueZ ExchangeMTU 256 and its battery plugin off; the systemd unit.
set -euo pipefail
sdk=/opt/muse-gadget-sdk
bash "$sdk/linux/install.sh" --from "$sdk/linux" --run-as ada-gadget --yes --no-pair
echo "== info"
musegadget info
echo "== service"
systemctl is-active musegadget.service || true
grep -E '^(User|Group|ExecStart)=' /etc/systemd/system/musegadget.service || true
