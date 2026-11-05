#!/bin/bash
# A throwaway copy of Tiri that can't touch the real one: its own bundle ID, state, config and socket.
#   scripts/dev-app.sh start <name>      build (debug), assemble and launch
#   scripts/dev-app.sh run <name>        launch what's already assembled, without building
#   scripts/dev-app.sh stop <name>       quit it and end its terminals
#   scripts/dev-app.sh shot <name> <png> capture its main window, whatever is in front of it
#   scripts/dev-app.sh focus <name> -- cmd…  takes the keyboard, so needs TIRI_DEV_MAY_TAKE_FOCUS=yes, for this and to start it: for when nobody's using this Mac
# A copy hides itself as an app, because Stage Manager brings any window back on screen. Only with
# TIRI_DEV_MAY_TAKE_FOCUS=yes at the start is it visible and clickable. If one reaches the screen, it's stopped.
#   scripts/dev-app.sh env <name>        prints `export ...` lines; `eval` them to use its CLI
#   scripts/dev-app.sh cli <name> ...    runs its `tiri`
# Never run ./build.sh to test while someone's Tiri is open: it deletes the running app.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}"
ACTION="${1:?start|stop|shot|env|cli}"; NAME="${2:-dev}"
DIR="$ROOT/$NAME"; APP="$DIR/TiriDev.app"
export TIRI_HOME="$DIR/home" TIRI_CONFIG_HOME="$DIR/config" TIRI_SOCKET="/tmp/tiri-dev-$NAME.sock"
CLI="$APP/Contents/Resources/bin/tiri"

# Only one tester can have the screen. Held briefly around anything needing focus.
LOCK="${TMPDIR:-/tmp}/tiri-focus.lock"
take_screen() {
  local waited=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    sleep 0.5; waited=$((waited + 1))
    if [ "$waited" -gt 240 ]; then rmdir "$LOCK" 2>/dev/null || true; fi
  done
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}
raise() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $(cat "$DIR/pid")) to true" >/dev/null 2>&1 || true
  sleep 0.8
}
# A test copy never comes forward by itself: someone may be working on this Mac.
launch_in_background() {
  : >"$DIR/app.log"
  open -g -n -a "$APP" --stdout "$DIR/app.log" --stderr "$DIR/app.log" \
    --env TIRI_HOME="$TIRI_HOME" --env TIRI_CONFIG_HOME="$TIRI_CONFIG_HOME" --env TIRI_SOCKET="$TIRI_SOCKET" --env TIRI_DEV_OFFSCREEN=1 \
    ${TIRI_DEV_MAY_TAKE_FOCUS:+--env TIRI_DEV_VISIBLE=1} \
    ${TIRI_SSH_CONFIG:+--env TIRI_SSH_CONFIG="$TIRI_SSH_CONFIG"} \
    ${TIRI_CONVERSATIONS_HOME:+--env TIRI_CONVERSATIONS_HOME="$TIRI_CONVERSATIONS_HOME"} \
    ${CODEX_HOME:+--env CODEX_HOME="$CODEX_HOME"} ${GROK_HOME:+--env GROK_HOME="$GROK_HOME"}
  for _ in $(seq 1 50); do
    pid="$(pgrep -f "$NAME/TiriDev.app/Contents/MacOS/Tiri" | head -1 || true)"
    [ -n "$pid" ] && break
    sleep 0.1
  done
  echo "${pid:-}" > "$DIR/pid"
  if [ -n "${pid:-}" ] && [ "${TIRI_DEV_MAY_TAKE_FOCUS:-}" != "yes" ]; then stop_if_on_screen "$pid"; fi
}

# Someone may be using this Mac. A test copy that reaches their screen is stopped, and that's a failure.
stop_if_on_screen() {
  local found
  sleep 0.4
  found="$(swift - "$1" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
var displays = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &displays, &count)
let screens = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0
    && (w[kCGWindowIsOnscreen as String] as? Bool) == true {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let frame = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    if frame.width > 100, screens.contains(where: { $0.intersects(frame) }) { print(Int(frame.minX), Int(frame.minY)) }
}
SWIFT
)"
  if [ -n "$found" ]; then
    kill -9 "$1" 2>/dev/null || true
    echo "The test copy's window reached the screen, at $found, so it was stopped." >&2
    exit 70
  fi
}

window_id() { # the app's largest window, which is hidden from the screen but still draws
  swift - "$1" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var best = (0, 0.0)
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if area > best.1 { best = (w[kCGWindowNumber as String] as? Int ?? 0, area) }
}
print(best.0)
SWIFT
}

case "$ACTION" in
start)
  swift build -c "${TIRI_DEV_CONFIG:-debug}" --product TiriApp 2>&1 | tail -1
  swift build -c "${TIRI_DEV_CONFIG:-debug}" --product tiri 2>&1 | tail -1
  swift build -c "${TIRI_DEV_CONFIG:-debug}" --product tiri-session 2>&1 | tail -1
  BIN="$(swift build -c "${TIRI_DEV_CONFIG:-debug}" --show-bin-path)"
  "$CLI" quit >/dev/null 2>&1 || true; sleep 0.5
  # A dialog can hold up a quit, and two copies can't share a socket.
  [ -f "$DIR/pid" ] && kill -9 "$(cat "$DIR/pid")" 2>/dev/null || true
  pkill -9 -f "$NAME/TiriDev.app/Contents/MacOS/Tiri" 2>/dev/null || true
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$TIRI_HOME" "$TIRI_CONFIG_HOME"
  cp "$BIN/TiriApp" "$APP/Contents/MacOS/Tiri"
  cp "$BIN/tiri" "$BIN/tiri-session" "$APP/Contents/Resources/bin/"
  cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
  for extra in Resources/remote Resources/web Resources/textmate Resources/grammars Resources/language-servers; do [ -e "$extra" ] && cp -R "$extra" "$APP/Contents/Resources/"; done
  sed "s/dev.tiri.app/dev.tiri.test.$NAME/" Resources/Info.plist > "$APP/Contents/Info.plist"
  # TIRI_DEV_SIGN_IDENTITY tries it as a release runs: signed, under the hardened runtime.
  if [ -n "${TIRI_DEV_SIGN_IDENTITY:-}" ]; then
    for program in "$APP/Contents/Resources/bin/tiri" "$APP/Contents/Resources/bin/tiri-session" "$APP"/Contents/Resources/remote/tiri-remote-darwin-*; do
      codesign --force --sign "$TIRI_DEV_SIGN_IDENTITY" --options runtime --timestamp=none "$program" >/dev/null 2>&1
    done
    codesign --force --sign "$TIRI_DEV_SIGN_IDENTITY" --options runtime --timestamp=none --entitlements Resources/Tiri.entitlements "$APP" >/dev/null 2>&1
  else
    codesign --force --sign - --timestamp=none --entitlements Resources/Tiri.entitlements "$APP" >/dev/null 2>&1
  fi
  launch_in_background
  for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done
  "$CLI" ping
  ;;
run)
  # Always through here: launched by hand, without these variables, it would be using real state.
  [ -f "$DIR/pid" ] && kill -9 "$(cat "$DIR/pid")" 2>/dev/null || true
  launch_in_background
  for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done
  "$CLI" ping
  ;;
stop)
  "$CLI" quit >/dev/null 2>&1 || true; sleep 0.3
  [ -f "$DIR/pid" ] && kill "$(cat "$DIR/pid")" 2>/dev/null || true
  pkill -f "tiri-session attach /tmp/tiri-$(id -u)-$(printf %s "$TIRI_HOME" | shasum -a 256 | cut -c1-12)/" 2>/dev/null || true
  ;;
focus)
  # With Stage Manager on, a window in the strip is a thumbnail until its app comes forward.
  # That takes the keyboard from whoever is using this Mac, so it has to be asked for by name.
  if [ "${TIRI_DEV_MAY_TAKE_FOCUS:-}" != "yes" ]; then
    echo "focus takes the keyboard. Only with TIRI_DEV_MAY_TAKE_FOCUS=yes, when nobody is using this Mac." >&2
    exit 65
  fi
  shift 2; [ "${1:-}" = "--" ] && shift
  take_screen; raise
  "$@"
  ;;
shot)
  # By window, without raising it. The copy keeps itself hidden, and this reads what it drew.
  screencapture -x -o -l"$(window_id "$(cat "$DIR/pid")")" "${3:?png path}"
  ;;
env)
  echo "export TIRI_HOME='$TIRI_HOME' TIRI_CONFIG_HOME='$TIRI_CONFIG_HOME' TIRI_SOCKET='$TIRI_SOCKET' PATH='$APP/Contents/Resources/bin':\"\$PATH\""
  ;;
cli)
  # Never from the repository: a `tiri term` starts where it's run, and this copy touching ~/Documents
  # makes macOS show a permission dialog on the screen of whoever's using this Mac.
  shift 2; cd "$DIR"; exec "$CLI" "$@"
  ;;
*) echo "unknown action $ACTION" >&2; exit 64 ;;
esac
