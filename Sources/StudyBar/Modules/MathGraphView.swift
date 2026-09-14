import SwiftUI

/// The 2D graphing tab: curves drawn into a `Canvas`, panned by dragging and zoomed by
/// scrolling, with a trace readout under the cursor.
///
/// Not Swift Charts. That draws a series of data points; this resamples a function every time
/// the viewport moves, has to break a line at a pole, and needs the cursor's x to mean something
/// in the plane. One `Canvas` pass, no view identity per point.
struct MathGraphView: View {
    @ObservedObject var model: GraphModel
    @State private var traceX: Double?
    /// Where the drag started, in plane coordinates — panning holds that point under the mouse.
    @State private var dragAnchor: (point: CGPoint, viewport: Viewport)?

    var body: some View {
        VStack(spacing: 0) {
            plot
            Divider()
            controls
        }
    }

    // MARK: - Plot

    private var plot: some View {
        GeometryReader { geo in
            let size = geo.size
            // One plane-unit is the same length on both axes, so a circle looks round and the
            // slope a student reads off the screen is the slope the function has.
            let v = model.viewport.squared(forAspect: size.width / max(size.height, 1))

            Canvas { ctx, _ in
                draw(ctx, viewport: v, size: size)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragAnchor == nil { dragAnchor = (g.startLocation, model.viewport) }
                        guard let anchor = dragAnchor else { return }
                        let dx = (g.location.x - anchor.point.x) / size.width * v.width
                        let dy = (g.location.y - anchor.point.y) / size.height * v.height
                        // Drag right → the plane moves right → the window moves left.
                        model.viewport = anchor.viewport.panned(dx: -dx, dy: dy)
                    }
                    .onEnded { _ in dragAnchor = nil }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): traceX = v.x(atPixel: p.x, width: size.width)
                case .ended:         traceX = nil
                }
            }
            .overlay(alignment: .topLeading) { traceReadout(v) }
            .overlay(alignment: .topTrailing) { zoomControls }
        }
        .frame(minHeight: 220)
    }

    private func draw(_ ctx: GraphicsContext, viewport v: Viewport, size: CGSize) {
        let w = size.width, h = size.height
        let xStep = PlotMath.niceStep(range: v.width)
        let yStep = PlotMath.niceStep(range: v.height)

        // Gridlines, then axes, then curves: anything a curve crosses should sit under it.
        var grid = Path()
        for x in PlotMath.ticks(from: v.xMin, to: v.xMax, step: xStep) {
            let px = v.pixelX(x, width: w)
            grid.move(to: CGPoint(x: px, y: 0)); grid.addLine(to: CGPoint(x: px, y: h))
        }
        for y in PlotMath.ticks(from: v.yMin, to: v.yMax, step: yStep) {
            let py = v.pixelY(y, height: h)
            grid.move(to: CGPoint(x: 0, y: py)); grid.addLine(to: CGPoint(x: w, y: py))
        }
        ctx.stroke(grid, with: .color(.primary.opacity(0.07)), lineWidth: 1)

        var axes = Path()
        if v.yMin <= 0 && v.yMax >= 0 {
            let py = v.pixelY(0, height: h)
            axes.move(to: CGPoint(x: 0, y: py)); axes.addLine(to: CGPoint(x: w, y: py))
        }
        if v.xMin <= 0 && v.xMax >= 0 {
            let px = v.pixelX(0, width: w)
            axes.move(to: CGPoint(x: px, y: 0)); axes.addLine(to: CGPoint(x: px, y: h))
        }
        ctx.stroke(axes, with: .color(.primary.opacity(0.35)), lineWidth: 1)

        // Axis numbers, along the axis when it's on screen and along the edge when it isn't —
        // a plot panned away from the origin still needs to say where it is.
        let axisY = min(max(v.pixelY(0, height: h), 10), h - 4)
        for x in PlotMath.ticks(from: v.xMin, to: v.xMax, step: xStep) where abs(x) > xStep / 2 {
            ctx.draw(Text(PlotMath.label(x, step: xStep)).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: v.pixelX(x, width: w), y: axisY + 8), anchor: .top)
        }
        let axisX = min(max(v.pixelX(0, width: w), 4), w - 4)
        for y in PlotMath.ticks(from: v.yMin, to: v.yMax, step: yStep) where abs(y) > yStep / 2 {
            ctx.draw(Text(PlotMath.label(y, step: yStep)).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: axisX - 5, y: v.pixelY(y, height: h)), anchor: .trailing)
        }

        if model.mode == .slopeField, let node = model.odeNode {
            // Direction ticks first: the solution curve is read against them, so it sits on top.
            var field = Path()
            for tick in ODE.slopeField(node, viewport: v, angle: model.angle) {
                field.move(to: CGPoint(x: v.pixelX(tick.from.x, width: w),
                                       y: v.pixelY(tick.from.y, height: h)))
                field.addLine(to: CGPoint(x: v.pixelX(tick.to.x, width: w),
                                          y: v.pixelY(tick.to.y, height: h)))
            }
            ctx.stroke(field, with: .color(.primary.opacity(0.33)), lineWidth: 1.2)

            if model.showSolution {
                let points = ODE.solution(node, from: model.odeX0, y0: model.odeY0,
                                          viewport: v, angle: model.angle)
                var path = Path()
                var started = false
                for p in points {
                    let point = CGPoint(x: v.pixelX(p.x, width: w), y: v.pixelY(p.y, height: h))
                    guard point.y.isFinite else { continue }
                    let clamped = CGPoint(x: point.x, y: min(max(point.y, -h), 2 * h))
                    if started { path.addLine(to: clamped) } else { path.move(to: clamped); started = true }
                }
                ctx.stroke(path, with: .color(PlotCurve.palette[1]), lineWidth: 2)
                // The initial condition, marked: the curve is one of infinitely many, and which
                // one is the whole content of an initial-value problem.
                let p = CGPoint(x: v.pixelX(model.odeX0, width: w), y: v.pixelY(model.odeY0, height: h))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                           with: .color(PlotCurve.palette[1]), lineWidth: 2)
            }
            return
        }

        for curve in model.curves where curve.visible {
            guard let node = curve.node else { continue }
            var path = Path()
            for segment in PlotMath.segments(node, viewport: v, pixelWidth: w, angle: model.angle) {
                var started = false
                for p in segment {
                    let point = CGPoint(x: v.pixelX(p.x, width: w), y: v.pixelY(p.y, height: h))
                    // Clamp far-off points rather than dropping them, so a curve leaving the top
                    // of the window still enters from the right place.
                    guard point.y.isFinite else { continue }
                    let clamped = CGPoint(x: point.x, y: min(max(point.y, -h), 2 * h))
                    if started { path.addLine(to: clamped) } else { path.move(to: clamped); started = true }
                }
            }
            ctx.stroke(path, with: .color(curve.color), lineWidth: 1.8)

            // The traced point, on every visible curve at once — comparing two functions at the
            // same x is most of why a student plots two functions.
            if let tx = traceX, let ty = PlotMath.value(node, at: tx, angle: model.angle),
               ty >= v.yMin, ty <= v.yMax {
                let p = CGPoint(x: v.pixelX(tx, width: w), y: v.pixelY(ty, height: h))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                         with: .color(curve.color))
            }
        }

        if let tx = traceX {
            var line = Path()
            let px = v.pixelX(tx, width: w)
            line.move(to: CGPoint(x: px, y: 0)); line.addLine(to: CGPoint(x: px, y: h))
            ctx.stroke(line, with: .color(.primary.opacity(0.18)), lineWidth: 1)
        }
    }

    @ViewBuilder private func traceReadout(_ v: Viewport) -> some View {
        if let tx = traceX {
            VStack(alignment: .leading, spacing: 1) {
                Text("x = \(MathEval.format(tx))").font(.caption2.monospacedDigit())
                ForEach(model.curves.filter { $0.visible && $0.node != nil }) { c in
                    if let y = PlotMath.value(c.node!, at: tx, angle: model.angle) {
                        Text("\(shortSource(c.source)) = \(MathEval.format(y))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(c.color)
                    }
                }
            }
            .padding(DS.Space.s)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .padding(DS.Space.m)
        }
    }

    private func shortSource(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count > 14 ? String(t.prefix(13)) + "…" : t
    }

    private var zoomControls: some View {
        HStack(spacing: DS.Space.xs) {
            Button { model.viewport = model.viewport.zoomed(by: 1 / 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Button { model.viewport = model.viewport.zoomed(by: 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { model.resetViewport() } label: { Image(systemName: "scope") }
                .help("Back to the default window")
        }
        .buttonStyle(.borderless)
        .padding(DS.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control))
        .padding(DS.Space.m)
    }

    // MARK: - Curves

    @ViewBuilder private var controls: some View {
        VStack(spacing: DS.Space.s) {
            Picker("", selection: $model.mode) {
                ForEach(GraphModel.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
            if model.mode == .function { curveList } else { odeControls }
        }
        .padding(DS.Space.l)
    }

    private var odeControls: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Text("y′ =").font(.callout.monospaced()).foregroundStyle(.secondary)
                TextField("a function of x and y", text: $model.odeSource)
                    .textFieldStyle(.plain).font(.callout.monospaced())
                if let e = model.odeError {
                    Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            HStack(spacing: DS.Space.m) {
                Toggle("Solution through", isOn: $model.showSolution)
                    .toggleStyle(.checkbox).font(.caption)
                NumberField(label: "x₀", value: $model.odeX0)
                NumberField(label: "y₀", value: $model.odeY0)
                Spacer()
                Text("RK4 · \(model.angle.short)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var curveList: some View {
        VStack(spacing: DS.Space.s) {
            ForEach(model.curves) { curve in
                HStack(spacing: DS.Space.m) {
                    // Hollow when nothing is being drawn, filled when it is. A solid colour dot
                    // beside an empty row said a curve was on the plot when none was.
                    Button { toggle(curve) } label: {
                        Circle()
                            .strokeBorder(curve.color.opacity(curve.node == nil ? 0.45 : 1), lineWidth: 2)
                            .background(Circle().fill(
                                curve.node != nil && curve.visible ? curve.color : .clear))
                            .frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(curve.node == nil)
                    .help(curve.visible ? "Hide this curve" : "Show this curve")

                    // A prompt, not an example: "y = x^2" as placeholder text read as a function
                    // already typed into the row.
                    TextField("Type a function of x", text: Binding(
                        get: { curve.source },
                        set: { model.update(curve.id, source: $0) }))
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())

                    if let e = curve.error, !curve.source.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                    Button { model.remove(curve.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Remove")
                }
            }
            HStack {
                Button { model.addCurve() } label: { Label("Add a function", systemImage: "plus") }
                    .buttonStyle(.borderless).font(.caption)
                Spacer()
                Text("Drag to pan · \(model.angle.short)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func toggle(_ curve: PlotCurve) {
        guard let i = model.curves.firstIndex(where: { $0.id == curve.id }) else { return }
        model.curves[i].visible.toggle()
    }
}

/// A small labelled number field. Used wherever a tool needs a bare number rather than an
/// expression — an initial condition, a rate, a measurement.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    var width: CGFloat = 62

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { MathEval.format(value) },
                // Typed with an expression, since "1/3" and "2*pi" are things a student has in
                // hand more often than their decimals.
                set: { if let r = try? MathEval.evaluate($0) { value = r.value } }))
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .frame(width: width)
        }
    }
}
