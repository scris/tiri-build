#!/bin/bash
# A throwaway copy of Tiri that can't touch the real one: its own bundle ID, state, config and socket.
#   scripts/dev-app.sh start <name>      build (debug), assemble and launch
#   scripts/dev-app.sh run <name>        launch what's already assembled, without building
#   scripts/dev-app.sh stop <name>       quit it and end its terminals
#   scripts/dev-app.sh shot <name> <png> capture its main window, whatever is in front of it
#   scripts/dev-app.sh focus <name> -- cmd…  takes the keyboard, so needs TIRI_DEV_MAY_TAKE_FOCUS=yes, for this and to start it: for when nobody's using this Mac
# A copy hides itself as an app, because Stage Manager brings any window back on screen. Only with
# TIRI_DEV_MAY_TAKE_FOCUS=yes at the start is it visible and clickable. If one reaches the screen, it's stopped.
# TIRI_DEV_MAC_ACCENT=blue makes it act as if this Mac's accent were blue, to see "Your Mac" against Tiri Pink.
# TIRI_DEV_A11Y=transparency,contrast,motion makes it act as if Reduce Transparency, Increase Contrast or Reduce
# Motion were on, without touching this Mac's settings. `cli <name> dev-a11y <list|none>` changes it live.
# TIRI_DEV_LANGUAGE=zh-Hans|zh-Hant|settings: a test copy is in English otherwise, so checks that read words pass on any Mac.
# TIRI_UPDATE_FEED=http://127.0.0.1:<port>/update.json gives it a release feed on this Mac. TIRI_DEV_APPLICATIONS=<folder> is where
# Move to Applications puts it: a test copy never moves into the real one.
# TIRI_DEV_WELCOME=1 shows the first launch's welcome, which test copies otherwise skip. TIRI_DEV_LOOKING=1
# acts as if someone were looking at its window, which a hidden copy never is, for what waits for that.
# CLAUDE_CONFIG_DIR, CODEX_HOME, GROK_HOME=<empty folder> make it see an agent with no hooks, as a newcomer's would be.
# TIRI_DEV_NO_DEVELOPER_TOOLS=1 makes it act as if this Mac had no Command Line Tools, as a fresh Mac doesn't; =all, as if it had no git anywhere.
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
# Only ever what the pid file says if that's still a copy of this name. A pid outlives its process in that file,
# and pids get used again: on 2026-11-05, a stale one killed the script that was running this.
kill_recorded() { # signal
  [ -f "$DIR/pid" ] || return 0
  local recorded; recorded="$(cat "$DIR/pid")"
  [ -n "$recorded" ] || return 0
  case "$(ps -p "$recorded" -o command= 2>/dev/null)" in
    *"$NAME/TiriDev.app/Contents/MacOS/Tiri"*|*"$NAME/home/your-tiri/copies/"*) kill "$1" "$recorded" 2>/dev/null || true ;;
  esac
}

# The copy that's up: this one, or a personal copy it made and handed over to.
running_pid() { pgrep -f "$NAME/(TiriDev.app|home/your-tiri/copies/[^/]+/Tiri.app)/Contents/MacOS/Tiri" | tail -1 || true; }

# A test copy never comes forward by itself: someone may be working on this Mac.
launch_in_background() {
  : >"$DIR/app.log"
  open -g -n -a "$APP" --stdout "$DIR/app.log" --stderr "$DIR/app.log" \
    --env TIRI_HOME="$TIRI_HOME" --env TIRI_CONFIG_HOME="$TIRI_CONFIG_HOME" --env TIRI_SOCKET="$TIRI_SOCKET" --env TIRI_DEV_OFFSCREEN=1 \
    ${TIRI_DEV_MAY_TAKE_FOCUS:+--env TIRI_DEV_VISIBLE=1} \
    ${TIRI_DEV_OPTION:+--env TIRI_DEV_OPTION=1} \
    ${TIRI_DEV_MAC_ACCENT:+--env TIRI_DEV_MAC_ACCENT="$TIRI_DEV_MAC_ACCENT"} \
    ${TIRI_DEV_A11Y:+--env TIRI_DEV_A11Y="$TIRI_DEV_A11Y"} \
    --env TIRI_DEV_LANGUAGE="${TIRI_DEV_LANGUAGE:-en}" \
    ${TIRI_DEV_NO_DEVELOPER_TOOLS:+--env TIRI_DEV_NO_DEVELOPER_TOOLS="$TIRI_DEV_NO_DEVELOPER_TOOLS"} \
    ${TIRI_SSH_CONFIG:+--env TIRI_SSH_CONFIG="$TIRI_SSH_CONFIG"} \
    ${TIRI_UPDATE_FEED:+--env TIRI_UPDATE_FEED="$TIRI_UPDATE_FEED"} \
    ${TIRI_CONVERSATIONS_HOME:+--env TIRI_CONVERSATIONS_HOME="$TIRI_CONVERSATIONS_HOME"} \
    ${CODEX_HOME:+--env CODEX_HOME="$CODEX_HOME"} ${GROK_HOME:+--env GROK_HOME="$GROK_HOME"} \
    ${CLAUDE_CONFIG_DIR:+--env CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"} \
    ${TIRI_DEV_WELCOME:+--env TIRI_DEV_WELCOME=1} ${TIRI_DEV_LOOKING:+--env TIRI_DEV_LOOKING=1} \
    ${TIRI_DEV_APPLICATIONS:+--env TIRI_DEV_APPLICATIONS="$TIRI_DEV_APPLICATIONS"}
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
  source scripts/swift-setup.sh
  # TIRI_DEV_SWIFT_FLAGS: the fast build of a change, so a check doesn't build everything again.
  # shellcheck disable=SC2086
  swift build -c "${TIRI_DEV_CONFIG:-debug}" ${TIRI_DEV_SWIFT_FLAGS:-} --product TiriApp 2>&1 | tail -1
  swift build -c "${TIRI_DEV_CONFIG:-debug}" ${TIRI_DEV_SWIFT_FLAGS:-} --product tiri 2>&1 | tail -1
  swift build -c "${TIRI_DEV_CONFIG:-debug}" ${TIRI_DEV_SWIFT_FLAGS:-} --product tiri-session 2>&1 | tail -1
  BIN="$(swift build -c "${TIRI_DEV_CONFIG:-debug}" ${TIRI_DEV_SWIFT_FLAGS:-} --show-bin-path)"
  "$CLI" quit >/dev/null 2>&1 || true; sleep 0.5
  # A dialog can hold up a quit, and two copies can't share a socket.
  kill_recorded -9
  pkill -9 -f "$NAME/(TiriDev.app|home/your-tiri/copies/[^/]+/Tiri.app)/Contents/MacOS/Tiri" 2>/dev/null || true
  rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$TIRI_HOME" "$TIRI_CONFIG_HOME"
  cp "$BIN/TiriApp" "$APP/Contents/MacOS/Tiri"
  cp "$BIN/tiri" "$BIN/tiri-session" "$APP/Contents/Resources/bin/"
  cp Resources/AppIcon.icns Resources/Assets.car "$APP/Contents/Resources/"
  for extra in Resources/remote Resources/web Resources/textmate Resources/grammars Resources/language-servers; do [ -e "$extra" ] && cp -R "$extra" "$APP/Contents/Resources/"; done
  cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
  sed "s/dev.tiri.app/dev.tiri.test.$NAME/" Resources/Info.plist > "$APP/Contents/Info.plist"
  scripts/stamp-bundle.sh "$APP" "$APP/Contents/Info.plist" >/dev/null
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
  # TIRI_DEV_APP_PATH=<a copy of this one elsewhere>, a disk image say, runs that instead, with this copy's state. Its path has to end
  # in <name>/TiriDev.app, as a volume named <name> does, for stop to find it.
  if [ -n "${TIRI_DEV_APP_PATH:-}" ]; then APP="$TIRI_DEV_APP_PATH"; fi
  # Always through here: launched by hand, without these variables, it would be using real state.
  kill_recorded -9
  launch_in_background
  for _ in $(seq 1 100); do "$CLI" ping >/dev/null 2>&1 && break; sleep 0.1; done
  "$CLI" ping
  ;;
stop)
  "$CLI" quit >/dev/null 2>&1 || true; sleep 0.3
  kill_recorded -TERM
  pkill -f "$NAME/(TiriDev.app|home/your-tiri/copies/[^/]+/Tiri.app)/Contents/MacOS/Tiri" 2>/dev/null || true
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
  screencapture -x -o -l"$(window_id "$(running_pid)")" "${3:?png path}"
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
