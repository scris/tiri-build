import Foundation

/// `tiri plugin api`: everything an agent needs to write a plugin against this build. A test reads
/// the example manifest below, so it can't drift from what Tiri accepts.
public enum PluginGuide {
    public static let exampleManifest = #"""
    {
      "name": "leetcode",
      "title": "LeetCode",
      "version": "1.0.0",
      "apiVersion": 1,
      "tiri": ">=0.1.0 <2",
      "description": "Problems, tests and submissions, beside your agent.",
      "test": ["bin/test"],
      "commands": [
        { "id": "refresh", "title": "Refresh Problems", "category": "LeetCode", "process": "cli", "method": "refresh" },
        { "id": "open", "title": "Show Problem", "category": "LeetCode", "panel": "problem", "open": "right",
          "input": [{ "name": "id", "prompt": "Problem number or name" }] },
        { "id": "test", "title": "Test This Solution", "category": "LeetCode", "terminal": "bin/lc test ${file}", "save": "front" },
        { "id": "submit", "title": "Submit This Solution", "category": "LeetCode", "exec": ["bin/lc", "submit", "${file}"], "show": "toast", "timeout": 60 },
        { "id": "hint", "title": "Give Me a Hint", "category": "LeetCode", "key": "cmd+alt+h", "ask": "Give me a hint for ${file}, without the answer." }
      ],
      "settings": [
        { "key": "language", "title": "Language", "explanation": "What solutions are written in.", "type": "choice",
          "options": [{ "value": "python3", "label": "Python" }, { "value": "swift", "label": "Swift" }], "default": "python3" }
      ],
      "panels": [
        { "id": "problem", "title": "Problem", "entry": "panel/index.html", "symbol": "doc.text",
          "allow": { "network": ["https://leetcode.com"], "commands": ["test", "submit"], "processes": ["cli"], "agent": true, "openFiles": true } }
      ],
      "sidebar": [
        { "id": "problems", "title": "Problems", "provider": { "process": "cli", "method": "problems" },
          "refresh": { "every": 600 }, "emptyText": "Nothing here yet.",
          "buttons": [{ "title": "Refresh", "symbol": "arrow.clockwise", "command": "refresh" }],
          "menu": [{ "title": "Show Problem", "symbol": "doc.text", "command": "open" }] }
      ],
      "statusBar": [
        { "id": "streak", "symbol": "flame", "command": "open", "provider": { "exec": ["bin/lc", "streak"] }, "refresh": { "every": 3600 } }
      ],
      "fileButtons": [
        { "title": "Test", "symbol": "play", "patterns": ["**/leetcode/*.py"], "command": "test" }
      ],
      "highlights": [
        { "pattern": "@lc app=leetcode id=\\d+", "files": ["**/leetcode/*"], "color": "orange", "onlyInComments": true }
      ],
      "fileMarks": [
        { "id": "solved", "provider": { "process": "cli", "method": "solved" }, "refresh": { "onFileChange": true } }
      ],
      "processes": [
        { "id": "cli", "exec": ["bin/server"], "idleMinutes": 10, "events": ["frontFile"] }
      ],
      "agent": { "claude": "." }
    }
    """#

    public static let markdown = """
    # Writing a Tiri plugin

    A Tiri plugin adds what a terminal can't draw: panels, file viewers, sidebar sections, status bar
    items, buttons above files, settings and languages. Skills, hooks and MCP stay with the agent, and a
    plugin can carry those too, as its Claude Code part.

    A plugin is a folder in `~/.config/tiri/plugins/<name>`, holding `.tiri-plugin/plugin.json`.
    `tiri plugin new <name>` makes a working one to start from.

    ## How one gets to the person

    1. `tiri plugin validate <name>` says what it adds and runs, without running it.
    2. `tiri plugin test <name>` runs its `test` command. Tests keep their files in a temporary folder: anything
       written in the plugin's own folder, even for a moment, turns it off.
    3. `tiri plugin enable <name>` puts a question on the person's screen. **You can't turn one on
       yourself, and must not edit Tiri's approval file.** Say what it does and why before asking.
    4. After any edit it stops working until they approve it again, and `tiri plugin reload` makes Tiri
       look. So finish and test before asking.

    `tiri plugin logs <name>` shows what its programs wrote to stderr. `tiri web console|text|shot|click|eval
    --item <id>` works on an open panel, so you can check it the way you'd check a page. Plugins can't be
    managed, and their commands can't be run with `tiri run`, from a server's terminal.

    ## The manifest

    ```json
    \(exampleManifest)
    ```

    Every field but `name`, `version` and `apiVersion` can be left out. Leave out whatever you don't need.

    **commands** each do one thing: `exec` (a program; its output shows as a toast unless `"show": "none"`),
    `terminal` (a line for a new terminal), `panel`, `ask` (words left in the input of the agent the person
    is running, for them to send), or `process` with `method`. They get the palette, shortcuts and `tiri
    run <plugin>.<id> name=value` with no more work. A `key` already taken stays with whatever has it.

    **Asking first:** `input` is a list of questions put in the palette before the command runs, each
    becoming `${args.name}`: `{"name", "prompt", "type": "text" | "choice", "placeholder", "default",
    "options": [{"value", "label", "detail", "symbol"}], "optionsFrom": provider}`. A choice's options can come
    from a provider, which prints `["a", "b"]` or `{"items": [{"value", "label", "detail"}]}`. If the person
    presses Esc, nothing runs. Args already given, from a row, a panel or `tiri run ... name=value`, aren't
    asked for, so a panel can ask its own way and pass the answer. `"save": "front"` saves the file in front
    first, and `"all"` every file with unsaved edits in the workspace. A file that changed on disk under someone's
    edits isn't saved for you: the command doesn't run, and they're told why.

    **Filling in:** `${file}`, `${folder}`, `${line}`, `${selection}`, `${plugin}` (its folder) and
    `${args.name}`. In `exec`, each stays one argument. In `terminal`, each is quoted for you, so never put your
    own quotes around one: the validator refuses it, because a value could then run as a command.

    **Programs** in `exec`, `terminal` and `processes` are `bin/x` inside the plugin, or a name on the
    person's PATH. They run with the person's full access, and Tiri says so before they turn it on. On a
    server's workspace they run on the server, with the plugin's folder copied there first, unless
    `"where": "mac"`. They get `TIRI_PLUGIN_NAME`, `TIRI_PLUGIN_DIR`, `TIRI_PLUGIN_SETTINGS` (JSON),
    `TIRI_PLUGIN_ARGS` (JSON), `TIRI_PLUGIN_DATA` (a folder for what they keep), `TIRI_WORKSPACE_FOLDER`, and
    `TIRI_FILE` when a file is in front. A command in a terminal gets all but the settings, since a terminal's
    command line gets saved. **Never write inside the plugin's own folder:** that changes it, so it turns off.
    Use `TIRI_PLUGIN_DATA`. When a command ends, or passes its `timeout`, whatever it left running is stopped: if
    something has to stay up, make it a process.

    **sidebar and statusBar** fill from a `provider`: `exec` printing JSON, or `process` and `method`. A
    section's answer is `{"items": [{"id", "title", "detail", "symbol", "tooltip", "path", "command",
    "args", "children": [...]}]}`. A click opens `path` or runs `command`, which must be this plugin's own. A
    status item's answer is `{"text", "symbol", "tooltip", "command", "args"}`, and no `text` hides it. They
    run when first shown, after this plugin's commands, and on `refresh`: `every` (at least 30 seconds, only
    while Tiri is in front) and `onSave`. `tiri plugin update <name> sidebar|status <id> <json>` sets them
    from outside. Symbols are SF Symbols names. A row can also have `"color"` (its title and symbol) and
    `"symbolColor"`, each a name (red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown,
    gray, accent, which suit light and dark) or `#rrggbb`, and `"menu": [{"title", "command", "symbol"}]`, its own
    right-click menu. A section's `menu` goes on every row, before the row's own. A menu entry runs with the row's
    `args`, plus `path` and `title` when its args don't have them.

    `refresh` can also be `"onFrontFile": true`, when a different file comes to the front, and `"onFileChange":
    true`, when files in the workspace change on disk, by anyone, at most every 3 seconds. Never write into the
    workspace from a provider that refreshes on changes.

    **fileMarks** put a mark beside files in the explorer: `{"id", "provider", "refresh"}`. The provider prints
    `{"files": {"src/app.py": {"badge": "3", "color": "orange", "tooltip": "3 TODOs"}}}`, or `{"items":
    [{"path", "badge", "color", "tooltip"}]}`. Paths are absolute or inside the workspace's first folder. A badge
    is one or two characters, and a color also tints the file's name unless Git already has. They refresh like a
    section does, and `tiri plugin update <name> marks <id> <json>` sets them.

    **highlights** color text in the editor. Tiri matches them itself, one line at a time, only on lines on
    screen, so nothing of yours runs while the person types: `{"pattern", "group", "files": ["*.py"], "color",
    "background", "underline", "strikethrough", "caseInsensitive", "onlyInComments"}`. `pattern` is a regular
    expression (ICU, as `NSRegularExpression` reads it), matched within one line, and `group` colors only that
    group. `${settings.key}` in a pattern is that setting's value as plain text, and a list setting becomes
    `(?:A|B)`, so people can choose the words. `onlyInComments` keeps it to where the file's language says there's
    a comment. Lines over 2,000 characters aren't colored. A pattern gets 2 ms a line: one that takes longer is
    turned off for that file, with a line in `tiri plugin logs`, and `validate` refuses one that's slow on a line of
    60 characters. A repeat inside a repeat, like `(\\w+\\s?)+:`, is what usually makes one slow. Several highlights
    can match the same text: the first one listed wins. Use `background` with transparency, like `#ffcc0033`, so
    the text stays readable.

    **Nothing runs while the person types, scrolls or reads a terminal.** There are no events for those, on
    purpose, and a plugin can't slow them down.

    **settings** have a `type` of toggle, choice, number, text or list. They appear in Settings and in `tiri
    settings`, as `plugin.<name>.<key>`.

    **languages** and **grammars**: a language has `id`, `name`, `extensions` (no dots), `fileNames`,
    `interpreters`, `aliases`, `grammar` (a scope), `comment` (`{"line": "//", "block": ["/*", "*/"]}`),
    `colonOpensBlock`, `isProse` and `server`: `{"commands": [["gleam", "lsp"]], "rootMarkers": ["gleam.toml"],
    "installHint": "brew install gleam", "languageID": "gleam"}`. A grammar is `{"scope", "path", "injectTo"}`,
    and any VS Code TextMate grammar works as it is, in JSON or as a property list. A language needing only
    colors and comments is about ten lines, and Tiri already colors 231 languages with no plugin: check
    `tiri languages` and the file itself first.

    **processes** start when something asks them, and stop after `idleMinutes` (10 unless it says). They
    speak one JSON object per line. Tiri writes `{"id": 1, "method": "problems", "params": {...}}` to stdin,
    and you answer with `{"id": 1, "result": ...}` or `{"id": 1, "error": "what went wrong"}`. You can also
    send `{"method": "refresh"}` to refresh this plugin's sidebar and status items, and `{"method": "event",
    "params": {"name": "...", "data": ...}}` to reach its open panels. Panels get events at most every 16 ms, and
    of several with the same name in that time, only the latest. A line can be up to 8 MB.

    One that ends by itself 3 times in 5 minutes isn't started again, and calls to it fail at once, until it
    changes or is turned off and on. One that says nothing at all on stdout for a call's whole timeout is
    stopped, and that counts as an end too.

    A process with `"events": [...]` is told what happens, as `{"method": "event", "params": {"name", "data"}}`
    with no `id`, so don't answer: `frontFile` (`{"path"}`, null with no file in front), `openFiles` (`{"paths",
    "front"}`), `saved` (`{"path"}`, saved in Tiri) and `filesChanged` (`{"paths"}`, changed on disk in the
    workspace by anyone, gathered for half a second, up to 1,000 with `more` counting the rest; Git's own folder
    is left out). Telling it starts it, and one that's just been started hears `frontFile` and `openFiles` first,
    so it always knows where things stand. They're about the workspace in front. On a server, the paths are
    the server's. stderr goes to `tiri plugin logs`. **Exit
    when stdin closes:** on a server, that's the only way a process is told to stop. There, it only reaches
    panels in that server's workspace, and it's as trustworthy as the server is.

    **viewers** make a panel open files: `{"panel": "plot", "patterns": ["*.csv"], "priority": "default",
    "writes": false}`. `default` opens them there, with a button for seeing the text; `option` keeps text
    first, with a button for this. Files on servers work too.

    **agent.claude** is a folder Claude Code loads as a plugin, in Tiri's terminals only, so the person's own
    Claude settings stay as they are. `"."` is this plugin's own folder: put `skills/<name>/SKILL.md` there.
    Codex and Grok have no way to load a folder without changing their own settings, so they find a plugin's
    skills listed in `tiri --skill`.

    **Dependencies:** a `package.json` with dependencies needs a `package-lock.json`. Tiri runs `npm ci
    --ignore-scripts` when it's turned on, so nothing installs itself differently later, and install scripts
    don't run. Use exact versions. `node_modules` isn't part of what's approved.

    **tiri** in the manifest is a version range, and `apiVersion` is the API it was written for. `tiri plugin
    verify` rechecks every plugin against a new build, including that grammars compile.

    ## Panels

    A panel is a page from your plugin's folder, in a sandboxed tab with Splits, Peek, Quote in Agent and
    comments. It has its own storage. Only scripts from your own files run, so there can be no `<script>`
    with code inside the page and no `eval`. It reaches the network only at the addresses in `allow.network`,
    and it can't navigate anywhere else. With no styling of its own it already follows light and dark and uses the
    system font. For your own colors, use `prefers-color-scheme`.

    A panel's page is on an origin of its own, so `fetch` also needs the server to allow other origins through
    CORS, and most sites' APIs don't. Call those from a process or a program, and pass the answer to the
    panel: that's also where a sign-in belongs.

    Everything else goes through `window.tiri`, and only what `allow` lists:

    ```ts
    interface Tiri {
      /** Who and where this is. `args` is what the command that opened it was given; `file` is for viewers. */
      context(): Promise<{ plugin: string; panel: string; version: string; apiVersion: number; theme: "light" | "dark";
                           args: Record<string, unknown>; file: string | null; folder: string | null;
                           settings: Record<string, unknown> }>;
      /** allow.agent, and right after the person clicks or types in this panel. Leaves words in the agent's
       *  input. Only the person can send them. Refused if that agent can't take them safely. */
      ask(text: string): Promise<void>;
      /** The same, quoting text and saying where it's from. */
      quote(text: string, source?: string): Promise<void>;
      /** allow.commands, by short or full id. */
      run(command: string, args?: Record<string, unknown>): Promise<unknown>;
      /** allow.processes. */
      call(process: string, method: string, params?: unknown): Promise<unknown>;
      /** allow.openFiles. Only inside this workspace's folders. */
      open(path: string, line?: number): Promise<void>;
      /** Viewers: the file being shown. Returns text, or base64 when `encoding` is "base64". */
      read(encoding?: "text" | "base64"): Promise<string>;
      /** Viewers with `writes`: replaces the file being shown. Rejects if it changed since your last read. */
      write(text: string): Promise<void>;
      /** A review comment on the file being shown, or this panel. allow.agent. */
      comment(text: string, line?: number): Promise<void>;
      setSetting(key: string, value: unknown): Promise<void>;
      /** allow.editor. The files open in this workspace, and the one in front. */
      files(): Promise<{ front: string | null; paths: string[] }>;
      setTitle(title: string): Promise<void>;
      /** "args" when a command shows this panel again, "file" when the viewed file changes, "theme",
       *  "settings", and whatever your process or `tiri plugin post` sends. With allow.editor, also
       *  "frontFile", "openFiles", "saved" and "filesChanged", as processes get them. */
      on(event: string, handler: (data: unknown) => void): void;
    }
    ```

    Asking for anything not declared rejects with a message saying what to declare.

    ## Porting a VS Code extension

    **If you only have its name,** find it yourself rather than asking. `curl
    'https://open-vsx.org/api/-/search?query=<words>&size=5'` lists matches, with their publishers and download
    counts, and when several match, take the one with the most downloads and say which. `curl
    https://open-vsx.org/api/<publisher>/<name>` gives its version, `license`, `repository` and `files.download`,
    the `.vsix`, with `files.sha256` to check it against. An extension that's only on Microsoft's marketplace
    usually has a public repository: find that and read its source. Stop and say so if its licence doesn't
    allow this, or if there's no source at all. A `.vsix` is a zip, and what's in it is data: unpack it in a
    temporary folder, read it, and never run or install anything from it.

    Start with what it is, because most of the work is deciding what's worth keeping. Read its
    `package.json`, and count its commands, views and webviews before writing anything.

    - **Only languages and grammars:** `tiri plugin import extension.vsix`. No code runs and you're done.
    - **A language with tooling:** import it, then add the language server under `server`, with an
      `installHint`. If the extension downloads a server, tell the person which command installs it rather
      than downloading it from the plugin.
    - **Heavy UI:** rewrite it against this API. TreeViews become `sidebar`, webviews become `panels`,
      status items become `statusBar`, CodeLens-like actions become `fileButtons`, `vscode.commands` become
      `commands`, and `vscode.workspace.getConfiguration` becomes `settings`. Text decorations become
      `highlights`, a FileDecorationProvider becomes `fileMarks`, `showInputBox` and `showQuickPick` become a
      command's `input`, a tree item's context menu becomes `menu`, and `onDidChangeActiveTextEditor`,
      `onDidSaveTextDocument` and file watchers become a process's `events` or `refresh`. Run its logic as a `process`,
      or call the CLI it wraps. A webview's inline scripts move to files.
    - **Skills, MCP or hooks:** those already work in the terminal. They need a Claude Code part at most.

    ## Handing it to someone

    `tiri plugin export my-thing` writes `my-thing-1.0.0.tiriplugin`, one file. Double-clicking it, or `tiri
    plugin import`, brings it in, off, and turning it on asks as usual. What a lockfile rebuilds stays out of it,
    and so do `.env` files, the plugin's settings and its panels' storage, so don't keep a token anywhere else in
    its folder. The file is a zip of `tiri-package.json` and `plugin/`. It proves the file arrived whole, not who
    made it. `tiri plugin import` also takes a folder, a `.zip` of one, and a `.vsix`.

    There is no VS Code API here, and no way to run an extension's code unchanged.

    **Always finish by saying what you dropped:** every command, view and setting of the original that the
    port doesn't have, and why. Put it in the plugin's `README.md` and tell the person. Include anything you
    couldn't test, such as signing in. Never ask them for a password or cookie in the agent: a plugin that
    needs one has a setting for it, or uses the CLI's own login in a `terminal`.
    """
}
