#!/bin/bash
# Plugins on a workspace on a server: programs run there, and a server can't manage or drive them.
#   TIRI_E2E_HOST=<host> scripts/dev-app.sh start e2eplugr && TIRI_E2E_HOST=<host> scripts/e2e-plugins-remote.sh e2eplugr
# TIRI_SSH_CONFIG reaches a private server with a config of its own. The test copy needs it too.
set -u
NAME="${1:-e2eplugr}"
HOST="${TIRI_E2E_HOST:?TIRI_E2E_HOST names the server}"
ROOT="${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}"
DIR="$ROOT/$NAME"
APP="$DIR/TiriDev.app"
CLI="$APP/Contents/Resources/bin/tiri"
[ -x "$CLI" ] || { echo "No test copy called $NAME." >&2; exit 1; }
export TIRI_HOME="$DIR/home" TIRI_CONFIG_HOME="$DIR/config" TIRI_SOCKET="/tmp/tiri-dev-$NAME.sock"
PLUGINS="$TIRI_CONFIG_HOME/plugins"
WORK="$(mktemp -d)"
cd "$WORK"
SSH=(ssh); [ -n "${TIRI_SSH_CONFIG:-}" ] && SSH=(ssh -F "$TIRI_SSH_CONFIG")
SERVER_DIR="tiri-e2e-plugins-$$"
trap 'rm -rf "$WORK"; "${SSH[@]}" "$HOST" "rm -rf ~/$SERVER_DIR" 2>/dev/null' EXIT

passed=0; failed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
no() { failed=$((failed + 1)); echo "FAIL  $1"; }
expect() { local name="$1" needle="$2"; shift 2; local output; output="$("$@" 2>&1)"
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: expected \"$needle\" in: $output"; fi; }
lacks() { local name="$1" needle="$2"; shift 2; local output; output="$("$@" 2>&1)"
  if [[ "$output" != *"$needle"* ]]; then ok "$name"; else no "$name: found \"$needle\" in: $output"; fi; }
refuses() { local name="$1" needle="$2"; shift 2; local output; if output="$("$@" 2>&1)"; then no "$name: not refused: $output"; return; fi
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: refused, but said: $output"; fi; }
waits() { local name="$1" needle="$2"; shift 2; local output=""; for _ in $(seq 1 150); do output="$("$@" 2>&1)"
    if [[ "$output" == *"$needle"* ]]; then ok "$name"; return; fi; sleep 0.1; done; no "$name: expected \"$needle\" in: $output"; }
approve() { "$CLI" plugin enable "$1" >/dev/null; for _ in $(seq 1 40); do "$CLI" dev-plugin-question | grep -q '"question" *: *"[^"]' && break; sleep 0.05; done
  "$CLI" dev-plugin-answer yes >/dev/null; for _ in $(seq 1 60); do "$CLI" plugin | grep -q "^$1	on" && return 0; sleep 0.1; done; return 1; }

mkdir -p "$PLUGINS/where/.tiri-plugin" "$PLUGINS/where/bin" "$PLUGINS/where/panel"
cat > "$PLUGINS/where/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "where", "title": "Where", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "commands": [
    { "id": "here", "title": "Where Am I", "exec": ["bin/where", "${file}", "${args.word}"], "show": "none" },
    { "id": "mac", "title": "On the Mac", "exec": ["bin/where"], "where": "mac", "show": "none" },
    { "id": "ask", "title": "Ask the Process", "process": "server", "method": "where" },
    { "id": "term", "title": "In a Terminal", "terminal": "bin/where" },
    { "id": "show", "title": "Show", "panel": "main" }
  ],
  "panels": [{ "id": "main", "title": "Where Panel", "entry": "panel/index.html", "allow": { "commands": ["here"] } },
             { "id": "viewer", "title": "Where View", "entry": "panel/view.html" }],
  "viewers": [{ "panel": "viewer", "patterns": ["*.whereview"], "writes": true }],
  "sidebar": [{ "id": "list", "title": "Where List", "provider": { "exec": ["bin/tree"] } }],
  "processes": [{ "id": "server", "exec": ["bin/server"] }]
}
JSON
printf '<!doctype html><meta charset="utf-8"><title>W</title><h1>Where</h1>\n' > "$PLUGINS/where/panel/index.html"
printf '<!doctype html><meta charset="utf-8"><title>V</title><h1 id="t">View</h1><script src="view.js"></script>\n' > "$PLUGINS/where/panel/view.html"
printf "tiri.read().then((text) => { document.getElementById('t').textContent = text; });\n" > "$PLUGINS/where/panel/view.js"
cat > "$PLUGINS/where/bin/where" <<'SH'
#!/bin/sh
echo "ssh=${SSH_CONNECTION:+yes} dir=$TIRI_PLUGIN_DIR folder=$TIRI_WORKSPACE_FOLDER file=$1 word=$2 pwd=$PWD"
SH
cat > "$PLUGINS/where/bin/tree" <<'SH'
#!/bin/sh
echo "{\"items\": [{\"title\": \"ssh=${SSH_CONNECTION:+yes}\"}]}"
SH
cat > "$PLUGINS/where/bin/server" <<'SH'
#!/bin/sh
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  printf '{"id":%s,"result":"process ssh=%s pid=%s"}\n' "$id" "${SSH_CONNECTION:+yes}" "$$"
done
SH
chmod +x "$PLUGINS/where/bin/"*
"$CLI" plugin reload >/dev/null
approve where && ok "turned on" || no "turned on"

"${SSH[@]}" "$HOST" "mkdir -p ~/$SERVER_DIR && printf 'on the server' > ~/$SERVER_DIR/doc.whereview && printf 'x' > ~/$SERVER_DIR/a.txt"
"$CLI" remote connect "$HOST" "~/$SERVER_DIR" >/dev/null && ok "connected" || no "connected"
waits "the server is ready" "Connected" "$CLI" remote
sleep 1

expect "a program runs on the server" "ssh=yes" "$CLI" run where.here word=sky
expect "from a copy there, not the Mac's folder" "/.tiri/plugins/where-" "$CLI" run where.here word=sky
lacks "and its paths are the server's" "tiri-dev" "$CLI" run where.here word=sky
expect "in the workspace's folder" "pwd=" "$CLI" run where.here word=sky
expect "a value stays one word over ssh" "word=two words" "$CLI" run where.here "word=two words"
lacks "where mac means the Mac" "ssh=yes" "$CLI" run where.mac
expect "and from the Mac's folder" "config/plugins/where" "$CLI" run where.mac
expect "a process runs on the server" "process ssh=yes" "$CLI" run where.ask
FIRST="$("$CLI" run where.ask)"
SECOND="$("$CLI" run where.ask)"
[ "$FIRST" = "$SECOND" ] && ok "and stays up between questions" || no "and stays up between questions: $FIRST / $SECOND"
"$CLI" run where.term >/dev/null
sleep 0.5
TERM_ITEM="$("$CLI" items | awk -F'\t' '$4=="In a Terminal"{print $1}' | head -1)"
waits "a terminal command runs there too" "ssh=yes" "$CLI" read "$TERM_ITEM" --lines 5

# A viewer, on a file that lives on the server.
FILE_ITEM="$("$CLI" open "\$HOME/$SERVER_DIR/doc.whereview" --tab 2>/dev/null || true)"
HOME_THERE="$("${SSH[@]}" "$HOST" 'echo $HOME')"
FILE_ITEM="$("$CLI" open "$HOME_THERE/$SERVER_DIR/doc.whereview" --tab)"
sleep 2
expect "a viewer shows a file on the server" "on the server" "$CLI" web text --item "$FILE_ITEM"
"$CLI" web eval "tiri.write('saved from a viewer'); 0" --item "$FILE_ITEM" >/dev/null
sleep 2
expect "and saving reaches the server" "saved from a viewer" "${SSH[@]}" "$HOST" "cat ~/$SERVER_DIR/doc.whereview"

# From a terminal on the server: none of this is its to decide.
"$CLI" run where.show >/dev/null
sleep 1
PANEL="$("$CLI" items | awk -F'\t' '$4=="Where Panel"{print $1}' | head -1)"
SHELL_ITEM="$("$CLI" term --cwd "$HOME_THERE/$SERVER_DIR")"
sleep 2
from_server() { # a command in a terminal on the server, and what it said
  "$CLI" send "$SHELL_ITEM" "clear; $1; echo finished-\$?" --enter >/dev/null
  for _ in $(seq 1 50); do sleep 0.1; "$CLI" read "$SHELL_ITEM" --lines 12 | grep -q 'finished-[0-9]' && break; done
  "$CLI" read "$SHELL_ITEM" --lines 12
}
expect "it can't list plugins" "can only be run on the Mac" from_server "tiri plugin"
expect "or turn one on" "can only be run on the Mac" from_server "tiri plugin enable where"
expect "or turn one off" "can only be run on the Mac" from_server "tiri plugin disable where"
expect "or install one" "only be managed on the Mac" from_server "tiri plugin install /tmp"
expect "or write one" "only be managed on the Mac" from_server "tiri plugin new x"
expect "or run its commands" "can only be run on the Mac" from_server "tiri run where.mac"
expect "or press a panel's buttons" "only be driven from the Mac" from_server "tiri web eval 'tiri.run(1)' --item $PANEL"
expect "and is still on" "where	on" "$CLI" plugin
lacks "the Mac's plugin paths aren't in its guide" "SKILL.md" from_server "tiri --skill | tail -3"

"$CLI" plugin disable where
sleep 1
lacks "turning it off stops the process on the server" "bin/server" "${SSH[@]}" "$HOST" "ps -ax -o command= | grep '[w]here-.*bin/server' || true"
"${SSH[@]}" "$HOST" 'rm -rf ~/.tiri/plugins/where-*'

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
