#!/bin/bash
# Your Tiri against a real, invisible test copy: a change made with the real tools, built and signed for real,
# tried, kept, undone, turned off, a copy that won't start, and a change shared and opened in a friend's Tiri.
# Stand-in for the agent: this script.
#   TIRI_DEV_ROOT=<somewhere> scripts/e2e-your-tiri.sh      TIRI_E2E_SHOTS=<folder> also takes pictures of sharing
# Takes a few minutes the first time, since it builds Tiri from its own source twice.
set -u
cd "$(dirname "$0")/.."
# Copies of Tiri in debug mode, a fraction of a release build's time; what's tested isn't the optimizer.
# TIRI_DEV_COPY_CONFIG=release makes them as a real change does.
export TIRI_DEV_COPY_CONFIG="${TIRI_DEV_COPY_CONFIG:-debug}"
# And all in one build folder, kept between runs, so the packages Tiri uses compile once, not in every fresh source folder.
export TIRI_SCRATCH_PATH="${TIRI_SCRATCH_PATH:-${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}/swift-build-cache}"
REPO="$PWD"
NAME="${TIRI_E2E_NAME:-yte2e}"
ROOT="${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}"
export TIRI_DEV_ROOT="$ROOT"
scripts/dev-app.sh stop "$NAME" >/dev/null 2>&1
rm -rf "${ROOT:?}/${NAME:?}"
scripts/dev-app.sh start "$NAME" >/dev/null 2>&1
eval "$(scripts/dev-app.sh env "$NAME")"
Y="$TIRI_HOME/your-tiri"
PLAIN="$ROOT/$NAME/TiriDev.app"
WORK="$ROOT/$NAME/project"; mkdir -p "$WORK"; cd "$WORK"
trap 'cd "$REPO"; scripts/dev-app.sh stop "$NAME" >/dev/null 2>&1' EXIT

passed=0; failed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
no() { failed=$((failed + 1)); echo "FAIL  $1"; }
expect() { local name="$1" needle="$2"; shift 2; local output; output="$("$@" 2>&1)"
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: expected \"$needle\" in: $output"; fi; }
lacks() { local name="$1" needle="$2"; shift 2; local output; output="$("$@" 2>&1)"
  if [[ "$output" != *"$needle"* ]]; then ok "$name"; else no "$name: found \"$needle\" in: $output"; fi; }
refuses() { local name="$1" needle="$2"; shift 2; local output; if output="$("$@" 2>&1)"; then no "$name: should have been refused, said: $output"; return; fi
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: refused, but said: $output"; fi; }
waits() { local name="$1" needle="$2" tries="$3"; shift 3; local output=""
  for _ in $(seq 1 "$tries"); do output="$("$@" 2>&1)"; if [[ "$output" == *"$needle"* ]]; then ok "$name"; return 0; fi; sleep 0.1; done
  no "$name: expected \"$needle\" in: $output"; return 1; }
where() { tiri dev-your-tiri where; }
field() { python3 -c "import json,sys;print(json.load(open('$Y/state.json')).get('$1'))"; }
draft_id() { python3 -c "import json;print(json.load(open('$Y/draft.json'))['id'])"; }

# A change, the way an agent makes one.
make_change() { # sentence, text the version line gains
  tiri change start "$1" >/dev/null || no "start: $1"
  local id; id="$(draft_id)"
  (cd "$Y/source" && perl -pi -e "s/(return \\.printText\\(\"tiri \\\\\\(TiriCoreVersion\\.string\\))/\$1 $2/" Sources/TiriCore/CLI.swift
   mkdir -p checks; printf '#!/bin/bash\ntiri --version | grep -q %s\n' "$2" > "checks/$id.sh")
  tiri change build >/dev/null || no "build: $1"
  tiri change ready >/dev/null 2>&1 || no "ready: $1"
}

echo "--- someone who has never used this"
expect "Settings shows what this is" yourTiri where
expect "the entries are there" '"offers" : true' where
expect "it can tell this Mac has Swift" '"swiftTools" : true' where
if [ ! -e "$Y/state.json" ]; then ok "no state file"; else no "a state file exists already"; fi
expect "plain says it's plain" '"personal" : false' where
refuses "an agent can't switch" "usage" tiri change try

echo "--- making one"
tiri term --cwd "$WORK" --cmd "echo \$\$ > $WORK/program.pid; while true; do date +%s >> $WORK/counter.txt; sleep 0.2; done" >/dev/null
for _ in $(seq 1 100); do [ -s "$WORK/counter.txt" ] && break; sleep 0.1; done
if [ -s "$WORK/counter.txt" ]; then ok "a program is running"; else no "no program running"; fi
PROGRAM="$(cat "$WORK/program.pid")"
make_change "Say first in the version" first
if kill -0 "$PROGRAM" 2>/dev/null; then ok "making a change left the program alone"; else no "making a change ended the program $PROGRAM, now $(cat "$WORK/program.pid")"; fi
expect "the list has it" "Say first in the version" tiri change list
expect "it has a check" "check" tiri change list
expect "it's waiting" "waiting for the person" tiri change status
if [ -d "$Y/copies/ready/Tiri.app" ]; then ok "a copy is ready"; else no "no copy ready"; fi
expect "signed with the personal identity" "Authority=Tiri Personal" codesign -dvv "$Y/copies/ready/Tiri.app"
expect "under the hardened runtime" "runtime" codesign -dvv "$Y/copies/ready/Tiri.app"
codesign --verify --deep --strict "$Y/copies/ready/Tiri.app" 2>/dev/null && ok "the signature verifies" || no "the signature doesn't verify"
expect "with its own bundle ID" "dev.tiri.test.$NAME.personal" /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$Y/copies/ready/Tiri.app/Contents/Info.plist"
FIRST_REQUIREMENT="$(codesign -d -r- "$Y/copies/ready/Tiri.app" 2>&1 | tail -1)"
waits "the pane is there now" yourTiri 30 where
expect "nothing has switched" '"personal" : false' where
waits "it's on offer" "Say first in the version" 30 where

echo "--- trying it"
BEFORE="$(cd "$PLAIN" && shasum Contents/MacOS/Tiri)"
tiri dev-your-tiri try >/dev/null
waits "the new copy is running" '"personal" : true' 150 where
expect "from the stable place" "copies/current/Tiri.app" where
expect "it's being tried" "Say first in the version" where
expect "the new tiri is the changed one" "first" "$Y/copies/current/Tiri.app/Contents/Resources/bin/tiri" --version
if [ "$(cd "$PLAIN" && shasum Contents/MacOS/Tiri)" = "$BEFORE" ]; then ok "the installed app wasn't touched"; else no "the installed app changed"; fi
if kill -0 "$PROGRAM" 2>/dev/null; then ok "the program lived through the switch"; else no "the program died in the switch: was $PROGRAM, now $(cat "$WORK/program.pid")"; fi
A="$(wc -l < "$WORK/counter.txt")"; sleep 1; B="$(wc -l < "$WORK/counter.txt")"
if [ "$B" -gt "$A" ]; then ok "and it's still working"; else no "the program stopped writing"; fi
waits "the terminal came back" "project" 50 tiri items
sleep 11
if pgrep -f "$PLAIN/Contents/MacOS/Tiri" >/dev/null; then no "the launcher is still there after it settled"; else ok "the launcher went away"; fi
[ "$(field attempts)" = "0" ] && ok "it counts as having started" || no "attempts is $(field attempts)"

echo "--- going back"
tiri dev-your-tiri back >/dev/null
waits "plain again" '"personal" : false' 150 where
expect "from where it's installed" "TiriDev.app" where
expect "the change is kept, off" "off  Say first" tiri change list
if kill -0 "$PROGRAM" 2>/dev/null; then ok "the program lived through going back"; else no "the program died going back"; fi

echo "--- switches"
ID="$(tiri change list | awk '{print $1}' | head -1)"
tiri change on "$ID" >/dev/null 2>&1 || no "turning on"
expect "on again" "on   Say first" tiri change list
waits "the app knows" '"ready" : "Turn on' 50 where
tiri dev-your-tiri try >/dev/null
waits "and running" '"personal" : true' 150 where
tiri dev-your-tiri keep >/dev/null
sleep 0.2
[ "$(field trial)" = "None" ] && ok "keep ends the trial" || no "still a trial: $(field trial)"

echo "--- a second change, and back to the first"
make_change "Say second in the version" second
expect "both on" "Say second" tiri change list
SECOND_REQUIREMENT="$(codesign -d -r- "$Y/copies/ready/Tiri.app" 2>&1 | tail -1)"
if [ "$FIRST_REQUIREMENT" = "$SECOND_REQUIREMENT" ] && [ -n "$FIRST_REQUIREMENT" ]; then ok "every build has the same designated requirement"; else no "requirements differ: $FIRST_REQUIREMENT / $SECOND_REQUIREMENT"; fi
waits "the app knows" '"ready" : "Say second in the version"' 50 where
tiri dev-your-tiri try >/dev/null
waits "the second copy comes up" '"trial" : "Say second in the version"' 150 where
expect "this copy has both" "second first" "$Y/copies/current/Tiri.app/Contents/Resources/bin/tiri" --version
tiri dev-your-tiri back >/dev/null
sleep 0.5
waits "back to the first copy" '"personal" : true' 150 where
waits "with no trial" '"trial" : ""' 50 where
lacks "without the second" "second" "$Y/copies/current/Tiri.app/Contents/Resources/bin/tiri" --version
expect "the second is kept, off" "off  Say second" tiri change list

echo "--- plain tiri, and back, quicker than the launcher goes away"
tiri dev-your-tiri plain >/dev/null
sleep 0.3
waits "plain" '"personal" : false' 150 where
tiri dev-your-tiri yours >/dev/null
sleep 0.3
waits "yours" '"personal" : true' 150 where
tiri dev-your-tiri plain >/dev/null
sleep 0.3
waits "plain, at once" '"personal" : false' 150 where
tiri dev-your-tiri yours >/dev/null
sleep 0.3
waits "yours, for what follows" '"personal" : true' 150 where

echo "--- option held at launch"
tiri quit >/dev/null; sleep 0.6
(cd "$REPO" && TIRI_DEV_OPTION=1 scripts/dev-app.sh run "$NAME" >/dev/null 2>&1)
waits "plain for now" '"plainForNow" : true' 50 where
expect "and it is plain" '"personal" : false' where
[ "$(field active)" = "personal" ] && ok "next time is still yours" || no "the choice changed: $(field active)"
tiri quit >/dev/null; sleep 0.6

echo "--- a copy that won't start"
cp "$Y/copies/current/Tiri.app/Contents/MacOS/Tiri" "$WORK/good-binary"
printf '#!/bin/sh\nexit 3\n' > "$Y/copies/current/Tiri.app/Contents/MacOS/Tiri"
chmod +x "$Y/copies/current/Tiri.app/Contents/MacOS/Tiri"
(cd "$REPO" && scripts/dev-app.sh run "$NAME" >/dev/null 2>&1)
waits "tiri falls back by itself" '"personal" : false' 300 where
sleep 0.5
[ "$(field active)" = "plain" ] && ok "and remembers" || no "active is $(field active)"
cp "$WORK/good-binary" "$Y/copies/current/Tiri.app/Contents/MacOS/Tiri"
tiri quit >/dev/null; sleep 0.6

echo "--- a copy that's signed properly and dies at launch"
printf 'int main(void) { return 3; }\n' > "$WORK/dies.c"
clang "$WORK/dies.c" -o "$Y/copies/current/Tiri.app/Contents/MacOS/Tiri"
"$Y/source/scripts/personal-identity.sh" "$Y/identity" >/dev/null
codesign --force --sign "$(cat "$Y/identity/hash")" --keychain "$Y/identity/personal.keychain-db" --options runtime --timestamp=none "$Y/copies/current/Tiri.app" 2>/dev/null
python3 - "$Y/state.json" <<'PY'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s['active']='personal'; s['attempts']=0; json.dump(s,open(p,'w'))
PY
(cd "$REPO" && scripts/dev-app.sh run "$NAME" >/dev/null 2>&1)
waits "tiri falls back by itself again" '"personal" : false' 300 where
sleep 0.5
[ "$(field active)" = "plain" ] && ok "and remembers again" || no "active is $(field active)"
expect "with nothing left to say next time" "None" field notice

echo "--- sharing a change"
# TIRI_E2E_SHOTS=<folder> also takes pictures of what sharing shows, for a person to look at.
SHOTS="${TIRI_E2E_SHOTS:-}"
copy_pid() { pgrep -f "$NAME/(TiriDev.app|home/your-tiri/copies/[^/]+/Tiri.app)/Contents/MacOS/Tiri" | tail -1; }
shot() { [ -z "$SHOTS" ] || (cd "$REPO" && scripts/dev-app.sh shot "$NAME" "$SHOTS/$1.png" >/dev/null 2>&1) || true; }
sheet_shot() { # a sheet is a window of its own, inside the main one
  [ -n "$SHOTS" ] || return 0
  sleep 2
  local id; id="$(swift - "$(copy_pid)" 2>/dev/null <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .map { w -> (Int, CGRect) in
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (w[kCGWindowNumber as String] as? Int ?? 0, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
    }
    .sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
let sheet = windows.dropFirst().first { windows[0].1.contains($0.1) && $0.1.width > 100 }
print(sheet?.0 ?? 0)
SWIFT
)"
  [ "${id:-0}" != "0" ] && screencapture -x -o -l"$id" "$SHOTS/$1.png" || no "no sheet to take a picture of for $1"
}
FIRST="$(tiri change list | awk '/Say first/ {print $1}')"
SECOND="$(tiri change list | awk '/Say second/ {print $1}')"
mkdir -p "$WORK/shared"
printf '[user]\n\tname = Ann Example\n\temail = ann@example.com\n' > "$WORK/gitconfig"
export GIT_CONFIG_GLOBAL="$WORK/gitconfig"
expect "share writes one file" "nothing else" tiri change share "$FIRST" "$WORK/shared"
FILE="$WORK/shared/say-first-in-the-version.tirichange"
if [ -f "$FILE" ]; then ok "named by its words"; else no "no $FILE: $(ls "$WORK/shared")"; fi
expect "it's plain text, saying what it was made on" "X-Tiri-Release: " cat "$FILE"
expect "with their sentence" "Subject: [PATCH] Say first in the version" cat "$FILE"
expect "from the name they sign with" "From: Ann Example <>" cat "$FILE"
lacks "and not their email" "ann@example.com" cat "$FILE"
expect "and its check" "checks/$FIRST.sh" cat "$FILE"
lacks "and nothing of another change" "second" cat "$FILE"
expect "the second one shares too" "nothing else" tiri change share "$SECOND" "$WORK/shared/second.tirichange"
unset GIT_CONFIG_GLOBAL
expect "back where it came from, it's already here" "Already here: $FIRST" tiri change import "$FILE"
sed 's/ first/ worst/' "$FILE" > "$WORK/shared/changed.tirichange"
refuses "one changed on the way is refused" "changed after it was shared" tiri change import "$WORK/shared/changed.tirichange"
tiri run showYourTiri >/dev/null
tiri dev-your-tiri unfold "$FIRST" >/dev/null
sleep 1; shot share-button

# From here it's a friend's Tiri: the same release, with neither change.
tiri change off "$FIRST" --no-build >/dev/null || no "turning the first off"
git -C "$Y/source" update-ref -d "refs/tiri/off/$FIRST"
git -C "$Y/source" update-ref -d "refs/tiri/off/$SECOND"
lacks "neither is in their list" "Say" tiri change list
tiri dev-your-tiri open-shared "$FILE" >/dev/null
waits "opening it asks first" 'Add “Say first in the version” to your Tiri?' 100 where
expect "saying what it changes" "in 2 files" where
expect "that its check runs at every update" "check runs at every update" where
expect "who it says it's from" "Says it's from Ann Example." where
expect "and that it's code with full access" "full access" where
lacks "nothing is in the list before Add" "Say first" tiri change list
sheet_shot share-import-sheet
tiri dev-your-tiri shared-answer see >/dev/null
waits "See What Changed leaves Add in the bar" '"waiting" : "Add “Say first' 50 where
sleep 1; shot share-see-what-changed
tiri dev-your-tiri shared-answer add >/dev/null
waits "Add puts it in the list" '"lastShare" : "added' 100 where
expect "switched off" "off  Say first in the version" tiri change list
expect "under its own id, which was free" "$FIRST  off" tiri change list
expect "with its check" "check" tiri change list
expect "as from who it says" "Ann Example" git -C "$Y/source" log -1 --format=%an "refs/tiri/off/$FIRST"
if [ -e "$Y/copies/ready/ready.json" ]; then no "something was built"; else ok "nothing was built"; fi
tiri dev-your-tiri unfold "$FIRST" >/dev/null
sleep 1; shot share-arrived-off
tiri change on "$FIRST" >/dev/null 2>&1 || no "turning it on"
waits "turning it on builds a copy to try, like any change" '"ready" : "Turn on: Say first in the version"' 50 where
tiri dev-your-tiri try >/dev/null
waits "which is tried the same way" '"personal" : true' 150 where
expect "and has their change" "first" "$Y/copies/current/Tiri.app/Contents/Resources/bin/tiri" --version
tiri dev-your-tiri keep >/dev/null

echo "--- a shared change that doesn't go on"
tiri dev-your-tiri open-shared "$WORK/shared/second.tirichange" >/dev/null
waits "it still asks" 'Add “Say second in the version” to your Tiri?' 100 where
expect "saying it has to be redone" "needing to be redone" where
sheet_shot share-not-fitting-sheet
tiri dev-your-tiri shared-answer add >/dev/null
waits "and is added" '"lastShare" : "added' 100 where
REDO="$(tiri change list | awk '/Say second/ {print $1}')"
expect "off, in the list" "off  Say second in the version" tiri change list
refuses "it can't simply go on" "redone first" tiri change on "$REDO"
refuses "nor be shared on" "redone" tiri change share "$REDO" "$WORK/shared"
tiri run showYourTiri >/dev/null
tiri dev-your-tiri unfold "$REDO" >/dev/null
sleep 1; shot share-needs-redoing
expect "redoing starts from their diff" "Their diff is" tiri change revise "$REDO"
expect "which is beside the source" "Say second in the version" cat "$Y/source/.tiri-shared-$REDO.patch"
tiri change drop >/dev/null
expect "giving that up keeps it, to redo another time" "off  Say second in the version" tiri change list

echo "--- the off switch for all of it"
tiri settings set change.offer false >/dev/null
waits "nothing is offered" '"offers" : false' 30 where
tiri settings set change.offer true >/dev/null

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
