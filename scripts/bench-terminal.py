#!/usr/bin/env python3
"""Measures a Tiri terminal on heavy output. Run through scripts/bench-terminal.sh, not by hand.

For each workload it opens a terminal in the copy at TIRI_SOCKET, runs the workload in it, and reports:
  seconds   from the writer starting until the end marker is on the terminal's screen, as `tiri read` sees it
  MB/s      the workload's bytes over that time
  drain     of those seconds, how long the screen took to catch up once the writer had finished
  main p50/p99/max  round trips of `ping`, which runs on the app's main thread, every 10 ms during the run
  echo p50/max      with --echo: typing into a second terminal running `cat`, until it shows up there
  cpu       CPU seconds used during the run by the app, the relay (tiri-session attach in the app) and the
            session server (the background tiri-session that owns the program's terminal)
  MB        the app's memory footprint after the run, and how much it grew
"""
import argparse
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))


class Control:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.buffer = b""

    def call(self, _command, **args):
        request = {"id": uuid.uuid4().hex[:8], "cmd": _command, "args": args}
        self.sock.sendall(json.dumps(request).encode() + b"\n")
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise RuntimeError("Tiri closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        response = json.loads(line)
        if not response.get("ok", True) and response.get("error"):
            raise RuntimeError(f"{_command}: {response['error']}")
        return response.get("result")


def processes():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,time=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            rows.append((int(parts[0]), int(parts[1]), cpu_seconds(parts[2]), parts[3]))
    return rows


def cpu_seconds(text):
    total = 0.0
    for part in text.split(":"):
        total = total * 60 + float(part)
    return total


def cpu_of(pids):
    by_pid = {row[0]: row[2] for row in processes()}
    return {name: by_pid.get(pid, 0.0) for name, pid in pids.items()}


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def wait_for(predicate, timeout, interval=0.01):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    return None


def run_workload(control, args, name, command, size):
    token = uuid.uuid4().hex[:10]
    # The terminal starts in an empty folder. Its signals live beside it, so writing them doesn't
    # set off Tiri's file watching in the workspace being measured.
    scratch = os.path.join(args.work, "runs")
    signals = os.path.join(args.work, "signals")
    os.makedirs(scratch, exist_ok=True)
    os.makedirs(signals, exist_ok=True)
    go = os.path.join(signals, token + ".go")
    result_path = os.path.join(signals, token + ".json")
    runner = os.path.join(HERE, "bench-terminal-runner.py")

    echo_item = None
    if args.echo:
        echo_item = control.call("term", cwd=scratch, cmd="exec cat")["item"]
    item = control.call("term", cwd=scratch, cmd=f"exec python3 -I {runner} {go} {result_path} {token} -- {command}")["item"]

    # The runner's parent is the session server. The relay is the other tiri-session for this item.
    ready = wait_for(lambda: os.path.exists(go + ".ready") and open(go + ".ready").read().strip(), 20)
    if not ready:
        raise RuntimeError(f"{name}: the runner never started")
    runner_pid = int(ready)
    rows = processes()
    parent = {row[0]: row[1] for row in rows}
    server = parent.get(runner_pid, 0)
    relay = next((row[0] for row in rows if "tiri-session attach" in row[3] and item in row[3] and row[0] != server), 0)
    pids = {"app": args.app_pid, "relay": relay, "server": server}
    time.sleep(0.3)

    before = cpu_of(pids)
    memory_before = control.call("perf")["footprintMB"]

    pings, echoes = [], []
    finished = threading.Event()

    def ping_loop():
        own = Control(args.socket)
        while not finished.is_set():
            start = time.perf_counter()
            own.call("ping")
            pings.append((time.perf_counter() - start) * 1000)
            time.sleep(0.01)

    def echo_loop():
        own = Control(args.socket)
        count = 0
        while not finished.is_set():
            count += 1
            word = f"k{count}x"
            start = time.perf_counter()
            own.call("send", item=echo_item, text=word)
            while not finished.is_set():
                text = own.call("read", item=echo_item, lines=3)["text"]
                if word in text:
                    echoes.append((time.perf_counter() - start) * 1000)
                    break
                time.sleep(0.002)
            time.sleep(0.1)

    threads = [threading.Thread(target=ping_loop, daemon=True)]
    if echo_item:
        threads.append(threading.Thread(target=echo_loop, daemon=True))
    for thread in threads:
        thread.start()

    sampler = None
    if args.sample:
        sample_out = os.path.join(args.out, f"sample-{name}.txt")
        sampler = subprocess.Popen(["sample", str(args.app_pid), str(args.sample), "-file", sample_out],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    open(go, "w").close()
    written = wait_for(lambda: os.path.exists(result_path) and open(result_path).read(), args.timeout, 0.005)
    if not written:
        raise RuntimeError(f"{name}: no result within {args.timeout} s")
    timing = json.loads(written)
    shown = wait_for(lambda: token in control.call("read", item=item, lines=4)["text"] and time.time(), 120, 0.005)
    finished.set()
    for thread in threads:
        thread.join(5)
    if sampler:
        sampler.wait()
    after = cpu_of(pids)
    perf = control.call("perf")
    counts = next((t for t in perf.get("terminals", []) if t["item"] == item), {})

    control.call("close", item=item)
    if echo_item:
        control.call("close", item=echo_item)

    seconds = (shown or time.time()) - timing["start"]
    return {
        "workload": name,
        "MB": round(size / 1048576, 1),
        "seconds": round(seconds, 3),
        "MB/s": round(size / 1048576 / seconds, 1) if size else None,
        "writer": round(timing["end"] - timing["start"], 3),
        "drain": round((shown or time.time()) - timing["end"], 3),
        "main_p50_ms": round(statistics.median(pings), 1) if pings else None,
        "main_p99_ms": round(percentile(pings, 0.99), 1),
        "main_max_ms": round(max(pings), 1) if pings else None,
        "echo_p50_ms": round(statistics.median(echoes), 1) if echoes else None,
        "echo_max_ms": round(max(echoes), 1) if echoes else None,
        "echoes": len(echoes),
        "cpu_app": round(after["app"] - before["app"], 2),
        "cpu_relay": round(after["relay"] - before["relay"], 2),
        "cpu_server": round(after["server"] - before["server"], 2),
        "footprint_MB": round(perf["footprintMB"], 1),
        "growth_MB": round(perf["footprintMB"] - memory_before, 1),
        "frames": counts.get("frames"),
        "renders": counts.get("renders"),
        "batches": counts.get("batches"),
        "mainHops": counts.get("mainHops"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=os.environ.get("TIRI_SOCKET"))
    parser.add_argument("--work", required=True, help="folder holding the workloads, from bench-terminal-workloads.py")
    parser.add_argument("--out", required=True)
    parser.add_argument("--app-pid", type=int, required=True)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--only", default="", help="comma-separated workload names")
    parser.add_argument("--echo", action="store_true")
    parser.add_argument("--sample", type=int, default=0, help="seconds of `sample` on the app during each run")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--label", default="run")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    def cat(file):
        path = os.path.join(args.work, file)
        return f"cat {path}", os.path.getsize(path)

    workloads = {
        "ascii": cat("ascii.txt"),
        "sgr": cat("sgr.txt"),
        "unicode": cat("unicode.txt"),
        "wrap": cat("wrap.txt"),
        "seq": ("seq 1 5000000", 38_888_896),
        "idle": ("sleep 5", 0),
        "agent": cat("agent.txt"),
    }
    chosen = [name for name in workloads if not args.only or name in args.only.split(",")]
    control = Control(args.socket)
    results = []
    for name in chosen:
        for run in range(args.runs):
            command, size = workloads[name]
            row = run_workload(control, args, name, command, size)
            row["run"] = run + 1
            results.append(row)
            print(json.dumps(row), flush=True)
            time.sleep(1)
    with open(os.path.join(args.out, f"{args.label}.json"), "w") as out:
        json.dump(results, out, indent=1)


if __name__ == "__main__":
    main()
