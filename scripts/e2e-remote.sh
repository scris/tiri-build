#!/bin/bash
# Drives Tiri's SSH workspaces against a real server, through a copy made by scripts/dev-app.sh.
#   TIRI_E2E_HOST=<ssh host> TIRI_DEV_NAME=<name> scripts/e2e-remote.sh
# Uses ~/tiri-e2e on the server, and needs python3 and git there. Needs sudo there for the outage test,
# which is skipped without it. TIRI_SSH_CONFIG, if set, applies here and in the app.
set -u
cd "$(dirname "$0")/.."
HOST="${TIRI_E2E_HOST:?set TIRI_E2E_HOST to an ssh host}"
NAME="${TIRI_DEV_NAME:-e2e}"
T() { scripts/dev-app.sh cli "$NAME" "$@"; }
if [ -n "${TIRI_SSH_CONFIG:-}" ]; then R() { ssh -o LogLevel=ERROR -F "$TIRI_SSH_CONFIG" "$HOST" "$@"; }; else R() { ssh -o LogLevel=ERROR "$HOST" "$@"; }; fi
passed=0; failed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
bad() { failed=$((failed + 1)); echo "FAIL  $1: ${2:-}"; }
has() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "expected \"$2\" in: $3"; fi; }
hasnt() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "didn't expect \"$2\" in: $3"; fi; }
eventually() { # name needle seconds command…
  local name="$1" needle="$2" seconds="$3" output=""; shift 3
  for _ in $(seq 1 $((seconds * 2))); do output="$("$@" 2>&1)"; [[ "$output" == *"$needle"* ]] && { ok "$name"; return; }; sleep 0.5; done
  bad "$name" "no \"$needle\" after ${seconds}s in: $(printf %s "$output" | tail -c 300)"
}
term() { T items | grep -F "[$1]" | grep terminal | head -1 | cut -f1; }

R 'rm -rf ~/tiri-e2e; mkdir -p ~/tiri-e2e/src "$HOME/tiri-e2e/dir with space" ~/tiri-e2e/node_modules/x; cd ~/tiri-e2e
printf "def hello():\n    return 42\n" > src/app.py; printf "# Report\n" > report.md; echo spaced > "dir with space/é.txt"; echo x > node_modules/x/i.js
printf "<link rel=stylesheet href=s.css><h1>Hi</h1>" > page.html; echo "h1{color:red}" > s.css
git init -q .; git add -A; git -c user.email=a@b -c user.name=a commit -qm first; echo more >> src/app.py; echo new > untracked.txt'

# Every run starts from nothing, here and there.
scripts/dev-app.sh stop "$NAME" >/dev/null 2>&1
rm -rf "${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}/$NAME/home" "${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}/$NAME/config"
R 'for s in ~/.tiri/run/*-i-*.sock; do ~/.tiri/bin/tiri-remote session kill "$s" 2>/dev/null; done; true' 2>/dev/null
scripts/dev-app.sh start "$NAME" >/dev/null 2>&1
has "connects" "tiri-e2e" "$(T remote connect "$HOST" '~/tiri-e2e')"
has "state" "Connected" "$(T remote)"
eventually "tree shows the server's files" "src/" 15 T tree
hasnt "excluded names stay out" "node_modules" "$(T tree)"
ID="$(term tiri-e2e)"; [ -n "$ID" ] && ok "starts with a terminal" || bad "starts with a terminal"
eventually "terminal is on the server" "tiri-e2e" 15 T read "$ID" --lines 5
eventually "changes come from the server's git" "/home" 15 T changes
has "changes use the server's paths" "src/app.py" "$(T changes)"
hasnt "no local copy's path in changes" "Remote.noindex" "$(T changes)"
has "search on the server" "src/app.py" "$(T search hello)"
hasnt "search speaks the server's paths" "Remote.noindex" "$(T search hello)"
has "git status" "master" "$(T git)$(T git | grep -c main >/dev/null; T git)"

# tiri inside a terminal there
T send "$ID" 'clear; which tiri; tiri ping' --enter
eventually "tiri works on the server" "pong" 10 T read "$ID" --lines 5
T send "$ID" 'clear; tiri open src/app.py; tiri quit; echo rc=$?' --enter
eventually "the Mac is off limits" "only be run" 10 T read "$ID" --lines 6
eventually "open from the server floats a Peek" "(peek)" 10 T items
T send "$ID" 'clear; tiri open report.md:1; tiri open "dir with space/é.txt"; tiri open /etc/hosts; echo done-$((40+2))' --enter
eventually "odd names and outside paths open" "done-42" 10 T read "$ID" --lines 8
hasnt "nothing refused" "No such file" "$(T read "$ID" --lines 8)"

# Reading follows the server
R 'cd ~/tiri-e2e; printf "live-edit\n" >> report.md; mkdir -p fresh; echo x > fresh/new.txt'
eventually "new files appear" "fresh/" 10 T tree

# Status of what's in the foreground
T send "$ID" 'clear; sleep 4' --enter
eventually "busy while something runs" "working" 8 T items
eventually "idle afterwards" "idle" 12 T items

# Status from hooks, through the relay
hook() { T send "$ID" "clear; printf '{\"hook_event_name\":\"$1\",\"session_id\":\"s1\",\"cwd\":\"/tmp\"}' | tiri hook claude; echo hooked-$1" --enter; }
hook UserPromptSubmit
eventually "a hook reports work" "working" 10 T items
hook Stop
eventually "and that it's done" "hooked-Stop" 10 T read "$ID" --lines 3

# Going past sshd's session limit
for i in $(seq 1 12); do T term --cmd "echo term-$i-up; exec sh" >/dev/null; done
sleep 8
ups=0; for item in $(T items | grep -F "[tiri-e2e]" | grep terminal | cut -f1); do T read "$item" --lines 30 2>/dev/null | grep -q 'term-[0-9]*-up' && ups=$((ups + 1)); done
if [ "$ups" -eq 12 ]; then ok "12 more terminals all run"; else bad "12 more terminals all run" "only $ups"; fi
has "commands still work with them" "src/app.py" "$(T search hello)"
for item in $(T items | grep -F "[tiri-e2e]" | grep terminal | grep -v "$ID" | cut -f1); do T close "$item" >/dev/null 2>&1; done
sleep 2
COUNT="$(R 'ls ~/.tiri/run/*.sock 2>/dev/null | grep -c -e -i- ')"
[ "$COUNT" -le 3 ] && ok "closing tabs ends their programs" || bad "closing tabs ends their programs" "$COUNT sockets left"

# The connection dying under a running program
T send "$ID" 'clear; for i in 1 2 3 4 5 6 7 8; do echo tick-$i; sleep 1; done; echo ticks-done' --enter
sleep 1.5
pkill -f "ssh.*-M -N.*$HOST" ; has "notices" "Reconnecting" "$(sleep 0.3; T remote)"
eventually "comes back" "Connected" 20 T remote
eventually "nothing printed meanwhile is lost" "tick-8" 15 T read "$ID" --lines 12
has "and everything before" "tick-2" "$(T read "$ID" --lines 12)"

# Quitting Tiri under a running program
T send "$ID" 'clear; for i in 1 2 3 4 5 6 7 8; do echo after-quit-$i; sleep 1; done' --enter
sleep 1
scripts/dev-app.sh cli "$NAME" quit >/dev/null 2>&1; sleep 1
scripts/dev-app.sh start "$NAME" >/dev/null 2>&1
eventually "reconnects at launch" "Connected" 20 T remote
sleep 1; T workspace switch tiri-e2e >/dev/null 2>&1
eventually "same session after a relaunch" "after-quit-8" 25 T read "$ID" --lines 12

# What a hostile server might try. Each of these has to stay on its own side.
MARK="$(mktemp -d)"
LOCAL_FILE="$MARK/secret.txt"; echo mac-secret > "$LOCAL_FILE"
T workspace new localfront --folder "$MARK" >/dev/null
T send "$ID" "clear; env -u TIRI_ITEM_ID tiri term --cwd /tmp --cmd 'touch $MARK/pwned'; env -u TIRI_ITEM_ID tiri open /tmp; echo tried-1" --enter
eventually "with no item and a local workspace in front" "tried-1" 15 T read "$ID" --lines 5
has "a server is refused" "workspace in front" "$(T read "$ID" --lines 8 | tr -d '\n')"
T send "$ID" "clear; tiri term --cmd 'touch $MARK/pwned2'; tiri open $LOCAL_FILE; echo tried-2" --enter
eventually "its own term stays on its server" "tried-2" 15 T read "$ID" --lines 6
sleep 2
[ ! -e "$MARK/pwned" ] && [ ! -e "$MARK/pwned2" ] && ok "nothing ran on the Mac" || bad "nothing ran on the Mac"
hasnt "no Mac file opened" "secret.txt" "$(T items)"
hasnt "and items only shows its own" "localfront" "$(T send "$ID" 'clear; tiri items; echo listed' --enter; sleep 2; T read "$ID" --lines 8)"
T workspace switch tiri-e2e >/dev/null; sleep 1
T send "$ID" "clear; tiri review add $LOCAL_FILE:1 x; tiri preview file://$LOCAL_FILE; tiri send i-nosuch hi; tiri focus i-nosuch; tiri theme light; echo tried-3" --enter
eventually "other reaches" "tried-3" 15 T read "$ID" --lines 8
hasnt "a Mac file can't be quoted" "$(cat "$LOCAL_FILE")" "$(T read "$ID" --lines 12)"
has "preview of a Mac file is refused" "isn't on this server" "$(T read "$ID" --lines 12 | tr -d '\n')"
has "theme stays the Mac's" "can only be run on the Mac" "$(T read "$ID" --lines 12 | tr -d '\n')"
T workspace delete localfront >/dev/null 2>&1
for leftover in $(T items | grep -F "[tiri-e2e]" | grep terminal | grep -v "$ID" | cut -f1); do T close "$leftover" >/dev/null 2>&1; done
rm -rf "$MARK"

# A file named to break out of quotes, on whatever the login shell is
R "cd ~/tiri-e2e; python3 - <<'PY'
open(\"';touch PWNED;\\\\\", 'w').write('harmless\\n')
PY
true" 2>/dev/null
T send "$ID" 'clear; cd ~/tiri-e2e; tiri tree >/dev/null; echo quoted-done' --enter
eventually "odd file names" "quoted-done" 10 T read "$ID" --lines 3
sleep 2
for name in $(T tree 2>/dev/null | grep -c PWNED); do :; done
T open "/home/$(R 'id -un')/tiri-e2e/';touch PWNED;\\" >/dev/null 2>&1
sleep 2
R 'cd ~/tiri-e2e; [ -e PWNED ] && echo PWNED || echo clean' | grep -q clean && ok "a file's name can't run anything" || bad "a file's name can't run anything"
R "cd ~/tiri-e2e; python3 -c \"import os; [os.remove(f) for f in os.listdir('.') if f.startswith(\\\"';\\\")]\""

# A save that doesn't all arrive
R 'cd ~/tiri-e2e; printf full-original-contents > keep.txt; printf ORI | ~/.tiri/bin/tiri-remote write keep.txt 30 2>/dev/null; echo "rc=$?"; cat keep.txt' > /tmp/.tiri-e2e-w 2>&1
W="$(cat /tmp/.tiri-e2e-w)"; rm -f /tmp/.tiri-e2e-w
has "a cut-off save is refused" "rc=1" "$W"
has "and the file is untouched" "full-original-contents" "$W"
W="$(R 'cd ~/tiri-e2e; printf new | ~/.tiri/bin/tiri-remote write keep.txt 3 --if-modified 12345 2>/dev/null; echo "rc=$?"; cat keep.txt')"
has "a save that would replace newer work stops" "rc=9" "$W"
has "and leaves it alone" "full-original-contents" "$W"

if [ -n "${TIRI_E2E_NO_FORWARDING:-}" ]; then
  # A server that forbids forwarding: everything else still works, and these say so.
  T send "$ID" 'clear; tiri preview http://localhost:18765/; echo preview-done' --enter
  eventually "a forbidden port fails quickly" "preview-done" 10 T read "$ID" --lines 4
  has "and says why" "forward" "$(T read "$ID" --lines 4)"
else
# Ports
T send "$ID" 'clear; cd ~/tiri-e2e; (python3 -m http.server 18765 >/dev/null 2>&1 &) ; sleep 1; tiri preview http://localhost:18765/report.md; echo served' --enter
eventually "preview from the server" "served" 10 T read "$ID" --lines 3
has "port is listed" "18765" "$(T remote ports; echo; T read "$ID" --lines 4)"
curl -s -m 5 "http://localhost:18765/report.md" | grep -q Report && ok "port reaches the Mac" || bad "port reaches the Mac"
R "pkill -f 'http.server 18765'"

# Editor protocol, from where Claude Code would be
R 'cat > /tmp/tiri-ws.py' <<'PY'
import base64, glob, json, os, socket, struct, sys
port = int(os.environ["CLAUDE_CODE_SSE_PORT"])
lock = json.load(open(os.path.expanduser(f"~/.claude/ide/{port}.lock")))
os.kill(lock["pid"], 0)
s = socket.create_connection(("127.0.0.1", port))
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nx-claude-code-ide-authorization: {lock['authToken']}\r\n\r\n").encode())
assert b"101" in s.recv(4096)
def send(o):
    b = json.dumps(o).encode(); mask = os.urandom(4)
    h = bytes([0x81]) + (bytes([0x80 | len(b)]) if len(b) < 126 else bytes([0x80 | 126]) + struct.pack(">H", len(b)))
    s.sendall(h + mask + bytes(c ^ mask[i % 4] for i, c in enumerate(b)))
def recv():
    h = s.recv(2); n = h[1] & 127
    if n == 126: n = struct.unpack(">H", s.recv(2))[0]
    if n == 127: n = struct.unpack(">Q", s.recv(8))[0]
    d = b""
    while len(d) < n: d += s.recv(n - len(d))
    return json.loads(d)
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}); print("init", list(recv().get("result",{}).keys()))
send({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"getWorkspaceFolders","arguments":{}}}); print("folders", json.dumps(recv()))
send({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"getOpenEditors","arguments":{}}}); print("editors", json.dumps(recv()))
print("ws-ok")
PY
T send "$ID" 'clear; python3 /tmp/tiri-ws.py 2>&1 | cut -c1-400' --enter
sleep 3
WS="$(T read "$ID" --lines 12)"
if [[ "$WS" == *"ws-ok"* ]]; then ok "editor protocol reaches the Mac from the server"; else
  # A session started before the current connection has the previous port.
  T term --cmd "python3 /tmp/tiri-ws.py 2>&1 | cut -c1-400; exec sh" >/dev/null; sleep 4
  ITEM="$(T items | grep -F "[tiri-e2e]" | grep terminal | grep -v "$ID" | head -1 | cut -f1)"; WS="$(T read "$ITEM" --lines 14)"
  has "editor protocol reaches the Mac from the server" "ws-ok" "$WS"
fi
has "and folders are the server's" "tiri-e2e" "$WS"
hasnt "with no local paths" "Remote.noindex" "$WS"

fi

# A real outage
if R 'sudo -n true' 2>/dev/null; then
  R "nohup sudo -n sh -c 'iptables -I INPUT -p tcp --dport 22 -j DROP; sleep 45; iptables -D INPUT -p tcp --dport 22 -j DROP' >/dev/null 2>&1 &"
  eventually "an outage is noticed" "Reconnecting" 50 T remote
  eventually "and recovered from" "Connected" 60 T remote
  T send "$ID" 'clear; echo after-outage-$((40+2))' --enter
  eventually "terminal works after the outage" "after-outage-42" 20 T read "$ID" --lines 3
else
  echo "skip  outage test (needs sudo on the server)"
fi

# Asking for something that isn't there
has "a host that doesn't exist says so" "isn't a host" "$(T remote connect no-such-host-tiri.invalid 2>&1)"
has "a folder that doesn't exist says so" "isn't a folder" "$(T remote connect "$HOST" /no/such/folder 2>&1)"

scripts/dev-app.sh stop "$NAME"
R 'for s in ~/.tiri/run/*-i-*.sock; do ~/.tiri/bin/tiri-remote session kill "$s" 2>/dev/null; done; rm -rf ~/tiri-e2e /tmp/tiri-ws.py'
echo; echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
