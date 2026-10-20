import AppKit
import MetalKit
import CadCore

/// High-performance GPU-accelerated drawing view using Metal and MTKView.
/// Capable of rendering millions of CAD primitives at 120 FPS with hardware MSAA.
final class MetalCanvasView: MTKView, MTKViewDelegate {
    let pipeline: MetalPipeline
    private var uniformBuffer: MTLBuffer?

    var geometryBuffer: MetalGeometryBuffer?
    var vt = ViewTransform() {
        didSet {
            updateUniforms()
            needsDisplay = true
        }
    }

    var style = RenderStyle() {
        didSet {
            updateClearColor()
            needsDisplay = true
        }
    }

    init?(frame frameRect: NSRect, pipeline: MetalPipeline = MetalPipeline.shared!) {
        self.pipeline = pipeline
        super.init(frame: frameRect, device: pipeline.device)

        self.delegate = self
        self.colorPixelFormat = .bgra8Unorm
        self.sampleCount = pipeline.sampleCount
        self.enableSetNeedsDisplay = true
        self.isPaused = true

        self.uniformBuffer = pipeline.makeUniformBuffer()
        updateClearColor()
        updateUniforms()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateClearColor() {
        if style.darkBackground {
            // Match CadMac dark background: rgb(0.13, 0.157, 0.188)
            clearColor = MTLClearColor(red: 0.13, green: 0.157, blue: 0.188, alpha: 1.0)
        } else {
            clearColor = MTLClearColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        }
    }

    func updateUniforms() {
        guard let uBuf = uniformBuffer else { return }
        pipeline.updateUniforms(uBuf, center: vt.center, size: vt.size, scale: vt.scale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        vt.size = newSize
        updateUniforms()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled via setFrameSize and view bounds
    }

    func draw(in view: MTKView) {
        guard let renderPassDesc = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let uBuf = uniformBuffer else {
            return
        }

        renderPassDesc.colorAttachments[0].clearColor = clearColor

        guard let cmdBuffer = pipeline.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        encoder.setRenderPipelineState(pipeline.pipelineState)
        encoder.setVertexBuffer(uBuf, offset: 0, index: 1)

        if let geo = geometryBuffer {
            // 1. Draw solid fills (hatches, arrowheads)
            if let fBuf = geo.fillBuffer, geo.fillVertexCount > 0 {
                encoder.setVertexBuffer(fBuf, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geo.fillVertexCount)
            }

            // 2. Draw lines and curves
            if let lBuf = geo.lineBuffer, geo.lineVertexCount > 0 {
                encoder.setVertexBuffer(lBuf, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: geo.lineVertexCount)
            }

            // 3. Draw points
            if let pBuf = geo.pointBuffer, geo.pointVertexCount > 0 {
                encoder.setVertexBuffer(pBuf, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: geo.pointVertexCount)
            }
        }

        encoder.endEncoding()
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}
