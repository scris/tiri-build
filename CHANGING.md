# Changing Tiri

You're in Tiri's own source, for the exact version this person is running. They asked for something to be
different, and you're making it so. `tiri --skill` has the commands, under Change Tiri.

## How it's laid out

| Where | What |
|---|---|
| `Sources/TiriApp/` | The app: SwiftUI and AppKit. `AppModel.swift` holds its state, and most of what follows from a click goes through it. |
| `Sources/TiriCore/` | What needs no window: the workspace model, settings, the CLI, Git, plugins. Unit tested. |
| `Sources/TiriHighlight/` | Colors, from TextMate grammars. |
| `Sources/tiri/` | The `tiri` command, a thin client of `TiriCore`. |
| `Tests/` | `swift test`. |
| `Resources/` | What's copied into the app: grammars, web assets, the icon. |
| `scripts/dev-app.sh` | An invisible copy of Tiri with its own state, which is what checks drive. |

## What people call things

These are the names people use when they ask for a change, and the file to start from.

| They mean | File |
|---|---|
| A tab, the tab bar | `Sources/TiriApp/TabBar.swift` |
| The sidebar: workspaces, agents, open items | `Sources/TiriApp/Sidebar.swift`, `AgentsView.swift` |
| The file tree, the explorer | `Sources/TiriApp/FileTree.swift` |
| Changes, a diff | `Sources/TiriApp/DiffViewer.swift`, `TurnDiffs.swift` |
| A terminal | `Sources/TiriApp/Terminal.swift` |
| A Peek, the floating viewer | `Sources/TiriApp/PeekView.swift` |
| File viewers | `Sources/TiriApp/Viewers.swift`, `RichDocuments.swift` |
| The code editor | `Sources/TiriApp/CodeEditor.swift` |
| Quick open, the command palette | `Sources/TiriApp/Palette.swift` |
| Commands and what `tiri` can ask for | `Sources/TiriApp/Commands.swift` |
| The bar along the bottom | `Sources/TiriApp/StatusBar.swift` |
| Review comments | `Sources/TiriApp/ReviewView.swift` |
| Settings | `Sources/TiriApp/SettingsView.swift`, and `Sources/TiriCore/SettingsSchema.swift` for the rows |
| The start screen, the window's layout | `Sources/TiriApp/RootView.swift` |
| More than one window, each with its own workspace | `Sources/TiriApp/WorkspaceWindows.swift` |

## Off limits

- **`Sources/tiri-session/`.** Agents running right now live under it, and they have to survive the switch to what you build.
- **`Remote/` and `Resources/remote/`.** The helper on servers, in C, built with zig for Linux.
- **Saved data.** Add fields, and never rename or remove one. Plain Tiri has to be able to read what your copy wrote.
- **`Sources/TiriApp/Launch.swift` and `Sources/TiriCore/YourTiri.swift`.** They're how a person gets back from a copy that doesn't work.
- **Anything that needs a provisioning profile or the keychain.** A copy built here can't carry either.

## Write changes that survive

An update replays each change onto the next release, and most of the time nothing has to be done by anyone, if
the change is written for it.

- Put new code in a new file, with a one-line hook in the existing one.
- Add to the end of a list, a struct or a view, not beside lines that change often.
- Don't reformat, rename or tidy anything you didn't have to touch. Each line you leave alone can't conflict.
- Only ever change what was asked for. Each extra thing is one more way to fail later.

## Words on screen

Tiri speaks English, Simplified Chinese and Traditional Chinese. Write new words in English, and add each one to
the end of both `Resources/Localization/zh-Hans.lproj/Localizable.strings` and `zh-Hant.lproj`, in the person's
words if they gave any. `Resources/Localization/README.md` says how, and `swift test --filter LocalizationTests`
says what's missing. Prompts for agents and `tiri` output stay English.

## Checks

Write `checks/<id>.sh`. `tiri change start` tells you the id. It runs with `tiri` on the PATH, talking to a real,
invisible copy of Tiri built from this source with its own state, and `$TIRI_SOURCE` is this folder.
It passes by exiting 0. At every update it runs again, so make it say whether the thing still works:

```sh
#!/bin/bash
set -e
# A unit test, when the logic can be reached without a window.
(cd "$TIRI_SOURCE" && swift test --filter MyNewThingTests)
# Or the real app, through anything the CLI can see.
tiri layout | grep -q '"timer"'
```

A window you can see is out of the question: never raise one, and never click. If the thing can only be judged by
eye, check that the code is reached and say so.

## The fast loop

`tiri change build` builds with optimization in debug, about 5 seconds per edit. `tiri change check` uses that same
build. `tiri change ready` makes the real release build, about 30 seconds after an edit and a minute and a half from
nothing, and that's what they try.
