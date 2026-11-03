#!/bin/bash
# Drives a real Tiri.app through every control-API command, in an isolated state directory.
# Doesn't touch your workspaces, settings or real socket. Run ./build.sh first.
set -u
cd "$(dirname "$0")/.."

# TIRI_APP tests another copy, such as one kept apart from the app you're using.
APP="${TIRI_APP:-$PWD/build/Tiri.app}"
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
    # Sessions outlive the app on purpose. These ones were only ever for this test.
    # Only this test's: your own terminals have their own folder.
    pkill -f "tiri-session attach /tmp/tiri-$(id -u)-$(printf %s "$TIRI_HOME" | shasum -a 256 | cut -c1-12)/" 2>/dev/null
    # Only the app this script started. You may have another one open.
    kill "$APP_PID" 2>/dev/null
    rm -rf "$WORK" "$TIRI_SOCKET"
}
trap cleanup EXIT

"$APP/Contents/MacOS/Tiri" >/dev/null 2>&1 &
APP_PID=$!
for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done

expect "ping" "pong" "$CLI" ping
expect "--skill prints the guide" "TIRI_ITEM_ID" "$CLI" --skill
expect "first launch has a workspace" "Home" "$CLI" workspace list
refuses "first launch starts no terminal" bash -c "'$CLI' items | grep -q terminal"

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
printf '%%PDF-1.4\n' > "$PROJECT/paper.pdf"
check "open a pdf" "$CLI" open "$PROJECT/paper.pdf" --tab
PDF_ID=$("$CLI" items | grep paper.pdf | cut -f1)
check "web-dark on a pdf" "$CLI" web-dark on "$PDF_ID"
check "web-dark off a pdf" "$CLI" web-dark off "$PDF_ID"
refuses "web-dark on a text file" "$CLI" web-dark on "$("$CLI" items | grep app.py | cut -f1)"
check "close the pdf" "$CLI" close "$PDF_ID"
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

# A path that doesn't exist as written gets searched for, the way a ⌘-click does.
mkdir -p "$PROJECT/resume" "$WORK/other/resume" "$PROJECT/only"
printf 'a' > "$PROJECT/only/single.md"
printf 'a' > "$PROJECT/resume/opportunities.html"
printf 'b' > "$WORK/other/resume/opportunities.html"
LINK_ID=$("$CLI" term --cwd "$PROJECT")
sleep 2.5
"$CLI" send "$LINK_ID" "clear; printf '/only/single.md\\n/nothing/missing.html\\nplain words\\nUpdate(only/single.md)\\n'" --enter
for _ in $(seq 1 50); do [ "$("$CLI" read "$LINK_ID" | head -1)" = "/only/single.md" ] && break; sleep 0.2; done
check "follow a path with one match" "$CLI" follow "$LINK_ID" 0 3
sleep 0.6
expect "one match opens as a peek" "single.md" "$CLI" items
check "follow a path with no match shows a toast" "$CLI" follow "$LINK_ID" 1 3
refuses "follow plain words" "$CLI" follow "$LINK_ID" 2 2
check "follow a path inside a tool call" "$CLI" follow "$LINK_ID" 3 10
check "close the link terminal" "$CLI" close "$LINK_ID"

check "hook payload is accepted" "$CLI" hook claude '{"hook_event_name":"Stop"}'
(unset TIRI_ITEM_ID; check "notify outside a terminal stays quiet" "$CLI" notify done)

expect "settings lists every setting" "terminal.linkOpens" "$CLI" settings
expect "settings explains itself" "Accepts:" "$CLI" settings explain code.wordWrap
expect "settings set takes effect" "on" "$CLI" settings set code.wordWrap on
expect "settings get reads it back" "on" "$CLI" settings get code.wordWrap
expect "settings reset restores it" "off" "$CLI" settings reset code.wordWrap
refuses "settings set checks the value" "$CLI" settings set code.wordWrap maybe
refuses "settings set checks the key" "$CLI" settings set no.such on
check "settings open" "$CLI" settings open
expect "settings is a tab" "settings" "$CLI" items
SETTINGS_ID=$("$CLI" items | grep -m1 '	settings	' | cut -f1)
check "close settings" "$CLI" close "$SETTINGS_ID"
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.name=t -c user.email=t@t add report.md
git -C "$PROJECT" -c user.name=t -c user.email=t@t commit -qm first
printf 'changed\n' >> "$PROJECT/report.md"
sleep 1
expect "changes lists a modified file" "report.md" "$CLI" changes
check "diff opens" "$CLI" diff "$PROJECT/report.md" --tab
expect "diff is an item" "changes" "$CLI" items
DIFF_ID=$("$CLI" items | grep -m1 'changes' | cut -f1)
check "close the diff" "$CLI" close "$DIFF_ID"
check "diff floats" "$CLI" diff "$PROJECT/report.md"
expect "floating diff is a peek" "(peek)" "$CLI" items
PEEK_DIFF=$("$CLI" items | grep '(peek)' | cut -f1)
check "close the floating diff" "$CLI" close "$PEEK_DIFF"

expect "search finds text in files" "report.md:1" "$CLI" search Report
expect "search reaches into folders" "app.py:1" "$CLI" search 'print("hi")'
check "search with no match succeeds" "$CLI" search nothing-has-this-text

# Quitting leaves what's running in a terminal alone, and the next launch comes back to it.
SESSION_ID=$("$CLI" term --cwd "$PROJECT")
sleep 2.5
"$CLI" send "$SESSION_ID" "echo before-quit; (sleep 3; echo after-quit) &" --enter
sleep 1
"$CLI" quit
sleep 1
if pgrep -f "tiri-session attach .*$SESSION_ID" >/dev/null; then passed=$((passed + 1)); echo "ok    the session outlives the app"; else failed=$((failed + 1)); echo "FAIL  the session outlives the app"; fi
sleep 3
"$APP/Contents/MacOS/Tiri" >/dev/null 2>&1 &
APP_PID=$!
for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done
sleep 1
check "focus the terminal after relaunch" "$CLI" focus "$SESSION_ID"
sleep 1.5
expect "output from before the quit is back" "before-quit" "$CLI" read "$SESSION_ID"
expect "output from while Tiri was closed is there" "after-quit" "$CLI" read "$SESSION_ID"
"$CLI" send "$SESSION_ID" "echo still-typing-\$((40+2))" --enter
sleep 1
expect "the terminal still takes input" "still-typing-42" "$CLI" read "$SESSION_ID"
check "close the session" "$CLI" close "$SESSION_ID"
sleep 1
if pgrep -f "tiri-session attach .*$SESSION_ID" >/dev/null; then failed=$((failed + 1)); echo "FAIL  closing the tab ends the session"; else passed=$((passed + 1)); echo "ok    closing the tab ends the session"; fi

expect "keys lists commands" "toggleSidebar" "$CLI" keys
expect "keys set takes effect" "⌘J" "$CLI" keys set toggleSidebar cmd+j
expect "commands show the new key" "⌘J" bash -c "'$CLI' keys | grep toggleSidebar"
expect "keys unset removes it" "no shortcut" "$CLI" keys unset toggleSidebar
expect "keys reset restores it" "⌘B" "$CLI" keys reset toggleSidebar
refuses "keys set refuses a plain letter" "$CLI" keys set toggleSidebar a
refuses "keys set checks the command" "$CLI" keys set nope cmd+j
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
