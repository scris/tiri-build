#!/bin/bash
# Files that come from outside Tiri: Finder and the Dock (`open -a`), `tiri open` from another terminal, tiri:// links,
# the editor programs ask for (tiri-edit, `tiri open --wait`) and a dev server's "open in editor" (tiri-open).
# Drives a real copy in an isolated state directory, in the background. Run as e2e.sh is:
#   TIRI_APP=<a copy, not one that's open> scripts/e2e-opening.sh
set -u
cd "$(dirname "$0")/.."
APP="${TIRI_APP:-$PWD/build/Tiri.app}"
if [ ! -x "$APP/Contents/MacOS/Tiri" ]; then echo "No app at $APP" >&2; exit 1; fi
APP_REAL="$(cd "$APP" && pwd -P)"
if pgrep -f "$APP_REAL/Contents/MacOS/Tiri" >/dev/null; then echo "$APP is already running. Test a copy: scripts/dev-app.sh start e2e" >&2; exit 1; fi
BIN="$APP/Contents/Resources/bin"
CLI="$BIN/tiri"
WORK="$(mktemp -d)"
export TIRI_HOME="$WORK/home" TIRI_CONFIG_HOME="$WORK/config" TIRI_SOCKET="/tmp/tiri-e2e-open-$$.sock"
# Asked from outside Tiri, unless a check says otherwise. An agent's own GIT_EDITOR would stand in for the editor.
unset TIRI_ITEM_ID TIRI_WORKSPACE GIT_EDITOR EDITOR VISUAL LAUNCH_EDITOR REACT_EDITOR
mkdir -p "$WORK"; cd "$WORK"
A="$WORK/projA"; B="$WORK/projB"
mkdir -p "$A/src" "$B/lib" "$WORK/linked-dir"
printf 'let a = 1\nlet b = 2\n' > "$A/src/main.swift"
printf 'def x():\n    return 1\n' > "$B/lib/util.py"
printf '<h1>hi</h1><script>document.title="ran"</script>\n' > "$B/page.html"
printf 'loose\n' > "$WORK/loose.txt"

passed=0
failed=0
check() { local name="$1"; shift
    if output="$("$@" 2>&1)"; then passed=$((passed + 1)); echo "ok    $name"; else failed=$((failed + 1)); echo "FAIL  $name: $output"; fi
}
expect() { local name="$1" needle="$2"; shift 2
    output="$("$@" 2>&1)"
    if [[ "$output" == *"$needle"* ]]; then passed=$((passed + 1)); echo "ok    $name"; else failed=$((failed + 1)); echo "FAIL  $name: expected \"$needle\" in: $output"; fi
}
lacks() { local name="$1" needle="$2"; shift 2
    output="$("$@" 2>&1)"
    if [[ "$output" != *"$needle"* ]]; then passed=$((passed + 1)); echo "ok    $name"; else failed=$((failed + 1)); echo "FAIL  $name: didn't expect \"$needle\" in: $output"; fi
}

cleanup() {
    pkill -f "tiri-session attach /tmp/tiri-$(id -u)-$(printf %s "$TIRI_HOME" | shasum -a 256 | cut -c1-12)/" 2>/dev/null
    kill "$APP_PID" 2>/dev/null
    sleep 0.5
    rm -rf "$WORK" "$TIRI_SOCKET" 2>/dev/null || { sleep 1; rm -rf "$WORK"; }
}
trap cleanup EXIT

# In the background, out of sight: someone may be using this Mac. Told to act as if someone were looking at
# the terminal in front, as whoever presses Ctrl-G is.
launch_app() {
    open -g -n -a "$APP" --env TIRI_HOME="$TIRI_HOME" --env TIRI_CONFIG_HOME="$TIRI_CONFIG_HOME" --env TIRI_SOCKET="$TIRI_SOCKET" \
        --env TIRI_DEV_OFFSCREEN=1 --env TIRI_DEV_LOOKING=1
    for _ in $(seq 1 50); do
        APP_PID="$(pgrep -n -f "$APP_REAL/Contents/MacOS/Tiri" || true)"
        [ -n "$APP_PID" ] && break
        sleep 0.1
    done
    for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done
}
launch_app
"$CLI" settings set notifications.enabled false >/dev/null
"$CLI" workspace new A --folder "$A" >/dev/null
"$CLI" workspace new B --folder "$B" >/dev/null
"$CLI" workspace switch A >/dev/null

front() { "$CLI" workspace list | grep '^\*'; }
# What the window shows, which isn't always what Tiri thinks is in front.
shown() { "$CLI" --json window list | python3 -c 'import json,sys; print("shows", [w["workspace"] for w in json.load(sys.stdin)["result"]])'; }
# What the file in front says and where its caret is, as `path offset`.
caret() { "$CLI" --json dev-editor | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r["path"], r["selection"][0])'; }
# A hidden copy takes a moment to show what it was handed.
settle() { sleep "${1:-1.5}"; }

# Finder and the Dock: the file goes to the workspace that has its folder.
open -g -a "$APP" "$B/lib/util.py"; settle
expect "a file from Finder goes to the workspace that has it" "* B" front
expect "  and opens there as a tab" "util.py	(active)	[B]" "$CLI" items
expect "  and the window shows it" "shows ['B']" shown
"$CLI" open "$A/src/main.swift" >/dev/null
expect "tiri open from another terminal goes there too" "* A" front
"$CLI" open "$WORK/loose.txt" >/dev/null
expect "a file in no workspace's folder stays in front" "* A" front
open -g -a "$APP" "$WORK/loose.txt"; settle
expect "  from Finder too, and the window stays on it" "shows ['A']" shown

# tiri:// links, as "open in editor" buttons on error pages make them.
open -g -a "$APP" "tiri://file$B/lib/util.py:2:5"; settle
expect "a tiri:// link opens its file where it belongs" "* B" front
expect "  and the window shows it" "shows ['B']" shown
expect "  at its line and column" "util.py 13" caret
open -g -a "$APP" "tiri://open?file=$A/src/main.swift&line=2"; settle
expect "the query form too" "main.swift 10" caret
open -g -a "$APP" "tiri://file$B/page.html"; settle
expect "a page from a link is shown as its text, never run" "page.html 0" caret
"$CLI" workspace switch A >/dev/null
open -g -a "$APP" "tiri://file$WORK/linked-dir"; settle
expect "a link to a folder doesn't open it" "* A" front
lacks "  nor make it a workspace" "linked-dir" "$CLI" workspace list

# A dev server's "open in editor": launch-editor passes the file, the line and the column.
check "tiri-open as LAUNCH_EDITOR calls it" "$BIN/tiri-open" "$B/lib/util.py" 2 1
expect "  goes to the file's workspace" "* B" front
expect "  at its line" "util.py 9" caret

# The editor a program asks for, from a Tiri terminal: a Peek to type in, handed back when it closes.
"$CLI" workspace switch A >/dev/null
TERM_ID="$("$CLI" term --cwd "$A")"; settle 2
expect "Tiri's terminals name LAUNCH_EDITOR" "tiri-open" bash -c "'$CLI' send $TERM_ID 'echo L=\$LAUNCH_EDITOR' --enter; sleep 1; '$CLI' read $TERM_ID"
printf 'draft\n' > "$WORK/prompt.md"
"$CLI" focus "$TERM_ID" >/dev/null
(TIRI_ITEM_ID="$TERM_ID" "$BIN/tiri-edit" "$WORK/prompt.md"; echo "returned $?" > "$WORK/edit.out") &
settle
expect "tiri-edit floats the file as a Peek over its terminal" "prompt.md	(peek)" "$CLI" items
check "  and waits" test ! -e "$WORK/edit.out"
check "  with its text to type in, not rendered Markdown" bash -c "'$CLI' dev-editor --json | grep -q prompt.md"
"$CLI" dev-compose --commit "typed " >/dev/null
"$CLI" workspace switch B >/dev/null; settle 0.5
"$CLI" workspace switch A >/dev/null; settle 0.5
expect "  it stays through a workspace switch" "prompt.md	(peek)" "$CLI" items
check "  and typing doesn't make it a tab" test ! -e "$WORK/edit.out"
TIRI_ITEM_ID="$TERM_ID" "$CLI" open "$A/src/main.swift" >/dev/null; settle 0.5
expect "  an agent showing a file meanwhile doesn't replace it" "unsaved	prompt.md	(peek)" "$CLI" items
"$CLI" focus "$TERM_ID" >/dev/null; settle 0.5
"$CLI" run promotePeek >/dev/null; settle
expect "Done (⌘↩) hands it back" "returned 0" cat "$WORK/edit.out"
expect "  saved" "typed" cat "$WORK/prompt.md"
lacks "  and closed" "prompt.md" "$CLI" items

# An agent's own git command, from a terminal nobody's at: it doesn't get the keyboard, and its tab says it needs you.
OTHER_ID="$("$CLI" term --cwd "$A")"; settle 2
"$CLI" focus "$TERM_ID" >/dev/null
printf 'x\n' > "$WORK/agent.txt"
(TIRI_ITEM_ID="$OTHER_ID" "$BIN/tiri-edit" "$WORK/agent.txt"; echo "returned $?" > "$WORK/agent.out") &
settle
expect "a wait from a terminal nobody's at floats too" "agent.txt	(peek)" "$CLI" items
lacks "  without taking the keyboard" "agent.txt" "$CLI" dev-editor
expect "  and its terminal needs you" "needs" bash -c "'$CLI' --json items | python3 -c 'import json,sys; print([i[\"status\"] for i in json.load(sys.stdin)[\"result\"] if i[\"id\"]==\"$OTHER_ID\"])'"
AGENT_FILE="$("$CLI" items | grep agent.txt | cut -f1)"
"$CLI" close "$AGENT_FILE" >/dev/null; settle
expect "  closing it hands it back" "returned 0" cat "$WORK/agent.out"

# From outside a Tiri terminal: a tab, and closing it is done.
("$CLI" open --wait "$WORK/loose.txt"; echo "returned $?" > "$WORK/wait.out") &
settle
check "tiri open --wait waits for the tab" test ! -e "$WORK/wait.out"
LOOSE="$("$CLI" items | grep loose.txt | cut -f1)"
"$CLI" close "$LOOSE" >/dev/null; settle
expect "  and returns once it's closed" "returned 0" cat "$WORK/wait.out"

# git commit, with EDITOR as Tiri's terminals set it.
git -C "$A" init -q && git -C "$A" -c user.name=t -c user.email=t@t commit -q --allow-empty -m first
"$CLI" send "$TERM_ID" "clear; EDITOR=tiri-edit git -c user.name=t -c user.email=t@t commit --allow-empty" --enter; settle 2.5
expect "git commit opens its message in a Peek" "COMMIT_EDITMSG	(peek)" "$CLI" items
"$CLI" dev-compose --commit "Written in Tiri" >/dev/null
"$CLI" dev-key 53 >/dev/null; settle 2
expect "  and Esc after typing commits what was typed" "Written in Tiri" git -C "$A" log -1 --format=%s

# Turned off, new terminals leave the editor alone.
"$CLI" settings set terminal.editor false >/dev/null
OFF_ID="$("$CLI" term --cwd "$A")"; settle 2
lacks "with Edit in Tiri off, terminals don't name it" "tiri-open" bash -c "'$CLI' send $OFF_ID 'echo L=\$LAUNCH_EDITOR' --enter; sleep 1; '$CLI' read $OFF_ID"

# Tiri quitting with something typed in a Peek a program waits on: kept, as a tab, and the program is told.
"$CLI" settings set terminal.editor true >/dev/null
printf 'start\n' > "$WORK/quit.md"
"$CLI" focus "$TERM_ID" >/dev/null
(TIRI_ITEM_ID="$TERM_ID" "$BIN/tiri-edit" "$WORK/quit.md"; echo "returned $?" > "$WORK/quit.out") &
settle
"$CLI" dev-compose --commit "half a thought " >/dev/null
"$CLI" quit >/dev/null 2>&1
for _ in $(seq 1 100); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
settle 1
expect "quitting fails the program waiting" "returned 1" cat "$WORK/quit.out"
lacks "  and leaves the file as it was" "half a thought" cat "$WORK/quit.md"
launch_app; settle 2
expect "  what was typed comes back, in a tab" "unsaved	quit.md" "$CLI" items

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
