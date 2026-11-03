#!/bin/bash
# Drives a real Tiri.app through every control-API command, in an isolated state directory.
# Doesn't touch your workspaces, settings or real socket. Run ./build.sh first.
set -u
cd "$(dirname "$0")/.."

APP="$PWD/build/Tiri.app"
CLI="$APP/Contents/Resources/bin/tiri"
WORK="$(mktemp -d)"
export TIRI_HOME="$WORK/home" TIRI_CONFIG_HOME="$WORK/config" TIRI_SOCKET="/tmp/tiri-e2e-$$.sock"
PROJECT="$WORK/project"
mkdir -p "$PROJECT/src" "$WORK/other"
printf '# Report\n\nHello.\n' > "$PROJECT/report.md"
printf 'print("hi")\n' > "$PROJECT/src/app.py"
printf '<!doctype html><title>Page</title><h1>Hi</h1>\n' > "$PROJECT/page.html"
printf '{ "folders": [ { "path": "project" }, { "path": "other" } ] }\n' > "$WORK/team.code-workspace"

passed=0
failed=0
check() { # name, command...
    local name="$1"
    shift
    if output="$("$@" 2>&1)"; then
        passed=$((passed + 1))
        echo "ok    $name"
    else
        failed=$((failed + 1))
        echo "FAIL  $name: $output"
    fi
}
expect() { # name, needle, command...
    local name="$1" needle="$2"
    shift 2
    output="$("$@" 2>&1)"
    if [[ "$output" == *"$needle"* ]]; then
        passed=$((passed + 1))
        echo "ok    $name"
    else
        failed=$((failed + 1))
        echo "FAIL  $name: expected \"$needle\" in: $output"
    fi
}
refuses() { # name, command...
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        failed=$((failed + 1))
        echo "FAIL  $name: should have been refused"
    else
        passed=$((passed + 1))
        echo "ok    $name"
    fi
}

cleanup() {
    pkill -f "$APP/Contents/MacOS/Tiri" 2>/dev/null
    rm -rf "$WORK" "$TIRI_SOCKET"
}
trap cleanup EXIT

"$APP/Contents/MacOS/Tiri" >/dev/null 2>&1 &
for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done

expect "ping" "pong" "$CLI" ping
expect "--skill prints the guide" "TIRI_ITEM_ID" "$CLI" --skill
expect "first launch has a workspace" "Home" "$CLI" workspace list

check "workspace new with a folder" "$CLI" workspace new demo --folder "$PROJECT"
sleep 0.6
expect "new workspace is active" "* demo" "$CLI" workspace list
expect "new workspace starts with a terminal" "terminal" "$CLI" items
expect "tree shows the folder" "report.md" "$CLI" tree

touch "$PROJECT/from-outside.txt"
sleep 0.6
expect "tree updates from outside" "from-outside.txt" "$CLI" tree

check "open as a tab" "$CLI" open "$PROJECT/report.md" --tab
expect "tab is listed" "report.md" "$CLI" items
check "open with a line and split" "$CLI" open "$PROJECT/src/app.py:1" --split right
expect "split made two groups" '"split" : "horizontal"' "$CLI" layout
refuses "open a missing file" "$CLI" open "$PROJECT/nope.txt"

check "open as a peek" "$CLI" open "$PROJECT/page.html" --peek
expect "peek is listed" "(peek)" "$CLI" items
PEEK=$("$CLI" items | grep '(peek)' | cut -f1)
check "close the peek" "$CLI" close "$PEEK"

check "reveal" "$CLI" reveal "$PROJECT/src"
expect "reveal expanded it" "app.py" "$CLI" tree
refuses "reveal outside the workspace" "$CLI" reveal /usr

WEB=$("$CLI" preview "$PROJECT/page.html" --split down)
sleep 0.5
expect "preview is listed" "web" "$CLI" items
check "web-dark on" "$CLI" web-dark on "$WEB"
check "web-dark off" "$CLI" web-dark off "$WEB"
refuses "web-dark on a missing item" "$CLI" web-dark on i-nope
check "close the preview" "$CLI" close "$WEB"

TERM_ID=$("$CLI" term --cwd "$PROJECT" --cmd "sleep 300")
sleep 0.4
expect "term with a command is listed" "sleep 300" "$CLI" items
check "focus" "$CLI" focus "$TERM_ID"
check "notify needs-input" "$CLI" notify needs-input --item "$TERM_ID" --message "Pick one"
expect "status shows" "needs-input" "$CLI" items
check "notify done" "$CLI" notify done --item "$TERM_ID"
check "notify working" "$CLI" notify working --item "$TERM_ID"
check "close the terminal" "$CLI" close "$TERM_ID"
refuses "focus a closed item" "$CLI" focus "$TERM_ID"

SHELL_ID=$("$CLI" items | grep -m1 terminal | cut -f1)
sleep 2
check "send to a terminal" "$CLI" send "$SHELL_ID" "echo marker-\$((40+2))" --enter
sleep 1
expect "read a terminal" "marker-42" "$CLI" read "$SHELL_ID" --lines 10

check "hook payload is accepted" "$CLI" hook claude '{"hook_event_name":"Stop"}'
(unset TIRI_ITEM_ID; check "notify outside a terminal stays quiet" "$CLI" notify done)

check "theme dark" "$CLI" theme dark
expect "theme written to settings" '"theme": "dark"' cat "$TIRI_CONFIG_HOME/settings.json"
check "theme system" "$CLI" theme system

check "workspace add-folder" "$CLI" workspace add-folder "$WORK/other"
check "workspace remove-folder" "$CLI" workspace remove-folder "$WORK/other"
check "workspace import" "$CLI" workspace import "$WORK/team.code-workspace"
expect "import kept both folders" "other" "$CLI" workspace list
check "workspace switch" "$CLI" workspace switch demo
check "workspace rename" "$CLI" workspace rename renamed team
check "workspace delete" "$CLI" workspace delete renamed
refuses "switch to a missing workspace" "$CLI" workspace switch nope

expect "commands lists actions" "splitRight" "$CLI" commands
check "run a command" "$CLI" run toggleSidebar
check "run it back" "$CLI" run toggleSidebar
refuses "run a missing command" "$CLI" run nope

printf '{ broken' > "$TIRI_CONFIG_HOME/settings.json"
sleep 0.5
expect "still alive with invalid settings" "pong" "$CLI" ping

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
