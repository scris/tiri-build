#!/usr/bin/env node
// Writes everything the highlighter ships with:
//   Resources/grammars/*.json.z, index.json and NOTICE.txt
//   Resources/textmate/ (the TextMate engine and its regular expression library)
//   Sources/TiriCore/GeneratedLanguages.swift
//
//   cd scripts/grammars && npm ci --ignore-scripts && node build.mjs
//
// Only grammars whose licence has been read get bundled: see `excluded` and `verified`.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const modules = path.join(here, 'node_modules');
const { grammars, injections } = await import(path.join(modules, 'tm-grammars/index.js'));
const linguist = (await import(path.join(modules, 'linguist-languages/index.js')));

// Copyleft, or no licence anyone can point to. An agent can still add these for you.
const excluded = {
  ada: 'GPL-3.0', gnuplot: 'GPL-3.0', nginx: 'GPL-3.0', org: 'GPL-3.0', racket: 'GPL-3.0', ahk2: 'LGPL-3.0',
  apl: 'no licence in its repository', dax: 'no licence in its repository', 'dream-maker': 'no licence in its repository',
  glsl: 'no licence in its repository', tcl: 'no licence in its repository',
};
// tm-grammars can't name these licences, so they were read at the source. Names are files in licenses/.
const bundle = 'textmate-bundle';
const verified = {
  abap: bundle, applescript: bundle, erb: bundle, logo: bundle, mipsasm: bundle, po: bundle, 'ssh-config': bundle, toml: bundle, yaml: bundle,
  apache: 'apache', apex: 'apex', asciidoc: 'asciidoc', cue: 'cue', elixir: 'elixir', llvm: 'llvm', luau: 'luau', nim: 'nim', nsis: 'nsis',
  purescript: 'purescript', sass: 'sass', wolfram: 'wolfram', matlab: 'matlab', kusto: 'kusto', sparql: 'stardog', turtle: 'stardog',
  hurl: 'MIT, as its package.json says', rel: 'MIT, as its README says', 'ts-tags': 'MIT, written by tm-grammars itself',
};
const permissive = new Set(['MIT', 'Apache-2.0', 'BSD-3-Clause', 'BSD-2-Clause', 'ISC', 'MPL-2.0']);

const everything = [...grammars, ...injections];
const kept = everything.filter((g) => {
  if (excluded[g.name]) return false;
  if (verified[g.name] || permissive.has(g.license)) return true;
  throw new Error(`${g.name}: licence ${g.license ?? 'unknown'} hasn't been read. Add it to verified or excluded.`);
});

// MARK: Grammars

const out = path.join(root, 'Resources/grammars');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
const read = (g) => fs.readFileSync(path.join(modules, 'tm-grammars/grammars', `${g.name}.json`), 'utf8');
const scopes = {};
const injectTo = {};
let compressed = 0;
for (const g of kept) {
  const packed = zlib.deflateRawSync(JSON.stringify(JSON.parse(read(g))), { level: 9 });
  fs.writeFileSync(path.join(out, `${g.name}.json.z`), packed);
  compressed += packed.length;
  scopes[g.scopeName] = g.name;
  for (const host of g.injectTo ?? []) (injectTo[host] ??= []).push(g.scopeName);
}
// Tiri's own, for settings files nobody has written a grammar for.
for (const file of fs.readdirSync(path.join(here, 'own'))) {
  const raw = JSON.parse(fs.readFileSync(path.join(here, 'own', file), 'utf8'));
  fs.writeFileSync(path.join(out, `${raw.name}.json.z`), zlib.deflateRawSync(JSON.stringify(raw), { level: 9 }));
  scopes[raw.scopeName] = raw.name;
}
fs.writeFileSync(path.join(out, 'index.json'), JSON.stringify({ scopes, injections: injectTo }));

// A notice for each licence, from tm-grammars' own where it has one.
const notice = fs.readFileSync(path.join(modules, 'tm-grammars/NOTICE'), 'utf8');
const rule = /={20,}\n/;
const [preamble, ...blocks] = notice.split(rule);
const keptBlocks = blocks.filter((block) => {
  const file = /^Files:\s+(\S+)\.json/m.exec(block)?.[1];
  return !file || !excluded[file];
});
let sections = [preamble.trim(), ...keptBlocks.map((b) => b.trim())];
sections.push(`tm-grammars itself\n${fs.readFileSync(path.join(modules, 'tm-grammars/LICENSE'), 'utf8').trim()}`);
const byLicence = {};
for (const [name, licence] of Object.entries(verified)) (byLicence[licence] ??= []).push(name);
for (const [licence, names] of Object.entries(byLicence)) {
  const file = path.join(here, 'licenses', `${licence}.txt`);
  const text = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').trim() : licence;
  sections.push(`Files: ${names.map((n) => `${n}.json`).join(', ')}\n${text}`);
}
const microsoft = `MIT License\n\nCopyright (c) Microsoft Corporation. All rights reserved.\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.`;
// Their packages don't include the file, and both declare MIT.
const mitOf = { 'vscode-textmate': microsoft, 'vscode-oniguruma': microsoft };
for (const pkg of ['vscode-textmate', 'vscode-oniguruma', 'linguist-languages']) {
  const file = fs.readdirSync(path.join(modules, pkg)).find((f) => /^licen[sc]e/i.test(f));
  const license = file ? fs.readFileSync(path.join(modules, pkg, file), 'utf8').trim() : mitOf[pkg];
  sections.push(`${pkg}\n${license}`);
}
fs.writeFileSync(path.join(out, 'NOTICE.txt'), sections.join('\n\n' + '='.repeat(80) + '\n\n') + '\n');

// MARK: The engine

const engine = path.join(root, 'Resources/textmate');
fs.mkdirSync(engine, { recursive: true });
for (const [from, to] of [
  ['vscode-textmate/release/main.js', 'vscode-textmate.js'],
  ['vscode-oniguruma/release/main.js', 'vscode-oniguruma.js'],
  ['vscode-oniguruma/release/onig.wasm', 'onig.wasm'],
]) fs.copyFileSync(path.join(modules, from), path.join(engine, to));

// MARK: Which files are which language

const names = (g) => [g.name, ...(g.aliases ?? [])].map((n) => n.toLowerCase());
const data = Object.values(linguist.default ?? linguist).filter((l) => l && l.name);
// Linguist's own entry for this language, and others that only borrow its grammar.
function linguistFor(g) {
  const wanted = new Set(names(g));
  const display = g.displayName?.toLowerCase();
  const own = [];
  const borrowing = [];
  for (const l of data) {
    const known = [l.name, ...(l.aliases ?? [])].map((n) => n.toLowerCase());
    if (known.some((n) => wanted.has(n)) || l.name.toLowerCase() === display) own.push(l);
    else if (l.tmScope === g.scopeName) borrowing.push(l);
  }
  return { own, borrowing };
}

// Where two languages claim an extension, the one people mean more often.
const preferred = ['javascript', 'typescript', 'python', 'c', 'cpp', 'objective-c', 'java', 'csharp', 'go', 'rust', 'ruby', 'php', 'swift',
  'kotlin', 'shellscript', 'html', 'css', 'json', 'yaml', 'toml', 'markdown', 'sql', 'perl', 'r', 'lua', 'scala', 'xml', 'latex', 'clojure',
  'elixir', 'erlang', 'haskell', 'ocaml', 'fsharp', 'dart', 'julia', 'zig', 'vue', 'svelte'];
const rank = (name) => { const i = preferred.indexOf(name); return i < 0 ? preferred.length : i; };

// A rule's literal text, once what surrounds it in a regular expression is taken away.
function literal(pattern) {
  if (typeof pattern !== 'string') return null;
  let text = pattern
    .replace(/^\(\?x\)/, '').replace(/\(\?<[=!][^)]*\)/g, '').replace(/\(\?[=!][^)]*\)/g, '')
    .replace(/^\^/, '').replace(/\$$/, '').replace(/\\G/g, '')
    .replace(/\(\^?\[ ?\\t\]\+\)\?/g, '').replace(/\^?\\s\*/g, '').replace(/\[ ?\\t\]\*/g, '').replace(/\(\?:\^\|\\G\)/g, '');
  text = text.replace(/^\((.*)\)$/, '$1').replace(/^\?:/, '');
  text = text.replace(/\\(.)/g, '$1');
  return /^[^\sA-Za-z0-9()[\]{}|?+^$]{1,4}$/.test(text) ? text : null;
}

function commentsOf(raw) {
  const lines = new Map();
  const blocks = new Map();
  const visit = (node) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) return node.forEach(visit);
    const name = `${node.name ?? ''} ${node.contentName ?? ''}`;
    if (/\bcomment\.line\b/.test(name) && !/embedded/.test(name)) {
      const text = literal(node.begin) ?? literal(/^\(?([^)]*)\)?\.\*\$?$/.exec(node.match ?? '')?.[1]);
      if (text) lines.set(text, (lines.get(text) ?? 0) + 1);
    }
    if (/\bcomment\.block\b/.test(name) && !/documentation/.test(name)) {
      const open = literal(node.begin); const close = literal(node.end);
      if (open && close) { const key = `${open}\u0000${close}`; blocks.set(key, (blocks.get(key) ?? 0) + 1); }
    }
    Object.values(node).forEach(visit);
  };
  visit(raw.repository); visit(raw.patterns);
  const best = (map) => [...map.entries()].sort((a, b) => b[1] - a[1])[0]?.[0];
  const block = best(blocks)?.split('\u0000') ?? [];
  // `///` and `----` are decorated versions of the comment itself.
  const line = best(lines)?.replace(/^(.)\1{2,}$/, '$1$1') ?? '';
  return { line, open: block[0] ?? '', close: block[1] ?? '' };
}

const borrowed = new Set();
const claims = new Map();
const nameClaims = new Map();
const rows = [];
for (const g of grammars.filter((g) => !excluded[g.name])) {
  const raw = JSON.parse(read(g));
  const sources = linguistFor(g);
  const extensions = new Set((raw.fileTypes ?? []).map((t) => t.replace(/^\./, '').toLowerCase()).filter((t) => !t.includes('.') || t.split('.').length <= 2));
  const filenames = new Set();
  const interpreters = new Set();
  for (const s of sources.own) {
    for (const e of s.extensions ?? []) extensions.add(e.replace(/^\./, '').toLowerCase());
    for (const f of s.filenames ?? []) filenames.add(f.toLowerCase());
    for (const i of s.interpreters ?? []) interpreters.add(i);
  }
  // Only used if nothing has a better claim.
  for (const s of sources.borrowing) {
    for (const e of s.extensions ?? []) {
      const key = e.replace(/^\./, '').toLowerCase();
      if (!extensions.has(key)) { extensions.add(key); borrowed.add(`${g.name}\u0000${key}`); }
    }
    for (const f of s.filenames ?? []) {
      const key = f.toLowerCase();
      if (!filenames.has(key)) { filenames.add(key); borrowed.add(`${g.name}\u0000${key}`); }
    }
  }
  for (const e of extensions) { if (!claims.has(e)) claims.set(e, []); claims.get(e).push(g.name); }
  for (const f of filenames) { if (!nameClaims.has(f)) nameClaims.set(f, []); nameClaims.get(f).push(g.name); }
  rows.push({ g, comments: commentsOf(raw), extensions, filenames, interpreters });
}
const winner = (claimants, key) => [...claimants].sort((a, b) =>
  (Number(borrowed.has(`${a}\u0000${key}`)) - Number(borrowed.has(`${b}\u0000${key}`))) || (rank(a) - rank(b)) || (Number(names(grammars.find((g) => g.name === b)).includes(key)) - Number(names(grammars.find((g) => g.name === a)).includes(key))) || a.localeCompare(b))[0];

const clean = (values) => [...values].sort().join(' ');
const lines = rows.map(({ g, comments, extensions, filenames, interpreters }) => {
  const ownExtensions = [...extensions].filter((e) => !/\s/.test(e) && winner(claims.get(e), e) === g.name);
  const ownNames = [...filenames].filter((f) => !/\s/.test(f) && winner(nameClaims.get(f), f) === g.name);
  const cells = [g.name, g.displayName ?? g.name, g.scopeName, clean(ownExtensions), clean(ownNames), clean(interpreters), clean(g.aliases ?? []),
    comments.line, comments.open, comments.close];
  if (cells.some((c) => c.includes('\t') || c.includes('\n'))) throw new Error(`${g.name}: a cell holds a separator`);
  return cells.join('\t');
});

fs.writeFileSync(path.join(root, 'Sources/TiriCore/GeneratedLanguages.swift'), `// Written by scripts/grammars/build.mjs. Change that, or add to LanguageCatalog.swift, and not this.

extension LanguageCatalog {
    /// id, name, grammar scope, extensions, file names, interpreters, aliases, line comment, block open, block close.
    /// One string rather than a list of values, because the compiler takes minutes over a list this long.
    static let generatedTable = #"""
${lines.join('\n')}
"""#
}
`);

const total = kept.reduce((sum, g) => sum + fs.statSync(path.join(modules, 'tm-grammars/grammars', `${g.name}.json`)).size, 0);
console.log(`${rows.length} languages, ${kept.length} grammars with injections: ${(total / 1048576).toFixed(1)} MB, ${(compressed / 1048576).toFixed(2)} MB compressed`);
console.log(`left out: ${Object.keys(excluded).join(', ')}`);
