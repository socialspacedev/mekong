import AppKit
import Metal
import MetalKit

/// Shared Metal device, queue and the one pipeline every view draws with.
final class MetalStage {
    static let shared = MetalStage()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Mekong needs a Metal-capable GPU")
        }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: Shaders.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Shader compile failed: \(error)")
        }
    }

    func encode(_ pass: MTLRenderPassDescriptor, into cb: MTLCommandBuffer,
                uniforms: Uniforms, bands: [Float]) {
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        var b = bands
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&b, length: MemoryLayout<Float>.stride * b.count, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Renders one frame offscreen — used by `--snapshot` to check the scenes
    /// without a display.
    func image(uniforms: Uniforms, bands: [Float]) -> CGImage? {
        let w = Int(uniforms.width), h = Int(uniforms.height)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat,
                                                          width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget]
        td.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: td),
              let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        encode(pass, into: cb, uniforms: uniforms, bands: bands)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.synchronize(resource: tex)
            blit.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// An MTKView that steps the shared engine and draws the current frame. Used
/// both for the console preview and the fullscreen stage.
final class VisualView: MTKView, MTKViewDelegate {
    private let engine: VisualEngine
    private let hidesCursor: Bool
    private var cursorHidden = false

    init(engine: VisualEngine, fps: Int, hidesCursor: Bool) {
        self.engine = engine
        self.hidesCursor = hidesCursor
        super.init(frame: .zero, device: MetalStage.shared.device)
        colorPixelFormat = MetalStage.pixelFormat
        framebufferOnly = true
        preferredFramesPerSecond = fps
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var restartObservers: [NSObjectProtocol] = []

    /// The view's display link can stall after a lock, sleep/wake or a move to
    /// another display, leaving a frozen or black preview. Kick it on each.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restartObservers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        restartObservers = []
        guard let window else { return }
        let kick: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.restartDrawing() }
        }
        restartObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                                                   object: window, queue: .main, using: kick),
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main, using: kick),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                              object: nil, queue: .main, using: kick),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                                              object: nil, queue: .main, using: kick),
        ]
    }

    private func restartDrawing() {
        isPaused = true
        isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var dbgLast: CFTimeInterval = 0
    func draw(in view: MTKView) {
        if ProcessInfo.processInfo.environment["MEKONG_DEBUG"] != nil, CACurrentMediaTime() - dbgLast > 1 {
            dbgLast = CACurrentMediaTime()
            FileHandle.standardError.write("draw fps=\(preferredFramesPerSecond) bounds=\(bounds.size) drawable=\(drawableSize) pass=\(currentRenderPassDescriptor != nil) paused=\(isPaused) win=\(window != nil) level=\(engine.u.level) onset=\(engine.u.onset) master=\(engine.u.master) scene=\(engine.u.sceneA) seed=\(engine.u.seed) inDb=\(engine.inputDb) presence=\(engine.u.presence)\n".data(using: .utf8)!)
        }
        MainActor.assumeIsolated { engine.step(now: CACurrentMediaTime()) }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = MetalStage.shared.queue.makeCommandBuffer() else { return }
        var u = MainActor.assumeIsolated { engine.u }
        u.width = Float(drawableSize.width)
        u.height = Float(drawableSize.height)
        let bands = MainActor.assumeIsolated { engine.bands }
        MetalStage.shared.encode(pass, into: cb, uniforms: u, bands: bands)
        cb.present(drawable)
        cb.commit()
    }

    // The stage hides the pointer while it's over the projection.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard hidesCursor else { return }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setCursorHidden(true) }
    override func mouseExited(with event: NSEvent) { setCursorHidden(false) }

    func setCursorHidden(_ hide: Bool) {
        guard hide != cursorHidden else { return }
        cursorHidden = hide
        hide ? NSCursor.hide() : NSCursor.unhide()
    }
}
