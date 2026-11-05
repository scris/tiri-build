# Tiri

A neutral, native macOS workspace for people who do their work through CLI agents like Claude Code, Codex and Grok, and use the "IDE" to see, review and organize.

Terminals, files and web previews are equal items in one tab and pane system, on this Mac or a server. Tiri has no chat, account or model of its own, and no bottom terminal panel. Your agents can drive the whole app through a local CLI.

**Don't like something in Tiri? Say so. It stays yours through every update.** Choose Change Tiri…, and say what you want instead. Your own agent changes Tiri's source, on your own subscription, and you try the result with one click. [More below](#your-tiri).

## Build and run

Needs macOS 26 or later, and either Apple's free Command Line Tools (`xcode-select --install`) or Xcode 26.

```sh
./build.sh && open build/Tiri.app
```

This builds `build/Tiri.app` and installs the `tiri` CLI to `~/.local/bin`. It runs on Apple silicon with macOS 26 or newer.

macOS asks for permission the first time Tiri opens something in Documents, Desktop or Downloads, and terminals inside Tiri count as Tiri. So do the microphone, camera, and scripting other apps: an agent asking for one of those shows Tiri's name, and it's your answer either way. An ad-hoc-signed build counts as a new app each time you rebuild, so macOS asks again. To keep your answer across rebuilds, sign with an identity of your own, which also turns on the hardened runtime:

```sh
TIRI_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" ./build.sh
```

### A build for other people

A notarized build opens on any Mac with a double-click, with no warning and no right-click to get past. It needs a Developer ID certificate from the Apple Developer Program, and notary credentials saved once in your keychain:

```sh
xcrun notarytool store-credentials tiri-notary --apple-id you@example.com --team-id ABCDE12345
scripts/release.sh
```

That leaves a stapled `build/release/Tiri.app` and a zip beside it. It checks every program in the bundle before sending anything to Apple, doesn't touch a running Tiri, and publishes nothing. `TIRI_RELEASE_IDENTITY` and `TIRI_NOTARY_PROFILE` choose another certificate or set of credentials.

## Terminals outlive Tiri

Quit Tiri, update it, or have it crash, and your agents keep working. When it comes back, each terminal reattaches and its screen is redrawn. An agent with no conversation to resume starts fresh. Closing a terminal's tab is what ends it. A restart of your Mac still ends them, and then agents resume their conversations as before. You can turn this off in Settings, under Agents.

## Work on a server

Press **Connect to Server…** in the workspaces' + menu or the command palette, or run `tiri remote connect <host> [folder]`. Pick a host from your `~/.ssh/config` or type `user@host`, then pick a folder. It becomes a workspace like any other, starting with a terminal there.

Everything works the same as a local folder: the tree, quick open, ⌘-click, the Peek, Changes, search, go to definition, language servers, review comments. So do agents, which run on the server. `tiri open report.md` in a terminal there floats a Peek on your Mac, and Quote in Agent reaches them too.

- **Your agents keep working when your lid closes.** Programs run under a small helper on the server. When the connection comes back, or Tiri does, each terminal reattaches and nothing it printed is lost. Saves made while it's down wait, and go when it's back. Closing a tab is what ends a program.
- **Nothing to set up, nothing installed but one file.** Tiri puts one small static program in `~/.tiri` on the server, about 90 KB, for Linux on x86-64 or ARM, or a Mac. It needs no root, compiler or Node. Other systems still get terminals and files, without programs surviving a dropped connection.
- **OpenSSH does the connecting**, so your keys, agent, jump hosts and config just work. If it has a question (a passphrase, a password, a one-time code, an unknown host) Tiri shows it, and keeps none of the answers.
- **Files come over when you open them.** The tree is real, and a large project costs nothing until you read it: the Linux kernel's 97,000 files appear in about ten seconds, and take no disk space. What you've read is cached under `~/Library/Caches/Tiri`, and goes when you delete the workspace.
- **Pages on the server open here.** ⌘-click `http://localhost:3000` in a terminal on the server, or run `tiri preview http://localhost:3000` there, and the port is forwarded for you. Forward others from the server's name in the bottom bar, or with `tiri remote forward <port>`.
- **Pictures and files you paste or drop are sent over first**, so an agent there can read them.
- **A save that had to wait won't quietly replace newer work.** If an agent changed the same file meanwhile, Tiri asks which to keep. A connection that drops part-way through a save leaves the file as it was.
- **A server is trusted less than your Mac.** `tiri` in a terminal there only reaches that server's own workspaces and files. It can't see or type into terminals on your Mac, read your Mac's files, change settings or hooks here, or quit the app. Each server has its own token for the editor protocol, and only hears about its own files.
- **Your SSH agent keeps working** in terminals that outlive their connection, if your config forwards it.

If a server forbids SSH forwarding, `tiri`, the Peek and agent status still work, and Tiri says when it can't forward a port. Claude Code then gets lines as text, rather than through the editor protocol.

`tiri remote` lists the servers, and `tiri remote ports` what's forwarded.

## Other work

Agents make branches and worktrees for themselves, and they find you. A line under **Changes** says when there are branches here that aren't merged, and **Other Work** in its menu lists them in plain terms, like `3 files changed · 2 commits, not merged`, with the agent working there if there is one. Choose one to read what it changed. **Ask Agent to Merge** or **Ask Agent to Clean Up** hands the rest over, to the agent in that worktree if there is one. `tiri work` lists the same for agents, and `tiri worktree <branch>` makes a second checkout as a workspace of its own.

Fetch, pull and push are one click in the bottom bar. If one of them can't do the simple thing, Tiri offers to ask your agent. Everything further in Git is your agent's.

## See what your agents are doing

The **Agents** section of the sidebar has every running agent, in every workspace: what you last asked it, what it just did, and how many files it's changed. Click one to go there. It reads what agents report through their hooks, and `tiri activity` prints the same.

## Web pages agents can see

Agents working on a page can read it for themselves, so you don't have to copy anything across. `tiri web console` has what it logged and its errors, `network` what it fetched and how that went, and `shot` saves a picture of it and says where. `text` is what it says, `click` and `type` use it, and `eval` runs anything in it. Add `--errors` or `--failed` for what's wrong, and `--item` when several pages are open. On a server the picture goes to that server.

You've got two buttons of your own beside the address. A count appears when the page has errors, and clicking it quotes them in your agent. ◎ lets you point at something on the page: click it and your agent gets where it is and its HTML. Esc cancels. Scripts on the page can't see that you're picking.

## Past conversations

The clock in the toolbar lists your Claude Code, Codex and Grok conversations, this workspace's first. So do ⇧⌘H, **Past Conversations…** in the **+** menu and in an empty tab, and the clock in the Agents section. Click one, or press Return, and you're back in it: in a terminal, in the folder it was in, or in the terminal it's already running in. If it can't be carried on, because its folder has gone, you get to read it instead. **Read**, on the row you're on or pointing at, or ⌘↩, shows it as a document, with what was said and what was done in a line each, and **Hand To** there asks another agent to read it and carry on. Tiri only reads the agents' own files, and what it writes for reading stays private to you. `tiri conversations [words]`, `read`, `open`, `reopen` and `hand` do the same for agents.

Each has a short title saying what it was about, with your first prompt on the line beneath it. Your Mac's own model writes them as they come into view, in under a second or so each, and keeps them. To have them all ready, turn on **Title every conversation in advance** in Settings, under Agents: it runs only while plugged in, and only if you ask. Without Apple Intelligence, and on a server, titles come from your first prompt, with links and paths made short. A title is a good guess from what was said, so check before relying on one.

To find one, describe what you remember. Results appear as you type, each with what was said around the match.

- **It looks at what was said.** Tiri keeps a private index of what you and your agents wrote and did, without tool output, which is most of the file and matches nearly everything. 7 GB of conversations came to an index of under 60 MB, built in a minute or two the first time, then only what's changed.
- **It tries other words.** With Apple Intelligence on, your Mac's own model suggests other words for what you described, in English even if you asked in Chinese, and picks the likeliest when nothing has your exact words. It runs on your Mac and sends nothing anywhere. Without it, or with **Titles and search with Apple Intelligence** off in Settings, search finds the words you type. If your Mac can't use it, Settings says why, and takes you to where it's turned on if that's what it needs.
- **For the hard ones, ask an agent.** **Ask Claude Code to find it**, at the end of the list, has your agent try other searches and read what it finds. This one uses your agent's tokens.

On a server it searches that server's files for the same words, without an index, so results come more slowly and with no excerpt.

## Tell an agent about a change

Hover over a change in a diff and press **Undo** or **Ask**, or right-click for those and **Undo All Changes in This File**. The request goes to the agent that made the change, typed into its input for you to send, with the change quoted. If Tiri can't tell who made it, it asks.

## Give your agent lines, files and images

Select lines in any file. Claude Code sees the selection the way it does in VS Code, because Tiri speaks its editor protocol: its status line shows what you've selected and it can read it. Run `/ide` in Claude if it isn't connected.

Select something in a file, a diff, rendered markdown, an HTML file, a web page or a PDF, and a **Quote in Agent** button appears beside it. It, ⌘L and right-click all do the same thing. With one agent running, your selection goes straight to it. With several, in any workspace, Tiri asks which session should get it, with the one you last used first. Then it moves you there.

Claude Code gets a real mention. Codex and Grok get the path and line range typed in, in the form each one reads, since they have no editor protocol. From a diff, both get the selected change itself, with its + and − marks, because a removed line isn't in the file any more.

A selection in rendered markdown becomes the source lines it came from, so Claude gets `@report.md#L12-20` rather than a copy of the words. HTML, web pages and PDFs have no lines to point at, so the selected text goes in as a quotation, with its page number from a PDF. Office files show through Quick Look, which doesn't let an app read a selection, so ⌘L adds the whole file.

To add files and images, use whichever is closest:

- ⌘V pastes a picture from the clipboard, or a file copied in Finder.
- Drag from the explorer or Finder onto the terminal.
- ⇧⌘L or the paperclip in the toolbar picks them.
- Right-click in the explorer or Changes, and choose Add to Agent.

In a plain shell, these insert quoted paths instead.

## Review an agent's work

Reading a change usually raises several remarks, and sending each one as you go interrupts you and the agent. So keep them, then send them together.

Select lines in a file or a diff and press **Comment** beside the selection, or ⌥⌘L, or right-click. With nothing selected, it's the line the cursor is in. Rendered markdown, web pages and PDFs work too. Write your remark: Return adds it, and ⇧Return makes a new line.

A mark appears beside the line, and clicking it lets you change or delete the comment. They wait in the **Review** section of the sidebar, go across as many files as you like, and survive a relaunch. If an agent moves the lines, the comment follows them. If it rewrites them, the comment says so when it's sent.

Press the paper plane, or ⌥⇧⌘L, and all of them go into one agent's input as one message, each beside the code it's about. Nothing is sent until you press Return in that session, so you can add to it first. With several agents running, Tiri asks which one. **Quote in Agent** (⌘L) still sends a single selection straight away.

Agents can use the same list with `tiri review`.

## Another window

Right-click a tab and choose **Move to New Window** to put a terminal, file or page on your other display. Its tab stays and says where it went, and closing the window brings it back. Each window shows one item: there's still one set of workspaces, in the main window.

## Quick edits

Type in any text or code file, and ⌘S saves. A dot on the tab means unsaved changes, and Tiri asks before closing or quitting over them. If an agent changes the file while you're editing, your text stays on screen and Tiri tells you, so nothing is overwritten without you choosing. Editing a Peek makes it a tab. This is for quick fixes, and it's still not a full editor: no snippets or AI ghost text.

The keys are VS Code's. ⌘/ comments, ⌘] and ⌘[ or Tab and ⇧Tab indent, ⌥↑ and ⌥↓ move lines, ⇧⌥↑ and ⇧⌥↓ copy them, ⇧⌘K deletes them, and ⌘↩ and ⇧⌘↩ add a line below or above. ⌃G goes to a line. ⌘D adds the next occurrence as another cursor, and typing goes in at all of them, with an input method too. Esc goes back to one. ⌥⌘F replaces, with a count of matches.

⌥Z wraps long lines in the file in front. `editor.wordWrap` sets what files start with: `off`, `on` or `bounded`, which wraps at `editor.wordWrapColumn`.

## Finding your way around

⌘⇧O lists what's in this file, from its language server or a reading of its lines, and shows each as you arrow through them. Esc puts you back. ⌘T searches the whole workspace, when a language server can answer. In ⌘P, spaces mean all of these words, `file:12` goes to the line, and `:`, `@` and `#` do the same as ⌃G, ⌘⇧O and ⌘T.

⌘+, ⌘- and ⌘0 change the text size in terminals and files, and web pages scale to match. It stays that way until you change it.

In a terminal, ⌘K clears, ⌘← and ⌘→ go to the ends of the line, ⌘⌫ deletes back to its start, and ⌘F marks every match on screen. Return goes further back through the output.

## Read anything

**Notebooks:** `.ipynb` files render with highlighted code, execution counts, text, errors, tables and images. HTML outputs can't run scripts or restyle the page, and big outputs are cut and say so. Files that can't be rendered show their source and say why.

**Math and diagrams:** `$…$`, `$$…$$`, `\( \)`, `\[ \]` and Mermaid code blocks render in markdown and notebooks, using libraries bundled with the app. A diagram that can't be drawn shows its source.

**LaTeX:** a `.tex` file with a same-named PDF beside it or in a build folder gets a PDF button. The PDF keeps your page and zoom when an agent recompiles.

**CSV and TSV:** files of millions of rows open quickly, with numbers lined up and a sticky header.

## Run a notebook

Press **Run All** above a notebook, or hover over a cell and press ▶. Output appears as it comes. Click a cell and ⇧↩ runs it and moves to the next. Double-click a cell, or press Return, to change it: ⇧↩ runs it, Esc puts it back, and it saves as you type. The menu beside **Run All** restarts the kernel, clears outputs, adds and deletes cells, and chooses the Python.

- **Your Python, nothing bundled.** Tiri looks for the project's `.venv`, then what a terminal there would get, then conda and pyenv, and uses the first with `ipykernel`. If none has it, it offers to ask your agent to install it. A kernel gets the same environment as a terminal, API keys and all.
- **It outlives the window.** A long cell keeps running if you quit Tiri, close the lid or lose the connection, and every result goes straight into the `.ipynb`, so it's there whether or not you were watching. Tiri picks it back up when you return. Closing the tab stops the kernel, and asks first if a cell is running.
- **On a server it runs on the server,** with that server's Python, the same as an agent would.
- **Agents can do all of this:** `tiri notebook run report.ipynb [--cell N]`, and `status`, `interrupt`, `restart` and `stop`. They can read the results from the file. If an agent changes a cell while you're typing in it, your edit isn't saved and Tiri says so.

A cell asking for `input()` asks right there in the cell, with **Stop** still working. If you're elsewhere, a toast says so and nothing gets in your way. An agent can answer with `tiri notebook input report.ipynb "text"`, and `status` says what it's waiting for.

Widgets that need scripts in the page, like `ipywidgets`, show a picture or text where they have one.

## Follow a name

⌘-click a name in a file or a diff, or press F12, to see where it's defined. Holding ⌘ underlines what you can follow. It floats as a Peek, and **Back** (⌃-) returns you to where you were, through as many jumps as you made. ⇧F12 finds everywhere it's used.

With no language server for that file, Tiri searches the workspace, the same way it does for a path. One match opens, several let you choose, and none shows a toast with a way to search. This is a good guess rather than a compiler's answer, and it doesn't need any setup.

## Colors

Every viewer of code uses the same TextMate grammars, 231 languages bundled and run locally: the editor, diffs, markdown and notebooks. A file with no extension goes by its `#!` line. Lines are colored off the main thread, visible ones first, and typing usually redoes one line, so there's no limit on file size. A few grammars aren't included because of their licences: Ada, Gnuplot, nginx, Org, Racket and AutoHotkey 2 are GPL or LGPL, and APL, DAX, DreamMaker, GLSL and Tcl have no licence to go by. `Resources/grammars/NOTICE.txt` has the rest.

## Completion

While you type a name, or after `.` and the like, a list offers what the language server knows. With no server it offers words from this file and your other open files, from the second letter. ⌃Space or ⌥Esc asks at any time, including in comments, strings and prose, where it otherwise stays quiet.

Arrows move, Return and Tab accept, and Esc closes the list without reaching the agent or closing a Peek. "cra" finds `createApplication`, and what you've used lately and names close to the cursor come first. An import the name needs comes along with it, and accepting inserts at every cursor. The list stays hidden while an input method is composing. `editor.completion` turns off the list that appears by itself.

## Language servers

Tiri uses a language server you already have, wherever your shell or the project keeps it, for TypeScript and JavaScript, Python, Rust, Go, Swift, C and its relatives, shell scripts, YAML, JSON, HTML, CSS, Ruby, Lua, Java, Kotlin, C#, PHP and more. Servers you set up through Claude Code's language plugins work too.

The first time you open a language with no server, Tiri asks once whether to add one. Nothing downloads until you say so. **Add** installs it into Tiri's own folder, at exact versions and hashes that came with the app, with `uv`, `npm --ignore-scripts` or `go`, and nothing outside that folder changes. Python gets basedpyright, about 283 MB, and it doesn't need Node. Settings offers the same thing, or for the rest, a prompt for your agent. Agents can run `tiri languages` and `tiri languages add <id>`. On a server, your agent does the installing.

- ⌘-click, F12 and ⇧F12 ask the server first, and search if it has no answer yet.
- Hold ⌘ over a name for a moment, or press ⌘K ⌘I, to see what it is.
- Errors and warnings are underlined, with a dot beside the line, and counted in the bar along the bottom.
- A diff shows only the errors on lines it added, with **Quote in Agent** to hand them over.
- Claude Code gets them through its editor protocol, so it can see what its own edit broke. Any agent can run `tiri diagnostics`, which checks the files changed since the last commit.

A server starts once you've looked at one of its files for a moment, and stops after 10 minutes unused. They can use a lot of memory, and that's on top of Tiri's own. Some servers run a project's build scripts as they read it, the same as building it would. A server that's inside the project itself, like one in `node_modules/.bin`, is that project's code, so Tiri asks once before running it, and only when you've just asked for something it would answer. Turn all of this off in Settings, under Languages.

## The bar along the bottom

It shows each repository's branch, with fetch, pull and push, and what a language server has to say about the file in front. With nothing to show, like in a folder that isn't in a repository, it goes away and gives the room to what you're looking at.

## The sidebar

Explorer, Changes and Open Items each fold: click a section's name. What's still open takes the room, and Tiri remembers which are folded.

## Search across files

⌘⇧F searches the contents of the workspace's files and leaves out what `.gitignore` does. Results appear as you type, and lowercase ignores case. Return floats the file over what you're doing, at that line, and ⌘↩ keeps it as a tab. It starts from what you've selected, or your last search.

## See what changed

When a workspace folder is in a Git repository, the sidebar has a **Changes** section listing every file changed since the last commit, live as your agents work. Click one to see its diff as a tab, or double-click to keep it. A changed file has a **Changes** button above it, and a diff has **Open File** to go back. They work the same in a Peek. Agents can show you a diff too: `tiri diff src/app.ts` floats it over the terminal.

Since the last commit can cover a lot, so the same section can show what one agent's turn changed. Choose **Latest Turn** or a particular prompt from the menu in its header. Tiri takes a snapshot when an agent takes your prompt and another when it stops, using the hooks in Agent Status. The snapshots stay in Tiri's own folder for a week, and nothing changes in your repository: no branch, stash, staged change or new object. If two agents work in one repository at the same time, a turn can include the other's edits, and Tiri says so. Codex only reports when it stops, so its first turn gives Tiri somewhere to start from, and the turns after that show up. `tiri turns`, `tiri changes --turn latest` and `tiri diff src/app.ts --turn latest` do the same for agents.

The bar along the bottom of the window shows each repository's branch, a `*` if it has uncommitted changes, and how many commits there are to pull and push, like `feat/login* 2↓ 3↑`. The counts follow commits and pushes from your terminals.

- The arrows button fetches. Tiri never fetches by itself, so `0↓` means nothing was new at the last fetch.
- `2↓` pulls, only ever moving your branch forward. If the branch and the remote have both moved on, or your uncommitted changes touch the same files, Tiri says so and changes nothing.
- `3↑` pushes, after asking which branch is going where. A branch that's never been pushed offers **Publish** instead.

All three are in the command palette too, and `tiri git` shows the same status. A remote that needs a password can't ask from here, so Tiri offers a terminal in that repository. Merging, committing and switching branches are for you or your agent.

Agents commit often, so the same menu goes further. **This Branch** shows everything since the branch left its base, uncommitted work included, and says what it's compared with: origin's default branch, or else main or master. **Recent Commits** lists the last 30 commits, and choosing one shows its files. A merge shows what it brought in compared with its first parent. Diffs from any of these are items like any other, and they come back after a relaunch.

A diff has a button for side by side, kept in Settings as `diff.sideBySide`. In a narrow pane or Peek it stays in one column. What changed within a line is highlighted. An image shows before and after. F7 and ⇧F7 go through the changes, in a diff or a file.

Thin bars beside a file's line numbers mark what differs from the last commit: green for added, blue for changed, and a red wedge where lines were deleted. Click one to float that change. They follow the file on disk and new commits, and wait while you have unsaved edits. Files outside the workspace's repositories and very large files don't get them. The explorer tints changed files, with M, U and the other letters, and a folder gets a dot when something under it changed.

`tiri changes --branch`, `tiri changes --commit HEAD~1`, `tiri diff src/app.ts --commit HEAD~1`, `tiri diff src/app.ts --branch` and `tiri log` do the same for agents.

## Start with a folder

Nothing runs until you've said where. A new workspace shows the agents your shell can find: press one, choose its folder, and it starts there. If it can't find any, it links to where to get them, and they appear when you come back. Any other first terminal or agent in a workspace without a folder asks too. In a workspace with several folders, the **+** menu asks which folder a new terminal or agent should use, and ⌃\` uses the folder of what you're looking at.

## The Peek

When you ⌘-click a file in a Claude Code or Codex session, it opens as a floating Peek over the session rather than as a new tab. Your layout doesn't change, and the terminal stays visible beside it.

- ⌘-click the next path to replace it, so you can go through a list of files.
- **Open as Tab** (⌘↩) keeps it. **Open to the Side** (⌥⌘↩) puts it in a split.
- Esc, or clicking outside it, closes it and returns you to the terminal, without reaching the agent, even when an agent opened it and your keyboard stayed in the terminal. The next Esc is the agent's.
- ⌘⇧-click skips the Peek and opens a tab.

When an agent runs `tiri open report.md` in a Tiri terminal, the file floats the same way, and the keyboard stays in the session. Settings can change what ⌘-click does.

## Everyday use

Shortcuts follow Cursor. All of them can be changed in Settings, or by asking your agent.

| Action | Shortcut |
|---|---|
| Quick open (add `:12` to jump to a line, or `>` for commands) | ⌘P |
| Command palette | ⌘⇧P |
| Toggle sidebar | ⌘B |
| Focus explorer | ⌘⇧E |
| New terminal | ⌃\` |
| Split right / down | ⌘\\ / ⌘K ⌘\\ |
| Close item / reopen last closed | ⌘W / ⌘⇧T |
| Next / previous tab | ⌃Tab / ⌃⇧Tab, ⌘⇧] / ⌘⇧[ |
| Focus group 1…9 | ⌘1…⌘9 |
| Switch workspace 1…9 | ⌃1…⌃9 |
| Go to the next terminal needing attention | ⌘⇧U |
| Add a review comment / send them all to an agent | ⌥⌘L / ⌥⇧⌘L |
| Find in the current item | ⌘F |
| Go to definition / find references / back | F12 / ⇧F12 / ⌃- |
| Settings | ⌘, |

In the explorer, a single click previews a file and a double-click keeps it open. Enter renames, Space previews, ⌘↓ opens and ⌘⌫ moves to the Trash. Drag a file from the explorer into a terminal to insert its shell-quoted path. Drag tabs to reorder them, move them between groups, or onto the edge of a pane to split it.

⌘-hover underlines any path in terminal output that exists or can be found. ⌘-clicking a file opens it, including `path:line:col` and the other formats compilers and test runners print. ⌘-clicking a folder reveals it in the explorer.

Agents often print a path that doesn't exist as written, like `/resume/index.html` from a web root. Tiri doesn't give up on those. It searches the workspace's folders, the folders its terminals are in, and its open files. One match opens right away. If several match, you pick one, with the likeliest first. There's never an alert to dismiss.

## Drive it from an agent

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
```

Run `tiri --help` for all commands, or `tiri --skill` for a guide written for agents. Terminals inside Tiri have `TIRI_SOCKET`, `TIRI_WORKSPACE` and `TIRI_ITEM_ID` set.

`tiri` works in every terminal inside Tiri. To use it in your other terminals, go to Settings, General, and press Install. That adds a link at `~/.local/bin/tiri`, which keeps working when the app updates. If your shell doesn't look there, Tiri gives you the line to add.

## Show agent status

Hooks tell Tiri exactly when an agent is working, waiting for you or done, and let it resume exactly the right conversation after a relaunch. The status shows on the tab, in the item list and on the workspace switcher, and you get a notification if you aren't looking at that terminal.

Without hooks, Tiri estimates status from terminal activity, which is less precise.

A `claude -p` run doesn't report, whether a session or a script started it, so it can't change the tab's status or which conversation comes back after a relaunch. Neither can one agent running inside another's terminal.

**Turning them on:** Each agent in Settings has an Install button, and Tiri offers the first time it sees one run. Your agent can start it too, with `tiri hooks install claude`. Either way Tiri shows what it will add and waits for your yes. It keeps your other hooks and settings, leaves a copy of the file next to it, and can remove its entries again.

Outside Tiri these hooks do nothing and print nothing, so they're safe to leave on. Codex asks you to trust hooks once, in `/hooks`. Grok asks you to trust each folder before it runs any hooks. Grok also runs the hooks in your Claude Code settings by default, so if those are on, it already reports. Its Install button adds a file of Tiri's own at `~/.grok/hooks/tiri.json` and changes nothing of yours, for when you've turned that off.

## Your agents

There's one list of agents, in Settings under Agents, or through **Manage Agents…** in the + menu. Switch off the ones you don't use. If you only use Claude Code, only Claude Code appears in the + menu, on a new workspace, in the Ask buttons and in the command palette. Turn Grok on and it appears in all of them straight away, because they all read the one list. Your agent can do the same with `tiri agents off codex`.

Turning one off only stops Tiri offering it. Sessions already running carry on, and you can still hand them things.

Tiri isn't tied to these three either. Press **Add an Agent** and give it any command, and you can hand it lines, files, review comments and problems from Tiri, as plain text it can read. One you added can be deleted. What it can't do without more is report its status exactly or resume a conversation by its ID, though you can give it a resume command.

Supporting one fully takes one entry in `AgentCatalog` (`Sources/TiriCore/Agents.swift`), which says how to recognize it, write a mention, resume it, install hooks and read their payloads. Everything else reads from there.

## Plugins

A plugin adds what a terminal can't draw: panels, file viewers, sidebar sections, status bar items, buttons above files, settings, commands and languages. Skills, hooks and MCP stay with your agent, so a plugin doesn't rebuild them, though it can carry a part for Claude Code that loads only in Tiri's terminals.

You don't write them by hand. Say what you want, your agent writes and tests it, and you see what it adds and runs before turning it on. Type it into **New plugin**, under Plugins in Settings, or run **New Plugin…** from the palette or the Plugins menu: "show my pull requests in the sidebar", "open .csv files as a chart", or "port the VS Code extension Todo Tree". A file in a language nobody here knows has a button in the bottom bar that asks your agent to add it.

Your agent can also do it from the command line:

```sh
tiri plugin new my-thing        # a working start
tiri plugin validate my-thing   # what it adds and runs, without running it
tiri plugin test my-thing       # its own tests
tiri plugin enable my-thing     # asks you, on screen
tiri plugin reload              # reads the folder again, with no restart
tiri plugin verify [--tests]    # every plugin against this build
tiri plugin export my-thing     # my-thing-1.0.0.tiriplugin, one file to hand to someone
tiri plugin import a.tiriplugin # or a .zip, a folder, or a VS Code .vsix: it arrives off
tiri run my-thing.hello a=b     # a plugin's commands work like any other
```

To hand a plugin to someone, use Export in its menu in Settings, or `tiri plugin export`. They double-click the `.tiriplugin` file, see what it adds and runs, and turn it on. Its settings don't go with it, and neither do `.env` files.

Its commands reach the palette, the Plugins menu, shortcuts and `tiri run` with no more work. To bring over a VS Code extension, give your agent its name: it finds the extension, rewrites it for Tiri, and tells you what it dropped. Tiri doesn't run extensions as they are. Importing a `.vsix` directly runs none of its code, brings its languages and grammars, and writes down everything else.

**What it can do:**

- **Only you can turn one on.** An agent can ask, and the question names everything it adds and runs. Return doesn't press Turn On, since a question can appear while you're typing to an agent.
- **Any change turns it off,** until you approve it again, with what changed listed. Tiri records a hash of its files, and looks again right before anything runs. What npm rebuilds from an exact lockfile, in `node_modules`, isn't part of that hash, and install scripts never run.
- **Panels are sandboxed.** Each plugin has separate storage. A panel only gets files from its own folder, only runs scripts from those files, reaches only the addresses it declared, and can't navigate away. It reaches the rest of Tiri through a bridge that only allows what it declared.
- **A panel can't make your agent do anything.** Right after you click or type in it, it can leave words in the agent's input, and you're the one who presses Return. It's refused if the agent is waiting for an answer, where your Return would answer it, and if what's running doesn't hold pastes as pastes, where they could run by themselves. Otherwise a page with no access could borrow an agent's.
- **Programs run with your full access.** Anything a plugin runs can do what you can, including reading your files, and Tiri says so before you turn it on. The control socket has no per-client login, so nothing short of an OS sandbox would change that, and there isn't one yet. A command that's finished or past its time is stopped, with whatever it left running.
- **Nothing loads by itself.** Plugins in a cloned repository aren't looked at. A terminal on a server can't manage plugins, run their commands or drive their panels. On a server's workspace, programs run on the server, from a copy of the plugin's folder in `~/.tiri/plugins`, unless they say `"where": "mac"`.
- **It can't slow you down.** There's nothing for a plugin to hook while you type, scroll or read a terminal. One you aren't using costs a directory walk at launch: panels open on demand, sections load when you unfold them, and background processes stop after 10 idle minutes.
- **Turning one off takes all of it away:** commands, keys, languages, sections, items, panels, processes and servers. Its settings stay until you remove it.

**What this doesn't stop:** the approval record is a file in Tiri's own folder, and anything running as you could edit it. It stops an agent that's been tricked into asking, not a program already running with your access, which could as easily edit your shell's startup files. A panel's page can probably still leak a little through DNS lookups, which a content policy doesn't cover. And a plugin's process on a server is as trustworthy as that server.

## Your Tiri

Tiri can be changed the way it was made: by asking. Choose **Change Tiri…** from the Tiri menu, the command palette or the start screen, or ask when the palette or a settings search finds nothing, or just tell any agent in a Tiri terminal. You can drag a box around the part you mean, so your agent can see it. Say what you want different, press Return, and your agent starts in a tab of its own, in a workspace called Your Tiri holding the exact source of the version you're running. You watch it in Tiri's own file tree and Changes.

When it's done, a card on its tab says what it did and how big it is, with **Try It**. Tiri closes and opens again in about half a second, with everything still running, including the agent that made the change, now running inside what it made. For ten minutes the card says **Keep** and **Back**, and Back is one click and loses nothing.

**Change Tiri…** also lists your changes in your own words, each with a switch, and **Plain Tiri**, the app you installed, and Settings has the same list with what each one touched. Whatever is waiting for you, like a change to try or an update, stays in the bar along the bottom. It's never altered, so it's always there. Hold ⌥ while opening Tiri to start it for one run. If a change stops Tiri from starting, Tiri goes back to the copy before it by itself, and says so.

The first change takes about 1 GB of build files, in `~/Library/Application Support/Tiri/your-tiri`, and needs the Command Line Tools, which anyone running an agent already has. If you never use any of this you won't find it: there's no button, tip or tour, nothing runs, and nothing's on disk but the source inside the app, about 5 MB. **Offer to change Tiri** in Settings removes every entry.

**Updates keep your changes.** Each change is one commit on top of a release, and an update replays them onto the next release in the background: Git first, then a merge that understands Swift, then a build, then each change's own check. Only then does **Update** appear, one button, the same for everyone. A change that can't be replayed goes to your agent to mend, if you've said yes to that once, and one it can't mend is kept, named, and left out of that update. If Tiri learns to do the same thing itself, your change retires itself and tells you.

What an agent can and can't do:

- It can build a copy but can't switch to one. Switching takes your click, with no command for it. A program running as you could still write Tiri's files, as it could anything else of yours, so this is a line for agents, not a wall against malware.
- A personal copy is signed on your Mac with its own certificate, in a keychain file of its own, and has its own bundle ID. So macOS asks once about your folders for it, and never again after rebuilds, and your answers for the app you installed are left as they were.
- Nothing loads from anywhere else. There's no gallery and no way in from a link.
- An update has to be a newer release of this app from whoever made yours, by Apple's chain, checked before it goes anywhere and again when you press Update. A feed has to be https, and its notes don't reach your agent.
- A change's check is a script that runs at every update, with your access, so it's counted in the card's size and shown with its diff.

For agents, `tiri --skill` has the commands and `CHANGING.md` in the source has the rest. Maintainers: `scripts/release.sh` refuses a release if the changes in `Tests/personal-changes` no longer go on (`scripts/replay-corpus.sh`), or if it stops building with the Command Line Tools (`scripts/check-free-tools.sh`), which is what using an Apple macro whose plugin is only in Xcode does. The syntax-aware merge is Mergiraf with a Swift profile, from `scripts/build-merge-tool.sh`. It's optional, and goes at `your-tiri/tools/mergiraf`.

## Dark mode

Choose Dark in Settings, or leave it on System while your Mac is dark, and everything follows, live: the app, terminals, code, markdown, web pages and media.

PDF, Office, iWork, RTF, font and web archive previews have no dark mode of their own, so Tiri shows their pages inverted, with colors kept. A photo in a document inverts too, so the moon button above the file shows its true colors, and Tiri remembers that for the item. `tiri web-dark on|off <item-id>` does the same. To keep all documents in true colors, turn off Darken documents in Settings.

Black artwork on a transparent background, in a PNG or SVG, gets a light plate behind it so it stays visible.

## Settings

There are two ways to change a setting, and neither involves a file.

**The screen:** ⌘, opens Settings as a tab, with a list of panes down its side: General, Agents, Terminal, Editor, Languages, Files and Keyboard. ⌘F searches all of them at once, and you change what you find right there. Changes apply immediately. A setting you've changed has an arrow beside it that puts it back.

**Your AI:** **Ask Claude Code** under that list hands your agent a prompt, and the arrow beside it offers your other agents or copies the prompt. It can then explain any setting in plain words and change it for you. Agents use `tiri settings`, and `tiri settings open` shows you a pane, a setting, a command or a search:

```sh
tiri settings explain              # every setting, its value and what it does
tiri settings set code.wordWrap on
tiri settings open terminal.fontSize
```

Keyboard shortcuts work the same way. Under Keyboard, commands are grouped by what they're for, and the list beside them jumps to any group. Click a shortcut and press the keys, or point at a command that has none and click **Add Shortcut**. If another command has that key, Tiri asks before taking it. **Find by Key** tells you what a key does, or that it's free. **Changed** shows only the ones you've changed. Your agent can change them with `tiri keys`.

## Development

Test copies from `scripts/dev-app.sh` hide themselves as apps, take no clicks, and are stopped if a window reaches the screen, because Stage Manager brings back any window put off-screen. `TIRI_DEV_MAY_TAKE_FOCUS=yes` makes one visible, for when nobody's using this Mac.

`scripts/e2e-plugins.sh` drives a test copy through the whole plugin system, including trying to break out of a panel, and `TIRI_BUDGETS=1` checks the speed budgets with 50 plugins. `scripts/e2e-plugins-remote.sh` does the same for a workspace on a server.

```sh
swift test          # unit tests and an in-process control server test
scripts/e2e.sh      # drives a real app through every CLI command, with isolated state
```

`TiriCore` holds the models, persistence, path parsing, workspace import, control protocol and the catalog of agents, with no UI. `TiriApp` is the SwiftUI and AppKit app. `tiri` is the CLI. See [PROGRESS.md](PROGRESS.md) for current status.
