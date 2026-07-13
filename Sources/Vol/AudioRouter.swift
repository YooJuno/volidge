import AVFoundation
import AudioToolbox
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
    private struct OutputVolumeSnapshot {
        let device: AudioDeviceID
        let volume: Float
        let isMuted: UInt32?
    }

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
    private var outputVolumeSnapshot: OutputVolumeSnapshot?
    private var volumeControl: AudioObjectID?
    private var systemVolumeListener: AudioObjectPropertyListenerBlock?
    private var volumeSyncTimer: Timer?
    private var defaultDeviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    var onStateChange: (() -> Void)?
    private(set) var isRunning = false {
        didSet { notifyStateChange() }
    }
    private(set) var isDirectOutput = false {
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
                && !Self.isMicrophone($0.name)
        }
    }

    var statusDescription: String {
        if isDirectOutput {
            return "Using (selectedOutputName) directly · no added latency"
        }
        if isRunning {
            return "Routing Volidge → \(selectedOutputName) · \(bridge.diagnosticDescription)"
        }
        return "Stopped — choose devices, then start routing"
    }

    var requiresMicrophonePermission: Bool {
        guard let outputDevice = outputDevices.first(where: { $0.name == selectedOutputName }) else {
            return true
        }
        return Self.nativeOutputVolumeControl(for: outputDevice.id) == nil
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
        bridge.setVolume(volume)
        guard isRunning, let volumeControl else { return }
        try? Self.setVolume(of: volumeControl, to: volume)
    }

    func start() throws {
        guard !isRunning else { return }
        guard let outputDevice = outputDevices.first(where: { $0.name == selectedOutputName }) else {
            throw AudioRouterError.missingOutputDevice
        }

        if let directVolumeControl = Self.nativeOutputVolumeControl(for: outputDevice.id) {
            saveCurrentDefaultDevices(excluding: outputDevice.id)
            do {
                try Self.setDefaultDevice(outputDevice.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
                try Self.setDefaultDevice(outputDevice.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
                installSystemVolumeListener(for: directVolumeControl)
                isDirectOutput = true
                isRunning = true
                installDefaultDeviceListeners(expectedDevice: outputDevice.id)
                return
            } catch {
                stop(restoreSystemDevices: true)
                throw error
            }
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRouterError.microphonePermissionRequired
        }
        guard let inputDevice = inputDevices.first(where: { $0.name == selectedInputName }) else {
            throw AudioRouterError.missingInputDevice
        }
        guard outputDevice.id != inputDevice.id else {
            throw AudioRouterError.virtualDeviceSelectedAsOutput
        }
        guard let volumeControl = Self.outputVolumeControl(for: inputDevice.id) else {
            throw AudioRouterError.unavailableAudioUnit
        }

        saveCurrentDefaultDevices(excluding: inputDevice.id)

        do {
            normalizeOutputVolume(for: outputDevice.id)
            savedVirtualDeviceSampleRate = Self.nominalSampleRate(of: inputDevice.id)
            try Self.matchSampleRate(of: inputDevice.id, to: outputDevice.id)
            try Self.setDefaultDevice(inputDevice.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
            try Self.setDefaultDevice(inputDevice.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
            try Self.setVolume(of: volumeControl, to: volume)

            bridge.setVolume(volume)
            guard let sampleRate = Self.nominalSampleRate(of: outputDevice.id) else {
                throw AudioRouterError.unavailableAudioUnit
            }
            try bridge.start(inputDevice: inputDevice.id, outputDevice: outputDevice.id, sampleRate: sampleRate)
            installSystemVolumeListener(for: volumeControl)
            isRunning = true
            installDefaultDeviceListeners(expectedDevice: inputDevice.id)
        } catch {
            stop(restoreSystemDevices: true)
            throw error
        }
    }

    func stop(restoreSystemDevices: Bool) {
        stop(restoreSystemDevices: restoreSystemDevices, preserveSavedDevices: false)
    }

    private func stop(restoreSystemDevices: Bool, preserveSavedDevices: Bool) {
        guard isRunning
            || savedOutputDevice != nil
            || savedSystemOutputDevice != nil
            || outputVolumeSnapshot != nil else { return }
        removeDefaultDeviceListeners()
        bridge.stop()
        removeSystemVolumeListener()
        restoreOutputVolume()
        isDirectOutput = false
        isRunning = false

        restoreVirtualDeviceSampleRate()
        if restoreSystemDevices {
            restoreSavedDevices()
        } else if !preserveSavedDevices {
            savedOutputDevice = nil
            savedSystemOutputDevice = nil
        }
    }

    private func restartIfNeeded() {
        guard isRunning else { return }
        stop(restoreSystemDevices: false, preserveSavedDevices: true)
        try? start()
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private func saveCurrentDefaultDevices(excluding activeDevice: AudioDeviceID) {
        if savedOutputDevice == nil,
           let currentOutput = Self.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice),
           currentOutput != activeDevice,
           Self.deviceName(for: currentOutput) != Self.virtualDeviceName {
            savedOutputDevice = currentOutput
        }
        if savedSystemOutputDevice == nil,
           let currentSystemOutput = Self.defaultDevice(for: kAudioHardwarePropertyDefaultSystemOutputDevice),
           currentSystemOutput != activeDevice,
           Self.deviceName(for: currentSystemOutput) != Self.virtualDeviceName {
            savedSystemOutputDevice = currentSystemOutput
        }
    }

    private func restoreSavedDevices() {
        let fallbackDevice = outputDevices.first(where: { $0.name == selectedOutputName })?.id
        if let outputDevice = savedOutputDevice ?? fallbackDevice {
            try? Self.setDefaultDevice(outputDevice, selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
        if let systemOutputDevice = savedSystemOutputDevice ?? fallbackDevice {
            try? Self.setDefaultDevice(systemOutputDevice, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        savedOutputDevice = nil
        savedSystemOutputDevice = nil
    }

    private func restoreVirtualDeviceSampleRate() {
        if let savedVirtualDeviceSampleRate, let virtualDevice = inputDevices.first(where: { $0.name == selectedInputName }) {
            try? Self.setNominalSampleRate(of: virtualDevice.id, to: savedVirtualDeviceSampleRate)
        }
        savedVirtualDeviceSampleRate = nil
    }

    private func normalizeOutputVolume(for device: AudioDeviceID) {
        restoreOutputVolume()
        guard let outputVolume = Self.virtualMainVolume(of: device) else { return }

        outputVolumeSnapshot = OutputVolumeSnapshot(
            device: device,
            volume: outputVolume,
            isMuted: Self.muteState(of: device)
        )
        try? Self.setVirtualMainVolume(of: device, to: 1)
        try? Self.setMuteState(of: device, to: 0)
    }

    private func restoreOutputVolume() {
        guard let snapshot = outputVolumeSnapshot else { return }
        try? Self.setVirtualMainVolume(of: snapshot.device, to: snapshot.volume)
        if let isMuted = snapshot.isMuted {
            try? Self.setMuteState(of: snapshot.device, to: isMuted)
        }
        outputVolumeSnapshot = nil
    }

    private func installDefaultDeviceListeners(expectedDevice: AudioDeviceID) {
        removeDefaultDeviceListeners()
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handleDefaultDeviceChange(expectedDevice: expectedDevice)
                }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
            if status == noErr {
                defaultDeviceListeners.append((selector, listener))
            }
        }

        handleDefaultDeviceChange(expectedDevice: expectedDevice)
    }

    private func removeDefaultDeviceListeners() {
        for (selector, listener) in defaultDeviceListeners {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                listener
            )
        }
        defaultDeviceListeners.removeAll()
    }

    private func handleDefaultDeviceChange(expectedDevice: AudioDeviceID) {
        guard isRunning else { return }
        let defaultOutput = Self.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice)
        let systemOutput = Self.defaultDevice(for: kAudioHardwarePropertyDefaultSystemOutputDevice)

        if defaultOutput != expectedDevice {
            let userSelectedDevice = defaultOutput
            stop(restoreSystemDevices: false, preserveSavedDevices: false)
            if let userSelectedDevice {
                try? Self.setDefaultDevice(
                    userSelectedDevice,
                    selector: kAudioHardwarePropertyDefaultSystemOutputDevice
                )
            }
            return
        }

        if systemOutput != expectedDevice {
            try? Self.setDefaultDevice(
                expectedDevice,
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice
            )
        }
    }


    private func installSystemVolumeListener(for control: AudioObjectID) {
        removeSystemVolumeListener()

        volumeControl = control
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncVolumeFromSystemControl(control)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeSyncTimer = timer

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncVolumeFromSystemControl(control)
        }
        let status = AudioObjectAddPropertyListenerBlock(control, &address, .main, listener)
        if status == noErr {
            systemVolumeListener = listener
        }
        syncVolumeFromSystemControl(control)
    }

    private func removeSystemVolumeListener() {
        volumeSyncTimer?.invalidate()
        volumeSyncTimer = nil
        if let volumeControl, let systemVolumeListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioLevelControlPropertyScalarValue,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(volumeControl, &address, .main, systemVolumeListener)
        }
        self.volumeControl = nil
        self.systemVolumeListener = nil
    }

    private func syncVolumeFromSystemControl(_ control: AudioObjectID) {
        guard let systemVolume = Self.volume(of: control) else { return }
        if abs(volume - systemVolume) > 0.0001 {
            volume = systemVolume
        }
        bridge.setVolume(systemVolume)
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

    private static func isMicrophone(_ name: String) -> Bool {
        let normalizedName = name.lowercased()
        return normalizedName.contains("microphone")
            || normalizedName.contains(" mic")
            || normalizedName.contains("마이크")
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

    private static func virtualMainVolume(of device: AudioDeviceID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private static func setVirtualMainVolume(of device: AudioDeviceID, to volume: Float) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
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
            throw AudioRouterError.coreAudio(status, "Normalising the output device volume")
        }
    }

    private static func muteState(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isMuted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &isMuted) == noErr else {
            return nil
        }
        return isMuted
    }

    private static func setMuteState(of device: AudioDeviceID, to isMuted: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableMuteState = isMuted
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableMuteState
        )
        guard status == noErr else {
            throw AudioRouterError.coreAudio(status, "Changing the output device mute state")
        }
    }

    private static func outputVolumeControl(for device: AudioDeviceID) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyControlList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var controls = Array(repeating: AudioObjectID(), count: count)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &controls) == noErr else {
            return nil
        }

        return controls.first { control in
            var scopeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioControlPropertyScope,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var scope = AudioObjectPropertyScope()
            var scopeSize = UInt32(MemoryLayout<AudioObjectPropertyScope>.size)
            guard AudioObjectGetPropertyData(
                control,
                &scopeAddress,
                0,
                nil,
                &scopeSize,
                &scope
            ) == noErr, scope == kAudioObjectPropertyScopeOutput else {
                return false
            }
            return volume(of: control) != nil
        }
    }

    private static func nativeOutputVolumeControl(for device: AudioDeviceID) -> AudioObjectID? {
        guard virtualMainVolume(of: device) != nil,
              let control = outputVolumeControl(for: device) else {
            return nil
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(control, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return nil
        }
        return control
    }

    private static func volume(of control: AudioObjectID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var dataSize = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(control, &address, 0, nil, &dataSize, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private static func setVolume(of control: AudioObjectID, to volume: Float) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableVolume = min(max(volume, 0), 1)
        let status = AudioObjectSetPropertyData(
            control,
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
