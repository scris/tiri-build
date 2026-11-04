# Progress

Status against the [spec](https://claude.ai/artifact/KiXf5aQEigev1vNJFeysbb).

All of milestones M0 to M8 are built. The work is one commit, not one per milestone, because the milestones were built together and then hardened by testing; splitting it afterwards would have invented a history.

## How it was tested

- `swift test`: unit tests for the model, path parsing, persistence, import, settings, keybindings, CLI and an in-process control server.
- `scripts/e2e.sh`: drives a real app through every CLI command, with isolated state.
- Real launches, driven with real mouse and keyboard events and checked with window screenshots.
- Real Claude Code sessions in Tiri terminals, in a scratch project: prompts, status, ⌘-clicking its output, relaunch and resume, and a session running a nested `claude -p`, before and after the fix. Codex was launched to confirm its TUI renders, but no session was run.
- Real folders, read-only, at their true paths: `~/ai-hotpoints-2026`, `~/nvcm-agent`, `~/mgx-dev`, `~/Documents/tiri`, and the real `seenot-web.code-workspace` in `~/Documents`, after you allowed access. No prompt appeared.
- Dark mode on every viewer, on a virtual display, with real PDF, PowerPoint, Excel (51 MB) and Word files as temporary copies. Measured brightness in the content area confirms dark, light, and switching live both ways.
- Real project contents, as copies with the same relative layout: `seenot-web.code-workspace` and its three folders, plus Office, PDF, HEIC, video and other files.

- SSH workspaces, with `scripts/e2e-remote.sh` and by hand, against real servers: Ubuntu 24.04 on x86-64 on Google Cloud (also through a jump host), Alpine with busybox and no bash on ARM with forwarding forbidden, and Ubuntu on ARM with fish as the login shell and `MaxSessions 3`. Includes a real 45-second packet blackhole with `iptables`, killing the connection under a running program, quitting Tiri under one, the Linux kernel's 97,000 files, clangd running there, real Claude Code's first-run screens, and real clicks and keys through the unknown-host, passphrase, ⌘-click, save and paste flows.

### Not verified yet

| What | Why | How to check |
|---|---|---|
| The theme following a live change of the Mac's own appearance | Flipping it would change the whole Mac while it's in use. `"system"` is verified while the Mac stays dark, and `tiri theme` switches live both ways | Change Appearance in System Settings with a PDF open |
| By hand, with the keyboard and mouse in a focused window | Tested on a virtual display without taking your screen, so these never had a real press: Shift+Enter and Option+Enter in Claude Code, ⌘V with a picture or a copied file, drag and drop, the paperclip's picker, ⌘-clicking a path | Try each one once |
| Sessions over days, and across a reboot | Quit and relaunch are tested on a real Claude session. A long run isn't | Use it |
| Resume by session ID on a real session | A relaunch reattaches to the running session, so this only happens after a reboot. The stored ID itself is verified across a relaunch, and `claude --continue` on a real session | Reboot, then see that the agent comes back |
| Clicking a native notification | Needs the system permission prompt answered. In-app toasts and badges are verified | Allow notifications, then run `tiri notify done --item <id>` in a terminal in another workspace |
| Codex hooks, and a Codex turn | Its composer is tested with lines and an image, unsent. Hook payloads are tested with documented-format JSON | Settings, Agent Status, then run a session |
| Clicks on what's new: the switches, Add an Agent and the details in Your Agents, Manage Agents… in the + menu, the Comment button, a comment's mark, the Review section's buttons, the menu in Changes' header, Back and Quote in Agent on a diff | Buttons don't take clicks in an unfocused window. Each one's action is tested through the CLI and commands, and they've all been seen on screen, except the menu in Changes' header, which hasn't been seen open | Try each once |
| Grok's permission prompt reporting "needs input" | Grok on this Mac runs with always-approve, so a real one never came up. Its payload is read from the docs, and every other Grok event is checked against real ones | Turn always-approve off, then ask Grok for something it has to ask about |
| A real ⌘-click and ⌘-hover on a name in code | Unfocused windows don't take clicks. Followed through `tiri follow` and F12, which run the same search, but not the hit test under the mouse | Hold ⌘ over a name in a file, then click |
| rust-analyzer, gopls, pyright, typescript-language-server, ruby-lsp and lua-language-server | clangd and sourcekit-lsp are tested for real: diagnostics, definition, references, hover, an edit on disk, and stopping when idle. On this Mac rust-analyzer is a rustup shim for a component that isn't installed, which did prove that case is reported. The others aren't installed. The protocol they share is the same, but each has its own habits | Open a file in each language, and press F12 on a name |
| Claude Code asking for diagnostics by itself | The answer is tested through the real WebSocket with a token, the way Claude Code connects. Not watched during a real edit, which needs a real prompt | Ask Claude to make an edit that breaks something, with the file open in Tiri |
| Per-turn diffs in a real session | Tested with real hook payloads through the real CLI, and real edits on disk. Not during a real agent turn, which needs a real prompt | Choose Latest Turn in Changes, then send your agent a prompt |
| Seeing the folder panel, and a real ⌘-click on a path | Tested without taking your screen: the panel through accessibility, and the click through `tiri follow`, which runs the same code. An unfocused window doesn't draw the panel or take clicks | Open Tiri, press +, choose Claude Code; then ⌘-click a path |
| Ask Claude Code against the real agent | Tested with a stand-in command, to avoid a real session on your account | Press Ask Claude Code on the Settings tab |
| Pressing the agent buttons on the empty screen, and agents appearing after you install one | Buttons don't take clicks in an unfocused window, so tested without taking your screen through the palette command, which runs the same code. Coming back to the app needs real focus | New workspace, press Claude Code, choose a folder |
| A `codex exec` inside a Claude terminal | Covered by unit tests only, to avoid a real Codex run | Ask a Claude session to run one, then check `tiri items` |
| Fetch, pull and push against a real remote | Tested with a local bare repository, so no real remote changed. SSH keys, the keychain and push hooks are unproven from the app | Fetch in a real repository, then push something you mean to |
| Clicking the status bar's buttons | Clicks don't reach an unfocused window, so tested through the palette commands, which run the same code. The confirmation's buttons had real presses through accessibility | Click the arrows and the `↓` and `↑` counts |
| A real agent's conversation on a server | Testing Claude Code on a server needs your account on it, and credentials weren't copied there. Its screens render, its editor-protocol socket was exercised by a stand-in client with the real token and lock file, and hooks with documented payloads | Connect to a server where you're logged in, run `claude`, and try `/ide`, a Quote in Agent and a turn |
| A Mac as the server | The helper is built and its commands were run on this Mac, but no full session against Remote Login | Connect to a Mac |
| A password rather than a key, and one-time codes | Passphrases and unknown hosts had real keystrokes. Passwords and codes go through the same prompt | Connect to a host that asks |
| Waking from real sleep on a server workspace | Dropped connections are tested, and wake triggers the same retry, but the Mac was kept awake | Close the lid, open it |
| Quote in Agent from a notebook with a real agent | Tested with a stand-in command | Select in a notebook, press ⌘L with Claude Code running |
| Wheel scrolling in two columns, the pointer over a mark, ⌘-hover in the left column | Tested with real clicks and keys, but not a real scroll or hover | Scroll a side-by-side diff; hold ⌘ over a name on its left |
| ⌘T with sourcekit-lsp on a built package | Tested with clangd. An unbuilt Swift package has no index, so it reports nothing | Build, press ⌘T, type a name |
| Reduce Transparency, Increase Contrast | Left to the system's glass, as the spec asks, but not exercised | Turn them on in Accessibility settings |
| Terminal translucency setting | Implemented, not looked at | Set `terminal.translucent` |

## What works

- **Servers:** Connect to Server, `tiri remote`, and importing Cursor's Remote-SSH `.code-workspace` files. A folder on a server is a workspace like any other: tree, quick open, ⌘-click, Peek, Changes, search, go to definition, language servers, comments and agents. Programs survive dropped connections and quitting, saves wait for the connection, ports forward on demand, pasted files are sent over, and `tiri` in a terminal there reaches only that server's workspaces. Works with forwarding forbidden, except for port forwarding and the editor protocol. Other systems get terminals and files without surviving a dropped connection.
- **Workspaces:** create, rename, delete, switch (sidebar and ⌃1…⌃9), add and remove folders, persist and restore, import `.code-workspace`.
- **File tree:** multi-root, lazy, live updates, preview and pinned opens, reveal, context menu, inline new and rename, Trash, Cursor's keys.
- **Terminal:** login shell with your aliases, truecolor, full-screen TUIs, cwd tracking, presets, exit bar with Restart.
- **Peek:** ⌘-click or `tiri open` from a terminal floats a viewer, with Open as Tab, Open to the Side, replace on next click, Esc and click-outside to close.
- **Path links:** existing paths underline on ⌘-hover, VS Code's location formats, soft and hard wrapped paths, directories reveal, web URLs float too.
- **Editing and highlighting:** plain-text editing with save, undo and conflict handling, and highlight.js grammars, bundled and run locally, for common languages.
- **Sessions:** a small background server keeps each terminal's program running while Tiri is closed, and Tiri reattaches. Closing the tab ends it.
- **Agents:** Claude Code, Codex and Grok come from one catalog in `Agents.swift`. Which ones you use is one list, on or off, that everything offering agents reads, shown as one table in Settings and through `tiri agents`. You can add any command as an agent, and delete it again.
- **Agent input:** selections reach Claude Code through its editor protocol. ⌘L, paste, drag and a picker add lines, files and images to any agent.
- **Review comments:** comment on lines of any file or diff, keep them in the sidebar across a relaunch, and send them to one agent as one message, unsent. They follow lines an agent moves. `tiri review` for agents.
- **Go to definition:** ⌘-click or F12 in a file or diff floats the definition as a Peek, with Back. ⇧F12 finds uses. Found by searching the workspace when there's no language server.
- **Language servers:** finds the servers on this Mac and starts them when a file has been looked at for a moment. Hover, definition, references and diagnostics. Diagnostics reach Claude through `getDiagnostics`, any agent through `tiri diagnostics`, and diffs for the lines they added.
- **Changes:** a sidebar section and diff items in the main window, live, in tabs and Peeks, with `tiri changes` and `tiri diff`. Read-only: no staging or committing.
- **Reviewing commits:** Changes also shows This Branch, which names its base, and Recent Commits, with `tiri changes --branch`, `--commit`, and `tiri log`. Handles root commits, merges, empty branches, detached HEAD, no commits, renames and binary files.
- **Diff viewer:** inline or side by side (`diff.sideBySide`), changed words highlighted, images before and after, F7 and ⇧F7. Tens of thousands of changed lines stay responsive.
- **Gutter marks and explorer decorations:** bars against HEAD beside the line numbers, click to float the change. M and U letters and tints in the tree, a dot on folders.
- **Per-turn diffs:** snapshots at the start and end of each agent turn, kept outside the repository, so Changes can show what one turn did. `tiri turns` for agents.
- **Editing keys:** comment, indent, move, copy and delete lines, auto-indent, bracket match, current line, ⌘D with real multi-cursor typing including through an input method, find and replace with a count, wrapping off, on or bounded. Undo is per file, and restores the cursor.
- **Symbols:** ⌘⇧O from a language server or a fallback reading, previewing as you arrow. ⌘T when a server can answer. ⌃G with a live preview.
- **Quick open:** spaces as AND, `file:12`, recent files first, across a relaunch.
- **Explorer:** compact folders, on by default (`explorer.compactFolders`).
- **Zoom:** `window.zoomLevel`, in terminals, files, diffs and web pages.
- **Terminal:** ⌘K, ⌘← ⌘→ ⌘⌫, find with marks and a count, and `16:5` under a path as a link.
- **Worktrees:** New Worktree… and `tiri worktree <branch>` give another agent its own checkout, as a workspace, on a Mac or a server.
- **Fetch, pull and push:** a bar along the bottom of the window with each repository's branch, uncommitted marker and commits to pull and push, plus Fetch, Pull (fast-forward only), Push (asks first) and Publish, and `tiri git`. No merging, no force push, no automatic fetch.
- **Path search:** a path that doesn't exist as written is searched for across the workspace's folders, its terminals' folders and its open files. One match opens, several offer a choice, none shows a toast. Never an alert.
- **First run:** the empty screen offers the agents the user's own shell can find, or links to get them. Settings can link `tiri` into `~/.local/bin` for other terminals.
- **Tree → terminal:** drag inserts a shell-quoted path.
- **Agent attention:** status on the tab, item list and workspace switcher, toasts, dock badge, jump to next (⌘⇧U), hooks, fallback estimate when there are no hooks.
- **Session restore:** layout, cwd and terminals. Agents resume. Other commands wait typed at the prompt, so nothing like `./deploy.sh` re-runs by itself.
- **Dark mode:** every viewer. PDF, Office, iWork, RTF, font and web archive pages are inverted with their colors kept, with a moon button for true colors. Black artwork on transparency gets a light plate.
- **Viewers:** markdown (rendered and source, with math and Mermaid), Jupyter notebooks (rendered and source), code with light highlighting, images (HEIC, GIF), SVG, PDF (keeps page and zoom on reload), audio, video, HTML, CSV and TSV of any size, Office and iWork through Quick Look, Quick Look for everything else. All reload when the file changes. A `.tex` file offers its PDF to the side.
- **Web:** address bar, back, forward, reload, auto-reload for local files, forced dark.
- **Control API and CLI:** everything in spec §5, plus `send`, `read`, `layout`, `tree`, `commands`, `run`, `perf`, `hook`, `hooks`.
- **Navigation:** quick open, command palette, all §6 keybindings, chords, breadcrumbs, find, tab drag and drop.
- **Settings:** a screen built from one list of settings, and `tiri settings` for agents, with a one-click prompt from the screen to your agent. Keyboard shortcuts too, with `tiri keys`. Nobody needs to touch JSON. The file is only where they're stored.

## What is stubbed or thin

- Find doesn't cover images, video or Quick Look files. Web and markdown find has no match count.
- One main window. Any tab can move to its own window, but a second window can't hold its own workspace. A second instance can't take the control socket and says so.
- Notebooks are for reading. They don't run: an agent runs one with `jupyter nbconvert --execute`, and the view updates.
- Notebook outputs that need scripts (Plotly, widgets) show a picture if they have one, or a note. The Source button on a very large notebook can stall for seconds.
- A server: a workspace is on one server, not several, and not a mixture with local folders. Agents can't be told apart between two Macs on one server's Claude settings. If the connection comes back on another forwarded port, an agent already running there needs `/ide` to find the editor again.

## Performance (spec §9)

Measured on this Mac (M-series, macOS 27), release build.

A language server isn't counted below, because it's optional and only runs once you've looked at a file for a moment. sourcekit-lsp on a one-file package took 35 MB. A large TypeScript or Rust project's server can take gigabytes, which is why they stop after 10 minutes unused.

| Budget | Target | Measured |
|---|---|---|
| Cold launch to window | < 500 ms | 270–360 ms after the first launch of a build. The first launch after a build was 480–900 ms |
| Open text, code or image under 5 MB | < 100 ms | 15–30 ms |
| Open markdown | < 100 ms | 47 ms typically; 110 ms for a 124 KB file (over budget) |
| Open HEIC | (not in budget, was 8 MB) | 134 ms, decoded off the main thread |
| 50,000 files | stays responsive | Switching in takes 42 ms, the tree loads lazily, quick open searches off the main thread |
| Memory: 1 workspace, 2 terminals, 3 previews | < 250 MB | 68 MB app + about 80 MB WebKit helpers |

Open times run from the request until the content is showing, except for Office and PDF, where they stop when the viewer is attached and Quick Look's own rendering continues after that.

## Known bugs

- ⌘-clicking a labelled hyperlink whose target has no scheme can still show SwiftTerm's "Link blocked" alert, because SwiftTerm doesn't expose link targets. Text that looks like a path never reaches it. Fixing it needs a patch to SwiftTerm.
- In dark mode, photos inside a PDF or Office file invert with the page, because the viewer can't tell them apart. The moon button shows true colors.
- Large Office files show Quick Look's spinner for a few seconds before they appear.
- A `grok -p` inside a Grok terminal reports like the session around it, because nothing in its hooks tells them apart. Its session ID can then replace the real one, and the wrong conversation comes back after a relaunch.
- A `codex exec` inside a Codex terminal may still overwrite the stored session ID, because nothing yet tells it apart from the session. Not tested with a real run.
- Ignoring `claude -p` runs depends on `CLAUDE_CODE_ENTRYPOINT`, read from real hooks in Claude Code 2.1.318. If Claude Code changes it, those runs report again.
- Status without hooks is an estimate. A long silent pause can read as done.
- Once, after Tiri was killed rather than quit, the next launch of a dev copy had no main window until it was quit and opened again. Six later kills and relaunches, by SIGTERM and SIGKILL, couldn't repeat it.
- A tab moved to its own window has no text focus until you click it.
- ⌘K may not survive a reattach: the session helper isn't told, so it may replay what was cleared. Not tested.
- With several cursors, line commands like ⌘/ apply to the newest one and drop the rest.
- On a server, files whose names differ only by case get one place on this Mac, so only the first shows. A toast says so, and terminals see them all.
- Hard-wrap joining for paths is a heuristic, and hasn't been seen against a long real path from Claude.
- Tiri shows `.env` files in the tree like any other file, as Cursor does.
- macOS autocorrect can change words typed in the comment box.
- The first jump to the end of a very long diff lays out everything before it: about a second at 46,000 rows, longer at 180,000.
- A 4.9 MB markdown file with 46,000 headings takes about 3.7 s to build, off the main thread. A 2,000-formula document takes about 1.3 s.

## Decisions: deviations from Cursor

| Cursor | Tiri | Why |
|---|---|---|
| A path that doesn't exist as written does nothing, or errors | Tiri searches the workspace and opens it, or lets you choose | Agents print paths relative to all sorts of places. Stopping you there is the worst outcome |
| ⌘-click in a terminal opens a pinned tab | Opens a Peek | The point of the Peek. `terminal.linkOpens` restores tabs; ⌘⇧-click does it once |
| Opens a second copy in the active group if a file is open elsewhere | Focuses the existing tab, unless you ask for a split | Review-first: one file, one place |
| Split duplicates the editor | Files and web pages duplicate; a terminal starts a new terminal in the same folder | A process can't be in two places |
| ⌘W with nothing open closes the window | Does nothing | Closing the window would stop every terminal in every workspace |
| Bottom terminal panel | None; terminals are tabs | Spec principle 1 |
| Remote-SSH downloads a full server to the host, which shuts down 5 minutes after you disconnect (`remote.SSH.serverShutdownTimeout`) | One static file of about 90 KB and OpenSSH. Programs keep running until their tab closes | An agent's work shouldn't depend on a laptop's lid |
| Deleting moves to the Trash | On a server it deletes, after saying so | There's no Trash there to move it to |
| Opens a terminal in your home folder if no folder is open | Asks for a folder first; first launch starts nothing | An agent started in the wrong folder does real work in the wrong place |
| Root row only with several folders | Always a root row | Spec: one section per folder |
| ⌘K in a terminal clears at once and has no chords | Waits 0.3 s, so ⌘K ⌘\ still splits from a terminal | Splitting from a terminal is common in Tiri |
| `editor.wordWrapColumn` defaults to 80 | 120 | Your Cursor uses bounded at 120 |
| Compact rows let you click a middle segment | Rows act on the deepest folder | Simpler, and it's almost always what's meant |
| Hides nothing but `.git` and `.DS_Store` by default | Also hides `node_modules` and `.build` | Spec §9 |

## Next 5 tasks

1. A real workday with several agents, because nothing here has had one, and fixing what it finds.
2. Patch SwiftTerm so a labelled hyperlink with no scheme can't show "Link blocked", and read link targets directly.
4. Staging and committing from the changes view, if reviewing there makes it wanted.
5. An MCP wrapper around the control API, now that the CLI is stable.
6. Completion on request, from the language server, if real use shows people want it. Snippets and AI ghost text are decided against.
