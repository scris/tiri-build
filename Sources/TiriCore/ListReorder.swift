import Foundation

/// Dragging one row of a list of equal rows to a new place: where it would land, how the rows it
/// passes step aside, and the list afterwards. The sidebar's workspace list uses it.
public enum ListReorder {
    /// The index the row at `from` lands on after being dragged `translation` points down (or up, if negative).
    public static func target(from: Int, translation: Double, rowHeight: Double, count: Int) -> Int {
        guard count > 0, rowHeight > 0 else { return from }
        let steps = Int((translation / rowHeight).rounded())
        return min(max(from + steps, 0), count - 1)
    }

    /// How far the dragged row may travel, so it stays inside the list.
    public static func clamped(translation: Double, from: Int, rowHeight: Double, count: Int) -> Double {
        guard count > 0 else { return 0 }
        return min(max(translation, -Double(from) * rowHeight), Double(count - 1 - from) * rowHeight)
    }

    /// Rows another row steps by while the row at `from` is held over `to`: -1 is up one, 1 is down one.
    public static func shift(of index: Int, from: Int, to: Int) -> Int {
        if index == from { return 0 }
        if from < index, index <= to { return -1 }
        if to <= index, index < from { return 1 }
        return 0
    }

    /// The list with the element at `from` moved so that it ends up at `to`.
    public static func moved<T>(_ list: [T], from: Int, to: Int) -> [T] {
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return list }
        var result = list
        result.insert(result.remove(at: from), at: to)
        return result
    }
}
