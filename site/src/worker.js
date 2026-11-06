// tiri.build is static files. This runs only for /download/* (see run_worker_first in wrangler.jsonc): it
// serves the file as usual and adds one to a count in the tiri-downloads database. A count is the day, the
// kind and the version, and nothing else: no IP address, no cookie, no user agent, no country. Nothing about
// who downloaded is kept.
//   install  a .dmg, someone getting Tiri from the site
//   update   a .zip, a copy of Tiri updating itself from update.json
// scripts/downloads.sh reads the counts.

export function kindOf(name) {
  if (name.endsWith(".dmg")) return "install";
  if (name.endsWith(".zip")) return "update";
  return null;
}

// A resumed download asks for the rest of the file; it's the same download, so it isn't counted again.
const fromStart = (request) => {
  const range = request.headers.get("Range");
  return !range || /^bytes=0-/.test(range.trim());
};

const COUNT = "INSERT INTO downloads (day, kind, version, n) VALUES (?1, ?2, ?3, 1) " +
  "ON CONFLICT (day, kind, version) DO UPDATE SET n = n + 1";

export default {
  async fetch(request, env, ctx) {
    const response = await env.ASSETS.fetch(request);
    const url = new URL(request.url);
    const name = decodeURIComponent(url.pathname.slice("/download/".length));
    const kind = kindOf(name);
    // Only a file that was actually sent counts; the /download/Tiri.dmg redirect and HEAD requests don't.
    const sent = response.status === 200 || response.status === 206;
    if (kind && sent && request.method === "GET" && fromStart(request) && env.DB) {
      const version = name.match(/^Tiri-(.+)\.(?:dmg|zip)$/)?.[1] ?? "";
      const day = new Date().toISOString().slice(0, 10);
      // Counted after the file starts going out; counting must never stand between someone and the file.
      ctx.waitUntil(env.DB.prepare(COUNT).bind(day, kind, version).run().catch(() => {}));
    }
    return response;
  },
};
