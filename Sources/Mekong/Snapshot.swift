import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Headless check of the whole chain: synthetic audio → analyser → engine →
/// shader → PNG, one per scene, 1280×720.
@MainActor
enum Snapshot {
    static func run(to dir: String) {
        let analyzer = AudioAnalyzer()
        let engine = VisualEngine(analyzer: analyzer, settings: AppSettings.shared)
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
        for scene in SceneKind.allCases {
            engine.force(scene: scene.rawValue)
            signal.pluckNow()
            advance(0.1)    // land just after an attack
            var u = engine.u
            u.width = 1280
            u.height = 720
            u.sceneA = Float(scene.rawValue)
            u.mixAB = 0
            let path = (dir as NSString).appendingPathComponent("mekong-\(scene.rawValue + 1)-\(scene.name.lowercased()).png")
            if let img = MetalStage.shared.image(uniforms: u, bands: engine.bands),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                          UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print(String(format: "%@  level %.2f  onset %.2f  seed %.0f", path, u.level, u.onset, u.seed))
            }
        }

        // The CRT collapse, part way: line phase and dot phase.
        for (label, presence) in [("crt-line", Float(0.55)), ("crt-dot", Float(0.12))] {
            var u = engine.u
            u.width = 1280; u.height = 720
            u.sceneA = 1; u.mixAB = 0; u.presence = presence
            write(u, bands: engine.bands, to: (dir as NSString).appendingPathComponent("mekong-\(label).png"))
        }
    }

    private static func write(_ u: Uniforms, bands: [Float], to path: String) {
        if let img = MetalStage.shared.image(uniforms: u, bands: bands),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            print(path)
        }
    }
}
