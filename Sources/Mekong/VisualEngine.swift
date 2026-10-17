import Foundation
import QuartzCore
import Metal

/// Must match `struct U` in Shaders.swift field for field — 24 Floats.
struct Uniforms {
    var time: Float = 0, width: Float = 0, height: Float = 0, level: Float = 0
    var onset: Float = 0, centroid: Float = 0, low: Float = 0, mid: Float = 0
    var high: Float = 0, seed: Float = 0, flash: Float = 0, density: Float = 0
    var intensity: Float = 1, master: Float = 1, sceneA: Float = 0, sceneB: Float = 0
    var mixAB: Float = 0, palette: Float = 0, tick: Float = 0, scroll: Float = 0
    var presence: Float = 0, pad1: Float = 0, pad2: Float = 0, pad3: Float = 0
}

/// Sits between the analyser and the shader: smooths the raw features at the
/// console's response setting, turns attacks into decaying envelopes and a
/// re-scramble seed, integrates the "clocks" the scenes step by, and handles
/// scene crossfades and blackout. Time-based, so the preview and the stage
/// can both call `step` each frame without double-counting anything.
@MainActor
final class VisualEngine {
    private let analyzer: AudioAnalyzer
    private let settings: AppSettings
    private let library: SceneLibrary

    private(set) var u = Uniforms()
    private(set) var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private(set) var drone: Float = 0
    private(set) var lastOnsetTime: CFTimeInterval = 0
    private(set) var inputDb: Float = -120
    private(set) var gateOpen = false

    var blackout = false

    private var raw = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var start: CFTimeInterval = 0
    private var lastUpdate: CFTimeInterval = 0
    private var lastOnsetCount = 0
    private var lastFlash: CFTimeInterval = -10
    private var lastSound: CFTimeInterval = -10
    private var lastSceneChange: CFTimeInterval = 0
    private var currentScene: SceneEntry?
    private var targetScene: SceneEntry?

    /// Images for the two scenes being drawn (nil for non-image scenes).
    var textureA: MTLTexture? { currentScene?.texture }
    var textureB: MTLTexture? { targetScene?.texture }
    var pipeline: MTLRenderPipelineState { library.pipeline }

    init(analyzer: AudioAnalyzer, settings: AppSettings, library: SceneLibrary) {
        self.analyzer = analyzer
        self.settings = settings
        self.library = library
    }

    func step(now: CFTimeInterval) {
        if start == 0 { start = now; lastUpdate = now; lastSceneChange = now }
        let elapsed = now - lastUpdate
        guard elapsed > 0.002 else { return }
        lastUpdate = now
        let dt = Float(min(elapsed, 0.1))
        let p = settings.prefs

        analyzer.setParams(.init(channel: p.channel, autoLevel: p.autoLevel,
                                 gainDb: Float(p.gainDb), sensitivity: Float(p.attackSensitivity),
                                 gateDb: Float(p.gateDb)))
        let f = analyzer.read(into: &raw)
        inputDb = f.inputDb
        gateOpen = f.gateOpen

        func follow(_ cur: inout Float, _ target: Float, _ attack: Float, _ release: Float) {
            let tau = target > cur ? attack : release
            cur += (target - cur) * (1 - expf(-dt / tau))
        }
        // Presence: the picture opens out of a pinpoint when sound arrives and
        // collapses back into one, like an old CRT switching off, after a
        // couple of seconds of silence. The hold stops it collapsing in the
        // gaps between notes. Linear ramps; the shader shapes the two phases.
        if f.gateOpen { lastSound = now }
        let sounding = now - lastSound < 2.0
        u.presence = min(1, max(0, u.presence + (sounding ? dt / 0.9 : -dt / 1.3)))

        let r = Float(p.response)
        let atk = 0.015 + 0.12 * r, rel = 0.08 + 1.0 * r
        follow(&u.level, f.level, atk, rel)
        for i in bands.indices { follow(&bands[i], raw[i], atk, rel) }
        follow(&u.centroid, f.centroid, 0.2, 0.6)
        u.low = avg(0..<8); u.mid = avg(8..<20); u.high = avg(20..<32)
        follow(&drone, u.low, 1.5, 3.0)

        if f.onsetCount != lastOnsetCount {
            lastOnsetCount = f.onsetCount
            u.onset = max(u.onset, 0.45 + 0.55 * f.onsetStrength)
            u.seed += 1
            lastOnsetTime = now
            // Full-field inversions, capped at 3 per second (the WCAG
            // general-flash limit) because this is going on a wall in a room.
            if p.flashes, f.onsetStrength > 0.5, now - lastFlash > 1.0 / 3.0 {
                u.flash = 1
                lastFlash = now
            }
        }
        u.onset *= expf(-dt / 0.22)
        u.flash *= expf(-dt / 0.07)

        let m = Float(0.2 + 1.8 * p.motion)
        u.tick += dt * (0.4 + 9 * powf(u.level, 1.4)) * m
        u.scroll += dt * (0.04 + 0.7 * u.level) * m
        // Keep the clocks small so float precision holds over a long set.
        if u.tick > 10_000 { u.tick -= 10_000 }
        if u.scroll > 1_000 { u.scroll -= 1_000 }

        follow(&u.master, blackout ? 0 : 1, 0.5, 0.5)

        // Scene changes: auto-advance, then crossfade over ~1.2 s. Entries are
        // looked up fresh every frame, so a scene whose file was edited (new
        // code or texture) or removed is picked up straight away.
        if p.autoSceneMinutes > 0, now - lastSceneChange > Double(p.autoSceneMinutes) * 60 {
            let others = library.entries.map(\.id).filter { $0 != p.sceneKey }
            settings.prefs.sceneKey = others.randomElement() ?? SceneKind.barcode.key
        }
        let wanted = library.entry(settings.prefs.sceneKey) ?? library.entries[0]
        currentScene = currentScene.flatMap { library.entry($0.id) } ?? wanted
        targetScene = targetScene.flatMap { library.entry($0.id) } ?? wanted
        if wanted.id != targetScene?.id {
            if u.mixAB > 0 { currentScene = targetScene }
            targetScene = wanted
            u.mixAB = 0.0001
            lastSceneChange = now
        }
        if targetScene?.id != currentScene?.id {
            u.mixAB += dt / 1.2
            if u.mixAB >= 1 { currentScene = targetScene; u.mixAB = 0 }
        } else {
            u.mixAB = 0
        }
        u.sceneA = Float(currentScene?.code ?? 0)
        u.sceneB = Float(targetScene?.code ?? 0)

        u.density = Float(p.density)
        u.intensity = Float(0.25 + 1.0 * p.brightness)
        u.palette = Float(p.palette)
        u.time = Float((now - start).truncatingRemainder(dividingBy: 3600))
    }

    /// Jump straight to a scene with no crossfade (snapshot rendering).
    func force(scene: SceneEntry) {
        currentScene = scene; targetScene = scene; u.mixAB = 0
        u.sceneA = Float(scene.code); u.sceneB = Float(scene.code)
    }

    private func avg(_ r: Range<Int>) -> Float {
        var s: Float = 0
        for i in r { s += bands[i] }
        return s / Float(r.count)
    }
}
