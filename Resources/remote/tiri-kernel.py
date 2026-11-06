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
An output is one run's, by "run", and says what changed: its outputs from position "from" on are "outputs".
A problem's "text" is the English with %@ for each of "args", so that the app can say it in its own words.
Edits come through here while one is running, so that the file only has one writer at a time.
jupyter_client comes with ipykernel, so it's only imported to run one.
"""
import hashlib
import itertools
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
import traceback
import uuid

SOCKET = "s"
# Long enough to come back from a holiday, short enough that a forgotten kernel doesn't live for ever.
ABANDONED_AFTER = 7 * 24 * 3600
# A training log can run for days. Both ends of it are what's worth keeping.
STREAM_LIMIT = 2_000_000
# The same goes for a cell's outputs: a figure every epoch would make a file of gigabytes. Its first few and
# its latest are kept, as Jupyter's own viewers only show so many.
KEEP_FIRST = 20
KEEP_LAST = 100
OUTPUT_LIMIT = 16_000_000
# Rewriting a big file on every line of output would be most of what the machine does.
SAVE_EVERY = 2.0
PUSH_EVERY = 0.12
# Bytes a second worth sending to a viewer. A big push waits longer for the next.
PUSH_RATE = 8_000_000
# How long a kernel has to run its own cleanup, finally blocks and atexit, when it's stopped or restarted.
GRACE = 2.0
# What the kernel itself printed, outside any cell, for when it dies.
KERNEL_OUTPUT_KEPT = 65536
# Besides text/*, what nbformat stores as lines.
SPLIT_TYPES = ("application/javascript", "image/svg+xml")


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
    # Only this runner's own notes. The kernel's output has a pipe of its own.
    log = os.open("log", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(null, 0)
    os.dup2(log, 1)
    os.dup2(log, 2)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    # So that whoever attaches next, knowing only this folder, can find the right Python.
    with open("python", "w") as file:
        file.write(sys.executable)
    own = Files(directory)
    try:
        Server(listener, directory, os.path.abspath(notebook), kernel_name, own).run()
    finally:
        own.remove()
        try:
            os.rmdir(directory)
        except OSError:
            pass
        os._exit(0)


class Files:
    """This runner's socket and notes. A new one may start in the same folder while this one is still stopping
    its kernel, and what it made isn't this one's to remove."""

    def __init__(self, directory):
        self.directory = directory
        self.inodes = {}
        for name in (SOCKET, "log", "python"):
            try:
                self.inodes[name] = os.stat(os.path.join(directory, name)).st_ino
            except OSError:
                pass

    def remove(self):
        for name, inode in list(self.inodes.items()):
            path = os.path.join(self.directory, name)
            try:
                if os.stat(path).st_ino == inode:
                    os.unlink(path)
            except OSError:
                pass
        self.inodes = {}


def lines(text):
    """Notebooks store text as a list of lines, each keeping its newline."""
    return text.splitlines(True)


def say(text, *args):
    """Words the app shows. `text` is how it looks them up, so it's always one whole sentence, with %@ for each arg."""
    english = text
    for arg in args:
        english = english.replace("%@", str(arg), 1)
    return {"message": english, "text": text, "args": [str(arg) for arg in args]}


class Refused(Exception):
    """A change that shouldn't happen, with what to tell the person, as for say()."""


class Missing(Exception):
    """The cell isn't in the file any more."""


class Busy(OSError):
    """The file kept changing under a save."""


def write_atomically(path, data, unchanged=None):
    """False, and nothing written, if `unchanged` says someone else wrote the file meanwhile."""
    directory = os.path.dirname(path)
    handle, temporary = tempfile.mkstemp(prefix=".tiri-", dir=directory)
    try:
        with os.fdopen(handle, "wb") as file:
            file.write(data)
        try:
            os.chmod(temporary, os.stat(path).st_mode & 0o7777)
        except OSError:
            pass
        if unchanged is not None and not unchanged():
            os.unlink(temporary)
            return False
        os.replace(temporary, path)
        return True
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


# The notebook's cells. Anything can be in a file an agent wrote, and what isn't an object isn't a cell to run.

def is_code(cell):
    return isinstance(cell, dict) and cell.get("cell_type") == "code"


def source_of(cell):
    source = cell.get("source", "") if isinstance(cell, dict) else ""
    if isinstance(source, list):
        return "".join(part for part in source if isinstance(part, str))
    return source if isinstance(source, str) else ""


def cells_of(notebook):
    cells = notebook.get("cells") if isinstance(notebook, dict) else None
    if not isinstance(cells, list):
        raise ValueError("it has no cells")
    return cells


def locate(cells, wanted, index, source, edited=False):
    """Where a cell is now. By its id when it has one. Without, a position only counts while it holds the same
    code, or else the one cell that does. `edited` also takes a changed cell in the same place, when nothing has
    been added or taken away since."""
    if wanted.id:
        matches = [position for position, cell in enumerate(cells) if is_code(cell) and cell.get("id") == wanted.id]
        if len(matches) <= 1:
            return matches[0] if matches else None
        # The same id twice, from a copied cell: the one asked for is the one in its place, or with its code.
        if index in matches:
            return index
        return next((position for position in matches if source_of(cells[position]) == source), matches[0])
    if index is not None and 0 <= index < len(cells) and is_code(cells[index]) and source_of(cells[index]) == source:
        return index
    same = [position for position, cell in enumerate(cells) if is_code(cell) and source_of(cell) == source]
    if len(same) == 1:
        return same[0]
    if edited and index is not None and 0 <= index < len(cells) and is_code(cells[index]) and len(cells) == wanted.cell_count:
        return index
    return None


def repair_ids(cells):
    """Like nbformat's own repair: a later cell with an id that's already taken gets a new one."""
    seen = set()
    for cell in cells:
        if not isinstance(cell, dict) or not isinstance(cell.get("id"), str):
            continue
        while cell["id"] in seen:
            cell["id"] = uuid.uuid4().hex[:8]
        seen.add(cell["id"])


# Writing the file. Only what changed is written, in the file's own layout, so that a diff shows what
# changed and not how it's written: its indent, its line endings, and the bytes of every other cell.

_STRING = re.compile(r'"[^"\\]*(?:\\.[^"\\]*)*"', re.S)
_SPACE = re.compile(r'[ \t\r\n]*')
_STRUCTURE = re.compile(r'["\[\]{}]')
_SCALAR = re.compile(r'[^,\]}\s]+')
_ESCAPED = re.compile(r'\\u(?:00[89a-fA-F]|0[1-9a-fA-F]|[1-9a-fA-F])')


def _space(text, position):
    return _SPACE.match(text, position).end()


def _value_end(text, position):
    first = text[position]
    if first == '"':
        found = _STRING.match(text, position)
        if not found:
            raise ValueError("unterminated string")
        return found.end()
    if first in "[{":
        depth = 0
        while True:
            found = _STRUCTURE.search(text, position)
            if not found:
                raise ValueError("unterminated value")
            if found.group() == '"':
                position = _value_end(text, found.start())
                continue
            depth += 1 if found.group() in "[{" else -1
            position = found.end()
            if depth == 0:
                return position
    found = _SCALAR.match(text, position)
    if not found:
        raise ValueError("no value")
    return found.end()


def _members(text, start):
    """(name, key, value start, value end) for each member of the object at `start`."""
    result = []
    position = _space(text, start + 1)
    while text[position] != "}":
        key_end = _value_end(text, position)
        name = json.loads(text[position:key_end])
        colon = _space(text, key_end)
        if text[colon] != ":":
            raise ValueError("no colon")
        value = _space(text, colon + 1)
        end = _value_end(text, value)
        result.append((name, position, value, end))
        position = _space(text, end)
        if text[position] == ",":
            position = _space(text, position + 1)
    return result


def _elements(text, start):
    result = []
    position = _space(text, start + 1)
    while text[position] != "]":
        end = _value_end(text, position)
        result.append((position, end))
        position = _space(text, end)
        if text[position] == ",":
            position = _space(text, position + 1)
    return result


def _indent_at(text, position):
    """The white space a line starts with, when `position` begins its content. None in the middle of a line."""
    start = position
    while start > 0 and text[start - 1] in " \t":
        start -= 1
    return text[start:position] if start == 0 or text[start - 1] == "\n" else None


def _same(old, new):
    return type(old) is type(new) and old == new


class Layout:
    """How a file is written, read from the file."""

    def __init__(self, text):
        first_line = text.find("\n")
        self.newline = "\r\n" if first_line > 0 and text[first_line - 1] == "\r" else "\n"
        self.ensure_ascii = not re.search(r'[^\x00-\x7f]', text) and bool(_ESCAPED.search(text))
        self.unit = None
        self.colon, self.comma = ": ", ","
        root = _space(text, 0)
        if text[root:root + 1] == "{":
            members = _members(text, root)
            if members:
                name, key, value, end = members[0]
                self.unit = _indent_at(text, key) or None
                between = text[_value_end(text, key):value]
                self.colon = ": " if between.endswith(" ") else ":"
                after = _space(text, end)
                if self.unit is None and text[after:after + 2] == ", ":
                    self.comma = ", "

    def encode(self, value, indent):
        if self.unit is None or indent is None:
            return json.dumps(value, ensure_ascii=self.ensure_ascii, sort_keys=True, separators=(self.comma, self.colon))
        return json.dumps(value, indent=self.unit, ensure_ascii=self.ensure_ascii, sort_keys=True).replace("\n", self.newline + indent)

    def whole(self, value, text):
        """The entire file, when only rewriting it all will do."""
        trailing = text[len(text.rstrip()):]
        if self.unit is None:
            return json.dumps(value, ensure_ascii=self.ensure_ascii, separators=(self.comma, self.colon)) + trailing
        return json.dumps(value, indent=self.unit, ensure_ascii=self.ensure_ascii).replace("\n", self.newline) + trailing

    def between(self, indent):
        return "," + self.newline + indent if indent is not None and self.unit is not None else self.comma

    def member(self, name, value, indent):
        return json.dumps(name, ensure_ascii=self.ensure_ascii) + self.colon + self.encode(value, indent)

    def diff(self, text, old, new, start, end, indent, edits):
        """Edits that make text[start:end], which holds `old`, hold `new`."""
        if _same(old, new):
            return
        if isinstance(old, dict) and isinstance(new, dict) and old:
            members = _members(text, start)
            names = [member[0] for member in members]
            if len(set(names)) == len(names) == len(old) and all(name in new for name in names):
                for name, key, value, value_end in members:
                    self.diff(text, old[name], new[name], value, value_end, _indent_at(text, key), edits)
                added = [name for name in new if name not in old]
                if added:
                    self.add_members(text, members, new, added, edits)
                return
        elif isinstance(old, list) and isinstance(new, list) and old:
            elements = _elements(text, start)
            if len(elements) == len(old):
                if len(new) == len(old):
                    for (value, value_end), before, after in zip(elements, old, new):
                        self.diff(text, before, after, value, value_end, _indent_at(text, value), edits)
                    return
                if self.splice_list(text, elements, old, new, edits):
                    return
        edits.append((start, end, self.encode(new, indent)))

    def add_members(self, text, members, new, added, edits):
        names = [member[0] for member in members]
        in_order = names == sorted(names)
        for name in sorted(added) if in_order else added:
            following = next((member for member in members if member[0] > name), None) if in_order else None
            if following:
                indent = _indent_at(text, following[1])
                edits.append((following[1], following[1], self.member(name, new[name], indent) + self.between(indent)))
            else:
                indent = _indent_at(text, members[-1][1])
                edits.append((members[-1][3], members[-1][3], self.between(indent) + self.member(name, new[name], indent)))

    def splice_list(self, text, elements, old, new, edits):
        """One element added or taken away, which is what adding or deleting a cell does."""
        if len(new) == len(old) + 1:
            at = next((index for index, (before, after) in enumerate(zip(old, new)) if not _same(before, after)), len(old))
            if old[at:] != new[at + 1:]:
                return False
            if at < len(old):
                place = elements[at][0]
                indent = _indent_at(text, place)
                edits.append((place, place, self.encode(new[at], indent) + self.between(indent)))
            else:
                place = elements[-1]
                indent = _indent_at(text, place[0])
                edits.append((place[1], place[1], self.between(indent) + self.encode(new[at], indent)))
            return True
        if len(new) == len(old) - 1 and new:
            at = next((index for index, (before, after) in enumerate(zip(old, new)) if not _same(before, after)), len(new))
            if old[at + 1:] != new[at:]:
                return False
            if at + 1 < len(old):
                edits.append((elements[at][0], elements[at + 1][0], ""))
            else:
                edits.append((elements[at - 1][1], elements[at][1], ""))
            return True
        return False


def rewrite(text, old, new):
    """`text`, which holds `old`, changed to hold `new`, touching only what differs."""
    layout = Layout(text)
    try:
        edits = []
        root = _space(text, 0)
        layout.diff(text, old, new, root, _value_end(text, root), _indent_at(text, root) or "", edits)
        pieces, cursor = [], 0
        for start, end, replacement in sorted(edits, key=lambda edit: (edit[0], edit[1])):
            if start < cursor:
                raise ValueError("overlapping edits")
            pieces += [text[cursor:start], replacement]
            cursor = end
        result = "".join(pieces) + text[cursor:]
        if json.loads(result) == new:
            return result
    except (ValueError, IndexError, TypeError, RecursionError):
        pass
    return layout.whole(new, text)


def output_size(output):
    kind = output.get("output_type")
    if kind == "stream":
        return len(output.get("_text", ""))
    if kind == "error":
        return len(output.get("evalue", "")) + sum(len(line) for line in output.get("traceback", []) if isinstance(line, str))
    size = 0
    for value in (output.get("data") or {}).values():
        if isinstance(value, str):
            size += len(value)
        elif isinstance(value, list) and all(isinstance(line, str) for line in value):
            size += sum(len(line) for line in value)
        else:
            size += len(json.dumps(value))
    return size


class CellRun:
    """One cell's results as they arrive, in the file's own shape."""

    serials = itertools.count(1)

    def __init__(self, wanted):
        self.id = wanted.id
        self.index = wanted.index
        self.source = wanted.source
        self.cell_count = wanted.cell_count
        self.serial = next(CellRun.serials)
        self.count = None
        self.head, self.tail = [], []
        self.head_bytes = self.tail_bytes = 0
        self.head_full = False
        self.left_out = 0
        self.clear_next = False
        self.displays = {}
        # The first output that differs from what viewers were last sent, or None.
        self.changed_from = 0
        self.unsaved = True
        self.failed = False
        self.missing = False

    def changed(self, position):
        self.changed_from = position if self.changed_from is None else min(self.changed_from, position)
        self.unsaved = True

    def length(self):
        return len(self.head) + (1 if self.left_out else 0) + len(self.tail)

    def last(self):
        return self.tail[-1] if self.tail else (self.head[-1] if self.head else None)

    def position(self, output):
        for position, existing in enumerate(self.head):
            if existing is output:
                return position
        base = len(self.head) + (1 if self.left_out else 0)
        for position, existing in enumerate(self.tail):
            if existing is output:
                return base + position
        return None

    def bytes_from(self, position):
        outputs = self.head + ([None] if self.left_out else []) + self.tail
        return sum(output["_size"] for output in outputs[position:] if output is not None)

    def add(self, kind, content):
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
            self.append({"ename": content.get("ename", ""), "evalue": content.get("evalue", ""), "output_type": "error",
                         "traceback": content.get("traceback", [])})
        elif kind in ("display_data", "update_display_data", "execute_result"):
            self.add_display(kind, content)

    def clear(self):
        self.head, self.tail = [], []
        self.head_bytes = self.tail_bytes = 0
        self.head_full = False
        self.left_out = 0
        self.displays = {}
        self.clear_next = False
        self.changed(0)

    def resized(self, output, before):
        output.pop("_saved", None)
        if self.tail and any(existing is output for existing in self.tail):
            self.tail_bytes += output["_size"] - before
        else:
            self.head_bytes += output["_size"] - before
        self.changed(self.position(output))
        self.trim()

    def append(self, output):
        output["_size"] = output_size(output)
        if not self.head_full and len(self.head) < KEEP_FIRST and self.head_bytes + output["_size"] <= OUTPUT_LIMIT // 4:
            self.head.append(output)
            self.head_bytes += output["_size"]
        else:
            self.head_full = True
            self.tail.append(output)
            self.tail_bytes += output["_size"]
        self.changed(self.length() - 1)
        self.trim()

    def trim(self):
        """Down to the latest, well under the limits, so that this happens now and then, not on every output."""
        if len(self.tail) <= 1 or (len(self.tail) <= 2 * KEEP_LAST and self.head_bytes + self.tail_bytes <= OUTPUT_LIMIT):
            return
        room = OUTPUT_LIMIT // 2 - self.head_bytes
        dropped, size = 0, self.tail_bytes
        while dropped < len(self.tail) - 1 and (len(self.tail) - dropped > KEEP_LAST or size > room):
            size -= self.tail[dropped]["_size"]
            dropped += 1
        gone = {id(output) for output in self.tail[:dropped]}
        del self.tail[:dropped]
        self.tail_bytes = size
        self.left_out += dropped
        self.displays = {key: kept for key, outputs in self.displays.items()
                         if (kept := [output for output in outputs if id(output) not in gone])}
        self.changed(len(self.head))

    def add_stream(self, name, text):
        last = self.last()
        if last and last["output_type"] == "stream" and last["name"] == name:
            before = last["_size"]
            last["_text"] += text
            if len(last["_text"]) > STREAM_LIMIT:
                kept = last["_text"]
                cut = "\n\n[Tiri kept the start and end of this output: it was too long to save.]\n\n"
                last["_text"] = kept[:STREAM_LIMIT // 4] + cut + kept[-STREAM_LIMIT // 2:]
            last["_size"] = len(last["_text"])
            self.resized(last, before)
        else:
            self.append({"name": name, "output_type": "stream", "_text": text})

    def add_display(self, kind, content):
        data = {type_: lines(value) if (type_.startswith("text/") or type_ in SPLIT_TYPES) and isinstance(value, str) else value
                for type_, value in content.get("data", {}).items()}
        output = {"data": data, "metadata": content.get("metadata", {}),
                  "output_type": "execute_result" if kind == "execute_result" else "display_data"}
        if kind == "execute_result":
            output["execution_count"] = content.get("execution_count")
        display = (content.get("transient") or {}).get("display_id")
        if kind == "update_display_data":
            # Only what it's replacing moves. An update nothing's waiting for is dropped.
            for existing in self.displays.get(display, []):
                before = existing["_size"]
                existing["data"], existing["metadata"] = output["data"], output["metadata"]
                existing["_size"] = output_size(existing)
                self.resized(existing, before)
            return
        if display:
            self.displays.setdefault(display, []).append(output)
        self.append(output)

    @staticmethod
    def saved(output):
        kept = output.get("_saved")
        if kept is None:
            if output["output_type"] == "stream":
                kept = {"name": output["name"], "output_type": "stream", "text": lines(output["_text"])}
            else:
                kept = {key: value for key, value in output.items() if not key.startswith("_")}
            output["_saved"] = kept
        return kept

    def saved_outputs(self):
        result = [self.saved(output) for output in self.head]
        if self.left_out:
            # Other viewers show the words. Tiri's own reads the number, to say it in the person's language.
            result.append({"data": {"text/plain": ["[Tiri left out %d outputs here: there were too many to keep.]" % self.left_out]},
                           "metadata": {"tiri": {"left_out": self.left_out}}, "output_type": "display_data"})
        return result + [self.saved(output) for output in self.tail]


class Wanted:
    """A cell that's been asked for: where it was, and what it held then."""

    def __init__(self, cells, index):
        self.index = index
        self.id = cells[index].get("id") if isinstance(cells[index].get("id"), str) else None
        self.source = source_of(cells[index])
        self.cell_count = len(cells)


class Asked:
    """A cell as the app saw it when it was asked to run, for finding it in the file as it is now."""

    def __init__(self, id, source, cell_count):
        self.id = id
        self.source = source
        self.cell_count = cell_count if isinstance(cell_count, int) else -1


class Viewer:
    """An app that's attached. What it's sent goes from a thread of its own, holding only the latest of each
    thing, so that a slow viewer can never hold up the kernel, and its messages can't pile up."""

    def __init__(self, connection):
        self.connection = connection
        self.condition = threading.Condition()
        self.items = []
        self.open = True
        self.thread = threading.Thread(target=self.send_forever, daemon=True)
        self.thread.start()

    def put(self, message):
        with self.condition:
            if message.get("ev") == "status":
                self.items = [item for item in self.items if item[0] != "status"]
            self.items.append(["status" if message.get("ev") == "status" else "event", None, message, None, 0])
            self.condition.notify()

    def put_output(self, key, message, outputs, start):
        with self.condition:
            for item in self.items:
                if item[0] == "output" and item[1] == key:
                    item[2], item[3], item[4] = message, outputs, min(item[4], start)
                    break
            else:
                self.items.append(["output", key, message, outputs, start])
            self.condition.notify()

    def close(self):
        with self.condition:
            self.open = False
            self.condition.notify()

    def send_forever(self):
        try:
            while True:
                with self.condition:
                    while not self.items and self.open:
                        self.condition.wait()
                    if not self.items:
                        break
                    kind, _, message, outputs, start = self.items.pop(0)
                if kind == "output":
                    message = dict(message, outputs=outputs[start:], **{"from": start})
                self.connection.sendall(json.dumps(message, ensure_ascii=False).encode() + b"\n")
        except (OSError, ValueError, TypeError):
            pass
        self.open = False
        try:
            self.connection.close()
        except OSError:
            pass


class Server:
    def __init__(self, listener, directory, notebook, kernel_name, files=None):
        self.listener = listener
        self.directory = directory
        self.notebook = notebook
        self.kernel_name = kernel_name
        self.files = files
        self.viewers = []
        self.viewers_lock = threading.Lock()
        self.commands = queue.Queue()
        self.pending = []
        self.current = None
        self.message_id = None
        self.manager = None
        self.client = None
        self.state = "starting"
        self.waiting_for_input = None
        self.pushed_at = 0
        self.next_push = 0
        self.saved_at = 0
        self.save_every = SAVE_EVERY
        self.checked_at = 0
        self.last_client_at = time.time()
        # The file as last read or written here: anything else means someone else wrote it.
        self.known = None
        self.told = {}
        # Restarts and stops asked for, and done: a second one while the first waits for the kernel hurries it.
        self.asks_lock = threading.Lock()
        self.asked = {"restart": 0, "stop": 0}
        self.handled = {"restart": 0, "stop": 0}
        self.skip_restarts = 0
        self.kernel_pipe = None
        self.kernel_process = None
        self.kernel_output = bytearray()
        self.kernel_output_total = 0
        self.kernel_output_from = 0
        self.kernel_output_lock = threading.Lock()

    # What's watching

    def accept_forever(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            viewer = Viewer(connection)
            with self.viewers_lock:
                self.viewers.append(viewer)
            # Told what's going on by the loop, which owns it, so that what it's told adds up.
            self.commands.put({"op": "hello", "viewer": viewer})
            threading.Thread(target=self.read_client, args=(viewer,), daemon=True).start()

    def read_client(self, viewer):
        buffer = b""
        try:
            while True:
                data = viewer.connection.recv(1 << 16)
                if not data:
                    break
                buffer += data
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        command = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(command, dict):
                        continue
                    command.pop("viewer", None)
                    if command.get("op") in self.asked:
                        with self.asks_lock:
                            self.asked[command["op"]] += 1
                    self.commands.put(command)
        except OSError:
            pass
        with self.viewers_lock:
            if viewer in self.viewers:
                self.viewers.remove(viewer)
        self.last_client_at = time.time()
        viewer.close()

    def all_viewers(self):
        with self.viewers_lock:
            self.viewers = [viewer for viewer in self.viewers if viewer.open]
            return list(self.viewers)

    def broadcast(self, message):
        for viewer in self.all_viewers():
            viewer.put(message)

    def status(self):
        running = self.current.index if self.current and self.current.index >= 0 else None
        return {"ev": "status", "state": self.state, "running": running,
                "queued": [wanted.index for wanted in self.pending if wanted.index >= 0], "python": sys.executable,
                "version": "%d.%d.%d" % sys.version_info[:3], "kernel": self.kernel_name or "python3",
                "input": self.waiting_for_input}

    def set_state(self, state=None):
        if state:
            self.state = state
        self.broadcast(self.status())

    def problem(self, text, *args, detail=None, hint=None):
        words = say(text, *args)
        # The same thing again and again, from a save that keeps failing, is said once in a while.
        now = time.time()
        if now - self.told.get(words["message"], 0) < 20:
            return
        self.told[words["message"]] = now
        self.broadcast(dict(words, ev="problem", detail=detail, hint=hint))

    # The kernel

    def start_kernel(self):
        from jupyter_client.manager import KernelManager

        self.set_state("starting")
        if self.kernel_pipe is None:
            reader, self.kernel_pipe = os.pipe()
            threading.Thread(target=self.keep_kernel_output, args=(reader,), daemon=True).start()
        self.manager = KernelManager(kernel_name=self.kernel_name or "python3")
        self.mark_kernel_output()
        # Its own pipe, read all the time, and only the end kept: a kernel can print for a week.
        self.manager.start_kernel(cwd=os.path.dirname(self.notebook), stdout=self.kernel_pipe, stderr=self.kernel_pipe)
        self.note_kernel_process()
        self.client = self.manager.client()
        self.client.start_channels()
        self.client.wait_for_ready(timeout=120)
        self.mark_kernel_output()
        self.note_language()
        self.set_state("idle")

    def note_kernel_process(self):
        provisioner = getattr(self.manager, "provisioner", None)
        self.kernel_process = getattr(provisioner, "process", None) if provisioner is not None else getattr(self.manager, "kernel", None)

    def keep_kernel_output(self, reader):
        while True:
            try:
                data = os.read(reader, 1 << 16)
            except OSError:
                return
            if not data:
                return
            with self.kernel_output_lock:
                self.kernel_output += data
                self.kernel_output_total += len(data)
                if len(self.kernel_output) > KERNEL_OUTPUT_KEPT:
                    del self.kernel_output[:-KERNEL_OUTPUT_KEPT]

    def mark_kernel_output(self):
        """What it says from now on is this kernel's, after its start-up notes."""
        with self.kernel_output_lock:
            self.kernel_output_from = self.kernel_output_total

    def kernel_said(self, count=20):
        with self.kernel_output_lock:
            since = self.kernel_output_total - self.kernel_output_from
            data = bytes(self.kernel_output[-since:]) if 0 < since < len(self.kernel_output) else bytes(self.kernel_output if since else b"")
        text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", data.decode("utf-8", "replace"))
        said = [line[:300] for line in text.splitlines() if line.strip()]
        return said[-count:]

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
                if not isinstance(notebook, dict):
                    return False
                metadata = notebook.setdefault("metadata", {})
                if not isinstance(metadata, dict):
                    return False
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

    def hurried(self):
        with self.asks_lock:
            return any(self.asked[kind] > self.handled[kind] for kind in self.asked)

    def let_kernel_finish(self, restart):
        """Asks it to stop, and gives it a moment for its own cleanup. A second Restart, or a Stop, meanwhile
        means not waiting any more."""
        if not self.kernel_alive():
            return
        try:
            if self.current:
                self.manager.interrupt_kernel()
            self.manager.request_shutdown(restart=restart)
        except Exception as error:
            print("asking the kernel to stop: %s" % error, flush=True)
            return
        deadline = time.time() + GRACE
        while time.time() < deadline and self.kernel_alive():
            if self.hurried():
                with self.asks_lock:
                    self.skip_restarts = self.asked["restart"] - self.handled["restart"]
                return
            time.sleep(0.05)

    def begin_next(self):
        if self.current or not self.pending or self.state == "dead":
            return
        if not self.kernel_alive():
            try:
                self.start_kernel()
            except Exception as error:
                self.pending = []
                self.set_state("dead")
                self.problem("The kernel didn't start: %@", error, detail="\n".join(self.kernel_said(8)) or None)
                return
        wanted = self.pending.pop(0)
        # From the file as it is now: an agent may have changed the cell since it was queued.
        try:
            cells = self.read_cells()
        except (OSError, ValueError) as error:
            self.problem("Couldn't read this notebook: %@", error)
            self.pending = []
            self.set_state()
            return
        index = locate(cells, wanted, wanted.index, wanted.source, edited=True)
        if index is None:
            self.problem("That cell isn't in the notebook any more, so it didn't run.")
            self.set_state()
            return
        run = CellRun(wanted)
        run.index = index
        cell = cells[index]
        run.id = cell.get("id") if isinstance(cell.get("id"), str) else None
        run.source = source_of(cell)
        run.cell_count = len(cells)
        self.message_id = self.client.execute(run.source, store_history=True, allow_stdin=True, stop_on_error=False)
        self.current = run
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
        code = None
        try:
            code = self.kernel_process.poll() if self.kernel_process is not None else None
        except Exception:
            pass
        # Its last words may still be in the pipe.
        time.sleep(0.2)
        said = self.kernel_said()
        text, args = self.why_stopped(code)
        reason = say(text, *args)["message"]
        try:
            self.client.stop_channels()
        except Exception:
            pass
        self.manager = None
        self.kernel_process = None
        run = self.current
        self.current = None
        self.message_id = None
        self.pending = []
        self.waiting_for_input = None
        if run:
            message = "The kernel stopped while this cell was running. " + reason
            run.add("error", {"ename": "Kernel stopped", "evalue": message,
                              "traceback": ["Kernel stopped: " + message, ""] + said if said else []})
            self.save_run(run)
            self.push_run(run)
        self.set_state("stopped")
        self.problem(text, *args, detail="\n".join(said[-6:]) or None, hint="Running a cell starts it again.")

    @staticmethod
    def why_stopped(code):
        if code is None:
            return "The kernel stopped.", ()
        if code < 0:
            try:
                name = signal.Signals(-code).name
            except ValueError:
                name = "signal %d" % -code
            if -code == signal.SIGKILL:
                return "The kernel was killed, likely out of memory.", ()
            if -code in (signal.SIGSEGV, signal.SIGBUS, signal.SIGABRT, signal.SIGILL, signal.SIGFPE):
                return "The kernel crashed in native code (%@).", (name,)
            return "The kernel was stopped by %@.", (name,)
        if code == 0:
            return "The kernel exited.", ()
        return "The kernel exited with code %@.", (code,)

    # The file

    def stamp(self, path=None):
        status = os.stat(path or self.notebook)
        return status.st_mtime_ns, status.st_size, status.st_ino

    def read_cells(self):
        with open(self.notebook, "rb") as file:
            return cells_of(json.loads(file.read().decode("utf-8").lstrip("﻿")))

    def tracked(self):
        return ([self.current] if self.current else []) + self.pending

    def change_notebook(self, change, follow=None):
        """`change` edits the notebook in place, and says whether it did. It's written over nobody's work: if
        the file changes before it's in place, it's read again and changed again. The notebook, when it was.
        `follow` says where a cell that's running or queued is, after the change: its index, and its code."""
        for _ in range(3):
            with open(self.notebook, "rb") as file:
                status = os.fstat(file.fileno())
                data = file.read()
            read = (status.st_mtime_ns, status.st_size, status.st_ino)
            digest = hashlib.sha256(data).digest()
            text = data.decode("utf-8")
            mark = "﻿" if text.startswith("﻿") else ""
            text = text[len(mark):]
            old = json.loads(text)
            new = json.loads(text)
            if not change(new):
                return None
            cells = new.get("cells") if isinstance(new, dict) else None
            found = []
            if isinstance(cells, list):
                for item in self.tracked():
                    index, source = follow(item) if follow else (item.index, item.source)
                    found.append((item, None if index is None else locate(cells, item, index, source), source))
                repair_ids(cells)
            result = (mark + rewrite(text, old, new)).encode("utf-8")

            def unchanged():
                try:
                    if self.stamp() != read:
                        return False
                    with open(self.notebook, "rb") as file:
                        return hashlib.sha256(file.read()).digest() == digest
                except OSError:
                    return False

            if write_atomically(self.notebook, result, unchanged):
                self.known = self.stamp()
                for item, index, source in found:
                    item.source = source
                    item.index = -1 if index is None else index
                    if index is not None:
                        item.id = cells[index].get("id") if isinstance(cells[index].get("id"), str) else None
                        item.cell_count = len(cells)
                return new
        raise Busy("it kept changing while Tiri was saving it")

    def notice_outside_changes(self):
        """An agent may have moved cells while one runs. Only a look at the file's date, most of the time."""
        now = time.time()
        if now - self.checked_at < PUSH_EVERY:
            return
        self.checked_at = now
        try:
            stamp = self.stamp()
            if stamp == self.known:
                return
            cells = self.read_cells()
        except (OSError, ValueError):
            # Halfway through someone's write, perhaps. Next time.
            return
        self.known = stamp
        moved = False
        for item in self.tracked():
            index = locate(cells, item, item.index, item.source)
            index = -1 if index is None else index
            if index != item.index:
                item.index, moved = index, True
                if index >= 0:
                    item.cell_count = len(cells)
        if moved:
            self.set_state()

    def save_run(self, run, running=False):
        def change(notebook):
            cells = cells_of(notebook)
            index = locate(cells, run, run.index, run.source)
            if index is None:
                raise Missing()
            cells[index]["outputs"] = run.saved_outputs()
            cells[index]["execution_count"] = None if running else run.count
            return True

        began = time.time()
        try:
            self.change_notebook(change)
            run.unsaved = False
        except Missing:
            run.unsaved = False
            if not run.missing:
                run.missing = True
                self.problem("That cell isn't in the notebook any more, so its output wasn't saved.")
        except Busy as error:
            # The next save tries again. Only the last one has to say so.
            if not running:
                self.problem("Couldn't save this cell's output: %@", error)
        except (OSError, ValueError) as error:
            self.problem("Couldn't save this cell's output: %@", error)
        self.saved_at = time.time()
        # A big notebook takes a while to write, and saving it shouldn't be most of what happens.
        self.save_every = max(SAVE_EVERY, (self.saved_at - began) * 10)

    def save_current(self, running=False):
        if self.current:
            self.save_run(self.current, running=running)

    def output_message(self, run, running):
        return {"ev": "output", "index": run.index, "run": run.serial, "count": None if running else run.count, "running": running}

    def push_run(self, run, running=False):
        outputs = run.saved_outputs()
        start = len(outputs) if run.changed_from is None else min(run.changed_from, len(outputs))
        message = self.output_message(run, running)
        for viewer in self.all_viewers():
            viewer.put_output(run.serial, message, outputs, start)
        now = time.time()
        self.pushed_at = now
        self.next_push = now + PUSH_EVERY + run.bytes_from(start) / PUSH_RATE
        run.changed_from = None

    def push(self, force=False):
        run = self.current
        if not run:
            return
        self.notice_outside_changes()
        if run.changed_from is not None and (force or time.time() >= self.next_push):
            self.push_run(run, running=True)
        if run.unsaved and time.time() - self.saved_at >= self.save_every:
            self.save_current(running=True)

    # What's asked for

    def handle_command(self, command):
        operation = command.get("op")
        if operation == "hello":
            viewer = command.get("viewer")
            if isinstance(viewer, Viewer):
                viewer.put(self.status())
                # What happened with nobody watching, when something's still going on.
                if self.current:
                    viewer.put_output(self.current.serial, self.output_message(self.current, True), self.current.saved_outputs(), 0)
        elif operation == "run":
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
            self.waiting_for_input = None
            if self.kernel_alive():
                self.manager.interrupt_kernel()
            self.set_state()
        elif operation == "input":
            if self.waiting_for_input:
                self.waiting_for_input = None
                self.client.input(command.get("value", ""))
                self.set_state()
        elif operation == "restart":
            with self.asks_lock:
                self.handled["restart"] += 1
                skip = self.skip_restarts > 0
                if skip:
                    self.skip_restarts -= 1
            if not skip:
                self.restart()
        elif operation == "stop":
            with self.asks_lock:
                self.handled["stop"] += 1
            return False
        return True

    def queue_cells(self, command):
        try:
            cells = self.read_cells()
        except (OSError, ValueError) as error:
            self.problem("Couldn't read this notebook: %@", error)
            return
        wanted = range(len(cells)) if command.get("all") else command.get("cells", [])
        if not isinstance(wanted, (list, range)):
            return
        # Which cell each was when it was asked for, from apps that say: cells may have moved since.
        ids, sources, count = command.get("ids"), command.get("sources"), command.get("count")
        for position, index in enumerate(wanted):
            if not isinstance(index, int) or isinstance(index, bool):
                continue
            if isinstance(ids, list) and isinstance(sources, list) and position < min(len(ids), len(sources)) and isinstance(sources[position], str):
                asked = Asked(ids[position] if isinstance(ids[position], str) else None, sources[position], count)
                index = locate(cells, asked, index, asked.source, edited=True)
                if index is None:
                    self.problem("That cell isn't in the notebook any more, so it didn't run.")
                    continue
            if 0 <= index < len(cells) and is_code(cells[index]):
                self.pending.append(Wanted(cells, index))

    def edit(self, command):
        action = command.get("action")
        index = command.get("index")
        after = command.get("after", -1)
        text = command.get("source", "")

        def change(notebook):
            if not isinstance(notebook, dict) or not isinstance(notebook.setdefault("cells", []), list):
                raise Refused("Couldn't change this notebook: %@", "it has no cells")
            cells = notebook["cells"]
            if action == "insert":
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
                    if is_code(cell):
                        cell["outputs"], cell["execution_count"] = [], None
                return True
            if not isinstance(index, int) or not 0 <= index < len(cells):
                raise Refused("That cell isn't in the notebook any more.")
            cell = cells[index]
            if action == "delete":
                del cells[index]
                return True
            if not isinstance(cell, dict):
                raise Refused("That cell isn't in the notebook any more.")
            if action == "source":
                expected = command.get("expected")
                if expected is not None and source_of(cell) != expected:
                    raise Refused("Something else changed this cell while you were editing it, so your edit wasn't saved.")
                cell["source"] = lines(text)
            elif action == "clear":
                if is_code(cell):
                    cell["outputs"], cell["execution_count"] = [], None
            else:
                return False
            return True

        # Where what's running or queued is afterwards, by what this did, for cells that can only be found by place.
        def follow(item):
            if action == "insert" and isinstance(after, int):
                return (item.index + 1 if item.index > after else item.index), item.source
            if action == "delete" and isinstance(index, int):
                if item.index == index:
                    return None, item.source
                return (item.index - 1 if item.index > index else item.index), item.source
            if action == "source" and item.index == index:
                return item.index, text
            return item.index, item.source

        try:
            if self.change_notebook(change, follow) is not None:
                self.set_state()
        except Refused as refusal:
            self.problem(*refusal.args)
        except (OSError, ValueError) as error:
            self.problem("Couldn't change this notebook: %@", error)

    def restart(self):
        run = self.current
        self.pending = []
        self.waiting_for_input = None
        if run:
            self.save_run(run)
            self.push_run(run)
        if self.manager is None:
            self.current = None
            self.message_id = None
            self.set_state("stopped")
            return
        self.set_state("starting")
        try:
            self.let_kernel_finish(restart=True)
            self.current = None
            self.message_id = None
            # Whatever's left of it goes now, then the same kernel starts again.
            self.manager.restart_kernel(now=True)
            self.note_kernel_process()
            self.client.wait_for_ready(timeout=120)
            self.mark_kernel_output()
            self.set_state("idle")
        except Exception as error:
            self.current = None
            self.message_id = None
            self.set_state("dead")
            self.problem("The kernel didn't restart: %@", error)

    def guarded(self, work, *args):
        """Whatever goes wrong in one step is said, and the kernel carries on. A runner that died here would take
        the kernel with it, and leave the page showing a cell running for ever."""
        try:
            return work(*args)
        except Exception as error:
            traceback.print_exc()
            sys.stdout.flush()
            if self.current and self.message_id is None:
                self.current = None
            self.problem("Something went wrong running this notebook: %@", "%s: %s" % (type(error).__name__, error))
            try:
                self.set_state()
            except Exception:
                pass
            return None

    def run(self):
        threading.Thread(target=self.accept_forever, daemon=True).start()
        self.state = "stopped"
        try:
            self.start_kernel()
        except Exception as error:
            print("start failed: %s" % error, flush=True)
            self.state = "dead"
            self.problem("The kernel didn't start: %@", error, detail="\n".join(self.kernel_said(8)) or None)
        while True:
            busy = False
            try:
                while True:
                    if self.guarded(self.handle_command, self.commands.get_nowait()) is False:
                        self.shut_down()
                        return
                    busy = True
            except queue.Empty:
                pass
            self.guarded(self.begin_next)
            if self.client is not None and self.manager is not None:
                try:
                    busy = self.read_kernel() or busy
                except Exception as error:
                    print("reading the kernel: %s" % error, flush=True)
                self.guarded(self.push)
            self.guarded(self.check_kernel)
            if not busy:
                try:
                    command = self.commands.get(timeout=0.03 if self.current else 0.25)
                    if self.guarded(self.handle_command, command) is False:
                        self.shut_down()
                        return
                except queue.Empty:
                    pass
            if not self.current and not self.pending and not self.all_viewers() and time.time() - self.last_client_at > ABANDONED_AFTER:
                self.shut_down()
                return

    def shut_down(self):
        # Nothing new can attach to this one, and another can start in its place while its kernel finishes.
        try:
            self.listener.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.listener.close()
        except OSError:
            pass
        if self.files:
            self.files.remove()
        run = self.current
        if run:
            self.guarded(self.save_run, run)
            self.guarded(self.push_run, run)
        self.state = "stopped"
        self.broadcast(self.status())
        if self.manager:
            try:
                self.let_kernel_finish(restart=False)
                self.current = None
                self.client.stop_channels()
                self.manager.shutdown_kernel(now=True)
            except Exception as error:
                print("shutting down: %s" % error, flush=True)
        self.current = None
        viewers = self.all_viewers()
        for viewer in viewers:
            viewer.close()
        for viewer in viewers:
            viewer.thread.join(timeout=2)


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
