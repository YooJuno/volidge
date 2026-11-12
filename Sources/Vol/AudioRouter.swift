import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    var identifier: AudioDeviceID { id }
}

enum AudioLatencyMode: String, CaseIterable, Identifiable {
    case low
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low latency"
        case .compatible: return "Compatibility"
        }
    }
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
    private enum VolumeEndpoint {
        case control(AudioObjectID)
        case virtualMain(AudioDeviceID)

        var objectID: AudioObjectID {
            switch self {
            case let .control(objectID), let .virtualMain(objectID): return objectID
            }
        }

        var address: AudioObjectPropertyAddress {
            switch self {
            case .control:
                return AudioObjectPropertyAddress(
                    mSelector: kAudioLevelControlPropertyScalarValue,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            case .virtualMain:
                return AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
            }
        }
    }

    private struct PropertyListener {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct OutputVolumeSnapshot {
        let deviceUID: String
        let volume: Float
        let isMuted: UInt32?
    }

    private struct OutputBufferSnapshot {
        let deviceUID: String
        let frameSize: UInt32
    }

    private enum PreferenceKey {
        static let inputName = "inputDeviceName"
        static let outputName = "outputDeviceName"
        static let outputUID = "outputDeviceUID"
        static let volume = "volume"
        static let latencyMode = "latencyMode"
        static let savedOutputUID = "savedDefaultOutputUID"
        static let savedSystemOutputUID = "savedDefaultSystemOutputUID"
        static let volumeSnapshotUID = "outputVolumeSnapshotUID"
        static let volumeSnapshotValue = "outputVolumeSnapshotValue"
        static let volumeSnapshotMute = "outputVolumeSnapshotMute"
    }

    private static let virtualDeviceName = "Volidge"
    private static let legacyVirtualDeviceName = "VolDevice"

    private let bridge = PassthroughAudioUnit()
    private var savedOutputDeviceUID: String?
    private var savedSystemOutputDeviceUID: String?
    private var savedVirtualDeviceSampleRate: Float64?
    private var outputVolumeSnapshot: OutputVolumeSnapshot?
    private var outputBufferSnapshot: OutputBufferSnapshot?
    private var volumeEndpoint: VolumeEndpoint?
    private var systemVolumeListener: AudioObjectPropertyListenerBlock?
    private var volumeSyncTimer: Timer?
    private var defaultDeviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var hardwareDeviceListener: PropertyListener?
    private var activeDeviceListeners: [PropertyListener] = []
    private var recoveryTask: Task<Void, Never>?
    private var routeHealthTimer: Timer?
    private var lastBridgeHealth: PassthroughAudioHealth?
    private var unhealthyHealthChecks = 0
    private var activeInputDeviceID: AudioDeviceID?
    private var activeOutputDeviceID: AudioDeviceID?
    private var routingRequested = false
    private var isSuspended = false

    var onStateChange: (() -> Void)?
    var onError: ((String) -> Void)?
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
    private(set) var selectedOutputUID: String {
        didSet { UserDefaults.standard.set(selectedOutputUID, forKey: PreferenceKey.outputUID) }
    }
    private(set) var selectedOutputName: String {
        didSet { UserDefaults.standard.set(selectedOutputName, forKey: PreferenceKey.outputName) }
    }
    private(set) var latencyMode: AudioLatencyMode {
        didSet {
            UserDefaults.standard.set(latencyMode.rawValue, forKey: PreferenceKey.latencyMode)
            notifyStateChange()
        }
    }

    init() {
        let availableOutputs = Self.outputDeviceList
        let defaultOutputID = Self.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice)
        let defaultOutput = defaultOutputID.flatMap { id in availableOutputs.first { $0.id == id } }
        selectedInputName = Self.firstDeviceName(containing: "volidge", requiringInput: true)
            ?? Self.virtualDeviceName
        let savedOutputUID = UserDefaults.standard.string(forKey: PreferenceKey.outputUID)
        let savedOutputName = UserDefaults.standard.string(forKey: PreferenceKey.outputName)
        let savedOutput = availableOutputs.first { $0.uid == savedOutputUID }
            ?? availableOutputs.first { $0.name == savedOutputName && $0.name != Self.virtualDeviceName }
        let fallbackOutput = availableOutputs.first { $0.name.localizedCaseInsensitiveContains("audient") }
            ?? availableOutputs.first { $0.name.localizedCaseInsensitiveContains("id14") }
            ?? defaultOutput
            ?? availableOutputs.first
        if let savedOutputUID, !savedOutputUID.isEmpty {
            selectedOutputUID = savedOutputUID
            selectedOutputName = savedOutput?.name ?? savedOutputName ?? "Audio output"
        } else if let savedOutputName, savedOutputName != Self.virtualDeviceName {
            selectedOutputUID = savedOutput?.uid ?? ""
            selectedOutputName = savedOutputName
        } else {
            selectedOutputUID = fallbackOutput?.uid ?? ""
            selectedOutputName = fallbackOutput?.name ?? "Audio output"
        }
        volume = UserDefaults.standard.object(forKey: PreferenceKey.volume) as? Float ?? 0.7
        latencyMode = AudioLatencyMode(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.latencyMode) ?? ""
        ) ?? .low
        savedOutputDeviceUID = UserDefaults.standard.string(forKey: PreferenceKey.savedOutputUID)
        savedSystemOutputDeviceUID = UserDefaults.standard.string(forKey: PreferenceKey.savedSystemOutputUID)
        UserDefaults.standard.set(selectedInputName, forKey: PreferenceKey.inputName)
        UserDefaults.standard.set(selectedOutputUID, forKey: PreferenceKey.outputUID)
        UserDefaults.standard.set(selectedOutputName, forKey: PreferenceKey.outputName)
        UserDefaults.standard.set(latencyMode.rawValue, forKey: PreferenceKey.latencyMode)
        recoverPersistedOutputVolume()
        installHardwareDeviceListener()
    }

    var inputDevices: [AudioDevice] {
        Self.devices.filter { Self.hasChannels($0.id, scope: kAudioObjectPropertyScopeInput) }
    }

    var outputDevices: [AudioDevice] {
        Self.outputDeviceList
    }

    private var selectedOutputDevice: AudioDevice? {
        outputDevices.first { $0.uid == selectedOutputUID }
            ?? outputDevices.first { $0.name == selectedOutputName }
    }

    var statusDescription: String {
        if isDirectOutput {
            return "Using \(selectedOutputName) directly · no added latency"
        }
        if isRunning {
            return "Routing Volidge → \(selectedOutputName) · \(bridge.diagnosticDescription)"
        }
        return "Stopped — choose devices, then start routing"
    }

    var requiresMicrophonePermission: Bool {
        guard let outputDevice = selectedOutputDevice else {
            return true
        }
        return !Self.hasNativeOutputVolume(for: outputDevice.id)
    }

    var selectedOutputUsesBridge: Bool {
        guard let outputDevice = selectedOutputDevice else { return true }
        return !Self.hasNativeOutputVolume(for: outputDevice.id)
    }

    func selectOutput(uid: String) {
        guard let device = outputDevices.first(where: { $0.uid == uid }) else { return }
        selectedOutputUID = device.uid
        selectedOutputName = device.name
        restartIfNeeded()
    }

    func setLatencyMode(_ mode: AudioLatencyMode) {
        guard latencyMode != mode else { return }
        latencyMode = mode
        restartIfNeeded()
    }

    func adjustVolume(by amount: Float) {
        setVolume(volume + amount)
    }

    func setVolume(_ newVolume: Float) {
        volume = newVolume
        bridge.setVolume(volume)
        guard isRunning, let volumeEndpoint else { return }
        try? Self.setVolume(of: volumeEndpoint, to: volume)
    }

    func start() throws {
        routingRequested = true
        try startRoute()
    }

    private func startRoute() throws {
        guard !isRunning else { return }
        guard !isSuspended else { return }
        guard let outputDevice = selectedOutputDevice else {
            throw AudioRouterError.missingOutputDevice
        }

        if Self.hasNativeOutputVolume(for: outputDevice.id) {
            saveCurrentDefaultDevices(excluding: outputDevice.id)
            do {
                try Self.setDefaultDevice(outputDevice.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
                try Self.setDefaultDevice(outputDevice.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
                installSystemVolumeListener(for: .virtualMain(outputDevice.id))
                isDirectOutput = true
                isRunning = true
                activeOutputDeviceID = outputDevice.id
                installDefaultDeviceListeners(expectedDevice: outputDevice.id)
                installActiveDeviceListeners(inputDevice: nil, outputDevice: outputDevice.id)
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
            optimizeOutputBuffer(for: outputDevice)
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
            installSystemVolumeListener(for: .control(volumeControl))
            isRunning = true
            activeInputDeviceID = inputDevice.id
            activeOutputDeviceID = outputDevice.id
            installDefaultDeviceListeners(expectedDevice: inputDevice.id)
            installActiveDeviceListeners(inputDevice: inputDevice.id, outputDevice: outputDevice.id)
            startRouteHealthMonitoring()
        } catch {
            stop(restoreSystemDevices: true)
            throw error
        }
    }

    func stop(restoreSystemDevices: Bool) {
        routingRequested = false
        recoveryTask?.cancel()
        stop(restoreSystemDevices: restoreSystemDevices, preserveSavedDevices: false)
    }

    private func stop(restoreSystemDevices: Bool, preserveSavedDevices: Bool) {
        guard isRunning
            || savedOutputDeviceUID != nil
            || savedSystemOutputDeviceUID != nil
            || savedVirtualDeviceSampleRate != nil
            || outputVolumeSnapshot != nil
            || outputBufferSnapshot != nil
            || !activeDeviceListeners.isEmpty else { return }
        removeDefaultDeviceListeners()
        removeActiveDeviceListeners()
        stopRouteHealthMonitoring()
        bridge.stop()
        removeSystemVolumeListener()
        restoreOutputVolume()
        restoreOutputBuffer()
        isDirectOutput = false
        isRunning = false
        activeInputDeviceID = nil
        activeOutputDeviceID = nil

        restoreVirtualDeviceSampleRate()
        if restoreSystemDevices {
            restoreSavedDevices()
        } else if !preserveSavedDevices {
            clearSavedDevices()
        }
    }

    private func restartIfNeeded() {
        guard routingRequested else { return }
        if isRunning {
            stop(restoreSystemDevices: false, preserveSavedDevices: true)
        }
        do {
            try startRoute()
        } catch {
            onError?(error.localizedDescription)
            notifyStateChange()
        }
    }

    func suspendForSleep() {
        isSuspended = true
        recoveryTask?.cancel()
        if isRunning {
            stop(restoreSystemDevices: true, preserveSavedDevices: false)
        }
    }

    func resumeAfterWake() {
        isSuspended = false
        scheduleRouteRecovery(delay: 1.0)
    }

    func shutdown() {
        routingRequested = false
        recoveryTask?.cancel()
        removeHardwareDeviceListener()
        stop(restoreSystemDevices: true, preserveSavedDevices: false)
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private func startRouteHealthMonitoring() {
        stopRouteHealthMonitoring()
        lastBridgeHealth = bridge.healthSnapshot
        unhealthyHealthChecks = 0
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkRouteHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        routeHealthTimer = timer
    }

    private func stopRouteHealthMonitoring() {
        routeHealthTimer?.invalidate()
        routeHealthTimer = nil
        lastBridgeHealth = nil
        unhealthyHealthChecks = 0
    }

    private func checkRouteHealth() {
        guard isRunning, !isDirectOutput else {
            stopRouteHealthMonitoring()
            return
        }
        let health = bridge.healthSnapshot
        let callbacksStopped = lastBridgeHealth.map {
            $0.captureCount == health.captureCount || $0.renderCount == health.renderCount
        } ?? false
        let excessiveUnderflow = lastBridgeHealth.map {
            health.underflowFrames &- $0.underflowFrames > 4_096
        } ?? false
        let unhealthy = health.captureStatus != noErr || callbacksStopped || excessiveUnderflow
        unhealthyHealthChecks = unhealthy ? unhealthyHealthChecks + 1 : 0
        lastBridgeHealth = health

        guard unhealthyHealthChecks >= 2 else { return }
        activeOutputDeviceID = nil
        stopRouteHealthMonitoring()
        scheduleRouteRecovery(delay: 0.1)
    }

    private func installHardwareDeviceListener() {
        removeHardwareDeviceListener()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleHardwareDeviceListChange()
            }
        }
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, listener) == noErr else {
            return
        }
        hardwareDeviceListener = PropertyListener(objectID: objectID, address: address, block: listener)
    }

    private func removeHardwareDeviceListener() {
        guard let listener = hardwareDeviceListener else { return }
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, .main, listener.block)
        hardwareDeviceListener = nil
    }

    private func installActiveDeviceListeners(inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID) {
        removeActiveDeviceListeners()
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyDeviceIsAlive,
            kAudioDevicePropertyNominalSampleRate,
            kAudioDevicePropertyBufferFrameSize,
        ]
        let deviceIDs = [inputDevice, outputDevice].compactMap { $0 }

        for deviceID in deviceIDs {
            for selector in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.activeOutputDeviceID = nil
                        self?.scheduleRouteRecovery(delay: 0.25)
                    }
                }
                guard AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener) == noErr else {
                    continue
                }
                activeDeviceListeners.append(
                    PropertyListener(objectID: deviceID, address: address, block: listener)
                )
            }
        }
    }

    private func removeActiveDeviceListeners() {
        for listener in activeDeviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, .main, listener.block)
        }
        activeDeviceListeners.removeAll()
    }

    private func handleHardwareDeviceListChange() {
        if let selectedDevice = outputDevices.first(where: { $0.uid == selectedOutputUID })
            ?? (selectedOutputUID.isEmpty
                ? outputDevices.first(where: { $0.name == selectedOutputName })
                : nil) {
            selectedOutputUID = selectedDevice.uid
            selectedOutputName = selectedDevice.name
        }
        if !isRunning, outputVolumeSnapshot != nil {
            restoreOutputVolume()
        }
        notifyStateChange()
        scheduleRouteRecovery(delay: 0.5)
    }

    private func scheduleRouteRecovery(delay: TimeInterval) {
        guard routingRequested, !isSuspended else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(delay, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.recoverRouteIfNeeded()
        }
    }

    private func recoverRouteIfNeeded() {
        guard routingRequested, !isSuspended, let outputDevice = selectedOutputDevice else {
            if isRunning {
                stop(restoreSystemDevices: true, preserveSavedDevices: false)
            }
            return
        }

        let inputDevice = inputDevices.first(where: { $0.name == selectedInputName })
        let activeRouteChanged = activeOutputDeviceID != outputDevice.id
            || (!isDirectOutput && activeInputDeviceID != inputDevice?.id)
        if isRunning, !activeRouteChanged {
            return
        }
        if isRunning {
            stop(restoreSystemDevices: false, preserveSavedDevices: true)
        }
        do {
            try startRoute()
        } catch {
            onError?(error.localizedDescription)
            notifyStateChange()
        }
    }

    private func saveCurrentDefaultDevices(excluding activeDevice: AudioDeviceID) {
        if savedOutputDeviceUID == nil,
           let currentOutput = Self.defaultDevice(for: kAudioHardwarePropertyDefaultOutputDevice),
           currentOutput != activeDevice,
           Self.deviceName(for: currentOutput) != Self.virtualDeviceName,
           let uid = Self.deviceUID(for: currentOutput) {
            savedOutputDeviceUID = uid
            UserDefaults.standard.set(uid, forKey: PreferenceKey.savedOutputUID)
        }
        if savedSystemOutputDeviceUID == nil,
           let currentSystemOutput = Self.defaultDevice(for: kAudioHardwarePropertyDefaultSystemOutputDevice),
           currentSystemOutput != activeDevice,
           Self.deviceName(for: currentSystemOutput) != Self.virtualDeviceName,
           let uid = Self.deviceUID(for: currentSystemOutput) {
            savedSystemOutputDeviceUID = uid
            UserDefaults.standard.set(uid, forKey: PreferenceKey.savedSystemOutputUID)
        }
    }

    private func restoreSavedDevices() {
        let fallbackDevice = selectedOutputDevice?.id
            ?? outputDevices.first { $0.uid == "BuiltInSpeakerDevice" }?.id
            ?? outputDevices.first?.id
        let savedOutputDevice = savedOutputDeviceUID.flatMap(Self.device(withUID:))
        let savedSystemOutputDevice = savedSystemOutputDeviceUID.flatMap(Self.device(withUID:))
        if let outputDevice = savedOutputDevice ?? fallbackDevice {
            try? Self.setDefaultDevice(outputDevice, selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
        if let systemOutputDevice = savedSystemOutputDevice ?? fallbackDevice {
            try? Self.setDefaultDevice(systemOutputDevice, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
        clearSavedDevices()
    }

    private func clearSavedDevices() {
        savedOutputDeviceUID = nil
        savedSystemOutputDeviceUID = nil
        UserDefaults.standard.removeObject(forKey: PreferenceKey.savedOutputUID)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.savedSystemOutputUID)
    }

    private func restoreVirtualDeviceSampleRate() {
        if let savedVirtualDeviceSampleRate, let virtualDevice = inputDevices.first(where: { $0.name == selectedInputName }) {
            try? Self.setNominalSampleRate(of: virtualDevice.id, to: savedVirtualDeviceSampleRate)
        }
        savedVirtualDeviceSampleRate = nil
    }

    private func normalizeOutputVolume(for device: AudioDeviceID) {
        restoreOutputVolume()
        guard outputVolumeSnapshot == nil,
              let deviceUID = Self.deviceUID(for: device),
              let outputVolume = Self.virtualMainVolume(of: device) else { return }

        outputVolumeSnapshot = OutputVolumeSnapshot(
            deviceUID: deviceUID,
            volume: outputVolume,
            isMuted: Self.muteState(of: device)
        )
        persistOutputVolumeSnapshot(outputVolumeSnapshot)
        try? Self.setVirtualMainVolume(of: device, to: 1)
        try? Self.setMuteState(of: device, to: 0)
    }

    private func restoreOutputVolume() {
        guard let snapshot = outputVolumeSnapshot else { return }
        guard let device = Self.device(withUID: snapshot.deviceUID) else { return }
        try? Self.setVirtualMainVolume(of: device, to: snapshot.volume)
        if let isMuted = snapshot.isMuted {
            try? Self.setMuteState(of: device, to: isMuted)
        }
        outputVolumeSnapshot = nil
        clearPersistedOutputVolumeSnapshot()
    }

    private func recoverPersistedOutputVolume() {
        let defaults = UserDefaults.standard
        guard let deviceUID = defaults.string(forKey: PreferenceKey.volumeSnapshotUID),
              defaults.object(forKey: PreferenceKey.volumeSnapshotValue) != nil else { return }
        let snapshot = OutputVolumeSnapshot(
            deviceUID: deviceUID,
            volume: defaults.float(forKey: PreferenceKey.volumeSnapshotValue),
            isMuted: defaults.object(forKey: PreferenceKey.volumeSnapshotMute).map { _ in
                UInt32(defaults.integer(forKey: PreferenceKey.volumeSnapshotMute))
            }
        )
        outputVolumeSnapshot = snapshot
        restoreOutputVolume()
    }

    private func persistOutputVolumeSnapshot(_ snapshot: OutputVolumeSnapshot?) {
        guard let snapshot else { return }
        let defaults = UserDefaults.standard
        defaults.set(snapshot.deviceUID, forKey: PreferenceKey.volumeSnapshotUID)
        defaults.set(snapshot.volume, forKey: PreferenceKey.volumeSnapshotValue)
        if let isMuted = snapshot.isMuted {
            defaults.set(Int(isMuted), forKey: PreferenceKey.volumeSnapshotMute)
        } else {
            defaults.removeObject(forKey: PreferenceKey.volumeSnapshotMute)
        }
    }

    private func clearPersistedOutputVolumeSnapshot() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: PreferenceKey.volumeSnapshotUID)
        defaults.removeObject(forKey: PreferenceKey.volumeSnapshotValue)
        defaults.removeObject(forKey: PreferenceKey.volumeSnapshotMute)
    }

    private func optimizeOutputBuffer(for device: AudioDevice) {
        restoreOutputBuffer()
        guard latencyMode == .low,
              let currentFrameSize = Self.bufferFrameSize(of: device.id),
              currentFrameSize > 256,
              Self.canSetBufferFrameSize(of: device.id),
              let range = Self.bufferFrameSizeRange(of: device.id) else { return }

        let targetFrameSize = UInt32(min(max(256, range.mMinimum), range.mMaximum))
        guard targetFrameSize < currentFrameSize else { return }
        outputBufferSnapshot = OutputBufferSnapshot(deviceUID: device.uid, frameSize: currentFrameSize)
        do {
            try Self.setBufferFrameSize(of: device.id, to: targetFrameSize)
        } catch {
            outputBufferSnapshot = nil
        }
    }

    private func restoreOutputBuffer() {
        guard let snapshot = outputBufferSnapshot else { return }
        if let device = Self.device(withUID: snapshot.deviceUID) {
            try? Self.setBufferFrameSize(of: device, to: snapshot.frameSize)
        }
        outputBufferSnapshot = nil
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
            routingRequested = false
            recoveryTask?.cancel()
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


    private func installSystemVolumeListener(for endpoint: VolumeEndpoint) {
        removeSystemVolumeListener()

        volumeEndpoint = endpoint
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncVolumeFromSystemControl(endpoint)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        volumeSyncTimer = timer

        var address = endpoint.address
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.syncVolumeFromSystemControl(endpoint)
        }
        let status = AudioObjectAddPropertyListenerBlock(endpoint.objectID, &address, .main, listener)
        if status == noErr {
            systemVolumeListener = listener
        }
        syncVolumeFromSystemControl(endpoint)
    }

    private func removeSystemVolumeListener() {
        volumeSyncTimer?.invalidate()
        volumeSyncTimer = nil
        if let volumeEndpoint, let systemVolumeListener {
            var address = volumeEndpoint.address
            AudioObjectRemovePropertyListenerBlock(
                volumeEndpoint.objectID,
                &address,
                .main,
                systemVolumeListener
            )
        }
        self.volumeEndpoint = nil
        self.systemVolumeListener = nil
    }

    private func syncVolumeFromSystemControl(_ endpoint: VolumeEndpoint) {
        guard let systemVolume = Self.volume(of: endpoint) else { return }
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
            guard let name = deviceName(for: identifier) else { return nil }
            let uid = deviceUID(for: identifier) ?? "coreaudio:\(identifier)"
            return AudioDevice(id: identifier, uid: uid, name: name)
        }
    }

    private static var outputDeviceList: [AudioDevice] {
        devices.filter {
            $0.name != virtualDeviceName
                && $0.name != legacyVirtualDeviceName
                && hasChannels($0.id, scope: kAudioObjectPropertyScopeOutput)
                && !isMicrophone($0.name)
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

    private static func deviceUID(for device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &uid) == noErr else {
            return nil
        }
        return uid?.takeUnretainedValue() as String?
    }

    private static func device(withUID uid: String) -> AudioDeviceID? {
        devices.first { $0.uid == uid }?.id
    }

    private static func bufferFrameSize(of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frameSize: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &frameSize) == noErr else {
            return nil
        }
        return frameSize
    }

    private static func bufferFrameSizeRange(of device: AudioDeviceID) -> AudioValueRange? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var dataSize = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &range) == noErr else {
            return nil
        }
        return range
    }

    private static func canSetBufferFrameSize(of device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr
            && isSettable.boolValue
    }

    private static func setBufferFrameSize(of device: AudioDeviceID, to frameSize: UInt32) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableFrameSize = frameSize
        let status = AudioObjectSetPropertyData(
            device,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableFrameSize
        )
        guard status == noErr else {
            throw AudioRouterError.coreAudio(status, "Optimising the output buffer")
        }
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

    private static func hasNativeOutputVolume(for device: AudioDeviceID) -> Bool {
        guard virtualMainVolume(of: device) != nil else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr
            && isSettable.boolValue
    }

    private static func volume(of endpoint: VolumeEndpoint) -> Float? {
        switch endpoint {
        case let .control(control): return volume(of: control)
        case let .virtualMain(device): return virtualMainVolume(of: device)
        }
    }

    private static func setVolume(of endpoint: VolumeEndpoint, to volume: Float) throws {
        switch endpoint {
        case let .control(control): try setVolume(of: control, to: volume)
        case let .virtualMain(device): try setVirtualMainVolume(of: device, to: volume)
        }
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
