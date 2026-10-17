import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Headless check of the whole chain: synthetic audio → analyser → engine →
/// shader → PNG, one per scene (built-in and from the Scenes folder), 1280×720,
/// plus two frames of the CRT collapse. Also prints any Scenes-folder errors.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        let library = SceneLibrary.shared
        library.start(watch: false)
        for (file, problem) in library.issues.sorted(by: { $0.key < $1.key }) {
            print("⚠︎ \(file): \(problem)")
        }

        let analyzer = AudioAnalyzer()
        let engine = VisualEngine(analyzer: analyzer, settings: AppSettings.shared, library: library)
        let signal = TestSignal(analyzer: analyzer)

        var now: CFTimeInterval = 1
        func advance(_ seconds: Double) {
            var left = seconds
            while left > 0 {
                signal.feed(seconds: 1.0 / 60)
                now += 1.0 / 60
                engine.step(now: now)
                left -= 1.0 / 60
            }
        }

        advance(4)
        for (i, scene) in library.entries.enumerated() {
            signal.pluckNow()
            advance(0.1)    // land just after an attack
            engine.force(scene: scene)
            let slug = scene.name.lowercased().replacingOccurrences(of: " ", with: "-")
            write(engine, scene: scene, presence: nil,
                  to: (dir as NSString).appendingPathComponent(String(format: "mekong-%02d-%@.png", i + 1, slug)))
        }

        // Ribbons played softly and hard, to check it follows dynamics.
        if let ribbons = library.entry(SceneKind.ribbons.key) {
            for (label, level) in [("ribbons-soft", Float(0.2)), ("ribbons-hard", Float(0.9))] {
                write(engine, scene: ribbons, presence: nil, level: level,
                      to: (dir as NSString).appendingPathComponent("mekong-\(label).png"))
            }
        }

        // The CRT collapse, part way: line phase and dot phase.
        if let grid = library.entry(SceneKind.grid.key) {
            for (label, presence) in [("crt-line", Float(0.55)), ("crt-dot", Float(0.12))] {
                write(engine, scene: grid, presence: presence,
                      to: (dir as NSString).appendingPathComponent("mekong-\(label).png"))
            }
        }
    }

    private static func write(_ engine: VisualEngine, scene: SceneEntry, presence: Float?,
                              level: Float? = nil, to path: String) {
        var u = engine.u
        if let level { u.level = level }
        u.width = 1280; u.height = 720
        u.sceneA = Float(scene.code); u.sceneB = Float(scene.code); u.mixAB = 0
        if let presence { u.presence = presence }
        guard let img = MetalStage.shared.image(pipeline: engine.pipeline, uniforms: u, bands: engine.bands,
                                                texture: scene.texture),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print(path)
    }
}
