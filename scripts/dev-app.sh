#!/bin/bash
# A throwaway copy of Tiri that can't touch the real one: its own bundle ID, state, config and socket.
#   scripts/dev-app.sh start <name>      build (debug), assemble and launch
#   scripts/dev-app.sh stop <name>       quit it and end its terminals
#   scripts/dev-app.sh shot <name> <png> capture its main window, whatever is in front of it
#   scripts/dev-app.sh focus <name> -- cmd…  hold the screen, bring it forward and run cmd (real clicks and keys)
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

window_id() { # the app's largest on-screen window
  swift - "$1" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var best = (0, 0.0)
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0
    && (w[kCGWindowIsOnscreen as String] as? Bool) == true {
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
  pkill -9 -f "$APP/Contents/MacOS/Tiri" 2>/dev/null || true
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$TIRI_HOME" "$TIRI_CONFIG_HOME"
  cp "$BIN/TiriApp" "$APP/Contents/MacOS/Tiri"
  cp "$BIN/tiri" "$BIN/tiri-session" "$APP/Contents/Resources/bin/"
  cp Resources/AppIcon.icns Resources/highlight.min.js "$APP/Contents/Resources/"
  for extra in Resources/remote Resources/web; do [ -e "$extra" ] && cp -R "$extra" "$APP/Contents/Resources/"; done
  sed "s/dev.tiri.app/dev.tiri.test.$NAME/" Resources/Info.plist > "$APP/Contents/Info.plist"
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
  nohup "$APP/Contents/MacOS/Tiri" >"$DIR/app.log" 2>&1 &
  echo $! > "$DIR/pid"
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
  shift 2; [ "${1:-}" = "--" ] && shift
  take_screen; raise
  "$@"
  ;;
shot)
  take_screen; raise
  screencapture -x -o -l"$(window_id "$(cat "$DIR/pid")")" "${3:?png path}"
  ;;
env)
  echo "export TIRI_HOME='$TIRI_HOME' TIRI_CONFIG_HOME='$TIRI_CONFIG_HOME' TIRI_SOCKET='$TIRI_SOCKET' PATH='$APP/Contents/Resources/bin':\"\$PATH\""
  ;;
cli)
  shift 2; exec "$CLI" "$@"
  ;;
*) echo "unknown action $ACTION" >&2; exit 64 ;;
esac
