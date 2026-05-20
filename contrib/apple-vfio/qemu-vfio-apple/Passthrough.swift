// Passthrough.swift — auto-detect a dext-bound PCI *slot* (not just a
// single function) for `-device vfio-apple-pci`.
//
// NVIDIA and AMD discrete GPUs are multi-function: the video controller
// sits on function 0 and an HDMI/DisplayPort audio controller sits on
// function 1, sometimes with a USB-C / NVLink bridge on further
// functions. Passing through only the video function works visually
// but loses digital audio, and can confuse drivers that expect the
// whole endpoint group (libpci treats functions as siblings).
//
// We therefore:
//   1. Walk all IOPCIDevice nodes.
//   2. Keep only those bound to our dext (by CFBundleIdentifier, with
//      a fallback on the legacy registry-entry name).
//   3. Group them by their host PCI slot (bus:device).
//   4. Prefer the slot whose function 0 is a display controller
//      (PCI class 0x03) — that's the GPU slot we want to pass. If no
//      display-class slot is bound, fall back to any slot that has
//      at least one function bound (useful for non-GPU testing, and
//      matches what a user would expect from "just pick whichever
//      device the dext claimed").
//   5. Return every dext-bound function in that slot, sorted by
//      function number so function 0 is first — the launcher relies
//      on that to set multifunction=on on the right device.
//
// For explicit `--passthrough <BDF>` overrides we expose
// `findSlotSiblings(bus:device:)` so the launcher can auto-complete
// the user's single BDF with its dext-bound siblings.

import Foundation
import IOKit

// kDextBundleID is defined in Driver.swift and shared with the
// driver-status / list-devices subcommands.

struct PassthroughCandidate {
    let bus:      UInt8
    let device:   UInt8
    let function: UInt8
    let vendor:   UInt16
    let deviceId: UInt16
    let classCode: UInt32     // full 3-byte PCI class code (base<<16 | sub<<8 | prog)
    let description: String

    /// vfio-apple-pci host= syntax, e.g. "43:00.0".
    var hostBDF: String {
        String(format: "%02x:%02x.%x", bus, device, function)
    }

    /// Slot-only form (no function), used for log messages describing
    /// the whole endpoint group rather than an individual function.
    var slotString: String {
        String(format: "%02x:%02x", bus, device)
    }

    /// PCI base class (the most significant byte of classCode).
    var baseClass: UInt8 { UInt8((classCode >> 16) & 0xff) }

    /// True if this is a display controller (VGA, 3D, XGA, other).
    var isDisplayController: Bool { baseClass == 0x03 }
}

// MARK: - Auto-detect

/// Find all functions of the slot we should pass through. Returns an
/// empty array if no dext-bound devices exist. The launcher treats an
/// empty return as "no passthrough" rather than an error.
func autoDetectPassthroughSlot() -> [PassthroughCandidate] {
    let all = collectDextBoundPCIDevices()
    if all.isEmpty { return [] }

    // Group by (bus, device).
    var slots: [UInt16: [PassthroughCandidate]] = [:]
    for c in all {
        let key = (UInt16(c.bus) << 8) | UInt16(c.device)
        slots[key, default: []].append(c)
    }

    // Prefer the first slot whose function 0 is a display controller.
    let preferredSlot: [PassthroughCandidate]? = slots.values.first(where: { group in
        group.contains(where: { $0.isDisplayController })
    })

    let picked = preferredSlot ?? slots.values.first
    guard var functions = picked else { return [] }
    functions.sort(by: { $0.function < $1.function })

    // Drop multimedia/audio functions (PCI base class 0x04). On NVIDIA
    // and AMD discrete GPUs, function 1 is the HDMI/DisplayPort audio
    // controller — useful for desktop output, useless for headless
    // inference, and an extra DMA source that has triggered DART
    // assertions on this fork (see VFIOUserPCIDriver.cpp PrepareForDMA
    // path). Skip it by default; the user can still force it in via
    // an explicit `--passthrough BB:DD.F` referencing the audio
    // function, since findExactFunction() bypasses this filter.
    let kept = functions.filter { $0.baseClass != 0x04 }
    for d in functions where d.baseClass == 0x04 {
        warn("skipping audio function \(d.hostBDF) (\(d.description)) — " +
             "pass it explicitly with --passthrough \(d.hostBDF) if you need it")
    }
    return kept
}

/// Given an explicit BDF (e.g. "43:00.0"), return the dext-bound
/// functions that share its slot. If none of the siblings are bound
/// we fall back to returning just the requested BDF as a synthesized
/// candidate so the user's override still works end-to-end.
func findSlotSiblings(bus: UInt8, device: UInt8, fallbackBDF: String) -> [PassthroughCandidate] {
    let all = collectDextBoundPCIDevices()
    var match = all.filter { $0.bus == bus && $0.device == device }
    if match.isEmpty {
        return [PassthroughCandidate(
            bus: bus, device: device, function: 0,
            vendor: 0, deviceId: 0, classCode: 0,
            description: "explicit (\(fallbackBDF), not bound to dext)"
        )]
    }
    match.sort(by: { $0.function < $1.function })
    return match
}

/// Look up a single (bus, device, function) in the dext-bound set.
/// Used when the user asked for a specific function explicitly (e.g.
/// `--passthrough 03:00.0`) so we *don't* also drag in sibling
/// functions. Returns a synthesized candidate if the exact BDF isn't
/// bound to the dext — mirrors findSlotSiblings' fallback behaviour.
func findSingleFunction(bus: UInt8,
                        device: UInt8,
                        function: UInt8,
                        fallbackBDF: String) -> [PassthroughCandidate]
{
    let all = collectDextBoundPCIDevices()
    if let hit = all.first(where: {
        $0.bus == bus && $0.device == device && $0.function == function
    }) {
        return [hit]
    }
    return [PassthroughCandidate(
        bus: bus, device: device, function: function,
        vendor: 0, deviceId: 0, classCode: 0,
        description: "explicit (\(fallbackBDF), not bound to dext)"
    )]
}

/// Parse "43:00.0" / "0000:43:00.0" (explicit function) or "43:00" /
/// "0000:43:00" (slot only) into (bus, device, function?). Function
/// is nil when the user omitted the ".N" suffix, which the launcher
/// interprets as "expand to all dext-bound sibling functions in this
/// slot" — the historical behaviour. Supplying the function selects
/// that single function.
func parseHostBDF(_ s: String) -> (UInt8, UInt8, UInt8?)? {
    // Strip optional PCI domain prefix (4 hex digits + colon).
    var rest = s
    let colons = rest.filter { $0 == ":" }.count
    if colons >= 2, let firstColon = rest.firstIndex(of: ":") {
        rest = String(rest[rest.index(after: firstColon)...])
    }

    // Separate the "bus:dev" part from the optional ".fn" tail so we
    // don't have to guess whether a 2- or 3-part split was intended.
    let fnPart: Substring?
    let slotPart: Substring
    if let dot = rest.firstIndex(of: ".") {
        slotPart = rest[..<dot]
        fnPart   = rest[rest.index(after: dot)...]
    } else {
        slotPart = Substring(rest)
        fnPart   = nil
    }

    let slotParts = slotPart.split(separator: ":")
    guard slotParts.count == 2,
          let bus = UInt8(slotParts[0], radix: 16),
          let dev = UInt8(slotParts[1], radix: 16)
    else { return nil }

    var fn: UInt8? = nil
    if let fp = fnPart {
        guard let v = UInt8(fp, radix: 16) else { return nil }
        fn = v
    }
    return (bus, dev, fn)
}

// MARK: - IOKit walk

/// Enumerate every IOPCIDevice whose registry has a child service
/// bound to our dext, and return them as PassthroughCandidate records.
private func collectDextBoundPCIDevices() -> [PassthroughCandidate] {
    var result: [PassthroughCandidate] = []

    guard let matching = IOServiceMatching("IOPCIDevice") else { return [] }
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iter) }

    var dev = IOIteratorNext(iter)
    while dev != 0 {
        defer {
            IOObjectRelease(dev)
            dev = IOIteratorNext(iter)
        }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(dev, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { continue }

        guard isDeviceBoundToOurDext(dev) else { continue }

        guard let (bus, device, function) = parsePcidebugTriple(dict["pcidebug"]) else { continue }

        let cls    = readU32(dict["class-code"])
        let vendor = readU16(dict["vendor-id"])
        let dvId   = readU16(dict["device-id"])

        let name: String
        if let data = dict["name"] as? Data, let s = cStringFromData(data), !s.isEmpty {
            name = s
        } else if let s = dict["name"] as? String, !s.isEmpty {
            name = s
        } else {
            name = String(format: "pci%04x,%04x", Int(vendor), Int(dvId))
        }
        let desc = String(format: "%@ (%04x:%04x @ %02x:%02x.%x, class %06x)",
                          name, Int(vendor), Int(dvId), bus, device, function, Int(cls))
        result.append(PassthroughCandidate(
            bus: bus, device: device, function: function,
            vendor: vendor, deviceId: dvId,
            classCode: cls, description: desc
        ))
    }
    return result
}

private func isDeviceBoundToOurDext(_ pciDev: io_object_t) -> Bool {
    var iter: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(pciDev, kIOServicePlane, &iter) == KERN_SUCCESS else {
        return false
    }
    defer { IOObjectRelease(iter) }

    var child = IOIteratorNext(iter)
    while child != 0 {
        defer {
            IOObjectRelease(child)
            child = IOIteratorNext(iter)
        }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(child, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = unmanaged?.takeRetainedValue() as? [String: Any],
           let bid = dict["CFBundleIdentifier"] as? String,
           bid == kDextBundleID
        {
            return true
        }

        var name = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(child, &name) == KERN_SUCCESS,
           String(cString: name) == "VFIOUserPCIDriver"
        {
            return true
        }
    }
    return false
}

/// Convert `pcidebug` ("1:0:0" decimal bus:dev:func, optional trailing
/// "(seg:link)") into (bus, dev, fn) UInt8 triple.
private func parsePcidebugTriple(_ raw: Any?) -> (UInt8, UInt8, UInt8)? {
    guard let s = raw as? String, !s.isEmpty else { return nil }
    var head = s
    if let lp = s.firstIndex(of: "(") { head = String(s[..<lp]) }

    let parts = head.split(separator: ":")
    guard parts.count >= 3,
          let bus = UInt8(parts[0]),
          let dv  = UInt8(parts[1]),
          let fn  = UInt8(parts[2])
    else { return nil }
    return (bus, dv, fn)
}

private func readU16(_ v: Any?) -> UInt16 {
    guard let data = v as? Data, data.count >= 2 else { return 0 }
    return data.withUnsafeBytes { bp -> UInt16 in
        let p = bp.bindMemory(to: UInt8.self)
        return UInt16(p[0]) | (UInt16(p[1]) << 8)
    }
}

private func readU32(_ v: Any?) -> UInt32 {
    guard let data = v as? Data, data.count >= 4 else { return 0 }
    return data.withUnsafeBytes { bp -> UInt32 in
        let p = bp.bindMemory(to: UInt8.self)
        return UInt32(p[0])
            | (UInt32(p[1]) << 8)
            | (UInt32(p[2]) << 16)
            | (UInt32(p[3]) << 24)
    }
}

private func cStringFromData(_ data: Data) -> String? {
    var bytes = [UInt8](data)
    if !bytes.contains(0) { bytes.append(0) }
    return bytes.withUnsafeBufferPointer { bp -> String? in
        guard let base = bp.baseAddress else { return nil }
        return String(cString: base)
    }
}
