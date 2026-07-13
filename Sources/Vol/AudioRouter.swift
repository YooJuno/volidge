import AVFoundation
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String

    var identifier: AudioDeviceID { id }
}

enum AudioRouterError: LocalizedError {
    case missingInputDevice
    case missingOutputDevice
    case virtualDeviceSelectedAsOutput
    case microphonePermissionRequired
    case unavailableAudioUnit
    case sampleRateChangeTimedOut
    case coreAudio(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .missingInputDevice:
            return "Volidge audio is not installed yet. Run the Volidge installer again, then reopen the app."
        case .missingOutputDevice:
            return "Connect an output device, then choose it under Output."
        case .virtualDeviceSelectedAsOutput:
            return "Choose a speaker or audio interface as the output, not Volidge."
        case .microphonePermissionRequired:
            return "Volidge needs Microphone permission to receive audio from Volidge. Enable Volidge in Privacy & Security → Microphone, then reopen the app."
        case .unavailableAudioUnit:
            return "macOS could not create Volidge's audio route. Try quitting and reopening Volidge."
        case .sampleRateChangeTimedOut:
            return "Volidge could not match the selected output's sample rate. Try stopping and starting routing again."
        case let .coreAudio(status, operation):
            return "\(operation) failed (Core Audio error \(status))."
        }
    }
}

@MainActor
final class AudioRouter {
    private enum PreferenceKey {
        static let inputName = "inputDeviceName"
        static let outputName = "outputDeviceName"
        static let volume = "volume"
    }

    private static let virtualDeviceName = "Volidge"
    private static let legacyVirtualDeviceName = "VolDevice"

    private let bridge = PassthroughAudioUnit()
    private var savedOutputDevice: AudioDeviceID?
    private var savedSystemOutputDevice: AudioDeviceID?
    private var savedVirtualDeviceSampleRate: Float64?
    private var volumeListenerDevice: AudioDeviceID?
    private var systemVolumeListener: AudioObjectPropertyListenerBlock?

    var onStateChange: (() -> Void)?
    private(set) var isRunning = false {
        didSet { notifyStateChange() }
    }
    private(set) var volume: Float {
        didSet {
            volume = min(max(volume, 0), 1)
            UserDefaults.standard.set(volume, forKey: PreferenceKey.volume)
            notifyStateChange()
        }
    }

    private(set) var selectedInputName: String {
        didSet { UserDefaults.standard.set(selectedInputName, forKey: PreferenceKey.inputName) }
    }
    private(set) var selectedOutputName: String {
        didSet { UserDefaults.standard.set(selectedOutputName, forKey: PreferenceKey.outputName) }
    }

    init() {
        let defaultOutput = Self.defaultDeviceName(for: kAudioHardwarePropertyDefaultOutputDevice)
        selectedInputName = Self.firstDeviceName(containing: "volidge", requiringInput: true)
            ?? Self.virtualDeviceName
        let savedOutputName = UserDefaults.standard.string(forKey: PreferenceKey.outputName)
        let preferredOutputName: String? = savedOutputName == Self.virtualDeviceName
            ? nil
            : savedOutputName
        selectedOutputName = preferredOutputName
            ?? Self.firstDeviceName(containing: "audient", requiringInput: false)
            ?? Self.firstDeviceName(containing: "id14", requiringInput: false)
            ?? (defaultOutput == Self.virtualDeviceName ? nil : defaultOutput)
            ?? "iD14 MKII"
        volume = UserDefaults.standard.object(forKey: PreferenceKey.volume) as? Float ?? 0.7
    }

    var inputDevices: [AudioDevice] {
        Self.devices.filter { Self.hasChannels($0.id, scope: kAudioObjectPropertyScopeInput) }
    }

    var outputDevices: [AudioDevice] {
        Self.devices.filter {
            $0.name != Self.virtualDeviceName
                && $0.name != Self.legacyVirtualDeviceName
                && Self.hasChannels($0.id, scope: kAudioObjectPropertyScopeOutput)
                && Self.canBeDefaultOutputDevice($0.id)
        }
    }

    var statusDescription: String {
        if isRunning {
            return "Routing Volidge → \(selectedOutputName) · \(bridge.diagnosticDescription)"
        }
        return "Stopped — choose devices, then start routing"
    }

    func selectInput(named name: String) {
        selectedInputName = name
        restartIfNeeded()
    }

    func selectOutput(named name: String) {
        guard name != Self.virtualDeviceName else { return }
        selectedOutputName = name
        restartIfNeeded()
    }

    func adjustVolume(by amount: Float) {
        setVolume(volume + amount)
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        guard isRunning, let volumeListenerDevice else { return }
        try? Self.setVolume(of: volumeListenerDevice, to: volume)
    }

    func start() throws {
        guard !isRunning else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRouterError.microphonePermissionRequired
        }
        guard let inputDevice = inputDevices.first(where: { $0.name == selectedInputName }) else {
            throw AudioRouterError.missingInputDevice
        }
        guard let outputDevice = outputDevices.first(where: { $0.name == selectedOutputName }) else {
            throw AudioRouterError.missingOutputDevice
        }
        guard outputDevice.id != inputDevice.id else {
            throw AudioRouterError.virtualDeviceSelectedAsOutput
        }

        savedOutputDevice = Self.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice)
        savedSystemOutputDevice = Self.defaultDevice(for: kAudioHardwarePropertyDefaultSystemOutputDevice)

        do {
            savedVirtualDeviceSampleRate = Self.nominalSampleRate(of: inputDevice.id)
            try Self.matchSampleRate(of: inputDevice.id, to: outputDevice.id)
            try Self.setDefaultDevice(inputDevice.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
            try Self.setDefaultDevice(inputDevice.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            try Self.setVolume(of: inputDevice.id, to: volume)

            bridge.setVolume(1)
            guard let sampleRate = Self.nominalSampleRate(of: outputDevice.id) else {
                throw AudioRouterError.unavailableAudioUnit
            }
            try bridge.start(inputDevice: inputDevice.id, outputDevice: outputDevice.id, sampleRate: sampleRate)
            installSystemVolumeListener(for: inputDevice.id)
            isRunning = true
        } catch {
            stop(restoreSystemDevices: true)
            throw error
        }
    }

    func stop(restoreSystemDevices: Bool) {
        guard isRunning || savedOutputDevice != nil else { return }
        bridge.stop()
        removeSystemVolumeListener()
        isRunning = false

        guard restoreSystemDevices else { return }
        restoreSavedDevices()
    }

    private func restartIfNeeded() {
        guard isRunning else { return }
        stop(restoreSystemDevices: true)
        try? start()
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private func restoreSavedDevices() {
        if let savedOutputDevice {
            try? Self.setDefaultDevice(savedOutputDevice, selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
        if let savedSystemOutputDevice {
            try? Self.setDefaultDevice(savedSystemOutputDevice, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        savedOutputDevice = nil
        savedSystemOutputDevice = nil
        if let savedVirtualDeviceSampleRate, let virtualDevice = inputDevices.first(where: { $0.name == selectedInputName }) {
            try? Self.setNominalSampleRate(of: virtualDevice.id, to: savedVirtualDeviceSampleRate)
        }
        savedVirtualDeviceSampleRate = nil
    }


    private func installSystemVolumeListener(for device: AudioDeviceID) {
        removeSystemVolumeListener()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncVolumeFromSystemDevice(device)
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        guard status == noErr else { return }

        volumeListenerDevice = device
        systemVolumeListener = listener
        syncVolumeFromSystemDevice(device)
    }

    private func removeSystemVolumeListener() {
        guard let volumeListenerDevice, let systemVolumeListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(volumeListenerDevice, &address, .main, systemVolumeListener)
        self.volumeListenerDevice = nil
        self.systemVolumeListener = nil
    }

    private func syncVolumeFromSystemDevice(_ device: AudioDeviceID) {
        guard let systemVolume = Self.volume(of: device) else { return }
        volume = systemVolume
    }

    private static var devices: [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var identifiers = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &identifiers
        ) == noErr else { return [] }

        return identifiers.compactMap { identifier in
            deviceName(for: identifier).map { AudioDevice(id: identifier, name: $0) }
        }
    }

    private static func deviceName(for device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &name) == noErr else {
            return nil
        }
        return name?.takeUnretainedValue() as String?
    }

    private static func hasChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else {
            return false
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, rawBufferList) == noErr else {
            return false
        }

        let bufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).contains { $0.mNumberChannels > 0 }
    }

    private static func canBeDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var canBeDefault: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &dataSize,
            &canBeDefault
        ) == noErr && canBeDefault != 0
    }

    private static func defaultDevice(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &device
        ) == noErr else { return nil }
        return device
    }

    private static func defaultDeviceName(for selector: AudioObjectPropertySelector) -> String? {
        defaultDevice(for: selector).flatMap(deviceName(for:))
    }

    private static func firstDeviceName(containing needle: String, requiringInput: Bool) -> String? {
        devices.first {
            $0.name.localizedCaseInsensitiveContains(needle)
                && hasChannels($0.id, scope: requiringInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        }?.name
    }

    private static func setDefaultDevice(
        _ device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDevice = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDevice
        )
        guard status == noErr else {
            throw AudioRouterError.coreAudio(status, "Changing the default audio device")
        }
    }

    private static func volume(of device: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private static func setVolume(of device: AudioDeviceID, to volume: Float) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableVolume = min(max(volume, 0), 1)
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float>.size),
            &mutableVolume
        )
        guard status == noErr else {
            throw AudioRouterError.coreAudio(status, "Changing the Volidge volume")
        }
    }

    private static func nominalSampleRate(of device: AudioDeviceID) -> Float64? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &sampleRate) == noErr else {
            return nil
        }
        return sampleRate
    }

    private static func matchSampleRate(of inputDevice: AudioDeviceID, to outputDevice: AudioDeviceID) throws {
        guard let inputRate = nominalSampleRate(of: inputDevice),
              let outputRate = nominalSampleRate(of: outputDevice),
              inputRate != outputRate else {
            return
        }
        try setNominalSampleRate(of: inputDevice, to: outputRate)
        for _ in 0 ..< 50 {
            if nominalSampleRate(of: inputDevice) == outputRate {
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw AudioRouterError.sampleRateChangeTimedOut
    }

    private static func setNominalSampleRate(of device: AudioDeviceID, to sampleRate: Float64) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableSampleRate = sampleRate
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float64>.size),
            &mutableSampleRate
        )
        guard status == noErr else {
            throw AudioRouterError.coreAudio(status, "Matching Volidge's sample rate to the output device")
        }
    }

}
