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

## Start with a folder

Nothing runs until you've said where. A new workspace asks for its folder first, and so does the first terminal or agent in a workspace without one. In a workspace with several folders, the **+** menu asks which folder a new terminal or agent should use, and ⌃\` uses the folder of what you're looking at.

## The Peek

When you ⌘-click a file in a Claude Code or Codex session, it opens as a floating Peek over the session rather than as a new tab. Your layout doesn't change, and the terminal stays visible beside it.

- ⌘-click the next path to replace it, so you can go through a list of files.
- **Open as Tab** (⌘↩) keeps it. **Open to the Side** (⌥⌘↩) puts it in a split.
- Esc, or clicking outside it, closes it and returns you to the terminal.
- ⌘⇧-click skips the Peek and opens a tab.

When an agent runs `tiri open report.md` in a Tiri terminal, the file floats the same way, and the keyboard stays in the session. Set `"terminal.linkOpens"` to `"tab"` or `"external"` to change what ⌘-click does.

## Everyday use

Shortcuts follow Cursor. All of them can be changed in `keybindings.json`.

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
| Find in the current item | ⌘F |
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
tiri theme dark
```

Run `tiri --help` for all commands, or `tiri --skill` for a guide written for agents. Terminals inside Tiri have `TIRI_SOCKET`, `TIRI_WORKSPACE` and `TIRI_ITEM_ID` set.

## Show agent status

Hooks tell Tiri exactly when an agent is working, waiting for you or done, and let it resume exactly the right conversation after a relaunch. The status shows on the tab, in the item list and on the workspace switcher, and you get a notification if you aren't looking at that terminal.

Without hooks, Tiri estimates status from terminal activity, which is less precise.

**Claude Code:** print the config and add it to `~/.claude/settings.json`:

```sh
tiri hooks claude
```

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }],
    "StopFailure": [{ "hooks": [{ "type": "command", "async": true, "command": "tiri hook claude" }] }]
  }
}
```

Outside Tiri these hooks do nothing and print nothing, so they're safe to leave on.

**Codex:** `tiri hooks codex` prints the config for `~/.codex/config.toml`. Codex asks you to trust hooks once, in `/hooks`.

## Dark mode

Set `"theme"` to `"dark"`, or leave it on `"system"` while your Mac is dark, and everything follows, live: the app, terminals, code, markdown, web pages and media.

PDF, Office, iWork, RTF, font and web archive previews have no dark mode of their own, so Tiri shows their pages inverted, with colors kept. A photo in a document inverts too, so the moon button above the file shows its true colors, and Tiri remembers that for the item. `tiri web-dark on|off <item-id>` does the same. To keep all documents in true colors, set `"documents.forceDark": false`.

Black artwork on a transparent background, in a PNG or SVG, gets a light plate behind it so it stays visible.

## Settings

There are two ways to change a setting, and neither involves a file.

**The screen:** ⌘, opens Settings as a tab, with every setting explained. Changes apply immediately. Right-click a setting to reset it.

**Your AI:** the top of that screen has a prompt ready to send. **Ask Claude Code** or **Ask Codex** hands it to your agent, which can then explain any setting in plain words and change it for you. Agents use `tiri settings`:

```sh
tiri settings explain              # every setting, its value and what it does
tiri settings set code.wordWrap on
```

Keyboard shortcuts are still in `~/.config/tiri/keybindings.json`, in the same shape as Cursor's.

## Development

```sh
swift test          # unit tests and an in-process control server test
scripts/e2e.sh      # drives a real app through every CLI command, with isolated state
```

`TiriCore` holds the models, persistence, path parsing, workspace import and control protocol, with no UI. `TiriApp` is the SwiftUI and AppKit app. `tiri` is the CLI. See [PROGRESS.md](PROGRESS.md) for current status.
