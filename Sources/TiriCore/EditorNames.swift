import Foundation

/// The `tiri` program under the names other tools start an editor by. Both are links to it in the app.
///   tiri-edit <file>…               what EDITOR is in Tiri's terminals: `tiri open --wait`, one file after another
///   tiri-open <file> [line [col]]   what LAUNCH_EDITOR and REACT_EDITOR are: a dev server's "open in editor"
public enum EditorNames {
    public static let edit = "tiri-edit"
    public static let open = "tiri-open"

    /// The `tiri` command lines a call by one of these names stands for, or nil if it's plain `tiri`.
    public static func commands(invokedAs program: String, arguments: [String]) -> [[String]]? {
        switch (program as NSString).lastPathComponent {
        case edit:
            // vi's `+12 file` is how some programs say where; anything else starting with - or + is for another editor.
            var line: Int?
            var commands: [[String]] = []
            for argument in arguments {
                if argument.hasPrefix("+"), let number = Int(argument.dropFirst()), number > 0 {
                    line = number
                    continue
                }
                if argument.hasPrefix("-") || argument.hasPrefix("+") { continue }
                commands.append(["open", line.map { "\(argument):\($0)" } ?? argument, "--wait"])
                line = nil
            }
            return commands
        case open:
            let words = arguments.filter { !$0.hasPrefix("-") }
            guard let file = words.first else { return [] }
            let numbers = words.dropFirst().prefix(2).compactMap { Int($0) }.filter { $0 > 0 }
            let location = ([file] + numbers.map(String.init)).joined(separator: ":")
            return [["open", location, "--front"]]
        default:
            return nil
        }
    }
}
