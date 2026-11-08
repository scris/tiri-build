#!/bin/bash
# An update carrying someone's changes, against real builds of two releases, in an invisible test copy:
# one change that replays cleanly, one only a syntax-aware merge can do, one that has to be repaired, and one
# that the new release made pointless. Stand-in for the agent: this script.
#   TIRI_DEV_ROOT=<somewhere> TIRI_E2E_MERGE_TOOL=<mergiraf> scripts/e2e-your-tiri-update.sh
set -u
cd "$(dirname "$0")/.."
# Builds of Tiri are most of this suite's time, and in release mode each is minutes of the optimizer, which isn't what's
# tested here. So copies and the test's release build in debug mode, a fraction of that. TIRI_DEV_COPY_CONFIG=release
# makes them as a real update does, for when that matters.
export TIRI_DEV_COPY_CONFIG="${TIRI_DEV_COPY_CONFIG:-debug}"
# And all in one build folder, kept between runs, so the packages Tiri uses compile once, not in every fresh source folder.
export TIRI_SCRATCH_PATH="${TIRI_SCRATCH_PATH:-${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}/swift-build-cache}"
# The version the source is, and a next release above it. Written in, they stopped matching once Tiri passed them.
NOW="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
NEXT="$(echo "$NOW" | awk -F. '{ printf "%d.%d.0", $1, $2 + 1 }')"
REPO="$PWD"
NAME="${TIRI_E2E_NAME:-ytupdate}"
ROOT="${TIRI_DEV_ROOT:-${TMPDIR:-/tmp}/tiri-dev}"
export TIRI_DEV_ROOT="$ROOT"
scripts/dev-app.sh stop "$NAME" >/dev/null 2>&1
rm -rf "${ROOT:?}/${NAME:?}"
scripts/dev-app.sh start "$NAME" >/dev/null 2>&1
eval "$(scripts/dev-app.sh env "$NAME")"
Y="$TIRI_HOME/your-tiri"
PLAIN="$ROOT/$NAME/TiriDev.app"
WORK="$ROOT/$NAME/project"; mkdir -p "$WORK"; cd "$WORK"
trap 'cd "$REPO"; scripts/dev-app.sh stop "$NAME" >/dev/null 2>&1; scripts/dev-app.sh stop "$NAME-plain" >/dev/null 2>&1' EXIT

passed=0; failed=0
ok() { passed=$((passed + 1)); echo "ok    $1"; }
no() { failed=$((failed + 1)); echo "FAIL  $1"; }
expect() { local name="$1" needle="$2"; shift 2; local output; output="$("$@" 2>&1)"
  if [[ "$output" == *"$needle"* ]]; then ok "$name"; else no "$name: expected \"$needle\" in: $output"; fi; }
lacks() { local name="$1" needle="$2"; shift 2; local output; output="$("$@" 2>&1)"
  if [[ "$output" != *"$needle"* ]]; then ok "$name"; else no "$name: found \"$needle\" in: $output"; fi; }
waits() { local name="$1" needle="$2" tries="$3"; shift 3; local output=""
  for _ in $(seq 1 "$tries"); do output="$("$@" 2>&1)"; if [[ "$output" == *"$needle"* ]]; then ok "$name"; return 0; fi; sleep 0.1; done
  no "$name: expected \"$needle\" in: $output"; return 1; }
where() { tiri dev-your-tiri where; }
draft_id() { python3 -c "import json;print(json.load(open('$Y/draft.json'))['id'])"; }

# A change with a check, the way an agent makes one. The edit is a script reading the source folder.
change() { # sentence, check line, edit...
  local sentence="$1" check="$2"; shift 2
  tiri change start "$sentence" >/dev/null || no "start: $sentence"
  local id; id="$(draft_id)"
  (cd "$Y/source" && "$@" && mkdir -p checks && printf '#!/bin/bash\n%s\n' "$check" > "checks/$id.sh")
  tiri change ready >/dev/null 2>&1 || no "ready: $sentence"
  LAST_ID="$id"
}

edit_cleanly() { printf 'public enum PersonalOne { public static let word = "one" }\n' > Sources/TiriCore/PersonalOne.swift; }
edit_field_mine() { perl -pi -e 's/^(\s*)public var notes: String\?\n/$1public var notes: String?\n$1public var mine: String?\n/ if !$d && /struct ReleaseEntry/../notes/ and /notes: String/ and ($d=1)' Sources/TiriCore/YourTiriUpdates.swift; }
edit_version() { perl -pi -e 's/return \.printText\("tiri \\\(TiriCoreVersion\.string\)/return .printText("tiri \\(TiriCoreVersion.string) mended/' Sources/TiriCore/CLI.swift; }
edit_same() { printf '\nSomething the next release says too.\n' >> CHANGING.md; }

echo "--- the changes"
tiri term --cwd "$WORK" --cmd "echo \$\$ > $WORK/program.pid; while true; do date +%s >> $WORK/counter.txt; sleep 0.2; done" >/dev/null
for _ in $(seq 1 100); do [ -s "$WORK/program.pid" ] && break; sleep 0.1; done
PROGRAM="$(cat "$WORK/program.pid")"
# Needed first, since `change` runs in the tree the first `start` makes.
if [ -n "${TIRI_E2E_MERGE_TOOL:-}" ]; then mkdir -p "$Y/tools"; cp "$TIRI_E2E_MERGE_TOOL" "$Y/tools/mergiraf"; ok "using the merge tool"; else echo "note: no merge tool"; fi
change "Add a word of my own" 'test -f "$TIRI_SOURCE/Sources/TiriCore/PersonalOne.swift"' edit_cleanly; CLEAN=$LAST_ID
change "Remember one more thing in a release" 'grep -q "var mine" "$TIRI_SOURCE/Sources/TiriCore/YourTiriUpdates.swift"' edit_field_mine; FIELD=$LAST_ID
change "Mention mending in the version" 'tiri --version | grep -q mended' edit_version; MEND=$LAST_ID
change "Add a line to the guide" 'tail -1 "$TIRI_SOURCE/CHANGING.md" | grep -q "says too"' edit_same; SAME=$LAST_ID
expect "four changes" "$SAME" tiri change list
tiri dev-your-tiri try >/dev/null
waits "running them" '"personal" : true' 150 where
tiri dev-your-tiri keep >/dev/null

echo "--- the next release"
RELEASE="$ROOT/$NAME/release"; mkdir -p "$RELEASE/source"
tar -xzf "$PLAIN/Contents/Resources/source.tar.gz" -C "$RELEASE/source"
(cd "$RELEASE/source"
 git init -q -b main; git config user.name t; git config user.email t@t; git config commit.gpgsign false; git config core.hooksPath /dev/null
 git add -A; git commit -qm base
 # Beside the same field, in the same place.
 perl -pi -e 's/^(\s*)public var notes: String\?\n/$1public var notes: String?\n$1public var theirs: String?\n/ if !$d && /struct ReleaseEntry/../notes/ and /notes: String/ and ($d=1)' Sources/TiriCore/YourTiriUpdates.swift
 # The same line, rewritten.
 perl -pi -e 's/return \.printText\("tiri \\\(TiriCoreVersion\.string\)/return .printText("tiri \\(TiriCoreVersion.string) new/' Sources/TiriCore/CLI.swift
 # Word for word what a change did.
 printf '\nSomething the next release says too.\n' >> CHANGING.md
 /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" Resources/Info.plist
 git add -A; git commit -qm "$NEXT")
printf 'The version line was rewritten.\n' > "$RELEASE/notes.txt"
(cd "$RELEASE/source" && TIRI_RELEASE_NOTES="$RELEASE/notes.txt" TIRI_BUILD_DIR="$RELEASE/out" TIRI_SIGN_IDENTITY=- TIRI_BUNDLE_ID="dev.tiri.test.$NAME" ./build.sh "$TIRI_DEV_COPY_CONFIG" >"$RELEASE/build.log" 2>&1) || no "couldn't build the release: $(tail -3 "$RELEASE/build.log")"
expect "the release says what it is" "$NEXT" /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE/out/Tiri.app/Contents/Info.plist"

echo "--- replay"
OTHER="$RELEASE/other/Tiri.app"; mkdir -p "$RELEASE/other"; ditto "$RELEASE/out/Tiri.app" "$OTHER"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.other' "$OTHER/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$OTHER" 2>/dev/null
expect "another app is refused" "copy of this Tiri" tiri update prepare "$OTHER"
TAMPERED="$RELEASE/tampered/Tiri.app"; mkdir -p "$RELEASE/tampered"; ditto "$RELEASE/out/Tiri.app" "$TAMPERED"
printf 'x' >> "$TAMPERED/Contents/Resources/source.tar.gz"
expect "a tampered release is refused" "isn't signed properly" tiri update prepare "$TAMPERED"
expect "the same version is refused" "isn't newer" tiri update prepare "$PLAIN"
if [ ! -e "$Y/updates/status.json" ]; then ok "and being refused changed nothing"; else no "a refused release left something: $(tiri update)"; fi
# Stopped halfway, the way a quit or a restart would stop it.
tiri update prepare "$RELEASE/out/Tiri.app" >/dev/null 2>&1 &
PREPARING=$!
for _ in $(seq 1 600); do grep -qE '"phase" : "(building|checking)"' "$Y/updates/status.json" 2>/dev/null && break; sleep 0.1; done
kill -9 "$PREPARING" 2>/dev/null
wait "$PREPARING" 2>/dev/null
ok "stopped it partway through"
expect "the notes signed into the release are read" "The version line was rewritten" cat "$Y/updates/status.json"
pkill -9 -f "$Y/source/.build" 2>/dev/null
tiri change list >/dev/null
tiri dev-your-tiri where >/dev/null
waits "it starts again by itself" "almost ready" 1800 where
expect "one needs a look" "$MEND" tiri update
expect "named in its words" "Mention mending" tiri update
expect "the one Tiri learned retired itself" "retired: Add a line to the guide" tiri update
LIST="$(cd "$Y/source" && git log --format=%s refs/tiri/next-release..HEAD)"
if [[ "$LIST" == *"Add a word of my own"* ]]; then ok "the clean one replayed"; else no "the clean one didn't replay: $LIST"; fi
if [ -n "${TIRI_E2E_MERGE_TOOL:-}" ]; then
  if [[ "$LIST" == *"Remember one more thing"* ]]; then ok "the syntax-aware merge solved the other"; else no "the merge tool didn't solve it: $(tiri update)"; fi
  # That only means something if plain Git couldn't have.
  (cd "$Y/source" && git diff --quiet HEAD -- . ; git merge-tree --write-tree --no-messages -X ours HEAD HEAD >/dev/null 2>&1)
  grep -q "var theirs" "$Y/source/Sources/TiriCore/YourTiriUpdates.swift" && ok "the release's field is in the merged file" || no "the release's field isn't there"
  grep -q "var mine" "$Y/source/Sources/TiriCore/YourTiriUpdates.swift" && ok "and so is the change's" || no "the change's field isn't there"
  MERGE_TEST="$RELEASE/plain-merge"; rm -rf "${MERGE_TEST:?}"; git clone -q "$Y/source" "$MERGE_TEST" 2>/dev/null
  if (cd "$MERGE_TEST" && git config user.name t && git config user.email t@t && git config commit.gpgsign false && git checkout -q "$(git -C "$Y/source" rev-parse refs/tiri/next-release 2>/dev/null)" 2>/dev/null; git -C "$Y/source" cat-file -p refs/tiri/next-release >/dev/null); then
    BASE_FILE="$(git -C "$Y/source" show release:Sources/TiriCore/YourTiriUpdates.swift)"
    printf '%s\n' "$BASE_FILE" > "$RELEASE/base.swift"
    git -C "$Y/source" show refs/tiri/next-release:Sources/TiriCore/YourTiriUpdates.swift > "$RELEASE/theirs.swift"
    git -C "$Y/source" show "personal~2:Sources/TiriCore/YourTiriUpdates.swift" > "$RELEASE/mine.swift"
    if git merge-file -p "$RELEASE/mine.swift" "$RELEASE/base.swift" "$RELEASE/theirs.swift" >/dev/null 2>&1; then no "plain Git could have merged that, so the test proves nothing"; else ok "and plain Git couldn't have merged it"; fi
  fi
fi
tiri change start "Something new" 2>&1 | grep -q "update is being got ready" && ok "no new change while it's underway" || no "a change started during an update"

echo "--- repair"
tiri update repair "$MEND" > "$WORK/repair.txt" 2>&1
expect "the agent sees the old change" "mended" cat "$WORK/repair.txt"
expect "and the conflict is marked" "<<<<<<<" cat "$Y/source/Sources/TiriCore/CLI.swift"
(cd "$Y/source" && /usr/bin/python3 - <<'PY'
import re
p='Sources/TiriCore/CLI.swift'; s=open(p).read()
s=re.sub(r'<<<<<<<.*?\n(.*?)(?:\|\|\|\|\|\|\|.*?)?=======\n.*?>>>>>>>[^\n]*\n', lambda m: m.group(1).replace(' new',' new mended'), s, flags=re.S)
open(p,'w').write(s)
PY
)
OUTPUT="$(tiri update repaired 2>&1)"; echo "$OUTPUT" | tail -1
# Without the merge tool, plain Git can't put two fields side by side, so the second change needs a repair too,
# done as an agent would: both fields kept.
if [ -z "${TIRI_E2E_MERGE_TOOL:-}" ]; then
  tiri update repair "$FIELD" > "$WORK/repair-field.txt" 2>&1
  expect "without the merge tool, the second needs a repair too" "<<<<<<<" cat "$Y/source/Sources/TiriCore/YourTiriUpdates.swift"
  (cd "$Y/source" && /usr/bin/python3 - <<'PY'
import re
p='Sources/TiriCore/YourTiriUpdates.swift'; s=open(p).read()
s=re.sub(r'<<<<<<<[^\n]*\n(.*?)(?:\|\|\|\|\|\|\|.*?)?=======\n(.*?)>>>>>>>[^\n]*\n',
         lambda m: m.group(1) + ''.join(l + '\n' for l in m.group(2).splitlines() if l not in m.group(1).splitlines()), s, flags=re.S)
open(p,'w').write(s)
PY
  )
  OUTPUT="$(tiri update repaired 2>&1)"; echo "$OUTPUT" | tail -1
fi
waits "it's ready" "ready, with your 3 changes" 50 where
expect "the running app hasn't changed" "$NOW" where
if kill -0 "$PROGRAM" 2>/dev/null; then ok "the program is untouched so far"; else no "the program ended during the update"; fi

echo "--- pressing Update"
tiri dev-your-tiri update >/dev/null
sleep 1
waits "the personal copy came back" "\"version\" : \"$NEXT\"" 200 where
expect "it's the personal copy" '"personal" : true' where
expect "the installed app is the new release" "$NEXT" /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLAIN/Contents/Info.plist"
expect "which is what's kept for going back" "$NOW" /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$Y/updates/previous/Tiri.app/Contents/Info.plist"
expect "the version line has both" "new mended" "$Y/copies/current/Tiri.app/Contents/Resources/bin/tiri" --version
expect "the field and the other field" "var theirs" grep -n "var theirs" "$Y/source/Sources/TiriCore/YourTiriUpdates.swift"
expect "are both there" "var mine" grep -n "var mine" "$Y/source/Sources/TiriCore/YourTiriUpdates.swift"
expect "three changes on" "$MEND  on" tiri change list
lacks "the retired one's gone" "$SAME" tiri change list
expect "the repair is marked" "Tiri-Repaired: $NEXT" git -C "$Y/source" log -1 --format=%B "$(tiri change list --json | python3 -c "import json,sys;print([c['commit'] for c in json.load(sys.stdin) if c['id']=='$MEND'][0])")"
expect "the list says it was repaired" "$MEND  on" tiri change list
expect "and for which version" "repaired for $NEXT" tiri change list
MENDED="$(tiri change list --json | /usr/bin/python3 -c "import json,sys;print(' '.join([c['repairTouched'] for c in json.load(sys.stdin) if c['id']=='$MEND'][0]))")"
if [[ "$MENDED" == *"Sources/TiriCore/CLI.swift"* ]]; then ok "and what the repair touched"; else no "what the repair touched: $MENDED"; fi
lacks "a change that was only carried isn't called repaired" "$CLEAN  on   Add a word of my own  (1 file, 1 line, check, repaired" tiri change list
expect "on the personal branch" "personal" git -C "$Y/source" symbolic-ref --short HEAD
if kill -0 "$PROGRAM" 2>/dev/null; then ok "the program lived through the update"; else no "the program died in the update"; fi
tiri change start "After an update, changes go on as before" >/dev/null && ok "changes go on" || no "can't start a change after an update"
tiri change drop >/dev/null

echo "--- a rebuild: the same version, a newer build"
(cd "$RELEASE/source" && TIRI_BUILD_DIR="$RELEASE/rebuilt" TIRI_SIGN_IDENTITY=- TIRI_BUNDLE_ID="dev.tiri.test.$NAME" ./build.sh "$TIRI_DEV_COPY_CONFIG" >"$RELEASE/rebuild.log" 2>&1) || no "couldn't rebuild: $(tail -3 "$RELEASE/rebuild.log")"
REBUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RELEASE/rebuilt/Tiri.app/Contents/Info.plist")"
expect "it's still the same version" "$NEXT" /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE/rebuilt/Tiri.app/Contents/Info.plist"
tiri update prepare "$RELEASE/rebuilt/Tiri.app" >/dev/null 2>&1
waits "the rebuild is ready with the changes" "ready, with your" 50 where
tiri dev-your-tiri update >/dev/null
waits "the rebuild is what's installed" "$REBUILT" 200 /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLAIN/Contents/Info.plist"
waits "and the personal copy came back on it" '"personal" : true' 200 where
expect "still has the changes" "$MEND  on" tiri change list
if kill -0 "$PROGRAM" 2>/dev/null; then ok "the program lived through the rebuild"; else no "the program died in the rebuild"; fi

echo "--- someone with no changes, the same one button"
cd "$REPO"; scripts/dev-app.sh start "$NAME-plain" >/dev/null 2>&1
eval "$(scripts/dev-app.sh env "$NAME-plain")"
cd "$ROOT/$NAME-plain"
TIRI_BUNDLE_ID_CHECK="dev.tiri.test.$NAME-plain"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TIRI_BUNDLE_ID_CHECK" "$RELEASE/out/Tiri.app/Contents/Info.plist"
codesign --force --sign - --timestamp=none --entitlements "$REPO/Resources/Tiri.entitlements" "$RELEASE/out/Tiri.app" 2>/dev/null
expect "it's ready at once" "is ready." tiri update prepare "$RELEASE/out/Tiri.app"
lacks "with nothing built" "copies" ls "$TIRI_HOME/your-tiri"
waits "the button's there" "Tiri $NEXT is ready." 30 where
tiri dev-your-tiri update >/dev/null
sleep 1
waits "the new version is running" "\"version\" : \"$NEXT\"" 200 where
expect "plain, as they had it" '"personal" : false' where

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
