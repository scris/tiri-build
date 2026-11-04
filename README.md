# Tiri

A neutral, native macOS workspace for people who do their work through CLI agents like Claude Code and Codex, and use the "IDE" to see, review and organize.

Terminals, files and web previews are equal items in one tab and pane system. There is no bundled AI, and no bottom terminal panel. Your agents can drive the whole app through a local CLI.

## Build and run

Needs macOS 26 or later and Xcode 26 or later.

```sh
./build.sh && open build/Tiri.app
```

This builds `build/Tiri.app` and installs the `tiri` CLI to `~/.local/bin`.

macOS asks for permission the first time Tiri opens something in Documents, Desktop or Downloads, and terminals inside Tiri count as Tiri. An ad-hoc-signed build counts as a new app each time you rebuild, so macOS asks again. To keep your answer across rebuilds, sign with an identity of your own:

```sh
TIRI_SIGN_IDENTITY="Apple Development: you@example.com (ABCDE12345)" ./build.sh
```

## Terminals outlive Tiri

Quit Tiri, update it, or have it crash, and your agents keep working. When it comes back, each terminal reattaches and its screen is redrawn. Closing a terminal's tab is what ends it. A restart of your Mac still ends them, and then agents resume their conversations as before. You can turn this off in Settings, under Agents.

## Give your agent lines, files and images

Select lines in any file. Claude Code sees the selection the way it does in VS Code, because Tiri speaks its editor protocol: its status line shows what you've selected and it can read it. Run `/ide` in Claude if it isn't connected.

Select something in a file, a diff, rendered markdown, an HTML file, a web page or a PDF, and a **Quote in Agent** button appears beside it. It, ⌘L and right-click all do the same thing. With one agent running, your selection goes straight to it. With several, in any workspace, Tiri asks which session should get it, with the one you last used first. Then it moves you there.

Claude Code gets a real mention. Codex gets the path and line range typed in, since it has no editor protocol. From a diff, both get the selected change itself, with its + and − marks, because a removed line isn't in the file any more.

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

Type in any text or code file, and ⌘S saves. A dot on the tab means unsaved changes, and Tiri asks before closing or quitting over them. If an agent changes the file while you're editing, your text stays on screen and Tiri tells you, so nothing is overwritten without you choosing. Editing a Peek makes it a tab. This is for quick fixes, and it's still not a full editor: there's no autocomplete.

## Follow a name

⌘-click a name in a file or a diff, or press F12, to see where it's defined. Holding ⌘ underlines what you can follow. It floats as a Peek, and **Back** (⌃-) returns you to where you were, through as many jumps as you made. ⇧F12 finds everywhere it's used.

With no language server for that file, Tiri searches the workspace, the same way it does for a path. One match opens, several let you choose, and none shows a toast with a way to search. This is a good guess rather than a compiler's answer, and it doesn't need any setup.

## Language servers

Tiri uses the language servers already on your Mac, for TypeScript and JavaScript, Python, Rust, Go, Swift, C and its relatives, Ruby and Lua. None are bundled and there's nothing to configure. Settings shows which it found, and for one it didn't, offers to ask your agent to install it. This is for reading and reviewing: there's no autocomplete, snippets or AI ghost text, and a file in Tiri stays a quick place to fix something.

- ⌘-click, F12 and ⇧F12 ask the server first, and search if it has no answer yet.
- Hold ⌘ over a name for a moment, or press ⌘K ⌘I, to see what it is.
- Errors and warnings are underlined, with a dot beside the line, and counted in the bar along the bottom.
- A diff shows only the errors on lines it added, with **Quote in Agent** to hand them over.
- Claude Code gets them through its editor protocol, so it can see what its own edit broke. Any agent can run `tiri diagnostics`, which checks the files changed since the last commit.

A server starts once you've looked at one of its files for a moment, and stops after 10 minutes unused. They can use a lot of memory, and that's on top of Tiri's own. Some servers run a project's build scripts as they read it, the same as building it would. A server that's inside the project itself, like one in `node_modules/.bin`, is that project's code, so Tiri asks once before running it, and only when you've just asked for something it would answer. Turn all of this off in Settings, under Code.

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

## Start with a folder

Nothing runs until you've said where. A new workspace shows the agents your shell can find: press one, choose its folder, and it starts there. If it can't find any, it links to where to get them, and they appear when you come back. Any other first terminal or agent in a workspace without a folder asks too. In a workspace with several folders, the **+** menu asks which folder a new terminal or agent should use, and ⌃\` uses the folder of what you're looking at.

## The Peek

When you ⌘-click a file in a Claude Code or Codex session, it opens as a floating Peek over the session rather than as a new tab. Your layout doesn't change, and the terminal stays visible beside it.

- ⌘-click the next path to replace it, so you can go through a list of files.
- **Open as Tab** (⌘↩) keeps it. **Open to the Side** (⌥⌘↩) puts it in a split.
- Esc, or clicking outside it, closes it and returns you to the terminal.
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

`tiri` works in every terminal inside Tiri. To use it in your other terminals, go to Settings, Command Line, and press Install. That adds a link at `~/.local/bin/tiri`, which keeps working when the app updates. If your shell doesn't look there, Tiri gives you the line to add.

## Show agent status

Hooks tell Tiri exactly when an agent is working, waiting for you or done, and let it resume exactly the right conversation after a relaunch. The status shows on the tab, in the item list and on the workspace switcher, and you get a notification if you aren't looking at that terminal.

Without hooks, Tiri estimates status from terminal activity, which is less precise.

A `claude -p` run doesn't report, whether a session or a script started it, so it can't change the tab's status or which conversation comes back after a relaunch. Neither can one agent running inside another's terminal.

**Turning them on:** Settings has an Agent Status section with an Install button for Claude Code and Codex, and Tiri offers the first time it sees one run. Your agent can start it too, with `tiri hooks install claude`. Either way Tiri shows what it will add and waits for your yes. It keeps your other hooks and settings, leaves a copy of the file next to it, and can remove its entries again.

Outside Tiri these hooks do nothing and print nothing, so they're safe to leave on. Codex asks you to trust hooks once, in `/hooks`.

## Dark mode

Choose Dark in Settings, or leave it on System while your Mac is dark, and everything follows, live: the app, terminals, code, markdown, web pages and media.

PDF, Office, iWork, RTF, font and web archive previews have no dark mode of their own, so Tiri shows their pages inverted, with colors kept. A photo in a document inverts too, so the moon button above the file shows its true colors, and Tiri remembers that for the item. `tiri web-dark on|off <item-id>` does the same. To keep all documents in true colors, turn off Darken documents in Settings.

Black artwork on a transparent background, in a PNG or SVG, gets a light plate behind it so it stays visible.

## Settings

There are two ways to change a setting, and neither involves a file.

**The screen:** ⌘, opens Settings as a tab, with every setting explained. Changes apply immediately. Right-click a setting to reset it.

**Your AI:** the top of that screen has a prompt ready to send. **Ask Claude Code** or **Ask Codex** hands it to your agent, which can then explain any setting in plain words and change it for you. Agents use `tiri settings`:

```sh
tiri settings explain              # every setting, its value and what it does
tiri settings set code.wordWrap on
```

Keyboard shortcuts work the same way. They're on that screen, where you click a shortcut and press the keys, and your agent can change them with `tiri keys`.

## Development

```sh
swift test          # unit tests and an in-process control server test
scripts/e2e.sh      # drives a real app through every CLI command, with isolated state
```

`TiriCore` holds the models, persistence, path parsing, workspace import and control protocol, with no UI. `TiriApp` is the SwiftUI and AppKit app. `tiri` is the CLI. See [PROGRESS.md](PROGRESS.md) for current status.
