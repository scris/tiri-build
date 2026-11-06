#!/bin/bash
# How many times Tiri has been downloaded from tiri.build, from the counts site/src/worker.js keeps.
# Installs are .dmg downloads from the site; updates are .zip downloads by copies of Tiri updating themselves.
# The counts hold no IP address, cookie or anything else about who downloaded.
#   scripts/downloads.sh           totals, by version, and the last 14 days
#   scripts/downloads.sh --local   the same, from `npm run dev`'s local copy
set -euo pipefail
cd "$(dirname "$0")/../site"
WHERE="--remote"; [ "${1:-}" = "--local" ] && WHERE="--local"
query() { npx --no-install wrangler d1 execute tiri-downloads "$WHERE" --json --command "$1" 2>/dev/null; }
show() {
  python3 -c '
import json, sys
rows = json.load(sys.stdin)[0]["results"]
if not rows: print("  none yet"); sys.exit()
cols = list(rows[0])
w = {c: max(len(c), *(len(str(r[c])) for r in rows)) for c in cols}
print("  " + "  ".join(c.ljust(w[c]) for c in cols))
for r in rows: print("  " + "  ".join(str(r[c]).ljust(w[c]) for c in cols))'
}
echo "All time"
query "SELECT SUM(CASE WHEN kind='install' THEN n ELSE 0 END) AS installs, SUM(CASE WHEN kind='update' THEN n ELSE 0 END) AS updates FROM downloads HAVING COUNT(*) > 0" | show
echo; echo "By version"
query "SELECT version, SUM(CASE WHEN kind='install' THEN n ELSE 0 END) AS installs, SUM(CASE WHEN kind='update' THEN n ELSE 0 END) AS updates FROM downloads GROUP BY version ORDER BY MIN(day) DESC" | show
echo; echo "Last 14 days (UTC)"
query "SELECT day, SUM(CASE WHEN kind='install' THEN n ELSE 0 END) AS installs, SUM(CASE WHEN kind='update' THEN n ELSE 0 END) AS updates FROM downloads WHERE day >= date('now', '-13 days') GROUP BY day ORDER BY day DESC" | show
