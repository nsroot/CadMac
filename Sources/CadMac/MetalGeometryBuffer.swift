import AppKit
import Metal
import simd
import CadCore

/// Holds GPU vertex buffers for a compiled CAD scene.
final class MetalGeometryBuffer {
    let lineBuffer: MTLBuffer?
    let lineVertexCount: Int

    let fillBuffer: MTLBuffer?
    let fillVertexCount: Int

    let pointBuffer: MTLBuffer?
    let pointVertexCount: Int

    let sceneVersion: Int

    init(lineBuffer: MTLBuffer?, lineCount: Int,
         fillBuffer: MTLBuffer?, fillCount: Int,
         pointBuffer: MTLBuffer?, pointCount: Int,
         version: Int) {
        self.lineBuffer = lineBuffer
        self.lineVertexCount = lineCount
        self.fillBuffer = fillBuffer
        self.fillVertexCount = fillCount
        self.pointBuffer = pointBuffer
        self.pointVertexCount = pointCount
        self.sceneVersion = version
    }

    /// Converts a Scene into GPU vertex buffers.
    static func build(from scene: Scene, drawing: Drawing, style: RenderStyle, pipeline: MetalPipeline) -> MetalGeometryBuffer {
        var lineVertices: [CadVertex] = []
        var fillVertices: [CadVertex] = []
        var pointVertices: [CadVertex] = []

        // Estimate capacities
        lineVertices.reserveCapacity(scene.strokes.count * 64)
        fillVertices.reserveCapacity(scene.fills.count * 12)
        pointVertices.reserveCapacity(scene.points.count)

        func metalColor(_ c: CadColor, alpha: Float = 1.0) -> SIMD4<Float> {
            if style.monochrome {
                return SIMD4<Float>(0, 0, 0, alpha)
            }
            let rgb = c.rgb(darkBackground: style.darkBackground)
            return SIMD4<Float>(
                Float(rgb.r) / 255.0,
                Float(rgb.g) / 255.0,
                Float(rgb.b) / 255.0,
                alpha
            )
        }

        // 1. Strokes (Lines, Polylines, Arcs)
        for batch in scene.strokes {
            let col = metalColor(batch.style.color)
            for prim in batch.prims {
                switch prim {
                case let .seg(a, b):
                    lineVertices.append(CadVertex(point: a, color: col))
                    lineVertices.append(CadVertex(point: b, color: col))

                case let .arc(c, r, st, sw):
                    guard r > 0, abs(sw) > 1e-6 else { continue }
                    // Adaptive curve segmentation: 8 to 64 steps based on sweep angle
                    let steps = max(6, min(64, Int(ceil(abs(sw) / (2.0 * .pi) * 36.0))))
                    var prev = c + .polar(r, st)
                    for step in 1...steps {
                        let t = Double(step) / Double(steps)
                        let curr = c + .polar(r, st + sw * t)
                        lineVertices.append(CadVertex(point: prev, color: col))
                        lineVertices.append(CadVertex(point: curr, color: col))
                        prev = curr
                    }
                }
            }
        }

        // 2. Fills (Solid hatches, Arrowheads)
        var layers: [String: Layer] = [:]
        for l in drawing.layers { layers[l.name.lowercased()] = l }

        for (i, it) in scene.items.enumerated() {
            guard i < scene.visible.count, scene.visible[i] else { continue }
            for part in it.parts {
                guard !part.fills.isEmpty else { continue }
                var color = part.color
                if color == .byLayer || color == .byBlock {
                    color = layers[part.layer.lowercased()]?.color ?? .aci(7)
                }
                let col = metalColor(color)

                for poly in part.fills where poly.count >= 3 {
                    // Fan triangulation for simple / convex polygons
                    let v0 = poly[0]
                    for k in 1..<(poly.count - 1) {
                        fillVertices.append(CadVertex(point: v0, color: col))
                        fillVertices.append(CadVertex(point: poly[k], color: col))
                        fillVertices.append(CadVertex(point: poly[k + 1], color: col))
                    }
                }
            }
        }

        // 3. Points
        for p in scene.points {
            let col = metalColor(p.color)
            pointVertices.append(CadVertex(point: p.point, color: col))
        }

        let lBuf = pipeline.makeVertexBuffer(vertices: lineVertices)
        let fBuf = pipeline.makeVertexBuffer(vertices: fillVertices)
        let pBuf = pipeline.makeVertexBuffer(vertices: pointVertices)

        return MetalGeometryBuffer(
            lineBuffer: lBuf, lineCount: lineVertices.count,
            fillBuffer: fBuf, fillCount: fillVertices.count,
            pointBuffer: pBuf, pointCount: pointVertices.count,
            version: scene.version
        )
    }
}
