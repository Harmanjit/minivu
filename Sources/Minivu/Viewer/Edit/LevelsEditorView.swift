import SwiftUI
import MinivuRender

/// The Levels inspector: channel, histogram with the three input handles,
/// the output range, and the numbers for all five.
struct LevelsInspectorView: View {
    @Bindable var state: LevelsToolState
    let actions: InspectorActions

    var body: some View {
        ToolInspector(title: state.title, actions: actions) {
            Section {
                Picker("Channel", selection: $state.channel) {
                    ForEach(ToneChannel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LevelsEditorView(state: state)
                    .frame(maxWidth: .infinity)
            }
            Section("Input") {
                levelField("Black", value: state.current.inputBlack) { v in
                    state.edit { LevelsMath.setInputBlack(v, in: &$0) }
                }
                LabeledContent("Gamma") {
                    TextField("Gamma", value: Binding(get: { state.current.gamma }, set: { v in
                        state.edit { $0.gamma = LevelsMath.clampGamma(v) }
                    }), format: .number.precision(.fractionLength(2)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 58)
                }
                levelField("White", value: state.current.inputWhite) { v in
                    state.edit { LevelsMath.setInputWhite(v, in: &$0) }
                }
            }
            Section("Output") {
                levelField("Black", value: state.current.outputBlack) { v in
                    state.edit { LevelsMath.setOutput(black: v, in: &$0) }
                }
                levelField("White", value: state.current.outputWhite) { v in
                    state.edit { LevelsMath.setOutput(white: v, in: &$0) }
                }
            }
        }
    }

    /// A 0...255 field for a 0...1 level.
    private func levelField(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { Int((value * 255).rounded()) }, set: { set(Double($0) / 255) }),
                      format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 58)
        }
    }
}

/// Histogram with draggable black, midtone and white input handles, and
/// below it a grey ramp with the two output handles.
struct LevelsEditorView: View {
    @Bindable var state: LevelsToolState
    static let width: CGFloat = 256
    static let histogramHeight: CGFloat = 110
    static let handleSize: CGFloat = 11

    private enum Handle { case black, gamma, white, outputBlack, outputWhite }
    @State private var dragging: Handle?

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in drawHistogram(in: &context, size: size) }
                .frame(width: Self.width, height: Self.histogramHeight)
            Canvas { context, size in
                let c = state.current
                drawHandle(in: &context, x: c.inputBlack * size.width, fill: .black)
                drawHandle(in: &context, x: LevelsMath.gammaPosition(c) * size.width, fill: .gray)
                drawHandle(in: &context, x: c.inputWhite * size.width, fill: .white)
            }
            .frame(width: Self.width + Self.handleSize, height: Self.handleSize + 2)
            .contentShape(Rectangle())
            .gesture(drag(input: true))

            Canvas { context, size in
                let ramp = CGRect(x: Self.handleSize / 2, y: 0, width: Self.width, height: 10)
                context.fill(Path(roundedRect: ramp, cornerRadius: 2),
                             with: .linearGradient(Gradient(colors: [.black, .white]),
                                                   startPoint: CGPoint(x: ramp.minX, y: 0),
                                                   endPoint: CGPoint(x: ramp.maxX, y: 0)))
                context.stroke(Path(roundedRect: ramp, cornerRadius: 2), with: .color(.secondary.opacity(0.5)), lineWidth: 0.5)
                let c = state.current
                var handles = context
                handles.translateBy(x: 0, y: 12)
                drawHandle(in: &handles, x: c.outputBlack * Self.width, fill: .black)
                drawHandle(in: &handles, x: c.outputWhite * Self.width, fill: .white)
            }
            .frame(width: Self.width + Self.handleSize, height: 12 + Self.handleSize + 2)
            .contentShape(Rectangle())
            .gesture(drag(input: false))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Levels for \(state.channel.title)")
    }

    private func drag(input: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let x = Double((value.location.x - Self.handleSize / 2) / Self.width)
                let c = state.current
                if dragging == nil {
                    let startX = Double((value.startLocation.x - Self.handleSize / 2) / Self.width)
                    let candidates: [(Handle, Double)] = input
                        ? [(.black, c.inputBlack), (.gamma, LevelsMath.gammaPosition(c)), (.white, c.inputWhite)]
                        : [(.outputBlack, c.outputBlack), (.outputWhite, c.outputWhite)]
                    dragging = candidates.min { abs($0.1 - startX) < abs($1.1 - startX) }?.0
                }
                switch dragging {
                case .black: state.edit { LevelsMath.setInputBlack(x, in: &$0) }
                case .white: state.edit { LevelsMath.setInputWhite(x, in: &$0) }
                case .gamma: state.edit { $0.gamma = LevelsMath.gamma(forPosition: x, in: $0) }
                case .outputBlack: state.edit { LevelsMath.setOutput(black: x, in: &$0) }
                case .outputWhite: state.edit { LevelsMath.setOutput(white: x, in: &$0) }
                case nil: break
                }
            }
            .onEnded { _ in dragging = nil }
    }

    private func drawHandle(in context: inout GraphicsContext, x: Double, fill: Color) {
        let cx = CGFloat(x) + Self.handleSize / 2
        var triangle = Path()
        triangle.move(to: CGPoint(x: cx, y: 1))
        triangle.addLine(to: CGPoint(x: cx + Self.handleSize / 2, y: Self.handleSize))
        triangle.addLine(to: CGPoint(x: cx - Self.handleSize / 2, y: Self.handleSize))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(fill))
        context.stroke(triangle, with: .color(.secondary), lineWidth: 0.75)
    }

    private func drawHistogram(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.18)))
        let color: Color = switch state.channel {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
        if let bins = state.histogram?.bins(for: state.channel) {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                path.addLine(to: CGPoint(x: CGFloat(i) / 255 * size.width, y: size.height - CGFloat(v) * size.height * 0.92))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(0.45)))
        }
        // The clipped ranges outside the input handles, dimmed.
        let c = state.current
        context.fill(Path(CGRect(x: 0, y: 0, width: c.inputBlack * size.width, height: size.height)),
                     with: .color(.black.opacity(0.25)))
        context.fill(Path(CGRect(x: c.inputWhite * size.width, y: 0, width: (1 - c.inputWhite) * size.width,
                                 height: size.height)), with: .color(.black.opacity(0.25)))
    }
}
