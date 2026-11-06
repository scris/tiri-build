# The Tiri guide

Everything Tiri does, grouped by what you're trying to do. For a quick overview, see the [README](README.md).

- [Getting started](#getting-started)
- [Working with agents](#working-with-agents)
- [Reviewing their work](#reviewing-their-work)
- [Git](#git)
- [Reading and editing files](#reading-and-editing-files)
- [Code intelligence](#code-intelligence)
- [Notebooks](#notebooks)
- [Web pages](#web-pages)
- [Servers](#servers)
- [Plugins](#plugins)
- [Your Tiri: changing Tiri by asking](#your-tiri-changing-tiri-by-asking)
- [Window, keys and settings](#window-keys-and-settings)
- [Driving Tiri from an agent](#driving-tiri-from-an-agent)
- [Building](#building)

---

## Getting started

### Pick a folder first

Nothing runs until you say where. A new workspace shows the agents your shell can find. Press one, choose its folder, and the agent starts there. If Tiri finds no agents, it links to where you can get them, and they appear when you come back.

In a workspace with several folders, the **+** menu asks which folder a new terminal or agent should use, and ⌃\` uses the folder of whatever you're looking at.

### Turn on hooks

Hooks tell Tiri exactly when an agent is working, waiting for you or done. They also let Tiri resume the right conversation after a relaunch. Without hooks, Tiri guesses from terminal activity, which is less precise.

Each agent in **Settings → Agents** has an **Install** button, and Tiri offers to install the first time it sees an agent run. Your agent can also start the install with `tiri hooks install claude`. Either way, Tiri shows what it will add and waits for your yes. It keeps your other hooks and settings, saves a backup of the file next to it, and can remove its entries later.

Outside Tiri, these hooks do nothing and print nothing, so they're safe to leave on.

- **Codex** asks you to trust its hooks once, in `/hooks`.
- **Grok** asks you to trust each folder before it runs any hooks. By default it also runs the hooks in your Claude Code settings, so if those are installed, Grok already reports. Its Install button adds a separate file at `~/.grok/hooks/tiri.json` for when you've turned that off.
- A `claude -p` run never reports, and neither does an agent running inside another agent's terminal.

### Choose your agents

There's one list of agents, in **Settings → Agents** or under **Manage Agents…** in the + menu. Switch off the ones you don't use. If you only use Claude Code, only Claude Code appears in the + menu, on the start screen, in the Ask buttons and in the command palette. Turning an agent off only stops Tiri offering it, so sessions already running carry on. Agents can do the same with `tiri agents off codex`.

Press **Add an Agent** to add any other command. You can hand it lines, files, review comments and problems as plain text. Without more setup, Tiri can't track its status exactly or resume a conversation by ID, though you can give it a resume command.

To support a new agent fully, add one entry to `AgentCatalog` in `Sources/TiriCore/Agents.swift`. That entry says how to recognize the agent, write a mention, resume it, install hooks and read their payloads. Everything else reads from it.

---

## Working with agents

### See what they're doing

The **Agents** section of the sidebar lists every running agent in every workspace. Each row shows what you last asked, what the agent just did and how many files it has changed. Click a row to go there. Status also shows on the tab and the workspace switcher, and you get a notification when an agent needs you and you aren't looking at its terminal. ⌘⇧U jumps to the next terminal that needs your attention. `tiri activity` prints the same list.

### Terminals outlive Tiri

If you quit Tiri, update it or it crashes, your agents keep working. When Tiri comes back, each terminal reattaches and its screen is redrawn. Closing a terminal's tab is what ends it. Restarting your Mac still ends terminals, and then agents resume their conversations. You can turn this off in **Settings → Agents**.

### Give agents lines, files and images

**Selections.** Select something in a file, diff, rendered markdown, HTML file, web page or PDF. A **Quote in Agent** button appears beside it, and ⌘L or right-click do the same. With one agent running, the selection goes straight to it. With several, Tiri asks which one should get it, with the one you used last at the top, and then takes you there.

What the agent receives depends on the agent and the source:

- **Claude Code** gets a real mention, because Tiri speaks its editor protocol. Its status line shows your selection, as it does in VS Code. Run `/ide` in Claude if it isn't connected.
- **Codex and Grok** get the path and line range typed in the format each one reads.
- **From a diff**, every agent gets the change itself, with its + and − marks, because a removed line isn't in the file anymore.
- **From rendered markdown**, the selection becomes the source lines, so Claude gets `@report.md#L12-20` instead of a copy of the words.
- **From HTML, web pages and PDFs**, which have no lines, the text goes in as a quotation, with the page number from a PDF.
- **From Office files**, which show through Quick Look and don't expose a selection, ⌘L adds the whole file.

**Files and images.** Use whichever is closest:

- ⌘V pastes a picture from the clipboard, or a file you copied in Finder.
- Drag from the explorer or Finder onto the terminal.
- ⇧⌘L, or the paperclip in the toolbar, opens a picker.
- Right-click in the explorer or Changes and choose **Add to Agent**.

In a plain shell, these insert shell-quoted paths instead.

### Past conversations

The clock in the toolbar lists your Claude Code, Codex and Grok conversations, with this workspace's first. ⇧⌘H, **Past Conversations…** in the + menu and the clock in the Agents section open the same list.

- **Click or press Return** to go back into a conversation: in a new terminal in its folder, or in the terminal where it's already running.
- **Read**, or ⌘↩, shows the conversation as a document, with one line for each thing said or done. Tiri also shows this if the conversation can't be resumed because its folder is gone.
- **Hand To** asks another agent to read the conversation and carry on.

Each conversation has a short title, with your first prompt beneath it. Your Mac's own model writes titles as they scroll into view and keeps them. To title everything in advance, turn on **Title every conversation in advance** in **Settings → Agents**. That only runs while your Mac is plugged in. Without Apple Intelligence, and on servers, titles come from your first prompt. Titles are good guesses, so check before relying on one.

**Search** by describing what you remember. Results appear as you type, each with the text around the match.

- Search covers what you and your agents wrote and did, but not tool output, which is most of each file and would match nearly everything. Tiri keeps a private index: 7 GB of conversations became an index under 60 MB, built in a minute or two and then updated incrementally.
- With Apple Intelligence on, your Mac's model suggests other words for what you described, in English even if you searched in Chinese. Nothing leaves your Mac. Turn it off with **Titles and search with Apple Intelligence** in Settings. If your Mac can't use it, Settings says why.
- **Ask Claude Code to find it**, at the end of the list, has your agent try other searches. This one uses your agent's tokens.
- On a server, Tiri searches that server's files directly, without an index, so results are slower and have no excerpt.

Tiri only reads the agents' own files, and what it writes for reading stays private to you. Agents can use `tiri conversations [words]`, `read`, `open`, `reopen` and `hand`.

---

## Reviewing their work

### Leave review comments, then send them together

Reading a change usually raises several remarks. Sending each one as you go interrupts both you and the agent, so Tiri collects them.

1. Select lines in a file or diff and press **Comment**, or ⌥⌘L, or right-click. With nothing selected, the comment goes on the cursor's line. Rendered markdown, web pages and PDFs work too.
2. Write your remark. Return adds it, and ⇧Return starts a new line.
3. A mark appears beside the line. Click it to edit or delete the comment.

Comments collect in the **Review** section of the sidebar, across as many files as you like, and survive a relaunch. If an agent moves the lines, the comment follows them. If it rewrites them, the comment says so when it's sent.

Press the paper plane, or ⌥⇧⌘L, to put every comment into one agent's input as one message, each beside the code it's about. Nothing is sent until you press Return in that session, so you can add to it first. Agents can use the same list with `tiri review`.

### Undo or ask about a single change

Hover over a change in a diff and press **Undo** or **Ask**, or right-click for those and **Undo All Changes in This File**. The request goes to the agent that made the change, typed into its input with the change quoted, ready for you to send. If Tiri can't tell which agent made it, it asks you.

### Branches and worktrees agents made

Agents make branches and worktrees for themselves, and Tiri finds them. A line under **Changes** tells you when this repository has unmerged branches, and **Other Work** in its menu lists them in plain terms, like `3 files changed · 2 commits, not merged`, along with the agent working there, if any. Choose one to read what it changed. **Ask Agent to Merge** and **Ask Agent to Clean Up** hand the rest over, to the agent in that worktree if there is one.

`tiri work` lists the same for agents, and `tiri worktree <branch>` makes a second checkout as its own workspace.

---

## Git

### Changes

When a workspace folder is in a Git repository, the sidebar's **Changes** section lists every file changed since the last commit, updating live as agents work. Tiri uses whatever Git you have: Apple's, Homebrew's, MacPorts', Nix's, GitHub Desktop's, or the one on your shell's PATH. With none at all, Changes offers **Install** for Apple's free Command Line Tools. Tiri never brings up Apple's installer unless you press it. Click a file to see its diff as a tab, or double-click to keep the tab. A changed file has a **Changes** button above it, and a diff has **Open File** to go back. Agents can show you a diff too: `tiri diff src/app.ts` floats it over the terminal.

The menu in the section's header narrows or widens what you see:

- **Latest Turn** or a particular prompt shows what one agent turn changed. Tiri snapshots the files when an agent takes your prompt and again when it stops. Snapshots stay in Tiri's own folder for a week, and nothing in your repository changes: no branch, stash, staged change or new object. If two agents work in one repository at once, a turn can include the other's edits, and Tiri says so. Codex only reports when it stops, so its turns show from the second one on.
- **This Branch** shows everything since the branch left its base, uncommitted work included. It compares with origin's default branch, or else `main` or `master`, and says which.
- **Recent Commits** lists the last 30 commits. Choose one to see its files. A merge shows what it brought in compared with its first parent.

Diffs from any of these are ordinary items, and they come back after a relaunch.

### Reading diffs

- A button switches to side by side, kept in Settings as `diff.sideBySide`. In a narrow pane or Peek, diffs stay in one column.
- Changes within a line are highlighted, and images show before and after.
- F7 and ⇧F7 step through changes in a diff or a file.
- Thin bars beside a file's line numbers mark differences from the last commit: green for added, blue for changed and a red wedge for deleted lines. Click one to float that change. Very large files and files outside the workspace's repositories don't get these bars.
- The explorer tints changed files with M, U and the other letters, and puts a dot on any folder with changes inside.

### The branch bar

The bar along the bottom of the window shows each repository's branch, a `*` for uncommitted changes, and how many commits there are to pull and push, like `feat/login* 2↓ 3↑`. The counts follow commits and pushes you make in terminals.

- The arrows button fetches. Tiri never fetches by itself, so `0↓` means nothing was new at the last fetch.
- `2↓` pulls, and only ever moves your branch forward. If the branch and the remote have both moved on, or your uncommitted changes touch the same files, Tiri says so and changes nothing.
- `3↑` pushes, after asking which branch goes where. A branch that's never been pushed offers **Publish** instead.

These are in the command palette too. If a remote needs a password, Tiri offers a terminal in that repository. If fetch, pull or push can't do the simple thing, Tiri offers to ask your agent. Merging, committing and switching branches are for you or your agent.

For agents: `tiri git`, `tiri turns`, `tiri changes [--turn latest | --branch | --commit HEAD~1]`, `tiri diff <file> [--turn latest | --branch | --commit HEAD~1]` and `tiri log`.

---

## Reading and editing files

### The Peek

When you ⌘-click a file in an agent's output, it floats as a **Peek** over the session instead of opening a new tab. Your layout stays as it was, and the terminal stays visible.

- ⌘-click the next path to replace it, so you can step through a list of files.
- **Open as Tab** (⌘↩) keeps it. **Open to the Side** (⌥⌘↩) puts it in a split.
- Esc, or clicking outside, closes it and returns you to the terminal without the keypress reaching the agent. The next Esc goes to the agent.
- ⌘⇧-click skips the Peek and opens a tab.

When an agent runs `tiri open report.md`, the file floats the same way and your keyboard stays in the session. Settings can change what ⌘-click does.

### Paths in terminal output

Holding ⌘ underlines every path in terminal output that exists or can be found. ⌘-clicking a file opens it, including `path:line:col` and the other formats compilers and test runners print. ⌘-clicking a folder reveals it in the explorer.

Agents often print paths that don't exist as written, like `/resume/index.html` from a web root. Tiri searches the workspace's folders, its terminals' folders and its open files. One match opens right away. Several let you pick, with the likeliest first.

### Quick edits

Type in any text or code file, and ⌘S saves. A dot on the tab means unsaved changes, and Tiri asks before closing or quitting over them. If an agent changes a file while you're editing it, your text stays on screen and Tiri tells you, so nothing is overwritten without your choice. Editing a Peek turns it into a tab.

A file that isn't UTF-8, like Latin-1, Windows 1252, GB 18030, Big 5 or Shift JIS, opens the way it was written, and saves the same way. Its encoding shows above it. Click that, or choose **Reopen with Encoding…**, to read it another way or **Save as UTF-8**.

The keys are VS Code's:

| | |
|---|---|
| Comment | ⌘/ |
| Indent / outdent | ⌘] / ⌘[, or Tab / ⇧Tab |
| Move lines / copy lines | ⌥↑ ⌥↓ / ⇧⌥↑ ⇧⌥↓ |
| Delete lines | ⇧⌘K |
| New line below / above | ⌘↩ / ⇧⌘↩ |
| Go to line | ⌃G |
| Add next occurrence as a cursor | ⌘D (Esc returns to one) |
| Replace | ⌥⌘F |
| Toggle word wrap | ⌥Z |

`editor.wordWrap` sets what files start with: `off`, `on` or `bounded`, which wraps at `editor.wordWrapColumn`. This is for quick fixes. Tiri isn't a full editor, with no snippets and no AI ghost text.

### Finding things

- **⌘P** quick open. Spaces mean "all of these words", `file:12` goes to a line, and `:`, `@` and `#` work like ⌃G, ⌘⇧O and ⌘T. `>` runs commands.
- **⌘⇧O** lists the symbols in this file, from its language server or by reading its lines, and previews each as you arrow through. Esc puts you back.
- **⌘T** searches symbols across the workspace, when a language server can answer.
- **⌘⇧F** searches file contents and skips what `.gitignore` does. Results appear as you type, and lowercase ignores case. Return floats the file at that line, and ⌘↩ keeps it as a tab.
- **⌘F** finds in the current item. In a terminal, it marks every match on screen, and Return goes further back through the output.

### Viewers

- **Markdown** renders with `$…$`, `$$…$$`, `\( \)`, `\[ \]` math and Mermaid diagrams, using libraries bundled with the app. A diagram that can't be drawn shows its source.
- **Notebooks** render with highlighted code, execution counts, text, errors, tables and images. HTML outputs can't run scripts or restyle the page, and very large outputs are cut short with a note saying so.
- **LaTeX:** a `.tex` file with a PDF of the same name beside it or in a build folder gets a PDF button. The PDF keeps your page and zoom when an agent recompiles.
- **CSV and TSV** files with millions of rows open quickly, with numbers lined up and a sticky header.
- **PDF, Office, iWork, RTF, fonts, images, audio and video** open in place.

### Dark mode

Choose Dark in Settings, or leave it on System while your Mac is dark, and everything follows live: the app, terminals, code, markdown, web pages and media.

PDF, Office, iWork, RTF, font and web archive previews have no dark mode, so Tiri shows their pages inverted with colors kept. The moon button above a file shows its true colors, and Tiri remembers that for the item. To keep all documents in true colors, turn off **Darken documents** in Settings. Black artwork on a transparent PNG or SVG gets a light plate behind it.

### Themes

A theme colors terminals, the editor and highlights (selections, switches, tabs). Like VS Code, dark mode and light mode each keep their own, and so does Increase Contrast. **Settings → General** shows the one for the look you're in; switch your Mac to dark to choose the dark one. Tiri has its own: **System Dark** and **System Light** highlight in your Mac's accent color, **Tiri Pink Dark** and **Tiri Pink Light** always in Tiri's pink.

**Bring a Theme…** lists the themes Cursor, VS Code and Ghostty already have on your Mac, so most are one click, or takes a Ghostty theme, an iTerm2 `.itermcolors` file or a VS Code theme `.json`. A terminal theme gives the editor its colors from its palette, and an editor theme without terminal colors gets Tiri's. **Make One…** takes a few words, like "a foggy harbor at dawn", and your agent makes the theme with `tiri theme`, on screen as it goes. **Colors** shows every color of the theme showing now to change. Changing a built-in one makes your own copy.

```sh
tiri theme list --available
tiri theme import "Solarized Light" --use
tiri theme set terminal.background '#101014' editor.comment '#9a9aa2'
tiri theme set accent purple
tiri theme new "Harbor" --for dark       # your own, starting as a copy, then set its colors
tiri theme rename "Harbor" "Harbor Night"
```

Themes are JSON files in `~/.config/tiri/themes`.

---

## Code intelligence

### Colors

Every code view uses the same TextMate grammars: the editor, diffs, markdown and notebooks. Tiri bundles 231 languages and runs them locally. A file with no extension is colored by its `#!` line. Coloring runs off the main thread, visible lines first, and typing usually recolors one line, so there's no file size limit.

A few grammars aren't included because of their licences: Ada, Gnuplot, nginx, Org, Racket and AutoHotkey 2 (GPL or LGPL), and APL, DAX, DreamMaker, GLSL and Tcl (no licence stated). `Resources/grammars/NOTICE.txt` has the rest.

### Language servers

Tiri uses language servers you already have, wherever your shell or the project keeps them. That covers TypeScript and JavaScript, Python, Rust, Go, Swift, C and its relatives, shell, YAML, JSON, HTML, CSS, Ruby, Lua, Java, Kotlin, C#, PHP and more. Servers you set up through Claude Code's language plugins work too.

The first time you open a language without a server, Tiri asks once whether to add one, and nothing downloads until you agree. **Add** installs the server into Tiri's own folder, at exact versions and hashes that ship with the app, using `uv`, `npm --ignore-scripts` or `go`. Nothing outside that folder changes. For Python, that's basedpyright, about 283 MB, with no Node needed. Agents can use `tiri languages` and `tiri languages add <id>`. On a server, your agent does the installing.

What you get:

- **Definitions.** ⌘-click a name or press F12. Holding ⌘ underlines what you can follow. The definition floats as a Peek, and **Back** (⌃-) retraces your jumps. ⇧F12 finds every use.
- **Hover.** Hold ⌘ over a name, or press ⌘K ⌘I.
- **Problems.** Errors and warnings are underlined, with a dot beside the line and a count in the bottom bar. A diff shows only the errors on the lines it added, with **Quote in Agent** to hand them over. Claude Code gets problems through its editor protocol, so it can see what its own edit broke. Any agent can run `tiri diagnostics` to check the files changed since the last commit.
- **Completion.** A list appears while you type a name or after `.`. ⌃Space or ⌥Esc asks at any time, even in comments and strings. "cra" finds `createApplication`, recent and nearby names come first, and any import the name needs comes with it. `editor.completion` turns off the automatic list.

Without a server, Tiri still helps. Definitions come from searching the workspace: one match opens, several let you choose. This is a good guess rather than a compiler's answer. Completion offers words from this file and your other open files.

A server starts after you've looked at one of its files for a moment, and stops after 10 idle minutes. Servers can use a lot of memory, and some run a project's build scripts as they read it. If a server lives inside the project, like one in `node_modules/.bin`, it's that project's code, so Tiri asks once before running it. You can turn all of this off in **Settings → Languages**.

---

## Notebooks

Press **Run All** above a notebook, or hover over a cell and press ▶. Output appears as it comes. Click a cell and press ⇧↩ to run it and move to the next. Double-click a cell, or press Return, to edit it: ⇧↩ runs it, Esc puts it back, and it saves as you type. The menu beside **Run All** restarts the kernel, clears outputs, adds and deletes cells, and chooses the Python.

- **It uses your Python, with nothing bundled.** Tiri tries the project's `.venv`, then what a terminal there would get, then conda and pyenv, and uses the first one that has `ipykernel`. If none has it, Tiri offers to ask your agent to install it. A kernel gets the same environment as a terminal, API keys included.
- **Runs outlive the window.** A long cell keeps running if you quit Tiri, close the lid or lose the connection, and every result goes straight into the `.ipynb`. Closing the tab stops the kernel, and Tiri asks first if a cell is running.
- **On a server, cells run on the server**, with that server's Python.
- **Input requests appear in the cell.** A cell asking for `input()` asks right there, and **Stop** still works. If you're elsewhere, a toast tells you.
- **Agents can run notebooks:** `tiri notebook run report.ipynb [--cell N]`, plus `status`, `interrupt`, `restart`, `stop` and `input report.ipynb "text"`. If an agent changes a cell while you're typing in it, your edit isn't saved and Tiri says so.

Widgets that need scripts in the page, like `ipywidgets`, show a picture or text if they have one.

---

## Web pages

Agents working on a page can read it themselves, so you don't have to copy anything across:

| `tiri web …` | |
|---|---|
| `console` | What the page logged, and its errors |
| `network` | What it fetched and how that went |
| `shot` | Saves a screenshot and says where |
| `text` | What the page says |
| `click`, `type` | Use the page |
| `eval` | Runs anything in the page |

Add `--errors` or `--failed` to see only what's wrong, and `--item` when several pages are open. On a server, screenshots are saved on that server.

Beside the address bar:

- **An error count** appears when the page has errors. Click it to quote them in your agent.
- **◎** lets you point at something on the page. Click an element, and your agent gets its location and HTML. Esc cancels. Scripts on the page can't detect that you're picking.
- **↗** moves the page to your own browser, where you're signed in; for a file, it opens your editor. Hold it, or right-click it, for the rest: your editor, **Show in Finder**, and **Always Open github.com in Chrome**, or whichever site and browser it is. From then on, links to that site go straight there, whether from a terminal, a page, a document or an agent's `tiri preview`. A note says where each one went, with **Open Here** for the times you want it in Tiri. **Settings → General** lists these sites.

---

## Servers

Press **Connect to Server…** in the workspaces' + menu or the command palette, or run `tiri remote connect <host> [folder]`. Pick a host from your `~/.ssh/config` or type `user@host`, then pick a folder. It becomes a workspace like any other, starting with a terminal there.

Everything works as it does locally: the tree, quick open, ⌘-click, the Peek, Changes, search, language servers, review comments and agents, which run on the server. `tiri open report.md` in a terminal there floats a Peek on your Mac.

- **Agents keep working when your lid closes.** Programs run under a small helper on the server. When the connection or Tiri comes back, each terminal reattaches with nothing lost. Saves made while you're disconnected wait, then go through.
- **There's almost nothing to install.** Tiri puts one static program of about 90 KB in `~/.tiri` on the server. It runs on Linux (x86-64 or ARM) and macOS, and needs no root, compiler or Node. Other systems still get terminals and files, but programs won't survive a dropped connection.
- **OpenSSH does the connecting**, so your keys, agent, jump hosts and config just work. If SSH asks for a passphrase, password, one-time code or host confirmation, Tiri shows the prompt and keeps none of the answers.
- **Files come over when you open them.** The tree is real, but a large project costs nothing until you read it: the Linux kernel's 97,000 files appear in about ten seconds. What you've read is cached under `~/Library/Caches/Tiri`, and the cache is deleted with the workspace.
- **Ports forward by themselves.** ⌘-click `http://localhost:3000` in a terminal on the server, or run `tiri preview http://localhost:3000` there, and the page opens on your Mac. Forward other ports from the server's name in the bottom bar, or with `tiri remote forward <port>`.
- **Pasted and dropped files go to the server first**, so an agent there can read them.
- **Delayed saves don't overwrite newer work.** If an agent changed the same file in the meantime, Tiri asks which version to keep. A connection that drops mid-save leaves the file as it was.
- **Your SSH agent keeps working** in terminals that outlive their connection, if your config forwards it.

A server is trusted less than your Mac. `tiri` on a server only reaches that server's own workspaces and files. It can't see or type into terminals on your Mac, read your Mac's files, change settings or hooks, or quit the app. Each server has its own token for the editor protocol and only hears about its own files.

If a server forbids SSH forwarding, `tiri`, the Peek and agent status still work, Tiri tells you when it can't forward a port, and Claude Code gets selected lines as text instead of through the editor protocol. `tiri remote` lists servers, and `tiri remote ports` lists what's forwarded.

---

## Plugins

A plugin adds what a terminal can't draw: panels, file viewers, sidebar sections, status bar items, buttons above files, colors on text in the editor, marks beside files in the explorer, settings, commands and languages. A plugin's command can ask you for a word or a choice in the palette before it runs, and its sidebar rows can have colors and a right-click menu. Skills, hooks and MCP servers stay with your agent, though a plugin can carry a Claude Code part that loads only in Tiri's terminals.

**You don't write plugins by hand.** Describe what you want and your agent writes and tests it. You see what it adds and runs before turning it on. Type your idea into **New plugin** under **Settings → Plugins**, or run **New Plugin…** from the palette or the Plugins menu. For example: "show my pull requests in the sidebar", "open .csv files as a chart" or "port the VS Code extension Todo Tree". A file in a language Tiri doesn't know gets a button in the bottom bar that asks your agent to add it.

To bring over a **VS Code extension**, give your agent its name. The agent finds the extension, rewrites it for Tiri, and tells you what it dropped. Tiri doesn't run extensions as they are. Importing a `.vsix` directly runs none of its code: it brings in its languages and grammars and lists everything else.

To **share** a plugin, choose **Export** in its menu in Settings, or run `tiri plugin export`. The other person double-clicks the `.tiriplugin` file, sees what it adds and runs, and turns it on. Settings and `.env` files stay behind.

```sh
tiri plugin new my-thing        # a working start
tiri plugin validate my-thing   # what it adds and runs, without running it
tiri plugin test my-thing       # its own tests
tiri plugin enable my-thing     # asks you, on screen
tiri plugin reload              # rereads the folder, no restart
tiri plugin verify [--tests]    # checks every plugin against this build
tiri plugin export my-thing     # my-thing-1.0.0.tiriplugin
tiri plugin import a.tiriplugin # or a .zip, a folder or a .vsix; it arrives off
tiri run my-thing.hello a=b     # run a plugin's command
```

A plugin's commands also reach the palette, the Plugins menu and keyboard shortcuts.

### Safety rules

- **Only you can turn a plugin on.** An agent can ask, and the question names everything the plugin adds and runs. Return doesn't press Turn On, because the question can appear while you're typing to an agent.
- **Any change turns a plugin off** until you approve it again, with the changes listed. Tiri records a hash of the plugin's files and checks it again right before anything runs. Packages npm rebuilds from an exact lockfile in `node_modules` aren't part of the hash, and install scripts never run.
- **Panels are sandboxed.** Each plugin has its own storage. A panel only loads files and scripts from its own folder, only reaches the addresses it declared and can't navigate away. It reaches the rest of Tiri through a bridge that allows only what it declared.
- **A panel can't make your agent act.** Right after you click or type in a panel, it can leave words in the agent's input, but you're the one who presses Return. Tiri refuses even that while the agent is waiting for an answer, or when the running program doesn't treat pastes as pastes.
- **Programs run with your full access.** Anything a plugin runs can do what you can, including reading your files, and Tiri says so before you turn it on. A finished or timed-out command is stopped, along with anything it left running.
- **Nothing loads by itself.** Plugins in a cloned repository are ignored. A terminal on a server can't manage plugins, run their commands or drive their panels. In a server workspace, a plugin's programs run on the server from a copy in `~/.tiri/plugins`, unless the plugin says `"where": "mac"`.
- **Plugins can't slow you down.** Nothing hooks into typing, scrolling or terminal output. A plugin's colors on text are patterns Tiri matches itself, only on the lines on screen, so none of its programs run while you type. An unused plugin costs one directory walk at launch: panels open on demand, sections load when unfolded and background processes stop after 10 idle minutes.
- **Turning a plugin off removes all of it:** commands, keys, languages, sections, items, panels, processes and servers. Its settings stay until you remove the plugin. A panel that can see which files you have open says so before you turn it on.

**What these rules don't stop:** approvals are stored in a file in Tiri's own folder, and any program running as you could edit it. The rules stop an agent that's been tricked into asking, not malware already running with your access, which could just as easily edit your shell's startup files. A panel can probably still leak a little data through DNS lookups, which a content policy doesn't cover. And a plugin's process on a server is only as trustworthy as that server.

---

## Your Tiri: changing Tiri by asking

Tiri can be changed the way it was made: by asking.

1. **Ask.** Choose **Change Tiri…** from the Tiri menu, the command palette or the start screen. You can also ask when a palette or settings search finds nothing, or just tell any agent in a Tiri terminal. Drag a box around the part of the screen you mean, so your agent can see it.
2. **Watch.** Your agent starts in its own tab, in a workspace called **Your Tiri** that holds the exact source of the version you're running. You can follow along in Tiri's own file tree and Changes. The first time, Claude Code asks whether it may work in that folder, with "No, exit" chosen; press **Trust Tiri's Code** on the tab to answer yes.
3. **Try it.** When the agent is done, a card on its tab says what changed and how big the change is. Press **Try It**. Tiri closes and reopens in about half a second with everything still running, including the agent that made the change, now inside what it made.
4. **Keep it or go back.** For ten minutes, the card offers **Keep** and **Back**. Back takes one click and loses nothing.

**Change Tiri…** lists your changes in your own words, each with a switch, and **Plain Tiri**, the app you installed. Settings has the same list, with what each change touched. Anything waiting for you, like a change to try or an update, stays in the bottom bar. Hold ⌥ while opening Tiri to start the plain app for one run. If a change stops Tiri from starting, Tiri goes back to the previous copy by itself and tells you.

**Updates keep your changes.** Each change is a commit on top of a release. An update replays your changes onto the next release in the background: first with Git, then with a merge that understands Swift, then a build, then each change's own check. Only after all of that does **Update** appear. If a change can't be replayed, it goes to your agent to fix, if you've agreed to that once. A change the agent can't fix is kept, named and left out of that update. If Tiri itself learns to do what your change did, your change retires itself and tells you.

**Cost.** The first change needs about 1 GB of build files, in `~/Library/Application Support/Tiri/your-tiri`, and the Command Line Tools, which anyone running an agent already has. If you never use this, nothing runs and nothing extra is on disk beyond the app's own source, about 5 MB. Turning off **Offer to change Tiri** in Settings removes every entry point.

**Limits:**

- An agent can build a copy of Tiri but can't switch to it. Switching takes your click, and there's no command for it. This is a line for agents, not a wall against malware, which could write Tiri's files like any others.
- Your personal copy is signed on your Mac with its own certificate, in its own keychain file, and has its own bundle ID. macOS asks once about your folders for it, never again after rebuilds, and your answers for the installed app stay as they were.
- Nothing loads from anywhere else. There's no gallery and no way in from a link.
- An update has to be a newer release of this app, from whoever made yours, according to Apple's signing chain. It's checked before it goes anywhere and again when you press Update. A feed must use https, and its release notes never reach your agent.
- A change's check is a script that runs at every update with your access, so it counts toward the change's size and is shown with its diff.

For agents, `tiri --skill` has the commands, and [CHANGING.md](CHANGING.md) has the rest.

---

## Window, keys and settings

### Layout

Terminals, files and pages are all tabs. Drag tabs to reorder them, move them between groups or drop them on the edge of a pane to split it. Right-click a tab and choose **Move to New Window** to put it on another display. The tab stays behind and says where it went, and closing the window brings the item back.

**File → New Window** (⇧⌘N), or **Open in New Window** on a workspace in the sidebar, gives a workspace a window of its own, with its own sidebar, Changes and terminals. Whatever you do acts on the window in front. A workspace is in one window at a time, so choosing one that's open elsewhere brings its window forward, marked in the switcher with a small window. Closing a window leaves its workspace running in the switcher, and windows come back after a relaunch. Agents use `tiri window new [<workspace>]`, `tiri window list`, `focus` and `close`.

The sidebar's sections (Explorer, Changes, Agents, Review, Open Items) each fold when you click their names. Tiri remembers which are folded, and the open sections take the room.

In the explorer, a single click previews a file and a double-click keeps it open. Enter renames, Space previews, ⌘↓ opens and ⌘⌫ moves to the Trash. Drag a file into a terminal to insert its shell-quoted path.

The bar along the bottom shows each repository's branch and what the language server says about the file in front. When there's nothing to show, it disappears.

### Shortcuts

Shortcuts follow Cursor. You can change any of them in Settings, or by asking your agent.

| Action | Shortcut |
|---|---|
| Quick open (`:12` for a line, `>` for commands) | ⌘P |
| Command palette | ⌘⇧P |
| Toggle sidebar | ⌘B |
| Focus explorer | ⌘⇧E |
| New terminal | ⌃\` |
| Split right / down | ⌘\\ / ⌘K ⌘\\ |
| Close item / reopen last closed | ⌘W / ⌘⇧T |
| Next / previous tab | ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[ |
| Focus group 1…9 | ⌘1…⌘9 |
| Switch workspace 1…9 | ⌃1…⌃9 |
| New window | ⇧⌘N |
| Next terminal needing attention | ⌘⇧U |
| Past conversations | ⇧⌘H |
| Quote in agent / add files | ⌘L / ⇧⌘L |
| Add review comment / send all | ⌥⌘L / ⌥⇧⌘L |
| Find in the current item | ⌘F |
| Search in files | ⌘⇧F |
| Go to definition / references / back | F12 / ⇧F12 / ⌃- |
| Text size | ⌘+ / ⌘- / ⌘0 |
| Settings | ⌘, |

In a terminal, ⌘K clears, ⌘← and ⌘→ go to the ends of the line, and ⌘⌫ deletes back to the line's start. Text size applies to terminals and files, and web pages scale to match.

### Settings

You never edit a settings file directly. There are two ways in:

- **The Settings tab.** ⌘, opens Settings as a tab, with panes for General, Agents, Terminal, Editor, Languages, Plugins, Your Tiri, Files and Keyboard. ⌘F searches every pane at once, and you can change what you find in place. Changes apply immediately. A changed setting has an arrow beside it that resets it.
- **Your agent.** **Ask Claude Code**, under the list of panes, hands your agent a prompt. The arrow beside it offers your other agents or copies the prompt. Your agent can explain any setting and change it for you.

```sh
tiri settings explain              # every setting, its value and what it does
tiri settings set code.wordWrap on
tiri settings open terminal.fontSize
```

**Keyboard shortcuts** are grouped by purpose, with a list to jump between groups. Click a shortcut and press new keys, or point at a command without one and click **Add Shortcut**. If another command already uses the key, Tiri asks before taking it. **Find by Key** tells you what a key does or that it's free, and **Changed** shows only what you've changed. Agents use `tiri keys`.

---

## Driving Tiri from an agent

```sh
tiri open report.md                  # float it over the session
tiri open report.md --split right    # or keep it beside the session
tiri preview http://localhost:3000 --split right
tiri term --cwd ~/project --cmd "npm run dev" --split down
tiri workspace new api --folder ~/api --folder ~/shared
tiri workspace import team.code-workspace
tiri items
tiri notify needs-input --message "Which database?"
tiri review add src/app.ts:12-20 "This doesn't handle an empty list"
tiri review send --to <item-id>
tiri theme dark
tiri theme import Monokai --use
```

`tiri --help` lists every command, and `tiri --skill` prints a guide written for agents. Terminals inside Tiri have `TIRI_SOCKET`, `TIRI_WORKSPACE` and `TIRI_ITEM_ID` set.

### Updates

A downloaded Tiri looks for a newer one every 6 hours while your Mac is plugged in and you're away from it, and offers **Update** in the bottom bar. **Tiri → Check for Updates…** looks right away. Updating keeps your terminals and agents running. A copy you built from source doesn't look; pull and build it instead. Turn off **Look for updates** in **Settings → General** and Tiri never goes online by itself; **Check for Updates…** still looks when you choose it.

### Reporting a problem

**Help → Report a Problem…** opens a new issue on GitHub, filled in with Tiri's version, macOS and Mac, the agents you use, how many of your own changes are on, and where Tiri last crashed in the past week, if it did. Only the crash's error and its top frames go in, not the file's identifiers or paths. Nothing is sent until you send it on GitHub, where you can edit all of it. After a crash, the next launch offers **Report** once. Agents can use `tiri report`, which prints the same issue, and `--open` shows it to you.

`tiri` works in every terminal inside Tiri. To use it in other terminals, go to **Settings → General** and press **Install**. That adds a link at `~/.local/bin/tiri` that keeps working when the app updates. If your shell doesn't look there, Tiri gives you the line to add.

---

## Building

### For yourself

You need macOS 26 or later on Apple silicon, plus the Command Line Tools (`xcode-select --install`) or Xcode 26.

```sh
./build.sh && open build/Tiri.app
```

macOS asks for permission the first time Tiri opens something in Documents, Desktop or Downloads. Terminals inside Tiri count as Tiri, so prompts for the microphone, camera and scripting other apps also show Tiri's name. The default build is ad-hoc signed, so macOS treats each rebuild as a new app and asks again. Sign with your own identity to keep your answers across rebuilds. That also turns on the hardened runtime:

```sh
TIRI_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" ./build.sh
```

### For other people

A notarized build opens on any Mac with a double-click and no warning. It needs a Developer ID certificate from the Apple Developer Program, and notary credentials saved once in your keychain:

```sh
xcrun notarytool store-credentials tiri-notary --apple-id you@example.com --team-id ABCDE12345
scripts/release.sh
```

This leaves three things in `build/release`, next to the stapled `Tiri.app`:

- `Tiri-<version>.dmg`, holding the app and a link to Applications. This is the download.
- `Tiri-<version>.zip`, which updates fetch. It's the same app, so the disk image is the only thing sent to Apple, and both get its ticket stapled on.
- `update.json`, the feed entry for that zip: its version, its address and its SHA-256. It goes at `https://tiri.build/update.json`, which is the feed the release looks at, and the zip goes in `https://tiri.build/download`. `TIRI_UPDATE_FEED` and `TIRI_DOWNLOAD_BASE` choose others.

It checks every program in the bundle before sending anything to Apple, doesn't touch a running Tiri and publishes nothing. `TIRI_RELEASE_IDENTITY` and `TIRI_NOTARY_PROFILE` choose another certificate or set of credentials.

`scripts/publish-release.sh` then puts that release on tiri.build: the DMG for people, and the zip and `update.json` that every copy's updates read. It checks the DMG is notarized first, and asks before it deploys.

`scripts/release.sh` refuses to release in two cases: if the changes in `Tests/personal-changes` no longer apply (`scripts/replay-corpus.sh`), or if Tiri stops building with the Command Line Tools alone (`scripts/check-free-tools.sh`). The second usually means something depends on an Apple macro whose plugin only ships with Xcode. The Swift-aware merge for Your Tiri is Mergiraf with a Swift profile, built by `scripts/build-merge-tool.sh`. It's optional and goes at `your-tiri/tools/mergiraf`.

### Testing

```sh
swift test          # unit tests and an in-process control server test
scripts/e2e.sh      # drives a real app through every CLI command, with isolated state
```

Test copies from `scripts/dev-app.sh` hide themselves, take no clicks, and stop if a window reaches the screen, because Stage Manager brings back any window placed off-screen. Set `TIRI_DEV_MAY_TAKE_FOCUS=yes` to make one visible when nobody is using the Mac.

`scripts/e2e-plugins.sh` drives a test copy through the whole plugin system, including attempts to break out of a panel. `TIRI_BUDGETS=1` checks the speed budgets with 50 plugins, and `scripts/e2e-plugins-remote.sh` does the same for a server workspace.
