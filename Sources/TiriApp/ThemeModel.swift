import AppKit
import TiriCore

/// Themes: which one shows now, bringing them in, and changing their colors, for Settings and `tiri theme` alike.
extension AppModel {
    var allThemes: [Theme] { Theme.builtIns + userThemes }

    func theme(named name: String) -> Theme? {
        allThemes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Which theme shows now: the one for this look, dark or light, high contrast or not.
    func resolveTheme(reload: Bool = true) {
        if reload { userThemes = ThemeLibrary().all() }
        let slot = ThemeSlot.current(dark: effectiveDark, increaseContrast: increaseContrast)
        let chosen = theme(named: settings.themeName(for: slot))
            ?? theme(named: Theme.defaultName(for: slot)) ?? (slot.isDark ? .tiriDark : .tiriLight)
        ThemePalette.increaseContrast = increaseContrast
        activeThemeSlot = slot
        activeTheme = chosen
        // Tiri's own colors in their own look are drawn with the system's colors, exactly as before themes.
        ThemePalette.current = chosen.isTiriStandard && chosen.isDark == effectiveDark ? nil : chosen
    }

    private func repaintForTheme() {
        resolveTheme(reload: false)
        applyTheme()
        reapplyControllerSettings()
    }

    /// Puts a theme in a look's place: the look it suits, unless one is given.
    @discardableResult
    func useTheme(_ name: String, for given: ThemeSlot? = nil) -> String? {
        guard let theme = theme(named: name) else { return "There's no theme called \(name). `tiri theme list` has them." }
        let slot = given ?? ThemeSlot.natural(for: theme)
        if let problem = setSetting(slot.settingKey, to: .string(theme.name)) { return problem }
        // The file is read again in a moment; the screen shouldn't wait for it.
        settings.setThemeName(theme.name, for: slot)
        repaintForTheme()
        return nil
    }

    /// Brings a theme in from a file, as one of this person's own, over an earlier copy of the same one.
    @discardableResult
    func importTheme(from url: URL, named name: String? = nil, use: Bool = true) throws -> Theme {
        var theme = try ThemeImport.read(file: url)
        // The name the other app shows it by, when it came from one.
        if let name { theme.name = name }
        if let builtIn = Theme.builtIns.first(where: { $0.name.caseInsensitiveCompare(theme.name) == .orderedSame }) {
            theme.name = ThemeLibrary().freeName(for: builtIn.name)
        }
        try ThemeLibrary().save(theme)
        userThemes = ThemeLibrary().all()
        if use { useTheme(theme.name) } else { repaintForTheme() }
        return theme
    }

    /// Changes colors of the theme showing now. Tiri's own themes stay as they are: changing one makes a copy,
    /// which takes its place.
    func setThemeColors(_ changes: [(key: String, value: String)]) -> String? {
        var theme = activeTheme
        let library = ThemeLibrary()
        let copying = theme.isBuiltIn
        if copying {
            theme.name = library.freeName(for: theme.name.replacingOccurrences(of: "Tiri ", with: "My "))
            theme.source = "Tiri"
        }
        for change in changes {
            if let problem = theme.set(change.key, to: change.value) { return problem }
        }
        do {
            try library.save(theme)
        } catch {
            return "Couldn't save the theme: \(error.localizedDescription)"
        }
        if let index = userThemes.firstIndex(where: { $0.name == theme.name }) {
            userThemes[index] = theme
        } else {
            userThemes = library.all()
        }
        if copying { return useTheme(theme.name, for: activeThemeSlot) }
        repaintForTheme()
        return nil
    }

    func deleteTheme(_ name: String) -> String? {
        guard let theme = userThemes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return Theme.builtIns.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                ? "\(name) is one of Tiri's own, and stays." : "There's no theme called \(name)."
        }
        do {
            try ThemeLibrary().delete(named: theme.name)
        } catch {
            return "Couldn't delete it: \(error.localizedDescription)"
        }
        userThemes.removeAll { $0.name == theme.name }
        // Any look that used it goes back to Tiri's.
        for slot in ThemeSlot.allCases where settings.themeName(for: slot) == theme.name {
            _ = setSetting(slot.settingKey, to: .string(Theme.defaultName(for: slot)))
            settings.setThemeName(Theme.defaultName(for: slot), for: slot)
        }
        repaintForTheme()
        return nil
    }

    func slots(using name: String) -> [ThemeSlot] {
        ThemeSlot.allCases.filter { settings.themeName(for: $0).caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: `tiri theme`

    func handleThemeRequest(_ method: String, _ args: [String: JSONValue]) throws -> JSONValue {
        func text(_ value: String) -> JSONValue { .object(["text": .string(value)]) }
        switch method {
        case "theme.show":
            var lines = ["\(activeTheme.name), for \(activeThemeSlot.title.lowercased()), showing now"]
            for slot in ThemeSlot.allCases { lines.append("  \(slot.title): \(settings.themeName(for: slot))") }
            lines.append("")
            lines.append("accent \(activeTheme.accent?.rawValue ?? "mac")")
            for key in Theme.colorKeys { lines.append("\(key) \(activeTheme[key] ?? "")") }
            if activeTheme.isBuiltIn { lines.append("\nIt's one of Tiri's own: `tiri theme set` makes a copy and changes that.") }
            return text(lines.joined(separator: "\n"))
        case "theme.list":
            if args["available"]?.boolValue == true {
                let inUse = ThemeDiscovery.inUse()
                let lines = ThemeDiscovery.available().map { found in
                    let look = found.dark.map { $0 ? "dark" : "light" } ?? ""
                    let using = inUse[found.from] == found.name ? "\t(\(found.from) uses it)" : ""
                    return "\(found.name)\t\(found.from)\t\(look)\(using)"
                }
                return text(lines.isEmpty ? "No other app on this Mac has themes Tiri can read. `tiri theme import <file>` takes a Ghostty theme, an .itermcolors file or a VS Code theme." : lines.joined(separator: "\n"))
            }
            let lines = allThemes.map { theme in
                let used = slots(using: theme.name).map { $0.title.lowercased() }
                return "\(theme.name)\t\(theme.isDark ? "dark" : "light")\t\(theme.isBuiltIn ? "Tiri's" : (theme.source ?? "yours"))"
                    + (used.isEmpty ? "" : "\tfor \(used.joined(separator: ", "))")
            }
            return text(lines.joined(separator: "\n"))
        case "theme.use":
            guard let name = args["name"]?.stringValue else { throw ControlHandler.ControlFailure("Which theme?") }
            var slot: ThemeSlot?
            if let raw = args["for"]?.stringValue {
                let wanted = raw.replacingOccurrences(of: "-", with: "").lowercased()
                guard let found = ThemeSlot.allCases.first(where: { $0.rawValue.lowercased() == wanted }) else {
                    throw ControlHandler.ControlFailure("--for is dark, light, high-contrast-dark or high-contrast-light")
                }
                slot = found
            }
            if let problem = useTheme(name, for: slot) { throw ControlHandler.ControlFailure(problem) }
            let chosen = theme(named: name)!
            return text("\(chosen.name) is the \(( slot ?? ThemeSlot.natural(for: chosen)).title.lowercased()) theme now.")
        case "theme.import":
            let use = args["use"]?.boolValue ?? false
            let url: URL
            var shownName: String?
            if let path = args["path"]?.stringValue {
                url = URL(fileURLWithPath: path)
            } else if let name = args["name"]?.stringValue {
                let available = ThemeDiscovery.available()
                guard let found = available.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                    ?? available.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else {
                    throw ControlHandler.ControlFailure("No file or theme on this Mac called \(name). `tiri theme list --available` shows what there is.")
                }
                url = URL(fileURLWithPath: found.path)
                shownName = found.name
            } else {
                throw ControlHandler.ControlFailure("Import what? A file, or a name from `tiri theme list --available`.")
            }
            do {
                let theme = try importTheme(from: url, named: shownName, use: use)
                let slot = ThemeSlot.natural(for: theme)
                return text(use ? "Brought in \(theme.name). It's the \(slot.title.lowercased()) theme now."
                                : "Brought in \(theme.name). `tiri theme use \"\(theme.name)\"` puts it on.")
            } catch let failure as ThemeImport.Failure {
                throw ControlHandler.ControlFailure(failure.description)
            }
        case "theme.set":
            guard case .object(let colors) = args["colors"] else { throw ControlHandler.ControlFailure("Which colors?") }
            let before = activeTheme.name
            if let problem = setThemeColors(colors.sorted { $0.key < $1.key }.map { ($0.key, $0.value.stringValue ?? "") }) {
                throw ControlHandler.ControlFailure(problem)
            }
            return text(before == activeTheme.name ? "Changed \(activeTheme.name)."
                                                    : "\(before) is Tiri's own, so this is a copy: \(activeTheme.name), the \(activeThemeSlot.title.lowercased()) theme now.")
        case "theme.delete":
            guard let name = args["name"]?.stringValue else { throw ControlHandler.ControlFailure("Which theme?") }
            if let problem = deleteTheme(name) { throw ControlHandler.ControlFailure(problem) }
            return text("Deleted \(name).")
        default:
            throw ControlHandler.ControlFailure("Unknown theme command")
        }
    }
}
