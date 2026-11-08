import Foundation

/// The language of Tiri's own words: menus, settings, buttons, messages. People's files, terminals and what
/// agents say are never translated, and neither is anything meant for agents or scripts: `tiri` output, the
/// guides, prompts, settings keys and command names stay in English. Resources/Localization/README.md has the rest.
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    /// The Mac's language, or the one chosen for Tiri in System Settings → General → Language & Region.
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    /// Each language in itself, so someone who can't read the one Tiri is in can still find theirs.
    public var nativeName: String {
        switch self {
        case .system: String(localized: "System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }

    /// The setting's values, as `tiri settings` and settings.json spell them.
    public static var settingValues: String { allCases.map { "\"\($0.rawValue)\"" }.formatted(.list(type: .or)) }

    /// Marks an AppleLanguages that Tiri wrote, so "system" takes away only that, and not one chosen in
    /// System Settings, which writes to the same place.
    static let ownKey = "TiriSetAppleLanguages"

    /// The first thing a launch does, before anything looks up a word: Foundation reads the language once.
    public static func applyAtLaunch(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        if language == .system {
            if defaults.bool(forKey: ownKey) {
                defaults.removeObject(forKey: "AppleLanguages")
                defaults.removeObject(forKey: ownKey)
            }
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
            defaults.set(true, forKey: ownKey)
        }
        launched = language
    }

    /// What this launch was started in. A change to the setting shows after a restart.
    public nonisolated(unsafe) private(set) static var launched: AppLanguage = .system

    /// The language from settings.json, read the cheap way at launch, before the settings store exists.
    public static func fromSettingsFile(_ url: URL) -> AppLanguage {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let settings = try? TiriSettings.parse(text) else { return .system }
        return settings.language
    }

    /// The bundle of one language's words, to say something in a language other than the one this launch
    /// is in, like the offer to restart in the language just chosen. Nil for system or English.
    public func bundle(in main: Bundle = .main) -> Bundle? {
        guard self != .system, self != .english,
              let path = main.path(forResource: rawValue, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// `key` in this language, or the English it is if this language doesn't have it.
    public func localized(_ key: String, in main: Bundle = .main) -> String {
        bundle(in: main)?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

/// Words that are English everywhere but the screen. A command's title is also how `tiri run` and the
/// keybindings file know it, and a setting's title is what `tiri settings` prints, so they stay English in
/// the code and get their words only where people see them: `L10n.display(command.title)`.
public enum L10n {
    /// In the language Tiri is in, or as it is when there's nothing for it. The `tiri` command has no
    /// tables beside it, so it always gets the English.
    public static func display(_ english: String) -> String {
        english.isEmpty ? english : Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }

    /// The locale of the words on screen, for lists and dates that sit inside them. The Mac's own can be in
    /// another language than Tiri is. English, and the `tiri` command, which has no tables, keep the Mac's.
    public static var locale: Locale {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return language == "en" ? .current : Locale(identifier: language)
    }

    /// "HTML and CSS", or "HTML 和 CSS".
    public static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        let list = formatter.string(from: items) ?? items.joined(separator: ", ")
        // Foundation's Chinese list is "HTML和CSS": Tiri's Chinese puts a space between Chinese and Latin.
        return locale.identifier.hasPrefix("zh") ? spaced(list) : list
    }

    /// A space between Chinese and Latin letters or numbers, as Tiri's Chinese always has: "JSON 和 CSS".
    public static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: #"(\p{Han})([A-Za-z0-9.#+])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z0-9+#])(\p{Han})"#, with: "$1 $2", options: .regularExpression)
    }

    /// Sentences one after another: "For .go files. To install it: …", but no space after Chinese's "。".
    public static func sentences(_ parts: [String]) -> String {
        parts.reduce("") { text, part in
            guard let last = text.last else { return part }
            return text + ("。！？：；）」”".contains(last) ? "" : " ") + part
        }
    }
}
