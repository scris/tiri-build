# Tiri in other languages

Tiri's own words come in English, Simplified Chinese (`zh-Hans`) and Traditional Chinese (`zh-Hant`).
Each language is a folder of Apple's plain `.strings` files, copied into the app by `build.sh` and
`scripts/dev-app.sh`. They need nothing beyond the Command Line Tools: no Xcode, no string catalogs.

- `Localizable.strings`: every word on screen. **The key is the English**, so English needs no table.
- `InfoPlist.strings`: what macOS shows from Info.plist, like the reasons in permission prompts.

People pick a language with the `language` setting (General, at the top), or for Tiri alone in System Settings →
General → Language & Region. A change shows after a restart, which Tiri offers.

## What gets translated

Only words people read in Tiri's own interface: menus, the palette, settings, buttons, toasts, alerts, empty
screens, tooltips and accessibility labels.

Never translated, and never wrapped:
- anything an agent or a script reads: `tiri` output, `--skill` and the guides, prompts and notes sent to agents,
  CHANGING.md, plugin docs, JSON, logs;
- names: settings keys, command ids, file names, theme names, agent and tool names, brand names;
- what people wrote: files, terminals, conversations, commit messages.

## In code

- **A literal on screen**: SwiftUI's `Text("…")`, `Button("…")`, `Label("…", systemImage:)`, `.help("…")`,
  `Toggle("…")`, `TextField("…")`, `Menu("…")`, `Section("…")` and `.accessibilityLabel("…")` look themselves up.
  Just add the key to both tables. A brand or symbol that must not be looked up uses `Text(verbatim:)`.
- **A literal that becomes a `String` first** (a toast, an alert, `NSMenuItem`, a model property, a view
  parameter typed `String`): `String(localized: "…")`. `Text(someString)` is never looked up.
- **English that's also a name**: a command's title is how `tiri run` and keybindings know it, and a setting's
  title, explanation and group are what `tiri settings` prints. Those stay English in the data, and the screen
  shows `L10n.display(english)`. Searches match both the shown words and the English.
- **Interpolation becomes a format**: `String(localized: "Open \(name)")` has the key `"Open %@"`. A `String`
  is `%@`, an `Int` `%lld`, a `Double` `%lf`. A translation may reorder them with `%1$@`, `%2$lld`.
- **One sentence, one key.** Don't build sentences from pieces: word order differs. Plural forms in English are
  separate keys (`"1 file"`, `"%lld files"`), both translated.
- **TiriCore** may use `String(localized:)` too. The `tiri` command has no tables beside it, so it stays English.

## Checks

`swift test --filter LocalizationTests` checks that both tables have the same keys with the same formats, that no
key is listed twice, that every literal the code looks up is in them, that every setting and command title is, and
that neither table slips into the other script. `-NSShowNonLocalizedStrings YES` at launch shows any word
missing a translation in capitals.

## Style

- Plain and short, like Apple's own. 你, not 您.
- A space between Chinese and Latin letters or numbers: `在 Finder 中显示`, `3 个文件`.
- Full-width punctuation in Chinese sentences (，。：；？！). Quotes: “…” in zh-Hans, 「…」 in zh-Hant.
  The menu ellipsis stays `…`. Keep ⌘ ⌥ ⇧ symbols, `code`, paths and setting keys exactly.
- Use the words in [GLOSSARY.md](GLOSSARY.md), so the same thing is always called the same.
- zh-Hant is written, not converted character by character from zh-Hans, and uses the words macOS's own zh-Hant
  uses: 檔案, 資料夾, 設定, 終端機, 視窗, 程式碼. Macs set to zh-HK fall back to it.
