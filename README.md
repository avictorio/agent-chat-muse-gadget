# agent-chat-muse-gadget

A fast wake path for the owner's Muse agent: a Muse Gadget SDK host on the Legion that watches an Agent Chat room and
posts a pointer-only wake message into a Muse side chat. Phase 1 research memo: kept by the owner (Nov 10, 2026). The
agent's own hook stays the guarantee; this path is best-effort (dark while the laptop sleeps).

## Layout

- `windows/`: run from the Legion's `operator` account.
  - `setup-account.ps1` (elevated): the `muse-gadget` Windows account, its runner, and with `-KeepAlive` the
    keep-alive task.
  - `import-distro.ps1` (elevated): the `muse-gadget` WSL distro from Ubuntu 24.04's checksummed WSL image.
  - `run-as-gadget.ps1`: run a command as `muse-gadget` through its runner.
  - `in-distro.ps1`: pipe one of `linux/*.sh` into the distro as a chosen Linux user.
  - `set-token.ps1`: the owner types the SDK token (hidden input).
  - `export-seed.ps1`, `import-state.ps1`: the owner moves the state over a USB stick for pairing (A5, A7).
- `linux/`: run inside the distro through `windows/in-distro.ps1`.
  - `harden.sh`, `check-hardening.sh`: `wsl.conf`, the accounts, and the check.
  - `fetch-sdk.sh`, `install-sdk.sh`: the SDK at a pinned commit, installed with `--run-as ada-gadget --no-pair`.
  - `import-state.sh`, `check-registered.sh`: A7's inside half and its check.
- `docs/pairing-runbook.md`: A5-A7, step by step, for the owner.

## Steps

| Step | Status | Done when (observed) |
| --- | --- | --- |
| A0 `muse-gadget` account + runner | done 2026-11-10 | runner reports `user=muse-gadget elevated=False` |
| A1 distro `muse-gadget` | done 2026-11-10 | sha256 matches SHA256SUMS; `wsl -l -v` lists it, version 2, Ubuntu 24.04 |
| A2 hardening | done 2026-11-10 | `check-hardening.sh` RESULT PASS 10/10 after `wsl --terminate` |
| A3 SDK at `55cbf48`, no pairing | done 2026-11-10 | `musegadget info`: node id, `paired: no`; service active |
| A4 SDK token (owner) | done 2026-11-10 | `set-token.ps1` RESULT PASS |
| A5-A7 pair from a live USB, copy state back (owner; docs/pairing-runbook.md) | done 2026-11-10 | `check-registered.sh` RESULT PASS 4/4 |
| A8 keep-alive | done 2026-11-10 (came up by itself after a reboot) | after 5 min with nothing else attached: distro up since the task started, `sleep infinity` as ada-watch, service active |

## Security

The memo assumed the distro would run under the owner's Windows account. It runs under a dedicated standard account
instead (`muse-gadget`: Users only, no interactive or RDP sign-in, hidden from the sign-in screen, a random password only
Task Scheduler holds), so even Linux root reaches only what that account can. Checked on 2026-11-10:

- **Interop.** With `[interop] enabled=false`, WSL still registers its binfmt hook, but a Windows program fails to start
  (`UtilAcceptVsock: accept4 failed 110`), tested by root mounting C: and running `whoami.exe` as `ada-watch`.
  `wsl-interop-off.service` also unregisters the hook at boot.
- **Drives.** Automount is off, but root can still `mount -t drvfs C:`. As `muse-gadget` that reaches no SHA data:
  `C:\agent`, the other accounts' profiles, `C:\ProgramData\hermes-panel` and `hermes-status` are all denied.
- **VM and network.** The distro runs in its own WSL VM (a different boot id from the `hermes` account's Docker
  Desktop VM), in NAT mode. From inside it, of the laptop's listening TCP ports below 49152 only 3389 (RDP) and 7680
  (Delivery Optimization) answer on the host address; none of the `127.0.0.1`/`127.0.0.2` services do (Ollama, Chrome's
  DevTools, the gateways, Hindsight, the panel). The internet and the home network are reachable.
- **Linux accounts.** No admin account: maintenance is `wsl -d muse-gadget -u root`, which only the `muse-gadget`
  Windows account can start (operator drives it through the runner). `ada-gadget` and `ada-watch` have no password and
  no sudo; `ada-watch`'s home is 0700.
- **Residual risk** (memo section 4): anything that can steer the Muse agent can run commands as `ada-gadget`, reach the
  internet and home network, and post device-attributed messages through the musegadget socket.
- `install.sh` fetches uv 0.9.9 from astral.sh without a hash check; everything else is pinned (`55cbf48`) or
  hash-locked.

## Never commit

Tokens (`mgst_...`, Agent Chat invites), `identity.json`, `pairing.json`, logs, or the room's name.
