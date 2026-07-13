import AudioToolbox
import CoreAudio
import Foundation

enum PassthroughAudioUnitError: LocalizedError {
    case unavailableComponent
    case coreAudio(OSStatus, String)

    var errorDescription: String? {
        switch self {
        case .unavailableComponent:
            return "macOS could not create the audio bridge."
        case let .coreAudio(status, operation):
            return "\(operation) failed (Core Audio error \(status))."
        }
    }
}

final class PassthroughAudioUnit: @unchecked Sendable {
    private static let maximumFramesPerSlice = 4_096

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let renderCount = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let captureCount = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let lastCaptureStatus = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: maximumFramesPerSlice * 2)
    private let inputBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    private let ringBuffer = AudioRingBuffer(frameCapacity: 8_192)

    init() {
        gain.pointee = 0.7
        renderCount.pointee = 0
        captureCount.pointee = 0
        lastCaptureStatus.pointee = 0
        inputBufferList.pointee.mNumberBuffers = 1
        inputBufferList.pointee.mBuffers = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: 0,
            mData: UnsafeMutableRawPointer(inputStorage)
        )
    }

    deinit {
        stop()
        gain.deallocate()
        renderCount.deallocate()
        captureCount.deallocate()
        lastCaptureStatus.deallocate()
        inputStorage.deallocate()
        inputBufferList.deallocate()
    }

    func start(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID, sampleRate: Float64) throws {
        stop()
        renderCount.pointee = 0
        captureCount.pointee = 0
        lastCaptureStatus.pointee = 0
        ringBuffer.reset()

        let inputUnit = try makeHALOutputUnit()
        let outputUnit = try makeHALOutputUnit()
        let format = stereoFloatFormat(sampleRate: sampleRate)

        do {
            try configureInput(inputUnit, device: inputDevice, format: format)
            try configureOutput(outputUnit, device: outputDevice, format: format)

            var inputCallback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(
                AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_SetInputCallback,
                    kAudioUnitScope_Global,
                    1,
                    &inputCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "Setting the Volidge input callback"
            )

            var outputCallback = AURenderCallbackStruct(
                inputProc: Self.outputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &outputCallback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                "Setting the iD14 output callback"
            )

            try check(AudioUnitInitialize(inputUnit), "Initialising Volidge input")
            try check(AudioUnitInitialize(outputUnit), "Initialising iD14 output")

            self.inputUnit = inputUnit
            self.outputUnit = outputUnit
            try check(AudioOutputUnitStart(inputUnit), "Starting Volidge input")
            try check(AudioOutputUnitStart(outputUnit), "Starting iD14 output")
        } catch {
            AudioComponentInstanceDispose(inputUnit)
            AudioComponentInstanceDispose(outputUnit)
            throw error
        }
    }

    func stop() {
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
            self.inputUnit = nil
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
    }

    func setVolume(_ value: Float) {
        gain.pointee = min(max(value, 0), 1)
    }

    var diagnosticDescription: String {
        if captureCount.pointee == 0 {
            return "Volidge input callback did not run"
        }
        let inputStatus = OSStatus(lastCaptureStatus.pointee)
        if inputStatus != noErr {
            return "Volidge capture error \(inputStatus)"
        }
        if renderCount.pointee == 0 {
            return "iD14 output callback did not run"
        }
        return "audio bridge active"
    }

    private func configureInput(
        _ audioUnit: AudioUnit,
        device: AudioDeviceID,
        format: AudioStreamBasicDescription
    ) throws {
        var enabled: UInt32 = 1
        var disabled: UInt32 = 0
        var device = device
        var format = format
        var maximumFramesPerSlice = UInt32(Self.maximumFramesPerSlice)

        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, UInt32(MemoryLayout<UInt32>.size)), "Enabling Volidge input")
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, UInt32(MemoryLayout<UInt32>.size)), "Disabling unused Volidge output")
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting Volidge")
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Configuring Volidge format")
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFramesPerSlice, UInt32(MemoryLayout<UInt32>.size)), "Configuring Volidge buffer size")
    }

    private func configureOutput(
        _ audioUnit: AudioUnit,
        device: AudioDeviceID,
        format: AudioStreamBasicDescription
    ) throws {
        var enabled: UInt32 = 1
        var disabled: UInt32 = 0
        var device = device
        var format = format
        var maximumFramesPerSlice = UInt32(Self.maximumFramesPerSlice)

        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, UInt32(MemoryLayout<UInt32>.size)), "Enabling iD14 output")
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disabled, UInt32(MemoryLayout<UInt32>.size)), "Disabling unused iD14 input")
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting iD14")
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Configuring iD14 format")
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFramesPerSlice, UInt32(MemoryLayout<UInt32>.size)), "Configuring iD14 buffer size")
    }

    private static let inputCallback: AURenderCallback = { context, actionFlags, timestamp, _, frameCount, _ in
        let bridge = Unmanaged<PassthroughAudioUnit>.fromOpaque(context).takeUnretainedValue()
        return bridge.capture(actionFlags: actionFlags, timestamp: timestamp, frameCount: frameCount)
    }

    private static let outputCallback: AURenderCallback = { context, _, _, _, frameCount, audioBufferList in
        guard let audioBufferList else { return noErr }
        let bridge = Unmanaged<PassthroughAudioUnit>.fromOpaque(context).takeUnretainedValue()
        return bridge.render(frameCount: frameCount, audioBufferList: audioBufferList)
    }

    private func capture(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        captureCount.pointee &+= 1
        guard let inputUnit else { return noErr }

        let capturedFrames = min(Int(frameCount), Self.maximumFramesPerSlice)
        inputBufferList.pointee.mBuffers.mDataByteSize = UInt32(capturedFrames * 2 * MemoryLayout<Float>.size)
        let status = AudioUnitRender(inputUnit, actionFlags, timestamp, 1, UInt32(capturedFrames), inputBufferList)
        lastCaptureStatus.pointee = Int32(status)
        if status == noErr {
            ringBuffer.write(inputStorage, frames: capturedFrames)
        }
        return noErr
    }

    private func render(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        renderCount.pointee &+= 1
        ringBuffer.read(into: audioBufferList, frames: Int(frameCount))

        let currentGain = gain.pointee
        guard currentGain != 1 else { return noErr }
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let samples = data.bindMemory(to: Float.self, capacity: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            for index in 0 ..< Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                samples[index] *= currentGain
            }
        }
        return noErr
    }

    private func makeHALOutputUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw PassthroughAudioUnitError.unavailableComponent
        }
        var audioUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &audioUnit), "Creating the audio bridge")
        guard let audioUnit else { throw PassthroughAudioUnitError.unavailableComponent }
        return audioUnit
    }

    private func stereoFloatFormat(sampleRate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw PassthroughAudioUnitError.coreAudio(status, operation) }
    }
}

private final class AudioRingBuffer: @unchecked Sendable {
    private let frameCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = NSLock()
    private var readFrame = 0
    private var writeFrame = 0
    private var availableFrames = 0

    init(frameCapacity: Int) {
        self.frameCapacity = frameCapacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity * 2)
        storage.initialize(repeating: 0, count: frameCapacity * 2)
    }

    deinit { storage.deallocate() }

    func reset() {
        lock.lock()
        readFrame = 0
        writeFrame = 0
        availableFrames = 0
        lock.unlock()
    }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        lock.lock()
        for frame in 0 ..< frames {
            if availableFrames == frameCapacity {
                readFrame = (readFrame + 1) % frameCapacity
                availableFrames -= 1
            }
            let destination = storage.advanced(by: writeFrame * 2)
            let sourceFrame = source.advanced(by: frame * 2)
            destination[0] = sourceFrame[0]
            destination[1] = sourceFrame[1]
            writeFrame = (writeFrame + 1) % frameCapacity
            availableFrames += 1
        }
        lock.unlock()
    }

    func read(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard let output = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        lock.lock()
        let maximumBufferedFrames = min(frameCapacity, max(frames * 2, 1_024))
        if availableFrames > maximumBufferedFrames {
            let framesToDiscard = availableFrames - maximumBufferedFrames
            readFrame = (readFrame + framesToDiscard) % frameCapacity
            availableFrames -= framesToDiscard
        }
        let readableFrames = min(frames, availableFrames)
        for frame in 0 ..< readableFrames {
            let source = storage.advanced(by: readFrame * 2)
            let destination = output.advanced(by: frame * 2)
            destination[0] = source[0]
            destination[1] = source[1]
            readFrame = (readFrame + 1) % frameCapacity
        }
        availableFrames -= readableFrames
        lock.unlock()
    }
}
