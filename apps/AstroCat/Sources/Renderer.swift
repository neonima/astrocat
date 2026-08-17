import Metal
import MetalKit
import MetalPerformanceShaders
import simd

struct Uniforms {
    var viewX: SIMD2<Float>
    var viewY: SIMD2<Float>
    var viewC: SIMD2<Float>
    var before: OpSlot
    var splitX: Float
    var clarity: Float
    var texture: Float
    var opCount: Int32
    var maskOutside: Int32
    var crop: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    /// Only built when a neighbourhood operation is actually switched on, so
    /// the common case stays a single pass straight to the drawable.
    private var offscreen: MTLRenderPipelineState?
    private var composite: MTLRenderPipelineState?
    private var sceneTex: MTLTexture?
    private var coarseTex: MTLTexture?
    private var fineTex: MTLTexture?
    private var coarseBlur: MPSImageGaussianBlur?
    private var fineBlur: MPSImageGaussianBlur?
    private var coarseSigma: Float = -1
    private var texture: MTLTexture?
    private var lut: MTLBuffer?
    private var zoneLut: MTLBuffer?
    private var imageAspect: Float = 1

    var detail = DetailParams()
    /// The stages to run, in order, each with its own parameters.
    var ops: [OpSlot] = []
    /// The as-stacked comparison and where the seam falls, drawn by the same
    /// pass so the two halves cannot be laid out differently.
    var before = OpSlot()
    var splitX: Float = -1
    var viewport = Viewport()

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue()
        else { fatalError("Metal is unavailable") }

        guard let library = device.makeDefaultLibrary(),
            let vfn = library.makeFunction(name: "v_image"),
            let ffn = library.makeFunction(name: "f_image")
        else { fatalError("default.metallib is missing v_image/f_image") }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("pipeline: \(error)")
        }

        if let voff = library.makeFunction(name: "v_offscreen"),
            let fcomp = library.makeFunction(name: "f_composite")
        {
            let off = MTLRenderPipelineDescriptor()
            off.vertexFunction = voff
            off.fragmentFunction = ffn
            off.colorAttachments[0].pixelFormat = .rgba16Float
            offscreen = Self.build(device, off, "offscreen")

            let comp = MTLRenderPipelineDescriptor()
            comp.vertexFunction = voff
            comp.fragmentFunction = fcomp
            comp.colorAttachments[0].pixelFormat = .bgra8Unorm
            composite = Self.build(device, comp, "composite")
        }

        self.device = device
        self.queue = queue
        super.init()
        setEqualisation(Array(repeating: 0, count: 256))
        setZones([(0..<256).map { Float($0) / 255 }])
    }

    /// Loud on failure: a nil pipeline would silently drop the two-pass path
    /// back to single-pass, and a detail slider that does nothing is a worse
    /// bug than one that refuses to start.
    private static func build(
        _ device: MTLDevice, _ desc: MTLRenderPipelineDescriptor, _ name: String
    ) -> MTLRenderPipelineState? {
        do {
            return try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            assertionFailure("\(name) pipeline failed: \(error)")
            return nil
        }
    }

    func upload(_ frame: LoadedFrame) {
        let w = frame.meta.width
        let h = frame.meta.height
        guard w > 0, h > 0 else { return }

        // Mipmapped because the frame is full resolution and the pane rarely is.
        // Without the chain the sampler point-samples one pixel in every four or
        // eight, which turns an undersampled star field into a lattice.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: frame.pixels,
            bytesPerRow: w * 4 * MemoryLayout<UInt16>.size)

        if tex.mipmapLevelCount > 1,
            let buffer = queue.makeCommandBuffer(),
            let blit = buffer.makeBlitCommandEncoder()
        {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            // Waited on: the first draw can be encoded before an async blit has
            // run, and a frame sampled from empty mip levels is a black pane.
            buffer.commit()
            buffer.waitUntilCompleted()
        }

        texture = tex
        imageAspect = Float(w) / Float(h)
    }

    func setEqualisation(_ cdf: [Float]) {
        var v = cdf
        if v.count != 256 { v = Array(repeating: 0, count: 256) }
        lut = device.makeBuffer(
            bytes: v, length: 256 * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    /// One 256-entry block per Zone balance stage, concatenated. A stage's slot
    /// carries the index of its own block, so several can hold different curves.
    func setZones(_ curves: [[Float]]) {
        var flat = [Float]()
        for c in curves {
            flat.append(contentsOf: c.count == 256 ? c : (0..<256).map { Float($0) / 255 })
        }
        if flat.isEmpty { flat = (0..<256).map { Float($0) / 255 } }
        zoneLut = device.makeBuffer(
            bytes: flat, length: flat.count * MemoryLayout<Float>.stride,
            options: .storageModeShared)
    }

    /// The frame's width over its height, so gesture handling can work out
    /// where a screen point lands without reaching into the texture.
    var aspect: Float { imageAspect }

    private func viewMatrix(_ size: CGSize) -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        guard size.width > 0, size.height > 0 else {
            return (SIMD2(0.5, 0), SIMD2(0, 0.5), SIMD2(0.5, 0.5))
        }
        let m = viewport.matrix(
            imageAspect: imageAspect, viewAspect: Float(size.width / size.height))
        return (m.x, m.y, m.centre)
    }

    /// Half-float targets: the composite subtracts a blurred copy from the
    /// original, and doing that in 8 bits bands the faint end where all the
    /// nebulosity lives.
    private func ensureTargets(_ width: Int, _ height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        if let t = sceneTex, t.width == width, t.height == height { return true }

        let make = { () -> MTLTexture? in
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]
            d.storageMode = .private
            return self.device.makeTexture(descriptor: d)
        }
        sceneTex = make()
        coarseTex = make()
        fineTex = make()
        return sceneTex != nil && coarseTex != nil && fineTex != nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else { return }
        encode(pass, size: view.drawableSize) { $0.present(drawable) }
    }

    /// Renders into a texture rather than a drawable, so what the shader
    /// actually produces can be read back and compared. Two panes that should
    /// look identical are a claim about pixels, and pixels are checkable.
    func render(width: Int, height: Int) -> [UInt8]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1)

        guard
            encode(pass, size: CGSize(width: width, height: height), present: nil, wait: true)
        else { return nil }

        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { raw in
            target.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return out
    }

    @discardableResult
    private func encode(
        _ pass: MTLRenderPassDescriptor, size: CGSize,
        present: ((MTLCommandBuffer) -> Void)? = nil, wait: Bool = false
    ) -> Bool {
        guard let tex = texture, let buffer = queue.makeCommandBuffer() else { return false }
        let m = viewMatrix(size)
        var u = Uniforms(
            viewX: m.0, viewY: m.1, viewC: m.2, before: before, splitX: splitX,
            clarity: detail.clarity, texture: detail.texture, opCount: Int32(ops.count),
            maskOutside: 1, crop: viewport.crop)
        // An empty list still needs a byte to point at, and a slot whose code is
        // zero is a no-op the loop never reaches.
        let slots = ops.isEmpty ? [OpSlot()] : ops

        let width = Int(size.width)
        let height = Int(size.height)
        let wantsDetail =
            !detail.isIdentity && offscreen != nil && composite != nil
            && ensureTargets(width, height)

        // Straight to the drawable when nothing needs a neighbourhood, which is
        // most of the time and half the work.
        guard wantsDetail,
            let scene = sceneTex, let coarse = coarseTex, let fine = fineTex,
            let offPipeline = offscreen, let compPipeline = composite
        else {
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBuffer(lut, offset: 0, index: 1)
            encoder.setFragmentBuffer(zoneLut, offset: 0, index: 2)
            encoder.setFragmentBytes(
                slots, length: MemoryLayout<OpSlot>.stride * slots.count, index: 3)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            present?(buffer)
            buffer.commit()
            if wait { buffer.waitUntilCompleted() }
            return true
        }

        let offDesc = MTLRenderPassDescriptor()
        offDesc.colorAttachments[0].texture = scene
        offDesc.colorAttachments[0].loadAction = .clear
        offDesc.colorAttachments[0].storeAction = .store
        offDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        // The offscreen pass must not black out the letterbox: the blur that
        // follows would then pull the frame's own edge toward it and leave a
        // dark rim once the composite subtracts it.
        var offUniforms = u
        offUniforms.maskOutside = 0

        guard let offEncoder = buffer.makeRenderCommandEncoder(descriptor: offDesc) else { return false }
        offEncoder.setRenderPipelineState(offPipeline)
        offEncoder.setVertexBytes(&offUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        offEncoder.setFragmentBytes(&offUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        offEncoder.setFragmentBuffer(lut, offset: 0, index: 1)
        offEncoder.setFragmentBuffer(zoneLut, offset: 0, index: 2)
        offEncoder.setFragmentBytes(
            slots, length: MemoryLayout<OpSlot>.stride * slots.count, index: 3)
        offEncoder.setFragmentTexture(tex, index: 0)
        offEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        offEncoder.endEncoding()

        // Metal Performance Shaders rather than a hand-rolled separable blur:
        // it is already tuned per GPU, and the interesting part of clarity is
        // the compositing, not the Gaussian.
        let sigma = max(1, detail.radius)
        if coarseBlur == nil || coarseSigma != sigma {
            coarseBlur = MPSImageGaussianBlur(device: device, sigma: sigma)
            coarseSigma = sigma
        }
        if fineBlur == nil { fineBlur = MPSImageGaussianBlur(device: device, sigma: 1.5) }
        coarseBlur?.encode(commandBuffer: buffer, sourceTexture: scene, destinationTexture: coarse)
        fineBlur?.encode(commandBuffer: buffer, sourceTexture: scene, destinationTexture: fine)

        guard let compEncoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        compEncoder.setRenderPipelineState(compPipeline)
        compEncoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        compEncoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        compEncoder.setFragmentTexture(scene, index: 0)
        compEncoder.setFragmentTexture(coarse, index: 1)
        compEncoder.setFragmentTexture(fine, index: 2)
        compEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        compEncoder.endEncoding()

        present?(buffer)
        buffer.commit()
        if wait { buffer.waitUntilCompleted() }
        return true
    }
}
