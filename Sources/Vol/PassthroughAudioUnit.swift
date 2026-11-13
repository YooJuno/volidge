import AudioToolbox
import CoreAudio
import Foundation
import VolAtomics

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

struct PassthroughAudioHealth {
    let captureCount: UInt64
    let renderCount: UInt64
    let captureStatus: OSStatus
    let droppedFrames: UInt64
    let underflowFrames: UInt64
}

final class PassthroughAudioUnit: @unchecked Sendable {
    private static let maximumFramesPerSlice = 4_096

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private let targetGain = VolAtomicUInt32Create(Float(0.7).bitPattern)!
    private let renderCount = VolAtomicUInt64Create(0)!
    private let captureCount = VolAtomicUInt64Create(0)!
    private let lastCaptureStatus = VolAtomicUInt32Create(0)!
    private let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: maximumFramesPerSlice * 2)
    private let inputBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    private let ringBuffer = AudioRingBuffer(frameCapacity: 16_384)
    private var currentGain: Float = 0.7

    init() {
        inputBufferList.pointee.mNumberBuffers = 1
        inputBufferList.pointee.mBuffers = AudioBuffer(
            mNumberChannels: 2,
            mDataByteSize: 0,
            mData: UnsafeMutableRawPointer(inputStorage)
        )
    }

    deinit {
        stop()
        VolAtomicUInt32Destroy(targetGain)
        VolAtomicUInt64Destroy(renderCount)
        VolAtomicUInt64Destroy(captureCount)
        VolAtomicUInt32Destroy(lastCaptureStatus)
        inputStorage.deallocate()
        inputBufferList.deallocate()
    }

    func start(inputDevice: AudioDeviceID, outputDevice: AudioDeviceID, sampleRate: Float64) throws {
        stop()
        VolAtomicUInt64StoreRelaxed(renderCount, 0)
        VolAtomicUInt64StoreRelaxed(captureCount, 0)
        VolAtomicUInt32StoreRelaxed(lastCaptureStatus, 0)
        ringBuffer.reset()
        currentGain = Float(bitPattern: VolAtomicUInt32LoadAcquire(targetGain))

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
        let clampedValue = min(max(value, 0), 1)
        VolAtomicUInt32StoreRelease(targetGain, clampedValue.bitPattern)
    }

    var diagnosticDescription: String {
        let health = healthSnapshot
        if health.captureCount == 0 {
            return "Volidge input callback did not run"
        }
        if health.captureStatus != noErr {
            return "Volidge capture error \(health.captureStatus)"
        }
        if health.renderCount == 0 {
            return "iD14 output callback did not run"
        }
        let metrics = ringBuffer.metrics
        return "audio bridge active · queue \(metrics.queuedFrames)f · drift \(metrics.rateCorrectionPPM) ppm · dropped \(metrics.droppedFrames) · silent \(metrics.underflowFrames)"
    }

    var healthSnapshot: PassthroughAudioHealth {
        let metrics = ringBuffer.metrics
        return PassthroughAudioHealth(
            captureCount: VolAtomicUInt64LoadRelaxed(captureCount),
            renderCount: VolAtomicUInt64LoadRelaxed(renderCount),
            captureStatus: OSStatus(Int32(bitPattern: VolAtomicUInt32LoadRelaxed(lastCaptureStatus))),
            droppedFrames: metrics.droppedFrames,
            underflowFrames: metrics.underflowFrames
        )
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
        VolAtomicUInt64FetchAddRelaxed(captureCount, 1)
        guard let inputUnit else { return noErr }

        let capturedFrames = min(Int(frameCount), Self.maximumFramesPerSlice)
        inputBufferList.pointee.mBuffers.mDataByteSize = UInt32(capturedFrames * 2 * MemoryLayout<Float>.size)
        let status = AudioUnitRender(inputUnit, actionFlags, timestamp, 1, UInt32(capturedFrames), inputBufferList)
        VolAtomicUInt32StoreRelaxed(lastCaptureStatus, UInt32(bitPattern: Int32(status)))
        if status == noErr {
            ringBuffer.write(inputStorage, frames: capturedFrames)
        }
        return noErr
    }

    private func render(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        VolAtomicUInt64FetchAddRelaxed(renderCount, 1)
        ringBuffer.read(into: audioBufferList, frames: Int(frameCount))

        let targetGain = Float(bitPattern: VolAtomicUInt32LoadAcquire(targetGain))
        let startingGain = currentGain
        let frameTotal = max(Int(frameCount), 1)
        let gainStep = (targetGain - startingGain) / Float(frameTotal)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let data = buffers.first?.mData else { return noErr }
        let samples = data.assumingMemoryBound(to: Float.self)
        for frame in 0 ..< frameTotal {
            let frameGain = startingGain + gainStep * Float(frame + 1)
            samples[frame * 2] *= frameGain
            samples[frame * 2 + 1] *= frameGain
        }
        currentGain = targetGain
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

private struct AudioRingBufferMetrics {
    let queuedFrames: UInt64
    let droppedFrames: UInt64
    let underflowFrames: UInt64
    let rateCorrectionPPM: Int32
}

private final class AudioRingBuffer: @unchecked Sendable {
    private let frameCapacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let readFrame = VolAtomicUInt64Create(0)!
    private let writeFrame = VolAtomicUInt64Create(0)!
    private let droppedFrames = VolAtomicUInt64Create(0)!
    private let underflowFrames = VolAtomicUInt64Create(0)!
    private let queuedFrames = VolAtomicUInt64Create(0)!
    private let overflowGeneration = VolAtomicUInt64Create(0)!
    private let producerFrameSize = VolAtomicUInt64Create(0)!
    private let rateCorrectionPPM = VolAtomicUInt32Create(0)!
    private var readPosition = 0.0
    private var currentRateRatio = 1.0
    private var lastOverflowGeneration: UInt64 = 0
    private var isPrimed = false
    private var hasPrimed = false

    init(frameCapacity: Int) {
        self.frameCapacity = frameCapacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity * 2)
        storage.initialize(repeating: 0, count: frameCapacity * 2)
    }

    deinit {
        VolAtomicUInt64Destroy(readFrame)
        VolAtomicUInt64Destroy(writeFrame)
        VolAtomicUInt64Destroy(droppedFrames)
        VolAtomicUInt64Destroy(underflowFrames)
        VolAtomicUInt64Destroy(queuedFrames)
        VolAtomicUInt64Destroy(overflowGeneration)
        VolAtomicUInt64Destroy(producerFrameSize)
        VolAtomicUInt32Destroy(rateCorrectionPPM)
        storage.deallocate()
    }

    var metrics: AudioRingBufferMetrics {
        AudioRingBufferMetrics(
            queuedFrames: VolAtomicUInt64LoadRelaxed(queuedFrames),
            droppedFrames: VolAtomicUInt64LoadRelaxed(droppedFrames),
            underflowFrames: VolAtomicUInt64LoadRelaxed(underflowFrames),
            rateCorrectionPPM: Int32(bitPattern: VolAtomicUInt32LoadRelaxed(rateCorrectionPPM))
        )
    }

    func reset() {
        VolAtomicUInt64StoreRelaxed(readFrame, 0)
        VolAtomicUInt64StoreRelaxed(writeFrame, 0)
        VolAtomicUInt64StoreRelaxed(droppedFrames, 0)
        VolAtomicUInt64StoreRelaxed(underflowFrames, 0)
        VolAtomicUInt64StoreRelaxed(queuedFrames, 0)
        VolAtomicUInt64StoreRelaxed(overflowGeneration, 0)
        VolAtomicUInt64StoreRelaxed(producerFrameSize, 0)
        VolAtomicUInt32StoreRelaxed(rateCorrectionPPM, 0)
        readPosition = 0
        currentRateRatio = 1
        lastOverflowGeneration = 0
        isPrimed = false
        hasPrimed = false
    }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        VolAtomicUInt64StoreRelaxed(producerFrameSize, UInt64(frames))
        let currentWriteFrame = VolAtomicUInt64LoadRelaxed(writeFrame)
        let currentReadFrame = VolAtomicUInt64LoadAcquire(readFrame)
        let bufferedFrames = min(currentWriteFrame &- currentReadFrame, UInt64(frameCapacity))
        let writableFrames = Int(UInt64(frameCapacity) - bufferedFrames)
        let framesToWrite = min(frames, writableFrames)

        if framesToWrite > 0 {
            copyIntoStorage(source, startingAt: currentWriteFrame, frames: framesToWrite)
            VolAtomicUInt64StoreRelease(writeFrame, currentWriteFrame &+ UInt64(framesToWrite))
        }
        if framesToWrite < frames {
            VolAtomicUInt64FetchAddRelaxed(droppedFrames, UInt64(frames - framesToWrite))
            VolAtomicUInt64FetchAddRelaxed(overflowGeneration, 1)
        }
        VolAtomicUInt64StoreRelaxed(queuedFrames, bufferedFrames + UInt64(framesToWrite))
    }

    func read(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard let output = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        let currentWriteFrame = VolAtomicUInt64LoadAcquire(writeFrame)
        let currentOverflowGeneration = VolAtomicUInt64LoadAcquire(overflowGeneration)
        if currentOverflowGeneration != lastOverflowGeneration {
            lastOverflowGeneration = currentOverflowGeneration
            flush(upTo: currentWriteFrame)
            VolAtomicUInt64FetchAddRelaxed(underflowFrames, UInt64(frames))
            return
        }

        var currentReadFrame = UInt64(readPosition.rounded(.down))
        var bufferedFrames = min(currentWriteFrame &- currentReadFrame, UInt64(frameCapacity))
        let producerFrames = Int(VolAtomicUInt64LoadRelaxed(producerFrameSize))
        let targetFrames = UInt64(
            min(
                frameCapacity / 2,
                max(frames + producerFrames + max(producerFrames / 2, 64), 256)
            )
        )
        var shouldFadeIn = false

        if !isPrimed {
            guard bufferedFrames >= targetFrames + 2 else {
                if hasPrimed {
                    VolAtomicUInt64FetchAddRelaxed(underflowFrames, UInt64(frames))
                }
                VolAtomicUInt64StoreRelaxed(queuedFrames, bufferedFrames)
                return
            }
            let alignedReadFrame = currentWriteFrame - targetFrames
            let discardedFrames = alignedReadFrame &- currentReadFrame
            if discardedFrames > 0 {
                VolAtomicUInt64FetchAddRelaxed(droppedFrames, discardedFrames)
            }
            readPosition = Double(alignedReadFrame)
            currentReadFrame = alignedReadFrame
            bufferedFrames = targetFrames
            isPrimed = true
            hasPrimed = true
            shouldFadeIn = true
        } else if bufferedFrames > targetFrames * 4 {
            let alignedReadFrame = currentWriteFrame - targetFrames
            let discardedFrames = alignedReadFrame &- currentReadFrame
            VolAtomicUInt64FetchAddRelaxed(droppedFrames, discardedFrames)
            readPosition = Double(alignedReadFrame)
            currentReadFrame = alignedReadFrame
            bufferedFrames = targetFrames
            shouldFadeIn = true
        }

        let queueError = Double(bufferedFrames) - Double(targetFrames)
        let normalizedError = queueError / Double(targetFrames)
        let desiredCorrection = min(max(normalizedError * 0.006, -0.005), 0.005)
        let desiredRateRatio = 1 + desiredCorrection
        currentRateRatio += (desiredRateRatio - currentRateRatio) * 0.08
        let correctionPPM = Int32((currentRateRatio - 1) * 1_000_000)
        VolAtomicUInt32StoreRelaxed(rateCorrectionPPM, UInt32(bitPattern: correctionPPM))

        let availableSourceFrames = Double(currentWriteFrame) - readPosition
        let readableOutputFrames = min(
            frames,
            max(0, Int(((availableSourceFrames - 1) / currentRateRatio).rounded(.down)))
        )

        var sourcePosition = readPosition
        for outputFrame in 0 ..< readableOutputFrames {
            let sourceFrame = UInt64(sourcePosition.rounded(.down))
            let fraction = Float(sourcePosition - Double(sourceFrame))
            let inverseFraction = 1 - fraction
            output[outputFrame * 2] = sample(at: sourceFrame, channel: 0) * inverseFraction
                + sample(at: sourceFrame + 1, channel: 0) * fraction
            output[outputFrame * 2 + 1] = sample(at: sourceFrame, channel: 1) * inverseFraction
                + sample(at: sourceFrame + 1, channel: 1) * fraction
            sourcePosition += currentRateRatio
        }

        readPosition = sourcePosition
        let newReadFrame = UInt64(readPosition.rounded(.down))
        VolAtomicUInt64StoreRelease(readFrame, newReadFrame)
        VolAtomicUInt64StoreRelaxed(queuedFrames, currentWriteFrame &- newReadFrame)

        if shouldFadeIn {
            fadeIn(output, frames: readableOutputFrames)
        }
        if readableOutputFrames < frames {
            fadeOut(output, endingAt: readableOutputFrames)
            VolAtomicUInt64FetchAddRelaxed(underflowFrames, UInt64(frames - readableOutputFrames))
            isPrimed = false
        }
    }

    private func copyIntoStorage(_ source: UnsafePointer<Float>, startingAt frame: UInt64, frames: Int) {
        let storageFrame = Int(frame % UInt64(frameCapacity))
        let firstFrameCount = min(frames, frameCapacity - storageFrame)
        memcpy(storage.advanced(by: storageFrame * 2), source, firstFrameCount * 2 * MemoryLayout<Float>.size)

        let remainingFrames = frames - firstFrameCount
        if remainingFrames > 0 {
            memcpy(storage, source.advanced(by: firstFrameCount * 2), remainingFrames * 2 * MemoryLayout<Float>.size)
        }
    }

    private func sample(at frame: UInt64, channel: Int) -> Float {
        storage[Int(frame % UInt64(frameCapacity)) * 2 + channel]
    }

    private func flush(upTo writeFrame: UInt64) {
        readPosition = Double(writeFrame)
        VolAtomicUInt64StoreRelease(readFrame, writeFrame)
        VolAtomicUInt64StoreRelaxed(queuedFrames, 0)
        VolAtomicUInt32StoreRelaxed(rateCorrectionPPM, 0)
        currentRateRatio = 1
        isPrimed = false
    }

    private func fadeIn(_ output: UnsafeMutablePointer<Float>, frames: Int) {
        let fadeFrameCount = min(32, frames)
        guard fadeFrameCount > 0 else { return }
        for frame in 0 ..< fadeFrameCount {
            let scale = Float(frame + 1) / Float(fadeFrameCount)
            output[frame * 2] *= scale
            output[frame * 2 + 1] *= scale
        }
    }

    private func fadeOut(_ output: UnsafeMutablePointer<Float>, endingAt frameCount: Int) {
        let fadeFrameCount = min(32, frameCount)
        guard fadeFrameCount > 0 else { return }
        let fadeStart = frameCount - fadeFrameCount
        for frame in 0 ..< fadeFrameCount {
            let scale = Float(fadeFrameCount - frame - 1) / Float(fadeFrameCount)
            let outputFrame = fadeStart + frame
            output[outputFrame * 2] *= scale
            output[outputFrame * 2 + 1] *= scale
        }
    }
}
