#!/bin/bash
# linux/watcher-selftest.sh -- as ada-watch, after install-watcher: tests the installed watcher's logic offline (no send),
# then that kick() ends a real stream's blocked read. Prints PASS/FAIL lines and RESULT; no message text, no token.
main() {
  python3 - <<'PY'
import sys, time, threading, json
sys.path.insert(0, "/opt/ada-watch")
import watcher as w
w.STATE = "/tmp/watcher-selftest-state.json"   # never the real cursors
w.save = lambda: None
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

lc = {"id": 28, "type": "lightcycles", "status": "running", "tick": 9, "players": [{"name": "Ada"}, {"name": "SHA"}]}
w.on_game({"type": "game", "from": "SHA", "kind": "agent", "targets": ["Ada"], "game": lc})
w.on_game({"type": "game", "from": "Ada", "kind": "agent", "targets": ["Ada", "SHA"], "game": dict(lc, tick=10)})
w.on_game({"type": "game", "from": "Ada", "kind": "agent", "targets": ["SHA"], "game": dict(lc, tick=10)})
w.on_game({"type": "game", "from": "SHA", "kind": "agent", "targets": ["Hank"], "game": dict(lc, id=30)})
check(len(w.pending) == 1, "envelope: a game frame for us from someone else passes; our own, or not for us, doesn't")
w.on_game({"type": "game", "from": "Referee", "kind": "non_interactive", "targets": ["Ada", "SHA"], "game": dict(lc, tick=11)})
check(len(w.pending) == 2, "envelope: a clock-driven frame from the Referee passes")
w.on_reaction({"type": "reaction", "id": 5, "from": "SHA", "targets": ["Ada"], "reaction": "x"})
w.on_reaction({"type": "reaction", "id": 6, "from": "SHA", "targets": ["Henry"], "reaction": "x"})
w.on_reaction({"type": "reaction", "id": 7, "from": "Ada", "targets": ["Ada"], "reaction": "x"})
check(len(w.pending) == 3 and w.pending[-1]["kind"] == "reaction", "a reaction to our message passes; others don't")
w.pending.clear()

s19 = {"id": 19, "type": "battleship", "status": "running", "turn": 50, "targets": ["Henry"]}
s20 = {"id": 20, "type": "newgame", "status": "running", "targets": ["Ada", "Jen"]}
check(w.check_games([s19, s20]) == [] and [p["body"]["game"]["id"] for p in w.pending] == [20],
      "the first games read records where games stand, and wakes any game (of any type) that targets us")
w.pending.clear()
w.on_game({"type": "game", "from": "Henry", "targets": ["Ada"], "game": dict(s19, turn=51)})
w.pending.clear()
check(w.check_games([dict(s19, turn=51, targets=["Ada"]), s20]) == [], "a summary that matches its last frame is fine")
moved = dict(s19, turn=53, targets=["Ada", "Henry"])
check(w.check_games([moved]) == [] and not w.pending, "one check behind isn't called stuck yet")
check(w.check_games([moved]) == [19] and len(w.pending) == 1, "two checks behind: stuck (named by id), and the summary is woken")
check(w.check_games([moved]) == [] and len(w.pending) == 1, "the missed game isn't woken twice")
w.pending.clear()
for i in range(200, 250):
    w.queue("message", {"id": i, "from": "Henry"}, i)
b = w.take_batch()
check(len(b) == 10 and b[0]["id"] == 220 and len(w.pending) == 30 and w.skipped == list(range(200, 220)),
      "a 50-item backlog keeps the newest 30, sends 10 per wake, and lists the 20 dropped")
check("(20 older messages not shown: ids 200-219)" in w.wake_text(b, w.skipped), "the wake names what was dropped")
w.pending.clear(); w.skipped.clear()
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
