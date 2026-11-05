#!/bin/bash
# Drives a real test copy through the whole plugin system, including trying to break out of a panel.
#   scripts/dev-app.sh start e2eplug && scripts/e2e-plugins.sh e2eplug
# Every program it starts stops when it's done. Screenshots go in $TIRI_SHOTS, if that's set.
set -u
NAME="${1:-e2eplug}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}"
DIR="$ROOT/$NAME"
APP="$DIR/TiriDev.app"
CLI="$APP/Contents/Resources/bin/tiri"
[ -x "$CLI" ] || { echo "No test copy called $NAME. Run scripts/dev-app.sh start $NAME" >&2; exit 1; }
export TIRI_HOME="$DIR/home" TIRI_CONFIG_HOME="$DIR/config" TIRI_SOCKET="/tmp/tiri-dev-$NAME.sock"
export PATH="$APP/Contents/Resources/bin:$PATH"
PLUGINS="$TIRI_CONFIG_HOME/plugins"
WORK="$(mktemp -d)"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
cd "$WORK"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
no() { failed=$((failed + 1)); echo "FAIL  $1"; }
expect() { # name, needle, command...
  local name="$1" needle="$2"; shift 2
  local output; output="$("$@" 2>&1)"
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: expected \"$needle\" in: $output"; fi
}
lacks() { # name, needle, command...
  local name="$1" needle="$2"; shift 2
  local output; output="$("$@" 2>&1)"
  if [[ "$output" != *"$needle"* ]]; then ok "$name"; else no "$name: found \"$needle\" in: $output"; fi
}
refuses() { # name, needle, command...
  local name="$1" needle="$2"; shift 2
  local output; if output="$("$@" 2>&1)"; then no "$name: should have been refused, said: $output"; return; fi
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: refused, but said: $output"; fi
}
waits() { # name, needle, command...: a few seconds for things that happen by themselves
  local name="$1" needle="$2"; shift 2
  local output=""
  for _ in $(seq 1 60); do
    output="$("$@" 2>&1)"
    if [[ "$output" == *"$needle"* ]]; then ok "$name"; return; fi
    sleep 0.1
  done
  no "$name: expected \"$needle\" in: $output"
}
goes() { # name, needle, command...: until it isn't there
  local name="$1" needle="$2"; shift 2
  local output=""
  for _ in $(seq 1 60); do
    output="$("$@" 2>&1)"
    if [[ "$output" != *"$needle"* ]]; then ok "$name"; return; fi
    sleep 0.1
  done
  no "$name: still \"$needle\" in: $output"
}
shot() { [ -n "${TIRI_SHOTS:-}" ] && (cd "$REPO" && scripts/dev-app.sh shot "$NAME" "$TIRI_SHOTS/$1.png"); return 0; }
approve() { # name: a yes, the way a press gives one
  "$CLI" plugin enable "$1" >/dev/null
  for _ in $(seq 1 40); do "$CLI" dev-plugin-question | grep -q '"question" *: *"[^"]' && break; sleep 0.05; done
  "$CLI" dev-plugin-answer yes >/dev/null
  for _ in $(seq 1 60); do "$CLI" plugin | grep -q "^$1	on" && return 0; sleep 0.1; done
  return 1
}
pageval() { # item, script
  "$CLI" web eval "$2" --item "$1"
}

"$CLI" workspace add-folder "$PROJECT" >/dev/null
# Every check below has to happen without this window being where anyone can see or press it.

# ---------------------------------------------------------------- core: a language-only plugin
echo "== A language, installed, approved, working and gone"
printf 'fn main() { // hello\n  let x = "tiridemo"\n}\n' > "$PROJECT/a.tiridemo"
mkdir -p "$PLUGINS/demo-lang/.tiri-plugin" "$PLUGINS/demo-lang/grammars"
cat > "$PLUGINS/demo-lang/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "demo-lang", "title": "Demo Language", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "grammars": [{ "scope": "source.tiridemo", "path": "grammars/demo.json" }],
  "languages": [{ "id": "tiridemo", "name": "Tiri Demo", "extensions": ["tiridemo"], "grammar": "source.tiridemo", "comment": { "line": "//" } }] }
JSON
cat > "$PLUGINS/demo-lang/grammars/demo.json" <<'JSON'
{ "scopeName": "source.tiridemo", "patterns": [
  { "match": "//.*$", "name": "comment.line" }, { "match": "\"[^\"]*\"", "name": "string.quoted" }, { "match": "\\b(fn|let)\\b", "name": "keyword.control" } ] }
JSON
"$CLI" plugin reload >/dev/null
expect "validate says what a language plugin adds" "Adds: 1 language" "$CLI" plugin validate demo-lang
lacks "and that it runs nothing" "Runs, with your full" "$CLI" plugin validate demo-lang
expect "found and off" "demo-lang	off" "$CLI" plugin
"$CLI" open "$PROJECT/a.tiridemo" >/dev/null
sleep 0.5
expect "enable only asks" "asking for a yes" "$CLI" plugin enable demo-lang
waits "the question is on screen" "Turn on Demo Language" "$CLI" dev-plugin-question
expect "still off while it's asking" "demo-lang	off" "$CLI" plugin
"$CLI" dev-plugin-answer no >/dev/null
sleep 0.3
expect "no means off" "demo-lang	off" "$CLI" plugin
approve demo-lang && ok "a yes turns it on" || no "a yes turns it on"
waits "and it's on" "demo-lang	on" "$CLI" plugin
shot plugin-language-on
"$CLI" plugin verify demo-lang > "$WORK/verify" 2>&1
expect "its grammar compiles in the real engine" "ok	demo-lang" cat "$WORK/verify"
expect "verify checks against the running app" "and the running app" cat "$WORK/verify"
printf 'changed' >> "$PLUGINS/demo-lang/grammars/demo.json"
waits "an edit turns it off by itself" "demo-lang	broken" "$CLI" plugin
python3 - "$PLUGINS/demo-lang/grammars/demo.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read().replace('changed', ''); open(p, 'w').write(s + ' ')
PY
waits "a fix with different bytes needs a new yes" "demo-lang	changed" "$CLI" plugin
expect "and says what changed" "grammars/demo.json" "$CLI" plugin
approve demo-lang && ok "approved again" || no "approved again"
"$CLI" plugin disable demo-lang
waits "turned off" "demo-lang	off" "$CLI" plugin
"$CLI" plugin verify > "$WORK/verify" 2>&1
expect "verify reads every plugin" "demo-lang" cat "$WORK/verify"

# ---------------------------------------------------------------- native surfaces
echo "== Native surfaces"
mkdir -p "$PLUGINS/surfaces/.tiri-plugin" "$PLUGINS/surfaces/bin" "$PLUGINS/surfaces/panel"
cat > "$PLUGINS/surfaces/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "surfaces", "title": "Surfaces", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "description": "Every native surface, for testing.",
  "test": ["bin/test"],
  "commands": [
    { "id": "echo", "title": "Echo", "category": "Surfaces", "key": "cmd+alt+shift+e", "exec": ["bin/echoer", "${args.word}", "${file}"], "show": "none" },
    { "id": "taken", "title": "Wants a Taken Key", "key": "cmd+p", "exec": ["bin/echoer"], "show": "none" },
    { "id": "fail", "title": "Fails", "exec": ["bin/failer"] },
    { "id": "slow", "title": "Slow", "exec": ["bin/sleeper"], "timeout": 1, "show": "none" },
    { "id": "term", "title": "In a Terminal", "terminal": "bin/echoer ${args.word}" },
    { "id": "ping", "title": "Ask the Process", "process": "server", "method": "ping" },
    { "id": "crash", "title": "Crash the Process", "process": "server", "method": "crash" },
    { "id": "hint", "title": "Give Me a Hint", "ask": "A hint about ${args.topic}, please." },
    { "id": "show", "title": "Show Panel", "panel": "main", "open": "tab" }
  ],
  "settings": [
    { "key": "word", "title": "Word", "explanation": "A word.", "type": "text", "default": "hello" },
    { "key": "mode", "title": "Mode", "type": "choice", "options": [{ "value": "a", "label": "A" }, { "value": "b" }], "default": "a" },
    { "key": "on", "title": "On", "type": "toggle", "default": true },
    { "key": "count", "title": "Count", "type": "number", "min": 1, "max": 5, "default": 2 }
  ],
  "panels": [{ "id": "main", "title": "Surfaces Panel", "entry": "panel/index.html" }],
  "sidebar": [
    { "id": "things", "title": "Things", "provider": { "exec": ["bin/tree"] }, "refresh": { "onSave": true }, "emptyText": "Nothing yet",
      "buttons": [{ "title": "Echo", "symbol": "bolt", "command": "echo" }] },
    { "id": "pushed", "title": "Pushed" }
  ],
  "statusBar": [
    { "id": "fixed", "text": "Fixed", "symbol": "star", "command": "echo" },
    { "id": "live", "provider": { "exec": ["bin/status"] }, "symbol": "flame" },
    { "id": "pushed" }
  ],
  "fileButtons": [{ "title": "Echo This", "symbol": "play", "patterns": ["*.txt"], "command": "echo" }],
  "processes": [{ "id": "server", "exec": ["bin/server"], "idleMinutes": 0.02 }]
}
JSON
cat > "$PLUGINS/surfaces/panel/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Surfaces</title><h1>Surfaces</h1>
HTML
cat > "$PLUGINS/surfaces/bin/echoer" <<'SH'
#!/bin/sh
echo "word=$1 file=$2 name=$TIRI_PLUGIN_NAME folder=$TIRI_WORKSPACE_FOLDER settings=$TIRI_PLUGIN_SETTINGS"
SH
cat > "$PLUGINS/surfaces/bin/failer" <<'SH'
#!/bin/sh
echo "this went wrong" >&2
exit 3
SH
cat > "$PLUGINS/surfaces/bin/sleeper" <<'SH'
#!/bin/sh
exec sleep 30
SH
cat > "$PLUGINS/surfaces/bin/tree" <<'SH'
#!/bin/sh
cat <<JSON
{"items": [{"id": "one", "title": "One", "detail": "first", "symbol": "doc", "command": "echo", "args": {"word": "row"}},
           {"id": "two", "title": "Two", "children": [{"title": "Inner", "path": "a.tiridemo"}]}]}
JSON
SH
cat > "$PLUGINS/surfaces/bin/status" <<'SH'
#!/bin/sh
echo '{"text": "Live 7", "tooltip": "From a program"}'
SH
cat > "$PLUGINS/surfaces/bin/server" <<'SH'
#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "crash":
        print("about to crash", file=sys.stderr, flush=True)
        sys.exit(9)
    print(json.dumps({"id": message["id"], "result": "pong"}), flush=True)
SH
cat > "$PLUGINS/surfaces/bin/test" <<'SH'
#!/bin/sh
"$TIRI_PLUGIN_DIR/bin/echoer" a b | grep -q word=a && echo fine
SH
chmod +x "$PLUGINS/surfaces/bin/"*
"$CLI" plugin reload >/dev/null
expect "validate lists what it runs" "bin/server" "$CLI" plugin validate surfaces
expect "and warns about the taken key" "which Tiri already uses" "$CLI" plugin validate surfaces
expect "its own tests pass" "Its tests passed" "$CLI" plugin test surfaces
refuses "a command isn't there until it's on" "No command" "$CLI" run surfaces.echo
lacks "not in the command list" "surfaces.echo" "$CLI" commands
approve surfaces && ok "surfaces turned on" || no "surfaces turned on"
expect "in the command list" "surfaces.echo" "$CLI" commands
expect "a panel gets a command" "surfaces.show" "$CLI" commands
expect "its key works" "surfaces.echo" bash -c "'$CLI' keys | grep '⌥⇧⌘E'"
lacks "a taken key stays where it was" "surfaces.taken	⌘P" "$CLI" keys
expect "and quick open still has it" "quickOpen" bash -c "'$CLI' keys | grep '⌘P'"

expect "tiri run with arguments reaches the program" "word=sky" "$CLI" run surfaces.echo word=sky
expect "it sees the workspace" "folder=$PROJECT" "$CLI" run surfaces.echo word=x
expect "and its settings" '"word":"hello"' "$CLI" run surfaces.echo word=x
"$CLI" open "$PROJECT/a.tiridemo" --tab >/dev/null
sleep 0.2
expect "and the file in front" "file=$PROJECT/a.tiridemo" "$CLI" run surfaces.echo word=x
expect "a value with spaces stays one word" "word=two words" "$CLI" run surfaces.echo "word=two words"
refuses "a failing program says why" "this went wrong" "$CLI" run surfaces.fail
expect "stderr reaches the log" "this went wrong" "$CLI" plugin logs surfaces
refuses "a program over its time is stopped" "longer than 1 seconds" "$CLI" run surfaces.slow
lacks "and nothing's left running" "bin/sleeper" bash -c "pgrep -fl 'plugins/surfaces/bin/sleeper' || true"

expect "settings list includes it" "plugin.surfaces.word" "$CLI" settings
expect "settings get" "hello" "$CLI" settings get plugin.surfaces.word
expect "settings set" "there" "$CLI" settings set plugin.surfaces.word there
expect "programs see the change" '"word":"there"' "$CLI" run surfaces.echo word=x
refuses "a choice stays a choice" "one of" "$CLI" settings set plugin.surfaces.mode zzz
expect "settings reset" "hello" "$CLI" settings reset plugin.surfaces.word
expect "own store, not Tiri's" "surfaces.json" ls "$TIRI_CONFIG_HOME/plugin-settings"
lacks "nothing in settings.json" "surfaces" bash -c "cat '$TIRI_CONFIG_HOME/settings.json' 2>/dev/null || true"

expect "the process answers" "pong" "$CLI" run surfaces.ping
expect "it's counted" '"pluginProcesses":1' "$CLI" perf --json
waits "it stops when idle" '"pluginProcesses":0' bash -c "sleep 1.2; '$CLI' perf --json"
expect "and starts again on demand" "pong" "$CLI" run surfaces.ping
refuses "a crash doesn't hang whoever asked" "stopped before it answered" "$CLI" run surfaces.crash
expect "the log has what it said" "about to crash" "$CLI" plugin logs surfaces
expect "and it comes back" "pong" "$CLI" run surfaces.ping

"$CLI" term --cwd "$WORK" --cmd "cat" >/dev/null
sleep 0.5
expect "a terminal command gets its own tab" "i-" "$CLI" run surfaces.term "word=from term"
waits "with the word quoted, in it" "word=from term" bash -c "for id in \$('$CLI' items | awk -F'\t' '\$2==\"terminal\"{print \$1}'); do '$CLI' read \$id --lines 20; done"

expect "update a pushed sidebar section" "" "$CLI" plugin update surfaces sidebar pushed '{"items": [{"title": "Pushed Row"}]}'
expect "update a pushed status item" "" "$CLI" plugin update surfaces status pushed '{"text": "Pushed Status"}'
refuses "only sections it declared" "no sidebar section" "$CLI" plugin update surfaces sidebar nothing '{"items": []}'
sleep 0.8
shot plugin-native-surfaces

"$CLI" plugin disable surfaces
goes "everything goes when it's off: commands" "surfaces.echo" "$CLI" commands
lacks "keys" "⌥⇧⌘E" "$CLI" keys
lacks "settings" "plugin.surfaces" "$CLI" settings
expect "processes" '"pluginProcesses":0' "$CLI" perf --json
refuses "and it can't be run" "No command" "$CLI" run surfaces.echo
expect "its settings are kept" "surfaces.json" ls "$TIRI_CONFIG_HOME/plugin-settings"
sleep 0.3
shot plugin-native-surfaces-off
approve surfaces && ok "back on" || no "back on"

# ---------------------------------------------------------------- panels, and trying to get out of one
echo "== Panels, and what they can't do"
mkdir -p "$PLUGINS/sealed/.tiri-plugin" "$PLUGINS/sealed/panel" "$PLUGINS/sealed/bin"
cat > "$PLUGINS/sealed/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "sealed", "title": "Sealed", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "commands": [
    { "id": "allowed", "title": "Allowed", "exec": ["bin/ran", "allowed", "${args.note}"], "show": "none" },
    { "id": "forbidden", "title": "Forbidden", "exec": ["bin/ran", "forbidden"], "show": "none" },
    { "id": "show", "title": "Show", "panel": "open" },
    { "id": "showlocked", "title": "Show Locked", "panel": "locked" }
  ],
  "panels": [
    { "id": "open", "title": "Open Panel", "entry": "panel/index.html", "allow": {
        "network": ["http://127.0.0.1:47831"], "commands": ["allowed"], "processes": ["server"], "agent": true, "openFiles": true } },
    { "id": "locked", "title": "Locked Panel", "entry": "panel/index.html" },
    { "id": "viewer", "title": "Sealed View", "entry": "panel/viewer.html" },
    { "id": "option", "title": "Other View", "entry": "panel/viewer.html" }
  ],
  "viewers": [
    { "panel": "viewer", "patterns": ["*.sealed"], "writes": true },
    { "panel": "viewer", "patterns": ["*.readonly"] },
    { "panel": "option", "patterns": ["*.opt"], "priority": "option" }
  ],
  "processes": [{ "id": "server", "exec": ["bin/server"] }],
  "settings": [{ "key": "note", "title": "Note", "type": "text", "default": "n" }]
}
JSON
cat > "$PLUGINS/sealed/panel/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Sealed</title><link rel="stylesheet" href="a.css">
<h1>Sealed</h1><p id="status">Selectable words in a panel</p><script src="panel.js"></script>
HTML
cat > "$PLUGINS/sealed/panel/viewer.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>View</title><h1 id="status">Viewer</h1><script src="viewer.js"></script>
HTML
cat > "$PLUGINS/sealed/panel/viewer.js" <<'JS'
window.fileEvents = 0;
tiri.on('file', () => { window.fileEvents++; });
tiri.read().then((text) => { window.loaded = text; document.getElementById('status').textContent = text; });
JS
cat > "$PLUGINS/sealed/panel/a.css" <<'CSS'
:root { color-scheme: light dark; } body { font: 14px sans-serif; margin: 24px; }
CSS
cat > "$PLUGINS/sealed/panel/panel.js" <<'JS'
window.results = {};
window.events = [];
// Each of these is something a hostile page would try. What happened is kept for the test to read.
window.attempt = async (name, body) => {
  try { window.results[name] = 'allowed: ' + String(await body()); } catch (error) { window.results[name] = 'refused: ' + error.message; }
};
tiri.on('hello', (data) => window.events.push(data));
tiri.on('args', (data) => window.events.push(data));
tiri.on('settings', (data) => window.events.push(data));
JS
cat > "$PLUGINS/sealed/bin/ran" <<'SH'
#!/bin/sh
echo "$1 $2" >> "$TIRI_PLUGIN_DIR/../../ran.txt"
echo "ran $1"
SH
cat > "$PLUGINS/sealed/bin/server" <<'SH'
#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    print(json.dumps({"method": "event", "params": {"name": "hello", "data": "from the process"}}), flush=True)
    print(json.dumps({"id": message["id"], "result": {"echo": message.get("params")}}), flush=True)
SH
chmod +x "$PLUGINS/sealed/bin/"*
"$CLI" plugin reload >/dev/null
approve sealed && ok "sealed turned on" || no "sealed turned on"

# A local server that the panel may reach, and one it may not.
# Both let anyone read them, so that only the panel's policy can be what stops it.
cat > "$WORK/serve.py" <<'PY'
import http.server, sys
class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
    def log_message(self, *args):
        pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
(cd "$WORK" && exec python3 serve.py 47831) &
ALLOWED_SERVER=$!
(cd "$WORK" && exec python3 serve.py 47832) &
FORBIDDEN_SERVER=$!
trap 'kill $ALLOWED_SERVER $FORBIDDEN_SERVER 2>/dev/null; rm -rf "$WORK"' EXIT
echo reachable > "$WORK/data.txt"
sleep 0.5

expect "show a panel" "" "$CLI" run sealed.show id=12
sleep 1.2
OPEN="$("$CLI" items | awk -F'\t' '$4=="Open Panel"{print $1}' | head -1)"
[ -n "$OPEN" ] && ok "it's an item ($OPEN)" || no "it's an item"
expect "listed as a plugin" "plugin" "$CLI" items
expect "a page with no styling follows light and dark" "dark" "$CLI" web eval "getComputedStyle(document.documentElement).colorScheme" --item "$OPEN"
expect "agents can read it with web" "Selectable words" "$CLI" web text --item "$OPEN"
shot plugin-panel

check_attempt() { # name, expected prefix, script body
  local name="$1" wanted="$2" body="$3"
  pageval "$OPEN" "attempt('$name', async () => { $body }); 0" >/dev/null
  local answer=""
  for _ in $(seq 1 40); do
    answer="$(pageval "$OPEN" "window.results['$name'] || ''")"
    [ -n "$answer" ] && break
    sleep 0.05
  done
  if [[ "$answer" == "$wanted"* ]]; then ok "$name: ${answer:0:70}"; else no "$name: expected $wanted, got: $answer"; fi
}
netget='const r = await fetch(URL); return r.status + " " + (await r.text());'
check_attempt "context" "allowed" 'const c = await tiri.context(); if (c.args.id !== "12") throw new Error("no args"); return c.plugin + " " + c.theme;'
check_attempt "own files" "allowed" 'const r = await fetch("a.css"); return r.status;'
check_attempt "declared address" "allowed: 200 reachable" "${netget//URL/\"http://127.0.0.1:47831/data.txt\"}"
check_attempt "undeclared address" "refused" "${netget//URL/\"http://127.0.0.1:47832/data.txt\"}"
check_attempt "the wider internet" "refused" "${netget//URL/\"https://example.com/\"}"
check_attempt "a file on this Mac" "refused" "${netget//URL/\"file:///etc/hosts\"}"
check_attempt "out of its folder" "refused" 'const r = await fetch("../../../settings.json"); if (!r.ok) throw new Error("not there"); return await r.text();'
check_attempt "the files of another plugin" "refused" 'const r = await fetch("tiri-plugin://surfaces/.tiri-plugin/plugin.json"); return await r.text();'
check_attempt "a script from elsewhere" "refused" 'return await new Promise((ok, no) => { const s = document.createElement("script"); s.src = "http://127.0.0.1:47831/data.txt"; s.onload = () => ok("loaded"); s.onerror = () => no(new Error("blocked")); document.head.appendChild(s); });'
check_attempt "a script written in the page" "refused" 'const s = document.createElement("script"); s.textContent = "window.injected = 1"; document.head.appendChild(s); if (!window.injected) throw new Error("did not run"); return "ran";'
check_attempt "eval" "refused" 'return eval("1+1");'
check_attempt "new Function" "refused" 'return new Function("return 1")();'
check_attempt "an embedded page" "refused" 'return await new Promise((ok, no) => { const f = document.createElement("iframe"); f.src = "http://127.0.0.1:47831/data.txt"; f.onload = () => { try { const t = f.contentDocument.body.innerText; t.includes("reachable") ? ok(t) : no(new Error("empty")); } catch (e) { no(e); } }; document.body.appendChild(f); setTimeout(() => no(new Error("never loaded")), 400); });'
check_attempt "a web socket" "refused" 'return await new Promise((ok, no) => { const w = new WebSocket("ws://127.0.0.1:47832/"); w.onopen = () => ok("open"); w.onerror = () => no(new Error("blocked")); setTimeout(() => no(new Error("no answer")), 400); });'
check_attempt "a worker" "refused" 'return await new Promise((ok, no) => { const w = new Worker("panel.js"); w.onmessage = () => ok("started"); w.onerror = () => no(new Error("blocked")); w.postMessage(1); setTimeout(() => no(new Error("no answer, assumed blocked")), 300); });'
check_attempt "the bridge handler directly" "refused" 'if (!window.webkit.messageHandlers.tiriPlugin) throw new Error("not visible here"); return await window.webkit.messageHandlers.tiriPlugin.postMessage({method: "context"});'
check_attempt "the other handlers" "refused" 'const h = window.webkit.messageHandlers; if (!h.tiriWebPick && !h.tiriWebSelection) throw new Error("not visible here"); return "visible";'
check_attempt "replacing the API" "allowed: frozen" 'try { window.tiri = {}; tiri.run = 1; } catch (e) {} return Object.isFrozen(tiri) ? "frozen" : "writable";'
check_attempt "a command it declared" "allowed: ran allowed" 'return await tiri.run("allowed", {note: "first"});'
check_attempt "a command it never declared" "refused: forbidden is" 'return await tiri.run("forbidden");'
check_attempt "a full id it never declared" "refused" 'return await tiri.run("sealed.forbidden");'
check_attempt "a built-in it never declared" "refused" 'return await tiri.run("quit");'
check_attempt "the command of another plugin" "refused" 'return await tiri.run("surfaces.echo");'
check_attempt "a process it declared" "allowed" 'return JSON.stringify(await tiri.call("server", "go", {a: 1}));'
check_attempt "a process it never declared" "refused" 'return await tiri.call("other", "go");'
check_attempt "a setting of its own" "allowed" 'return await tiri.setSetting("note", "changed");'
check_attempt "a setting of Tiri" "refused" 'return await tiri.setSetting("theme", "dark");'
check_attempt "a file in the workspace" "allowed" "return await tiri.open('$PROJECT/a.tiridemo');"
check_attempt "a file outside it" "refused" 'return await tiri.open("/etc/hosts");'
check_attempt "a climb out of it" "refused" "return await tiri.open('$PROJECT/../../etc/hosts');"
check_attempt "reading with no file" "refused" 'return await tiri.read();'
check_attempt "a method that does not exist" "refused" 'return await new Promise((ok, no) => { const id = 9999; const h = (e) => { const r = JSON.parse(e.detail); if (r.id === id) { document.removeEventListener("tiri-plugin-reply", h); no(new Error(r.error)); } }; document.addEventListener("tiri-plugin-reply", h); document.dispatchEvent(new CustomEvent("tiri-plugin-request", {detail: JSON.stringify({id, method: "quit", params: "{}"})})); });'
check_attempt "a forged request" "refused" 'return await new Promise((ok, no) => { const id = 9998; const h = (e) => { const r = JSON.parse(e.detail); if (r.id === id) { document.removeEventListener("tiri-plugin-reply", h); r.error ? no(new Error(r.error)) : ok(r.result); } }; document.addEventListener("tiri-plugin-reply", h); document.dispatchEvent(new CustomEvent("tiri-plugin-request", {detail: JSON.stringify({id, method: "run", params: JSON.stringify({command: "forbidden"})})})); });'
expect "the declared command really ran" "allowed first" cat "$PLUGINS/../ran.txt"
lacks "the forbidden one never did" "forbidden" cat "$PLUGINS/../ran.txt"

# Navigation: none of these should leave the plugin.
pageval "$OPEN" "location.href = 'http://127.0.0.1:47832/data.txt'; 0" >/dev/null
sleep 0.4
expect "can't navigate away" "tiri-plugin://sealed" pageval "$OPEN" "location.href"
pageval "$OPEN" "window.open('http://127.0.0.1:47832/data.txt'); 0" >/dev/null
sleep 0.4
lacks "can't open a window" "47832" "$CLI" items

# What's stored stays with the plugin.
pageval "$OPEN" "localStorage.setItem('secret', 'kept'); 0" >/dev/null
expect "own storage works" "kept" pageval "$OPEN" "localStorage.getItem('secret')"
expect "it's a separate origin" "tiri-plugin://sealed" pageval "$OPEN" "location.origin === 'null' ? location.href : location.origin"

# Events from outside
expect "a process reaches its panels" "from the process" pageval "$OPEN" "JSON.stringify(window.events)"
expect "tiri plugin post reaches them" "Reached 1" "$CLI" plugin post sealed.open hello '{"from": "outside"}'
sleep 0.2
expect "and it arrived" "outside" pageval "$OPEN" "JSON.stringify(window.events)"
expect "showing it again tells it what's new" "" "$CLI" run sealed.show id=99
sleep 0.2
expect "new args arrive" '"99"' pageval "$OPEN" "JSON.stringify(window.events)"
expect "settings changes arrive" "second" bash -c "'$CLI' settings set plugin.sealed.note second >/dev/null; sleep 0.2; '$CLI' web eval 'JSON.stringify(window.events)' --item '$OPEN'"

# Asking the agent: words go in, and only a person sends them.
ASKED="$("$CLI" term --cwd "$WORK" --cmd "cat")"
sleep 0.6
"$CLI" focus "$ASKED" >/dev/null
sleep 0.2
"$CLI" read "$ASKED" --lines 5 >/dev/null
# `cat` isn't an agent, so a stand-in named as one shows what reaches an agent's input.
expect "no agent means it says so, and doesn't start one" "" pageval "$OPEN" "attempt('ask', () => tiri.ask('Hello agent')); 0"

# A locked-down panel: nothing was declared.
"$CLI" run sealed.showlocked >/dev/null
sleep 1
LOCKED="$("$CLI" items | awk -F'\t' '$4=="Locked Panel"{print $1}' | head -1)"
[ -n "$LOCKED" ] && ok "a panel with nothing allowed opens" || no "a panel with nothing allowed opens"
locked() {
  local name="$1" wanted="$2" body="$3"
  pageval "$LOCKED" "attempt('$name', async () => { $body }); 0" >/dev/null
  sleep 0.15
  local answer; answer="$(pageval "$LOCKED" "window.results['$name'] || ''")"
  if [[ "$answer" == "$wanted"* ]]; then ok "locked, $name: ${answer:0:64}"; else no "locked, $name: expected $wanted, got: $answer"; fi
}
locked "no network" "refused" "${netget//URL/\"http://127.0.0.1:47831/data.txt\"}"
locked "no commands" "refused" 'return await tiri.run("allowed");'
locked "no processes" "refused" 'return await tiri.call("server", "go");'
locked "no agent" "refused" 'return await tiri.ask("hi");'
locked "no quoting" "refused" 'return await tiri.quote("hi");'
locked "no comments" "refused" 'return await tiri.comment("hi");'
locked "no opening files" "refused" "return await tiri.open('$PROJECT/a.tiridemo');"
locked "shares the storage of its plugin" "allowed: kept" 'return localStorage.getItem("secret");'

# A panel survives a split and a Peek.
"$CLI" focus "$OPEN" >/dev/null
"$CLI" run splitRight >/dev/null
sleep 1
COUNT="$("$CLI" items | awk -F'\t' '$4=="Open Panel"' | wc -l | tr -d ' ')"
[ "$COUNT" = "2" ] && ok "a split makes a second panel" || no "a split makes a second panel: $COUNT"

# File viewers
printf 'first contents' > "$PROJECT/doc.sealed"
printf 'read only' > "$PROJECT/doc.readonly"
printf 'optional' > "$PROJECT/doc.opt"
VIEW="$("$CLI" open "$PROJECT/doc.sealed" --tab)"
sleep 1
expect "a viewer opens the file type" "first contents" "$CLI" web text --item "$VIEW"
shot plugin-viewer
expect "it's still a file item" "doc.sealed" "$CLI" items
expect "a viewer can read its file" "first contents" "$CLI" web eval 'window.loaded' --item "$VIEW"
"$CLI" web eval "window.w = 0; tiri.write('written by viewer').then(() => window.w = 1, (e) => window.w = e.message); 0" --item "$VIEW" >/dev/null
sleep 0.2
expect "a viewer with writes can save" "written by viewer" cat "$PROJECT/doc.sealed"
printf 'changed by an agent' > "$PROJECT/doc.sealed"
sleep 0.4
"$CLI" web eval "window.w = ''; tiri.write('would overwrite').catch((e) => window.w = e.message); 0" --item "$VIEW" >/dev/null
sleep 0.2
expect "but not over someone else's change" "changed since" "$CLI" web eval 'window.w' --item "$VIEW"
expect "which is still there" "changed by an agent" cat "$PROJECT/doc.sealed"
sleep 0.4
expect "it hears the file change" "1" "$CLI" web eval 'String(window.fileEvents > 0 ? 1 : 0)' --item "$VIEW"
RO="$("$CLI" open "$PROJECT/doc.readonly" --tab)"
sleep 1
"$CLI" web eval "window.w = ''; tiri.write('x').then(() => window.w = 'wrote', (e) => window.w = e.message); 0" --item "$RO" >/dev/null
sleep 0.2
expect "one without writes can't" "writes" "$CLI" web eval 'window.w' --item "$RO"
expect "and the file's untouched" "read only" cat "$PROJECT/doc.readonly"
OPT="$("$CLI" open "$PROJECT/doc.opt" --tab)"
sleep 0.6
refuses "an optional viewer waits to be asked" "isn't a web page" "$CLI" web text --item "$OPT"

# Everything goes away.
"$CLI" plugin disable sealed
sleep 0.8
expect "panels say it's off" "Open Panel" "$CLI" items
refuses "they're no longer pages" "isn't a web page" "$CLI" web text --item "$OPEN"
refuses "a viewer goes back to Tiri's own" "isn't a web page" "$CLI" web text --item "$VIEW"
shot plugin-panel-off
"$CLI" close "$LOCKED" >/dev/null 2>&1

# ---------------------------------------------------------------- reaching an agent
echo "== Words for an agent wait for a person"
mkdir -p "$WORK/bin"
postkey() { "$CLI" dev-key "$1" >/dev/null; }
# What Tiri recognizes as Claude Code, and which shows what reaches its input. A line it's been sent
# comes back as HEARD. Words only typed don't. It asks for pastes to be marked, as real agents do.
cat > "$WORK/bin/claude" <<'PY'
#!/usr/bin/env python3
# Raw input and marked pastes, as every real agent has: a line break in a paste is only text, and Return ends the input.
import os, sys, termios, tty
tty.setraw(0)
out = lambda text: (os.write(1, text.replace("\n", "\r\n").encode()), None)
out("\033[?2004hstand-in ready\n")
held, pasting, waiting = "", False, b""
while True:
    data = os.read(0, 4096)
    if not data: break
    waiting += data
    while waiting:
        if waiting.startswith(b"\033[200~"): pasting, waiting = True, waiting[6:]; continue
        if waiting.startswith(b"\033[201~"): pasting, waiting = False, waiting[6:]; continue
        if waiting[:1] == b"\033" and len(waiting) < 6: break
        byte, waiting = waiting[:1], waiting[1:]
        if byte in (b"\r", b"\n") and not pasting:
            out("\nHEARD:" + held + "\n")
            held = ""
        else:
            text = byte.decode("utf-8", "replace")
            held += text
            out(text)
PY
chmod +x "$WORK/bin/claude"
approve sealed && ok "sealed back on" || no "sealed back on"
sleep 0.4
AGENT="$("$CLI" term --cwd "$WORK" --cmd "$WORK/bin/claude")"
waits "the stand-in agent is up" "stand-in ready" "$CLI" read "$AGENT" --lines 5
"$CLI" run sealed.show >/dev/null
sleep 0.8
OPEN2="$("$CLI" items | awk -F'\t' '$4=="Open Panel"{print $1}' | head -1)"
# With nobody clicking or typing, a page asking gets nothing.
"$CLI" web eval "window.refused = ''; tiri.ask('Nobody asked for this').catch((e) => window.refused = e.message); 0" --item "$OPEN2" >/dev/null
sleep 0.3
expect "a page alone can't reach the agent" "just clicked or typed" "$CLI" web eval "window.refused" --item "$OPEN2"
lacks "and nothing arrived" "Nobody asked" "$CLI" read "$AGENT" --lines 5
"$CLI" web eval "window.refused = ''; tiri.quote('Nor this').catch((e) => window.refused = e.message); 0" --item "$OPEN2" >/dev/null
sleep 0.3
expect "nor can it quote" "just clicked or typed" "$CLI" web eval "window.refused" --item "$OPEN2"
# A real key, in the panel. Space is key 49.
"$CLI" focus "$OPEN2" >/dev/null
sleep 0.4
"$CLI" web eval "window.speak = () => tiri[window.say || 'ask'](window.words || 'Please look at this', 'My Source').catch((e) => window.refused = e.message); 0" --item "$OPEN2" >/dev/null
# A hidden window's page doesn't get keys of its own, so the page speaks right after the key: what's
# being tried is the app's own judgment of whether someone just acted in this panel.
postkey() { "$CLI" dev-key "$1" >/dev/null; sleep 0.15; "$CLI" web eval "window.speak(); 0" --item "$OPEN2" >/dev/null; }
postkey 49
waits "a key in the panel reaches the agent's input" "Please look at this" "$CLI" read "$AGENT" --lines 5
sleep 0.5
lacks "and isn't sent" "HEARD:" "$CLI" read "$AGENT" --lines 5
"$CLI" send "$AGENT" "$(printf '\r')" >/dev/null
waits "until a person presses Return" "HEARD:" "$CLI" read "$AGENT" --lines 5
# Line breaks and an attempt to end the paste early stay words.
"$CLI" focus "$OPEN2" >/dev/null
sleep 1.1
"$CLI" web eval "window.words = 'one\x1b[201~\ntouch /tmp/tiri-plugin-pwned\n'; 0" --item "$OPEN2" >/dev/null
postkey 49
sleep 0.7
[ ! -e /tmp/tiri-plugin-pwned ] && ok "a paste can't be ended early" || no "a paste can't be ended early"
lacks "and no line of it has been sent" "HEARD:one" "$CLI" read "$AGENT" --lines 6
"$CLI" send "$AGENT" "$(printf '\r')" >/dev/null
"$CLI" focus "$OPEN2" >/dev/null
sleep 1.1
"$CLI" web eval "window.say = 'quote'; window.words = 'Words on the page'; 0" --item "$OPEN2" >/dev/null
postkey 49
waits "a quote says where it's from" "My Source" "$CLI" read "$AGENT" --lines 8
lacks "and isn't sent" "HEARD:From" "$CLI" read "$AGENT" --lines 8
"$CLI" send "$AGENT" "$(printf '\r')" >/dev/null
# An agent waiting on an answer doesn't take words that the next Return would send in reply.
"$CLI" focus "$OPEN2" >/dev/null
sleep 1.1
"$CLI" notify needs-input --item "$AGENT" --message "Allow this?" >/dev/null
"$CLI" web eval "window.say = 'ask'; window.words = 'Not while it is asking'; 0" --item "$OPEN2" >/dev/null
postkey 49
sleep 0.5
lacks "words wait while an agent is asking something" "Not while it is asking" "$CLI" read "$AGENT" --lines 8
"$CLI" notify working --item "$AGENT" >/dev/null
# Something that doesn't hold pastes could run them, so it isn't given any.
"$CLI" close "$AGENT" >/dev/null
cat > "$WORK/bin/codex" <<'SH'
#!/bin/sh
printf 'bare ready\n'
while IFS= read -r line; do printf 'HEARD:%s\n' "$line"; done
SH
chmod +x "$WORK/bin/codex"
BARE="$("$CLI" term --cwd "$WORK" --cmd "$WORK/bin/codex")"
waits "a program with no paste mode is up" "bare ready" "$CLI" read "$BARE" --lines 5
"$CLI" focus "$OPEN2" >/dev/null
sleep 1.1
"$CLI" web eval "window.words = 'echo would-have-run'; 0" --item "$OPEN2" >/dev/null
postkey 49
sleep 0.6
lacks "it's given nothing" "would-have-run" "$CLI" read "$BARE" --lines 5
"$CLI" close "$BARE" >/dev/null
AGENT="$("$CLI" term --cwd "$WORK" --cmd "$WORK/bin/claude")"
waits "the stand-in is back" "stand-in ready" "$CLI" read "$AGENT" --lines 5
"$CLI" web eval "window.refused = ''; tiri.comment('A note about this panel'); 0" --item "$OPEN2" >/dev/null
waits "a comment joins the review" "A note about this panel" "$CLI" review
"$CLI" review clear >/dev/null
"$CLI" select "$OPEN2" "Selectable" >/dev/null
sleep 0.3
"$CLI" focus "$OPEN2" >/dev/null
sleep 0.2
"$CLI" run addToAgent >/dev/null
waits "Quote in Agent works on a panel's page" "Selectable" "$CLI" read "$AGENT" --lines 8
"$CLI" send "$AGENT" "$(printf '\r')" >/dev/null
"$CLI" close "$AGENT" >/dev/null

# A page clicking its own link would carry anything anywhere.
"$CLI" web eval "const a = document.createElement('a'); a.href = 'http://127.0.0.1:47832/?stolen=1'; document.body.appendChild(a); a.click(); 0" --item "$OPEN2" >/dev/null
sleep 0.5
lacks "a page can't click its own way out" "stolen" "$CLI" items
expect "and it's still where it was" "tiri-plugin://sealed" "$CLI" web eval "location.href" --item "$OPEN2"
"$CLI" web eval "window.r = ''; try { const c = new RTCPeerConnection(); window.r = 'open'; } catch (e) { window.r = 'closed: ' + e.message; } 0" --item "$OPEN2" >/dev/null
expect "no peer connections" "closed" "$CLI" web eval "window.r" --item "$OPEN2"
"$CLI" web eval "window.r = ''; const f = document.createElement('iframe'); document.body.appendChild(f); try { new f.contentWindow.RTCPeerConnection(); window.r = 'open'; } catch (e) { window.r = 'closed: ' + e.message; } f.remove(); 0" --item "$OPEN2" >/dev/null
expect "not through an empty frame either" "closed" "$CLI" web eval "window.r" --item "$OPEN2"

# Programs that misbehave.
mkdir -p "$PLUGINS/unruly/.tiri-plugin" "$PLUGINS/unruly/bin" "$PLUGINS/unruly/panel"
cat > "$PLUGINS/unruly/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "unruly", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "commands": [
    { "id": "leaves", "title": "Leaves Something", "exec": ["bin/leaves"], "show": "none" },
    { "id": "ignores", "title": "Ignores Being Asked", "exec": ["bin/ignores"], "timeout": 1, "show": "none" },
    { "id": "long", "title": "Long", "exec": ["bin/long"], "timeout": 120, "show": "none" },
    { "id": "closes", "title": "Closes Its Input", "process": "closer", "method": "x" },
    { "id": "deaf", "title": "Reads Nothing", "process": "deaf", "method": "x" },
    { "id": "loud", "title": "Very Loud", "exec": ["bin/loud"], "show": "none" },
    { "id": "t", "title": "Term", "terminal": "bin/marker ${args.x}" },
    { "id": "asks", "title": "Asks", "ask": "${args.x}" },
    { "id": "show", "title": "Show", "panel": "main" }
  ],
  "panels": [{ "id": "main", "title": "Unruly Panel", "entry": "panel/index.html", "allow": { "commands": ["asks"] } }],
  "processes": [{ "id": "closer", "exec": ["bin/closer"] }, { "id": "deaf", "exec": ["bin/deaf"] }]
}
JSON
printf '<!doctype html><meta charset="utf-8"><title>U</title><h1>Unruly</h1>\n' > "$PLUGINS/unruly/panel/index.html"
printf '#!/bin/sh\nsleep 300 &\necho started\n' > "$PLUGINS/unruly/bin/leaves"
printf "#!/usr/bin/env python3\nimport signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(300)\n" > "$PLUGINS/unruly/bin/ignores"
printf '#!/bin/sh\nexec sleep 301\n' > "$PLUGINS/unruly/bin/long"
printf '#!/bin/sh\nexec <&-\nsleep 302\n' > "$PLUGINS/unruly/bin/closer"
printf '#!/bin/sh\nexec sleep 303\n' > "$PLUGINS/unruly/bin/deaf"
printf "#!/usr/bin/env python3\nimport sys\nsys.stdout.write('x' * 30000000)\nsys.stderr.write('y' * 30000000)\n" > "$PLUGINS/unruly/bin/loud"
printf '#!/bin/sh\necho ran-with-settings=[$TIRI_PLUGIN_SETTINGS] "$@"\n' > "$PLUGINS/unruly/bin/marker"
chmod +x "$PLUGINS/unruly/bin/"*
"$CLI" plugin reload >/dev/null
approve unruly && ok "unruly on" || no "unruly on"
expect "a command that leaves something behind still finishes" "started" "$CLI" run unruly.leaves
sleep 0.4
[ "$(pgrep -f 'sleep 300' | wc -l | tr -d ' ')" = "0" ] && ok "and what it left is stopped" || no "and what it left is stopped"
refuses "a program ignoring its time is stopped" "longer than" "$CLI" run unruly.ignores
waits "and is told, not asked, the second time" "gone" bash -c "pgrep -f 'plugins/unruly/bin/ignores' >/dev/null || echo gone"
expect "output is bounded, and the app's alive" "pong" bash -c "'$CLI' run unruly.loud --json >/dev/null; '$CLI' ping"
"$CLI" run unruly.long >/dev/null 2>&1 &
RUNNING_CALL=$!
sleep 0.4
pgrep -f 'sleep 301' >/dev/null && ok "a long command is running" || no "a long command is running"
"$CLI" run unruly.closes >/dev/null 2>&1 &
CLOSES_CALL=$!
sleep 0.5
expect "writing to a program that closed its input doesn't take the app down" "pong" "$CLI" ping
"$CLI" run unruly.closes >/dev/null 2>&1 &
sleep 0.2
expect "nor the second time" "pong" "$CLI" ping
# A question far bigger than a pipe holds, to something not reading.
"$CLI" run unruly.deaf "big=$(python3 -c "print('z' * 300000)")" >/dev/null 2>&1 &
sleep 0.5
expect "a program not reading can't freeze the app" "pong" "$CLI" ping
# A panel's command that speaks to the agent follows the same rules.
"$CLI" run unruly.show >/dev/null
sleep 0.8
UNRULY="$("$CLI" items | awk -F'\t' '$4=="Unruly Panel"{print $1}' | head -1)"
"$CLI" web eval "window.r = ''; tiri.run('asks', {x: 'smuggled'}).catch((e) => window.r = e.message); 0" --item "$UNRULY" >/dev/null
sleep 0.3
expect "a command can't carry a panel past what it wasn't allowed" "agent" "$CLI" web eval "window.r" --item "$UNRULY"
"$CLI" plugin disable unruly
sleep 2.6
for pattern in 'sleep 301' 'sleep 302' 'sleep 303'; do
  [ "$(pgrep -f "$pattern" | wc -l | tr -d ' ')" = "0" ] && ok "turning it off stops: $pattern" || no "turning it off stops: $pattern"
done
wait $RUNNING_CALL $CLOSES_CALL 2>/dev/null

# What npm installs isn't hashed, but it's watched.
printf '{"name": "unruly", "version": "1.0.0"}\n' > "$PLUGINS/unruly/package.json"
printf '{"name": "unruly", "version": "1.0.0", "lockfileVersion": 3, "requires": true, "packages": {"": {"name": "unruly", "version": "1.0.0"}}}\n' > "$PLUGINS/unruly/package-lock.json"
"$CLI" plugin reload >/dev/null
approve unruly && ok "it sets up from a lockfile" || no "it sets up from a lockfile"
mkdir -p "$PLUGINS/unruly/node_modules/left-pad"
echo 'evil()' > "$PLUGINS/unruly/node_modules/left-pad/index.js"
"$CLI" plugin reload >/dev/null
waits "what's installed changing turns it off" "unruly	changed" "$CLI" plugin
expect "and says so" "dependencies" "$CLI" plugin
"$CLI" plugin disable unruly
rm -rf "$PLUGINS/unruly/node_modules" "$PLUGINS/unruly/package.json" "$PLUGINS/unruly/package-lock.json"

# A terminal command after a relaunch doesn't come back.
"$CLI" plugin reload >/dev/null
approve unruly >/dev/null
"$CLI" run unruly.t "x=$(printf 'a\003b')" >/dev/null
sleep 0.8
PLUGTERM="$("$CLI" items | awk -F'\t' '$4=="Term"{print $1}' | head -1)"
waits "a terminal command's values lose their control characters" "ran-with-settings=[] ab" "$CLI" read "$PLUGTERM" --lines 5
lacks "and what's saved has no settings in it" 'TIRI_PLUGIN_SETTINGS' bash -c "grep -l 'TIRI_PLUGIN_SETTINGS' '$TIRI_HOME'/*.json || true"
"$CLI" plugin disable unruly
rm -rf "$PLUGINS/unruly"

# A Peek, and Open as Tab.
cat > "$PLUGINS/sealed/.tiri-plugin/plugin.json.new" <<'JSON'
JSON
rm -f "$PLUGINS/sealed/.tiri-plugin/plugin.json.new"
mkdir -p "$PLUGINS/peeker/.tiri-plugin"
cat > "$PLUGINS/peeker/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "peeker", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "commands": [{ "id": "show", "title": "Peek", "panel": "main", "open": "peek" }, { "id": "right", "title": "Right", "panel": "side", "open": "right" }],
  "panels": [{ "id": "main", "title": "Peek Panel", "entry": "p.html" }, { "id": "side", "title": "Side Panel", "entry": "p.html" }],
  "statusBar": [{ "id": "only", "text": "Peeker" }] }
JSON
printf '<!doctype html><meta charset="utf-8"><title>Peek</title><h1>In a Peek</h1>\n' > "$PLUGINS/peeker/p.html"
"$CLI" plugin reload >/dev/null
approve peeker && ok "peeker on" || no "peeker on"
"$CLI" run peeker.show >/dev/null
sleep 0.6
expect "a panel floats as a Peek" "(peek)" bash -c "'$CLI' items | grep 'Peek Panel'"
shot plugin-panel-peek
"$CLI" run promotePeek >/dev/null
sleep 0.4
lacks "and becomes a tab" "(peek)" bash -c "'$CLI' items | grep 'Peek Panel'"
"$CLI" run peeker.right >/dev/null
sleep 0.5
expect "or opens to the side" "Side Panel" "$CLI" items

# A relaunch brings it back, as the page it was.
SIDE="$("$CLI" items | awk -F'\t' '$4=="Side Panel"{print $1}' | head -1)"
"$CLI" quit >/dev/null 2>&1
sleep 1
(cd "$REPO" && scripts/dev-app.sh run "$NAME") >/dev/null 2>&1
waits "after a relaunch, plugins are on again" "peeker	on" "$CLI" plugin
"$CLI" focus "$SIDE" >/dev/null
sleep 1
expect "and a panel comes back as its page" "In a Peek" "$CLI" web text --item "$SIDE"
if [ -n "${PLUGTERM:-}" ]; then
  "$CLI" focus "$PLUGTERM" >/dev/null
  sleep 1
  lacks "a plugin's terminal command doesn't come back by itself" "bin/marker" "$CLI" read "$PLUGTERM" --lines 5
fi

# Removing: it asks, and then everything's gone.
"$CLI" plugin remove peeker >/dev/null
waits "removing asks" "Remove" "$CLI" dev-plugin-question
expect "and no means no" "peeker" bash -c "'$CLI' dev-plugin-answer no >/dev/null; sleep 0.2; '$CLI' plugin"
"$CLI" plugin remove peeker >/dev/null
waits "asks again" "Remove" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer yes >/dev/null
goes "yes removes it" "peeker" "$CLI" plugin
[ ! -d "$PLUGINS/peeker" ] && ok "its folder is gone" || no "its folder is gone"
expect "a tab left behind says so" "Side Panel" "$CLI" items
refuses "and isn't a page" "isn't a web page" "$CLI" web text --item "$SIDE"
"$CLI" close "$SIDE" >/dev/null

# A language server from a plugin, which answers.
mkdir -p "$PLUGINS/served/.tiri-plugin" "$PLUGINS/served/bin"
cat > "$PLUGINS/served/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "served", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "languages": [{ "id": "tirisrv", "name": "Tiri Served", "extensions": ["tirisrv"],
                  "server": { "commands": [["bin/lsp"]], "installHint": "It comes with this plugin" } }] }
JSON
cat > "$PLUGINS/served/bin/lsp" <<'PY'
#!/usr/bin/env python3
import json, sys
def send(message):
    body = json.dumps(message).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()
while True:
    length = 0
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line.strip() == b"": break
        if line.lower().startswith(b"content-length:"): length = int(line.split(b":")[1])
    message = json.loads(sys.stdin.buffer.read(length))
    method = message.get("method")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {"textDocumentSync": 1}}})
    elif method == "textDocument/didOpen":
        uri = message["params"]["textDocument"]["uri"]
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": uri, "diagnostics": [
            {"range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}}, "severity": 1, "message": "served by a plugin"}]}})
    elif "id" in message:
        send({"jsonrpc": "2.0", "id": message["id"], "result": None})
PY
chmod +x "$PLUGINS/served/bin/lsp"
"$CLI" plugin reload >/dev/null
approve served && ok "served on" || no "served on"
printf 'bad code\n' > "$PROJECT/x.tirisrv"
"$CLI" open "$PROJECT/x.tirisrv" --tab >/dev/null
expect "the server is in the list" "Tiri Served" "$CLI" languages
SERVERS() { pgrep -f "plugins/served/bin/lsp" | wc -l | tr -d ' '; }
expect "and answers" "served by a plugin" "$CLI" diagnostics "$PROJECT/x.tirisrv"
[ "$(SERVERS)" = "1" ] && ok "one is running" || no "one is running: $(SERVERS)"
"$CLI" plugin disable served
waits "turning it off stops its server, asking and then insisting" "0" SERVERS
lacks "and it's out of the list" "Tiri Served" "$CLI" languages

# ---------------------------------------------------------------- handing one to someone
echo "== Export and import"
OUT="$WORK/out"
mkdir -p "$OUT"
"$CLI" plugin new shared-one >/dev/null
printf 'TOKEN=abc\n' > "$PLUGINS/shared-one/.env"
"$CLI" plugin reload >/dev/null
expect "export says what it wrote" "shared-one-0.1.0.tiriplugin" "$CLI" plugin export shared-one --to "$OUT"
expect "and what stayed behind" ".env" "$CLI" plugin export shared-one --to "$OUT"
FILE="$OUT/shared-one-0.1.0.tiriplugin"
expect "it's our own format" "tiri-package.json" unzip -Z1 "$FILE"
lacks "the secret isn't in it" ".env" unzip -Z1 "$FILE"
rm "$PLUGINS/shared-one/.env"
"$CLI" plugin reload >/dev/null
"$CLI" dev-plugin-import "$FILE" >/dev/null
waits "the very same file changes nothing" "same shared-one" "$CLI" dev-plugin-question
"$CLI" plugin remove shared-one >/dev/null
waits "removing it asks" "Remove" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer yes >/dev/null
goes "and it's gone" "shared-one" "$CLI" plugin

"$CLI" dev-plugin-import "$FILE" >/dev/null
waits "importing asks to turn it on, with what it adds" "Turn on Shared One" "$CLI" dev-plugin-question
expect "it arrived off" "shared-one	off" "$CLI" plugin
if [ -x "$PLUGINS/shared-one/bin/hello" ]; then ok "its programs are still programs"; else no "bin/hello lost its execute bit"; fi
"$CLI" dev-plugin-answer yes >/dev/null
waits "yes turns it on" "shared-one	on" "$CLI" plugin
expect "and it runs" "Hello from shared-one" "$CLI" run shared-one.hello

# A double-click in Finder is an open event, sent here to this copy and nothing else.
"$CLI" plugin disable shared-one >/dev/null
"$CLI" plugin remove shared-one >/dev/null
waits "removing it asks again" "Remove" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer yes >/dev/null
goes "gone again" "shared-one" "$CLI" plugin
open -g -a "$APP" "$FILE"
waits "opening the file imports it" "Turn on Shared One" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer no >/dev/null
expect "and no leaves it off" "shared-one	off" "$CLI" plugin

# A new version of something you have.
python3 - "$PLUGINS/shared-one/.tiri-plugin/plugin.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
manifest["version"] = "0.2.0"
json.dump(manifest, open(path, "w"))
PY
"$CLI" plugin export shared-one --to "$OUT" >/dev/null
python3 - "$PLUGINS/shared-one/.tiri-plugin/plugin.json" <<'PY'
import json, sys
path = sys.argv[1]
manifest = json.load(open(path))
manifest["version"] = "0.1.0"
json.dump(manifest, open(path, "w"))
PY
"$CLI" plugin reload >/dev/null
"$CLI" dev-plugin-import "$OUT/shared-one-0.2.0.tiriplugin" >/dev/null
waits "a new version asks first" "Replace Shared One 0.1.0 with 0.2.0" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer no >/dev/null
sleep 0.5
expect "no keeps what's there" "0.1.0" cat "$PLUGINS/shared-one/.tiri-plugin/plugin.json"
"$CLI" dev-plugin-import "$OUT/shared-one-0.2.0.tiriplugin" >/dev/null
waits "asked again" "Replace Shared One" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer yes >/dev/null
waits "yes brings it in, and asks to turn it on" "Turn on Shared One" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer no >/dev/null
expect "the new one is there" "0.2.0" cat "$PLUGINS/shared-one/.tiri-plugin/plugin.json"

"$CLI" dev-plugin-export shared-one "$OUT/from-the-app.tiriplugin" >/dev/null
waits "the app's Export button writes the same thing" "exported shared-one" "$CLI" dev-plugin-question
expect "with the header in it" "tiri-package.json" unzip -Z1 "$OUT/from-the-app.tiriplugin"

# What someone might hand you instead.
mkdir -p "$WORK/github"
cp -R "$PLUGINS/shared-one" "$WORK/github/shared-one-main"
(cd "$WORK/github" && zip -q -r "$OUT/download.zip" shared-one-main)
"$CLI" plugin remove shared-one >/dev/null
waits "out of the way" "Remove" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer yes >/dev/null
goes "gone once more" "shared-one" "$CLI" plugin
"$CLI" dev-plugin-import "$OUT/download.zip" >/dev/null
waits "a zip from GitHub works" "Turn on Shared One" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer no >/dev/null
"$CLI" dev-plugin-import "$PLUGINS/shared-one" >/dev/null
waits "its own folder isn't imported over itself" "same shared-one" "$CLI" dev-plugin-question
mkdir -p "$WORK/vsix/extension"
printf '{ "name": "shared-lang", "version": "1.0.0", "contributes": { "languages": [{ "id": "sharedlang", "extensions": [".sharedlang"] }] } }' > "$WORK/vsix/extension/package.json"
(cd "$WORK/vsix" && zip -q -r "$OUT/shared-lang.vsix" extension)
"$CLI" dev-plugin-import "$OUT/shared-lang.vsix" >/dev/null
waits "a VS Code .vsix works from the same button" "Turn on shared-lang" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer no >/dev/null

# What someone might hand you to do harm.
refused() { # name, file, words
  "$CLI" dev-plugin-import "$2" >/dev/null
  waits "$1" "$3" "$CLI" dev-plugin-question
}
printf 'not a zip' > "$OUT/junk.tiriplugin"
refused "junk is refused" "$OUT/junk.tiriplugin" "won't open"
HARM="$WORK/tiri-climbed-out"
python3 - "$OUT/climb.zip" "$HARM" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../../../../../../../../../.." + sys.argv[2], "pwned")
    z.writestr("x/.tiri-plugin/plugin.json", '{"name":"climb","version":"1.0.0","apiVersion":1}')
PY
refused "a file climbing out is refused" "$OUT/climb.zip" "outside itself"
if [ -e "$HARM" ]; then no "it got out"; else ok "and nothing got out"; fi
python3 - "$OUT/through.zip" "$WORK" <<'PY'
import stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    link = zipfile.ZipInfo("x/way")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    z.writestr(link, sys.argv[2])
    z.writestr("x/way/written-through", "pwned")
    z.writestr("x/.tiri-plugin/plugin.json", '{"name":"through","version":"1.0.0","apiVersion":1}')
PY
refused "writing through a link is refused" "$OUT/through.zip" "inside a link"
if [ -e "$WORK/written-through" ]; then no "it wrote through"; else ok "and nothing was written"; fi
mkdir -p "$WORK/tamper"
(cd "$WORK/tamper" && unzip -q "$FILE" && printf '#!/bin/sh\necho changed\n' > plugin/bin/hello && zip -q -r "$OUT/tampered.tiriplugin" tiri-package.json plugin)
refused "a file changed after export is refused" "$OUT/tampered.tiriplugin" "changed after it was exported"
"$CLI" plugin disable shared-one >/dev/null 2>&1
rm -rf "$PLUGINS/shared-one" "$PLUGINS/shared-lang"
"$CLI" plugin reload >/dev/null

# ---------------------------------------------------------------- being written
echo "== Being built"
"$CLI" term --cmd "'$CLI' plugin new built-one; sleep 30" >/dev/null
waits "made from a terminal in Tiri, it's being built" "built-one" "$CLI" dev-plugin-question
"$CLI" plugin enable built-one >/dev/null
waits "asking to turn it on is the end of that" "Turn on" "$CLI" dev-plugin-question
lacks "and it isn't being built any more" "\"built-one\"" "$CLI" dev-plugin-question
"$CLI" dev-plugin-answer no >/dev/null
rm -rf "$PLUGINS/built-one"
"$CLI" plugin reload >/dev/null

# ---------------------------------------------------------------- what can't happen at all
echo "== What can't happen"
mkdir -p "$PLUGINS/fromrepo/.tiri-plugin" "$PROJECT/.tiri-plugin"
cat > "$PROJECT/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "cloned", "version": "1.0.0", "apiVersion": 1, "commands": [{ "id": "x", "title": "X", "exec": ["sh", "-c", "touch /tmp/tiri-pwned"] }] }
JSON
"$CLI" plugin reload >/dev/null
lacks "a plugin in a cloned repo isn't even seen" "cloned" "$CLI" plugin
rm -rf "$PLUGINS/fromrepo"
expect "tiri --skill tells agents about plugins" "tiri plugin api" "$CLI" --skill
mkdir -p "$PLUGINS/skilled/.tiri-plugin" "$PLUGINS/skilled/skills/cooking"
cat > "$PLUGINS/skilled/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "skilled", "title": "Skilled", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0", "agent": { "claude": "." } }
JSON
printf -- '---\nname: cooking\ndescription: How to cook\n---\nBoil it.\n' > "$PLUGINS/skilled/skills/cooking/SKILL.md"
"$CLI" plugin reload >/dev/null
lacks "its skills aren't listed while it's off" "cooking" "$CLI" --skill
PARTS="$TIRI_HOME/agent-plugins/claude"
approve skilled && ok "skilled on" || no "skilled on"
expect "and are once it's on" "skills/cooking/SKILL.md" "$CLI" --skill
waits "Claude Code's part is a copy of what was approved" "SKILL.md" ls "$PARTS/skilled/skills/cooking"
expect "with what Claude Code needs to see it" "skilled" cat "$PARTS/skilled/.claude-plugin/plugin.json"
printf 'Changed by someone.\n' >> "$PLUGINS/skilled/skills/cooking/SKILL.md"
waits "an edit takes it away" "skilled	changed" "$CLI" plugin
goes "from where agents look" "skills" bash -c "ls '$PARTS/skilled' 2>/dev/null"
"$CLI" plugin disable skilled
rm -rf "$PLUGINS/skilled"
expect "the API is there to read" "window.tiri" "$CLI" plugin api

# ---------------------------------------------------------------- the speed budgets
echo "== Speed"
kill $ALLOWED_SERVER $FORBIDDEN_SERVER 2>/dev/null
# Fifty installed, with the most common: mostly off, some on, one with a panel to open.
for n in $(seq 1 50); do
  folder="$PLUGINS/load$n"
  mkdir -p "$folder/.tiri-plugin" "$folder/panel" "$folder/bin"
  cat > "$folder/.tiri-plugin/plugin.json" <<JSON
{ "name": "load$n", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "commands": [{ "id": "go", "title": "Go $n", "exec": ["bin/go"], "show": "none" }, { "id": "show", "title": "Show $n", "panel": "main" }],
  "panels": [{ "id": "main", "title": "Load $n", "entry": "panel/index.html" }],
  "settings": [{ "key": "x", "title": "X", "type": "text" }],
  "languages": [{ "id": "load$n", "name": "Load $n", "extensions": ["load$n"] }] }
JSON
  printf '<!doctype html><meta charset="utf-8"><title>Load</title><h1>Load %s</h1>\n' "$n" > "$folder/panel/index.html"
  printf '#!/bin/sh\necho hi\n' > "$folder/bin/go"
  chmod +x "$folder/bin/go"
done
"$CLI" plugin reload >/dev/null
waits "fifty plugins found" "load50	off" "$CLI" plugin
if [ -n "${TIRI_BUDGETS:-}" ]; then
  # The real numbers, from a release build: launching with them, and opening a panel.
  for n in $(seq 1 10); do approve "load$n" >/dev/null; done
  "$CLI" quit >/dev/null 2>&1
  sleep 0.8
  (cd "$REPO" && scripts/dev-app.sh run "$NAME") >/dev/null 2>&1
  sleep 1.5
  budget() { # name, field, target
    local value; value="$("$CLI" perf --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result'].get('$2', 1e9))")"
    if python3 -c "import sys; sys.exit(0 if $value < $3 else 1)"; then ok "$1: $value ms, under $3"; else no "$1: $value ms, over $3"; fi
  }
  budget "cold launch to window, with 50 plugins" launchMs 500
  budget "reading 50 plugins, off the main thread, which launch does not wait for" pluginScanMs 150
  times=""
  for n in 1 2 3 4 5; do
    "$CLI" run "load$n.show" >/dev/null
    sleep 0.6
    times="$times $("$CLI" perf --json | python3 -c "import json,sys; print(json.load(sys.stdin)['result'].get('lastOpenMs', 1e9))")"
  done
  echo "      panel opens:$times"
  budget "open a panel" lastOpenMs 100
fi
SCAN="$("$CLI" perf --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("pluginScanMs", -1))')"
echo "      reading what's installed took ${SCAN} ms"
rm -rf "$PLUGINS"/load*
"$CLI" plugin reload >/dev/null

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
