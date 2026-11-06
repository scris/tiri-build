import Foundation

/// Claude Code's settings changed by editing only Tiri's entries in the text, so the rest of the
/// file reads exactly as its owner wrote it. Whatever comes out has to mean what re-writing the
/// whole file would have meant, or the edit isn't used.
extension AgentHooks {
    /// The edit's text if it parses to `expected`, otherwise nil.
    static func edited(_ text: String, becoming expected: [String: Any], by edit: () throws -> String) -> String? {
        guard let result = try? edit(),
              let parsed = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              NSDictionary(dictionary: parsed).isEqual(to: expected) else { return nil }
        return result
    }

    private static var claudeEntry: JSONTextEdit.Value {
        .object([("hooks", .array([.object([("type", .string("command")), ("command", .string(claudeCommand)), ("async", .bool(true))])]))])
    }

    private static func isTiris(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains("tiri hook claude") == true
    }

    static func claudeInstallingByEdit(in text: String, original: [String: Any]) throws -> String {
        let document = try JSONTextEdit.Document(text)
        guard let hooksNode = document.root.member("hooks") else {
            let hooks = JSONTextEdit.Value.object(claudeEvents.map { ($0, .array([claudeEntry])) })
            return try document.applying([document.appending([("hooks", hooks)], to: document.root)])
        }
        guard hooksNode.kind == .object, let hooks = original["hooks"] as? [String: Any] else { throw JSONTextEdit.Malformed() }
        var edits: [JSONTextEdit.Edit] = []
        var missing: [(key: String?, value: JSONTextEdit.Value)] = []
        for event in claudeEvents {
            guard let node = hooksNode.member(event) else {
                missing.append((event, .array([claudeEntry])))
                continue
            }
            guard node.kind == .array, let entries = hooks[event] as? [[String: Any]] else { throw JSONTextEdit.Malformed() }
            let present = entries.contains { ($0["hooks"] as? [[String: Any]])?.contains(where: isTiris) == true }
            if !present { edits.append(document.appending([(nil, claudeEntry)], to: node)) }
        }
        if !missing.isEmpty { edits.append(document.appending(missing, to: hooksNode)) }
        return try document.applying(edits)
    }

    static func claudeRemovingByEdit(from text: String, original: [String: Any]) throws -> String {
        let document = try JSONTextEdit.Document(text)
        guard let hooks = original["hooks"] as? [String: Any], let hooksIndex = document.root.memberIndex("hooks") else { return text }
        let hooksNode = document.root.members[hooksIndex].value
        guard hooksNode.kind == .object else { throw JSONTextEdit.Malformed() }
        var removedEvents: Set<Int> = []
        var edits: [JSONTextEdit.Edit] = []
        for (index, member) in hooksNode.members.enumerated() {
            guard let entries = hooks[member.key] as? [[String: Any]] else { continue }
            let entriesNode = member.value
            guard entriesNode.kind == .array, entriesNode.elements.count == entries.count else { throw JSONTextEdit.Malformed() }
            var removedEntries: Set<Int> = []
            var inside: [JSONTextEdit.Edit] = []
            for (entryIndex, entry) in entries.enumerated() {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                let matched = Set(inner.indices.filter { isTiris(inner[$0]) })
                if matched.isEmpty { continue }
                if matched.count == inner.count {
                    removedEntries.insert(entryIndex)
                    continue
                }
                guard let innerNode = entriesNode.elements[entryIndex].member("hooks"), innerNode.kind == .array,
                      innerNode.elements.count == inner.count else { throw JSONTextEdit.Malformed() }
                inside += document.removing(matched, from: innerNode)
            }
            // An event left with nothing goes, as it would from the whole file.
            if removedEntries.count == entries.count {
                removedEvents.insert(index)
            } else {
                edits += inside
                if !removedEntries.isEmpty { edits += document.removing(removedEntries, from: entriesNode) }
            }
        }
        guard removedEvents.count < hooksNode.members.count else {
            return try document.applying(document.removing([hooksIndex], from: document.root))
        }
        if !removedEvents.isEmpty { edits += document.removing(removedEvents, from: hooksNode) }
        return try document.applying(edits)
    }
}
