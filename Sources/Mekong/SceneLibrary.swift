import AppKit
import Metal
import MetalKit
import ImageIO

/// One selectable scene: built in, a shader file, or an image file.
struct SceneEntry: Identifiable, Equatable {
    enum Source: Equatable { case builtin, shader, image }

    let id: String          // stable key, saved in prefs ("grid", "shader:Tide.metal", …)
    let name: String
    let blurb: String
    let source: Source
    let code: Int           // dispatch code passed to the shader
    let texture: MTLTexture?

    static func == (a: SceneEntry, b: SceneEntry) -> Bool {
        a.id == b.id && a.code == b.code && a.texture === b.texture && a.blurb == b.blurb
    }
}

/// The built-in scenes plus whatever is in the Scenes folder, and the render
/// pipeline compiled for exactly that set.
///
/// The folder is checked every second. When anything in it changes, the
/// whole program is rebuilt off the main thread and swapped in, so a scene
/// can be edited while it's on the wall. Each shader file is first compiled
/// on its own; one that fails is listed with its error and left out rather
/// than taking the others down.
@MainActor
final class SceneLibrary: ObservableObject {
    static let shared = SceneLibrary()

    @Published private(set) var entries: [SceneEntry] = []
    /// File name → problem, for the console.
    @Published private(set) var issues: [String: String] = [:]
    @Published private(set) var isReloading = false

    private(set) var pipeline: MTLRenderPipelineState

    /// `MEKONG_SCENES_DIR` points elsewhere, for testing scenes without
    /// touching the real folder.
    let folder: URL = ProcessInfo.processInfo.environment["MEKONG_SCENES_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mekong/Scenes", isDirectory: true)

    private var signature = ""
    private var timer: Timer?

    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"]
    nonisolated static let styleNames = ["drift", "slices", "scan", "mosaic"]

    private init() {
        // Built-ins only to start with, so there is always a working pipeline.
        let built = try! Self.build(customs: [], images: [], folder: nil)
        pipeline = built.pipeline
        entries = built.entries
        createFolderIfNeeded()
    }

    /// Loads the folder synchronously (launch and `--snapshot`), then keeps
    /// watching it.
    func start(watch: Bool = true) {
        reload(sync: true)
        guard watch, timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForChanges() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func entry(_ id: String) -> SceneEntry? { entries.first(where: { $0.id == id }) }

    func openFolder() {
        createFolderIfNeeded()
        NSWorkspace.shared.open(folder)
    }

    func reloadNow() { reload(sync: false) }

    // MARK: - Loading

    private func checkForChanges() {
        guard !isReloading, currentSignature() != signature else { return }
        reload(sync: false)
    }

    private func currentSignature() -> String {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.map { url -> String in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.lastPathComponent)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(v?.fileSize ?? 0)"
        }.sorted().joined(separator: "\n")
    }

    private func reload(sync: Bool) {
        signature = currentSignature()
        let (customs, images) = scanFolder()
        let folder = self.folder
        if sync {
            apply(Result { try Self.build(customs: customs, images: images, folder: folder) })
            return
        }
        isReloading = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try Self.build(customs: customs, images: images, folder: folder) }
            await MainActor.run {
                self.apply(result)
                self.isReloading = false
            }
        }
    }

    private func apply(_ result: Result<Built, Error>) {
        switch result {
        case .success(let built):
            if ProcessInfo.processInfo.environment["MEKONG_DEBUG"] != nil {
                FileHandle.standardError.write("scenes: \(built.entries.map(\.name)) issues: \(built.issues)\n".data(using: .utf8)!)
            }
            pipeline = built.pipeline
            if entries != built.entries { entries = built.entries }
            issues = built.issues
        case .failure(let error):
            // Only reachable if the combined program fails after every file
            // passed on its own — keep the last good pipeline.
            issues = ["Scenes": error.localizedDescription]
        }
    }

    private func scanFolder() -> (customs: [(file: String, code: String)], images: [String]) {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var customs: [(String, String)] = []
        var images: [String] = []
        for f in files {
            let ext = (f as NSString).pathExtension.lowercased()
            if ext == "metal", let code = try? String(contentsOf: folder.appendingPathComponent(f), encoding: .utf8) {
                customs.append((f, code))
            } else if Self.imageExtensions.contains(ext) {
                images.append(f)
            }
        }
        return (customs, images)
    }

    // MARK: - Building (any thread)

    private struct Built {
        let pipeline: MTLRenderPipelineState
        let entries: [SceneEntry]
        let issues: [String: String]
    }

    private nonisolated static func build(customs: [(file: String, code: String)], images: [String],
                                          folder: URL?) throws -> Built {
        let device = MetalStage.shared.device
        var issues: [String: String] = [:]
        var entries = SceneKind.allCases.map {
            SceneEntry(id: $0.key, name: $0.name, blurb: $0.blurb, source: .builtin, code: $0.rawValue, texture: nil)
        }

        // Shader files: probe each alone, keep the ones that compile.
        var good: [(namespace: String, file: String, code: String)] = []
        for c in customs {
            do {
                _ = try device.makeLibrary(source: Shaders.probe(c.code, file: c.file), options: nil)
                let index = good.count
                good.append(("user\(index)", c.file, c.code))
                let meta = Self.header(c.code)
                entries.append(SceneEntry(id: "shader:\(c.file)",
                                          name: meta.name ?? Self.title(c.file),
                                          blurb: meta.blurb ?? "Custom scene from \(c.file).",
                                          source: .shader, code: Shaders.Code.custom(index), texture: nil))
            } catch {
                issues[c.file] = Self.firstError(error)
            }
        }

        // Images, with an optional same-named .json beside them.
        if let folder {
            for f in images {
                let url = folder.appendingPathComponent(f)
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                var cfg = ImageConfig()
                if let data = try? Data(contentsOf: sidecar) {
                    do { cfg = try JSONDecoder().decode(ImageConfig.self, from: data) }
                    catch { issues[sidecar.lastPathComponent] = "Couldn't read settings: \(error.localizedDescription)" }
                }
                let style = Self.styleNames.firstIndex(of: (cfg.style ?? "drift").lowercased())
                if style == nil { issues[f] = "Unknown style “\(cfg.style ?? "")” — use \(Self.styleNames.joined(separator: ", ")). Using drift." }
                guard let texture = Self.loadTexture(url, device: device) else {
                    issues[f] = "Couldn't open this image."
                    continue
                }
                let styleName = Self.styleNames[style ?? 0]
                entries.append(SceneEntry(id: "image:\(f)",
                                          name: cfg.name ?? Self.title(f),
                                          blurb: cfg.description ?? "Image scene, \(styleName)\(cfg.mono == true ? ", monochrome" : "").",
                                          source: .image,
                                          code: Shaders.Code.image(style: style ?? 0, mono: cfg.mono == true),
                                          texture: texture))
            }
        }

        let lib = try device.makeLibrary(source: Shaders.program(customs: good), options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "vmain")
        desc.fragmentFunction = lib.makeFunction(name: "fmain")
        desc.colorAttachments[0].pixelFormat = MetalStage.pixelFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        return Built(pipeline: pipeline, entries: entries, issues: issues)
    }

    struct ImageConfig: Decodable {
        var name: String?
        var description: String?
        var style: String?
        var mono: Bool?
    }

    /// Reads `// Name:` and `// Description:` from the top of a shader file.
    private nonisolated static func header(_ code: String) -> (name: String?, blurb: String?) {
        var name: String?, blurb: String?
        for line in code.split(separator: "\n").prefix(15) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("// Name:") { name = String(t.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("// Description:") { blurb = String(t.dropFirst(15)).trimmingCharacters(in: .whitespaces) }
        }
        return (name, blurb)
    }

    private nonisolated static func title(_ file: String) -> String {
        (file as NSString).deletingPathExtension
    }

    /// The compiler's first error line, already pointing at the user's file
    /// thanks to `#line` ("Tide.metal:12:5: error: …").
    private nonisolated static func firstError(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        let lines = text.split(separator: "\n").map(String.init)
        return lines.first(where: { $0.contains("error:") }) ?? lines.first ?? text
    }

    /// Downscaled to at most 2048 px (orientation applied) — plenty for a
    /// projector, and keeps a folder of camera photos from eating memory.
    /// Drawn into a plain 8-bit RGBA sRGB buffer first, so 16-bit, alpha,
    /// HEIC and wide-gamut images all arrive the same way (MTKTextureLoader
    /// misread some of them, shifting colours towards blue).
    private nonisolated static func loadTexture(_ url: URL, device: MTLDevice) -> MTLTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        // Transparent areas read as black, like everything else on the wall.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return tex
    }

    // MARK: - First run

    private func createFolderIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try? CustomScenesGuide.readme.write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try? CustomScenesGuide.example.write(to: folder.appendingPathComponent("Tide.metal"), atomically: true, encoding: .utf8)
    }
}

extension SceneKind {
    /// Stable key saved in prefs.
    var key: String { name.lowercased() }
}
