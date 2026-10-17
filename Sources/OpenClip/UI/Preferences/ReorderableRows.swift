// ReorderableRows.swift
// OpenClip
//
// Drag-to-reorder list with a blue insertion bar in the gap under the drag. Stands in for the
// Customize outline (an NSOutlineView that can't live in a Form). Drops land between rows only;
// dropping onto a row would make a group in the outline, which doesn't apply here.

import SwiftUI
import UniformTypeIdentifiers

/// Row frames, keyed by row id, in the list's own coordinate space.
private struct ReorderableRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// `DropDelegate` rather than `dropDestination`: only it reports the drag position continuously.
private struct ReorderableDropDelegate: DropDelegate {
    let isDraggingActive: () -> Bool
    let gapForLocation: (CGPoint) -> Int
    let onGapChanged: (Int?) -> Void
    let onDrop: (Int) -> Bool

    func dropEntered(info: DropInfo) {
        guard isDraggingActive() else { return }
        onGapChanged(gapForLocation(info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isDraggingActive() else { return nil }
        onGapChanged(gapForLocation(info.location))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onGapChanged(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isDraggingActive() else { return false }
        return onDrop(gapForLocation(info.location))
    }
}

@MainActor
struct ReorderableRows<Row: View>: View {
    let ids: [String]
    let dragPreviewTitle: (String) -> String
    /// Gap 0 is above the first row; `ids.count` is below the last.
    let onMove: (String, Int) -> Void
    var dividerInset: CGFloat = 0
    @ViewBuilder let row: (String) -> Row

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var insertionGap: Int?
    /// The row being dragged, captured at drag start so the drop resolves synchronously.
    @State private var draggingID: String?

    private static var coordinateSpace: String { "reorderableRows" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ids, id: \.self) { id in
                row(id)
                    // Whole row is the drag handle (no grip glyph), like the outline.
                    .background(frameReader(for: id))
                    .onDrag {
                        draggingID = id
                        return NSItemProvider(object: id as NSString)
                    } preview: {
                        Text(dragPreviewTitle(id))
                            .font(.system(size: 12, weight: .medium))
                            .padding(6)
                    }

                if id != ids.last {
                    Divider()
                        .padding(.horizontal, dividerInset)
                }
            }
        }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(ReorderableRowFramePreferenceKey.self) { frames in
            MainActor.assumeIsolated { rowFrames = frames }
        }
        .overlay(alignment: .topLeading) { insertionBar }
        .onDrop(of: [.text], delegate: ReorderableDropDelegate(
            isDraggingActive: { draggingID != nil },
            gapForLocation: { location in RowReordering.insertionGap(atY: location.y, rowFrames: orderedFrames) },
            onGapChanged: { gap in insertionGap = gap },
            onDrop: { gap in
                defer {
                    insertionGap = nil
                    draggingID = nil
                }
                guard let draggingID else { return false }
                onMove(draggingID, gap)
                return true
            }
        ))
    }

    /// Reports the row's frame via a clear background, so layout is unaffected.
    private func frameReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ReorderableRowFramePreferenceKey.self,
                value: [id: geo.frame(in: .named(Self.coordinateSpace))]
            )
        }
    }

    /// Row frames in list order; a row that has not reported its frame yet is skipped.
    private var orderedFrames: [CGRect] {
        ids.compactMap { rowFrames[$0] }
    }

    @ViewBuilder
    private var insertionBar: some View {
        if let insertionGap, let y = RowReordering.insertionY(forGap: insertionGap, rowFrames: orderedFrames) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }
}

/// Pure drop arithmetic, kept off the generic `ReorderableRows` so tests needn't name its Row type.
enum RowReordering {
    /// Counts rows whose midpoint the drag has passed, matching AppKit's outline rule.
    static func insertionGap(atY y: CGFloat, rowFrames: [CGRect]) -> Int {
        rowFrames.filter { y > $0.midY }.count
    }

    /// Top edge of the row the gap precedes, or bottom of the last row for the trailing gap.
    static func insertionY(forGap gap: Int, rowFrames: [CGRect]) -> CGFloat? {
        guard let first = rowFrames.first, let last = rowFrames.last else { return nil }
        if gap <= 0 { return first.minY }
        if gap >= rowFrames.count { return last.maxY }
        return rowFrames[gap].minY
    }

    /// Gap is read against the list before the row is lifted out, as `move(fromOffsets:toOffset:)` expects.
    static func reordering(_ ids: [String], moving id: String, toGap gap: Int) -> [String] {
        guard let source = ids.firstIndex(of: id) else { return ids }
        var reordered = ids
        reordered.move(fromOffsets: IndexSet(integer: source), toOffset: max(0, min(gap, ids.count)))
        return reordered
    }
}
