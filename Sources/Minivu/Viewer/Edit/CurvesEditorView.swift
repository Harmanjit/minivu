import SwiftUI
import MinivuRender

/// The Curves inspector: channel picker, the curve over a faint histogram,
/// and the selected point's numbers.
struct CurvesInspectorView: View {
    @Bindable var state: CurvesToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                Picker("Channel", selection: $state.channel) {
                    ForEach(ToneChannel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: state.channel) { state.selectedIndex = nil }
                CurvesEditorView(state: state)
                    .frame(maxWidth: .infinity)
                if let index = state.selectedIndex, state.points.indices.contains(index) {
                    let p = state.points[index]
                    LabeledContent("Input / Output") {
                        Text(verbatim: "\(Int((p.x * 255).rounded())) / \(Int((p.y * 255).rounded()))").monospacedDigit()
                    }
                }
            } footer: {
                InspectorFootnote("Click to add a point. Drag a point off the grid or double-click it to remove it.")
            }
        }
    }
}

/// A 256 pt square: grid, the identity diagonal, the curve sampled from
/// `ToneCurves.lookupTable` (what the renderer's tone table is built from),
/// and its control points.
///
/// One drag gesture does everything: a press near a point picks it up, a
/// press elsewhere adds one, dragging moves it between its neighbours, and
/// letting go off the grid removes it.
struct CurvesEditorView: View {
    @Bindable var state: CurvesToolState
    static let side: CGFloat = 256
    /// Room around the grid, so points at the corners draw whole.
    static let inset: CGFloat = 6
    /// Points are picked up within this distance, in points.
    static let hitRadius: CGFloat = 9

    @State private var dragIndex: Int?
    @State private var draggedOut = false

    var body: some View {
        Canvas { context, _ in
            context.translateBy(x: Self.inset, y: Self.inset)
            draw(in: &context, size: CGSize(width: Self.side, height: Self.side))
        }
        .frame(width: Self.side + 2 * Self.inset, height: Self.side + 2 * Self.inset)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged(dragChanged)
            .onEnded(dragEnded))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            let location = unit(value.location)
            let tolerance = Double(Self.hitRadius / Self.side)
            guard let index = CurveEditing.hitIndex(state.points, at: location, tolerance: tolerance) else { return }
            state.edit { _ = CurveEditing.remove(index, from: &$0) }
            state.selectedIndex = nil
        })
        .accessibilityLabel("Curve for \(state.channel.title)")
    }

    private func unit(_ location: CGPoint) -> CurvePoint {
        CurvePoint(x: Double((location.x - Self.inset) / Self.side), y: Double(1 - (location.y - Self.inset) / Self.side))
    }

    private func dragChanged(_ value: DragGesture.Value) {
        let location = unit(value.location)
        if dragIndex == nil {
            let start = unit(value.startLocation)
            let tolerance = Double(Self.hitRadius / Self.side)
            if let hit = CurveEditing.hitIndex(state.points, at: start, tolerance: tolerance) {
                dragIndex = hit
            } else {
                var inserted: Int?
                state.edit { inserted = CurveEditing.insert(start, into: &$0) }
                dragIndex = inserted
            }
            state.selectedIndex = dragIndex
        }
        guard let index = dragIndex else { return }
        draggedOut = !CurveEditing.isEndpoint(index, in: state.points) && CurveEditing.isDraggedOut(location)
        state.edit { CurveEditing.move(index, to: location, in: &$0) }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        if let index = dragIndex, draggedOut {
            state.edit { _ = CurveEditing.remove(index, from: &$0) }
            state.selectedIndex = nil
        }
        dragIndex = nil
        draggedOut = false
    }

    private var channelColor: Color {
        switch state.channel {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.18)))

        if let bins = state.histogram?.bins(for: state.channel) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                let x = CGFloat(i) / 255 * size.width
                path.addLine(to: CGPoint(x: x, y: size.height - CGFloat(v) * size.height * 0.9))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(channelColor.opacity(0.14)))
        }

        var grid = Path()
        for i in 1..<4 {
            let t = CGFloat(i) / 4
            grid.move(to: CGPoint(x: t * size.width, y: 0))
            grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
            grid.move(to: CGPoint(x: 0, y: t * size.height))
            grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)

        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height))
        diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        let table = state.curves.lookupTable(size: 256)[state.channel.rawValue]
        var curve = Path()
        for (i, v) in table.enumerated() {
            let point = CGPoint(x: CGFloat(i) / 255 * size.width, y: (1 - CGFloat(v)) * size.height)
            if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(channelColor), lineWidth: 1.5)

        for (i, p) in state.points.enumerated() {
            let center = CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
            let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            if i == state.selectedIndex {
                context.fill(dot, with: .color(channelColor))
            } else {
                context.fill(dot, with: .color(Color(nsColor: .controlBackgroundColor)))
                context.stroke(dot, with: .color(channelColor), lineWidth: 1.5)
            }
        }
    }
}
