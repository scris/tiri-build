-- One row per day, kind and version, holding how many downloads there were. Nothing about who.
CREATE TABLE downloads (
  day TEXT NOT NULL,      -- 2026-11-05, UTC
  kind TEXT NOT NULL,     -- install (a .dmg from the site) or update (a .zip from update.json)
  version TEXT NOT NULL,  -- 0.1
  n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, kind, version)
);
