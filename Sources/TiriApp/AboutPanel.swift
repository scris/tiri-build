import AppKit

/// The standard About panel, with credits: who made Tiri (linked to r-q.name), its website and its source,
/// the same as the footer of tiri.build.
@MainActor
enum AboutPanel {
    static let authorName = "Tianrun Qiu"
    /// Tagged, since a link opened from an app carries no referrer for the site to see.
    static let authorURL = URL(string: "https://r-q.name/?ref=tiri-app")!
    static let websiteURL = URL(string: "https://tiri.build")!
    static let sourceURL = URL(string: "https://github.com/tiri-build/tiri")!

    /// The bundle's name, so a personal copy reads as itself.
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Tiri"
    }

    /// Opens the panel. It doesn't activate Tiri: the menu or palette that calls this is already in front,
    /// and an agent running `tiri run about` mustn't pull Tiri in front of whatever the person is doing.
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    /// "A Mac workspace for coding agents." / "Made by Tianrun Qiu" / "tiri.build · GitHub" / the licence, centred.
    static func credits() -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ]
        let note: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ]
        func text(_ string: String, _ attributes: [NSAttributedString.Key: Any] = body) -> NSAttributedString {
            NSAttributedString(string: string, attributes: attributes)
        }
        func link(_ string: String, _ url: URL) -> NSAttributedString {
            var attributes = body
            attributes[.link] = url
            return NSAttributedString(string: string, attributes: attributes)
        }

        let out = NSMutableAttributedString()
        out.append(text(String(localized: "A Mac workspace for coding agents.") + "\n", note))
        // One sentence, with the name linked wherever the language puts it.
        let made = NSMutableAttributedString(attributedString: text(String(localized: "Made by \(authorName)")))
        let name = (made.string as NSString).range(of: authorName)
        if name.location != NSNotFound { made.addAttribute(.link, value: authorURL, range: name) }
        out.append(made)
        out.append(text("\n"))
        out.append(link("tiri.build", websiteURL))
        out.append(text(" · "))
        out.append(link("GitHub", sourceURL))
        out.append(text("\n"))
        out.append(text(String(localized: "Free and open source under MPL-2.0."), note))
        return out
    }
}
