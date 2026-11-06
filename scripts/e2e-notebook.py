#!/usr/bin/env python3
"""Runs real notebooks through Resources/remote/tiri-kernel.py, the way Tiri does, and checks what happens.

    scripts/e2e-notebook.py <python with ipykernel, jupyter_client and matplotlib> [case ...]

Each case starts its own runner and kernel in a new folder, talks to it over its socket as the app would, and
stops it. Nothing here opens a window. Cases: flood, moves, agent, layout, killed, odd, gentle.
"""
import json
import os
import queue
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

# TIRI_KERNEL_SCRIPT=<another tiri-kernel.py> runs the same cases against that one, to compare.
RUNNER = os.environ.get("TIRI_KERNEL_SCRIPT") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "remote", "tiri-kernel.py")
# TIRI_E2E_EPOCHS=<n> for a shorter flood.
EPOCHS = int(os.environ.get("TIRI_E2E_EPOCHS") or 5000)
failures = []


def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + ("  " + str(detail) if detail != "" else ""), flush=True)
    if not ok:
        failures.append(name)


def code(source, id=None):
    cell = {"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": source.splitlines(True)}
    if id:
        cell["id"] = id
    return cell


def markdown(source, id=None):
    cell = {"cell_type": "markdown", "metadata": {}, "source": source.splitlines(True)}
    if id:
        cell["id"] = id
    return cell


def notebook(cells, minor=5):
    return {"cells": cells, "metadata": {}, "nbformat": 4, "nbformat_minor": minor}


class Runner:
    """One notebook's runner, and a connection to it like the app's."""

    def __init__(self, python, folder, name, content, text=None):
        self.python = python
        self.path = os.path.join(folder, name)
        with open(self.path, "w", newline="") as file:
            file.write(text if text is not None else json.dumps(content, indent=1, sort_keys=True, ensure_ascii=False) + "\n")
        self.directory = tempfile.mkdtemp(prefix="k", dir=folder)
        subprocess.run([python, RUNNER, "start", self.directory, self.path], check=True)
        self.messages = queue.Queue()
        self.received = 0
        try:
            self.socket = self.connect()
        except RuntimeError:
            # It may be running all the same, and nothing else would stop it.
            for pid in (self.kernel_pid(), self.runner_pid()):
                if pid and alive(pid):
                    os.kill(pid, signal.SIGKILL)
            raise
        threading.Thread(target=self.read, daemon=True).start()

    def connect(self):
        for _ in range(100):
            try:
                connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                # Relative, as the runner does it: a socket's whole path has a short limit.
                here = os.getcwd()
                os.chdir(self.directory)
                try:
                    connection.connect("s")
                finally:
                    os.chdir(here)
                return connection
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("the runner didn't start")

    def read(self):
        buffer = b""
        while True:
            try:
                data = self.socket.recv(1 << 16)
            except OSError:
                break
            if not data:
                break
            self.received += len(data)
            buffer += data
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                self.messages.put(json.loads(line))
        self.messages.put({"ev": "closed"})

    def send(self, **command):
        self.socket.sendall(json.dumps(command).encode() + b"\n")

    def wait(self, test, timeout=60):
        """Messages until one passes `test`. All of them, and that one."""
        seen = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.messages.get(timeout=max(deadline - time.time(), 0.01))
            except queue.Empty:
                break
            seen.append(message)
            if test(message):
                return seen, message
        return seen, None

    def idle(self, timeout=120):
        return self.wait(lambda m: (m.get("ev") == "status" and m.get("state") in ("idle", "stopped", "dead") and m.get("running") is None
                                    and not m.get("queued")) or m.get("ev") == "closed", timeout)

    def run(self, *cells):
        self.send(op="run", cells=list(cells))
        self.wait(lambda m: m.get("ev") == "status" and m.get("state") == "busy", 60)

    def cells(self):
        with open(self.path, encoding="utf-8") as file:
            return json.load(file)["cells"]

    def kernel_pid(self):
        found = subprocess.run(["pgrep", "-f", "ipykernel_launcher.*" + os.path.basename(self.directory)], capture_output=True, text=True).stdout.split()
        if found:
            return int(found[0])
        # The connection file's name isn't in its command line everywhere: its parent is this runner.
        runner = self.runner_pid()
        children = subprocess.run(["pgrep", "-P", str(runner)], capture_output=True, text=True).stdout.split() if runner else []
        return int(children[0]) if children else None

    def runner_pid(self):
        found = subprocess.run(["pgrep", "-f", "tiri-kernel.py start " + self.directory], capture_output=True, text=True).stdout.split()
        return int(found[0]) if found else None

    def stop(self):
        runner = self.runner_pid()
        kernel = self.kernel_pid()
        try:
            self.send(op="stop")
        except OSError:
            pass
        deadline = time.time() + 10
        while time.time() < deadline and runner and alive(runner):
            time.sleep(0.05)
        for pid in (kernel, runner):
            if pid and alive(pid):
                os.kill(pid, signal.SIGKILL)
        try:
            self.socket.close()
        except OSError:
            pass


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def case_flood(python, folder):
    """A training loop with a figure every epoch, and a viewer that never reads."""
    source = ("import matplotlib\nmatplotlib.use('module://matplotlib_inline.backend_inline')\nimport matplotlib.pyplot as plt\n"
              "import numpy as np\nfor epoch in range(%d):\n    plt.plot(np.arange(10) * epoch)\n    plt.show()\n    print('epoch', epoch)\n") % EPOCHS
    runner = Runner(python, folder, "flood.ipynb", notebook([code(source, "train")]))
    try:
        # Someone with Tiri open but its window stuck: attached, never reading.
        stuck = runner.connect()
        stuck.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        began = time.time()
        runner.run(0)
        seen, _ = runner.idle(float(os.environ.get("TIRI_E2E_FLOOD_TIMEOUT") or 900))
        took = time.time() - began
        outputs = runner.cells()[0]["outputs"]
        pushes = [m for m in seen if m.get("ev") == "output"]
        check("flood: %d figures finish" % EPOCHS, runner.cells()[0]["execution_count"] is not None, "%.1f s" % took)
        check("flood: outputs kept are capped", len(outputs) <= 221, "%d outputs, file %.1f MB" % (len(outputs), os.path.getsize(runner.path) / 1e6))
        note = [o for o in outputs if (o.get("metadata") or {}).get("tiri")]
        check("flood: a note says how many were left out", bool(note), note[0]["data"]["text/plain"] if note else "")
        check("flood: pushes say what changed", all("from" in m for m in pushes) and any(m["from"] > 0 for m in pushes),
              "%d pushes, %.1f MB in all, biggest %.2f MB" % (len(pushes), runner.received / 1e6, max(len(json.dumps(m)) for m in pushes) / 1e6))
        # And while it floods, the stuck viewer doesn't hold up an interrupt.
        runner.send(op="edit", action="clear")
        runner.run(0)
        time.sleep(3)
        asked = time.time()
        runner.send(op="interrupt")
        _, done = runner.idle(60)
        check("flood: interrupt with a stuck viewer attached", done is not None, "%.2f s to idle" % (time.time() - asked))
        stuck.close()
    finally:
        runner.stop()


def case_moves(python, folder):
    """Cells added above a running one, by Tiri and by an agent, and duplicated ids."""
    for minor in (4, 5):
        ids = minor >= 5
        cells = [code("a = 1\n", "a" if ids else None), code("import time\nfor i in range(30):\n    print(i, flush=True)\n    time.sleep(0.1)\n", "long" if ids else None)]
        runner = Runner(python, folder, "moves%d.ipynb" % minor, notebook(cells, minor))
        try:
            runner.run(1)
            time.sleep(0.8)
            runner.send(op="edit", action="insert", after=-1, kind="code")
            time.sleep(0.8)
            # An agent's edit: a new markdown cell at the top, written straight to the file.
            content = json.load(open(runner.path))
            content["cells"].insert(0, markdown("# Added by an agent\n", "agent" if ids else None))
            with open(runner.path + ".tmp", "w") as file:
                json.dump(content, file, indent=1)
            os.replace(runner.path + ".tmp", runner.path)
            time.sleep(0.6)
            seen, _ = runner.idle(60)
            pushes = [m for m in seen if m.get("ev") == "output"]
            final = runner.cells()
            where = [i for i, cell in enumerate(final) if "range(30)" in "".join(cell.get("source", []))]
            check("moves (nbformat 4.%d): outputs saved on the cell that ran" % minor,
                  where == [3] and final[3]["outputs"] and not any(c.get("outputs") for i, c in enumerate(final) if i != 3),
                  "running cell now at %s" % where)
            check("moves (nbformat 4.%d): the last pushes name its new place" % minor, pushes and pushes[-1]["index"] == 3,
                  [m["index"] for m in pushes][-3:])
        finally:
            runner.stop()
    for minor in (4, 5):
        # Asked for by place while the kernel started, and a cell added above it before the runner read the file.
        runner = Runner(python, folder, "stale%d.ipynb" % minor, notebook([code("print('wanted')\n", "w" if minor >= 5 else None)], minor))
        try:
            content = json.load(open(runner.path))
            content["cells"].insert(0, code("print('not this one')\n", "new" if minor >= 5 else None))
            with open(runner.path, "w") as file:
                json.dump(content, file, indent=1)
            runner.send(op="run", cells=[0], ids=["w" if minor >= 5 else None], sources=["print('wanted')\n"], count=1)
            runner.wait(lambda m: m.get("ev") == "status" and m.get("state") == "busy", 60)
            runner.idle(60)
            final = runner.cells()
            check("stale place (nbformat 4.%d): the cell asked for runs, not what's there now" % minor,
                  final[1]["outputs"] and not final[0]["outputs"], [c["outputs"] for c in final])
        finally:
            runner.stop()
    runner = Runner(python, folder, "dup.ipynb", notebook([code("print('first')\n", "same"), code("print('second')\n", "same")]))
    try:
        runner.run(1)
        runner.idle(60)
        final = runner.cells()
        check("duplicate ids: the copy asked for runs", final[1]["outputs"] and final[1]["outputs"][0]["text"] == ["second\n"] and not final[0]["outputs"])
        check("duplicate ids: repaired when saving", final[0]["id"] == "same" and final[1]["id"] != "same", [c["id"] for c in final])
    finally:
        runner.stop()


def case_agent(python, folder):
    """An agent writes the file while a cell runs and saves every two seconds."""
    cells = [code("import time\nfor i in range(60):\n    print('x' * 2000, flush=True)\n    time.sleep(0.1)\n", "run"), markdown("old note\n", "note")]
    runner = Runner(python, folder, "agent.ipynb", notebook(cells))
    try:
        runner.run(0)
        written = 0
        for round in range(25):
            time.sleep(0.2)
            content = json.load(open(runner.path))
            content["cells"][1]["source"] = ["agent edit %d\n" % round]
            with open(runner.path, "w") as file:
                json.dump(content, file, indent=1)
            written = round
        runner.idle(60)
        final = runner.cells()
        check("agent: its last edit survives the kernel's saves", final[1]["source"] == ["agent edit %d\n" % written], final[1]["source"])
        check("agent: the run's outputs are saved too", final[0]["execution_count"] is not None and final[0]["outputs"])
    finally:
        runner.stop()


def case_layout(python, folder):
    """Notebooks written with CRLF and with tabs: after a run, git shows only the outputs."""
    shutil.which("git") or sys.exit("git is needed for this case")
    for style in ("crlf", "tabs", "vscode"):
        repo = tempfile.mkdtemp(prefix=style, dir=folder)
        subprocess.run(["git", "init", "-q", repo], check=True)
        content = notebook([code("print('héllo')\nimport math\nmath.pi\n", "c1"), markdown("Café, 1e-5\n", "m1")])
        content["metadata"] = {"papermill": {"duration": 1e-05}}
        if style == "tabs":
            text = json.dumps(content, indent="\t", sort_keys=True, ensure_ascii=False) + "\n"
        else:
            text = json.dumps(content, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
        if style == "crlf":
            text = text.replace("\n", "\r\n")
        if style == "vscode":
            text = text.replace("1e-05", "1e-5")
        runner = Runner(python, repo, "layout.ipynb", None, text)
        try:
            env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
            subprocess.run(["git", "-C", repo, "add", "layout.ipynb"], check=True)
            subprocess.run(["git", "-C", repo, "-c", "core.autocrlf=false", "commit", "-qm", "before"], check=True, env=env)
            runner.run(0)
            runner.idle(60)
            diff = subprocess.run(["git", "-C", repo, "diff", "--no-color", "-U0", "layout.ipynb"], capture_output=True, text=True).stdout
            removed = [line for line in diff.splitlines() if line.startswith("-") and not line.startswith("---")]
            added = [line for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++")]
            after = open(runner.path, newline="").read()
            check("layout %s: git diff touches only the cell's outputs and count" % style,
                  all("outputs" in line or "execution_count" in line for line in removed) and added,
                  "-%d +%d lines; removed: %s" % (len(removed), len(added), [line.strip() for line in removed]))
            check("layout %s: its line endings and indent stay" % style,
                  ("\r\n" in after) == (style == "crlf") and ("\n\t" in after) == (style == "tabs") and (style != "vscode" or "1e-5" in after)
                  and "Café" in after)
            print("      " + "\n      ".join(diff.splitlines()[4:16]))
        finally:
            runner.stop()


def case_killed(python, folder):
    """The kernel killed as the system does when memory runs out."""
    runner = Runner(python, folder, "killed.ipynb", notebook([code("import time\nprint('working', flush=True)\ntime.sleep(60)\n", "k")]))
    try:
        runner.run(0)
        time.sleep(1.5)
        pid = runner.kernel_pid()
        check("killed: found the kernel", pid is not None, pid)
        os.kill(pid, signal.SIGKILL)
        seen, problem = runner.wait(lambda m: m.get("ev") == "problem", 20)
        check("killed: says why", problem is not None and "memory" in problem.get("message", ""), problem and problem.get("message"))
        check("killed: the page stops showing it running", any(m.get("ev") == "status" and m.get("state") == "stopped" and m.get("running") is None for m in seen))
        error = [o for o in runner.cells()[0]["outputs"] if o["output_type"] == "error"]
        check("killed: the cell says so", error and "memory" in error[0]["evalue"], error and error[0]["evalue"])
        # It starts again for the next run.
        runner.run(0)
        runner.send(op="interrupt")
        _, done = runner.idle(60)
        check("killed: running a cell starts it again", done is not None)
    finally:
        runner.stop()
    runner = Runner(python, folder, "crash.ipynb", notebook([code("import ctypes, time\nprint('about to crash', flush=True)\nimport sys\nsys.stderr.write('native trouble\\n'); sys.stderr.flush()\nimport os\nos.write(2, b'from C: bad pointer\\n')\ntime.sleep(0.5)\nctypes.string_at(0)\n", "c")]))
    try:
        runner.run(0)
        _, problem = runner.wait(lambda m: m.get("ev") == "problem", 30)
        check("crashed: says it crashed in native code, with its last words", problem is not None and "native code" in problem.get("message", "") and "bad pointer" in (problem.get("detail") or ""),
              problem and (problem.get("message"), problem.get("detail")))
        print("      cell:", json.dumps(runner.cells()[0]["outputs"])[:600])
    finally:
        runner.stop()


def case_odd(python, folder):
    """A notebook with a null cell in it, and a bad command: the runner carries on."""
    text = json.dumps({"cells": [None, code("print('after the null')\n", "a"), 7, code("print('last')\n", "b")], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}, indent=1)
    runner = Runner(python, folder, "odd.ipynb", None, text)
    try:
        runner.send(op="edit", action="clear", index=0)
        runner.send(op="edit", action="source", index=2, source="x")
        runner.send(op="run", cells="nonsense")
        runner.send(op="run", all=True)
        runner.wait(lambda m: m.get("ev") == "status" and m.get("state") == "busy", 60)
        seen, _ = runner.idle(60)
        final = json.load(open(runner.path))["cells"]
        check("odd: both code cells ran", final[1]["outputs"] and final[3]["outputs"], [c.get("outputs") if isinstance(c, dict) else c for c in final])
        check("odd: the null and the 7 are still there", final[0] is None and final[2] == 7)
        check("odd: the runner is still alive", runner.runner_pid() is not None)
    finally:
        runner.stop()


def case_gentle(python, folder):
    """Stop and Restart let the kernel clean up; a second Restart doesn't wait."""
    marks = os.path.join(folder, "marks")
    os.makedirs(marks, exist_ok=True)
    source = ("import atexit, time\natexit.register(lambda: open(%r, 'w').write('atexit'))\ntry:\n    time.sleep(60)\nfinally:\n"
              "    open(%r, 'w').write('finally')\n") % (os.path.join(marks, "atexit"), os.path.join(marks, "finally"))
    runner = Runner(python, folder, "gentle.ipynb", notebook([code(source, "g")]))
    try:
        runner.run(0)
        time.sleep(1.5)
        began = time.time()
        runner.send(op="stop")
        runner.wait(lambda m: m.get("ev") == "closed", 15)
        check("stop: the cell's finally ran", os.path.exists(os.path.join(marks, "finally")), "stopped in %.1f s" % (time.time() - began))
        check("stop: atexit ran", os.path.exists(os.path.join(marks, "atexit")))
    finally:
        runner.stop()
    for name in ("atexit", "finally"):
        try:
            os.unlink(os.path.join(marks, name))
        except OSError:
            pass
    stubborn = "import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nsignal.signal(signal.SIGINT, signal.SIG_IGN)\ntime.sleep(60)\n"
    runner = Runner(python, folder, "restart.ipynb", notebook([code(source, "g"), code(stubborn, "s")]))
    try:
        runner.run(0)
        time.sleep(1.5)
        runner.send(op="restart")
        runner.wait(lambda m: m.get("ev") == "status" and m.get("state") == "idle", 60)
        check("restart: the cell's finally ran", os.path.exists(os.path.join(marks, "finally")))
        runner.run(1)
        time.sleep(1.5)
        began = time.time()
        runner.send(op="restart")
        time.sleep(0.3)
        runner.send(op="restart")
        runner.wait(lambda m: m.get("ev") == "status" and m.get("state") == "idle", 60)
        took = time.time() - began
        check("restart twice: the second doesn't wait out the grace", took < 2.0 + 1.5, "%.1f s to idle" % took)
        time.sleep(1)
        _, extra = runner.wait(lambda m: m.get("ev") == "status" and m.get("state") == "starting", 1.5)
        check("restart twice: it restarts once, not twice", extra is None)
    finally:
        runner.stop()


CASES = {"flood": case_flood, "moves": case_moves, "agent": case_agent, "layout": case_layout, "killed": case_killed,
         "odd": case_odd, "gentle": case_gentle}


def main(arguments):
    if not arguments:
        print(__doc__, file=sys.stderr)
        return 64
    python, names = arguments[0], arguments[1:] or list(CASES)
    folder = tempfile.mkdtemp(prefix="tiri-nb-")
    try:
        for name in names:
            print("== " + name, flush=True)
            CASES[name](python, folder)
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    print("%d failed: %s" % (len(failures), ", ".join(failures)) if failures else "all passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
