import SwiftUI

struct OfflineMapBlock: View {
    let source: String
    let format: OfflineMap.Format
    let fallback: String
    @State private var map: OfflineMap?
    @State private var displayedSource: String?

    var body: some View {
        Group {
            if let map, displayedSource == source {
                OfflineMapView(map: map).id(source)
            } else {
                Text(verbatim: fallback).font(.system(.body, design: .monospaced))
            }
        }
        .task(id: source) {
            let parsed = await Task.detached(priority: .utility) { try? OfflineMap.parse(source, format: format) }.value
            guard !Task.isCancelled else { return }
            displayedSource = source
            map = parsed
        }
    }
}

struct OfflineMapView: View {
    let map: OfflineMap
    private let projection: MapProjection
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @State private var selection: Int?
    @GestureState private var drag = CGSize.zero
    @GestureState private var magnification = 1.0

    init(map: OfflineMap) {
        self.map = map
        projection = MapProjection(map: map)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let viewport = projection.viewport(size: geometry.size, zoom: effectiveZoom, pan: effectivePan)
                Canvas { context, _ in
                    for (index, feature) in map.features.enumerated() {
                        let highlight = index == selection
                        for shape in feature.shapes {
                            let path = viewport.path(shape)
                            if case .line = shape {
                                context.stroke(path, with: .color(highlight ? .orange : .accentColor), lineWidth: highlight ? 3 : 2)
                            } else {
                                context.fill(path, with: .color(highlight ? .orange.opacity(0.45) : .accentColor.opacity(0.24)),
                                             style: FillStyle(eoFill: true))
                                context.stroke(path, with: .color(highlight ? .orange : .accentColor), lineWidth: 1.5)
                            }
                        }
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 5).updating($drag) { value, state, _ in
                    state = value.translation
                }.onEnded { value in
                    pan.width += value.translation.width
                    pan.height += value.translation.height
                })
                .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
                    state = value.magnification
                }.onEnded { value in
                    zoom = bounded(zoom * value.magnification)
                })
                .simultaneousGesture(SpatialTapGesture().onEnded { value in
                    selection = map.features.indices.reversed().first { index in
                        map.features[index].shapes.contains { viewport.hit(value.location, in: $0) }
                    }
                })
                .accessibilityLabel("Map preview")
                .accessibilityHint("Use the feature picker to inspect map details.")
            }
            .frame(height: 290)

            HStack {
                Picker("Feature", selection: $selection) {
                    Text("No selection").tag(nil as Int?)
                    ForEach(map.features.indices, id: \.self) { index in
                        Text(map.features[index].name ?? "Feature \(index + 1)").tag(index as Int?)
                    }
                }.frame(maxWidth: 280)
                Spacer()
                Button { zoom = bounded(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom out")
                Button { zoom = bounded(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom in")
                Button("Reset view") { zoom = 1; pan = .zero }
            }
            if let selection, map.features.indices.contains(selection) {
                let feature = map.features[selection]
                ForEach(feature.properties.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: key).fontWeight(.semibold)
                        Text(verbatim: feature.properties[key] ?? "").textSelection(.enabled)
                    }.font(.caption)
                }
            }
        }
    }

    private var effectiveZoom: Double { bounded(zoom * magnification) }
    private var effectivePan: CGSize { CGSize(width: pan.width + drag.width, height: pan.height + drag.height) }
    private func bounded(_ value: Double) -> Double { min(40, max(0.5, value)) }
}

struct MapProjection {
    private let startLongitude: Double
    private let center: CGPoint
    private let extent: CGSize

    init(map: OfflineMap) {
        let points = map.features.flatMap(\.shapes).flatMap(\.coordinates)
        let sorted = points.map { Self.positive($0.longitude) }.sorted()
        var largestGap = -1.0
        var start = sorted.first ?? 0
        for index in sorted.indices {
            let next = index + 1 == sorted.count ? sorted[0] + 360 : sorted[index + 1]
            let gap = next - sorted[index]
            if gap > largestGap {
                largestGap = gap
                start = Self.positive(next)
            }
        }
        startLongitude = start
        let positions = points.map { Self.project($0, startingAt: start) }
        let x = positions.map(\.x)
        let y = positions.map(\.y)
        let minX = x.min() ?? 0, maxX = x.max() ?? 0
        let minY = y.min() ?? 0, maxY = y.max() ?? 0
        center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        extent = CGSize(width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    func viewport(size: CGSize, zoom: Double = 1, pan: CGSize = .zero) -> Viewport {
        let fit = min(max(1, size.width - 48) / extent.width, max(1, size.height - 48) / extent.height)
        return Viewport(start: startLongitude, center: center, origin: CGPoint(x: size.width / 2 + pan.width,
                                                                               y: size.height / 2 + pan.height),
                        scale: fit * zoom)
    }

    private static func positive(_ degrees: Double) -> Double {
        let phase = degrees.truncatingRemainder(dividingBy: 360)
        return phase < 0 ? phase + 360 : phase
    }

    private static func project(_ coordinate: OfflineMap.Coordinate, startingAt start: Double) -> CGPoint {
        let latitude = min(85, max(-85, coordinate.latitude)) * .pi / 180
        let north = log(tan(.pi / 4 + latitude / 2)) * 180 / .pi
        return CGPoint(x: positive(coordinate.longitude - start), y: -north)
    }

    struct Viewport {
        let start: Double
        let center: CGPoint
        let origin: CGPoint
        let scale: Double

        func position(_ coordinate: OfflineMap.Coordinate) -> CGPoint {
            let p = MapProjection.project(coordinate, startingAt: start)
            return CGPoint(x: origin.x + (p.x - center.x) * scale, y: origin.y + (p.y - center.y) * scale)
        }

        func path(_ shape: OfflineMap.Shape) -> Path {
            switch shape {
            case let .point(coordinate):
                let p = position(coordinate)
                return Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            case let .line(coordinates):
                return Path { $0.addLines(coordinates.map(position)) }
            case let .polygon(rings):
                return Path { path in
                    for ring in rings { path.addLines(ring.map(position)); path.closeSubpath() }
                }
            }
        }

        func hit(_ point: CGPoint, in shape: OfflineMap.Shape) -> Bool {
            let path = path(shape)
            let stroke = path.strokedPath(StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)).contains(point)
            if case .line = shape { return stroke }
            return path.contains(point, eoFill: true) || stroke
        }
    }
}
