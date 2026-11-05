#!/bin/bash
# Tells an assembled app which source it is, and for one that can be changed, carries that source.
#   scripts/stamp-bundle.sh <app> <info-plist>
# TIRI_COPY=personal   a build made on someone's own Mac: names itself so, and carries no source, since they have it
# TIRI_BUNDLE_ID       overrides the bundle ID
# TIRI_RELEASE_COMMIT  which release a personal copy sits on
# TIRI_RELEASE_NOTES   a text file saying what's new in this release
set -euo pipefail
APP="$1"; PLIST="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

set_value() {
  /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST"
}

COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
set_value TiriSourceCommit "$COMMIT"
# The version is only changed on purpose. The build number changes every time, so a rebuild is newer, and an
# update can carry someone's changes onto it.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$PLIST"
if [ -n "${TIRI_BUNDLE_ID:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TIRI_BUNDLE_ID" "$PLIST"; fi

# What's new, listing any code that moved. It's signed with the app, and an agent repairing a change reads it.
if [ -n "${TIRI_RELEASE_NOTES:-}" ]; then cp "$TIRI_RELEASE_NOTES" "$APP/Contents/Resources/release-notes.txt"; fi

if [ "${TIRI_COPY:-}" = "personal" ]; then
  set_value TiriCopy personal
  set_value TiriReleaseCommit "${TIRI_RELEASE_COMMIT:-unknown}"
  # About says so, and the first question about any bug is whether Plain Tiri has it too.
  COUNT="$(git -C "$ROOT" rev-list --count "${TIRI_RELEASE_COMMIT:-HEAD}..HEAD" 2>/dev/null || echo 0)"
  if [ "$COUNT" = "1" ]; then WORD="1 change"; else WORD="$COUNT changes"; fi
  set_value NSHumanReadableCopyright "Your Tiri, with $WORD applied"
  exit 0
fi

# What git would keep, as it stands right now, so that the source is exactly what was built.
git -C "$ROOT" ls-files -z --cached --others --exclude-standard \
  | (cd "$ROOT" && tar --exclude '.env' --exclude '.env.*' --null -T - -czf - 2>/dev/null) >"$APP/Contents/Resources/source.tar.gz" || true
