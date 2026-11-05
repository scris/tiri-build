// The part of the highlighter that lives in JavaScriptCore. Swift hands it blocks of lines, and it
// keeps each line's end state, the way VS Code does, so typing usually redoes a single line.
(function () {
  'use strict';
  var tm = globalThis.vscodetextmate;
  var onig = globalThis.onig;

  // A theme whose "colors" are numbers: the matching of scopes to kinds is the library's own.
  var KIND = { comment: 1, string: 2, number: 3, keyword: 4, function: 5, type: 6, attribute: 7 };
  function color(kind) { return '#00000' + kind; }
  function rule(scope, kind) { return { scope: scope, settings: { foreground: kind === 0 ? '#000000' : color(kind) } }; }
  var theme = {
    name: 'tiri',
    settings: [
      { settings: { foreground: '#000000', background: '#ffffff' } },
      rule(['comment', 'punctuation.definition.comment', 'string.comment'], KIND.comment),
      rule(['string', 'string.regexp', 'markup.inline.raw', 'markup.fenced_code', 'markup.raw', 'constant.other.symbol', 'constant.other.key'], KIND.string),
      // What's interpolated into a string is code again.
      rule(['meta.embedded', 'source.groovy.embedded', 'meta.template.expression', 'string meta.interpolation', 'meta.interpolation'], 0),
      rule(['constant.numeric', 'constant.language', 'constant.character.numeric', 'constant.other.color', 'keyword.other.unit', 'markup.list.numbered'], KIND.number),
      rule(['keyword', 'storage', 'storage.type', 'storage.modifier', 'keyword.control', 'variable.language', 'support.type.primitive.keyword', 'markup.bold', 'keyword.other.special-method'], KIND.keyword),
      // Punctuation-like operators stay plain, as highlight.js left them.
      rule(['keyword.operator', 'punctuation'], 0),
      rule(['keyword.operator.new', 'keyword.operator.expression', 'keyword.operator.logical.python', 'keyword.operator.word', 'keyword.operator.wordlike'], KIND.keyword),
      rule(['punctuation.definition.string', 'punctuation.definition.string.begin', 'punctuation.definition.string.end', 'punctuation.section.embedded.begin.string'], KIND.string),
      rule(['entity.name.function', 'support.function', 'meta.function-call.generic', 'entity.name.section', 'markup.heading', 'entity.name.command', 'entity.name.selector', 'meta.selector'], KIND.function),
      rule(['entity.name.type', 'entity.name.class', 'entity.name.struct', 'entity.name.enum', 'entity.name.interface', 'entity.name.namespace', 'entity.name.scope-resolution', 'support.type', 'support.class', 'entity.other.inherited-class', 'storage.type.class.jsdoc', 'storage.type.numeric', 'storage.type.primitive', 'storage.type.built-in', 'storage.type.boolean', 'storage.type.string'], KIND.type),
      rule(['entity.other.attribute-name', 'entity.name.tag', 'support.type.property-name', 'variable.parameter', 'meta.object-literal.key', 'entity.name.label', 'meta.attribute', 'variable.other.member', 'variable.other.object.property', 'markup.underline.link', 'meta.preprocessor', 'punctuation.definition.tag'], KIND.attribute),
    ],
  };

  var injections = {};
  var read = null;
  var registry = null;
  var kindOfColor = [];

  function makeRegistry() {
    registry = new tm.Registry({
      onigLib: Promise.resolve({
        createOnigScanner: function (patterns) { return new onig.OnigScanner(patterns); },
        createOnigString: function (text) { return new onig.OnigString(text); },
      }),
      loadGrammar: function (scope) {
        var json = read(scope);
        return Promise.resolve(json ? JSON.parse(json) : null);
      },
      getInjections: function (scope) { return injections[scope]; },
      theme: theme,
    });
    var colors = registry.getColorMap();
    for (var i = 0; i < colors.length; i++) {
      var match = /^#00000([1-7])$/.exec(colors[i] || '');
      kindOfColor[i] = match ? Number(match[1]) : 0;
    }
  }

  function start(index, wasm, reader) {
    read = reader;
    injections = index.injections || {};
    onig.loadWASM({
      instantiator: function (imports) {
        // Synchronous on purpose. This thread has no run loop for a compile to report back on.
        var instance = new WebAssembly.Instance(new WebAssembly.Module(wasm), imports);
        return Promise.resolve({ instance: instance, module: null });
      },
    }).then(function () { api.engineReady = 1; }, function (e) { api.engineReady = -1; api.engineError = String(e); });
    makeRegistry();
  }

  // A plugin came or went. What's compiled stays with whoever has it, and everything from here on
  // reads what's there now.
  function restartRegistry(next) {
    injections = next || {};
    makeRegistry();
  }

  var docs = new Map();

  function open(id, scope) {
    var doc = { grammar: null, status: 0, states: [tm.INITIAL] };
    docs.set(id, doc);
    registry.loadGrammar(scope).then(function (grammar) {
      doc.grammar = grammar;
      doc.status = grammar ? 1 : -1;
    }, function () { doc.status = -1; });
  }

  var FOREGROUND_MASK = 0x00ff8000;
  var FOREGROUND_OFFSET = 15;
  // A line this long takes the layout seconds anyway. It keeps the state it came in with.
  var LONGEST_LINE = 200000;
  // A regular expression can take a very long time on one line. It stops there, and the line's
  // remainder has no colors. This also pays for compiling a grammar's rules the first time each
  // is reached, so it can't be tight: it's what VS Code uses.
  var LINE_LIMIT_MS = 500;

  var out = new Int32Array(1 << 16);
  function reserve(extra) {
    if (api.resultLength + extra <= out.length) return;
    var bigger = new Int32Array(Math.max(out.length * 2, api.resultLength + extra));
    bigger.set(out.subarray(0, api.resultLength));
    out = bigger;
    api.out = out;
  }

  var lineBreak = /\r\n|\r|\n/;

  /// Writes `count` lines' tokens into `out`, each as a length and then start * 8 + kind.
  /// `peek` starts from nothing and keeps nothing: a guess, for lines far ahead of the real pass.
  function tokenize(id, start, text, count, budget, dirtyUntil, peek) {
    var doc = docs.get(id);
    api.resultLength = 0;
    api.resultLines = 0;
    api.resultConverged = 0;
    if (!doc || !doc.grammar) return;
    var lines = text.split(lineBreak);
    var began = Date.now();
    var state = peek ? tm.INITIAL : doc.states[start];
    if (!state) state = tm.INITIAL;
    var done = 0;
    for (var n = 0; n < count && n < lines.length; n++) {
      var line = lines[n];
      var index = start + n;
      var end = state;
      reserve(2);
      var lengthAt = api.resultLength++;
      var written = 0;
      if (line.length <= LONGEST_LINE) {
        var result = doc.grammar.tokenizeLine2(line, state, LINE_LIMIT_MS);
        end = result.ruleStack;
        var tokens = result.tokens;
        reserve(tokens.length / 2 + 1);
        var previous = -1;
        for (var t = 0; t < tokens.length; t += 2) {
          var kind = kindOfColor[(tokens[t + 1] & FOREGROUND_MASK) >>> FOREGROUND_OFFSET] || 0;
          if (kind === previous || (previous === -1 && kind === 0)) { if (previous === -1) previous = 0; continue; }
          out[api.resultLength++] = tokens[t] * 8 + kind;
          previous = kind;
          written++;
        }
      }
      out[lengthAt] = written;
      done++;
      if (!peek) {
        var known = doc.states[index + 1];
        // Same as before means everything after this is too, once the edit itself is passed.
        if (known && known.equals(end)) {
          end = known;
          if (index >= dirtyUntil) {
            api.resultConverged = 1;
            break;
          }
        } else if (state.equals(end)) {
          end = state;
        }
        doc.states[index + 1] = end;
      }
      state = end;
      if (budget > 0 && Date.now() - began >= budget) break;
    }
    api.resultLines = done;
  }

  function edit(id, line, removed, inserted) {
    var doc = docs.get(id);
    if (!doc) return;
    var states = doc.states;
    if (line + 1 >= states.length) return;
    if (inserted < 64 && removed < 64) {
      var args = [line + 1, removed];
      for (var i = 0; i < inserted; i++) args.push(undefined);
      states.splice.apply(states, args);
    } else {
      var tail = states.slice(line + 1 + removed);
      states.length = line + 1;
      states.length += inserted;
      for (var j = 0; j < tail.length; j++) states.push(tail[j]);
    }
  }

  var api = {
    start: start,
    restartRegistry: restartRegistry,
    open: open,
    status: function (id) { var d = docs.get(id); return d ? d.status : -1; },
    close: function (id) { docs.delete(id); },
    reset: function (id) { var d = docs.get(id); if (d) d.states = [tm.INITIAL]; },
    edit: edit,
    tokenize: tokenize,
    out: out,
    resultLength: 0,
    resultLines: 0,
    resultConverged: 0,
    engineReady: 0,
    engineError: '',
  };
  globalThis.tiri = api;
})();
