# Progress

Status of the first build against the [spec](https://claude.ai/artifact/KiXf5aQEigev1vNJFeysbb) (v0.3).

All of milestones M0 to M8 are built. The work is one commit, not one per milestone, because the milestones were built together and then hardened by testing; splitting it afterwards would have invented a history.

## How it was tested

- `swift test`: unit tests for the model, path parsing, persistence, import, settings, keybindings, CLI and an in-process control server.
- `scripts/e2e.sh`: drives a real app through every CLI command, with isolated state.
- Real launches, driven with real mouse and keyboard events and checked with window screenshots.
- Real Claude Code sessions in Tiri terminals, in a scratch project: prompts, status, ⌘-clicking its output, relaunch and resume, and a session running a nested `claude -p`, before and after the fix. Codex was launched to confirm its TUI renders, but no session was run.
- Real folders, read-only, at their true paths: `~/ai-hotpoints-2026`, `~/nvcm-agent`, `~/mgx-dev`, `~/Documents/tiri`, and the real `seenot-web.code-workspace` in `~/Documents`, after you allowed access. No prompt appeared.
- Dark mode on every viewer, on a virtual display, with real PDF, PowerPoint, Excel (51 MB) and Word files as temporary copies. Measured brightness in the content area confirms dark, light, and switching live both ways.
- Real project contents, as copies with the same relative layout: `seenot-web.code-workspace` and its three folders, plus Office, PDF, HEIC, video and other files.

### Not verified yet

| What | Why | How to check |
|---|---|---|
| The theme following a live change of the Mac's own appearance | Flipping it would change the whole Mac while it's in use. `"system"` is verified while the Mac stays dark, and `tiri theme` switches live both ways | Change Appearance in System Settings with a PDF open |
| By hand, with the keyboard and mouse in a focused window | Tested on a virtual display without taking your screen, so these never had a real press: Shift+Enter and Option+Enter in Claude Code, ⌘V with a picture or a copied file, drag and drop, the paperclip's picker, ⌘-clicking a path | Try each one once |
| Sessions over days, and across a reboot | Quit and relaunch are tested on a real Claude session. A long run isn't | Use it |
| Your own Install click for hooks | The installer ran through its real yes against an isolated config, and a real Claude session ran with the hooks passed for that session only. Status and session ID both arrived. Your real config waits for your click, because it's yours and a safety hook rightly stops an agent editing it | Settings, Agent Status, Install |
| Resume by session ID on a real session | Depends on the hooks above. `claude --continue` is verified on a real session | Same as above, then relaunch |
| Clicking a native notification | Needs the system permission prompt answered. In-app toasts and badges are verified | Allow notifications, then run `tiri notify done --item <id>` in a terminal in another workspace |
| Codex hooks, and a Codex turn | Its composer is tested with lines and an image, unsent. Hook payloads are tested with documented-format JSON | Settings, Agent Status, then run a session |
| Seeing the folder panel, and a real ⌘-click on a path | Tested without taking your screen: the panel through accessibility, and the click through `tiri follow`, which runs the same code. An unfocused window doesn't draw the panel or take clicks | Open Tiri, press +, choose Claude Code; then ⌘-click a path |
| Ask Claude Code against the real agent | Tested with a stand-in command, to avoid a real session on your account | Press Ask Claude Code on the Settings tab |
| Reduce Transparency, Increase Contrast | Left to the system's glass, as the spec asks, but not exercised | Turn them on in Accessibility settings |
| Terminal translucency setting | Implemented, not looked at | Set `terminal.translucent` |

## What works

- **Workspaces:** create, rename, delete, switch (sidebar and ⌃1…⌃9), add and remove folders, persist and restore, import `.code-workspace`.
- **File tree:** multi-root, lazy, live updates, preview and pinned opens, reveal, context menu, inline new and rename, Trash, Cursor's keys.
- **Terminal:** login shell with your aliases, truecolor, full-screen TUIs, cwd tracking, presets, exit bar with Restart.
- **Peek:** ⌘-click or `tiri open` from a terminal floats a viewer, with Open as Tab, Open to the Side, replace on next click, Esc and click-outside to close.
- **Path links:** existing paths underline on ⌘-hover, VS Code's location formats, soft and hard wrapped paths, directories reveal, web URLs float too.
- **Editing and highlighting:** plain-text editing with save, undo and conflict handling, and highlight.js grammars, bundled and run locally, for common languages.
- **Sessions:** a small background server keeps each terminal's program running while Tiri is closed, and Tiri reattaches. Closing the tab ends it.
- **Agent input:** selections reach Claude Code through its editor protocol. ⌘L, paste, drag and a picker add lines, files and images to Claude Code or Codex.
- **Changes:** a sidebar section and diff items in the main window, live, in tabs and Peeks, with `tiri changes` and `tiri diff`. Read-only: no staging or committing.
- **Path search:** a path that doesn't exist as written is searched for across the workspace's folders, its terminals' folders and its open files. One match opens, several offer a choice, none shows a toast. Never an alert.
- **Tree → terminal:** drag inserts a shell-quoted path.
- **Agent attention:** status on the tab, item list and workspace switcher, toasts, dock badge, jump to next (⌘⇧U), hooks, fallback estimate when there are no hooks.
- **Session restore:** layout, cwd and terminals. Agents resume. Other commands wait typed at the prompt, so nothing like `./deploy.sh` re-runs by itself.
- **Dark mode:** every viewer. PDF, Office, iWork, RTF, font and web archive pages are inverted with their colors kept, with a moon button for true colors. Black artwork on transparency gets a light plate.
- **Viewers:** markdown (rendered and source), code with light highlighting, images (HEIC, GIF), SVG, PDF, audio, video, HTML, CSV and TSV, Office and iWork through Quick Look, Quick Look for everything else. All reload when the file changes.
- **Web:** address bar, back, forward, reload, auto-reload for local files, forced dark.
- **Control API and CLI:** everything in spec §5, plus `send`, `read`, `layout`, `tree`, `commands`, `run`, `perf`, `hook`, `hooks`.
- **Navigation:** quick open, command palette, all §6 keybindings, chords, breadcrumbs, find, tab drag and drop.
- **Settings:** a screen built from one list of settings, and `tiri settings` for agents, with a one-click prompt from the screen to your agent. Keyboard shortcuts too, with `tiri keys`. Nobody needs to touch JSON. The file is only where they're stored.

## What is stubbed or thin

- Find doesn't cover images, video or Quick Look files. Web and markdown find has no match count.
- One main window. Any tab can move to its own window, but a second window can't hold its own workspace. A second instance can't take the control socket and says so.
- `TerminalBackend` and `FileSystemProviding` exist for SSH later, each with only a local implementation.

## Performance (spec §9)

Measured on this Mac (M-series, macOS 27), release build.

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
- A `codex exec` inside a Codex terminal may still overwrite the stored session ID, because nothing yet tells it apart from the session. Not tested with a real run.
- Ignoring `claude -p` runs depends on `CLAUDE_CODE_ENTRYPOINT`, read from real hooks in Claude Code 2.1.318. If Claude Code changes it, those runs report again.
- Status without hooks is an estimate. A long silent pause can read as done.
- Multi-line link context isn't handled, such as a `16:5` under a path line from ripgrep.
- Hard-wrap joining for paths is a heuristic, and hasn't been seen against a long real path from Claude.
- Tiri shows `.env` files in the tree like any other file, as Cursor does.

## Decisions: deviations from Cursor

| Cursor | Tiri | Why |
|---|---|---|
| A path that doesn't exist as written does nothing, or errors | Tiri searches the workspace and opens it, or lets you choose | Agents print paths relative to all sorts of places. Stopping you there is the worst outcome |
| ⌘-click in a terminal opens a pinned tab | Opens a Peek | The point of the Peek. `terminal.linkOpens` restores tabs; ⌘⇧-click does it once |
| Opens a second copy in the active group if a file is open elsewhere | Focuses the existing tab, unless you ask for a split | Review-first: one file, one place |
| Split duplicates the editor | Files and web pages duplicate; a terminal starts a new terminal in the same folder | A process can't be in two places |
| ⌘W with nothing open closes the window | Does nothing | Closing the window would stop every terminal in every workspace |
| Bottom terminal panel | None; terminals are tabs | Spec principle 1 |
| Opens a terminal in your home folder if no folder is open | Asks for a folder first; first launch starts nothing | An agent started in the wrong folder does real work in the wrong place |
| Root row only with several folders | Always a root row | Spec: one section per folder |
| Compact folders on by default | Not implemented | Not in v0.1 scope; see next tasks |
| Quick open searches on spaces as AND | Spaces are ignored | Simpler for now |
| Hides nothing but `.git` and `.DS_Store` by default | Also hides `node_modules` and `.build` | Spec §9 |

## Next 5 tasks

1. A real workday with several agents, because nothing here has had one, and fixing what it finds.
2. Patch SwiftTerm so a labelled hyperlink with no scheme can't show "Link blocked", and read link targets directly.
3. Compact folders in the explorer, and multi-line link context.
4. Staging and committing from the changes view, if reviewing there makes it wanted.
5. An MCP wrapper around the control API, now that the CLI is stable.
