// DeviceWatcher.swift — IOKit matching notifications for the dext.
//
// Fires a callback whenever a VFIOUserPCIDriver service is published
// (the dext bound a device — e.g. an eGPU was plugged in) or terminated
// (device unplugged / driver torn down). This is the event-driven
// alternative to polling the IORegistry: an IONotificationPort wired to
// a dispatch queue, with first-match + terminated notifications armed
// against the dext's registry name.
//
// Note: the callback deliberately carries no payload. Consumers re-run
// the existing IORegistry walk (autoDetectPassthroughSlot) to get the
// current truth — the walk already resolves BDFs, sibling functions,
// and device classes, and racing registry lookups against a half-torn-
// down service object from the iterator is not worth the parse.

import Foundation
import IOKit

/// Registry-entry name the dext's services publish under. This is the
/// dext *class* name (fixed in the driver source), not the bundle id,
/// so it survives a forker's PRODUCT_BUNDLE_IDENTIFIER rename — same
/// fallback used by the device enumeration in Passthrough.swift.
private let kDextServiceName = "VFIOUserPCIDriver"

nonisolated final class DextDeviceWatcher: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var termIterator: io_iterator_t = 0

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Arm the notifications. Fires `onChange` once immediately so the
    /// consumer picks up the current state.
    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, DispatchQueue.global())
        notifyPort = port

        let context = Unmanaged.passUnretained(self).toOpaque()

        // Each IOServiceAddMatchingNotification call consumes one
        // matching-dict reference, hence a fresh dict per call. The
        // returned iterator must be drained to arm the notification;
        // its initial contents are the already-bound services.
        if IOServiceAddMatchingNotification(port,
                                            kIOFirstMatchNotification,
                                            IOServiceNameMatching(kDextServiceName),
                                            Self.callback,
                                            context,
                                            &matchIterator) == KERN_SUCCESS
        {
            Self.drain(matchIterator)
        }
        if IOServiceAddMatchingNotification(port,
                                            kIOTerminatedNotification,
                                            IOServiceNameMatching(kDextServiceName),
                                            Self.callback,
                                            context,
                                            &termIterator) == KERN_SUCCESS
        {
            Self.drain(termIterator)
        }

        onChange()
    }

    func stop() {
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if termIterator != 0 {
            IOObjectRelease(termIterator)
            termIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    // MARK: - Internals

    private static let callback: IOServiceMatchingCallback = { context, iterator in
        guard let context else { return }
        let watcher = Unmanaged<DextDeviceWatcher>.fromOpaque(context)
            .takeUnretainedValue()
        // Drain to re-arm, then let the consumer re-read the registry.
        drain(iterator)
        watcher.onChange()
    }

    private static func drain(_ iterator: io_iterator_t) {
        while true {
            let obj = IOIteratorNext(iterator)
            if obj == 0 { break }
            IOObjectRelease(obj)
        }
    }
}
