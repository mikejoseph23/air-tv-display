// SPDX-License-Identifier: MIT
import AppKit
import CoreVideo
import Metal
import QuartzCore
import simd

/// YCbCr -> RGB conversion for the NV12 fragment shader.
struct VideoColor {
    /// Matches the Metal `Conv` struct: float3x3 (3 x 16-byte columns) + float3 (16 bytes).
    struct Conversion { var matrix: simd_float3x3; var offset: SIMD3<Float> }

    static func conversion(fullRange: Bool, bt601: Bool) -> Conversion {
        // Kr/Kb-derived coefficients.
        let (rv, gu, gv, bu): (Float, Float, Float, Float) = bt601
            ? (1.402, -0.344136, -0.714136, 1.772)
            : (1.5748, -0.187324, -0.468124, 1.8556)
        let sy: Float = fullRange ? 1 : 255.0 / 219.0
        let sc: Float = fullRange ? 1 : 255.0 / 224.0
        let m = simd_float3x3(columns: (SIMD3(sy, sy, sy), SIMD3(0, gu * sc, bu * sc), SIMD3(rv * sc, gv * sc, 0)))
        let off = SIMD3<Float>(fullRange ? 0 : 16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        return Conversion(matrix: m, offset: off)
    }

    static func apply(_ c: Conversion, _ yuv: SIMD3<Float>) -> SIMD3<Float> { c.matrix * (yuv - c.offset) }
}

enum VideoGeometry {
    /// Largest rect of `content`'s aspect ratio centered in `bounds` (letterbox/pillarbox).
    static func aspectFit(content: CGSize, in bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let w = (content.width * scale).rounded(), h = (content.height * scale).rounded()
        return CGRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }
}

/// Draws decoded NV12 `CVPixelBuffer`s into a `CAMetalLayer`, aspect-fit on black.
///
/// Queueing: `enqueue` drops the frame into a one-slot mailbox (a newer frame replaces an
/// undrawn one, counted as a present drop) and the render queue draws the latest one. At most
/// one command buffer is in flight, so the queue depth (waiting + on the GPU) is <= 2.
final class VideoRenderer {
    let layer: CAMetalLayer
    let stats: VideoStats
    /// Called on the render queue after each presented frame.
    var onPresent: (() -> Void)?
    /// Called once the frame is on screen (or its GPU work is done when the compositor gives
    /// no present time), with the frame's timing and that host time (`CACurrentMediaTime` base).
    var onPresented: ((FrameTiming, CFTimeInterval) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let renderQueue = DispatchQueue(label: "net.iadev.airtv.render", qos: .userInteractive)
    private let inFlight = DispatchSemaphore(value: 1)

    private let lock = NSLock()
    private struct Pending { let pb: CVPixelBuffer; let timing: FrameTiming? }
    private var mailbox = FrameMailbox<Pending>()
    private var drainScheduled = false
    private var gpuBusy = 0

    init?(stats: VideoStats) {
        guard let device = MTLCreateSystemDefaultDevice(), let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = q
        self.stats = stats
        do {
            let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain")
            d.fragmentFunction = lib.makeFunction(name: "fmain")
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("[video] Metal pipeline: \(error)")
            return nil
        }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = NSColor.black.cgColor
        // 2 drawables = lowest latency; AIRTV_DRAWABLES=3 trades a frame of latency for fewer drops.
        layer.maximumDrawableCount = Int(ProcessInfo.processInfo.environment["AIRTV_DRAWABLES"] ?? "").map { min(3, max(2, $0)) } ?? 2
        // M8: vsync OFF by default. Measured arrival->on-glass p50 on the iMac (fixture feeder):
        // vsync on 23-34 ms at 30 fps and 50 ms at 60 fps (presents queue behind the 2 drawables),
        // vsync off 7.5 ms / 6.5 ms. AIRTV_VSYNC=1 restores vsync if tearing shows.
        layer.displaySyncEnabled = Self.vsyncDefault(env: ProcessInfo.processInfo.environment["AIRTV_VSYNC"])
        layer.allowsNextDrawableTimeout = true
    }

    var deviceName: String { device.name }
    var vsync: Bool { layer.displaySyncEnabled }

    static func vsyncDefault(env: String?) -> Bool { env == "1" }

    /// Any thread.
    func enqueue(_ pb: CVPixelBuffer, timing: FrameTiming? = nil) {
        lock.lock()
        if mailbox.put(Pending(pb: pb, timing: timing)) { stats.presentDropped() }
        stats.queueDepth(1 + gpuBusy)
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { renderQueue.async { [weak self] in self?.drain() } }
    }

    /// Drops any waiting frame and paints black (disconnect / end of session).
    func clear() {
        lock.lock(); mailbox.clear(); lock.unlock()
        renderQueue.async { [weak self] in self?.draw(nil) }
    }

    /// Blocks until the render queue is idle (fixture runs, tests).
    func flush() { renderQueue.sync {}; inFlight.wait(); inFlight.signal() }

    private func drain() {
        while true {
            lock.lock()
            guard let p = mailbox.take() else { drainScheduled = false; lock.unlock(); return }
            lock.unlock()
            if draw(p.pb, timing: p.timing) { stats.presented(); onPresent?() }
        }
    }

    /// Render queue only. Returns true when a frame was presented.
    @discardableResult
    private func draw(_ pb: CVPixelBuffer?, timing: FrameTiming? = nil) -> Bool {
        inFlight.wait()
        lock.lock(); gpuBusy = 1; stats.queueDepth((mailbox.pending == nil ? 0 : 1) + 1); lock.unlock()
        var keep: [CVMetalTexture] = []
        let done: () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.gpuBusy = 0; self.stats.queueDepth(self.mailbox.pending == nil ? 0 : 1); self.lock.unlock()
            self.inFlight.signal()
        }
        guard let drawable = layer.nextDrawable(), let cb = commandQueue.makeCommandBuffer() else { done(); return false }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { done(); return false }
        if let pb, let y = texture(pb, plane: 0, format: .r8Unorm), let uv = texture(pb, plane: 1, format: .rg8Unorm),
           let yt = CVMetalTextureGetTexture(y), let uvt = CVMetalTextureGetTexture(uv) {
            keep = [y, uv]
            let fit = VideoGeometry.aspectFit(content: CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb)),
                                              in: CGSize(width: drawable.texture.width, height: drawable.texture.height))
            enc.setViewport(MTLViewport(originX: fit.minX, originY: fit.minY, width: fit.width, height: fit.height, znear: 0, zfar: 1))
            var conv = Self.conversion(for: pb)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(yt, index: 0)
            enc.setFragmentTexture(uvt, index: 1)
            enc.setFragmentBytes(&conv, length: MemoryLayout<VideoColor.Conversion>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        if let timing, !keep.isEmpty { trackPresent(drawable, cb, timing) }
        cb.present(drawable)
        cb.addCompletedHandler { _ in _ = keep; done() }
        cb.commit()
        return pb != nil && !keep.isEmpty
    }

    /// Latency of one frame: on-glass time from the drawable's presented handler when the
    /// compositor reports one, else the command buffer's completion time.
    private func trackPresent(_ drawable: CAMetalDrawable, _ cb: MTLCommandBuffer, _ timing: FrameTiming) {
        let once = PresentOnce()
        drawable.addPresentedHandler { [weak self] d in
            guard d.presentedTime > 0, once.claim() else { return }
            self?.recordPresent(timing, at: d.presentedTime, onGlass: true)
        }
        cb.addCompletedHandler { [weak self] _ in
            let t = CACurrentMediaTime()
            // Give the presented handler a few refreshes to report a real on-glass time.
            self?.renderQueue.asyncAfter(deadline: .now() + 0.05) {
                if once.claim() { self?.recordPresent(timing, at: t, onGlass: false) }
            }
        }
    }

    private func recordPresent(_ timing: FrameTiming, at t: CFTimeInterval, onGlass: Bool) {
        stats.presentLatency(ms: (t - timing.arrival) * 1000, onGlass: onGlass)
        onPresented?(timing, t)
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var t: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format,
                                                           CVPixelBufferGetWidthOfPlane(pb, plane),
                                                           CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
        return st == kCVReturnSuccess ? t : nil
    }

    private static func conversion(for pb: CVPixelBuffer) -> VideoColor.Conversion {
        let full = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let bt601 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        return VideoColor.conversion(fullRange: full, bt601: bt601)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vmain(uint vid [[vertex_id]]) {
        const float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        const float2 t[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VOut o; o.pos = float4(p[vid], 0, 1); o.uv = t[vid]; return o;
    }
    struct Conv { float3x3 m; float3 offset; };
    fragment float4 fmain(VOut in [[stage_in]], texture2d<float> yTex [[texture(0)]],
                          texture2d<float> uvTex [[texture(1)]], constant Conv &c [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float3 yuv = float3(yTex.sample(s, in.uv).r, uvTex.sample(s, in.uv).rg);
        return float4(saturate(c.m * (yuv - c.offset)), 1);
    }
    """
}

/// First caller wins (presented handler vs. GPU-completion fallback).
private final class PresentOnce {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Layer-hosting view for the renderer's `CAMetalLayer`; keeps the drawable at pixel size.
final class VideoView: NSView {
    let metalLayer: CAMetalLayer

    init(frame: NSRect, layer: CAMetalLayer) {
        metalLayer = layer
        super.init(frame: frame)
        wantsLayer = true
        self.layer = layer   // layer-hosting: set before any subviews
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() { super.layout(); updateDrawableSize() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawableSize() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawableSize() }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }
}
