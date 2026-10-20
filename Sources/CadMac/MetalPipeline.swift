import AppKit
import Metal
import MetalKit
import simd
import CadCore

/// 32-byte vertex representation shared between Swift and Metal shaders.
struct CadVertex {
    var position: SIMD2<Float>
    var _pad: (Float, Float) = (0, 0)
    var color: SIMD4<Float>

    init(x: Float, y: Float, color: SIMD4<Float>) {
        self.position = SIMD2<Float>(x, y)
        self._pad = (0, 0)
        self.color = color
    }

    init(point: Vec2, color: SIMD4<Float>) {
        self.position = SIMD2<Float>(Float(point.x), Float(point.y))
        self._pad = (0, 0)
        self.color = color
    }
}

/// Uniforms passed to vertex shader to transform world coordinates into Metal NDC in real time.
struct MetalUniforms {
    var center: SIMD2<Float>
    var size: SIMD2<Float>
    var scale: Float
    var _pad: Float = 0

    init(center: Vec2, size: CGSize, scale: Double) {
        self.center = SIMD2<Float>(Float(center.x), Float(center.y))
        self.size = SIMD2<Float>(Float(size.width), Float(size.height))
        self.scale = Float(scale)
        self._pad = 0
    }
}

/// Encapsulates Metal device, shader compilation, and render pipeline states.
final class MetalPipeline {
    static let shared = MetalPipeline()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let sampleCount: Int = 4

    /// Embedded shader source fallback ensuring reliability in standalone CLI and app bundle modes.
    static let embeddedShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CadVertex {
        packed_float2 position;
        float _pad[2];
        float4 color;
    };

    struct VertexOut {
        float4 position [[position]];
        float4 color;
        float pointSize [[point_size]];
    };

    struct Uniforms {
        float2 center;
        float2 size;
        float scale;
        float _pad;
    };

    vertex VertexOut cad_vertex_main(const device CadVertex *vertices [[buffer(0)]],
                                     constant Uniforms &uniforms [[buffer(1)]],
                                     uint vid [[vertex_id]]) {
        CadVertex in = vertices[vid];
        VertexOut out;
        float2 viewOffset = float2(in.position[0] - uniforms.center.x, in.position[1] - uniforms.center.y) * uniforms.scale;
        float ndcX = viewOffset.x / (uniforms.size.x * 0.5);
        float ndcY = viewOffset.y / (uniforms.size.y * 0.5);
        out.position = float4(ndcX, ndcY, 0.0, 1.0);
        out.color = in.color;
        out.pointSize = 5.0;
        return out;
    }

    fragment float4 cad_fragment_main(VertexOut in [[stage_in]]) {
        return in.color;
    }
    """

    private init?() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice(),
              let queue = defaultDevice.makeCommandQueue() else {
            return nil
        }
        self.device = defaultDevice
        self.commandQueue = queue

        // Compile shaders: check default library, then compile source directly
        var library: MTLLibrary?
        if let defaultLib = defaultDevice.makeDefaultLibrary() {
            library = defaultLib
        } else {
            do {
                library = try defaultDevice.makeLibrary(source: MetalPipeline.embeddedShaderSource, options: nil)
            } catch {
                print("[MetalPipeline] Failed to compile shader source: \(error)")
                return nil
            }
        }

        guard let lib = library,
              let vertexFunc = lib.makeFunction(name: "cad_vertex_main"),
              let fragmentFunc = lib.makeFunction(name: "cad_fragment_main") else {
            print("[MetalPipeline] Failed to find shader functions")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "CadMac Render Pipeline"
        desc.vertexFunction = vertexFunc
        desc.fragmentFunction = fragmentFunc
        desc.rasterSampleCount = 4
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Standard alpha blending
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try defaultDevice.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("[MetalPipeline] Failed to create pipeline state: \(error)")
            return nil
        }
    }

    func makeVertexBuffer(vertices: [CadVertex]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return device.makeBuffer(bytes: vertices,
                                 length: vertices.count * MemoryLayout<CadVertex>.stride,
                                 options: .storageModeShared)
    }

    func makeUniformBuffer() -> MTLBuffer? {
        return device.makeBuffer(length: MemoryLayout<MetalUniforms>.stride,
                                 options: .storageModeShared)
    }

    func updateUniforms(_ buffer: MTLBuffer, center: Vec2, size: CGSize, scale: Double) {
        var uniforms = MetalUniforms(center: center, size: size, scale: scale)
        buffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<MetalUniforms>.stride)
    }
}
