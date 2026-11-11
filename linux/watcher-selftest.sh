#!/bin/bash
# linux/watcher-selftest.sh -- as ada-watch, after install-watcher: tests the installed watcher's logic offline (no send),
# then that kick() ends a real stream's blocked read. Prints PASS/FAIL lines and RESULT; no message text, no token.
main() {
  python3 - <<'PY'
import sys, time, threading, json
sys.path.insert(0, "/opt/ada-watch")
import watcher as w
ok = 0; total = 0
def check(cond, label):
    global ok, total
    total += 1; ok += bool(cond); print(("PASS " if cond else "FAIL ") + label)

w.state.update({"self": "Ada", "seen": 100, "delivered": 100, "awaiting": []})
w.on_message({"id": 101, "from": "Anthony", "text": "hi ``` there", "room_state": {"v": 1}})
w.on_message({"id": 102, "from": "Ada", "text": "mine"})
check([p["id"] for p in w.pending] == [101], "another member's message is queued, our own isn't")
check("room_state" not in w.pending[0]["body"], "room_state is stripped")
t = w.wake_text(w.pending)
check(t.startswith("[Agent Chat]\n````\n") and t.endswith("\n````"), "the fence outgrows the backticks inside")
w.pending.clear()

g = {"id": 21, "status": "running", "phase": "play", "turn": 40, "turn_of": "Ada",
     "players": [{"name": "Ada", "accepted": True, "placed": True}, {"name": "Matheo", "accepted": True, "placed": True}],
     "last_move": {"by": "Matheo", "cell": "E3", "result": "miss", "turn": 39}}
w.on_game({"type": "game", "game": g})
w.on_game({"type": "game", "game": dict(g)})
check(len(w.pending) == 1, "a game frame for our turn is queued once")
w.on_game({"type": "game", "game": dict(g, turn=41, turn_of="Matheo", last_move={"by": "Ada", "turn": 40})})
check(len(w.pending) == 1, "a frame for our own move is skipped")
w.on_game({"type": "game", "game": dict(g, id=22, players=[{"name": "Henry"}, {"name": "Hank"}])})
check(len(w.pending) == 1, "a match we don't play is skipped")
w.on_game({"type": "game", "game": dict(g, status="finished", turn_of=None, winner="Matheo")})
check(len(w.pending) == 2, "a finished match is queued")
w.pending.clear()

item = {"type": "game", "id": 21, "action": "move", "call": {"method": "POST", "path": "/api/rooms/r/games/21/moves"}}
check(w.note_awaiting({"awaiting_you": [item]}, from_check=True) is False and not w.pending, "a game with a fresh frame isn't repeated")
w.state["awaiting"] = []; w.last_frame.clear()
check(w.note_awaiting({"awaiting_you": [item]}, from_check=True) is True and len(w.pending) == 1, "a game awaiting with no frame wakes and flags the stream")
check(w.note_awaiting({"awaiting_you": [item]}, from_check=True) is False and len(w.pending) == 1, "the same item isn't repeated")
w.pending.clear()
big = {"id": 103, "from": "Henry", "text": "x" * 50000}
check(len(w.fenced(big)) < 3000 and "[cut: 48000 more characters]" in w.fenced(big), "an oversized item is cut and says so")

cfg = json.load(open(w.CONFIG)); room = w.Room(cfg)
w.state["seen"] = 10 ** 9
done = {}
def run():
    try:
        w.stream(room); done["how"] = "closed"
    except Exception as e:
        done["how"] = type(e).__name__
th = threading.Thread(target=run, daemon=True); th.start()
for _ in range(100):
    if w.stream_open: break
    time.sleep(0.1)
time.sleep(1); t0 = time.time(); w.kick("selftest"); th.join(10)
check(not th.is_alive() and time.time() - t0 < 5, "kick ends a real stream's read (%s)" % done.get("how"))
print("RESULT %s: %d/%d" % ("PASS" if ok == total else "FAIL", ok, total))
sys.exit(0 if ok == total else 1)
PY
}
main; exit $?
