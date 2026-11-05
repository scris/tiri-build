#!/bin/bash
# Do the changes people make to Tiri still go on? Replays a set of sample changes onto a commit, the way an update
# does, and builds the result. A sample that stops fitting is a change someone's own Tiri would lose, or need
# mending: fix it in the commit that broke it, or say why in that commit and replace the sample.
#   scripts/replay-corpus.sh [commit]      TIRI_MERGE_TOOL=<mergiraf> uses the syntax-aware merge too
# Samples are in Tests/personal-changes, oldest first. Touches nothing in this checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
COMMIT="${1:-HEAD}"
WORK="$(mktemp -d)"
TREE="$WORK/tree"
cleanup() { git -C "$REPO" worktree remove --force "$TREE" >/dev/null 2>&1 || true; rm -rf "${WORK:?}"; }
trap cleanup EXIT
git -C "$REPO" worktree add -q --detach "$TREE" "$COMMIT"
cd "$TREE"
# In the environment, never with `git config`: a worktree shares its config with the repository it came from,
# and that would put this name on someone's own commits from then on.
export GIT_AUTHOR_NAME=corpus GIT_AUTHOR_EMAIL=corpus@localhost GIT_COMMITTER_NAME=corpus GIT_COMMITTER_EMAIL=corpus@localhost
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
if [ -n "${TIRI_MERGE_TOOL:-}" ]; then
  export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_1=merge.mergiraf.driver
  export GIT_CONFIG_VALUE_1="\"$TIRI_MERGE_TOOL\" merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L"
  echo '*.swift merge=mergiraf' > "$WORK/attributes"
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_2=core.attributesFile GIT_CONFIG_VALUE_2="$WORK/attributes"
fi
failed=0
for patch in "$REPO"/Tests/personal-changes/*.patch; do
  name="$(basename "$patch" .patch)"
  if git apply --3way --index --whitespace=nowarn "$patch" >"$WORK/output" 2>&1 || git apply --index --whitespace=nowarn "$patch" >>"$WORK/output" 2>&1; then
    if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
      echo "conflict  $name"; sed 's/^/          /' "$WORK/output"; failed=1; git reset -q --hard
    else
      git commit -qm "$name"; echo "fits      $name"
    fi
  else
    echo "conflict  $name"; sed 's/^/          /' "$WORK/output"; failed=1; git reset -q --hard
  fi
done
[ "$failed" -eq 0 ] || exit 1
if [ "${TIRI_CORPUS_BUILD:-1}" = "1" ]; then
  source scripts/swift-setup.sh
  swift build -c debug --product TiriApp 2>&1 | tail -1
fi
echo "All of them still go on."
