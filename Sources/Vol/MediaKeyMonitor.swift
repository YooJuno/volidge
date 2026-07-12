import Foundation
import IOKit.hid

final class MediaKeyMonitor: @unchecked Sendable {
    enum Key: Sendable {
        case volumeUp
        case volumeDown
        case mute
    }

    private let handler: (Key) -> Void
    private var manager: IOHIDManager?

    init(handler: @escaping (Key) -> Void) {
        self.handler = handler
    }

    func start() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerRegisterInputValueCallback(
            manager,
            Self.handleInputValue,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private static let handleInputValue: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }

        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_Consumer) else { return }

        let key: Key?
        switch IOHIDElementGetUsage(element) {
        case UInt32(kHIDUsage_Csmr_VolumeIncrement):
            key = .volumeUp
        case UInt32(kHIDUsage_Csmr_VolumeDecrement):
            key = .volumeDown
        case UInt32(kHIDUsage_Csmr_Mute):
            key = .mute
        default:
            key = nil
        }

        guard let key else { return }
        let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            monitor.handler(key)
        }
    }
}
