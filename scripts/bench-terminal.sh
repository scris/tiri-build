#!/bin/bash
# Terminal speed on heavy output, in a test copy of Tiri, and optionally the same workloads in Ghostty.
#
#   scripts/bench-terminal.sh [--runs N] [--only ascii,sgr,unicode,wrap,seq,agent,idle] [--echo] [--sample SECONDS]
#
# Builds a release test copy named `bench` (scripts/dev-app.sh, so it never touches your own Tiri), writes
# the workloads once (scripts/bench-terminal-workloads.py says what each is), runs each in a new terminal and
# prints a JSON line per run. scripts/bench-terminal.py says what every field means.
#
# A test copy is hidden, and a hidden terminal parses but never draws: its display link doesn't tick
# (`frames` stays 0). So by default this measures everything up to drawing. To include drawing, run it
# when nobody is using this Mac, with the copy on screen:
#   TIRI_DEV_MAY_TAKE_FOCUS=yes scripts/bench-terminal.sh --visible
#
# Head to head with Ghostty, also only when nobody is using this Mac, since it opens a window:
#   TIRI_DEV_MAY_TAKE_FOCUS=yes scripts/bench-terminal.sh --ghostty /path/to/Ghostty.app
# Ghostty can't be read back, so its number is the writer's time: how long the workload took to be
# accepted, which for output this large is within a few hundredths of a second of it being shown. Compare
# it with Tiri's `writer`. Ghostty runs with its own defaults (no config files) at its default window size.
#
# Environment: TIRI_BENCH_DIR (default $TMPDIR/tiri-bench) holds the workloads and results.
set -euo pipefail
cd "$(dirname "$0")/.."
BENCH="${TIRI_BENCH_DIR:-${TMPDIR:-/tmp}/tiri-bench}"
WORK="$BENCH/work"; OUT="$BENCH/out"
ARGS=(); GHOSTTY=""; VISIBLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ghostty) GHOSTTY="${2:?Ghostty.app path}"; shift 2 ;;
    --visible) VISIBLE=yes; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
if { [ -n "$GHOSTTY" ] || [ -n "$VISIBLE" ]; } && [ "${TIRI_DEV_MAY_TAKE_FOCUS:-}" != "yes" ]; then
  echo "That puts a window on the screen. Only with TIRI_DEV_MAY_TAKE_FOCUS=yes, when nobody is using this Mac." >&2
  exit 65
fi

mkdir -p "$WORK/runs" "$OUT"
python3 -I scripts/bench-terminal-workloads.py "$WORK"

if [ -n "$GHOSTTY" ]; then
  runner="$PWD/scripts/bench-terminal-runner.py"
  mkdir -p "$WORK/signals"
  for name in ascii sgr unicode wrap seq agent; do
    case "$name" in seq) cmd=(seq 1 5000000) ;; *) cmd=(cat "$WORK/$name.txt") ;; esac
    token="ghostty-$name-$$"; go="$WORK/signals/$token.go"; result="$WORK/signals/$token.json"
    rm -f "$go" "$go.ready" "$result"
    "$GHOSTTY/Contents/MacOS/ghostty" --config-default-files=false --quit-after-last-window-closed=true \
      -e /usr/bin/env TIRI_BENCH_EXIT=1 python3 -I "$runner" "$go" "$result" "$token" -- "${cmd[@]}" >/dev/null 2>&1 &
    ghostty_pid=$!
    for _ in $(seq 1 200); do [ -s "$go.ready" ] && break; sleep 0.1; done
    sleep 0.5; : >"$go"
    for _ in $(seq 1 3000); do [ -s "$result" ] && break; sleep 0.1; done
    python3 -I -c "import json,sys; t=json.load(open(sys.argv[1])); print(json.dumps({'terminal': 'ghostty', 'workload': sys.argv[2], 'writer': round(t['end'] - t['start'], 3)}))" "$result" "$name" \
      | tee -a "$OUT/ghostty.jsonl"
    kill "$ghostty_pid" 2>/dev/null || true
    wait "$ghostty_pid" 2>/dev/null || true
  done
fi

export TIRI_DEV_ROOT="$BENCH/dev"
if [ -n "$VISIBLE" ]; then
  TIRI_DEV_CONFIG=release TIRI_DEV_MAY_TAKE_FOCUS=yes scripts/dev-app.sh start bench >/dev/null
else
  TIRI_DEV_CONFIG=release scripts/dev-app.sh start bench >/dev/null
fi
trap 'scripts/dev-app.sh stop bench >/dev/null 2>&1 || true' EXIT
scripts/dev-app.sh cli bench workspace new bench --folder "$WORK/runs" >/dev/null 2>&1 || scripts/dev-app.sh cli bench workspace switch bench >/dev/null
pid="$(cat "$TIRI_DEV_ROOT/bench/pid")"
[ -n "$pid" ] || { echo "The test copy didn't start." >&2; exit 70; }
TIRI_SOCKET=/tmp/tiri-dev-bench.sock python3 -I scripts/bench-terminal.py --work "$WORK" --out "$OUT" --app-pid "$pid" \
  --label "tiri-$(date +%Y%m%d-%H%M%S)" ${ARGS[@]+"${ARGS[@]}"} | tee -a "$OUT/tiri.jsonl"
