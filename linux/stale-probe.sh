#!/bin/bash
# linux/stale-probe.sh [seconds] -- as ada-watch, read-only: listens to the room's game frames and reads the games list
# every 5 s for the given time (default 240). Prints each frame's envelope and signature, and a MISMATCH line whenever
# a summary's signature differs from its game's last frame (what the watcher's stuck check counts). Ids, names, status
# and counters only; no board, no move text, no token.
main() {
  local secs=${1:-240}
  [[ $secs =~ ^[0-9]+$ ]] || { echo "seconds must be a number"; return 2; }
  SECS=$secs python3 - <<'PY'
import sys, os, json, time, threading
sys.path.insert(0, "/opt/ada-watch")
import watcher as w
room = w.Room(json.load(open(w.CONFIG)))
me = room.get("messages?limit=1").get("you")
end, t0, last = time.time() + int(os.environ["SECS"]), time.time(), {}
lock = threading.Lock()
def ts(): return "%6.1f" % (time.time() - t0)
def prog(g): return {k: g[k] for k in ("turn", "tick", "round", "phase", "turn_of") if k in g}

def frames():
    try:
        with room.open("stream?after=%d&events=game" % 10 ** 9, 45) as r:
            print(ts(), "stream open, as", me, flush=True)
            data = []
            while time.time() < end:
                line = r.readline()
                if not line: print(ts(), "stream closed", flush=True); return
                line = line.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("data:"): data.append(line[5:].lstrip())
                elif not line and data:
                    try: d = json.loads("\n".join(data))
                    except ValueError: d = {}
                    data = []
                    g = d.get("game") if isinstance(d.get("game"), dict) else {}
                    if g.get("id") is None: continue
                    sig = w.gsig(g, w.targets_of(d))
                    with lock: last[g["id"]] = sig
                    print(ts(), "FRAME", g["id"], g.get("type"), "from=%s" % d.get("from"), "targets=%s" % d.get("targets"),
                          "game.targets=%s" % g.get("targets"), "status=%s" % g.get("status"), prog(g), "sig=" + sig, flush=True)
    except Exception as e:
        print(ts(), "stream error", type(e).__name__, flush=True)

threading.Thread(target=frames, daemon=True).start()
n = 0
while time.time() < end:
    time.sleep(5)
    try: games = room.get("games").get("games") or []
    except Exception as e: print(ts(), "games error", type(e).__name__); continue
    for g in games:
        sig = w.gsig(g, w.targets_of({"game": g}))
        with lock: f = last.get(g.get("id"))
        if f is not None and f != sig:
            n += 1
            print(ts(), "MISMATCH", g.get("id"), g.get("type"), "summary=" + sig, "last_frame=" + f, prog(g), flush=True)
print(ts(), "done: %d mismatches" % n)
PY
}
main "$@"; exit $?
