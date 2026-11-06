#!/bin/bash
# Drives tiri-session by itself, the way a terminal does, through a pipe instead of a view:
# a paste into a program that isn't reading, Ctrl-C and closing behind it, a lost view, damaged
# pid files, attaches at the same moment, Backspace over a character of three bytes, and servers
# and relays from before protocol versions.
#   scripts/e2e-session.sh [path to tiri-session]   (default: swift build's)
#   TIRI_SESSION_OLD=<a tiri-session from before> also checks old and new work together.
# Everything lives in its own folder under /tmp, and only what this starts is killed.
set -u
cd "$(dirname "$0")/.."

BIN="${1:-}"
if [ -z "$BIN" ]; then
  swift build --product tiri-session 2>&1 | tail -1
  BIN="$(swift build --show-bin-path)/tiri-session"
fi
[ -x "$BIN" ] || { echo "No tiri-session at $BIN" >&2; exit 1; }
OLD="${TIRI_SESSION_OLD:-}"
WORK="$(mktemp -d /tmp/tiri-session-test.XXXXXX)"
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1

passed=0
failed=0
pass() { passed=$((passed + 1)); echo "ok    $1"; }
fail() { failed=$((failed + 1)); echo "FAIL  $1"; }

# Every relay and writer this starts, and every server, found by its socket in this folder.
started=()
cleanup() {
  for pid in "${started[@]}"; do kill -9 "$pid" 2>/dev/null; done
  # Servers carry the command line they were started with. Their programs go when their terminals do.
  pkill -9 -f "attach $WORK/" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

wait_for() { # seconds, command...
  local tries=$(( $1 * 10 )); shift
  for _ in $(seq 1 "$tries"); do "$@" && return 0; sleep 0.1; done
  return 1
}
gone() { ! kill -0 "$1" 2>/dev/null; }
ticks() { grep -o 'tick' "$1" 2>/dev/null | wc -l | tr -d ' '; }

# A relay reading from a pipe this holds open. Sets RELAY, and FD to write keys to.
attach() { # name, binary, args... SOCKET=<name> attaches to another's socket
  local name="$1" binary="$2"; shift 2
  rm -f "$WORK/$name.in"; mkfifo "$WORK/$name.in"
  "$binary" attach "$WORK/${SOCKET:-$name}.sock" "$@" < "$WORK/$name.in" > "$WORK/$name.out" 2>&1 &
  RELAY=$!
  started+=("$RELAY")
  # The bash on a Mac is too old to pick a free descriptor itself.
  NEXT_FD=$(( ${NEXT_FD:-9} + 1 )); FD=$NEXT_FD
  eval "exec $FD<>\"\$WORK/\$name.in\""
}
exit_code() { if gone "$1"; then wait "$1" 2>/dev/null; echo $?; else echo "still running"; fi; }
# Typing into a relay that's stuck mustn't stick this too.
type_keys() { ( printf "$1" >&"$FD" ) & started+=($!); }

# MARK: A paste a program isn't reading

TICKER=(--cwd "$WORK" -- /bin/sh -c 'i=0; while :; do i=$((i+1)); echo tick$i; sleep 0.05; done')

attach paste "$BIN" "${TICKER[@]}"
wait_for 5 test -s "$WORK/paste.out" || fail "the ticker started"
sleep 0.5
# A megabyte, in lines, as a paste would be.
( awk 'BEGIN { line = sprintf("%099d", 0); for (i = 0; i < 10486; i++) print line }' >&"$FD" ) &
WRITER=$!; started+=("$WRITER")
sleep 1
before="$(ticks "$WORK/paste.out")"
sleep 2
after="$(ticks "$WORK/paste.out")"
if [ $((after - before)) -ge 15 ]; then pass "output keeps coming during a 1 MB paste ($((after - before)) lines in 2 s)"
else fail "output stopped during a paste: $((after - before)) lines in 2 s"; fi
wait_for 10 gone "$WRITER" && pass "the whole paste was taken" || fail "the paste is still being written"
type_keys '\003'
if wait_for 5 gone "$RELAY"; then
  code="$(exit_code "$RELAY")"
  [ "$code" = 130 ] && pass "Ctrl-C after the paste stops the program (exit $code)" || fail "Ctrl-C ended it with $code"
else
  fail "Ctrl-C after the paste did nothing"
fi
[ ! -e "$WORK/paste.sock" ] && pass "its socket is gone once it's done" || fail "its socket was left"

# More than the server holds: the relay holds the rest, and Ctrl-C still gets past it.
attach big "$BIN" "${TICKER[@]}"
wait_for 5 test -s "$WORK/big.out"
sleep 0.5
( awk 'BEGIN { line = sprintf("%099d", 0); for (i = 0; i < 40000; i++) print line }' >&"$FD" ) &
WRITER=$!; started+=("$WRITER")
sleep 1
before="$(ticks "$WORK/big.out")"
sleep 2
after="$(ticks "$WORK/big.out")"
[ $((after - before)) -ge 15 ] && pass "output keeps coming during a 4 MB paste ($((after - before)) lines in 2 s)" \
  || fail "output stopped during a 4 MB paste: $((after - before)) lines in 2 s"
wait_for 10 gone "$WRITER" || fail "the relay didn't take a 4 MB paste"
type_keys '\003'
if wait_for 5 gone "$RELAY"; then
  code="$(exit_code "$RELAY")"
  [ "$code" = 130 ] && pass "Ctrl-C after a 4 MB paste stops the program (exit $code)" || fail "Ctrl-C after 4 MB ended it with $code"
else
  fail "Ctrl-C after a 4 MB paste did nothing"
fi

# More than fits anywhere: the view waits, output still comes, and closing still works.
attach flood "$BIN" "${TICKER[@]}"
wait_for 5 test -s "$WORK/flood.out"
sleep 0.5
( awk 'BEGIN { line = sprintf("%099d", 0); for (i = 0; i < 200000; i++) print line }' >&"$FD" ) &
WRITER=$!; started+=("$WRITER")
sleep 2
gone "$WRITER" && fail "20 MB went somewhere: nothing waited" || pass "a 20 MB paste waits in the view, not in memory"
before="$(ticks "$WORK/flood.out")"
sleep 2
after="$(ticks "$WORK/flood.out")"
[ $((after - before)) -ge 15 ] && pass "output keeps coming while the view waits ($((after - before)) lines in 2 s)" \
  || fail "output stopped while the view waits: $((after - before)) lines in 2 s"
FLOOD_RELAY=$RELAY
# A second view takes over while all that waits, and sees the output.
SOCKET=flood attach flood2 "$BIN" --cwd "$WORK" -- /bin/sh -c 'echo never started'
wait_for 5 grep -q tick "$WORK/flood2.out" && pass "another view attaches while input waits" || fail "a second view got nothing"
grep -q 'never started' "$WORK/flood2.out" && fail "a second server was started"
wait_for 5 gone "$FLOOD_RELAY"
code="$(exit_code "$FLOOD_RELAY")"
[ "$code" = 254 ] && pass "the replaced view's relay says the session was lost, not ended (254)" || fail "the replaced view's relay exited $code"
program="$(head -1 "$WORK/flood.sock.pid")"
start="$(date +%s)"
"$BIN" kill "$WORK/flood.sock"
if gone "$program" && [ ! -e "$WORK/flood.sock" ]; then pass "closing works with input waiting ($(( $(date +%s) - start )) s)"
else fail "closing with input waiting left program $program"; fi
kill -9 "$WRITER" 2>/dev/null

# MARK: Losing the server

attach lost "$BIN" --cwd "$WORK" -- /bin/sh -c 'echo up; sleep 60'
wait_for 5 grep -q up "$WORK/lost.out"
server="$(head -1 "$WORK/lost.sock.server" 2>/dev/null)"
[ -n "$server" ] && [ "$server" != "$RELAY" ] && kill -0 "$server" && pass "the server's pid is written down" || fail "no server pid: '$server'"
kill -9 "$server"
wait_for 5 gone "$RELAY"
code="$(exit_code "$RELAY")"
[ "$code" = 254 ] && pass "a server that's gone is 254, not an exit" || fail "a server that's gone gave $code"
"$BIN" alive "$WORK/lost.sock"; code=$?
[ "$code" = 1 ] && pass "alive: a killed server is gone, from its pid" || fail "alive said $code for a killed server"

attach real "$BIN" --cwd "$WORK" -- /bin/sh -c 'sleep 0.5; exit 254'
wait_for 5 gone "$RELAY"
code="$(exit_code "$RELAY")"
"$BIN" alive "$WORK/real.sock"; alive=$?
[ "$code" = 254 ] && [ "$alive" = 1 ] && [ ! -e "$WORK/real.sock" ] && pass "a program's own 254 ends the session, so it can't look lost" \
  || fail "a program's own 254: relay $code, alive $alive"

# MARK: Pid files

attach pids "$BIN" --cwd "$WORK" -- /bin/sh -c 'echo up; sleep 60'
wait_for 5 grep -q up "$WORK/pids.out"
"$BIN" alive "$WORK/pids.sock" && pass "alive: a running one" || fail "alive: a running one said no"
server="$(head -1 "$WORK/pids.sock.server")"
: > "$WORK/pids.sock.pid"; : > "$WORK/pids.sock.server"
"$BIN" alive "$WORK/pids.sock"; code=$?
[ "$code" = 0 ] && [ -e "$WORK/pids.sock" ] && pass "alive: empty pid files don't make a running one dead" || fail "alive said $code with empty pid files"
rm -f "$WORK/pids.sock.pid" "$WORK/pids.sock.server"
"$BIN" alive "$WORK/pids.sock"; code=$?
[ "$code" = 0 ] && pass "alive: no pid files at all, and it asks the socket" || fail "alive said $code with no pid files"
# The server's number given to something else after a crash.
kill -9 "$server"; wait_for 5 gone "$RELAY"
sleep 60 & stranger=$!; started+=("$stranger")
echo "$stranger" > "$WORK/pids.sock.server"; echo "$stranger" > "$WORK/pids.sock.pid"
"$BIN" alive "$WORK/pids.sock"; code=$?
[ "$code" = 1 ] && pass "alive: a pid that now belongs to something else isn't the server" || fail "alive said $code for a reused pid"
if [ -n "$OLD" ]; then
  "$OLD" alive "$WORK/pids.sock" && echo "      (the old helper said that reused pid was alive)"
fi
# And an attach there starts afresh, since nothing listens.
attach pids "$BIN" --cwd "$WORK" -- /bin/sh -c 'echo fresh; sleep 60'
wait_for 5 grep -q fresh "$WORK/pids.out" && pass "a dead server's socket is replaced by a new one" || fail "attach to a dead server's socket: $(cat "$WORK/pids.out")"
written="$(head -1 "$WORK/pids.sock.server")"
[ "$written" != "$stranger" ] && kill -0 "$written" && pass "the new server's pid replaced the stale one" || fail "the stale server pid stayed"
ls "$WORK" | grep -q '\.tmp$' && fail "a temporary pid file was left" || pass "pid files are written whole, by rename"

# MARK: Attaches at the same moment

relays=()
for index in 1 2 3 4 5 6; do
  "$BIN" attach "$WORK/race.sock" --cwd "$WORK" -- /bin/sh -c "echo started >> '$WORK/race.log'; sleep 60" < /dev/null > /dev/null 2>&1 &
  relays+=($!); started+=($!)
done
sleep 2
count="$(wc -l < "$WORK/race.log" 2>/dev/null | tr -d ' ')"
[ "$count" = 1 ] && pass "six attaches at once start one program" || fail "six attaches at once started ${count:-0}"
servers="$(pgrep -f "attach $WORK/race.sock" | while read -r pid; do [ "$(ps -o ppid= -p "$pid" | tr -d ' ')" = 1 ] && echo "$pid"; done | wc -l | tr -d ' ')"
[ "$servers" = 1 ] && pass "and one server" || fail "and $servers servers"

# MARK: Characters of more than one byte

attach modes "$BIN" --cwd "$WORK" -- /bin/sh -c 'stty -a; sleep 1'
wait_for 5 gone "$RELAY"
grep -qw 'iutf8' "$WORK/modes.out" && ! grep -q -- '-iutf8' "$WORK/modes.out" && pass "the terminal has iutf8 on" || fail "iutf8 is off: $(grep -o -- '-*iutf8' "$WORK/modes.out")"

attach erase "$BIN" --cwd "$WORK" -- /bin/bash -c 'read -r -p "? " line; printf "[%s]" "$line" | od -An -tx1 | tr -d " \n"; echo; sleep 0.5'
wait_for 5 grep -q '?' "$WORK/erase.out"
sleep 0.5
type_keys '中文\177\r'
wait_for 5 gone "$RELAY"
grep -q '5be4b8ad5d' "$WORK/erase.out" && pass "Backspace in a plain prompt takes all of 文" || fail "Backspace over 文 left: $(tail -1 "$WORK/erase.out")"

# MARK: Old and new together

if [ -n "$OLD" ]; then
  attach oldserver "$OLD" --cwd "$WORK" -- /bin/sh -c 'echo up; read x; echo "got $x"; exit 7'
  wait_for 5 grep -q up "$WORK/oldserver.out"
  kill -9 "$RELAY"; wait "$RELAY" 2>/dev/null
  attach oldserver "$BIN"
  wait_for 5 grep -q up "$WORK/oldserver.out"
  sleep 0.5
  type_keys 'hello\r'
  wait_for 5 gone "$RELAY"
  code="$(exit_code "$RELAY")"
  grep -q 'got hello' "$WORK/oldserver.out" && [ "$code" = 7 ] && pass "a new relay works with an old server" || fail "new relay, old server: $code $(cat "$WORK/oldserver.out")"

  # A Ctrl-C behind a paste mustn't send an old server the signal only new ones know.
  attach oldflood "$OLD" "${TICKER[@]}"
  wait_for 5 test -s "$WORK/oldflood.out"
  kill -9 "$RELAY"; wait "$RELAY" 2>/dev/null
  attach oldflood "$BIN"
  sleep 1
  ( awk 'BEGIN { line = sprintf("%099d", 0); for (i = 0; i < 20000; i++) print line }' >&"$FD" ) &
  started+=($!)
  sleep 1
  type_keys '\003'
  sleep 1
  server="$(pgrep -f "attach $WORK/oldflood.sock" | while read -r pid; do [ "$(ps -o ppid= -p "$pid" | tr -d ' ')" = 1 ] && echo "$pid"; done)"
  [ -n "$server" ] && pass "a new relay never signals an old server" || fail "the old server died"

  attach newserver "$BIN" --cwd "$WORK" -- /bin/sh -c 'echo up; read x; echo "got $x"; exit 7'
  wait_for 5 grep -q up "$WORK/newserver.out"
  kill -9 "$RELAY"; wait "$RELAY" 2>/dev/null
  attach newserver "$OLD"
  wait_for 5 grep -q up "$WORK/newserver.out"
  sleep 0.5
  type_keys 'hello\r'
  wait_for 5 gone "$RELAY"
  code="$(exit_code "$RELAY")"
  grep -q 'got hello' "$WORK/newserver.out" && [ "$code" = 7 ] && pass "an old relay works with a new server" || fail "old relay, new server: $code $(cat "$WORK/newserver.out")"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
