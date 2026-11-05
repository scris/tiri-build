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
        { "id": "open", "title": "Show Problem", "category": "LeetCode", "panel": "problem", "open": "right" },
        { "id": "test", "title": "Test This Solution", "category": "LeetCode", "terminal": "bin/lc test ${file}" },
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
          "buttons": [{ "title": "Refresh", "symbol": "arrow.clockwise", "command": "refresh" }] }
      ],
      "statusBar": [
        { "id": "streak", "symbol": "flame", "command": "open", "provider": { "exec": ["bin/lc", "streak"] }, "refresh": { "every": 3600 } }
      ],
      "fileButtons": [
        { "title": "Test", "symbol": "play", "patterns": ["**/leetcode/*.py"], "command": "test" }
      ],
      "processes": [
        { "id": "cli", "exec": ["bin/server"], "idleMinutes": 10 }
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
    from outside. Symbols are SF Symbols names.

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
    "params": {"name": "...", "data": ...}}` to reach its open panels. stderr goes to `tiri plugin logs`. **Exit
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
      setTitle(title: string): Promise<void>;
      /** "args" when a command shows this panel again, "file" when the viewed file changes, "theme",
       *  "settings", and whatever your process or `tiri plugin post` sends. */
      on(event: string, handler: (data: unknown) => void): void;
    }
    ```

    Asking for anything not declared rejects with a message saying what to declare.

    ## Porting a VS Code extension

    Start with what it is, because most of the work is deciding what's worth keeping. Read its
    `package.json`, and count its commands, views and webviews before writing anything.

    - **Only languages and grammars:** `tiri plugin import extension.vsix`. No code runs and you're done.
    - **A language with tooling:** import it, then add the language server under `server`, with an
      `installHint`. If the extension downloads a server, tell the person which command installs it rather
      than downloading it from the plugin.
    - **Heavy UI:** rewrite it against this API. TreeViews become `sidebar`, webviews become `panels`,
      status items become `statusBar`, CodeLens-like actions become `fileButtons`, `vscode.commands` become
      `commands`, and `vscode.workspace.getConfiguration` becomes `settings`. Run its logic as a `process`,
      or call the CLI it wraps. A webview's inline scripts move to files.
    - **Skills, MCP or hooks:** those already work in the terminal. They need a Claude Code part at most.

    There is no VS Code API here, and no way to run an extension's code unchanged.

    **Always finish by saying what you dropped:** every command, view and setting of the original that the
    port doesn't have, and why. Put it in the plugin's `README.md` and tell the person. Include anything you
    couldn't test, such as signing in. Never ask them for a password or cookie in the agent: a plugin that
    needs one has a setting for it, or uses the CLI's own login in a `terminal`.
    """
}
