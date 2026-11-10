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
/// buffer straight into the analyser.
///
/// Uses an input-only HAL unit rather than AVAudioEngine. AVAudioEngine ties
/// its input to the system *output* device: switching the Mac's output
/// reconfigured the engine and crashed the reconnect, and an interface used
/// only as an input (e.g. an M-Audio AIR alongside the built-in speakers)
/// could deliver silence. A HAL unit with output disabled has no output side
/// to disturb, and it delivers at the device's own buffer size, so attacks
/// land on time.
@MainActor
final class AudioInput: ObservableObject {
    static let testSignalUID = "mekong.test-signal"

    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var channelCount = 0
    @Published private(set) var status = ""
    @Published private(set) var isRunning = false

    let analyzer = AudioAnalyzer()

    private var hal: HALInput?
    private var test: TestSignal?
    private var currentUID = ""
    private var openedDevice: AudioDeviceID = 0
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// On the open device only; replaced each time a device is opened.
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refreshDevices()
        watchHardware()
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
            status = "Test signal — a synthetic drone with plucks and rests"
            isRunning = true
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            open(uid: uid)
        case .notDetermined:
            status = "Waiting for microphone permission…"
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    guard self.currentUID == uid else { return }
                    if granted { self.open(uid: uid) } else { self.denied() }
                }
            }
        default:
            denied()
        }
    }

    func stop() {
        for (object, addr, block) in deviceListeners {
            var addr = addr
            AudioObjectRemovePropertyListenerBlock(object, &addr, nil, block)
        }
        deviceListeners = []
        hal?.stop()
        hal = nil
        test?.stop()
        test = nil
        openedDevice = 0
        isRunning = false
    }

    private func denied() {
        status = "Microphone access is off — System Settings ▸ Privacy & Security ▸ Microphone"
        isRunning = false
    }

    private func open(uid: String) {
        let device = uid.isEmpty ? Self.defaultInput(in: devices)
                                 : devices.first(where: { $0.uid == uid })
        guard let device else {
            status = uid.isEmpty ? "No audio input available"
                                 : "Selected input isn't connected — plug it in or pick another"
            return
        }
        do {
            let hal = try HALInput(device: device.id, analyzer: analyzer)
            self.hal = hal
            openedDevice = device.id
            channelCount = hal.channels
            status = "\(device.name) · \(Int(hal.sampleRate / 1000)) kHz · \(hal.channels) ch"
            isRunning = true
            watchDevice(device.id)
        } catch {
            status = "Couldn't open \(device.name) (\(error.localizedDescription))"
        }
    }

    // MARK: - Hardware changes

    /// Reopen when the device list changes (interface plugged/unplugged), or
    /// when the system default input changes while we're following it.
    /// Output changes are irrelevant now.
    private func watchHardware() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        listen(system, kAudioHardwarePropertyDevices) { [weak self] in
            guard let self else { return }
            let before = Set(self.devices.map(\.uid))
            self.refreshDevices()
            let after = Set(self.devices.map(\.uid))
            guard before != after, self.currentUID != Self.testSignalUID else { return }
            let stillThere = self.devices.contains(where: { $0.id == self.openedDevice })
            if !stillThere || !self.isRunning { self.start(uid: self.currentUID) }
        }
        listen(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            guard let self, self.currentUID.isEmpty else { return }
            self.start(uid: "")
        }
    }

    /// Reopen when the open device changes sample rate (a DAW or Audio MIDI
    /// Setup can do this mid-set; the input unit can't convert, so every render
    /// would fail and the visuals go dark) or stops being usable.
    private func watchDevice(_ id: AudioDeviceID) {
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            deviceListeners.append(addListener(id, selector) { [weak self] in
                guard let self, self.openedDevice == id else { return }
                self.start(uid: self.currentUID)
            })
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ action: @escaping @MainActor () -> Void) {
        listeners.append(addListener(object, selector, action))
    }

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ action: @escaping @MainActor () -> Void)
        -> (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock) {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
        }
        AudioObjectAddPropertyListenerBlock(object, &addr, nil, block)
        return (object, addr, block)
    }

    // MARK: - CoreAudio device list

    private static func defaultInput(in devices: [InputDevice]) -> InputDevice? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return devices.first(where: { $0.id == id }) ?? devices.first
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

/// One open input device: an AUHAL unit with input enabled and output
/// disabled, pulling float32 non-interleaved audio in its input callback.
private final class HALInput: @unchecked Sendable {
    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) failed, OSStatus \(status)" }
    }

    let unit: AudioUnit
    let analyzer: AudioAnalyzer
    let channels: Int
    let sampleRate: Double
    let capacity: Int
    let buffers: UnsafeMutableAudioBufferListPointer

    init(device: AudioDeviceID, analyzer: AudioAnalyzer) throws {
        func check(_ s: OSStatus, _ step: String) throws {
            if s != noErr { throw Failure(step: step, status: s) }
        }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw Failure(step: "Find HAL", status: -1) }
        var maybeUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &maybeUnit), "Create HAL")
        guard let unit = maybeUnit else { throw Failure(step: "Create HAL", status: -1) }

        // Until every property is set, a throw skips deinit, so the unit is
        // disposed here instead of leaking on every failed open.
        let format: (channels: Int, sampleRate: Double, capacity: Int)
        do {
            format = try Self.configure(unit, device: device, check: check)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
        self.analyzer = analyzer
        (channels, sampleRate, capacity) = format
        buffers = AudioBufferList.allocate(maximumBuffers: channels)
        for i in 0..<channels {
            buffers[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity * 4),
                                     mData: UnsafeMutableRawPointer.allocate(byteCount: capacity * 4, alignment: 16))
        }

        analyzer.configure(sampleRate: sampleRate)

        var callback = AURenderCallbackStruct(inputProc: halInputProc,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Set callback")
        try check(AudioUnitInitialize(unit), "Initialise")
        try check(AudioOutputUnitStart(unit), "Start")
    }

    /// Input on, output off, the chosen device, and float32 non-interleaved
    /// at the device's own rate and channel count.
    private static func configure(_ unit: AudioUnit, device: AudioDeviceID,
                                  check: (OSStatus, String) throws -> Void) throws
        -> (channels: Int, sampleRate: Double, capacity: Int) {
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        var one: UInt32 = 1, zero: UInt32 = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32), "Enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32), "Disable output")
        var dev = device
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select device")

        // The device's own format on the input side of element 1…
        var hw = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &size), "Read format")
        let channels = max(1, Int(hw.mChannelsPerFrame))
        let sampleRate = hw.mSampleRate > 0 ? hw.mSampleRate : 48000

        // …and what we want handed to us: float32, one buffer per channel.
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                       &client, size), "Set format")

        var maxFrames: UInt32 = 0
        size = u32
        AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
        return (channels, sampleRate, max(Int(maxFrames), 4096))
    }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
    }

    deinit {
        AudioComponentInstanceDispose(unit)
        for b in buffers { b.mData?.deallocate() }
        free(buffers.unsafeMutablePointer)
    }
}

private let halInputProc: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    let input = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
    guard Int(frames) <= input.capacity else { return noErr }
    for i in 0..<input.buffers.count {
        input.buffers[i].mDataByteSize = frames * 4
    }
    let status = AudioUnitRender(input.unit, flags, timeStamp, bus, frames, input.buffers.unsafeMutablePointer)
    if status == noErr {
        input.analyzer.ingest(input.buffers.unsafePointer, frames: Int(frames))
    }
    return status
}
