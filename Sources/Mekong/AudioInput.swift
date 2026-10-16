import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int
}

/// Owns the live input: lists devices, opens the chosen one and feeds every
/// buffer straight into the analyser. Uses an `AVAudioSinkNode` rather than a
/// tap because taps on macOS arrive in ~100 ms chunks — far too late for a
/// pluck to land on the beat visually. The sink runs at the device's own I/O
/// buffer size.
@MainActor
final class AudioInput: ObservableObject {
    static let testSignalUID = "mekong.test-signal"

    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var channelCount = 0
    @Published private(set) var status = ""
    @Published private(set) var isRunning = false

    let analyzer = AudioAnalyzer()

    private var engine: AVAudioEngine?
    private var test: TestSignal?
    private var currentUID = ""
    private var configObserver: NSObjectProtocol?

    init() {
        refreshDevices()
    }

    func refreshDevices() {
        devices = Self.inputDevices()
    }

    func start(uid: String) {
        stop()
        currentUID = uid
        refreshDevices()

        if uid == Self.testSignalUID {
            analyzer.configure(sampleRate: 48000)
            let t = TestSignal(analyzer: analyzer)
            t.start()
            test = t
            channelCount = 1
            status = "Test signal — a synthetic drone with plucks"
            isRunning = true
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            openEngine(uid: uid)
        case .notDetermined:
            status = "Waiting for microphone permission…"
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard self.currentUID == uid else { return }
                    if granted { self.openEngine(uid: uid) } else { self.denied() }
                }
            }
        default:
            denied()
        }
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine?.stop()
        engine = nil
        test?.stop()
        test = nil
        isRunning = false
    }

    private func denied() {
        status = "Microphone access is off — System Settings ▸ Privacy & Security ▸ Microphone"
        isRunning = false
    }

    private func openEngine(uid: String) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        let device = devices.first(where: { $0.uid == uid }) ?? Self.defaultDevice(in: devices)
        if !uid.isEmpty, let device, let au = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            status = "No audio input available"
            return
        }
        analyzer.configure(sampleRate: format.sampleRate)

        let analyzer = self.analyzer
        let sink = AVAudioSinkNode { _, frames, abl in
            analyzer.ingest(abl, frames: Int(frames))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)

        do {
            try engine.start()
        } catch {
            status = "Couldn't open input: \(error.localizedDescription)"
            return
        }

        self.engine = engine
        channelCount = Int(format.channelCount)
        status = "\(device?.name ?? "Input") · \(Int(format.sampleRate / 1000)) kHz · \(channelCount) ch"
        isRunning = true

        // Interface unplugged, sample rate changed, etc. — reopen.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.start(uid: self.currentUID)
            }
        }
    }

    // MARK: - CoreAudio device list

    private static func defaultDevice(in devices: [InputDevice]) -> InputDevice? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return devices.first(where: { $0.id == id })
    }

    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let ch = inputChannels(id)
            guard ch > 0 else { return nil }
            return InputDevice(id: id,
                               uid: string(id, kAudioDevicePropertyDeviceUID),
                               name: string(id, kAudioObjectPropertyName),
                               channels: ch)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let v = value else { return "" }
        return v.takeRetainedValue() as String
    }
}
