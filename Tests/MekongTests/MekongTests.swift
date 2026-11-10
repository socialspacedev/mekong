import CoreAudio
import Foundation
import Testing
@testable import Mekong

/// Feeds `seconds` of a sine through `ingest` as a buffer list of `channels`
/// channels, with the sine on `loud` only and silence on the rest.
private func feed(_ analyzer: AudioAnalyzer, channels: Int, loud: Int, seconds: Double = 0.5) {
    let frames = 512
    let list = AudioBufferList.allocate(maximumBuffers: channels)
    defer {
        for b in list { b.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for c in 0..<channels {
        list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                              mData: UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16))
    }
    var t = 0
    for _ in 0..<Int(seconds * 48000) / frames {
        for c in 0..<channels {
            let data = list[c].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { data[i] = c == loud ? 0.3 * sinf(2 * .pi * 220 * Float(t + i) / 48000) : 0 }
        }
        analyzer.ingest(list.unsafePointer, frames: frames)
        t += frames
    }
}

private func snapshot(_ analyzer: AudioAnalyzer) -> AudioAnalyzer.Snapshot {
    var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    return analyzer.read(into: &bands)
}

@Suite struct AnalyzerTests {
    @Test func chosenChannelIsHeard() {
        let analyzer = AudioAnalyzer()
        analyzer.setParams(.init(channel: 1))
        feed(analyzer, channels: 2, loud: 1)
        #expect(snapshot(analyzer).inputDb > -30)
    }

    @Test func channelMissingFromThisDeviceMixesInstead() {
        // Channel 2 saved for a two-channel interface, then the built-in mic.
        let analyzer = AudioAnalyzer()
        analyzer.setParams(.init(channel: 1))
        feed(analyzer, channels: 1, loud: 0)
        #expect(snapshot(analyzer).inputDb > -30, "not silent")
        #expect(snapshot(analyzer).gateOpen)
    }

    @Test func testSignalPlucksAreAttacksAndSilenceClosesTheGate() {
        let analyzer = AudioAnalyzer()
        TestSignal(analyzer: analyzer).feed(seconds: 15)
        #expect(snapshot(analyzer).onsetCount > 0)

        let silence = [Float](repeating: 0, count: 48000)
        silence.withUnsafeBufferPointer { analyzer.ingestMono($0.baseAddress!, count: $0.count) }
        let quiet = snapshot(analyzer)
        #expect(!quiet.gateOpen)
        #expect(quiet.level == 0)
    }

    @Test func stoppingTheTestSignalLetsTheAnalyzerBeReconfigured() {
        let analyzer = AudioAnalyzer()
        for _ in 0..<20 {
            let signal = TestSignal(analyzer: analyzer)
            signal.start()
            usleep(15_000)
            signal.stop()
            analyzer.configure(sampleRate: 44100)   // must never overlap a tick
        }
    }
}

@Suite struct SceneTests {
    private static func scene(_ body: String) -> String {
        "float3 scene(float2 px, constant U& u, constant float* b) { \(body) }"
    }

    @Test func badFilesAreLeftOutAndTheRestStillLoad() throws {
        let good = (file: "Good.metal", code: "// Name: Good\n" + Self.scene("return mono(u.level, u);"))
        let broken = (file: "Broken.metal", code: Self.scene("return nonsense;"))
        // Compiles alone, but breaks Mekong's own code, which uses `k`.
        let macro = (file: "Macro.metal", code: "#define k 2.0\n" + Self.scene("return float3(k);"))
        // Each fine alone; together the first's #define breaks the second.
        let first = (file: "First.metal", code: "#define SHINE 2.0\n" + Self.scene("return float3(SHINE * 0.1);"))
        let second = (file: "Second.metal", code: "float SHINE(float x) { return x; }\n" + Self.scene("return float3(SHINE(0.5));"))

        let built = try SceneLibrary.build(customs: [good, broken, macro, first, second], images: [], folder: nil)
        let shaders = built.entries.filter { $0.source == .shader }
        #expect(shaders.map(\.file) == ["Good.metal", "First.metal"])
        #expect(shaders.map(\.name) == ["Good", "First"])
        #expect(shaders.map(\.code) == [100, 101], "dispatch codes follow the scenes that made it")
        #expect(built.issues["Broken.metal"]?.contains("Broken.metal") == true, "points at the user's file")
        #expect(built.issues["Macro.metal"]?.contains("built-in") == true)
        #expect(built.issues["Second.metal"]?.contains("Clashes") == true)
        #expect(built.entries.filter { $0.source == .builtin }.count == SceneKind.allCases.count)
    }

    @Test func corruptImagesAreReported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MekongTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not a picture".utf8).write(to: folder.appendingPathComponent("bad.png"))

        let built = try SceneLibrary.build(customs: [], images: ["bad.png"], folder: folder)
        #expect(built.issues["bad.png"] == "Couldn't open this image.")
        #expect(!built.entries.contains { $0.source == .image })
    }
}

@Suite struct SettingsTests {
    @Test func olderSavedSettingsStillLoad() throws {
        // An early version: scene saved by number, and no newer keys at all.
        let old = try JSONSerialization.data(withJSONObject: ["scene": 2, "brightness": 0.4, "channel": 1])
        let prefs = try #require(AppSettings.decode(old))
        #expect(prefs.sceneKey == "horizon")
        #expect(prefs.brightness == 0.4)
        #expect(prefs.channel == 1)
        #expect(prefs.gateDb == Prefs().gateDb, "missing keys take their defaults")
    }

    @Test func unreadableSettingsAreIgnored() {
        #expect(AppSettings.decode(Data("{".utf8)) == nil)
    }
}
