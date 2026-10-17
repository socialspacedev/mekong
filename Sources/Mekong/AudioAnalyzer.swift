import Foundation
import Accelerate
import CoreAudio
import os

/// Turns the raw input into a handful of numbers the visuals react to:
/// loudness, 32 log-spaced band energies, spectral brightness, and discrete
/// attacks (onsets). Runs on the audio thread every 512 samples (~94×/s at
/// 48 kHz) over a 2048-sample FFT window.
///
/// Attacks are found by spectral flux against an adaptive threshold, so a
/// sustained drone — however loud — doesn't trigger them, but a pluck over it
/// does.
final class AudioAnalyzer: @unchecked Sendable {
    struct Params {
        var channel = -1          // -1 = mix all
        var autoLevel = true
        var gainDb: Float = 0
        var sensitivity: Float = 0.5
        var gateDb: Float = -55     // below this the input counts as silence
    }

    /// What the main thread reads each frame.
    struct Snapshot {
        var level: Float = 0
        var inputDb: Float = -120   // raw input loudness, for the console meter
        var gateOpen = false
        var centroid: Float = 0
        var onsetCount = 0
        var onsetStrength: Float = 0
    }

    static let bandCount = 32
    private static let n = 2048
    private static let hop = 512
    private static let log2n = vDSP_Length(11)

    private let setup: FFTSetup
    private let window: [Float]

    // Audio-thread state. Only touched from whichever thread feeds `ingest`.
    private var ring = [Float](repeating: 0, count: n)
    private var ringPos = 0
    private var pending = 0
    private var frame = [Float](repeating: 0, count: n)
    private var real = [Float](repeating: 0, count: n / 2)
    private var imag = [Float](repeating: 0, count: n / 2)
    private var mags = [Float](repeating: 0, count: n / 2)
    private var mono = [Float](repeating: 0, count: 8192)
    private var sampleRate: Float = 48000
    private var bandRanges: [(Int, Int)] = []
    private var bandTilt: [Float] = []
    private var bands = [Float](repeating: 0, count: bandCount)
    private var prevBands = [Float](repeating: 0, count: bandCount)
    private var fluxHistory = [Float](repeating: 0, count: 48)
    private var fluxPos = 0
    private var peakDb: Float = -30
    private var bandPeakDb: Float = -20
    private var hopsSinceOnset = 1000
    private var onsets = 0

    private let params = OSAllocatedUnfairLock(initialState: Params())
    private let latest = OSAllocatedUnfairLock(initialState: (Snapshot(), [Float](repeating: 0, count: bandCount)))

    init() {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.n, isHalfWindow: false)
        configure(sampleRate: 48000)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Call before audio starts flowing (never while it is).
    func configure(sampleRate sr: Double) {
        sampleRate = Float(sr)
        let binHz = sampleRate / Float(Self.n)
        let lo: Float = 40, hi: Float = min(14000, sampleRate * 0.45)
        bandRanges = []
        bandTilt = []
        for k in 0..<Self.bandCount {
            let f0 = lo * powf(hi / lo, Float(k) / Float(Self.bandCount))
            let f1 = lo * powf(hi / lo, Float(k + 1) / Float(Self.bandCount))
            let b0 = max(1, Int(f0 / binHz))
            let b1 = max(b0 + 1, min(Self.n / 2, Int(f1 / binHz)))
            bandRanges.append((b0, b1))
            // +3 dB/octave so a guitar's upper partials register against the
            // drone's low-end weight instead of always reading as nothing.
            bandTilt.append(3 * log2f(sqrtf(f0 * f1) / 250))
        }
        ring = [Float](repeating: 0, count: Self.n)
        ringPos = 0
        pending = 0
    }

    func setParams(_ p: Params) { params.withLock { $0 = p } }

    /// Copies the latest features out. `bandsOut` must hold `bandCount` values.
    func read(into bandsOut: inout [Float]) -> Snapshot {
        let (snap, b) = latest.withLock { $0 }
        for i in 0..<Self.bandCount { bandsOut[i] = b[i] }
        return snap
    }

    // MARK: - Feeding

    /// Audio-thread entry point from the input sink.
    func ingest(_ abl: UnsafePointer<AudioBufferList>, frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let channel = params.withLock { $0.channel }

        // Flatten whatever layout arrives (normally one buffer per channel)
        // into a list of (buffer, stride, offset) per channel.
        var totalChannels = 0
        for b in list { totalChannels += Int(b.mNumberChannels) }
        guard totalChannels > 0 else { return }

        var done = 0
        while done < frames {
            let count = min(frames - done, mono.count)
            mono.withUnsafeMutableBufferPointer { m in
                for i in 0..<count { m[i] = 0 }
                var chIndex = 0
                var used = 0
                for b in list {
                    let nch = Int(b.mNumberChannels)
                    guard let data = b.mData?.assumingMemoryBound(to: Float.self) else {
                        chIndex += nch; continue
                    }
                    for c in 0..<nch {
                        if channel < 0 || channel == chIndex {
                            for i in 0..<count { m[i] += data[(done + i) * nch + c] }
                            used += 1
                        }
                        chIndex += 1
                    }
                }
                if used > 1 {
                    let s = 1 / Float(used)
                    for i in 0..<count { m[i] *= s }
                }
            }
            mono.withUnsafeBufferPointer { push($0.baseAddress!, count) }
            done += count
        }
    }

    /// Mono entry point, used by the built-in test signal.
    func ingestMono(_ src: UnsafePointer<Float>, count: Int) { push(src, count) }

    private func push(_ src: UnsafePointer<Float>, _ count: Int) {
        var i = 0
        while i < count {
            let take = min(count - i, Self.hop - pending)
            for j in 0..<take {
                ring[ringPos] = src[i + j]
                ringPos = (ringPos + 1) & (Self.n - 1)
            }
            pending += take
            i += take
            if pending == Self.hop {
                pending = 0
                analyse()
            }
        }
    }

    // MARK: - Analysis

    private func analyse() {
        let n = Self.n
        let p = params.withLock { $0 }
        let hopSeconds = Float(Self.hop) / sampleRate

        // Oldest-first copy of the ring.
        let tail = n - ringPos
        frame.withUnsafeMutableBufferPointer { f in
            ring.withUnsafeBufferPointer { r in
                for i in 0..<tail { f[i] = r[ringPos + i] }
                for i in 0..<ringPos { f[tail + i] = r[i] }
            }
        }

        // Loudness over the most recent half-window, so it tracks quickly.
        var rms: Float = 0
        frame.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + n / 2, 1, &rms, vDSP_Length(n / 2)) }
        let rmsDb = 20 * log10f(rms + 1e-9)

        let reference: Float
        if p.autoLevel {
            // Follow the loudest recent playing, letting go at 3 dB/s, but
            // never chase below -50 dB or silence gets amplified into noise.
            // Never chase far below the gate, or room noise gets amplified
            // into activity.
            peakDb = max(rmsDb, peakDb - 3 * hopSeconds, p.gateDb + 24)
            reference = peakDb + 3
        } else {
            reference = -6 - p.gainDb
        }
        let range: Float = 30
        let gateOpen = rmsDb > p.gateDb
        let level = gateOpen ? min(1, max(0, (rmsDb - (reference - range)) / range)) : 0

        // FFT → power spectrum.
        frame.withUnsafeMutableBufferPointer { f in
            vDSP_vmul(f.baseAddress!, 1, window, 1, f.baseAddress!, 1, vDSP_Length(n))
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { m in
                        vDSP_zvmags(&split, 1, m.baseAddress!, 1, vDSP_Length(n / 2))
                    }
                }
            }
        }

        // Bands in dB, normalised against their own slowly-falling peak.
        var maxDb: Float = -200
        var bandDb = [Float](repeating: 0, count: Self.bandCount)
        mags.withUnsafeBufferPointer { m in
            for k in 0..<Self.bandCount {
                let (b0, b1) = bandRanges[k]
                var sum: Float = 0
                for b in b0..<b1 { sum += m[b] }
                let db = 10 * log10f(sum / Float(b1 - b0) + 1e-12) + bandTilt[k]
                bandDb[k] = db
                maxDb = max(maxDb, db)
            }
        }
        bandPeakDb = max(maxDb, bandPeakDb - 4 * hopSeconds)
        let gate = min(1, level * 5)          // silence → empty bands
        for k in 0..<Self.bandCount {
            let v = (bandDb[k] - (bandPeakDb - 50)) / 50
            bands[k] = min(1, max(0, v)) * gate
        }

        // Spectral brightness: amplitude-weighted mean frequency, log-scaled.
        var num: Float = 0, den: Float = 0
        let binHz = sampleRate / Float(n)
        mags.withUnsafeBufferPointer { m in
            let top = min(n / 2, Int(12000 / binHz))
            for b in 2..<top {
                let a = sqrtf(m[b])
                num += a * Float(b) * binHz
                den += a
            }
        }
        let centroidHz = den > 0 ? num / den : 40
        let centroid = min(1, max(0, log2f(max(centroidHz, 40) / 40) / log2f(300)))

        // Attacks: positive spectral flux above mean + k·σ of the last ~0.5 s.
        var flux: Float = 0
        for k in 0..<Self.bandCount { flux += max(0, bands[k] - prevBands[k]) }
        flux /= Float(Self.bandCount)
        swap(&bands, &prevBands)   // prevBands now holds this hop's bands

        var mean: Float = 0, sq: Float = 0
        for v in fluxHistory { mean += v; sq += v * v }
        mean /= Float(fluxHistory.count)
        let sd = sqrtf(max(0, sq / Float(fluxHistory.count) - mean * mean))
        fluxHistory[fluxPos] = flux
        fluxPos = (fluxPos + 1) % fluxHistory.count

        let s = min(1, max(0, p.sensitivity))
        let threshold = mean + (3.0 - 2.2 * s) * sd + (0.035 - 0.025 * s)
        hopsSinceOnset += 1
        let minGap = Int(0.08 / hopSeconds)
        var strength: Float = -1
        if flux > threshold, level > 0.05, hopsSinceOnset >= minGap {
            hopsSinceOnset = 0
            onsets &+= 1
            strength = min(1, (flux - threshold) / max(threshold, 0.01))
        }

        let count = onsets
        let attack = strength
        let current = prevBands
        latest.withLock { state in
            state.0.level = level
            state.0.inputDb = rmsDb
            state.0.gateOpen = gateOpen
            state.0.centroid = centroid
            if attack >= 0 {
                state.0.onsetCount = count
                state.0.onsetStrength = attack
            }
            state.1 = current
        }
    }
}
