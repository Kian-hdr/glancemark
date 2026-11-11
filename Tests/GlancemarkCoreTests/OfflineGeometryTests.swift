import AppKit
import CoreGraphics
import SwiftUI
import Markdown
import XCTest
@testable import GlancemarkCore

final class OfflineGeometryTests: XCTestCase {
    func testGeoJSONPolygonHolesAndFeatureProperties() throws {
        let input = """
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Central Park"},
        "geometry":{"type":"Polygon","coordinates":[[[0,0],[8,0],[8,8],[0,8],[0,0]],
        [[2,2],[6,2],[6,6],[2,6],[2,2]]]}}]}
        """
        let map = try OfflineMap.parse(input, format: .geojson)
        XCTAssertEqual(map.features[0].name, "Central Park")
        let shape = map.features[0].shapes[0]
        let viewport = MapProjection(map: map).viewport(size: CGSize(width: 420, height: 300))
        XCTAssertTrue(viewport.hit(viewport.position(.init(longitude: 1, latitude: 1)), in: shape))
        XCTAssertFalse(viewport.hit(viewport.position(.init(longitude: 4, latitude: 4)), in: shape))
    }

    func testTopoJSONTransformsDeltaArcsAndJoinsReversedReferences() throws {
        let input = """
        {"type":"Topology","transform":{"scale":[0.5,1],"translate":[-120,40]},
         "objects":{"shape":{"type":"LineString","arcs":[0,-2],"properties":{"name":"Trail"}}},
         "arcs":[[[0,0],[4,0]],[[4,2],[0,-2]]]}
        """
        let map = try OfflineMap.parse(input, format: .topojson)
        XCTAssertEqual(map.features.first?.name, "Trail")
        XCTAssertEqual(map.features.first?.shapes, [
            .line([.init(longitude: -120, latitude: 40), .init(longitude: -118, latitude: 40),
                   .init(longitude: -118, latitude: 42)])
        ])
    }

    func testCoordinatesFitAcrossTheAntimeridianAndMalformedDataFails() throws {
        let input = #"{"type":"LineString","coordinates":[[179,5],[-179,5]]}"#
        let map = try OfflineMap.parse(input, format: .geojson)
        let viewport = MapProjection(map: map).viewport(size: CGSize(width: 400, height: 300))
        XCTAssertEqual(viewport.position(.init(longitude: -179, latitude: 5)).x
                       - viewport.position(.init(longitude: 179, latitude: 5)).x, 352, accuracy: 1)
        XCTAssertThrowsError(try OfflineMap.parse(#"{"type":"Point","coordinates":[true,2]}"#, format: .geojson))
        XCTAssertThrowsError(try OfflineMap.parse(#"{"type":"Topology","objects":{"x":{"type":"LineString","arcs":[-2]}},"arcs":[]}"#, format: .topojson))
    }

    @MainActor
    func testNativeMapAndMeshDrawColoredPixels() throws {
        let map = try OfflineMap.parse(#"{"type":"Polygon","coordinates":[[[0,0],[2,0],[2,2],[0,2],[0,0]]]}"#,
                                       format: .geojson)
        let mesh = ASCIIMesh(name: "Triangle", triangles: [
            .init(a: .init(-0.5, -0.5, 0), b: .init(0.5, -0.5, 0), c: .init(0, 0.5, 0), normal: .init(0, 0, 1))
        ])
        for scheme in [ColorScheme.light, .dark] {
            try assertColoredPixels(OfflineMapView(map: map).environment(\.colorScheme, scheme))
            try assertColoredPixels(ASCIIMeshView(mesh: mesh).environment(\.colorScheme, scheme))
        }
    }

    @MainActor
    private func assertColoredPixels(_ view: some View) throws {
        let renderer = ImageRenderer(content: view.frame(width: 420))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let found = (40..<240).contains { y in
            (40..<380).contains { x in
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return abs(pixel.blueComponent - pixel.redComponent) > 0.13
            }
        }
        XCTAssertTrue(found, "Expected visible colored geometry above the controls")
    }

    func testASCIIFenceParsesAndRotatesWhilePreservingOriginalText() throws {
        let stl = """
        solid Triangle
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 2 0 0
              vertex 0 2 0
            endloop
          endfacet
        endsolid Triangle
        """
        let source = "```stl\n\(stl)\n```"
        let snapshot = MarkdownSource(text: source).parse()
        let fence = try XCTUnwrap(snapshot.document.child(at: 0) as? CodeBlock)
        XCTAssertEqual(snapshot.source(of: fence), source)
        let mesh = try ASCIIMesh.parse(fence.code)
        XCTAssertEqual(mesh.name, "Triangle")
        XCTAssertEqual(mesh.triangles.count, 1)
        let face = mesh.triangles[0]
        XCTAssertEqual(face.a, SIMD3(-0.5, -0.5, 0))
        XCTAssertEqual(face.normal, SIMD3(0, 0, 1))
        let front = MeshCamera(yaw: 0, pitch: 0, scale: 100).project(face)
        let turned = MeshCamera(yaw: .pi / 3, pitch: 0, scale: 100).project(face)
        XCTAssertNotEqual(front.vertices, turned.vertices)
        XCTAssertNotEqual(front.depth, turned.depth)
        XCTAssertThrowsError(try ASCIIMesh.parse(stl.replacingOccurrences(of: "vertex 2", with: "vertex NaN")))
        XCTAssertThrowsError(try ASCIIMesh.parse(stl.replacingOccurrences(of: "endloop", with: "unexpected")))
    }
}
