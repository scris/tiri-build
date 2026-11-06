#!/bin/bash
# What plugins add around the editor, in a real test copy: colors on text, questions in the palette,
# saving first, right-click menus and colors on sidebar rows, marks in the explorer, and events.
#   scripts/dev-app.sh start e2eeditor && scripts/e2e-plugin-editor.sh e2eeditor   (a new copy: it adds a folder)
# Every program it starts stops when it's done. Screenshots go in $TIRI_SHOTS, if that's set.
set -u
NAME="${1:-e2eeditor}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}"
DIR="$ROOT/$NAME"
APP="$DIR/TiriDev.app"
CLI="$APP/Contents/Resources/bin/tiri"
[ -x "$CLI" ] || { echo "No test copy called $NAME. Run scripts/dev-app.sh start $NAME" >&2; exit 1; }
export TIRI_HOME="$DIR/home" TIRI_CONFIG_HOME="$DIR/config" TIRI_SOCKET="/tmp/tiri-dev-$NAME.sock"
export PATH="$APP/Contents/Resources/bin:$PATH"
PLUGINS="$TIRI_CONFIG_HOME/plugins"
DATA="$TIRI_HOME/plugin-data/gaps"
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
waits() { # name, needle, command...: a few seconds for things that happen by themselves
  local name="$1" needle="$2"; shift 2
  local output=""
  for _ in $(seq 1 80); do
    output="$("$@" 2>&1)"
    if [[ "$output" == *"$needle"* ]]; then ok "$name"; return; fi
    sleep 0.1
  done
  no "$name: expected \"$needle\" in: $output"
}
shot() { [ -n "${TIRI_SHOTS:-}" ] && (cd "$REPO" && scripts/dev-app.sh shot "$NAME" "$TIRI_SHOTS/$1.png"); return 0; }
approve() {
  # Asked too soon after launch, the question doesn't appear, so it's asked again until it does.
  for _ in $(seq 1 15); do
    "$CLI" plugin enable "$1" >/dev/null
    for _ in $(seq 1 20); do "$CLI" dev-plugin-question | grep -q '"question" *: *"[^"]' && break 2; sleep 0.1; done
  done
  "$CLI" dev-plugin-answer yes >/dev/null
  for _ in $(seq 1 60); do "$CLI" plugin | grep -q "^$1	on" && return 0; sleep 0.1; done
  return 1
}
palette_open() { for _ in $(seq 1 50); do "$CLI" dev-palette >/dev/null 2>&1 && return 0; sleep 0.1; done; return 1; }
background() { # file, command...: runs it, keeping what it prints
  local file="$1"; shift
  "$@" > "$file" 2>&1 &
}

# ---------------------------------------------------------------- the plugin
# From nothing, whatever an earlier run left.
"$CLI" plugin disable gaps >/dev/null 2>&1
rm -rf "$PLUGINS/gaps" "$DATA"
"$CLI" plugin reload >/dev/null
mkdir -p "$PLUGINS/gaps/.tiri-plugin" "$PLUGINS/gaps/bin" "$PLUGINS/gaps/panel"
cat > "$PLUGINS/gaps/.tiri-plugin/plugin.json" <<'JSON'
{ "name": "gaps", "title": "Gaps", "version": "1.0.0", "apiVersion": 1, "tiri": ">=0.1.0",
  "description": "Everything the ports were missing.",
  "settings": [{ "key": "tags", "title": "Tags", "type": "list", "default": ["TODO", "FIXME"] }],
  "highlights": [
    { "pattern": "(?://|#)\\s*(${settings.tags})\\b", "group": 1, "color": "orange", "background": "#ff9f0a33", "onlyInComments": true },
    { "pattern": "\\bDEPRECATED\\b", "color": "red", "strikethrough": true, "files": ["*.py"] }
  ],
  "commands": [
    { "id": "greet", "title": "Greet", "exec": ["bin/say", "hello ${args.name}"], "show": "none",
      "input": [{ "name": "name", "prompt": "Who should it greet?" }] },
    { "id": "pick", "title": "Pick a Fruit", "exec": ["bin/say", "${args.fruit} and ${args.size}"], "show": "none",
      "input": [{ "name": "fruit", "prompt": "Which fruit?", "options": [{ "value": "apple", "label": "Apple" }, { "value": "pear", "label": "Pear", "detail": "green" }] },
                { "name": "size", "prompt": "How big?", "optionsFrom": { "exec": ["bin/sizes"] } }] },
    { "id": "ondisk", "title": "Show What's on Disk", "exec": ["bin/ondisk"], "show": "none", "save": "front" },
    { "id": "remember", "title": "Remember Row", "exec": ["bin/remember"], "show": "none" },
    { "id": "panel", "title": "Show Gaps", "panel": "files", "open": "right" }
  ],
  "sidebar": [{ "id": "rows", "title": "Gaps", "provider": { "exec": ["bin/rows"] }, "refresh": { "onFrontFile": true },
               "menu": [{ "title": "Remember", "symbol": "pin", "command": "remember" }] }],
  "fileMarks": [{ "id": "todos", "provider": { "exec": ["bin/marks"] }, "refresh": { "onFileChange": true } }],
  "processes": [{ "id": "watch", "exec": ["bin/watch"], "events": ["frontFile", "openFiles", "saved", "filesChanged"] }],
  "panels": [{ "id": "files", "title": "Gaps", "entry": "panel/index.html", "allow": { "editor": true } }] }
JSON
cat > "$PLUGINS/gaps/bin/say" <<'SH'
#!/bin/sh
printf '%s' "$1"
SH
cat > "$PLUGINS/gaps/bin/sizes" <<'SH'
#!/bin/sh
echo '{"items": [{"value": "small", "label": "Small"}, {"value": "huge", "label": "Huge", "detail": "from a program"}]}'
SH
cat > "$PLUGINS/gaps/bin/ondisk" <<'SH'
#!/bin/sh
cat "$TIRI_FILE"
SH
cat > "$PLUGINS/gaps/bin/remember" <<'SH'
#!/bin/sh
printf '%s' "$TIRI_PLUGIN_ARGS" > "$TIRI_PLUGIN_DATA/remembered.json"
SH
cat > "$PLUGINS/gaps/bin/rows" <<'SH'
#!/bin/sh
front=$(basename "${TIRI_FILE:-none}")
cat <<JSON
{"items": [
  {"id": "a", "title": "Urgent", "symbol": "flame", "color": "red", "args": {"which": "a"}, "menu": [{"title": "Just This One", "command": "remember"}]},
  {"id": "b", "title": "Later", "symbol": "leaf", "symbolColor": "green", "path": "b.py"},
  {"id": "front", "title": "Front: $front", "symbol": "doc", "color": "#5e5ce6"}
]}
JSON
SH
cat > "$PLUGINS/gaps/bin/marks" <<'SH'
#!/usr/bin/env python3
import json, os, re
folder = os.environ.get("TIRI_WORKSPACE_FOLDER", ".")
files = {}
for name in sorted(os.listdir(folder)):
    if not name.endswith(".py"):
        continue
    count = len(re.findall(r"#\s*(TODO|FIXME)", open(os.path.join(folder, name)).read()))
    if count:
        files[name] = {"badge": str(count), "color": "orange", "tooltip": f"{count} to do"}
print(json.dumps({"files": files}))
SH
cat > "$PLUGINS/gaps/bin/watch" <<'SH'
#!/usr/bin/env python3
import json, os, sys
log = os.path.join(os.environ["TIRI_PLUGIN_DATA"], "events.log")
for line in sys.stdin:
    message = json.loads(line)
    if message.get("method") == "event":
        with open(log, "a") as out:
            out.write(json.dumps(message["params"]) + "\n")
SH
chmod +x "$PLUGINS/gaps/bin/"*
cat > "$PLUGINS/gaps/panel/index.html" <<'HTML'
<!doctype html><html><body><h3>Open files</h3><ul id="list"></ul><script src="panel.js"></script></body></html>
HTML
cat > "$PLUGINS/gaps/panel/panel.js" <<'JS'
window.heard = [];
const show = async () => {
  const files = await tiri.files();
  document.getElementById('list').innerHTML = files.paths.map(p => `<li>${p === files.front ? '<b>' : ''}${p.split('/').pop()}${p === files.front ? '</b>' : ''}</li>`).join('');
};
for (const name of ['frontFile', 'openFiles', 'saved', 'filesChanged']) tiri.on(name, (data) => { window.heard.push(name); show(); });
show();
JS

printf '# TODO: first\nx = 1  # FIXME later\ns = "TODO is not a comment here"\nDEPRECATED = True\n# NOTE: kept\n' > "$PROJECT/a.py"
printf 'print("nothing to do")\n' > "$PROJECT/b.py"
"$CLI" workspace add-folder "$PROJECT" >/dev/null
"$CLI" settings set notifications.enabled false >/dev/null 2>&1
"$CLI" plugin reload >/dev/null

echo "== Checked before it's on"
expect "validate is happy" "Adds:" "$CLI" plugin validate gaps
lacks "with no errors" "error:" "$CLI" plugin validate gaps
expect "it says it colors the editor" "colors in the editor" "$CLI" plugin validate gaps
expect "and marks files" "marks on files in the explorer" "$CLI" plugin validate gaps
expect "and that its panel sees open files" "which files you have open" "$CLI" plugin validate gaps
approve gaps && ok "turned on" || no "turned on"
"$CLI" settings reset plugin.gaps.tags >/dev/null 2>&1

echo "== Colors on text"
"$CLI" open "$PROJECT/a.py" >/dev/null
waits "a TODO in a comment is colored" '"text" : "TODO"' "$CLI" dev-plugin-colors "$PROJECT/a.py" 1
expect "and a FIXME after code" '"text" : "FIXME"' "$CLI" dev-plugin-colors "$PROJECT/a.py" 2
expect "but not TODO inside a string" '[' "$CLI" dev-plugin-colors "$PROJECT/a.py" 3
lacks "nothing on that line" 'TODO' "$CLI" dev-plugin-colors "$PROJECT/a.py" 3
expect "a second highlight on the same file" '"text" : "DEPRECATED"' "$CLI" dev-plugin-colors "$PROJECT/a.py" 4
lacks "a word that isn't a tag yet" 'NOTE' "$CLI" dev-plugin-colors "$PROJECT/a.py" 5
shot editor-01-colors
"$CLI" settings set plugin.gaps.tags '["TODO","FIXME","NOTE"]' >/dev/null
waits "a setting changes what's colored, at once" '"text" : "NOTE"' "$CLI" dev-plugin-colors "$PROJECT/a.py" 5
"$CLI" dev-compose --commit "# TODO typed " >/dev/null
waits "typing a tag colors it" '"text" : "TODO"' "$CLI" dev-plugin-colors "$PROJECT/a.py" 1
"$CLI" plugin update gaps marks nope '{}' >/dev/null 2>&1

echo "== Asking in the palette"
background "$WORK/greet" "$CLI" run gaps.greet
palette_open && ok "a text question opens the palette" || no "a text question opens the palette"
expect "it asks what the command asks" "Who should it greet?" "$CLI" dev-palette
expect "under the command's name" '"heading" : "Greet"' "$CLI" dev-palette
shot editor-02-asking-text
"$CLI" dev-palette --text "Ada Lovelace" >/dev/null
wait
expect "the answer becomes an arg, as one value" "hello Ada Lovelace" cat "$WORK/greet"
background "$WORK/cancelled" "$CLI" run gaps.greet
palette_open >/dev/null
"$CLI" dev-palette --cancel >/dev/null
wait
expect "Esc runs nothing" "Cancelled" cat "$WORK/cancelled"
expect "args given aren't asked for" "hello Grace" "$CLI" run gaps.greet name=Grace
background "$WORK/pick" "$CLI" run gaps.pick
palette_open >/dev/null
expect "a choice lists its options" '"Pear"' "$CLI" dev-palette
shot editor-03-asking-choice
"$CLI" dev-palette --choose 1 >/dev/null
waits "then the next question, with options from a program" '"Huge"' "$CLI" dev-palette
"$CLI" dev-palette --choose 1 >/dev/null
wait
expect "both answers arrive as values" "pear and huge" cat "$WORK/pick"

echo "== Saving first"
"$CLI" open "$PROJECT/b.py" >/dev/null
sleep 0.4
"$CLI" dev-compose --commit "# unsaved " >/dev/null
lacks "the edit isn't on disk yet" "unsaved" cat "$PROJECT/b.py"
expect "the command sees the saved file" "# unsaved" "$CLI" run gaps.ondisk
expect "and it's on disk" "unsaved" cat "$PROJECT/b.py"

echo "== Sidebar rows"
"$CLI" open "$PROJECT/a.py" >/dev/null
waits "rows are listed, colored" '"color" : "red"' "$CLI" dev-plugin-menu gaps/rows 0
waits "a refresh asked for during a refresh isn't lost" 'Front: a.py' "$CLI" dev-plugin-menu gaps/rows 2
expect "a row's menu has the section's entry and its own" '"Just This One"' "$CLI" dev-plugin-menu gaps/rows 0
expect "the section's comes first" '"Remember"' "$CLI" dev-plugin-menu gaps/rows 0
rm -f "$DATA/remembered.json"
"$CLI" dev-plugin-menu gaps/rows 0 0 >/dev/null
waits "choosing runs it with the row's args" '"which":"a"' cat "$DATA/remembered.json"
expect "and its title" '"title":"Urgent"' cat "$DATA/remembered.json"
rm -f "$DATA/remembered.json"
"$CLI" dev-plugin-menu gaps/rows 1 0 >/dev/null
waits "a row with a path passes it" "$PROJECT/b.py" cat "$DATA/remembered.json"
shot editor-04-sidebar

echo "== Marks in the explorer"
waits "a file with tags has a count" '"badge" : "2"' "$CLI" dev-file-mark "$PROJECT/a.py"
expect "and a tooltip" '"tooltip" : "2 to do"' "$CLI" dev-file-mark "$PROJECT/a.py"
lacks "a file without has none" "badge" "$CLI" dev-file-mark "$PROJECT/b.py"
printf '# TODO: from outside\n' > "$PROJECT/c.py"
waits "a change on disk by anyone refreshes them" '"badge" : "1"' "$CLI" dev-file-mark "$PROJECT/c.py"
"$CLI" plugin update gaps marks todos '{"files": {"b.py": {"badge": "!", "color": "red"}}}' >/dev/null
expect "tiri plugin update sets them" '"badge" : "!"' "$CLI" dev-file-mark "$PROJECT/b.py"
shot editor-05-explorer-marks

echo "== Events"
waits "a process hears what's in front" "a.py" grep frontFile "$DATA/events.log"
expect "and what's open" "openFiles" cat "$DATA/events.log"
"$CLI" open "$PROJECT/b.py" >/dev/null
waits "a different file in front is told" "b.py" sh -c "grep frontFile '$DATA/events.log' | tail -1"
waits "the sidebar follows the front file" 'Front: b.py' "$CLI" dev-plugin-menu gaps/rows 2
waits "saving is told" '"saved"' cat "$DATA/events.log"
printf 'changed\n' > "$PROJECT/d.txt"
waits "a change on disk is told" "d.txt" grep filesChanged "$DATA/events.log"
mkdir -p "$PROJECT/.git" && printf 'x' > "$PROJECT/.git/index"
sleep 1.2
lacks "but not Git's own files" ".git/index" cat "$DATA/events.log"

echo "== A panel that sees open files"
"$CLI" run gaps.panel >/dev/null
sleep 1
PANEL=$("$CLI" items | awk -F'\t' '/Gaps/ {print $1; exit}')
"$CLI" web eval "tiri.files().then(f => { window.files = JSON.stringify(f); }); 'asked'" --item "$PANEL" >/dev/null
waits "files() lists them" "b.py" "$CLI" web eval "window.files || ''" --item "$PANEL"
expect "and says which is in front" '"front":' "$CLI" web eval "window.files || ''" --item "$PANEL"
"$CLI" open "$PROJECT/a.py" >/dev/null
waits "and the panel hears changes" "frontFile" "$CLI" web eval "JSON.stringify(window.heard)" --item "$PANEL"
shot editor-06-panel

echo "== Off means gone"
"$CLI" plugin disable gaps
waits "turned off" "gaps	off" "$CLI" plugin
waits "colors go" "[" "$CLI" dev-plugin-colors "$PROJECT/a.py" 1
lacks "nothing colored" "TODO" "$CLI" dev-plugin-colors "$PROJECT/a.py" 1
lacks "marks go" "badge" "$CLI" dev-file-mark "$PROJECT/a.py"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
