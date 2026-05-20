// VMLauncher.swift — orchestrate `qemu-system-aarch64` against a cached
// base image and a writable overlay.
//
// Responsibilities:
//
//   1. Find the bundled qemu binaries and firmware inside
//      VFIOUserHostApp.app. When running out-of-bundle (dev / swift run)
//      we fall back to PATH, which mostly exists for testing.
//
//   2. Lazily create a qcow2 overlay backed by the cached base image so
//      boots are non-destructive. `reset` subcommand deletes the overlay
//      to restore a fresh-boot state.
//
//   3. Seed a per-VM EFI vars file from the bundled template. EFI vars
//      need to be writable (boot order, UEFI settings) so we keep one
//      per VM state dir instead of sharing the template.
//
//   4. Optionally auto-detect a dext-bound display controller for
//      `-device vfio-apple-pci,host=<BDF>,dma-companion=on` passthrough.
//
//   5. Assemble a qemu argv matching the apple-vfio machine config
//      pattern (virt machine with an aux-ram-share memory-backend-ram)
//      and exec it, forwarding signals so ^C cleanly shuts down the
//      guest.

import Foundation

enum LaunchError: LocalizedError {
    case bundleMissing(String)
    case qemuImgFailed(Int32, String)
    case qemuLaunchFailed(String)
    case extraDisk(String)

    var errorDescription: String? {
        switch self {
        case .bundleMissing(let path):
            return """
            missing required file(s) in the app bundle; reinstall VFIOUserHostApp.app:
              \(path)
            """
        case .qemuImgFailed(let c, let s): return "qemu-img exited \(c): \(s)"
        case .qemuLaunchFailed(let s):     return "could not start qemu-system-aarch64: \(s)"
        case .extraDisk(let s):            return s
        }
    }
}

/// A `--disk` argument after qemu-img has told us its format and we've
/// standardized the path. The launcher resolves these before spawning
/// qemu so a bad path fails fast with a good error message instead of
/// qemu exiting mid-boot.
struct ResolvedDisk {
    let path:     String
    let format:   String  // "qcow2", "raw", …
    let readOnly: Bool
}

// MARK: - Bundle discovery

struct LauncherBundle {
    let qemuBinary:   URL
    let qemuImgBin:   URL
    let shareDir:     URL   // -L argument: .../Contents/Resources/share/qemu
    let efiCodeFile:  URL   // .../share/qemu/edk2-aarch64-code.fd
    let efiVarsFile:  URL   // .../share/qemu/edk2-arm-vars.fd (template)
}

/// Locate the bundled qemu binaries + firmware.
///
/// We expect this binary (qemu-vfio-apple) to live inside
/// `VFIOUserHostApp.app/Contents/MacOS/`. When run that way,
/// `ProcessInfo.arguments[0]` resolves into the bundle and we can walk
/// up to find the other tools.
///
/// When run from a development build (e.g. swift build in a plain
/// directory), we fall back to `PATH` so manual testing still works.
func discoverLauncherBundle() throws -> LauncherBundle {
    let exe = executableURL()
    let macosDir = exe.deletingLastPathComponent()
    let contents = macosDir.deletingLastPathComponent()
    let resources = contents.appendingPathComponent("Resources")
    let share = resources.appendingPathComponent("share/qemu")

    if let b = tryAssembleBundle(binariesIn: macosDir, shareDir: share) {
        return b
    }

    // Fall back to PATH. EFI vars and code come from the system qemu
    // install (e.g. homebrew) — paths are user-dependent so we only try
    // a couple of common locations.
    if let qemu = whichOnPATH("qemu-system-aarch64"),
       let qemuImg = whichOnPATH("qemu-img")
    {
        for candidate in ["/opt/homebrew/share/qemu",
                          "/usr/local/share/qemu",
                          "/usr/share/qemu"]
        {
            let share = URL(fileURLWithPath: candidate)
            if let b = tryAssembleBundle(qemuBinary: qemu,
                                         qemuImgBin: qemuImg,
                                         shareDir: share)
            {
                return b
            }
        }
    }

    // Nothing worked. Produce a message that tells the user *which*
    // piece is missing instead of blaming the whole bundle — the
    // single most common failure mode is a make-dist.sh that only
    // staged the code file and not the vars template.
    let fm = FileManager.default
    let qemu    = macosDir.appendingPathComponent("qemu-system-aarch64")
    let qemuImg = macosDir.appendingPathComponent("qemu-img")
    let efiCode = share.appendingPathComponent("edk2-aarch64-code.fd")
    let efiVarsCandidates = [
        share.appendingPathComponent("edk2-arm-vars.fd").path,
        share.appendingPathComponent("edk2-aarch64-vars.fd").path,
    ]
    var missing: [String] = []
    if !fm.isExecutableFile(atPath: qemu.path)      { missing.append(qemu.path) }
    if !fm.isExecutableFile(atPath: qemuImg.path)   { missing.append(qemuImg.path) }
    if !fm.fileExists(atPath: efiCode.path)         { missing.append(efiCode.path) }
    if efiVarsCandidates.allSatisfy({ !fm.fileExists(atPath: $0) }) {
        missing.append("\(efiVarsCandidates[0]) (or edk2-aarch64-vars.fd)")
    }
    throw LaunchError.bundleMissing(missing.joined(separator: "\n  "))
}

/// Try to assemble a LauncherBundle from an explicit (binariesDir, shareDir)
/// pair. Returns nil if any required piece is missing.
private func tryAssembleBundle(binariesIn macosDir: URL,
                               shareDir share: URL) -> LauncherBundle?
{
    let qemu    = macosDir.appendingPathComponent("qemu-system-aarch64")
    let qemuImg = macosDir.appendingPathComponent("qemu-img")
    return tryAssembleBundle(qemuBinary: qemu,
                             qemuImgBin: qemuImg,
                             shareDir: share)
}

private func tryAssembleBundle(qemuBinary qemu: URL,
                               qemuImgBin qemuImg: URL,
                               shareDir share: URL) -> LauncherBundle?
{
    let fm = FileManager.default
    let efiCode = share.appendingPathComponent("edk2-aarch64-code.fd")
    let efiVars = firstExisting([
        share.appendingPathComponent("edk2-arm-vars.fd"),
        share.appendingPathComponent("edk2-aarch64-vars.fd"),
    ])
    guard fm.isExecutableFile(atPath: qemu.path),
          fm.isExecutableFile(atPath: qemuImg.path),
          fm.fileExists(atPath: efiCode.path),
          let efiVars = efiVars
    else {
        return nil
    }
    return LauncherBundle(qemuBinary: qemu,
                          qemuImgBin: qemuImg,
                          shareDir: share,
                          efiCodeFile: efiCode,
                          efiVarsFile: efiVars)
}

/// Resolve the path this process is actually running from. Bundle.main
/// works when Foundation has had a chance to populate it, but for a
/// raw CLI we look at argv[0] + pwd. We prefer argv[0] when it includes
/// a slash and exists; otherwise fall through to `/proc/self/exe`-style
/// resolution via readlink. This keeps the wrapper-via-symlink case
/// (unlikely — installCli installs shell wrappers not symlinks) working.
private func executableURL() -> URL {
    if let url = Bundle.main.executableURL,
       FileManager.default.isExecutableFile(atPath: url.path) {
        return url
    }
    let argv0 = CommandLine.arguments[0]
    if argv0.contains("/") {
        return URL(fileURLWithPath: argv0).standardized
    }
    return URL(fileURLWithPath: argv0)
}

private func whichOnPATH(_ name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
    for dir in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: "\(dir)/\(name)")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }
    return nil
}

private func firstExisting(_ urls: [URL]) -> URL? {
    urls.first(where: { FileManager.default.fileExists(atPath: $0.path) })
}

// MARK: - Overlay + EFI vars provisioning

/// Ensure the writable overlay qcow2 exists and is backed by `base`.
/// Rebases if it already exists but points at a different backing
/// file — that happens when the cached base's digest changes.
private func ensureOverlay(_ overlay: URL, base: URL, bundle: LauncherBundle) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: overlay.path) {
        let currentBase = queryBackingFile(overlay, qemuImg: bundle.qemuImgBin)
        if let currentBase, currentBase != base.path {
            log("rebasing overlay to new base (\(base.lastPathComponent))")
            try runQemuImg(bundle.qemuImgBin,
                           args: ["rebase", "-u", "-F", "qcow2",
                                  "-b", base.path,
                                  overlay.path])
        }
        return
    }

    log("creating overlay \(overlay.lastPathComponent) on \(base.lastPathComponent)")
    try fm.createDirectory(at: overlay.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    try runQemuImg(bundle.qemuImgBin,
                   args: ["create", "-f", "qcow2",
                          "-F", "qcow2",
                          "-b", base.path,
                          overlay.path])
}

/// Use `qemu-img info --output=json` to discover the current backing
/// file. Returns nil on any error — the caller then skips the rebase
/// short-circuit and proceeds as if the overlay were fresh.
///
/// Not `private` because `cmdPrune` also needs to walk overlays to
/// figure out which cached base images are still in use.
func queryBackingFile(_ overlay: URL, qemuImg: URL) -> String? {
    guard let info = queryQemuImgInfo(overlay, qemuImg: qemuImg) else { return nil }
    return info["backing-filename"] as? String ?? info["full-backing-filename"] as? String
}

/// Parsed `format` field from `qemu-img info`. Returns nil if qemu-img
/// can't open the file (bad path, unsupported format, permissions).
/// Callers should surface a good error message in that case.
private func queryDiskFormat(_ disk: URL, qemuImg: URL) -> String? {
    return queryQemuImgInfo(disk, qemuImg: qemuImg)?["format"] as? String
}

/// Shared `qemu-img info --output=json` runner.
private func queryQemuImgInfo(_ file: URL, qemuImg: URL) -> [String: Any]? {
    let task = Process()
    task.executableURL = qemuImg
    task.arguments = ["info", "--output=json", file.path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        return nil
    }
    task.waitUntilExit()
    if task.terminationStatus != 0 { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// Copy the bundled EFI vars template to the per-VM state dir on first
/// boot. Subsequent boots keep the existing mutable copy so UEFI boot
/// order + settings persist.
private func ensureEfiVars(_ varsFile: URL, template: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: varsFile.path) { return }
    try fm.createDirectory(at: varsFile.deletingLastPathComponent(),
                           withIntermediateDirectories: true)
    try fm.copyItem(at: template, to: varsFile)
    // The template is typically 0o444 out of share/qemu — make the copy
    // writable so qemu can mutate it on boot.
    try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: varsFile.path)
}

private func runQemuImg(_ qemuImg: URL, args: [String]) throws {
    let task = Process()
    task.executableURL = qemuImg
    task.arguments = args
    let err = Pipe()
    task.standardError = err
    task.standardOutput = Pipe()
    do { try task.run() }
    catch { throw LaunchError.qemuImgFailed(-1, error.localizedDescription) }
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        throw LaunchError.qemuImgFailed(task.terminationStatus, msg)
    }
}

// MARK: - Launch

func launchVM(base: URL, opts: Options) throws {
    let bundle = try discoverLauncherBundle()

    let overlay = resolvedOverlayURL(opts)
    let vars = efiVarsURL(for: opts.vmName)

    try ensureOverlay(overlay, base: base, bundle: bundle)
    try ensureEfiVars(vars, template: bundle.efiVarsFile)

    let extraDisks = try resolveExtraDisks(opts.extraDisks,
                                           qemuImg: bundle.qemuImgBin)
    for d in extraDisks {
        log("extra disk: \(d.path) (\(d.format)\(d.readOnly ? ", read-only" : ""))")
    }

    let passthrough = resolvePassthrough(opts)
    if opts.noPassthrough {
        log("passthrough: disabled via --no-passthrough")
    } else if passthrough.isEmpty {
        log("passthrough: no dext-bound display device found — booting without it")
    } else {
        log("passthrough: \(passthrough.count) function(s) on slot \(passthrough[0].slotString)")
        for c in passthrough {
            log("  function \(c.function): \(c.description)")
        }
    }

    let qemuArgv = buildQemuArgv(opts: opts,
                                 bundle: bundle,
                                 overlay: overlay,
                                 varsFile: vars,
                                 extraDisks: extraDisks,
                                 passthrough: passthrough)

    // If the user asked for --sudo, wrap the whole invocation in
    // `sudo -E -- <qemu> <args>`. -E preserves HOME so qemu's cocoa
    // display keeps using the user's CFPreferences instead of
    // /var/root's. We pass `--` so sudo stops parsing flags even if
    // any future qemu arg happens to start with `-`.
    let executable: URL
    let argv: [String]
    if opts.runAsRoot {
        executable = URL(fileURLWithPath: "/usr/bin/sudo")
        argv = ["-E", "--", bundle.qemuBinary.path] + qemuArgv
    } else {
        executable = bundle.qemuBinary
        argv = qemuArgv
    }

    if opts.dryRun {
        // Emit a copy-pasteable command line on stdout. Quote each arg
        // individually so spaces in paths survive; this matches what
        // the user would actually paste into a shell.
        print(shellQuote(executable.path) + " \\")
        for (i, a) in argv.enumerated() {
            let suffix = (i == argv.count - 1) ? "" : " \\"
            print("  \(shellQuote(a))\(suffix)")
        }
        return
    }

    if opts.runAsRoot {
        log("running qemu-system-aarch64 under sudo (may prompt for password)")
    } else {
        log("starting qemu-system-aarch64")
    }
    // exec() replaces this process so qemu inherits our controlling TTY
    // and foreground process group directly. Going through Process() /
    // posix_spawn puts qemu in a separate pgrp; when it then calls
    // tcsetattr() in stdio_chr_open the kernel sends SIGTTOU and the VM
    // hangs before boot. Same reasoning applies to sudo's password prompt
    // (it needs to own the TTY natively to read keystrokes).
    try execReplacingSelf(executable, argv: argv)
}

/// exec() the given binary, replacing this process. Only returns on
/// failure — on success our PID simply becomes the new binary. No
/// post-exec cleanup possible, which is fine here because we don't
/// have any state to clean up (overlay/EFI vars are already on disk).
private func execReplacingSelf(_ binary: URL, argv: [String]) throws {
    // execv wants [argv0, …rest, NULL]. By convention argv0 is the
    // program name but the kernel doesn't care — we use the full path
    // so `ps` shows something meaningful.
    var cArgs: [UnsafeMutablePointer<CChar>?] =
        ([binary.path] + argv).map { strdup($0) } + [nil]
    defer {
        for p in cArgs {
            if let p = p { free(p) }
        }
    }
    execv(binary.path, &cArgs)
    // Only reached if execv itself fails (permissions, ENOENT, …).
    let err = String(cString: strerror(errno))
    throw LaunchError.qemuLaunchFailed("execv \(binary.path): \(err)")
}

// MARK: - Extra disk resolution

/// Resolve user-supplied `--disk` specs against the filesystem +
/// qemu-img. Errors out early with a clear message instead of letting
/// qemu fail mid-boot.
private func resolveExtraDisks(_ disks: [ExtraDisk],
                               qemuImg: URL) throws -> [ResolvedDisk]
{
    if disks.isEmpty { return [] }
    let fm = FileManager.default
    var out: [ResolvedDisk] = []
    for d in disks {
        let expanded = (d.path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard fm.fileExists(atPath: url.path) else {
            throw LaunchError.extraDisk("--disk: file not found: \(url.path)")
        }
        guard let fmt = queryDiskFormat(url, qemuImg: qemuImg) else {
            throw LaunchError.extraDisk(
                "--disk: qemu-img could not probe \(url.path) " +
                "(unreadable, unsupported format, or corrupt)")
        }
        out.append(ResolvedDisk(path: url.path, format: fmt, readOnly: d.readOnly))
    }
    return out
}

// MARK: - Passthrough resolution

private func resolvePassthrough(_ opts: Options) -> [PassthroughCandidate] {
    if opts.noPassthrough { return [] }
    if let bdf = opts.passthroughBDF {
        // Two modes:
        //   --passthrough 03:00     (no function) → expand to all
        //                                            dext-bound siblings.
        //                                            Matches historical
        //                                            behaviour + what the
        //                                            auto-detect path does.
        //   --passthrough 03:00.0   (explicit fn) → pass that exact
        //                                            function only. Escape
        //                                            hatch when a sibling
        //                                            function makes qemu
        //                                            unhappy (e.g. GPU HDMI
        //                                            audio devices that
        //                                            trip pci_irq_handler
        //                                            assertions).
        guard let (bus, device, fn) = parseHostBDF(bdf) else {
            warn("could not parse --passthrough \(bdf); booting without it")
            return []
        }
        if let fn = fn {
            return findSingleFunction(bus: bus, device: device, function: fn, fallbackBDF: bdf)
        }
        return findSlotSiblings(bus: bus, device: device, fallbackBDF: bdf)
    }
    return autoDetectPassthroughSlot()
}

// MARK: - Qemu argv construction

private func buildQemuArgv(opts: Options,
                           bundle: LauncherBundle,
                           overlay: URL,
                           varsFile: URL,
                           extraDisks: [ResolvedDisk],
                           passthrough: [PassthroughCandidate]) -> [String]
{
    var a: [String] = []

    // Firmware data search path — we don't install qemu system-wide, so
    // without -L the binary can't find keymaps / descriptors / vgabios.
    a += ["-L", bundle.shareDir.path]

    // Machine + accelerator. The dext-based vfio-apple-pci path
    // handles guest DMA in-kernel via the apple-dma companion, so
    // we no longer need the memory-backend-ram + aux-ram-share
    // gymnastics that the old user-mode PCI device required.
    /*
     * tso=on enables Apple's total-store-ordering memory model on every
     * vCPU at vcpu-init time. This is what FEX-Emu and other x86 user-
     * mode emulators want, and doing it from the host *before* the guest
     * runs avoids the late-boot paging faults we used to see when the
     * in-guest module flipped ACTLR_EL1.EnTSO mid-flight.
     */
    a += ["-accel", "hvf,tso=on"]
    a += ["-cpu", "host"]
    a += ["-smp", "\(opts.cpus),sockets=1,cores=\(opts.cpus),threads=1"]
    // preallocate all guest memory, for performance
    a += ["-object",
          "memory-backend-ram,id=pc.ram,size=\(opts.memory),prealloc=on,share=off"]
    a += ["-machine", "virt,highmem=on,memory-backend=pc.ram"]
    a += ["-m", opts.memory]

    // UEFI firmware.
    a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(bundle.efiCodeFile.path)"]
    a += ["-drive", "if=pflash,format=raw,file=\(varsFile.path)"]

    // Disk (overlay backed by cached base).
    a += ["-drive", "if=none,id=hd0,file=\(overlay.path),format=qcow2,discard=unmap,detect-zeroes=unmap"]
    a += ["-device", "virtio-blk-pci,drive=hd0"]

    // Extra user-supplied disks. Each one gets its own `hdN` drive id
    // (starting at hd1) and its own virtio-blk-pci front-end. We
    // deliberately leave `addr=` unset so qemu auto-assigns guest PCI
    // slots — passthrough reserves slot 0x6 explicitly; auto-assigned
    // virtio devices start elsewhere so there's no collision.
    //
    // discard/detect-zeroes match the primary overlay so trim / zero-
    // punch behaviour is consistent across drives. For raw files this
    // is only meaningful on a file-system that supports it (APFS does),
    // but setting it is harmless otherwise.
    for (idx, d) in extraDisks.enumerated() {
        let id = "hd\(idx + 1)"
        var drive = "if=none,id=\(id),file=\(d.path),format=\(d.format)," +
                    "discard=unmap,detect-zeroes=unmap"
        if d.readOnly { drive += ",readonly=on" }
        a += ["-drive", drive]
        a += ["-device", "virtio-blk-pci,drive=\(id)"]
    }

    // Network: user mode with SSH hostfwd so the user can always reach
    // the guest at 127.0.0.1:<ssh-port>. No root / vmnet entitlement
    // needed. vmnet-shared can be added later via a flag.
    a += ["-netdev", "user,id=net0,hostfwd=tcp::\(opts.sshPort)-:22"]
    a += ["-device", "virtio-net-pci,netdev=net0"]

    // RNG — GNOME login really doesn't like a starved entropy pool.
    a += ["-device", "virtio-rng-pci"]

    // Input + display.
    a += ["-device", "qemu-xhci,id=xhci"]
    a += ["-device", "usb-kbd,bus=xhci.0"]
    a += ["-device", "usb-tablet,bus=xhci.0"]
    if opts.headless {
        a += ["-display", "none", "-nographic", "-serial", "mon:stdio"]
    } else {
        a += ["-device", "virtio-gpu-pci"]
        a += ["-display", "cocoa"]
    }

    // Passthrough. For multi-function devices (NVIDIA eGPUs present
    // the video controller on fn 0 and an HDMI/DisplayPort audio
    // controller on fn 1) we have to bundle every sibling function
    // into a single guest slot with multifunction=on, otherwise
    // lspci inside the guest only sees function 0 and the audio
    // path stays dead.
    //
    // Each function needs its own dma-companion: apple-device.c
    // matches the companion to the vfio-apple-pci device by
    // (host-bus, host-device, host-function), so a companion auto-
    // created for fn 0 doesn't cover fn 1. Setting dma-companion=on
    // on every function is safe — the second realize just skips
    // creation when its own match is found.
    //
    // Slot 0x1e is chosen to sit *above* qemu's auto-assigned slot
    // range. Auto-assignment on arm64 virt's pcie.0 fills from slot
    // 1 upward as we add virtio devices (hd0, each --disk, net, rng,
    // xhci, virtio-gpu), so pinning to a low number like 0x6 races
    // with them — add one extra --disk and the virtio-gpu lands on
    // slot 6 before vfio-apple-pci can claim it. 0x1e leaves room
    // for ~29 auto-assigned devices, which no realistic config will
    // hit. The guest BDF here is cosmetic — the dext matches host
    // BDFs only and the guest's apple-dma driver uses whatever BDF
    // qemu publishes via the MANAGED_BDF register.
    if !passthrough.isEmpty {
        let guestSlot = 0x1e
        let fn0 = passthrough[0].function
        for c in passthrough {
            let guestFn = Int(c.function) - Int(fn0)
            var props: [String] = [
                "vfio-apple-pci",
                "host=\(c.hostBDF)",
                // qemu's PCI addr= accepts "slot" or "slot.function"; we
                // always emit the long form so multi-function guests
                // get distinct guest BDFs.
                String(format: "addr=0x%x.%x", guestSlot, guestFn),
                "dma-companion=on",
                // The apple-vfio backend reports ROM region size = 0
                // (apple-device.c, VFIO_PCI_ROM_REGION_INDEX) because the
                // DriverKit dext doesn't expose the option ROM. Without
                // rombar=0, vfio_pci_load_rom() prints "Cannot read device
                // rom" the first time the guest (or UEFI during boot)
                // touches the ROM BAR. The ROM is x86 code anyway and the
                // aarch64 guest can't execute it, so skip the probe.
                "rombar=0",
            ]
            // multifunction=on only needs to be set on function 0 of
            // the guest slot — qemu propagates the bit to the whole
            // slot. Setting it on other functions is harmless but
            // produces redundant "multifunction=on already set" noise.
            if passthrough.count > 1 && c.function == fn0 {
                props.append("multifunction=on")
            }
            a += ["-device", props.joined(separator: ",")]
        }
    }

    // Verbatim tail from `-- <extra qemu args>`. Appended last so users
    // can override earlier arguments (qemu's later flags win for most
    // options) without us having to understand what they mean.
    a += opts.extraQemuArgs

    return a
}

private func shellQuote(_ s: String) -> String {
    if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=".contains($0) }) {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

