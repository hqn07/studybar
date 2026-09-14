import SwiftUI
import SceneKit

/// The 3D tab: `z = f(x, y)` as a real surface you can spin.
///
/// SceneKit rather than a hand-projected wireframe on a Canvas, for one reason that matters to
/// the person using it: depth. A wireframe drawn with a painter's algorithm reads as ambiguous —
/// a saddle looks identical to its own inverse until you rotate it — while a lit, depth-tested
/// mesh reads immediately. `allowsCameraControl` gives orbit, pan and zoom for free, so the
/// gesture work is SceneKit's rather than ours.
///
/// The mesh is rebuilt when the expression, the domain or the resolution changes. At the default
/// 60 that is 3,721 vertices and 7,200 triangles, which builds in a few milliseconds.
struct MathSurfaceView: View {
    @ObservedObject var model: GraphModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            SurfaceSceneView(surface: model.surface(), wireframe: model.wireframe, dark: scheme == .dark)
                .frame(minHeight: 220)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .topLeading) { legend }
                .overlay(alignment: .center) { emptyState }
            Divider()
            controls
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.surfaceNode == nil {
            VStack(spacing: DS.Space.s) {
                Image(systemName: "cube.transparent").font(.title).foregroundStyle(.tertiary)
                Text(model.surfaceError ?? "Type a function of x and y")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var legend: some View {
        if let s = model.surface(), s.zMax > s.zMin {
            VStack(alignment: .leading, spacing: 2) {
                Text("z \(compact(s.zMin)) … \(compact(s.zMax))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                // The ramp the mesh is coloured with, so a colour on screen can be read as a
                // height rather than being decorative.
                LinearGradient(colors: SurfaceColors.ramp, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 96, height: 5)
                    .clipShape(Capsule())
            }
            .padding(DS.Space.s)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            .padding(DS.Space.m)
        }
    }

    /// Three significant figures for a range readout — the calculator's twelve are right for an
    /// answer and absurd for a legend.
    private func compact(_ v: Double) -> String {
        guard v != 0, v.isFinite else { return "0" }
        let exponent = floor(log10(abs(v)))
        let factor = pow(10, 2 - exponent)
        return MathEval.format((v * factor).rounded() / factor)
    }

    private var controls: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Text("z =").font(.callout.monospaced()).foregroundStyle(.secondary)
                TextField("sin(x) * cos(y)", text: $model.surfaceSource)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                if let e = model.surfaceError {
                    Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            HStack(spacing: DS.Space.l) {
                HStack(spacing: DS.Space.s) {
                    Text("Range").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $model.surfaceRange, in: 1...20, step: 1).frame(width: 110)
                    Text("±\(MathEval.format(model.surfaceRange))")
                        .font(.caption2.monospacedDigit()).frame(width: 34, alignment: .leading)
                }
                HStack(spacing: DS.Space.s) {
                    Text("Detail").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(model.surfaceResolution) },
                                          set: { model.surfaceResolution = Int($0) }),
                           in: 20...120, step: 10).frame(width: 90)
                }
                Toggle("Wireframe", isOn: $model.wireframe)
                    .toggleStyle(.checkbox).font(.caption2)
                Spacer()
                Text("Drag to rotate · scroll to zoom")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(DS.Space.l)
    }
}

/// The height-to-colour ramp, shared by the mesh and the legend.
enum SurfaceColors {
    static let ramp: [Color] = [
        Color(red: 0.21, green: 0.35, blue: 0.62),
        Color(red: 0.24, green: 0.62, blue: 0.68),
        Color(red: 0.45, green: 0.74, blue: 0.47),
        Color(red: 0.92, green: 0.78, blue: 0.35),
        Color(red: 0.87, green: 0.42, blue: 0.31),
    ]

    /// The ramp as a 1-pixel-tall image, which is what the mesh samples by height.
    static let rampImage: NSImage = {
        let width = 256
        let image = NSImage(size: NSSize(width: width, height: 1))
        image.lockFocus()
        for x in 0..<width {
            color(Double(x) / Double(width - 1)).setFill()
            NSRect(x: CGFloat(x), y: 0, width: 1, height: 1).fill()
        }
        image.unlockFocus()
        return image
    }()

    /// Linear interpolation through the ramp for a 0…1 height.
    static func color(_ t: Double) -> NSColor {
        let stops = ramp.map { NSColor($0).usingColorSpace(.sRGB) ?? .gray }
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Double(stops.count - 1)
        let i = min(Int(scaled), stops.count - 2)
        let f = CGFloat(scaled - Double(i))
        let a = stops[i], b = stops[i + 1]
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * f,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                       alpha: 1)
    }
}

/// The SceneKit host. Rebuilds the mesh only when the inputs actually change — the surface is
/// resampled on every SwiftUI update otherwise, which at 120 detail is 14,641 evaluations.
struct SurfaceSceneView: NSViewRepresentable {
    let surface: Surface3D?
    let wireframe: Bool
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var signature: String = ""
        let node = SCNNode()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        let scene = SCNScene()
        view.scene = scene
        view.allowsCameraControl = true       // orbit, pan and zoom, without writing gestures
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        scene.rootNode.addChildNode(context.coordinator.node)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 500
        camera.camera?.fieldOfView = 45
        // Looking down from one corner: the angle that shows a saddle as a saddle. Close enough
        // that the surface fills the view — the first version framed it as a distant object.
        camera.position = SCNVector3(6.5, -8, 5.5)
        camera.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camera)

        // Lighting hangs off the CAMERA, not the scene, so orbiting never rotates the surface
        // into its own shadow. An ambient floor guarantees it can never render black — which is
        // exactly what the first version did: a lone directional light also suppressed
        // `autoenablesDefaultLighting` (that only fires for a scene with no lights at all), and
        // an unlit blinn material is solid black with no error to read.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 420
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 900
        key.position = SCNVector3(0, 0, 4)     // just in front of the lens
        camera.addChildNode(key)

        rebuild(context: context)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        rebuild(context: context)
    }

    private func rebuild(context: Context) {
        let signature = surface.map { s in
            "\(s.resolution)|\(s.xMin)|\(s.xMax)|\(s.yMin)|\(s.yMax)|\(s.zMin)|\(s.zMax)|\(s.z.first ?? 0)|\(s.z.last ?? 0)|\(wireframe)"
        } ?? "none"
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature

        context.coordinator.node.childNodes.forEach { $0.removeFromParentNode() }
        guard let s = surface, let geometry = SurfaceMesh.build(s, wireframe: wireframe) else { return }
        context.coordinator.node.addChildNode(SCNNode(geometry: geometry))
    }
}

/// Turns a height field into a SceneKit mesh.
enum SurfaceMesh {

    /// The vertical exaggeration: z is scaled so the surface's full height spans a fixed fraction
    /// of its footprint. Without it, `z = 0.001 * x` is a flat plate and `z = x^3` is a spike —
    /// the domain is the same but the ranges differ by orders of magnitude.
    static let plotHeight: Float = 4

    static func build(_ s: Surface3D, wireframe: Bool) -> SCNGeometry? {
        let side = s.side
        guard side >= 2 else { return nil }
        let span: Float = 8            // the surface's footprint, in scene units
        let zScale: Float = s.zMax > s.zMin ? plotHeight / Float(s.zMax - s.zMin) : 0

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        // Height drives a texture coordinate, not a per-vertex colour. A `.color` geometry source
        // has to describe its own buffer stride exactly, and SCNVector3 on macOS is three CGFloats
        // (24 bytes, not 12) — get that wrong and the surface renders solid black with no error.
        // A 1D gradient sampled by u = normalized height avoids the whole class of problem, and
        // the convenience initialisers below handle the conversions.
        var texcoords: [CGPoint] = []
        vertices.reserveCapacity(side * side)
        normals.reserveCapacity(side * side)
        texcoords.reserveCapacity(side * side)

        /// Height at a grid position in scene units, clamped at the edges so a normal at the
        /// boundary uses the nearest real sample rather than falling off the array.
        func height(_ row: Int, _ col: Int) -> Float {
            let r = Swift.min(Swift.max(row, 0), side - 1)
            let c = Swift.min(Swift.max(col, 0), side - 1)
            let v = s.z[r * side + c]
            return v.isFinite ? Float(v - (s.zMin + s.zMax) / 2) * zScale : 0
        }
        for row in 0..<side {
            for col in 0..<side {
                let value = s.z[row * side + col]
                let x = Float(col) / Float(side - 1) * span - span / 2
                let y = Float(row) / Float(side - 1) * span - span / 2
                // A hole in the domain (sqrt of a negative, a pole) becomes a vertex at zero
                // that no triangle references — see the index pass below.
                let z = value.isFinite ? Float(value - (s.zMin + s.zMax) / 2) * zScale : 0
                vertices.append(SCNVector3(x, y, z))
                // Central differences give the surface's slope in each direction; the normal is
                // perpendicular to both. Cheaper and smoother than averaging face normals.
                let spacing = span / Float(side - 1)
                let dzdx = (height(row, col + 1) - height(row, col - 1)) / (2 * spacing)
                let dzdy = (height(row + 1, col) - height(row - 1, col)) / (2 * spacing)
                let length = (dzdx * dzdx + dzdy * dzdy + 1).squareRoot()
                normals.append(SCNVector3(-dzdx / length, -dzdy / length, 1 / length))
                texcoords.append(CGPoint(x: value.isFinite ? s.normalized(value) : 0.5, y: 0.5))
            }
        }

        var indices: [Int32] = []
        indices.reserveCapacity((side - 1) * (side - 1) * 6)
        for row in 0..<(side - 1) {
            for col in 0..<(side - 1) {
                let a = row * side + col
                let b = a + 1
                let c = a + side
                let d = c + 1
                // Every corner must be a real value, or the mesh grows a wall down to zero at
                // the edge of the domain — which is exactly what a student would misread as part
                // of the surface.
                guard s.z[a].isFinite, s.z[b].isFinite, s.z[c].isFinite, s.z[d].isFinite else { continue }
                indices += [Int32(a), Int32(c), Int32(b), Int32(b), Int32(c), Int32(d)]
            }
        }
        guard !indices.isEmpty else { return nil }

        let source = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let uvSource = SCNGeometrySource(textureCoordinates: texcoords)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source, normalSource, uvSource], elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.isDoubleSided = true          // the underside of a surface is worth seeing
        material.diffuse.contents = SurfaceColors.rampImage
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.fillMode = wireframe ? .lines : .fill
        geometry.materials = [material]
        return geometry
    }
}
