#!/usr/bin/env python3
"""Runs one notebook's kernel, for Tiri, on a Mac or a server.

The kernel's work outlives whoever asked for it, as an agent's does: this stays running when Tiri
quits or a connection drops, and every result goes straight into the .ipynb, so the file is the
record of what happened. Tiri only needs to be attached to watch it live.

    tiri-kernel.py probe                     can this Python run kernels?
    tiri-kernel.py start <dir> <notebook>    make sure one is running, using <dir> for its socket
    tiri-kernel.py attach <dir>              stdin and stdout become its socket
    tiri-kernel.py alive <dir>               exit 0 if one is running

Over the socket, one JSON object per line. In: {"op": "run", "cells": [index, ...]} or {"op": "run",
"all": true}, {"op": "edit", "action": "source"|"insert"|"delete"|"clear", ...}, "interrupt", "restart",
"stop", "status", {"op": "input", "value"}. Out: {"ev": "status"|"output"|"input"|"problem", ...}.
Edits come through here while one is running, so that the file only has one writer at a time.
jupyter_client comes with ipykernel, so it's only imported to run one.
"""
import json
import os
import queue
import re
import select
import signal
import socket
import sys
import tempfile
import threading
import time
import uuid

SOCKET = "s"
# Long enough to come back from a holiday, short enough that a forgotten kernel doesn't live for ever.
ABANDONED_AFTER = 7 * 24 * 3600
# A training log can run for days. Both ends of it are what's worth keeping.
STREAM_LIMIT = 2_000_000
# Rewriting a big file on every line of output would be most of what the machine does.
SAVE_EVERY = 2.0
PUSH_EVERY = 0.12


def probe():
    from importlib.util import find_spec

    # Finding it, not importing it: this runs for every Python on the machine.
    if find_spec("ipykernel") is None or find_spec("jupyter_client") is None:
        return 1
    import jupyter_client
    from jupyter_client.kernelspec import KernelSpecManager

    try:
        specs = {name: spec["spec"].get("language", "") for name, spec in KernelSpecManager().get_all_specs().items()}
    except Exception:
        specs = {}
    print(json.dumps({"python": sys.executable, "version": "%d.%d.%d" % sys.version_info[:3],
                      "client": jupyter_client.__version__, "kernels": specs}))
    return 0


def connect(directory):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    # Relative, because a socket's whole path has a short limit, and homes can be long.
    os.chdir(directory)
    client.connect(SOCKET)
    return client


def alive(directory):
    try:
        connect(directory).close()
        return True
    except OSError:
        return False


def attach(directory):
    try:
        server = connect(directory)
    except OSError as error:
        print("nothing is running: %s" % error, file=sys.stderr)
        return 3
    stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
    while True:
        ready, _, _ = select.select([server, stdin], [], [])
        if server in ready:
            data = server.recv(1 << 16)
            if not data:
                return 0
            while data:
                data = data[os.write(stdout, data):]
        if stdin in ready:
            data = os.read(stdin, 1 << 16)
            # Whoever was watching has gone. The kernel carries on.
            if not data:
                return 0
            server.sendall(data)


def start(directory, notebook, kernel_name):
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    if alive(directory):
        return 0
    try:
        os.unlink(os.path.join(directory, SOCKET))
    except FileNotFoundError:
        pass
    # Listening before anyone is told it's started, so the first attach can't miss it.
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    os.chdir(directory)
    listener.bind(SOCKET)
    listener.listen(8)
    if os.fork() > 0:
        return 0
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    null = os.open(os.devnull, os.O_RDWR)
    log = os.open("log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(null, 0)
    os.dup2(log, 1)
    os.dup2(log, 2)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    # So that whoever attaches next, knowing only this folder, can find the right Python.
    with open("python", "w") as file:
        file.write(sys.executable)
    try:
        Server(listener, directory, os.path.abspath(notebook), kernel_name).run()
    finally:
        remove(directory)
        os._exit(0)


def remove(directory):
    for name in (SOCKET, "log", "python"):
        try:
            os.unlink(os.path.join(directory, name))
        except OSError:
            pass
    try:
        os.rmdir(directory)
    except OSError:
        pass


def lines(text):
    """Notebooks store text as a list of lines, each keeping its newline."""
    return text.splitlines(True)


def write_atomically(path, data):
    directory = os.path.dirname(path)
    handle, temporary = tempfile.mkstemp(prefix=".tiri-", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            file.write(data)
        try:
            os.chmod(temporary, os.stat(path).st_mode & 0o7777)
        except OSError:
            pass
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


class CellRun:
    """One cell's results as they arrive, in the file's own shape."""

    def __init__(self, cell):
        self.id = cell.get("id")
        self.index = cell.get("index", -1)
        self.outputs = []
        self.count = None
        self.clear_next = False
        self.displays = {}
        self.changed = True
        self.failed = False
        self.missing = False

    def add(self, kind, content):
        self.changed = True
        if kind == "clear_output":
            if content.get("wait"):
                self.clear_next = True
            else:
                self.clear()
            return
        if self.clear_next:
            self.clear()
        if kind == "stream":
            self.add_stream(content.get("name", "stdout"), content.get("text", ""))
        elif kind == "error":
            self.failed = True
            self.outputs.append({"output_type": "error", "ename": content.get("ename", ""), "evalue": content.get("evalue", ""),
                                 "traceback": content.get("traceback", [])})
        elif kind in ("display_data", "update_display_data", "execute_result"):
            self.add_display(kind, content)

    def clear(self):
        self.outputs = []
        self.displays = {}
        self.clear_next = False

    def add_stream(self, name, text):
        last = self.outputs[-1] if self.outputs else None
        if last and last["output_type"] == "stream" and last["name"] == name:
            last["_text"] += text
            if len(last["_text"]) > STREAM_LIMIT:
                kept = last["_text"]
                cut = "\n\n[Tiri kept the start and end of this output: it was too long to save.]\n\n"
                last["_text"] = kept[:STREAM_LIMIT // 4] + cut + kept[-STREAM_LIMIT // 2:]
        else:
            self.outputs.append({"output_type": "stream", "name": name, "_text": text})

    def add_display(self, kind, content):
        data = {type_: lines(value) if type_.startswith("text/") and isinstance(value, str) else value
                for type_, value in content.get("data", {}).items()}
        output = {"output_type": "execute_result" if kind == "execute_result" else "display_data",
                  "data": data, "metadata": content.get("metadata", {})}
        if kind == "execute_result":
            output["execution_count"] = content.get("execution_count")
        display = (content.get("transient") or {}).get("display_id")
        if kind == "update_display_data":
            # Only what it's replacing moves. An update nothing's waiting for is dropped.
            for existing in self.displays.get(display, []):
                existing["data"], existing["metadata"] = output["data"], output["metadata"]
            return
        if display:
            self.displays.setdefault(display, []).append(output)
        self.outputs.append(output)

    def saved_outputs(self):
        result = []
        for output in self.outputs:
            if output["output_type"] == "stream":
                result.append({"output_type": "stream", "name": output["name"], "text": lines(output["_text"])})
            else:
                result.append(output)
        return result


class Server:
    def __init__(self, listener, directory, notebook, kernel_name):
        self.listener = listener
        self.directory = directory
        self.notebook = notebook
        self.kernel_name = kernel_name
        self.clients = []
        self.clients_lock = threading.Lock()
        self.commands = queue.Queue()
        self.pending = []
        self.current = None
        self.message_id = None
        self.manager = None
        self.client = None
        self.state = "starting"
        self.waiting_for_input = None
        self.pushed_at = 0
        self.saved_at = 0
        self.last_client_at = time.time()
        self.saved_outputs_changed = False

    # What's watching

    def accept_forever(self):
        while True:
            connection, _ = self.listener.accept()
            with self.clients_lock:
                self.clients.append(connection)
            self.send_to(connection, self.status())
            # What happened with nobody watching, when something's still going on.
            if self.current:
                self.current.changed = True
            threading.Thread(target=self.read_client, args=(connection,), daemon=True).start()

    def read_client(self, connection):
        buffer = b""
        try:
            while True:
                data = connection.recv(1 << 16)
                if not data:
                    break
                buffer += data
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        self.commands.put(json.loads(line))
                    except ValueError:
                        pass
        except OSError:
            pass
        with self.clients_lock:
            if connection in self.clients:
                self.clients.remove(connection)
        self.last_client_at = time.time()
        connection.close()

    def send_to(self, connection, message):
        try:
            connection.sendall(json.dumps(message, ensure_ascii=False).encode() + b"\n")
            return True
        except OSError:
            return False

    def broadcast(self, message):
        with self.clients_lock:
            clients = list(self.clients)
        for connection in clients:
            if not self.send_to(connection, message):
                with self.clients_lock:
                    if connection in self.clients:
                        self.clients.remove(connection)

    def status(self):
        return {"ev": "status", "state": self.state, "running": self.current.index if self.current else None,
                "queued": [cell.get("index") for cell in self.pending], "python": sys.executable,
                "version": "%d.%d.%d" % sys.version_info[:3], "kernel": self.kernel_name or "python3",
                "input": self.waiting_for_input}

    def set_state(self, state=None):
        if state:
            self.state = state
        self.broadcast(self.status())

    def problem(self, message):
        self.broadcast({"ev": "problem", "message": message})

    # The kernel

    def start_kernel(self):
        from jupyter_client.manager import KernelManager

        self.set_state("starting")
        self.manager = KernelManager(kernel_name=self.kernel_name or "python3")
        self.manager.start_kernel(cwd=os.path.dirname(self.notebook))
        self.client = self.manager.client()
        self.client.start_channels()
        self.client.wait_for_ready(timeout=120)
        self.note_language()
        self.set_state("idle")

    def note_language(self):
        """A notebook with nothing in it doesn't say what it's in yet, and readers go by this."""
        try:
            message_id = self.client.kernel_info()
            reply = self.client.get_shell_msg(timeout=10)
            if reply["parent_header"].get("msg_id") != message_id:
                return
            info = reply["content"].get("language_info")
            spec = self.manager.kernel_spec

            def change(notebook):
                metadata = notebook.setdefault("metadata", {})
                changed = False
                if info and "language_info" not in metadata:
                    metadata["language_info"] = {key: info[key] for key in ("name", "version", "file_extension", "mimetype") if key in info}
                    changed = True
                if spec and "kernelspec" not in metadata:
                    metadata["kernelspec"] = {"name": self.manager.kernel_name, "display_name": spec.display_name, "language": spec.language}
                    changed = True
                return changed

            self.change_notebook(change)
        except Exception as error:
            print("couldn't read the kernel's language: %s" % error, flush=True)

    def kernel_alive(self):
        try:
            return self.manager is not None and self.manager.is_alive()
        except Exception:
            return False

    def begin_next(self):
        if self.current or not self.pending or self.state == "dead":
            return
        if not self.kernel_alive():
            try:
                self.start_kernel()
            except Exception as error:
                self.pending = []
                self.set_state("dead")
                self.problem("The kernel didn't start: %s" % error)
                return
        queued = self.pending.pop(0)
        # From the file as it is now: an agent may have changed the cell since it was queued.
        try:
            with open(self.notebook, encoding="utf-8") as file:
                cells = json.load(file).get("cells", [])
        except (OSError, ValueError) as error:
            self.problem("Couldn't read this notebook: %s" % error)
            self.pending = []
            self.set_state()
            return
        run = CellRun(queued)
        cell = self.find_cell(cells, run)
        if cell is None:
            self.problem("That cell isn't in the notebook any more, so it didn't run.")
            self.set_state()
            return
        run.index = cells.index(cell)
        source = cell.get("source", "")
        self.current = run
        self.message_id = self.client.execute("".join(source) if isinstance(source, list) else source,
                                              store_history=True, allow_stdin=True, stop_on_error=False)
        self.save_current(running=True)
        self.push(force=True)
        self.set_state("busy")

    def finish_current(self):
        run = self.current
        self.current = None
        self.message_id = None
        self.waiting_for_input = None
        self.save_run(run)
        self.push_run(run)
        # Like Jupyter, a cell that failed stops the ones queued after it.
        if run.failed:
            self.pending = []
        self.set_state("busy" if self.pending else "idle")

    def read_kernel(self):
        """Everything waiting from the kernel. True if there was anything."""
        got = False
        try:
            while self.client.iopub_channel.msg_ready():
                self.handle_iopub(self.client.get_iopub_msg(timeout=0))
                got = True
                if not self.current:
                    break
            while self.client.stdin_channel.msg_ready():
                self.handle_stdin(self.client.get_stdin_msg(timeout=0))
                got = True
        except queue.Empty:
            pass
        return got

    def handle_iopub(self, message):
        if not self.current or message["parent_header"].get("msg_id") != self.message_id:
            return
        kind, content = message["msg_type"], message["content"]
        if kind == "execute_input":
            self.current.count = content.get("execution_count")
            self.current.changed = True
        elif kind == "status":
            if content.get("execution_state") == "idle":
                self.finish_current()
        else:
            if kind == "execute_result" and content.get("execution_count"):
                self.current.count = content["execution_count"]
            self.current.add(kind, content)

    def handle_stdin(self, message):
        if message["msg_type"] != "input_request":
            return
        self.waiting_for_input = {"prompt": message["content"].get("prompt", ""), "password": bool(message["content"].get("password"))}
        self.broadcast({"ev": "input", **self.waiting_for_input})

    def check_kernel(self):
        if not self.manager or self.kernel_alive():
            return
        self.manager = None
        run = self.current
        self.current = None
        self.pending = []
        self.waiting_for_input = None
        if run:
            run.add("error", {"ename": "Kernel stopped", "evalue": "The kernel stopped while this cell was running.", "traceback": []})
            self.save_run(run)
            self.push_run(run)
        self.set_state("stopped")
        self.problem("The kernel stopped. Running a cell starts it again.")

    # The file

    def change_notebook(self, change):
        with open(self.notebook, encoding="utf-8") as file:
            text = file.read()
        notebook = json.loads(text)
        if not change(notebook):
            return
        # In the file's own layout, so that a diff shows what changed and not how it's written.
        found = re.search(r'^\{\s*\n( +)"', text)
        indent = len(found.group(1)) if found else 1
        result = json.dumps(notebook, indent=indent, ensure_ascii=False)
        write_atomically(self.notebook, result + ("\n" if text.endswith("\n") else ""))

    def find_cell(self, cells, run):
        """Someone may have moved things around since this cell started."""
        if run.id:
            for cell in cells:
                if cell.get("id") == run.id:
                    return cell
        if 0 <= run.index < len(cells):
            cell = cells[run.index]
            if cell.get("cell_type") == "code" and not cell.get("id"):
                return cell
        return None

    def save_run(self, run, running=False):
        def change(notebook):
            cell = self.find_cell(notebook.get("cells", []), run)
            if cell is None:
                if not run.missing:
                    run.missing = True
                    self.problem("That cell isn't in the notebook any more, so its output wasn't saved.")
                return False
            cell["outputs"] = run.saved_outputs()
            cell["execution_count"] = None if running else run.count
            return True

        try:
            self.change_notebook(change)
            self.saved_at = time.time()
            self.saved_outputs_changed = False
        except (OSError, ValueError) as error:
            self.problem("Couldn't save this cell's output: %s" % error)

    def save_current(self, running=False):
        if self.current:
            self.save_run(self.current, running=running)

    def push_run(self, run, running=False):
        self.broadcast({"ev": "output", "index": run.index, "count": None if running else run.count, "running": running,
                        "outputs": run.saved_outputs()})
        run.changed = False
        self.pushed_at = time.time()

    def push(self, force=False):
        run = self.current
        if not run or not (run.changed or force):
            return
        self.saved_outputs_changed = True
        if force or time.time() - self.pushed_at >= PUSH_EVERY:
            self.push_run(run, running=True)
        if time.time() - self.saved_at >= SAVE_EVERY and self.saved_outputs_changed:
            self.save_current(running=True)

    # What's asked for

    def handle_command(self, command):
        operation = command.get("op")
        if operation == "run":
            if self.state == "dead":
                self.state = "stopped"
            self.queue_cells(command)
            self.set_state()
        elif operation == "edit":
            self.edit(command)
        elif operation == "status":
            self.set_state()
        elif operation == "interrupt":
            self.pending = []
            if self.kernel_alive():
                self.manager.interrupt_kernel()
            self.set_state()
        elif operation == "input":
            if self.waiting_for_input:
                self.waiting_for_input = None
                self.client.input(command.get("value", ""))
        elif operation == "restart":
            self.restart()
        elif operation == "stop":
            return False
        return True

    def queue_cells(self, command):
        try:
            with open(self.notebook, encoding="utf-8") as file:
                cells = json.load(file).get("cells", [])
        except (OSError, ValueError) as error:
            self.problem("Couldn't read this notebook: %s" % error)
            return
        wanted = range(len(cells)) if command.get("all") else command.get("cells", [])
        for index in wanted:
            if isinstance(index, int) and 0 <= index < len(cells) and cells[index].get("cell_type") == "code":
                self.pending.append({"id": cells[index].get("id"), "index": index})

    def edit(self, command):
        action = command.get("action")

        def change(notebook):
            cells = notebook.setdefault("cells", [])
            index = command.get("index")
            if action == "insert":
                after = command.get("after", -1)
                if not isinstance(after, int) or not -1 <= after < len(cells):
                    return False
                cell = {"cell_type": command.get("kind", "code")}
                if cell["cell_type"] == "code":
                    cell["execution_count"] = None
                if (notebook.get("nbformat", 4), notebook.get("nbformat_minor", 0)) >= (4, 5):
                    cell["id"] = uuid.uuid4().hex[:8]
                cell["metadata"] = {}
                if cell["cell_type"] == "code":
                    cell["outputs"] = []
                cell["source"] = []
                cells.insert(after + 1, cell)
                return True
            if action == "clear" and index is None:
                for cell in cells:
                    if cell.get("cell_type") == "code":
                        cell["outputs"], cell["execution_count"] = [], None
                return True
            if not isinstance(index, int) or not 0 <= index < len(cells):
                self.problem("That cell isn't in the notebook any more.")
                return False
            cell = cells[index]
            if action == "source":
                source = cell.get("source", "")
                current = "".join(source) if isinstance(source, list) else source
                expected = command.get("expected")
                if expected is not None and current != expected:
                    self.problem("Something else changed this cell while you were editing it, so your edit wasn't saved.")
                    return False
                cell["source"] = lines(command.get("source", ""))
            elif action == "delete":
                del cells[index]
            elif action == "clear":
                cell["outputs"], cell["execution_count"] = [], None
            else:
                return False
            return True

        try:
            self.change_notebook(change)
        except (OSError, ValueError) as error:
            self.problem("Couldn't change this notebook: %s" % error)

    def restart(self):
        run = self.current
        self.current = None
        self.message_id = None
        self.pending = []
        self.waiting_for_input = None
        if run:
            self.save_run(run)
            self.push_run(run)
        if self.manager is None:
            self.set_state("stopped")
            return
        self.set_state("starting")
        try:
            self.manager.restart_kernel(now=True)
            self.client.wait_for_ready(timeout=120)
            self.set_state("idle")
        except Exception as error:
            self.set_state("dead")
            self.problem("The kernel didn't restart: %s" % error)

    def run(self):
        threading.Thread(target=self.accept_forever, daemon=True).start()
        self.state = "stopped"
        try:
            self.start_kernel()
        except Exception as error:
            print("start failed: %s" % error, flush=True)
            self.state = "dead"
            self.problem("The kernel didn't start: %s" % error)
        while True:
            busy = False
            try:
                while True:
                    if not self.handle_command(self.commands.get_nowait()):
                        self.shut_down()
                        return
                    busy = True
            except queue.Empty:
                pass
            self.begin_next()
            if self.client is not None and self.manager is not None:
                try:
                    busy = self.read_kernel() or busy
                except Exception as error:
                    print("reading the kernel: %s" % error, flush=True)
                self.push()
            self.check_kernel()
            if not busy:
                try:
                    if not self.handle_command(self.commands.get(timeout=0.03 if self.current else 0.25)):
                        self.shut_down()
                        return
                except queue.Empty:
                    pass
            if not self.current and not self.pending and not self.clients and time.time() - self.last_client_at > ABANDONED_AFTER:
                self.shut_down()
                return

    def shut_down(self):
        run = self.current
        self.current = None
        if run:
            self.save_run(run)
        self.state = "stopped"
        self.broadcast(self.status())
        if self.manager:
            try:
                self.client.stop_channels()
                self.manager.shutdown_kernel(now=True)
            except Exception as error:
                print("shutting down: %s" % error, flush=True)


def main(arguments):
    command = arguments[0] if arguments else ""
    if command == "probe":
        return probe()
    if command == "alive" and len(arguments) == 2:
        return 0 if alive(arguments[1]) else 1
    if command == "attach" and len(arguments) == 2:
        return attach(arguments[1])
    if command == "start" and len(arguments) >= 3:
        return start(arguments[1], arguments[2], arguments[3] if len(arguments) > 3 else "")
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
