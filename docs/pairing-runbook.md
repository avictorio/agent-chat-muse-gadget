# Pairing runbook (steps A5-A7)

The gadget's distro has no Bluetooth, so it pairs once from an Ubuntu live session booted on the same laptop, using
the SDK's documented copy route (`linux/docs/raspberry-pi-2-headless.md` in the SDK at `55cbf48`). The live session
keeps nothing after shutdown, so the SDK's last step (unpairing the helper) happens by itself.

About 30 minutes. The owner does every step; Claude opens the Windows windows and checks the result.

## Before you start

- **Two USB sticks.**
  - An **Ubuntu 24.04 desktop live stick**: the ISO from ubuntu.com (check its SHA256 against the site's list), written
    with Rufus or balenaEtcher.
  - A **state stick**: any FAT32 or exFAT stick. It carries the gadget's identity and token out and its pairing back,
    and `import-state.ps1` wipes it at the end.
- **The BitLocker recovery key for C:** at hand (from your Microsoft account, or wherever you saved it). C: unlocks with
  the TPM alone, and a one-time boot from USB normally doesn't disturb that. **Don't change anything in the firmware
  settings** (Secure Boot is on, and Ubuntu boots with it on); a firmware change is what triggers the recovery prompt.
- **Wi-Fi password** for the live session: the Muse app expects the pairing machine to be online.
- **The agents go offline** while the laptop is in Ubuntu (gateways, panel, Telegram). They start again when Windows
  boots; sign `hermes` back in on the screen afterwards so the panel's Chrome view works.
- **Phone**: the Muse app, signed in, with Bluetooth on, near the laptop.

## A5. Put the seed on the state stick (Windows, `operator`)

Plug in the state stick, note its drive letter (say `E:`), and in a PowerShell window in `operator`'s session:

```
powershell -ExecutionPolicy Bypass -File C:\Users\operator\muse-gadget\windows\export-seed.ps1 -Drive E:
```

Done when it prints `RESULT PASS: E:\muse-gadget\seed.tar`. Eject the stick safely. Then **shut down** Windows from the
Start menu (hold Shift while you click Shut down, so it's a full shutdown).

## A6. Pair from the live session (Ubuntu)

1. Plug in the Ubuntu stick, power on, and tap **F12** (Legion boot menu; or the Novo pinhole, then Boot Menu). Pick the
   USB stick. In Ubuntu's menu choose **Try Ubuntu** (never Install).
2. Connect to Wi-Fi. Plug in the state stick; it opens under `/media/ubuntu/<its name>`.
3. Open **Terminal** and paste these lines (right-click > Paste), changing `STICK` if needed:

   ```sh
   STICK=$(ls -d /media/ubuntu/*/muse-gadget | head -1); echo "$STICK"
   bluetoothctl show | grep -E 'Roles|Advertising Features'
   sudo apt-get update -qq && sudo apt-get install -y -qq git
   sudo mkdir -m 0700 /var/lib/musegadget && sudo tar -C /var/lib/musegadget -xf "$STICK/seed.tar"
   git clone -q https://github.com/facebookincubator/muse-gadget-sdk ~/sdk && git -C ~/sdk checkout -q 55cbf48
   cd ~/sdk/linux && bash install.sh --from . --yes
   ```

   `echo` must print the stick's `muse-gadget` folder, and `bluetoothctl` should list `Roles: peripheral` and an
   `Advertising Features` block. The installer ends by opening the pairing window and naming the device
   **MuseGadgetEFC56E**. If the name differs, stop: the seed didn't load.
4. In the Muse app, within ten minutes: **Settings > Devices > Developer mode** on, then **Add Device**, pick
   **MuseGadgetEFC56E**, accept the community-device warning, and pick the network shown when asked for Wi-Fi. If the
   window closes, run `sudo musegadget pair`.
5. Then:

   ```sh
   sudo musegadget info | grep -E 'node id|paired'
   sudo systemctl disable --now musegadget
   sudo tar -C /var/lib/musegadget -cf "$STICK/paired.tar" identity.json pairing.json sdk_token && sync
   ```

   Done when `info` shows `node id: homelink-efc56e` and `paired: yes`, and the `tar` line prints nothing.
6. Shut Ubuntu down (top-right menu > Power Off), remove the Ubuntu stick when told, and let Windows start.

## A7. Bring the pairing home (Windows, `operator`)

Sign in to `operator`, plug in the state stick, and run:

```
powershell -ExecutionPolicy Bypass -File C:\Users\operator\muse-gadget\windows\import-state.ps1 -Drive E:
```

It refuses another device's state, installs the three files as root, restarts the service, zeroes and deletes the
stick's copies, and runs `linux/check-registered.sh`. Done when that prints `RESULT PASS: 4/4` (paired, active, Noise
session, registered with the Muse). The gadget then shows under Settings > Devices in the app.

The end-to-end check (SDK): ask your Muse to run `hostname` on the gadget. It must answer with the laptop's name, not
`ubuntu` (the live session's).

## If something goes wrong

- **BitLocker recovery screen** when Windows starts: type the recovery key. Nothing is lost; it happens when the
  firmware thinks the boot path changed.
- **No `Roles: peripheral`** in the live session: the adapter can't advertise there. Stop and tell Claude; the fallback
  is a USB Bluetooth dongle (memo section 1).
- **Re-pairing later** (device removed in the app, or token revoked) repeats A5-A7 from a fresh live session.
