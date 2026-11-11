import simd
import SwiftUI

struct ASCIIMeshBlock: View {
    let source: String
    let fallback: String
    @State private var mesh: ASCIIMesh?
    @State private var displayedSource: String?

    var body: some View {
        Group {
            if let mesh, displayedSource == source {
                ASCIIMeshView(mesh: mesh).id(source)
            } else {
                Text(verbatim: fallback).font(.system(.body, design: .monospaced))
            }
        }
        .task(id: source) {
            let parsed = await Task.detached(priority: .utility) { try? ASCIIMesh.parse(source) }.value
            guard !Task.isCancelled else { return }
            displayedSource = source
            mesh = parsed
        }
    }
}

struct ASCIIMeshView: View {
    let mesh: ASCIIMesh
    @State private var yaw = -0.55
    @State private var pitch = 0.45
    @State private var zoom = 1.0
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { context, size in
                let camera = MeshCamera(yaw: yaw + drag.width * 0.012, pitch: pitch + drag.height * 0.012,
                                        scale: min(size.width, size.height) * 0.72 * boundedZoom(zoom * magnification))
                let triangles = mesh.triangles.map(camera.project).sorted { $0.depth < $1.depth }
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)
                for triangle in triangles {
                    let polygon = Path { path in
                        path.addLines(triangle.vertices.map { CGPoint(x: origin.x + $0.x, y: origin.y - $0.y) })
                        path.closeSubpath()
                    }
                    context.fill(polygon, with: .color(Color(hue: 0.57, saturation: 0.54, brightness: triangle.shade)))
                }
            }
            .frame(height: 300)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).updating($drag) { value, state, _ in
                state = value.translation
            }.onEnded { value in
                yaw += value.translation.width * 0.012
                pitch += value.translation.height * 0.012
            })
            .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
                state = value.magnification
            }.onEnded { value in
                zoom = boundedZoom(zoom * value.magnification)
            })
            .accessibilityLabel(mesh.name.isEmpty ? "3D model" : mesh.name)
            .accessibilityHint("Drag to rotate, or use the rotation buttons.")
            HStack {
                Button { yaw -= .pi / 12 } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("Rotate left")
                Button { yaw += .pi / 12 } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("Rotate right")
                Spacer()
                Button { zoom = boundedZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom out")
                Button { zoom = boundedZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom in")
                Button("Reset view") { yaw = -0.55; pitch = 0.45; zoom = 1 }
            }
        }
    }

    private func boundedZoom(_ value: Double) -> Double { min(12, max(0.3, value)) }
}

struct MeshCamera {
    struct Face {
        let vertices: [CGPoint]
        let depth: Double
        let shade: Double
    }

    private let cy: Double
    private let sy: Double
    private let cp: Double
    private let sp: Double
    private let scale: Double

    init(yaw: Double, pitch: Double, scale: Double) {
        cy = cos(yaw); sy = sin(yaw)
        cp = cos(pitch); sp = sin(pitch)
        self.scale = scale
    }

    func project(_ triangle: ASCIIMesh.Triangle) -> Face {
        let vertices = [triangle.a, triangle.b, triangle.c].map(rotate)
        let direction = rotate(triangle.normal)
        let light = simd_normalize(ASCIIMesh.Vector(-0.45, 0.6, 0.65))
        let brightness = 0.35 + 0.55 * abs(simd_dot(direction, light))
        return Face(vertices: vertices.map { CGPoint(x: $0.x * scale, y: $0.y * scale) },
                    depth: vertices.reduce(0) { $0 + $1.z } / 3, shade: brightness)
    }

    private func rotate(_ v: ASCIIMesh.Vector) -> ASCIIMesh.Vector {
        let x = cy * v.x + sy * v.z
        let z = -sy * v.x + cy * v.z
        return ASCIIMesh.Vector(x, cp * v.y - sp * z, sp * v.y + cp * z)
    }
}
