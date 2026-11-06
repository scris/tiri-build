#!/bin/bash
# Ends Tiri every way it can end while something is going on, and checks what comes back when it's
# reopened: a quit, a terminate signal, a crash, a force quit, damaged saved state, two launches at once.
# A crash is SIGKILL, never an abort: an abort puts macOS's "quit unexpectedly" dialog on the screen of whoever
# is using this Mac.
# A program keeps counting in a terminal throughout, and files have edits that aren't saved.
#   TIRI_APP=<a test copy, e.g. from scripts/dev-app.sh start> scripts/e2e-exits.sh
# Uses its own state, settings and socket, and kills only what it starts.
set -u
cd "$(dirname "$0")/.."

APP="${TIRI_APP:-$PWD/build/Tiri.app}"
if [ ! -x "$APP/Contents/MacOS/Tiri" ]; then echo "No app at $APP" >&2; exit 1; fi
APP_REAL="$(cd "$APP" && pwd -P)"
if pgrep -f "$APP_REAL/Contents/MacOS/Tiri" >/dev/null; then echo "$APP is already running. Test a copy: scripts/dev-app.sh start exits, then stop it" >&2; exit 1; fi
CLI="$APP/Contents/Resources/bin/tiri"
WORK="$(mktemp -d)"
export TIRI_HOME="$WORK/home" TIRI_CONFIG_HOME="$WORK/config" TIRI_SOCKET="/tmp/tiri-exits-$$.sock"
mkdir -p "$TIRI_CONFIG_HOME"
# No notification may reach the screen of whoever is using this Mac.
printf '{ "notifications.enabled": false }\n' > "$TIRI_CONFIG_HOME/settings.json"
mkdir -p "$WORK"; cd "$WORK"
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
SESSION_DIR="/tmp/tiri-$(id -u)-$(printf %s "$TIRI_HOME" | shasum -a 256 | cut -c1-12)"

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok    $1"; }
fail() { failed=$((failed + 1)); echo "FAIL  $1"; }
check() { # name, command...
    local name="$1"; shift
    if output="$("$@" 2>&1)"; then pass "$name"; else fail "$name: $output"; fi
}
expect() { # name, needle, command...
    local name="$1" needle="$2"; shift 2
    output="$("$@" 2>&1)"
    if [[ "$output" == *"$needle"* ]]; then pass "$name"; else fail "$name: expected \"$needle\" in: $output"; fi
}
lacks() { # name, needle, command...
    local name="$1" needle="$2"; shift 2
    output="$("$@" 2>&1)"
    if [[ "$output" != *"$needle"* ]]; then pass "$name"; else fail "$name: didn't expect \"$needle\" in: $output"; fi
}
waits() { # name, needle, command... : tries for a few seconds
    local name="$1" needle="$2"; shift 2
    for _ in $(seq 1 30); do
        output="$("$@" 2>&1)"
        if [[ "$output" == *"$needle"* ]]; then pass "$name"; return; fi
        sleep 0.2
    done
    fail "$name: expected \"$needle\" in: $output"
}

APP_PID=""
cleanup() {
    [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2>/dev/null
    # Sessions outlive the app on purpose. These were only ever for this test, in its own folder.
    pkill -f "tiri-session attach $SESSION_DIR/" 2>/dev/null
    rm -rf "${WORK:?}" "$TIRI_SOCKET"
}
trap cleanup EXIT

launch_app() {
    open -g -n -a "$APP" --env TIRI_HOME="$TIRI_HOME" --env TIRI_CONFIG_HOME="$TIRI_CONFIG_HOME" --env TIRI_SOCKET="$TIRI_SOCKET" \
        --env TIRI_DEV_OFFSCREEN=1 --env TIRI_DEV_LANGUAGE=en
    APP_PID=""
    for _ in $(seq 1 50); do
        # Its parent is launchd. A terminal it has just forked carries the same command line until it runs its own.
        APP_PID="$(pgrep -P 1 -f "$APP_REAL/Contents/MacOS/Tiri" || true)"
        [ -n "$APP_PID" ] && break
        sleep 0.1
    done
    for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done
    sleep 1
}
gone() { # waits for the app to be gone
    for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}
alive_sessions() { pgrep -f "tiri-session attach $SESSION_DIR/$1.sock" >/dev/null; }
counter_value() { "$CLI" read "$1" --lines 400 | grep -o 'TICK-[0-9]*' | tail -1 | cut -d- -f2; }
edit() { # item, text: typed into a file, as someone would
    "$CLI" focus "$1" >/dev/null; sleep 0.3
    "$CLI" dev-compose --commit "$2" >/dev/null
    sleep 1  # Kept on disk half a second after typing stops.
}
status_of() { "$CLI" items | awk -v id="$1" '$1 == id { print $3 }'; }

# A crash here is a bug, and makes a report. SIGKILL, used on purpose below, makes none.
REPORTS="$HOME/Library/Logs/DiagnosticReports"
reports_before=$(ls "$REPORTS" 2>/dev/null | grep -c '^Tiri' || true)

launch_app
expect "ping" "pong" "$CLI" ping
check "add the project" "$CLI" workspace add-folder "$PROJECT"

# A program that keeps working the whole time, and a file with edits that aren't saved.
COUNTER=$("$CLI" term --cwd "$PROJECT")
sleep 2
"$CLI" send "$COUNTER" 'i=0; while true; do i=$((i+1)); echo TICK-$i; sleep 0.5; done' --enter
printf 'first line\n' > "$PROJECT/a.txt"
FILE_A=$("$CLI" open "$PROJECT/a.txt" --tab)
sleep 1
edit "$FILE_A" "EDIT-A "
expect "the edit shows as unsaved" "unsaved" status_of "$FILE_A"

echo "-- quit, with edits that aren't saved"
check "quitting doesn't stop for unsaved edits" "$CLI" quit
gone && pass "the app is gone" || fail "the app is gone"
alive_sessions "$COUNTER" && pass "the counter outlives the app" || fail "the counter outlives the app"
before=$(counter_value "$COUNTER" 2>/dev/null || true)
sleep 2
launch_app
check "focus the counter" "$CLI" focus "$COUNTER"
sleep 1.5
after=$(counter_value "$COUNTER")
[ -n "$after" ] && [ "$after" -gt 4 ] && pass "the counter kept counting while Tiri was closed ($after)" || fail "the counter kept counting ($after)"
expect "the edit is back as unsaved" "unsaved" status_of "$FILE_A"
check "the edit's text is back" "$CLI" select "$FILE_A" "EDIT-A"
expect "the file on disk wasn't touched" "first line" cat "$PROJECT/a.txt"
lacks "nothing was saved behind your back" "EDIT-A" cat "$PROJECT/a.txt"

echo "-- crash (SIGKILL), moments after typing"
edit "$FILE_A" "MORE "
kill -9 "$APP_PID"; gone
launch_app
check "the edit typed just before a crash is back" "$CLI" select "$FILE_A" "MORE"
check "and the one from before" "$CLI" select "$FILE_A" "EDIT-A"
"$CLI" focus "$COUNTER" >/dev/null; sleep 1
n1=$(counter_value "$COUNTER"); sleep 1.5; n2=$(counter_value "$COUNTER")
[ -n "$n1" ] && [ -n "$n2" ] && [ "$n2" -gt "$n1" ] && pass "the counter is still counting after a crash" || fail "the counter is still counting after a crash ($n1 → $n2)"

echo "-- force quit right after opening a terminal, before anything was saved"
FRESH=$("$CLI" term --cwd "$PROJECT")
sleep 1.2
"$CLI" send "$FRESH" 'echo fresh-$((6*7))' --enter
sleep 0.05
kill -9 "$APP_PID"; gone
launch_app
expect "the new terminal is back as a tab" "$FRESH" "$CLI" items
check "focus it" "$CLI" focus "$FRESH"
waits "its program kept running" "fresh-42" "$CLI" read "$FRESH"

echo "-- terminate signal (kill, a shutdown running out of patience)"
printf 'bee\n' > "$PROJECT/b.txt"
FILE_B=$("$CLI" open "$PROJECT/b.txt" --tab)
sleep 0.8
"$CLI" focus "$FILE_B" >/dev/null; sleep 0.3
"$CLI" dev-compose --commit "EDIT-B " >/dev/null
TERM_TAB=$("$CLI" term --cwd "$PROJECT")
sleep 0.1
kill -TERM "$APP_PID"
gone && pass "a terminate signal ends Tiri" || fail "a terminate signal ends Tiri"
launch_app
expect "the terminal opened just before is back" "$TERM_TAB" "$CLI" items
check "the edit typed just before is back" "$CLI" select "$FILE_B" "EDIT-B"

echo "-- saved state damaged while Tiri was down"
kill -9 "$APP_PID"; gone
: > "$TIRI_HOME/workspaces.json"
launch_app
expect "the workspace comes back from its last good copy" "project" "$CLI" workspace list
expect "the counter's tab is back" "$COUNTER" "$CLI" items
alive_sessions "$COUNTER" && pass "damaged state didn't end the counter" || fail "damaged state didn't end the counter"
expect "the edits are back" "unsaved" status_of "$FILE_A"
LAYOUT=$(ls "$TIRI_HOME"/layouts/*.json | head -1)
kill -9 "$APP_PID"; gone
printf '{"items": [' > "$LAYOUT"
launch_app
expect "a damaged layout comes back from its last good copy" "$COUNTER" "$CLI" items
alive_sessions "$COUNTER" && pass "a damaged layout didn't end the counter" || fail "a damaged layout didn't end the counter"
expect "a terminal newer than the last good copy is adopted back" "$TERM_TAB" "$CLI" items

echo "-- the file changed on disk while edits were kept"
check "quit" "$CLI" quit; gone
printf 'changed by an agent\n' > "$PROJECT/a.txt"
launch_app
check "your edits still show" "$CLI" select "$FILE_A" "EDIT-A"
expect "and are still unsaved" "unsaved" status_of "$FILE_A"
expect "the agent's version is still on disk" "changed by an agent" cat "$PROJECT/a.txt"

echo "-- saving or closing ends what was kept"
"$CLI" focus "$FILE_A" >/dev/null; sleep 0.3
check "save" "$CLI" run saveFile
sleep 0.5
expect "the edit reached the disk" "EDIT-A" cat "$PROJECT/a.txt"
[ ! -e "$TIRI_HOME/unsaved/$FILE_A.json" ] && pass "nothing is kept for a saved file" || fail "nothing is kept for a saved file"
check "close the other file, unsaved" "$CLI" close "$FILE_B"
sleep 0.8
[ ! -e "$TIRI_HOME/unsaved/$FILE_B.json" ] && pass "closing its tab drops what was kept" || fail "closing its tab drops what was kept"
check "quit" "$CLI" quit; gone
launch_app
lacks "a closed tab stays closed" "$FILE_B" "$CLI" items

echo "-- ⌘K, then a reattach"
"$CLI" focus "$FRESH" >/dev/null; sleep 0.3
"$CLI" send "$FRESH" 'for i in $(seq 1 40); do echo OLD-LINE-$i; done' --enter
sleep 1
check "clear" "$CLI" run clearTerminal
sleep 0.5
"$CLI" send "$FRESH" 'echo after-clear' --enter
sleep 1
check "quit" "$CLI" quit; gone
launch_app
"$CLI" focus "$FRESH" >/dev/null
waits "the terminal reattached" "after-clear" "$CLI" read "$FRESH" --lines 400
lacks "what ⌘K cleared stays cleared" "OLD-LINE" "$CLI" read "$FRESH" --lines 400

echo "-- two launches at once"
first=$APP_PID
open -g -n -a "$APP" --env TIRI_HOME="$TIRI_HOME" --env TIRI_CONFIG_HOME="$TIRI_CONFIG_HOME" --env TIRI_SOCKET="$TIRI_SOCKET" --env TIRI_DEV_OFFSCREEN=1
sleep 3
count=$(pgrep -P 1 -f "$APP_REAL/Contents/MacOS/Tiri" | wc -l | tr -d ' ')
[ "$count" = 1 ] && pass "a second launch leaves" || fail "a second launch leaves ($count running)"
kill -0 "$first" 2>/dev/null && pass "the first one stays" || fail "the first one stays"
alive_sessions "$COUNTER" && pass "the counter is untouched" || fail "the counter is untouched"

echo "-- closing a terminal still ends its program"
check "close the counter" "$CLI" close "$COUNTER"
sleep 1.5
alive_sessions "$COUNTER" && fail "closing the tab ends the program" || pass "closing the tab ends the program"
check "quit" "$CLI" quit; gone
launch_app
lacks "a closed terminal isn't adopted back" "$COUNTER" "$CLI" items

reports_after=$(ls "$REPORTS" 2>/dev/null | grep -c '^Tiri' || true)
[ "$reports_after" = "$reports_before" ] && pass "nothing crashed along the way" || fail "nothing crashed along the way: $((reports_after - reports_before)) new crash reports in $REPORTS"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
