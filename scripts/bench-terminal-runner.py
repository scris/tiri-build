#!/usr/bin/env python3
"""Runs one workload inside a terminal for scripts/bench-terminal.py.

  bench-terminal-runner.py <go-file> <result-file> <token> -- command...

Says it's ready, waits to be told to go, times the command writing to this terminal, records the
times, prints the token as the end marker and then stays, so the terminal is still there to read.
"""
import json
import os
import subprocess
import sys
import time

go, result, token = sys.argv[1:4]
command = sys.argv[sys.argv.index("--") + 1:]
with open(go + ".ready", "w") as out:
    out.write(str(os.getpid()))
while not os.path.exists(go):
    time.sleep(0.005)
start = time.time()
subprocess.run(command)
end = time.time()
sys.stdout.write(f"\x1b[0m\r\n{token}\r\n")
sys.stdout.flush()
with open(result + ".part", "w") as out:
    json.dump({"start": start, "end": end}, out)
os.rename(result + ".part", result)
# In another terminal, with nothing to read the screen back, it ends and the window closes.
if os.environ.get("TIRI_BENCH_EXIT") != "1":
    time.sleep(3600)
