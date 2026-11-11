import CoreFoundation
import Foundation

struct OfflineMap {
    struct Coordinate: Equatable {
        let longitude: Double
        let latitude: Double
    }

    enum Shape: Equatable {
        case point(Coordinate)
        case line([Coordinate])
        case polygon([[Coordinate]])

        var coordinates: [Coordinate] {
            switch self {
            case let .point(point): return [point]
            case let .line(line): return line
            case let .polygon(rings): return rings.flatMap { $0 }
            }
        }
    }

    struct Feature {
        var shapes: [Shape]
        var properties: [String: String]

        var name: String? { properties["name"] ?? properties["title"] ?? properties["id"] }
    }

    enum Format: String, Hashable { case geojson, topojson }
    let features: [Feature]

    static func parse(_ source: String, format: Format) throws -> Self {
        guard source.utf8.count <= 512 * 1024,
              let object = try JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        else { throw InvalidMap() }
        var parser = MapParser()
        try parser.read(object, format: format)
        guard !parser.features.isEmpty else { throw InvalidMap() }
        return Self(features: parser.features)
    }

    struct InvalidMap: Error {}
}

private struct MapParser {
    typealias Coordinate = OfflineMap.Coordinate
    typealias Shape = OfflineMap.Shape
    typealias InvalidMap = OfflineMap.InvalidMap
    typealias Object = [String: Any]

    private struct Transform {
        var scale: [Double]
        var translation: [Double]
    }

    private var topology = false
    private var transform: Transform?
    private var arcs: [[Coordinate]] = []
    private var rawPointCount = 0
    private var renderedPointCount = 0
    private(set) var features: [OfflineMap.Feature] = []

    mutating func read(_ root: Object, format: OfflineMap.Format) throws {
        switch format {
        case .geojson:
            try readNode(root, inherited: [:], depth: 0)
        case .topojson:
            guard root["type"] as? String == "Topology", let objects = root["objects"] as? Object,
                  let sourceArcs = root["arcs"] as? [[[Any]]], objects.count <= 1_000 else { throw InvalidMap() }
            topology = true
            if let value = root["transform"] {
                guard let object = value as? Object else { throw InvalidMap() }
                transform = Transform(scale: try pair(object["scale"]), translation: try pair(object["translate"]))
            }
            for arc in sourceArcs {
                var previous = [0.0, 0.0]
                var points: [Coordinate] = []
                for raw in arc {
                    var position = try pair(raw)
                    if transform != nil {
                        previous = [previous[0] + position[0], previous[1] + position[1]]
                        position = previous
                    }
                    points.append(try point(position, transformed: true))
                }
                guard points.count >= 2 else { throw InvalidMap() }
                arcs.append(points)
            }
            for name in objects.keys.sorted() {
                guard let object = objects[name] as? Object else { throw InvalidMap() }
                try readNode(object, inherited: ["id": String(name.prefix(250))], depth: 0)
            }
        }
    }

    private mutating func readNode(_ node: Object, inherited: [String: String], depth: Int) throws {
        guard depth < 24 else { throw InvalidMap() }
        if node["type"] is NSNull { return }
        guard let type = node["type"] as? String else { throw InvalidMap() }
        var properties = inherited
        if let metadata = node["properties"] as? Object {
            for key in metadata.keys.sorted().prefix(40) {
                if let value = metadata[key] {
                    properties[String(key.prefix(120))] = String(describing: value).prefix(250).description
                }
            }
        }
        if let id = node["id"] { properties["id"] = String(describing: id).prefix(250).description }

        switch type {
        case "FeatureCollection", "GeometryCollection":
            let key = type == "FeatureCollection" ? "features" : "geometries"
            guard let children = node[key] as? [Object] else { throw InvalidMap() }
            for child in children { try readNode(child, inherited: properties, depth: depth + 1) }
        case "Feature":
            if node["geometry"] is NSNull { return }
            guard let geometry = node["geometry"] as? Object else { throw InvalidMap() }
            try readNode(geometry, inherited: properties, depth: depth + 1)
        default:
            let shapes = try readGeometry(type, node)
            guard features.count < 1_000, !shapes.isEmpty else { throw InvalidMap() }
            features.append(OfflineMap.Feature(shapes: shapes, properties: properties))
        }
    }

    private mutating func readGeometry(_ type: String, _ node: Object) throws -> [Shape] {
        let coordinates = node["coordinates"]
        let lines = topology ? node["arcs"] : coordinates
        switch type {
        case "Point":
            return [.point(try point(pair(coordinates), transformed: topology, renders: true))]
        case "MultiPoint":
            guard let values = coordinates as? [[Any]] else { throw InvalidMap() }
            return try values.map { .point(try point(pair($0), transformed: topology, renders: true)) }
        case "LineString":
            return [.line(try line(lines))]
        case "MultiLineString":
            guard let values = lines as? [Any] else { throw InvalidMap() }
            return try values.map { .line(try line($0)) }
        case "Polygon":
            return [.polygon(try polygon(lines))]
        case "MultiPolygon":
            guard let values = lines as? [Any] else { throw InvalidMap() }
            return try values.map { .polygon(try polygon($0)) }
        default:
            throw InvalidMap()
        }
    }

    private mutating func polygon(_ value: Any?) throws -> [[Coordinate]] {
        guard let rings = value as? [Any], !rings.isEmpty else { throw InvalidMap() }
        return try rings.map {
            let ring = try line($0)
            guard ring.count >= 4, ring.first == ring.last else { throw InvalidMap() }
            return ring
        }
    }

    private mutating func line(_ value: Any?) throws -> [Coordinate] {
        if topology {
            guard let indices = value as? [NSNumber], !indices.isEmpty else { throw InvalidMap() }
            var result: [Coordinate] = []
            for index in indices {
                let number = index.doubleValue
                guard CFGetTypeID(index) != CFBooleanGetTypeID(), number.rounded() == number,
                      number >= -Double(arcs.count), number < Double(arcs.count)
                else { throw InvalidMap() }
                let slot = Int(number)
                let arc = arcs[slot < 0 ? ~slot : slot]
                if slot < 0 {
                    guard result.last == nil || result.last == arc.last else { throw InvalidMap() }
                    try countRendered(arc.count - (result.isEmpty ? 0 : 1))
                    result.append(contentsOf: arc.reversed().dropFirst(result.isEmpty ? 0 : 1))
                } else {
                    guard result.last == nil || result.last == arc.first else { throw InvalidMap() }
                    try countRendered(arc.count - (result.isEmpty ? 0 : 1))
                    result.append(contentsOf: arc.dropFirst(result.isEmpty ? 0 : 1))
                }
            }
            return result
        }
        guard let values = value as? [[Any]], values.count >= 2 else { throw InvalidMap() }
        return try values.map { try point(pair($0), transformed: false, renders: true) }
    }

    private func pair(_ value: Any?) throws -> [Double] {
        guard let values = value as? [Any], values.count >= 2 else { throw InvalidMap() }
        return try values.prefix(2).map {
            guard let number = $0 as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { throw InvalidMap() }
            return number.doubleValue
        }
    }

    private mutating func point(_ value: [Double], transformed: Bool, renders: Bool = false) throws -> Coordinate {
        rawPointCount += 1
        guard rawPointCount <= 60_000 else { throw InvalidMap() }
        if renders { try countRendered(1) }
        let position: Coordinate
        if transformed, let transform {
            position = Coordinate(longitude: value[0] * transform.scale[0] + transform.translation[0],
                                  latitude: value[1] * transform.scale[1] + transform.translation[1])
        } else {
            position = Coordinate(longitude: value[0], latitude: value[1])
        }
        guard (-180...180).contains(position.longitude), (-90...90).contains(position.latitude)
        else { throw InvalidMap() }
        return position
    }

    private mutating func countRendered(_ count: Int) throws {
        renderedPointCount += count
        guard renderedPointCount <= 100_000 else { throw InvalidMap() }
    }
}
