import Foundation
import simd

struct ASCIIMesh {
    typealias Vector = SIMD3<Double>

    struct Triangle {
        let a: Vector
        let b: Vector
        let c: Vector
        let normal: Vector
    }

    let name: String
    let triangles: [Triangle]

    static func parse(_ source: String) throws -> Self {
        guard source.utf8.count <= 1_024 * 1_024 else { throw InvalidMesh() }
        let lines = source.split(whereSeparator: \.isNewline).map { line in line.split(whereSeparator: \.isWhitespace) }
            .filter { !$0.isEmpty }
        guard let opening = lines.first, opening.first?.lowercased() == "solid",
              let closing = lines.last, closing.first?.lowercased() == "endsolid",
              lines.count >= 9, (lines.count - 2).isMultiple(of: 7),
              (lines.count - 2) / 7 <= 12_000 else { throw InvalidMesh() }

        var min = Vector(repeating: .infinity)
        var max = Vector(repeating: -.infinity)
        var triangles: [Triangle] = []
        for i in stride(from: 1, to: lines.count - 1, by: 7) {
            guard lines[i].count == 5, lines[i][0].lowercased() == "facet", lines[i][1].lowercased() == "normal",
                  lines[i + 1].map({ $0.lowercased() }) == ["outer", "loop"],
                  lines[i + 5].map({ $0.lowercased() }) == ["endloop"],
                  lines[i + 6].map({ $0.lowercased() }) == ["endfacet"] else { throw InvalidMesh() }
            let declaredNormal = try vector(Array(lines[i].dropFirst(2)))
            let a = try vertex(lines[i + 2])
            let b = try vertex(lines[i + 3])
            let c = try vertex(lines[i + 4])
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length.isFinite else { throw InvalidMesh() }
            if length == 0 { continue }
            let normal = simd_dot(cross, declaredNormal) < 0 ? -cross / length : cross / length
            for p in [a, b, c] {
                min = simd_min(min, p)
                max = simd_max(max, p)
            }
            triangles.append(Triangle(a: a, b: b, c: c, normal: normal))
        }
        let size = max - min
        let extent = Swift.max(size.x, size.y, size.z)
        guard !triangles.isEmpty, extent.isFinite, extent > 0 else { throw InvalidMesh() }
        let center = min + size / 2
        return Self(name: opening.dropFirst().joined(separator: " ").prefix(250).description,
                    triangles: triangles.map {
                        Triangle(a: ($0.a - center) / extent, b: ($0.b - center) / extent,
                                 c: ($0.c - center) / extent, normal: $0.normal)
                    })
    }

    private static func vertex(_ tokens: [Substring]) throws -> Vector {
        guard tokens.count == 4, tokens[0].lowercased() == "vertex" else { throw InvalidMesh() }
        return try vector(Array(tokens.dropFirst()))
    }

    private static func vector(_ tokens: [Substring]) throws -> Vector {
        guard tokens.count == 3,
              let x = Double(tokens[0]), let y = Double(tokens[1]), let z = Double(tokens[2]),
              [x, y, z].allSatisfy({ $0.isFinite && abs($0) <= 1e30 })
        else { throw InvalidMesh() }
        return Vector(x, y, z)
    }

    struct InvalidMesh: Error {}
}
