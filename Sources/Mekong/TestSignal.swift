import Foundation

/// A synthetic stand-in for the guitar: a slowly swelling low drone with
/// pentatonic plucks over it at irregular intervals, and a 6-second rest
/// every 25 seconds so the visuals' fade to silence can be seen. Fed straight into the
/// analyser (nothing is played out loud), so the visuals can be tuned
/// without an instrument plugged in.
final class TestSignal: @unchecked Sendable {
    private let analyzer: AudioAnalyzer
    private let sampleRate = 48000.0
    private let chunk = 480                    // 10 ms
    private var timer: DispatchSourceTimer?
    private var buffer: [Float]

    private var t = 0.0
    private var nextPluck = 0.5
    private var plucks: [(freq: Double, amp: Double, age: Double)] = []

    private static let drone: [(Double, Double)] = [(55, 0.30), (82.4, 0.18), (110, 0.14), (164.8, 0.08), (220.6, 0.05)]
    private static let scale: [Double] = [196, 220, 261.6, 293.7, 329.6, 392, 440, 523.3, 587.3, 659.3]

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
        buffer = [Float](repeating: 0, count: chunk)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mekong.test-signal", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        render(count: chunk)
        buffer.withUnsafeBufferPointer { analyzer.ingestMono($0.baseAddress!, count: chunk) }
    }

    /// Fills `buffer` with the next `count` samples.
    func render(count: Int) {
        let dt = 1 / sampleRate
        for i in 0..<count {
            t += dt
            if t >= nextPluck {
                plucks.append((Self.scale.randomElement()!, Double.random(in: 0.25...0.7), 0))
                // Mostly sparse, occasionally a quick run.
                nextPluck = t + (Double.random(in: 0...1) < 0.25 ? Double.random(in: 0.12...0.3)
                                                                   : Double.random(in: 0.6...2.8))
            }
            let swell = 0.55 + 0.45 * sin(2 * .pi * t / 23)
            var s = 0.0
            for (f, a) in Self.drone { s += a * sin(2 * .pi * f * t) }
            s *= swell * 0.5
            for k in plucks.indices {
                let env = plucks[k].amp * exp(-plucks[k].age / 1.1)
                for h in 1...5 {
                    s += env / Double(h) * sin(2 * .pi * plucks[k].freq * Double(h) * plucks[k].age)
                }
                plucks[k].age += dt
            }
            let cycle = t.truncatingRemainder(dividingBy: 25)
            let rest = min(max((cycle - 18) / 0.4, 0), 1) * min(max((24 - cycle) / 0.4, 0), 1)
            buffer[i] = Float(s * 0.3 * (1 - rest))
        }
        plucks.removeAll { $0.amp * exp(-$0.age / 1.1) < 0.001 }
    }

    /// Synchronous feed for snapshot rendering.
    func feed(seconds: Double) {
        var left = Int(seconds * sampleRate)
        while left > 0 {
            let n = min(chunk, left)
            render(count: n)
            buffer.withUnsafeBufferPointer { analyzer.ingestMono($0.baseAddress!, count: n) }
            left -= n
        }
    }

    /// Schedule a pluck right now (snapshot rendering wants an attack in frame).
    func pluckNow() { nextPluck = t }
}
