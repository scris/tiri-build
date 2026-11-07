# Tiri

**A Mac workspace for coding agents, and the only one you can change by asking.**

![Keep your agent. Get everything around it. A real Tiri window: four workspaces, Grok asking for you in one, Claude Code in Tiri's own source having opened the features page as a Peek: a workspace for each task, not just code, the Peek, your agent drives Tiri, it improves itself. In the corner, the Change Tiri box.](.github/readme/tiri.png)

## Why not something else?

| If you pick | like | you give up |
|---|---|---|
| An AI editor | Cursor, Windsurf, Zed | **Your agent.** Theirs comes first, and yours gets a drawer under the editor. |
| The vendor's app | Claude Code desktop, Codex app | **Every other agent,** and the CLI you set up. |
| An agent manager | Conductor, Superset, Emdash | **Your repo as you use it.** Every job becomes a task in a fresh worktree. |
| A terminal | cmux, Warp, herdr, Ghostty + tmux | **Everything around the agent.** Files and diffs open in another app, paths in its output lead nowhere, and an agent starts wherever your shell happens to be. |

**Tiri gives up none of these.**

## Change anything by asking

Not a setting, and not a plugin API: you change the actual source.

1. Choose **Change Tiri…**, point at anything and say what you want instead.
2. Your own agent edits Tiri's source, on your own subscription.
3. Press **Try It**. Tiri reopens in about half a second, and your agents keep running.
4. Keep the change, or go back in one click.

- **Anything:** layout, behavior, shortcuts, what a button does, or a feature Tiri doesn't have yet.
- **It lasts:** every update keeps your changes. If Tiri ships the same thing, your change retires itself.
- **It's safe:** your agent can build a change, but only you can switch to it. Plain Tiri is always one click away.

## Any path an agent prints opens in place

- **⌘-click a path in agent output,** and the file floats over the session without moving your layout. This is the Peek.
- **Even a wrong path opens.** Tiri finds what the agent meant, or lets you choose.
- **Your agent can open things too.** `tiri open report.md` floats what it made for you to read, and your keyboard stays in the session.
- **Undo or Ask on any change** goes to the agent that made it, typed into its input and waiting for your Return.

## What you keep

- **Your agent, untouched.** It's the real CLI, with your config, hooks and subscription.
- **Any agent.** Claude Code, Codex, Grok, or any command you add.
- **Your muscle memory.** Shortcuts and the explorer work like Cursor and VS Code.
- **Your Git workflow.** Agents work in your repo, and Tiri finds the branches they make.
- **Your servers.** Connect over your own SSH config, with one 90 KB helper and no root.
- **Your setup, for good.** No account, no cloud of ours, and an MPL-2.0 license.

## What you get

- **Every agent at a glance:** what each one is doing, and which one needs you.
- **Files, diffs and pages are tabs**, equal to terminals. There's no terminal drawer.
- **Agents outlive the app.** Quitting, crashing or a dropped server connection doesn't stop them.
- **Folder first:** nothing starts until you say where, so an agent never works in the wrong place.
- **Per-turn diffs** show what one prompt changed.
- **Batched review:** comment across many files, then send everything as one message.
- **⌘L** quotes a selection to your agent, as a real mention in Claude Code.

## What Tiri believes

- **The agent types, and you read and judge.** Everything serves reading first, so there's no AI ghost text.
- **No AI of its own.** Tiri sells nothing, promotes nothing and never nags.
- **People don't operate Git; agents do.** Fetch, pull and push take one click. Anything beyond that is a request to an agent.
- **Nothing goes to an agent without your say-so.** Reviews, Undo and Ask wait in its input until you press Return.
- **Never interrupt.** Alerts never reorder your tabs, and Esc on a Peek never reaches the agent.
- **Whatever you can do, an agent can do** through the `tiri` command.
- **Settings have two ways in: the screen and your agent.** You never edit a JSON file.
- **Don't rebuild the agent.** Skills, hooks and MCP stay with your agent. Plugins only add what a terminal can't draw.
- **Native and fast.** Built in Swift, with no Electron. Features are never dropped for speed.

## When to use something else

- **For cloud sandboxes or a task board**, use an agent manager.
- **If you type code all day**, use an editor. Tiri is built for reading and reviewing.
- **On Windows, Linux or an Intel Mac.** Tiri needs macOS 26 on Apple silicon.

## Install

[Download Tiri](https://tiri.build/download/Tiri.dmg), or use Homebrew:

```sh
brew tap tiri-build/tap
brew install --cask tiri-build/tap/tiri
```

Tiri needs macOS 26 on Apple silicon. Pick an agent and choose a folder. Say yes when Tiri offers to install hooks.

To build it yourself, you need the Command Line Tools (`xcode-select --install`) or Xcode 26:

```sh
./build.sh && open build/Tiri.app
```

## More

- [tiri.build](https://tiri.build) shows Tiri at work.
- [GUIDE.md](GUIDE.md) covers every feature, plus signing and notarized builds.
- `tiri --skill` prints a guide written for agents.
- [CHANGING.md](CHANGING.md) maps the source.

Made by [Tianrun Qiu](https://r-q.name). Tiri is licensed under the [Mozilla Public License 2.0](LICENSE).
