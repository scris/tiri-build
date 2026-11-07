(() => {
  "use strict";

  const calm = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const narrow = matchMedia("(max-width: 760px)");
  // A finger, not a pointer: no Return key to press, and a tap rather than a click.
  const touch = matchMedia("(pointer: coarse)").matches;
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const wait = (ms) => new Promise((r) => setTimeout(r, calm ? Math.min(ms, 120) : ms));

  /* ---------- fit each fixed-size window into its column ---------- */
  // On a laptop-or-wider screen the film and its chapters share the first screen: the film takes the
  // height left under the headline, and the chapters run down beside it.
  const sideBySide = matchMedia("(min-width: 1061px)");
  const CHAPTERS_W = 220;
  const GAP = 40;
  function fitFirstScreen(stage, w, h) {
    const show = stage.parentElement;
    const room = show.clientWidth - CHAPTERS_W - GAP;
    const top = show.getBoundingClientRect().top + scrollY;
    const left = innerHeight - top - 32;
    return Math.max(0.55, Math.min(1, room / w, left / h));
  }
  function fit(stage) {
    const [w, h] = stage.dataset.stage.split("x").map(Number);
    const win = stage.firstElementChild;
    if (stage.id === "tour" && sideBySide.matches) {
      const s = fitFirstScreen(stage, w, h);
      stage.classList.remove("zoomed");
      stage.style.width = `${w * s}px`;
      stage.style.height = `${h * s}px`;
      win.style.transform = `scale(${s})`;
      return;
    }
    if (stage.id === "tour") stage.style.width = "";
    const avail = stage.clientWidth;
    // On a phone the film zooms in and follows the action, instead of shrinking the whole window.
    const zoom = stage.dataset.zoom && avail < 760;
    const s = zoom ? Math.min(1, avail / (stage.camZoom ?? +stage.dataset.zoom)) : Math.min(1, avail / w);
    const cx = stage.camX ?? w / 2;
    const cy = stage.camY ?? h / 2;
    const vh = zoom ? Math.min(h * s, avail * 1.05) : h * s;
    const tx = zoom ? Math.min(0, Math.max(avail - w * s, avail / 2 - cx * s)) : Math.max(0, (avail - w * s) / 2);
    const ty = zoom ? Math.min(0, Math.max(vh - h * s, vh / 2 - cy * s)) : 0;
    stage.classList.toggle("zoomed", !!zoom);
    win.style.transform = `translate(${tx}px, ${ty}px) scale(${s})`;
    stage.style.height = `${vh}px`;
  }
  function aim(stage, x0, y0, x1, y1) {
    const avail = stage.clientWidth;
    // Out a little further when what it's aimed at is wider, so a sheet isn't cut off at the side.
    const zoom = +stage.dataset.zoom;
    stage.camZoom = Math.min(zoom * 1.25, Math.max(zoom, x1 - x0 + 24));
    const s = Math.min(1, avail / stage.camZoom);
    const vw = avail / s - 16;
    const vh = Math.min(680, (avail * 1.05) / s) - 16;
    stage.camX = x1 - x0 > vw ? x0 + vw / 2 : (x0 + x1) / 2;
    stage.camY = y1 - y0 > vh ? y0 + vh / 2 : (y0 + y1) / 2;
    fit(stage);
  }
  const stages = $$("[data-stage]");
  const ro = new ResizeObserver(() => stages.forEach(fit));
  stages.forEach((s) => {
    fit(s);
    ro.observe(s.id === "tour" ? s.parentElement : s);
  });
  const refit = () => stages.forEach(fit);
  addEventListener("resize", refit);
  sideBySide.addEventListener("change", refit);
  document.fonts.ready.then(refit);

  /* ---------- times ---------- */
  function dur(since) {
    const s = Math.max(0, Math.floor((Date.now() - since) / 1000));
    if (s < 60) return `${s}s`;
    if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s`;
    return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
  }
  const spinText = (since) => `(${dur(since)} · ↓ ${(0.6 + (Date.now() - since) / 40000).toFixed(1)}k tokens)`;
  setInterval(() => {
    $$("[data-since]").forEach((el) => (el.textContent = dur(+el.dataset.since)));
    $$("[data-spin]").forEach((el) => (el.textContent = spinText(+el.dataset.spin)));
  }, 1000);

  /* ---------- code highlighting ---------- */
  const KW = /\b(import|from|export|async|function|const|let|for|await|try|return|catch|throw|new|if|var|func|struct|some|private)\b/g;
  function hl(src) {
    return src.split("\n").map((ln) => {
      const out = [];
      let rest = ln;
      const cm = rest.indexOf("//");
      let comment = "";
      if (cm >= 0) {
        comment = rest.slice(cm);
        rest = rest.slice(0, cm);
      }
      rest.split(/("[^"]*")/).forEach((part, i) => {
        if (i % 2) out.push(`<span class="s">${esc(part)}</span>`);
        else
          out.push(
            esc(part)
              .replace(KW, '<span class="k">$1</span>')
              .replace(/\b([A-Z]\w+)(?=\()/g, '<span class="t">$1</span>')
              .replace(/\b(\d[\d_]*)\b/g, '<span class="a">$1</span>')
          );
      });
      if (comment) out.push(`<span class="c">${esc(comment)}</span>`);
      return out.join("");
    });
  }

  /* ---------- Tiri's parts, drawn from a state ---------- */
  const svg = (d, cls = "ico") => `<svg class="${cls}" viewBox="0 0 20 20">${d}</svg>`;
  const FOLD = '<svg viewBox="0 0 20 20"><path d="M2.5 6.5a2 2 0 0 1 2-2h3.2l1.6 1.6h6.2a2 2 0 0 1 2 2v6.4a2 2 0 0 1-2 2h-11a2 2 0 0 1-2-2z"/></svg>';
  const ICON = {
    folder: `<span class="ic fold">${FOLD}</span>`,
    tree: `<span class="ic fold pink">${FOLD}</span>`,
    doc: '<span class="ic"><svg viewBox="0 0 20 20"><path d="M5.5 2.8h5.8l3.4 3.4v11H5.5z"/><path d="M11.2 2.8v3.5h3.5"/></svg></span>',
    code: '<span class="ic glyph">&lt;/&gt;</span>',
    json: '<span class="ic glyph">{ }</span>',
    image: '<span class="ic"><svg viewBox="0 0 20 20"><rect x="2.8" y="4" width="14.4" height="12" rx="1.5"/><circle cx="7.2" cy="8" r="1.3"/><path d="m3.5 15 4.5-4.5 3 3 2-2 3.5 3.5"/></svg></span>',
    globe: '<span class="ic"><svg viewBox="0 0 20 20"><circle cx="10" cy="10" r="7"/><path d="M3 10h14M10 3c2.2 2.4 2.2 11.6 0 14M10 3c-2.2 2.4-2.2 11.6 0 14"/></svg></span>',
    term: '<span class="ic"><svg viewBox="0 0 20 20"><rect x="2.5" y="4" width="15" height="12" rx="2"/><path d="m6 8 2.5 2L6 12M10 12.5h4"/></svg></span>',
    diff: '<span class="ic"><svg viewBox="0 0 20 20"><path d="M7 3.5v8M3 7.5h8M9 15.5h8"/></svg></span>',
  };
  const CHEV = svg('<path d="M5.5 8l4.5 4.5L14.5 8"/>', "chev");
  const CHEV_SHUT = svg('<path d="M8 5.5l4.5 4.5L8 14.5"/>', "chev");
  const TW_OPEN = '<svg viewBox="0 0 20 20"><path d="M5.5 8l4.5 4.5L14.5 8"/></svg>';
  const TW_SHUT = '<svg viewBox="0 0 20 20"><path d="M8 5.5l4.5 4.5L8 14.5"/></svg>';
  const PLUS = '<svg viewBox="0 0 20 20"><path d="M10 4.5v11M4.5 10h11"/></svg>';
  const HISTORY = '<svg viewBox="0 0 20 20"><path d="M4.5 10a5.5 5.5 0 1 0 1.6-3.9M4.5 4.5v2.5H7"/><path d="M10 7v3.2l2 1.3"/></svg>';
  const NEWFILE = '<svg viewBox="0 0 20 20"><path d="M6 3h5l3 3v4M11 3v3h3M6 3v14h4"/><path d="M14 13v5M11.5 15.5h5"/></svg>';
  const NEWDIR = '<svg viewBox="0 0 20 20"><path d="M3 6a1.5 1.5 0 0 1 1.5-1.5h3l1.5 1.5h6.5A1.5 1.5 0 0 1 17 7.5V9M3 6v8.5A1.5 1.5 0 0 0 4.5 16H10"/><path d="M14.5 12v5M12 14.5h5"/></svg>';
  const BRANCH = '<svg viewBox="0 0 20 20"><path d="M5.5 3.5v3.5c0 2.2 2 3.5 4.5 3.5s4.5-1.3 4.5-3.5V3.5M10 10.5v6"/></svg>';
  const CARD = {
    hammer: '<svg viewBox="0 0 24 24"><path d="m13.5 6.5 4 4M11 9l-7.2 7.2a1.9 1.9 0 0 0 2.7 2.7L13.7 11.7"/><path d="M12 5.2 14.6 2.6l6.8 6.8-2.6 2.6c-1.1-.4-2.3-.3-3.3.5l-3.3-3.3c.8-1 .9-2.2.5-3.3z"/></svg>',
    sparkle: '<svg viewBox="0 0 24 24"><path d="M12 3.5c.6 3.9 2.2 5.6 6.5 6.5-4.3.9-5.9 2.6-6.5 6.5-.6-3.9-2.2-5.6-6.5-6.5 4.3-.9 5.9-2.6 6.5-6.5zM18.5 15c.3 1.6 1 2.3 2.5 2.5-1.5.3-2.2 1-2.5 2.5-.3-1.5-1-2.2-2.5-2.5 1.5-.2 2.2-.9 2.5-2.5z"/></svg>',
    check: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="m8.3 12.3 2.5 2.5 5-5.3"/></svg>',
  };
  const SB = {
    spin: '<span class="ast work">✻</span>',
    sparkle: `<span class="ic">${CARD.sparkle.replace('viewBox="0 0 24 24"', 'viewBox="0 0 24 24" class="ico"')}</span>`,
    check: `<span class="ic">${CARD.check.replace('viewBox="0 0 24 24"', 'viewBox="0 0 24 24" class="ico"')}</span>`,
  };
  const stIcon = (st) =>
    st === "work" ? '<span class="st st-work"></span>' : st === "done" ? '<span class="st st-done"></span>' : st === "needs" ? '<span class="st st-needs"></span>' : "";

  const VIEWS = {
    image: () =>
      '<div class="view v-img"><div class="shot"><div class="shot-bar"><i></i><i></i><i></i><span>jobs.acme.example/payments-api</span></div><div class="posting"><div class="logo">acme</div><h5>Software Engineer, Payments API</h5><p class="meta">Engineering · Remote in US or Canada · Full time</p><b>What you\'ll do</b><ul><li>Design the APIs millions of businesses build on</li><li>Own billing and payment flows end to end</li><li>Make retries, webhooks and idempotency boring</li></ul><b>Who you are</b><ul><li>5+ years building backend systems</li><li>You care how an API feels to the person calling it</li></ul></div></div></div>',
    page: (g) =>
      `<div class="view v-doc"><div class="paper${g && g.reloadAt && Date.now() - g.reloadAt < 700 ? " reload" : ""}"><header><h5>Sam Example</h5><p>Backend engineer, payments and APIs</p><small>sam@example.com &nbsp; Toronto &nbsp; github.com/example</small></header><div class="cols"><div><h6>Experience</h6><div class="job"><b>Example Billing Co.</b><span>Senior Engineer, Billing</span><i>2022 to now</i></div><ul><li>Led the billing API rewrite, now serving 4,000 businesses</li><li>Cut failed payment retries 38% with idempotent webhooks</li>${g && g.v2 ? `<li${g.reloadAt && Date.now() - g.reloadAt < 2600 ? ' class="fresh"' : ""}>Designed the public webhooks API and its retry rules</li>` : ""}<li>Built the invoicing service in Go and Postgres</li></ul><div class="job"><b>Sample Shop</b><span>Software Engineer</span><i>2019 to 2022</i></div><ul><li>Designed the public orders API used by 300 partners</li><li>Moved card storage out of PCI scope</li></ul></div><div class="aside"><h6>Skills</h6><p>API design, idempotency, webhooks</p><p>Go, TypeScript, Postgres, Kafka</p><h6>Education</h6><p>BSc Computer Science<br>Example University</p><h6>Open source</h6><p>ratelimit, 2.1k stars</p></div></div></div></div>`,
    opps: () =>
      '<div class="view v-page"><h5>Three roles</h5><div class="role">Compared against your resume</div><table><tr><th>Company</th><th>Role</th><th>Fit</th></tr><tr><td>Acme</td><td>Payments API</td><td>Strong</td></tr><tr><td>Globex</td><td>Sync engine</td><td>Good</td></tr><tr><td>Initech</td><td>Card platform</td><td>Good</td></tr></table><h6>Why Acme first</h6><ul><li>Billing API work maps to the role</li><li>Idempotency and webhooks are named in the posting</li></ul></div>',
    notes: () =>
      '<div class="view v-md"><h5>Job hunt notes</h5><p>Applying to three roles this week. Acme closes Friday.</p><h6>To do</h6><ul><li>Tailor resume for Acme</li><li>Ask Mia for a referral</li><li>Prepare the system design story</li></ul></div>',
    fit: () =>
      '<div class="view v-md"><h5>Why the Acme role fits</h5><p>The posting asks for payments infrastructure and API design. Both are the last three years of your work.</p><h6>Lead with</h6><ul><li>The billing API rewrite, and the 4,000 businesses on it</li><li>38% fewer failed retries from idempotent webhooks</li></ul><h6>Expect them to ask</h6><ul><li>How you versioned the API without breaking clients</li><li>What you would change about the invoicing service</li></ul></div>',
    code: (g) => `<div class="view v-code"><div class="crumbs">${esc(g.crumbs || "")}</div><pre>${g.code}</pre></div>`,
  };

  function line([type, html]) {
    return `<div class="tl cc-${type}">${html}</div>`;
  }
  function bannerHTML(b) {
    if (!b) return "";
    return b.agent === "codex"
      ? `<div class="cc-banner codex"><b>&gt;_ OpenAI Codex</b><i>model: gpt-5.5 · directory: ${esc(b.path)}</i></div>`
      : `<div class="cc-banner"><span class="cc-mark">✻</span><span><b>Claude Code</b> <i>v2.1</i><br><i>Opus 5.5 · ${esc(b.path)}</i></span></div>`;
  }
  function viewHTML(g) {
    if (g.view === "term") {
      return (
        `<div class="term">${bannerHTML(g.banner)}${g.lines.map(line).join("")}${g.spin ? `<div class="tl cc-spin"><i class="star">✻</i> ${g.spin.verb}… <span data-spin="${g.spin.since}">${spinText(g.spin.since)}</span></div>` : ""}</div>` +
        `<div class="cc-input"><span class="pr">❯</span>${g.chip ? `<span class="chip">[⧉ ${esc(g.chip)}]</span>` : ""}<span class="tx">${g.input || ""}</span><i class="bcur"></i></div>` +
        `<div class="cc-mode">${g.mode || "? for shortcuts"}</div>`
      );
    }
    return VIEWS[g.view](g);
  }
  function tabHTML(t) {
    return `<span class="tab${t.on ? " on" : ""}${t.enter ? " enter" : ""}" data-tab="${t.id}">${t.st ? stIcon(t.st) : ICON[t.icon]}<span class="tt">${esc(t.title)}</span>${t.st === "done" ? '<i class="gdot"></i>' : ""}</span>`;
  }
  function cardHTML(c) {
    return `<div class="tcard"><span class="cic">${CARD[c.icon]}</span><span class="ctx"><b>${esc(c.title)}</b><small>${esc(c.detail)}</small></span>${c.btns
      .map((b) => `<button type="button" class="cbtn${b.hint ? " hint" : ""}" data-act="${b.act || ""}">${b.label}</button>`)
      .join("")}</div>`;
  }
  function popHTML(p) {
    const field = p.text
      ? `<span>${esc(p.text)}</span><i class="bcur"></i>${p.full ? '<button type="button" class="ret" data-act="ask">Return ↩</button>' : ""}`
      : '<span class="ph">What do you want Tiri to do differently?</span>';
    const items = p.items
      .map((s, i) => `<button type="button" class="cp-item${p.picked === i ? " picked" : ""}" data-act="pick:${i}"${p.done && p.done.includes(i) ? " disabled" : ""}><span class="q">“</span>${esc(s)}</button>`)
      .join("");
    return (
      `<div class="cpop"><div class="cp-field">${field}</div><div class="cp-body"><b>Tiri can rewrite itself for you.</b><div class="cp-cards">` +
      '<div class="cp-card"><div class="cp-ill"><div class="strip"><i></i><i></i><i></i></div><div class="in"><div class="bub">“Show how long each agent has been working”</div></div></div><b>You say what you want</b><small>In your own words</small></div>' +
      '<div class="cp-card"><div class="cp-ill"><div class="strip"><i></i><i></i><i></i></div><div class="in"><div class="gl">✻ <i class="w2"></i></div><div class="gl">+ <i class="w3"></i></div><div class="gl">+ <i class="w1"></i></div></div></div><b>Claude Code builds it</b><small>A few minutes. Keep working</small></div>' +
      '<div class="cp-card"><div class="cp-ill"><div class="strip"><i></i><i></i><i></i></div><div class="in"><span class="tm">3:12</span><div class="pills"><span>Back</span><span>Keep</span></div></div></div><b>Tiri reopens with it</b><small>Keep it, or go back</small></div>' +
      `</div><div class="cp-row"><span class="cp-mark">⛶ Mark It on Screen</span><small>Uses your Claude Code account. About 1 GB, the first time</small></div></div><div class="cp-list">${items}</div></div>`
    );
  }
  function sideHTML(S) {
    const ws = `<section class="sec" data-sec="ws"><h4>Workspaces<span class="h-r">${PLUS}</span></h4>${S.ws
      .map((w) => `<div class="row${w.name === S.on ? " on" : ""}" data-ws="${esc(w.name)}">${ICON.folder}<span class="nm">${esc(w.name)}</span>${w.badge ? `<b class="cnt${w.pink ? " pink" : ""}">${w.badge}</b>` : ""}</div>`)
      .join("")}</section>`;
    const tree = S.tree
      .map((t) =>
        t.dir
          ? `<div class="row d${t.d}"><span class="tw">${t.open ? TW_OPEN : TW_SHUT}</span>${ICON.tree}<span class="nm">${esc(t.name)}</span></div>`
          : `<div class="row d${t.d}${t.hot ? " on" : ""}"><span class="tw"></span>${ICON[t.kind]}<span class="nm">${esc(t.name)}</span></div>`
      )
      .join("");
    const ex = `<section class="sec" data-sec="explorer"><h4>${CHEV}Explorer<span class="h-r">${NEWFILE}${NEWDIR}${PLUS}</span></h4><div class="row root">${CHEV}${esc(S.root)}</div>${tree}</section>`;
    const ch = `<section class="sec" data-sec="changes"><h4>${CHEV}Changes<span class="h-r">Since commit <span>${S.changes.length}</span></span></h4>${
      S.changes.length
        ? S.changes.map((c) => `<div class="row">${ICON[c.kind]}<span class="nm">${esc(c.name)}</span><span class="dir">${esc(c.dir || "")}</span><span class="letter ${c.l}">${c.l}</span></div>`).join("")
        : '<div class="empty">No changes since the last commit.</div>'
    }</section>`;
    const ag = `<section class="sec" data-sec="agents"><h4>${CHEV}Agents<span class="h-r">${HISTORY}<span>${S.agents.length}</span></span></h4>${S.agents
      .map(
        (a) =>
          `<div class="agent${a.attn ? " attn" : ""}" data-agent="${a.id}">${a.st === "work" ? '<span class="ast work">✻</span>' : `<span class="ast">${stIcon(a.st)}</span>`}<span class="atx"><b>${esc(a.title)}</b><small>${esc(a.sub)}</small></span>${
            S.timers && a.st === "work" ? `<span class="atime" data-since="${a.since}">${dur(a.since)}</span>` : ""
          }</div>`
      )
      .join("")}</section>`;
    // Open Items is folded, as people usually keep it, so the sections above have room.
    const oi = `<section class="sec" data-sec="open"><h4>${CHEV_SHUT}Open Items<span class="h-r"><span>${S.open.length}</span></span></h4></section>`;
    return `<aside class="side">${ws}${ex}${ch}${ag}${oi}</aside>`;
  }
  function render(root, S) {
    const inner = $("[data-inner]", root);
    inner.className = `win-inner${S.flip ? " flip" : ""}${S.changesFirst ? " changes-first" : ""}`;
    const groups = S.groups
      .map((g) => `<div class="group" data-group="${g.id}"><div class="tabs">${g.tabs.map(tabHTML).join("")}</div>${viewHTML(g)}${g.card ? cardHTML(g.card) : ""}</div>`)
      .join("");
    const peek = S.peek
      ? `<div class="peekbox"><div class="pk-head">${ICON[S.peek.icon]}<span class="pk-name"><b>${esc(S.peek.name)}</b><small>${esc(S.peek.dir)}</small></span><span class="pk-tab" data-pk-tab>Open as Tab</span><span class="pk-x">✕</span></div>${VIEWS[S.peek.view](S.peek)}</div>`
      : "";
    const sb = S.sb
      ? `${SB[S.sb.icon] || ""}<span>${esc(S.sb.text)}</span>${(S.sb.btns || []).map((b) => `<button type="button" class="sbtn" data-act="${b.act || ""}">${b.label}</button>`).join("")}`
      : "";
    const prev = root.sig || {};
    const sig = {
      peek: S.peek ? S.peek.name : "",
      pop: !!S.pop,
      notif: S.notif ? S.notif.title : "",
      cards: S.groups.map((g) => (g.card ? g.id + g.card.icon + g.card.title : "")),
    };
    inner.innerHTML =
      `<div class="titlebar"><span class="lights"><i></i><i></i><i></i></span><span class="tb-side">${svg('<rect x="2.5" y="4" width="15" height="12" rx="2.5"/><path d="M7.5 4v12"/>')}</span><span class="tb-title"><b>${esc(S.title)}</b><small>${esc(S.path)}</small></span><span class="tb-tools">${svg('<path d="M10 4.5v11M4.5 10h11"/>')}${svg('<path d="M4.5 10a5.5 5.5 0 1 0 1.6-3.9M4.5 4.5v2.5H7"/><path d="M10 7v3.2l2 1.3"/>')}${svg('<path d="M13.5 8.5 8.6 13.4a2.3 2.3 0 0 1-3.3-3.3l5.6-5.6a1.6 1.6 0 0 1 2.2 2.2l-5.3 5.3"/>')}${svg('<rect x="3" y="4" width="14" height="12" rx="2"/><path d="M10 4v12"/>')}${svg('<rect x="3" y="4" width="14" height="12" rx="2"/><path d="M3 10h14"/>')}</span></div>` +
      `<div class="body">${sideHTML(S)}<div class="main">${groups}${peek}${S.pop ? popHTML(S.pop) : ""}</div></div>` +
      `<div class="statusbar"><span class="sb-l">${BRANCH}${esc(S.branch)}</span><span class="sb-r">${sb}</span></div>` +
      (S.notif ? `<div class="notif"><img src="/img/tiri-icon.png" alt=""><span><b>${esc(S.notif.title)}</b><small>${esc(S.notif.body)}</small></span></div>` : "");
    const still = (sel) => sel && sel.classList.add("still");
    if (sig.peek && sig.peek === prev.peek) still($(".peekbox", inner));
    if (sig.pop && prev.pop) still($(".cpop", inner));
    if (sig.notif && sig.notif === prev.notif) still($(".notif", inner));
    S.groups.forEach((g, i) => {
      if (sig.cards[i] && (prev.cards || []).includes(sig.cards[i])) still($(`[data-group="${g.id}"] .tcard`, inner));
      g.tabs.forEach((t) => (t.enter = false));
    });
    const turn = -(Date.now() % 2400);
    $$(".ast.work, .cc-spin .star", inner).forEach((e) => (e.style.animationDelay = `${turn}ms`));
    root.sig = sig;
  }
  function flash(root, sel) {
    const el = $(sel, root);
    if (!el) return;
    el.classList.remove("flash");
    void el.offsetWidth;
    el.classList.add("flash");
  }
  async function reopen(root, apply, waitFn = wait) {
    root.classList.add("reopening");
    await waitFn(220);
    apply();
    await waitFn(280);
    root.classList.remove("reopening");
  }

  /* ---------- shared content ---------- */
  const SOURCE_TREE = (hot) => [
    { d: 0, dir: 1, name: "Remote" },
    { d: 0, dir: 1, open: 1, name: "Sources" },
    { d: 1, dir: 1, open: 1, name: "TiriApp" },
    ...["AgentsView.swift", "RootView.swift", "Sidebar.swift"].map((n) => ({ d: 2, kind: "code", name: n, hot: n === hot })),
    { d: 0, dir: 1, name: "Tests" },
    { d: 0, kind: "doc", name: "CHANGING.md" },
  ];
  function yourTiri(S, sentence) {
    if (!S.ws.some((w) => w.name === "Your Tiri")) S.ws.push({ name: "Your Tiri" });
    S.on = "Your Tiri";
    S.title = "Your Tiri";
    S.path = "Tiri's own source, for the version you're running";
    S.root = "SOURCE";
    S.tree = SOURCE_TREE();
    S.changes = [];
    S.open = [{ st: "work", name: sentence, on: true }];
  }
  const youLine = (s) => ["you", `Change Tiri for me: ${esc(s.charAt(0).toLowerCase() + s.slice(1))}. Everything you need is in .tiri-brief.md, so read that first.`];
  const BUILDING = (s) => ({ icon: "hammer", title: s, detail: "Claude Code is rewriting Tiri. This takes a few minutes, and Tiri says when it's ready.", btns: [{ label: "Keep Working", act: "keepworking" }] });
  const READY = (s) => ({
    icon: "sparkle",
    title: s,
    detail: "Ready to try. 2 files, 59 lines, check passed. Tiri reopens with this, and your agents keep running.",
    btns: [{ label: "Not Now", act: "notnow" }, { label: "See What Changed", act: "see" }, { label: "Try It", act: "try", hint: true }],
  });
  const TRYING = (s) => ({
    icon: "check",
    title: s,
    detail: "You're trying this. Keep it, or go back to how it was. It keeps itself after ten minutes.",
    btns: [{ label: "Go Back", act: "back" }, { label: "Keep", act: "keep", hint: true }],
  });

  /* =====================================================================
     The hero film
     ===================================================================== */
  const film = $("[data-film]");
  const cursorEl = $("[data-cursor]", film);
  const keyEl = $("[data-key]", film);
  const chapterBtns = $$("[data-ch]");
  const chaptersEl = $("[data-chapters]");
  const pauseBtn = $("[data-pause]");
  const STOP = Symbol("stop");
  let F = null;
  let tok = 0;
  let playing = !calm;
  let visible = false;
  let started = false;

  const JOB = {
    title: "job-hunt",
    path: "~/Documents/job-hunt",
    root: "JOB-HUNT",
    tree: [
      { d: 0, dir: 1, open: 1, name: "resume" },
      { d: 1, kind: "globe", name: "resume.html" },
      { d: 1, kind: "doc", name: "resume.pdf" },
      { d: 1, kind: "globe", name: "opportunities.html" },
      { d: 0, dir: 1, open: 1, name: "screenshots" },
      { d: 1, kind: "image", name: "acme-posting.png" },
      { d: 0, kind: "doc", name: "notes.md" },
    ],
  };
  const BILLING = {
    title: "billing-api",
    path: "~/Code/billing-api",
    root: "BILLING-API",
    tree: [
      { d: 0, dir: 1, open: 1, name: "src" },
      { d: 1, dir: 1, open: 1, name: "upload" },
      { d: 2, kind: "code", name: "retry.ts" },
      { d: 2, kind: "code", name: "backoff.ts" },
      { d: 0, dir: 1, open: 1, name: "tests" },
      { d: 1, kind: "code", name: "upload.spec.ts" },
      { d: 0, kind: "json", name: "package.json" },
    ],
    groups: [
      {
        id: "L",
        tabs: [{ id: "codex", st: "needs", title: "Fix the flaky upload test", on: true }],
        view: "term",
        banner: { agent: "codex", path: "~/Code/billing-api" },
        lines: [
          ["you", "Fix the flaky upload test"],
          ["say", "Found it. The retry in <span class=\"cc-a\">src/upload/retry.ts:42</span> didn't wait for the last attempt to settle."],
          ["say", "Changed <span class=\"cc-a\">src/upload/retry.ts</span>. Now I'll run the upload tests."],
          ["raw", "  Allow this command?\n  $ pnpm test upload\n\n  › 1. Yes\n    2. Yes, and don't ask again for pnpm test\n    3. No"],
        ],
        mode: "Codex is waiting for you",
      },
    ],
  };

  function filmBase() {
    const t = Date.now();
    F = {
      on: "job-hunt",
      ...JOB,
      branch: "main",
      ws: [{ name: "job-hunt" }, { name: "tiri-site" }, { name: "billing-api" }],
      changes: [{ kind: "globe", name: "resume.html", dir: "resume", l: "M" }],
      agents: [
        { id: "claude", st: "work", title: "Tailor my resume for Acme", sub: "Claude Code · job-hunt · Editing resume.html", since: t - 72e3 },
        { id: "codex", st: "work", title: "Fix the flaky upload test", sub: "Codex · billing-api · Running tests", since: t - 437e3 },
        { id: "grok", st: "work", title: "Write the release notes", sub: "Grok · tiri-site · Reading CHANGELOG.md", since: t - 301e3 },
      ],
      open: [{ st: "work", name: "Tailor my resume for Acme", on: true }, { icon: "image", name: "acme-posting.png" }, { icon: "globe", name: "resume.html" }, { icon: "doc", name: "notes.md" }],
      groups: [
        {
          id: "L",
          tabs: [{ id: "claude", st: "work", title: "Tailor my resume for Acme", on: true }],
          view: "term",
          banner: { agent: "claude", path: "~/Documents/job-hunt" },
          lines: [
            ["you", "Tailor my resume for the Acme role in screenshots/acme-posting.png, and write up why it fits."],
            ["sum", "Read 3 files, viewed 1 image"],
            ["say", "The posting asks for payments and API design, so I'll lead with your billing work."],
            ["say", 'Update(<span class="cc-a">resume/resume.html</span>)'],
            ["sub", "Updated with 6 additions and 2 removals"],
          ],
          spin: { verb: "Tailoring", since: t - 72e3 },
        },
        {
          id: "R",
          tabs: [
            { id: "image", icon: "image", title: "acme-posting.png", on: true },
            { id: "page", icon: "globe", title: "resume.html" },
            { id: "notes", icon: "doc", title: "notes.md" },
          ],
          view: "image",
        },
      ],
      jobGroups: null,
    };
  }
  const fr = () => render(film, F);
  const G = (id) => F.groups.find((g) => g.id === id);
  const agentOf = (id) => F.agents.find((a) => a.id === id);
  function showTab(g, id) {
    g.tabs.forEach((t) => {
      t.on = t.id === id;
      t.enter = false;
    });
    g.view = id;
  }
  function goWs(name) {
    if (F.on === "job-hunt") F.jobGroups = F.groups;
    F.on = name;
    const src = name === "billing-api" ? BILLING : JOB;
    F.title = src.title;
    F.path = src.path;
    F.root = src.root;
    F.tree = src.tree;
    F.groups = name === "billing-api" ? BILLING.groups : F.jobGroups;
    F.changes = name === "billing-api" ? [{ kind: "code", name: "retry.ts", dir: "src/upload", l: "M" }] : [{ kind: "globe", name: "resume.html", dir: "resume", l: "M" }];
  }

  // The film runs at this fraction of the times written below.
  const PACE = 0.5;
  async function tsleep(ms, my) {
    let left = calm ? Math.min(ms, 300) : ms * PACE;
    while (left > 0) {
      const live = (playing || calm) && visible && !document.hidden;
      await new Promise((r) => setTimeout(r, live ? 50 : 500));
      if (my !== tok) throw STOP;
      if ((playing || calm) && visible && !document.hidden) left -= 50;
    }
  }
  function pt(el, ax = 0.5, ay = 0.5) {
    const w = film.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    const s = w.width / 1120;
    return [(r.left - w.left + r.width * ax) / s, (r.top - w.top + r.height * ay) / s];
  }
  function camTo(x, y) {
    const st = $("#tour");
    st.camX = x;
    st.camY = y;
    fit(st);
  }
  async function move(sel, my, ax = 0.5, ay = 0.5, ms = 650) {
    const el = $(sel, film);
    if (!el) return;
    const [x, y] = pt(el, ax, ay);
    camTo(x, y);
    cursorEl.style.transitionDuration = `${calm ? 0 : ms * PACE}ms`;
    cursorEl.style.transform = `translate(${x - 5}px, ${y - 3}px)`;
    await tsleep(ms + 60, my);
  }
  async function click(my) {
    cursorEl.classList.add("down");
    await tsleep(150, my);
    cursorEl.classList.remove("down");
  }
  function key(label) {
    keyEl.textContent = label || "";
    keyEl.classList.toggle("on", !!label);
  }

  // One place to look at a time. The second argument says what the beat shows; it isn't drawn.
  // Two spotlights cross-fade, so the dimming stays put and only the lit place changes.
  const spotA = $("[data-spot]", film);
  const spotB = spotA.cloneNode();
  spotA.after(spotB);
  let spotOn = null;
  let spotKey = "";
  function spot(sels) {
    const el = sels ? $(sels, film) : null;
    if (!el) {
      if (spotOn) spotOn.classList.remove("on");
      spotOn = null;
      spotKey = "";
      return;
    }
    const w = film.getBoundingClientRect();
    const s = w.width / 1120;
    const q = el.getBoundingClientRect();
    const p = 4;
    const x = Math.max(3, (q.left - w.left) / s - p);
    const y = Math.max(3, (q.top - w.top) / s - p);
    const r = Math.min(1117, (q.right - w.left) / s + p);
    const b = Math.min(677, (q.bottom - w.top) / s + p);
    const key = [x, y, r, b].map(Math.round).join(",");
    if ($("#tour").classList.contains("zoomed")) aim($("#tour"), x, y, r, b);
    if (key === spotKey) return;
    spotKey = key;
    const next = spotOn === spotA ? spotB : spotA;
    Object.assign(next.style, { left: `${x}px`, top: `${y}px`, width: `${r - x}px`, height: `${b - y}px` });
    next.classList.add("on");
    if (spotOn) spotOn.classList.remove("on");
    spotOn = next;
  }



  const SENT = "Show how long each agent has been working";
  const fitTab = () => {
    const R = G("R");
    if (!R.tabs.some((t) => t.id === "fit")) R.tabs.push({ id: "fit", icon: "doc", title: "fit.md", enter: true });
    showTab(R, "fit");
    R.tabs[R.tabs.length - 1].enter = true;
  };
  const after = [
    () => {
      Object.assign(agentOf("codex"), { st: "needs", attn: true, sub: "Codex · billing-api · Needs you" });
      Object.assign(agentOf("grok"), { st: "done", sub: "Grok · tiri-site · Done" });
      Object.assign(F.ws.find((w) => w.name === "billing-api"), { badge: 1, pink: true });
    },
    () => {
      G("L").lines.push(["say", 'Update(<span class="cc-a">resume/resume.html</span>)'], ["sub", "Added the webhooks API you designed"]);
      G("R").v2 = true;
      showTab(G("R"), "page");
    },
    () => {
      G("L").lines.push(["say", 'Compared the three roles in <span class="cc-a" data-p="wrong">/resume/opportunities.html</span>.']);
    },
    () => {
      const L = G("L");
      L.lines.push(["say", 'Bash(<span class="cc-a" data-cmd>tiri open fit.md</span>)'], ["done", "✻ Crunched for 4m 12s"]);
      L.spin = null;
      L.tabs[0].st = "done";
      Object.assign(agentOf("claude"), { st: "done", sub: "Claude Code · job-hunt · Done" });
      fitTab();
    },
  ];

  const CH = [
    {
      dur: 10200,
      async run(my) {
        spot('[data-sec="agents"]', "Every agent you're running, in one list.");
        await move('[data-sec="agents"]', my, 0.7, 0.5, 700);
        await tsleep(1600, my);
        after[0]();
        F.notif = { title: "Codex needs you", body: "billing-api: allow pnpm test upload?" };
        fr();
        spot('[data-agent="codex"]', "Codex needs you, and you get a notification.");
        await move('[data-agent="codex"]', my, 0.6, 0.5, 600);
        await tsleep(2200, my);
        await move('[data-ws="billing-api"]', my, 0.4, 0.5, 600);
        await click(my);
        F.notif = null;
        goWs("billing-api");
        fr();
        spot(".main", "Each task has its own workspace: its folder, its tabs, its agents.");
        await tsleep(2600, my);
        await move('[data-ws="job-hunt"]', my, 0.4, 0.5, 600);
        await click(my);
        goWs("job-hunt");
        fr();
        spot(null, "");
        await tsleep(500, my);
      },
    },
    {
      dur: 6900,
      async run(my) {
        // The screenshot it read is already a tab. Notes next, then the page, which reloads as the agent edits it.
        spot('[data-group="R"]', "The job posting the agent read is right there, as an image tab.");
        await move('[data-tab="notes"]', my, 0.5, 0.5, 550);
        await click(my);
        showTab(G("R"), "notes");
        fr();
        await tsleep(1200, my);
        await move('[data-tab="page"]', my, 0.5, 0.5, 450);
        await click(my);
        showTab(G("R"), "page");
        fr();
        await tsleep(500, my);
        G("L").lines.push(["say", 'Update(<span class="cc-a">resume/resume.html</span>)'], ["sub", "Added the webhooks API you designed"]);
        G("R").v2 = true;
        G("R").reloadAt = Date.now();
        fr();
        spot(".main", "The agent saves, and the page reloads by itself.");
        await tsleep(2800, my);
        spot(null, "");
      },
    },
    {
      dur: 5400,
      async run(my) {
        after[2]();
        fr();
        spot('[data-group="L"]', "The agent printed a path that's wrong as written. There's no /resume at the top.");
        await move('[data-p="wrong"]', my, 0.55, 0.6, 600);
        // Holding ⌘ underlines every path Tiri can open, the wrong one included.
        key("⌘");
        $$('[data-group="L"] .cc-a', film).forEach((el) => el.classList.add("hover"));
        await tsleep(650, my);
        await click(my);
        F.peek = { icon: "globe", name: "opportunities.html", dir: "job-hunt/resume", view: "opps" };
        fr();
        key("");
        spot(".peekbox", "Tiri finds what it meant, floating over the session.");
        await tsleep(2300, my);
        key("esc");
        await tsleep(250, my);
        F.peek = null;
        fr();
        spot(null, "");
        await tsleep(500, my);
        key("");
      },
    },
    {
      dur: 10200,
      async run(my) {
        const L = G("L");
        L.lines.push(["say", 'Bash(<span class="cc-a" data-cmd>tiri open fit.md</span>)']);
        fr();
        spot("[data-cmd]", "Your agent can drive Tiri too. It runs tiri open on what it wrote.");
        await tsleep(2600, my);
        F.peek = { icon: "doc", name: "fit.md", dir: "job-hunt", view: "fit" };
        L.lines.push(["done", "✻ Crunched for 4m 12s"]);
        L.spin = null;
        L.tabs[0].st = "done";
        Object.assign(agentOf("claude"), { st: "done", sub: "Claude Code · job-hunt · Done" });
        fr();
        spot(".peekbox", "The write-up floats up for you to read. Your keyboard stays where it was.");
        await tsleep(2800, my);
        await move("[data-pk-tab]", my, 0.5, 0.5, 700);
        await click(my);
        F.peek = null;
        fitTab();
        fr();
        spot('[data-group="R"]', "One click keeps it as a tab.");
        await tsleep(2200, my);
        spot(null, "");
      },
    },
    {
      dur: 15800,
      async run(my) {
        // Two agents are back at work, so the change has something to show.
        Object.assign(agentOf("codex"), { st: "work", attn: false, sub: "Codex · billing-api · Running tests" });
        Object.assign(agentOf("grok"), { st: "work", sub: "Grok · tiri-site · Writing CHANGELOG.md" });
        Object.assign(F.ws.find((w) => w.name === "billing-api"), { badge: 0 });
        fr();
        await move(".main", my, 0.45, 0.4, 600);
        spot(null, "Not how you like it? Ask Tiri to change itself.");
        key("Tiri ▸ Change Tiri…");
        await tsleep(1600, my);
        F.pop = { text: "", items: [SENT, "Put Changes above Explorer in the sidebar", "Move the sidebar to the right"] };
        fr();
        key("");
        spot(".cpop", "Say what you want instead, in your own words.");
        await tsleep(700, my);
        for (let i = 1; i <= SENT.length; i++) {
          F.pop.text = SENT.slice(0, i);
          $(".cp-field", film).innerHTML = `<span>${esc(F.pop.text)}</span><i class="bcur"></i>`;
          await tsleep(28, my);
        }
        key("Return");
        await tsleep(600, my);
        key("");
        F.pop = null;
        yourTiri(F, SENT);
        F.agents.unshift({ id: "change", st: "work", title: SENT, sub: "Claude Code · Your Tiri · Reading AgentsView.swift", since: Date.now() });
        F.groups = [{ id: "L", tabs: [{ id: "change", st: "work", title: SENT, on: true, enter: true }], view: "term", banner: { agent: "claude", path: "~/…/Tiri/source" }, lines: [youLine(SENT)], spin: { verb: "Architecting", since: Date.now() - 24e3 }, card: BUILDING(SENT) }];
        F.sb = { icon: "spin", text: `Changing Tiri: ${SENT}`, btns: [{ label: "Show" }] };
        fr();
        spot('[data-group="L"]', "Your own agent rewrites Tiri's real source, inside Tiri.");
        await tsleep(1600, my);
        const L = G("L");
        L.lines.push(["sum", "Searched for 1 pattern, read 3 files, ran 4 shell commands"], ["say", "I'm adding a live timer to each working agent in the sidebar, then I'll build it and write the check."]);
        F.changes = [{ kind: "code", name: "AgentsView.swift", dir: "Sources/TiriApp", l: "M" }];
        F.tree = SOURCE_TREE("AgentsView.swift");
        fr();
        await tsleep(1800, my);
        L.lines.push(["sum", "Ran 2 shell commands"], ["say", "The change is built and ready, so press Try It on the card on my tab to switch to it."], ["done", "✻ Crunched for 3m 9s · done"]);
        L.spin = null;
        L.tabs[0].st = "done";
        L.tabs[0].enter = false;
        L.card = READY(SENT);
        F.changes = [];
        Object.assign(F.agents[0], { st: "done", sub: "Claude Code · Your Tiri · Ready to try" });
        F.ws.find((w) => w.name === "Your Tiri").badge = 1;
        F.sb = { icon: "sparkle", text: `Ready to try: ${SENT}`, btns: [{ label: "Try It" }] };
        fr();
        spot(".tcard", "Built and checked. Nothing changes until you try it.");
        await tsleep(1800, my);
        await move('.tcard [data-act="try"]', my, 0.5, 0.5, 700);
        await click(my);
        spot(null);
        await reopen(
          film,
          () => {
            F.timers = true;
            L.card = TRYING(SENT);
            F.ws.find((w) => w.name === "Your Tiri").badge = 0;
            F.sb = { icon: "check", text: `Trying: ${SENT}`, btns: [{ label: "Go Back" }, { label: "Keep" }] };
            fr();
          },
          (ms) => tsleep(ms, my)
        );
        spot('[data-sec="agents"]', "Tiri reopened with a timer on every working agent, and they kept running.");
        await tsleep(2600, my);
        spot(".tcard", "Keep it, or go back to how it was.");
        await tsleep(2200, my);
        spot(null, "");
      },
    },
  ];

  function setup(i) {
    filmBase();
    for (let k = 0; k < i; k++) after[k]();
    F.notif = null;
    F.peek = null;
    fr();
    key("");
    spot(null, "");
  }
  function mark(i) {
    chapterBtns.forEach((b, k) => {
      b.classList.remove("now");
      b.classList.toggle("seen", k < i);
    });
    const b = chapterBtns[i];
    b.style.setProperty("--dur", `${CH[i].dur * PACE}ms`);
    void b.offsetWidth;
    b.classList.add("now");
  }
  function syncPaused() {
    chaptersEl.classList.toggle("paused", !(playing && visible) || calm);
    pauseBtn.classList.toggle("play", !playing);
    pauseBtn.setAttribute("aria-label", playing ? "Pause the film" : "Play the film");
  }
  async function play(i, once = false) {
    const my = ++tok;
    started = true;
    mark(i);
    setup(i);
    try {
      await tsleep(400, my);
      await CH[i].run(my);
      await tsleep(500, my);
    } catch (e) {
      if (e !== STOP) throw e;
      return;
    }
    if (calm || once) return;
    play((i + 1) % CH.length);
  }
  chapterBtns.forEach((b, k) =>
    b.addEventListener("click", () => {
      if (!calm) playing = true;
      syncPaused();
      play(k, calm);
    })
  );
  pauseBtn.addEventListener("click", () => {
    playing = !playing;
    syncPaused();
    if (playing && !started) play(0);
  });
  new IntersectionObserver(
    (entries) => {
      visible = entries.some((e) => e.isIntersecting);
      syncPaused();
      if (visible && !started && !calm) play(0);
    },
    { threshold: 0.25 }
  ).observe($("#tour"));
  if (calm) {
    setup(4);
    mark(3);
  } else {
    setup(0);
  }
  syncPaused();

  /* =====================================================================
     The change demo: the real Change Tiri flow, working
     ===================================================================== */
  const CHANGES = [
    {
      id: "timers",
      ask: SENT,
      cls: "timers",
      file: "AgentsView.swift",
      plan: "adding a live timer to each working agent in the sidebar",
      done: "Each working agent now shows how long it has been working",
      shows: '[data-sec="agents"]',
      start: 41,
      diff: [
        [" ", "HStack(spacing: 8) {"],
        [" ", "    StatusDot(agent.status)"],
        [" ", "    AgentSummary(agent)"],
        [" ", "    Spacer()"],
        ["+", "    if let started = agent.workingSince {"],
        ["+", "        Text(started, style: .timer)"],
        ["+", "            .font(.caption.monospacedDigit())"],
        ["+", "            .foregroundStyle(.secondary)"],
        ["+", "    }"],
        [" ", "}"],
      ],
    },
    {
      id: "changes",
      ask: "Put Changes above Explorer in the sidebar",
      cls: "changesFirst",
      file: "Sidebar.swift",
      plan: "moving the Changes block above the Explorer header in Sidebar.swift",
      done: "Changes now sits above Explorer in the sidebar",
      shows: '[data-sec="changes"]',
      start: 88,
      diff: [
        [" ", "VStack(spacing: 0) {"],
        [" ", "    WorkspacesSection()"],
        ["+", "    ChangesSection()"],
        [" ", "    ExplorerSection()"],
        ["-", "    ChangesSection()"],
        [" ", "    AgentsSection()"],
        [" ", "}"],
      ],
    },
    {
      id: "flip",
      ask: "Move the sidebar to the right",
      cls: "flip",
      file: "RootView.swift",
      plan: "moving the sidebar to the trailing edge in RootView.swift",
      done: "The sidebar now sits on the right",
      shows: ".side",
      start: 63,
      diff: [
        [" ", "HStack(spacing: 0) {"],
        ["-", "    Sidebar()"],
        [" ", "    ContentArea()"],
        ["+", "    Sidebar()"],
        ["+", "        .environment(\\.sidebarEdge, .trailing)"],
        [" ", "}"],
      ],
    },
  ];

  const demo = $("[data-demo]");
  const note = $("[data-demo-note]");
  const againBtn = $("[data-again]");
  const mbar = $("[data-mbar]");
  const sentences = $("[data-sentences]");
  const versionEl = $("[data-version]");
  let D = null;
  let phase = "pick";
  let current = null;
  let applied = { timers: false, changesFirst: false, flip: false };
  const kept = new Map();

  function demoBase() {
    const t = Date.now();
    D = {
      on: "tiri-site",
      title: "tiri-site",
      path: "~/Code/tiri-site",
      branch: "main",
      ws: [{ name: "Home" }, { name: "tiri-site" }, { name: "billing-api" }],
      root: "TIRI-SITE",
      tree: [
        { d: 0, dir: 1, open: 1, name: "src" },
        { d: 1, dir: 1, open: 1, name: "components" },
        { d: 2, kind: "code", name: "Header.tsx" },
        { d: 2, kind: "code", name: "ThemeToggle.tsx" },
        { d: 1, kind: "doc", name: "app.css" },
        { d: 0, kind: "json", name: "package.json" },
      ],
      changes: [{ kind: "doc", name: "app.css", dir: "src", l: "M" }],
      agents: [
        { id: "claude", st: "work", title: "Add a dark mode toggle", sub: "Claude Code · tiri-site · Editing Header.tsx", since: t - 72e3 },
        { id: "codex", st: "needs", title: "Fix the flaky upload test", sub: "Codex · billing-api · Needs you", since: t - 437e3 },
      ],
      open: [{ st: "work", name: "Add a dark mode toggle", on: true }],
      groups: [
        {
          id: "L",
          tabs: [{ id: "claude", st: "work", title: "Add a dark mode toggle", on: true }],
          view: "term",
          banner: { agent: "claude", path: "~/Code/tiri-site" },
          lines: [
            ["you", "Add a dark mode toggle to the header. Follow the system setting until someone picks."],
            ["sum", "Read 2 files"],
            ["say", 'Write(<span class="cc-a">src/components/ThemeToggle.tsx</span>)'],
            ["sub", "Wrote 38 lines"],
            ["say", 'Update(<span class="cc-a">src/components/Header.tsx</span>)'],
            ["sub", "Updated with 3 additions and 1 removal"],
          ],
          spin: { verb: "Wiring", since: t - 42e3 },
        },
      ],
      pop: { text: "", items: CHANGES.map((c) => c.ask), picked: null, done: [] },
      ...applied,
    };
  }
  // On a phone the camera goes to whatever needs you: the popover, the card, the diff, or what just changed.
  function demoCam(sel) {
    const st = $("#demo");
    if (!st.classList.contains("zoomed")) return;
    const el = sel ? $(sel, demo) : $(".cpop", demo) || $(".tcard", demo) || $('[data-group="R"]', demo) || $(".term", demo);
    if (!el) return;
    const w = demo.getBoundingClientRect();
    const s = w.width / 1120;
    const q = el.getBoundingClientRect();
    aim(st, (q.left - w.left) / s, (q.top - w.top) / s, (q.right - w.left) / s, (q.bottom - w.top) / s);
  }
  const dr = () => {
    Object.assign(D, applied);
    render(demo, D);
    syncUnder();
    demoCam();
  };
  const NOTES = {
    // A narrow screen sends the change as soon as it's picked.
    get pick() {
      if (narrow.matches) return "Pick a change in the window.";
      return touch ? "Pick a change in the window, then tap Return." : "Pick a change in the window, then press Return.";
    },
    asked: touch ? "Tap Return to hand it to Claude Code." : "Press Return to hand it to Claude Code.",
    building: "Claude Code is rewriting Tiri, inside Tiri. Minutes in real life, seconds here.",
    ready: touch ? "Built and checked. Tap Try It." : "Built and checked. Press Try It.",
    trying: "Tiri reopened with the change, and your agents kept running. Keep it, or go back.",
    kept: "Kept. It's in the list below, and every update keeps it.",
    back: "Back to how it was. Nothing else changed.",
    plain: "Plain Tiri. Your changes are saved; switch them back on below.",
  };
  function syncUnder() {
    note.textContent = NOTES[phase] || "";
    againBtn.hidden = !["kept", "back", "plain"].includes(phase) || kept.size === CHANGES.length;
    mbar.innerHTML = "";
    const card = D.groups[0] && D.groups[0].card;
    if (card && ["ready", "trying"].includes(phase)) {
      card.btns
        .filter((b) => ["try", "back", "keep"].includes(b.act))
        .forEach((b) => {
          const el = document.createElement("button");
          el.type = "button";
          el.className = b.hint ? "btn-pink" : "btn-quiet";
          el.textContent = b.label;
          el.addEventListener("click", () => act(b.act));
          mbar.append(el);
        });
    }
  }

  async function pick(i) {
    if (!["pick", "asked"].includes(phase)) return;
    phase = "asked";
    current = CHANGES[i];
    D.pop.picked = i;
    D.pop.full = false;
    const text = current.ask;
    for (let n = 1; n <= text.length; n++) {
      if (current !== CHANGES[i]) return;
      D.pop.text = text.slice(0, n);
      if (calm) D.pop.text = text;
      dr();
      if (calm) break;
      await new Promise((r) => setTimeout(r, 14));
    }
    D.pop.full = true;
    dr();
    if (narrow.matches) ask();
  }

  async function ask() {
    if (phase !== "asked" || !D.pop.full) return;
    phase = "building";
    const c = current;
    D.pop = null;
    yourTiri(D, c.ask);
    D.agents.unshift({ id: "change", st: "work", title: c.ask, sub: "Claude Code · Your Tiri · Reading CHANGING.md", since: Date.now() });
    D.groups = [{ id: "L", tabs: [{ id: "change", st: "work", title: c.ask, on: true, enter: true }], view: "term", banner: { agent: "claude", path: "~/…/Tiri/source" }, lines: [youLine(c.ask)], spin: { verb: "Architecting", since: Date.now() }, card: BUILDING(c.ask) }];
    D.sb = { icon: "spin", text: `Changing Tiri: ${c.ask}`, btns: [{ label: "Show" }] };
    dr();
    const L = D.groups[0];
    L.tabs[0].enter = false;
    await wait(1100);
    L.lines.push(["sum", "Searched for 1 pattern, read 3 files, ran 4 shell commands"], ["say", `I'm ${c.plan}, then I'll build it and write the check.`]);
    D.tree = SOURCE_TREE(c.file);
    D.changes = [{ kind: "code", name: c.file, dir: "Sources/TiriApp", l: "M" }];
    D.agents[0].sub = `Claude Code · Your Tiri · Editing ${c.file}`;
    dr();
    await wait(1300);
    L.lines.push(["say", "Running 1 shell command · 2s…"], ["sub", "$ ./build.sh && tiri change check"]);
    D.agents[0].sub = "Claude Code · Your Tiri · Building Tiri";
    dr();
    await wait(1600);
    L.lines.splice(-2, 2, ["sum", "Ran 2 shell commands"], ["say", `${c.done}. The change is built and ready, so press Try It on the card on my tab to switch to it.`], ["done", "✻ Crunched for 3m 9s · done"]);
    L.spin = null;
    L.tabs[0].st = "done";
    L.card = READY(c.ask);
    D.changes = [];
    Object.assign(D.agents[0], { st: "done", sub: "Claude Code · Your Tiri · Ready to try" });
    D.open[0].st = "done";
    D.ws.find((w) => w.name === "Your Tiri").badge = 1;
    D.sb = { icon: "sparkle", text: `Ready to try: ${c.ask}`, btns: [{ label: "Try It", act: "try" }] };
    phase = "ready";
    dr();
  }

  async function tryIt() {
    if (phase !== "ready") return;
    const c = current;
    phase = "trying";
    await reopen(demo, () => {
      applied[c.cls] = true;
      D.groups = D.groups.filter((g) => g.id === "L");
      D.groups[0].card = TRYING(c.ask);
      D.ws.find((w) => w.name === "Your Tiri").badge = 0;
      D.sb = { icon: "check", text: `Trying: ${c.ask}`, btns: [{ label: "Go Back", act: "back" }, { label: "Keep", act: "keep" }] };
      dr();
    });
    flash(demo, c.shows);
    demoCam(c.shows);
  }
  function settle() {
    D.groups[0].card = null;
    D.sb = null;
    current = null;
  }
  function keep() {
    if (phase !== "trying") return;
    const c = current;
    kept.set(c.id, true);
    settle();
    phase = "kept";
    dr();
    renderList(c.id);
  }
  async function back() {
    if (phase !== "trying") return;
    const c = current;
    await reopen(demo, () => {
      applied[c.cls] = false;
      settle();
      phase = "back";
      dr();
    });
  }
  function notNow() {
    if (phase !== "ready") return;
    D.groups[0].card = null;
    dr();
  }
  function see() {
    if (phase !== "ready" || D.groups.length > 1) return;
    const c = current;
    let n = c.start;
    const code = c.diff
      .map(([k, t]) => {
        const cls = k === "+" ? "plus" : k === "-" ? "minus" : "";
        const num = k === "-" ? "" : n++;
        return `<span class="${cls}"><span class="ln">${num}</span>${hl(t)[0]}</span>`;
      })
      .join("");
    D.groups.push({ id: "R", tabs: [{ id: "diff", icon: "diff", title: `${c.file} (this change)`, on: true, enter: true }], view: "code", crumbs: `Sources › TiriApp › ${c.file}`, code });
    dr();
  }
  function againOpen() {
    phase = "pick";
    current = null;
    D.pop = { text: "", items: CHANGES.map((c) => c.ask), picked: null, done: CHANGES.map((c, i) => (kept.has(c.id) ? i : -1)).filter((i) => i >= 0) };
    dr();
  }

  function act(a) {
    if (!a) return;
    if (a.startsWith("pick:")) return pick(+a.slice(5));
    ({ ask, try: tryIt, keep, back, notnow: notNow, see }[a] || (() => {}))();
  }
  demo.addEventListener("click", (e) => {
    const b = e.target.closest("[data-act]");
    if (b) act(b.dataset.act);
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && phase === "asked") {
      const r = demo.getBoundingClientRect();
      if (r.top < innerHeight && r.bottom > 0) {
        e.preventDefault();
        ask();
      }
    }
  });
  againBtn.addEventListener("click", againOpen);

  // phones: the choices sit above the window
  $$("[data-ask-list]").forEach((list) => {
    CHANGES.forEach((c, i) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "cp-item";
      b.innerHTML = `<span class="q">“</span>${esc(c.ask)}`;
      b.addEventListener("click", () => {
        if (["kept", "back", "plain"].includes(phase)) againOpen();
        pick(i);
        $("#demo").scrollIntoView({ behavior: calm ? "auto" : "smooth", block: "center" });
      });
      list.append(b);
    });
  });

  /* the Your Tiri list */
  function renderList(fresh) {
    $$("li:not([data-static])", sentences).forEach((li) => li.remove());
    [...kept.keys()].reverse().forEach((id) => {
      const c = CHANGES.find((x) => x.id === id);
      const li = document.createElement("li");
      if (id === fresh) li.className = "enter";
      li.innerHTML = `<span class="sn-text">${esc(c.ask)}<small>Today, from the window above</small></span><button type="button" class="switch" role="switch" aria-checked="${kept.get(id)}" aria-label="${esc(c.ask)}"></button>`;
      $(".switch", li).addEventListener("click", () => toggleKept(c));
      sentences.prepend(li);
    });
    const n = $$("li", sentences).length;
    versionEl.textContent = `Tiri 0.2 with ${n} change${n === 1 ? "" : "s"}`;
  }
  async function toggleKept(c) {
    if (["building", "ready", "trying"].includes(phase)) return;
    const on = !kept.get(c.id);
    kept.set(c.id, on);
    renderList();
    await reopen(demo, () => {
      applied[c.cls] = on;
      dr();
    });
    if (on) {
      flash(demo, c.shows);
      demoCam(c.shows);
    }
  }
  $("[data-plain]").addEventListener("click", async () => {
    if (["building", "ready", "trying"].includes(phase)) return;
    kept.forEach((_, id) => kept.set(id, false));
    $$("[data-static] .switch").forEach((s) => s.setAttribute("aria-checked", "false"));
    renderList();
    await reopen(demo, () => {
      applied = { timers: false, changesFirst: false, flip: false };
      phase = "plain";
      dr();
    });
  });
  $$("[data-static] .switch").forEach((s) =>
    s.addEventListener("click", () => s.setAttribute("aria-checked", s.getAttribute("aria-checked") === "true" ? "false" : "true"))
  );

  // It plays itself once, until someone touches it.
  let touched = false;
  const changeSec = $("#change");
  ["pointerdown", "keydown"].forEach((ev) => changeSec.addEventListener(ev, () => (touched = true), true));
  async function autoChange() {
    if (calm || touched || phase !== "pick") return;
    await wait(700);
    if (touched) return;
    await pick(0);
    if (touched) return;
    await wait(700);
    if (touched) return;
    if (phase === "asked") await ask();
    while (phase === "building" && !touched) await wait(200);
    if (touched || phase !== "ready") return;
    await wait(1200);
    if (touched) return;
    await tryIt();
    await wait(3000);
    if (touched || phase !== "trying") return;
    keep();
  }
  new IntersectionObserver(
    (entries, io) => {
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect();
        autoChange();
      }
    },
    { threshold: 0.5 }
  ).observe($("#demo"));

  demoBase();
  dr();

  /* =====================================================================
     The Peek section
     ===================================================================== */
  const FILES = {
    retry: {
      name: "retry.ts",
      dir: "src/upload",
      start: 36,
      mark: 42,
      code: `export async function retry<T>(
  run: () => Promise<T>,
  tries = 3,
): Promise<T> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    await previous?.catch(() => {});
    try {
      return await run();
    } catch (error) {
      last = error;
      await backoff(i);
    }
  }`,
    },
    spec: {
      name: "upload.spec.ts",
      dir: "tests",
      start: 1,
      mark: 4,
      code: `import { test, expect } from "vitest";
import { retry } from "../src/upload/retry";

test("waits for the last attempt to settle", async () => {
  let running = 0;
  const run = async () => {
    expect(running).toBe(0);
    running++;
    await tick();
    running--;
    throw new Error("offline");
  };`,
    },
    backoff: {
      name: "backoff.ts",
      dir: "src/upload",
      wrong: true,
      start: 1,
      mark: 7,
      code: `// Helper for the old uploader.
// Nothing imports it now.

const base = 200;
const cap = 8_000;

export function backoffMs(attempt: number) {
  return Math.min(cap, base * 2 ** attempt);
}`,
    },
  };
  const peekwin = $("[data-peekwin]");
  const box = $("[data-peekbox]");
  const say = $("[data-peek-say]");
  if (touch) say.textContent = "Tap the paths in the window. One of them is wrong.";
  const sayDefault = say.textContent;
  let opener = null;
  function openPeek(btn, auto = false) {
    const f = FILES[btn.dataset.peek];
    $$(".path.open", peekwin).forEach((p) => p.classList.remove("open"));
    btn.classList.add("open");
    opener = btn;
    $("[data-peek-name]", box).textContent = f.name;
    $("[data-peek-dir]", box).textContent = f.dir;
    $("[data-peek-code]", box).innerHTML = hl(f.code)
      .map((l, i) => {
        const n = f.start + i;
        const row = `<span class="ln">${n}</span>${l}`;
        return n === f.mark ? `<span class="hl">${row}</span>` : `${row}\n`;
      })
      .join("");
    say.textContent = f.wrong ? "That path was wrong as written. Tiri found src/upload/backoff.ts anyway." : sayDefault;
    box.hidden = false;
    box.style.animation = "none";
    void box.offsetWidth;
    box.style.animation = "";
    if (!auto) $("[data-peek-close]", box).focus({ preventScroll: true });
  }
  function closePeek(auto = false) {
    if (box.hidden) return;
    box.hidden = true;
    $$(".path.open", peekwin).forEach((p) => p.classList.remove("open"));
    say.textContent = sayDefault;
    if (opener && !auto) opener.focus({ preventScroll: true });
  }
  $$(".path", peekwin).forEach((b) => b.addEventListener("click", () => openPeek(b)));
  $("[data-peek-close]", box).addEventListener("click", () => closePeek());
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closePeek();
  });

  // It plays by itself while it's on screen: a path, then the wrong one. Touching it stops that for good.
  let peekTouched = false;
  let peekSeen = false;
  ["pointerdown", "keydown", "focusin"].forEach((ev) => peekwin.addEventListener(ev, () => (peekTouched = true), true));
  new IntersectionObserver((entries) => (peekSeen = entries.some((e) => e.isIntersecting)), { threshold: 0.4 }).observe(peekwin);
  const hold = async (ms) => {
    let left = ms;
    while (left > 0) {
      const live = peekSeen && !document.hidden;
      await new Promise((r) => setTimeout(r, live ? 100 : 600));
      if (peekTouched) throw STOP;
      if (peekSeen && !document.hidden) left -= 100;
    }
  };
  async function autoPeek() {
    if (calm) return;
    const real = $('[data-peek="retry"]', peekwin);
    const wrong = $('[data-peek="backoff"]', peekwin);
    try {
      for (;;) {
        await hold(1200);
        for (const btn of [real, wrong]) {
          btn.classList.add("hint");
          await hold(500);
          btn.classList.remove("hint");
          openPeek(btn, true);
          await hold(2600);
          closePeek(true);
          await hold(700);
        }
      }
    } catch (e) {
      if (e !== STOP) throw e;
      $$(".path.hint", peekwin).forEach((p) => p.classList.remove("hint"));
    }
  }
  autoPeek();
  document.addEventListener("keydown", () => {
  });
  peekwin.addEventListener("click", (e) => {
    if (!box.hidden && !box.contains(e.target) && !e.target.closest(".path")) closePeek();
  });
})();
