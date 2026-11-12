import Testing
@testable import TiriCore

struct ListReorderTests {
    @Test func whereItLands() {
        #expect(ListReorder.target(from: 1, translation: 0, rowHeight: 29, count: 4) == 1)
        #expect(ListReorder.target(from: 1, translation: 10, rowHeight: 29, count: 4) == 1)
        #expect(ListReorder.target(from: 1, translation: 16, rowHeight: 29, count: 4) == 2)
        #expect(ListReorder.target(from: 1, translation: 58, rowHeight: 29, count: 4) == 3)
        #expect(ListReorder.target(from: 1, translation: 500, rowHeight: 29, count: 4) == 3)
        #expect(ListReorder.target(from: 1, translation: -20, rowHeight: 29, count: 4) == 0)
        #expect(ListReorder.target(from: 1, translation: -500, rowHeight: 29, count: 4) == 0)
        #expect(ListReorder.target(from: 0, translation: 40, rowHeight: 29, count: 1) == 0)
    }

    @Test func staysInTheList() {
        #expect(ListReorder.clamped(translation: 500, from: 1, rowHeight: 29, count: 4) == 58)
        #expect(ListReorder.clamped(translation: -500, from: 1, rowHeight: 29, count: 4) == -29)
        #expect(ListReorder.clamped(translation: 12, from: 1, rowHeight: 29, count: 4) == 12)
    }

    @Test func othersStepAside() {
        // Dragging row 0 down to 2: rows 1 and 2 move up.
        #expect((0..<4).map { ListReorder.shift(of: $0, from: 0, to: 2) } == [0, -1, -1, 0])
        // Dragging row 3 up to 1: rows 1 and 2 move down.
        #expect((0..<4).map { ListReorder.shift(of: $0, from: 3, to: 1) } == [0, 1, 1, 0])
        #expect((0..<4).map { ListReorder.shift(of: $0, from: 2, to: 2) } == [0, 0, 0, 0])
    }

    @Test func theListAfterwards() {
        #expect(ListReorder.moved(["a", "b", "c", "d"], from: 0, to: 2) == ["b", "c", "a", "d"])
        #expect(ListReorder.moved(["a", "b", "c", "d"], from: 3, to: 0) == ["d", "a", "b", "c"])
        #expect(ListReorder.moved(["a", "b", "c", "d"], from: 1, to: 1) == ["a", "b", "c", "d"])
        #expect(ListReorder.moved(["a", "b"], from: 0, to: 5) == ["a", "b"])
    }
}
