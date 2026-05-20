// qemu-vfio-apple — unified CLI for the apple-vfio host app. Handles:
//
//   - downloading + booting prebaked Ubuntu images from GHCR (run / pull
//     / reset / prune / images)
//   - reporting on the DriverKit extension that backs passthrough
//     (driver-status)
//   - enumerating host PCI devices so the user can see what's bound to
//     the dext and what isn't (list-devices)
//
// Lives next to qemu-system-aarch64 inside VFIOUserHostApp.app and is
// surfaced to the user via a wrapper at ~/.local/bin/qemu-vfio-apple.
//
// For the VM side: pulls a prebaked qcow2 image from a GHCR OCI artifact
// (resumable, sha256-verified, content-addressed on disk) and boots a
// QEMU aarch64 VM against it, auto-detecting any dext-bound PCI display
// device for passthrough.
//
// Install / uninstall of the DriverKit extension is *not* handled here
// — submitting an OSSystemExtensionRequest needs the developer-restricted
// `com.apple.developer.system-extension.install` entitlement, and AMFI
// requires a per-binary embedded provisioning profile to authorize it.
// Mac CLI tool targets in Xcode don't get such a profile (only `.app`
// bundles do), so install/uninstall is driven from VFIOUserHostApp's
// setup checklist and this CLI only reports status.
//
// Commands:
//
//   run             download-if-needed + boot (default)
//   pull            download + verify, do not boot
//   reset           delete the writable overlay; keep cached base
//   prune           delete cached base images
//   images          list cached images and overlays
//   driver-status   report DriverKit extension state
//   list-devices    list PCI endpoints with current driver bindings
//   help            show usage
//   version         print version
//
// Flags (see `printUsage` for the full table).

import Foundation

// MARK: - Constants

let kVersion         = "1.0"
let kDefaultImageRef = "ghcr.io/scottjg/qemu-vfio-apple-images:latest"
let kDefaultCpus     = 8
let kDefaultMemory   = "14G"
let kDefaultSshPort  = 2222

// MARK: - Args

/// Result of parsing argv after the subcommand has been consumed.
struct Options {
    var imageRef:       String   = kDefaultImageRef
    var basePath:       String?  = nil    // local qcow2, skip download
    var overlayPath:    String?  = nil
    var cpus:           Int      = kDefaultCpus
    var memory:         String   = kDefaultMemory
    var headless:       Bool     = false
    var sshPort:        Int      = kDefaultSshPort
    var passthroughBDF: String?  = nil    // explicit override
    var noPassthrough:  Bool     = false  // force off, skip auto-detect
    var dryRun:         Bool     = false

    /// Run qemu-system-aarch64 under `sudo`. The only reason to do this
    /// today is USB passthrough of devices macOS has already bound to a
    /// driver (HID, IOUSBHost, IOStorage, …): qemu's usb-host backend
    /// asks IOKit to detach the device, which requires either the
    /// com.apple.vm.device-access entitlement (AMFI-gated, won't
    /// authorize self-signed builds) or root. We pick root.
    var runAsRoot:      Bool     = false

    /// Additional disks (beyond the overlay) to attach as virtio-blk-pci.
    /// Populated from repeated `--disk PATH[:ro]`. Format is auto-detected
    /// by qemu-img; we wire them up with the same discard/detect-zeroes
    /// flags as the primary overlay so trim / zero-punch behaviour is
    /// consistent inside the guest.
    var extraDisks:     [ExtraDisk] = []

    /// Verbatim tail appended to the qemu argv. Populated from everything
    /// after `--` on the command line. Escape hatch for one-off qemu
    /// features we haven't grown a flag for (e.g. -fw_cfg, -serial, extra
    /// -netdev, additional -device lines). We don't validate these — if
    /// they're wrong, qemu's error will tell the user.
    var extraQemuArgs:  [String]  = []

    /// Name used for the per-VM state directory (overlay, EFI vars). By
    /// default we derive it from the image reference's tag so distinct
    /// images get distinct overlays; users can override with --overlay.
    var vmName:         String   = ""
}

/// Parsed `--disk PATH[:ro]`. The format field is left nil here and
/// resolved in VMLauncher against qemu-img so parsing doesn't have to
/// run subprocesses.
struct ExtraDisk {
    var path:     String
    var readOnly: Bool
}

/// Minimal argv splitter. Accepts both `--flag value` and `--flag=value`.
/// Short forms are not supported — subcommands are rare and the launcher
/// is scripted more often than typed.
func parseOptions(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        i += 1

        // `--` terminates flag parsing. Everything after it is passed
        // through to qemu verbatim. This is the escape hatch for qemu
        // features we don't have a flag for.
        if arg == "--" {
            if i < argv.count {
                opts.extraQemuArgs = Array(argv[i...])
            }
            break
        }

        func value(for flag: String) -> String {
            if arg.contains("=") {
                return String(arg.split(separator: "=", maxSplits: 1)[1])
            }
            if i < argv.count {
                let v = argv[i]
                i += 1
                return v
            }
            die("flag \(flag) requires a value")
        }

        let key: String
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
            key = String(arg[..<eq])
        } else {
            key = arg
        }

        switch key {
        case "--image":          opts.imageRef = value(for: key)
        case "--base":           opts.basePath = value(for: key)
        case "--overlay":        opts.overlayPath = value(for: key)
        case "--cpus":
            let v = value(for: key)
            guard let n = Int(v), n > 0 else { die("--cpus must be a positive integer (got \(v))") }
            opts.cpus = n
        case "--memory":         opts.memory = value(for: key)
        case "--headless":       opts.headless = true
        case "--ssh-port":
            let v = value(for: key)
            guard let n = Int(v), n > 0, n < 65536 else { die("--ssh-port out of range (got \(v))") }
            opts.sshPort = n
        case "--passthrough":
            let v = value(for: key)
            if v.lowercased() == "none" {
                opts.noPassthrough = true
            } else {
                opts.passthroughBDF = v
            }
        case "--no-passthrough": opts.noPassthrough = true
        case "--disk":
            opts.extraDisks.append(parseExtraDisk(value(for: key)))
        case "--sudo", "--root": opts.runAsRoot = true
        case "--dry-run":        opts.dryRun = true
        default:
            die("unknown flag: \(arg) (try `qemu-vfio-apple help`)")
        }
    }

    if let base = opts.basePath {
        opts.vmName = deriveVMName(fromLocalPath: base)
    } else {
        opts.vmName = deriveVMName(from: opts.imageRef)
    }
    return opts
}

/// Turn `ghcr.io/scottjg/qemu-vfio-apple-images:latest` into `qemu-vfio-apple-images`.
/// The tag is used only for the cache key; the VM state dir is keyed by
/// the repo's last path component so that switching tags (`:latest` →
/// `:ubuntu-..-arm64`) reuses the same overlay by default. Users can
/// override with --overlay if they want isolated state per tag.
func deriveVMName(from ref: String) -> String {
    var s = ref
    if let at = s.range(of: "@") {        // strip ...@sha256:...
        s = String(s[..<at.lowerBound])
    }
    if let colon = s.range(of: ":", options: .backwards) {
        s = String(s[..<colon.lowerBound])
    }
    return (s as NSString).lastPathComponent
}

/// When booting a local qcow2 via --base, key the VM state off the
/// file's basename (sans extension). Keeps overlays separate from the
/// normal GHCR-pulled image overlays so local testing doesn't stomp on
/// the cached production state.
func deriveVMName(fromLocalPath path: String) -> String {
    let last = (path as NSString).lastPathComponent
    let stem = (last as NSString).deletingPathExtension
    let base = stem.isEmpty ? last : stem
    return "local-\(base)"
}

/// Parse `--disk PATH[:ro]`. Only `:ro` is recognized as a modifier; any
/// other trailing `:word` is treated as part of the path (macOS paths
/// with colons are rare but legal, so the check is intentionally strict
/// rather than "split on last colon unconditionally").
///
/// Format (qcow2 vs raw vs …) is auto-detected later via qemu-img, so
/// we don't need a `:fmt=` knob here.
private func parseExtraDisk(_ spec: String) -> ExtraDisk {
    if spec.hasSuffix(":ro") {
        let path = String(spec.dropLast(3))
        if path.isEmpty { die("--disk: empty path before ':ro'") }
        return ExtraDisk(path: path, readOnly: true)
    }
    if spec.isEmpty { die("--disk: empty path") }
    return ExtraDisk(path: spec, readOnly: false)
}

// MARK: - Entry point

let argv = CommandLine.arguments
let cmd  = argv.count >= 2 ? argv[1] : "run"
let rest = argv.count >= 3 ? Array(argv.dropFirst(2)) : []

switch cmd {
case "run":                   exit(cmdRun(parseOptions(rest)))
case "pull":                  exit(cmdPull(parseOptions(rest)))
case "reset":                 exit(cmdReset(parseOptions(rest)))
case "prune":                 exit(cmdPrune(parseOptions(rest)))
case "images":                exit(cmdImages(parseOptions(rest)))
case "driver-status":         exit(cmdDriverStatus())
case "list-devices", "ls":    exit(cmdListDevices())
case "help", "--help", "-h":
    printUsage()
    exit(0)
case "version", "--version", "-v":
    print("qemu-vfio-apple \(kVersion)")
    exit(0)
default:
    // If the first arg looks like a flag, assume the user meant `run` and
    // re-parse. Keeps `qemu-vfio-apple --headless` working the way people
    // actually type it.
    if cmd.hasPrefix("--") {
        exit(cmdRun(parseOptions(Array(argv.dropFirst()))))
    }
    fputs("qemu-vfio-apple: unknown command '\(cmd)'\n\n", stderr)
    printUsage()
    exit(2)
}

// MARK: - Usage

func printUsage() {
    print("""
        usage: qemu-vfio-apple <command> [flags]

        commands:
          run             (default) download image if needed and boot the VM
          pull            download + verify, do not boot
          reset           delete the writable overlay; keep cached base image
          prune           delete cached base images we can prove aren't in
                          use (keeps whatever --image resolves to right now,
                          plus any image backing an existing overlay)
          images          list cached images and overlays
          driver-status   report DriverKit extension state (is the VFIO
                          driver activated, waiting for user approval, …?)
          list-devices    list host PCI endpoints with their current driver
                          bindings, marking those bound to the VFIO driver
          help            show this message
          version         print version

        flags (run / pull / reset):
          --image REPO:TAG        OCI image to pull
                                  (default: \(kDefaultImageRef))
          --base PATH             use a local qcow2 as the base image and
                                  skip the download entirely. Handy when
                                  testing a locally-sealed image before
                                  pushing to GHCR. Per-VM state for a
                                  local base is keyed under vms/local-<stem>/
                                  so it won't collide with the cached
                                  --image overlays.
          --overlay PATH          writable qcow2 overlay path
                                  (default: ~/Library/Application Support/
                                            scottjg.VFIOUserHostApp.qemu-vfio-apple/vms/<name>/overlay.qcow2)
          --cpus N                vCPUs (default: \(kDefaultCpus))
          --memory SIZE           RAM, qemu syntax (default: \(kDefaultMemory))
          --headless              -display none -nographic
          --ssh-port PORT         hostfwd tcp host:PORT → guest:22
                                  (default: \(kDefaultSshPort))
          --passthrough BDF|none  passthrough a PCI device. BDF can be either
                                  'BB:DD'   (slot only) — bundle every dext-
                                            bound function of the slot (e.g.
                                            the GPU + its HDMI audio).
                                  'BB:DD.F' (explicit function) — pass only
                                            that single function, dropping any
                                            siblings. Use this when an
                                            additional sibling device (often
                                            a GPU's HDMI audio controller)
                                            makes qemu unhappy.
                                  'none'    disable passthrough entirely.
                                  Default: auto-detect the first dext-bound
                                  display controller slot.
          --no-passthrough        alias for --passthrough none
          --disk PATH[:ro]        attach an additional disk as a
                                  virtio-blk-pci device. Format is
                                  auto-detected by qemu-img. Append ':ro'
                                  to mount it read-only. Repeatable.
          --sudo                  run qemu-system-aarch64 under sudo so
                                  it can detach USB devices from macOS
                                  drivers (required for -device usb-host
                                  to grab anything macOS has already
                                  claimed — which is most devices).
                                  Triggers a password prompt on first
                                  boot; sudo caches for ~5 min. Files
                                  qemu touches (overlay, EFI vars) stay
                                  owned by you — Unix writes don't
                                  change ownership.
          --dry-run               print the qemu command line and exit

        extra qemu arguments:
          Anything after a literal `--` is appended verbatim to the
          qemu command line. Escape hatch for qemu features we don't
          have a flag for (e.g. -fw_cfg, -serial, extra -netdev).

        examples:
          qemu-vfio-apple
          qemu-vfio-apple --headless --ssh-port 2200
          qemu-vfio-apple --disk ~/games.qcow2 --disk ~/data.img:ro
          qemu-vfio-apple --sudo -- -device usb-host,vendorid=0x046d,productid=0xc52b,bus=xhci.0
          qemu-vfio-apple pull --image ghcr.io/scottjg/qemu-vfio-apple-images:ubuntu-desktop-resolute-arm64
          qemu-vfio-apple --base ./out/ubuntu-desktop-image/artifacts/ubuntu-desktop-resolute-arm64.qcow2
          qemu-vfio-apple run -- -serial file:/tmp/console.log
          qemu-vfio-apple reset
          qemu-vfio-apple driver-status
          qemu-vfio-apple list-devices
        """)
}

// MARK: - Shared error helpers

func die(_ msg: String) -> Never {
    fputs("qemu-vfio-apple: \(msg)\n", stderr)
    exit(1)
}

func warn(_ msg: String) {
    fputs("qemu-vfio-apple: \(msg)\n", stderr)
}

func log(_ msg: String) {
    // stderr so it doesn't pollute --dry-run's argv output on stdout.
    fputs("\(msg)\n", stderr)
}

// MARK: - Command implementations

func cmdRun(_ opts: Options) -> Int32 {
    let base: URL
    if let local = opts.basePath {
        let url = URL(fileURLWithPath: local).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            warn("--base path does not exist: \(url.path)")
            return 1
        }
        log("using local base image \(url.path)")
        base = url
    } else {
        let cache = ensureCacheLayout()
        do {
            base = try downloadImageIfNeeded(ref: opts.imageRef, cache: cache)
        } catch {
            warn("download failed: \(error.localizedDescription)")
            return 1
        }
    }

    do {
        try launchVM(base: base, opts: opts)
        return 0
    } catch {
        warn("launch failed: \(error.localizedDescription)")
        return 1
    }
}

func cmdPull(_ opts: Options) -> Int32 {
    if opts.basePath != nil {
        warn("--base is incompatible with `pull` (nothing to pull)")
        return 2
    }
    let cache = ensureCacheLayout()
    do {
        let path = try downloadImageIfNeeded(ref: opts.imageRef, cache: cache)
        print(path.path)
        return 0
    } catch {
        warn("download failed: \(error.localizedDescription)")
        return 1
    }
}

func cmdReset(_ opts: Options) -> Int32 {
    let overlay = resolvedOverlayURL(opts)
    let efiVars = efiVarsURL(for: opts.vmName)
    let fm = FileManager.default
    var removed = false
    for url in [overlay, efiVars] {
        if fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
                log("removed \(url.path)")
                removed = true
            } catch {
                warn("failed to remove \(url.path): \(error.localizedDescription)")
            }
        }
    }
    if !removed {
        log("nothing to remove under \(overlay.deletingLastPathComponent().path)")
    }
    return 0
}

func cmdPrune(_ opts: Options) -> Int32 {
    let cache = ensureCacheLayout()
    let fm = FileManager.default

    guard let imageEntries = try? fm.contentsOfDirectory(at: cache.imagesDir,
                                                         includingPropertiesForKeys: [.fileSizeKey],
                                                         options: [.skipsHiddenFiles])
    else {
        log("no cache dir at \(cache.imagesDir.path)")
        return 0
    }

    // Build the keep-set: by default, whatever `--image` resolves to
    // right now (so the next `qemu-vfio-apple` is still a cache hit)
    // plus every cached file that an existing overlay is backed by
    // (deleting one of those would leave an unbootable overlay).
    //
    // Both lookups are best-effort — if we're offline and can't
    // resolve the tag we still prune everything we can prove is
    // unused; if we can't locate qemu-img we still prune everything
    // except the resolved tag. We never delete blindly.
    var keepNames = Set<String>()
    var keepReasons: [String: [String]] = [:]
    func markKeep(_ name: String, reason: String) {
        keepNames.insert(name)
        keepReasons[name, default: []].append(reason)
    }

    if opts.basePath != nil {
        // --base means "I'm testing a local qcow2"; it has nothing
        // to do with the download cache. We still run the normal
        // keep logic below so a passing --base doesn't blow away
        // the tag / overlays.
        log("--base is ignored by prune (prune only touches the download cache)")
    }

    // 1. Keep whatever `--image` resolves to.
    do {
        let ref = try ImageRef.parse(opts.imageRef)
        let token = try getAnonymousToken(for: ref)
        let (digest, _) = try fetchLayerDigest(ref: ref, token: token)
        let digestHex = try hexOfSha256Digest(digest)
        let url = cachedImageURL(for: digestHex)
        markKeep(url.lastPathComponent, reason: opts.imageRef)
    } catch {
        warn("could not resolve \(opts.imageRef): \(error.localizedDescription)")
        warn("  (prune will not protect any tag on this run)")
    }

    // 2. Keep anything that any existing overlay is currently backed by.
    //    We need qemu-img to read the backing-file field; if the bundle
    //    can't be located (very unlikely when running from the installed
    //    app) we conservatively skip — that's the same behaviour as
    //    `ls` not finding the binary.
    let bundle: LauncherBundle?
    do { bundle = try discoverLauncherBundle() }
    catch {
        bundle = nil
        warn("cannot locate qemu-img (\(error.localizedDescription))")
        warn("  overlay-backing check will be skipped; overlays may be orphaned")
    }

    if let bundle,
       let vmEntries = try? fm.contentsOfDirectory(at: cache.vmsDir,
                                                   includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])
    {
        for vmDir in vmEntries {
            let overlay = vmDir.appendingPathComponent("overlay.qcow2")
            guard fm.fileExists(atPath: overlay.path) else { continue }
            guard let backing = queryBackingFile(overlay, qemuImg: bundle.qemuImgBin) else {
                warn("could not read backing file of \(vmDir.lastPathComponent)/overlay.qcow2; keeping conservatively")
                // Can't identify the file, so keep everything to be safe.
                // Mark a sentinel that disables pruning this run.
                return pruneAbortSafety(vmDir: vmDir)
            }
            let name = (backing as NSString).lastPathComponent
            markKeep(name, reason: "overlay \(vmDir.lastPathComponent)/overlay.qcow2")
        }
    }

    var freedBytes: Int = 0
    var keptBytes:  Int = 0
    for url in imageEntries {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if keepNames.contains(url.lastPathComponent) {
            keptBytes += size
            let why = keepReasons[url.lastPathComponent]?.joined(separator: ", ") ?? "keep"
            log("keeping \(url.lastPathComponent) (\(formatBytes(size))) — \(why)")
            continue
        }
        do {
            try fm.removeItem(at: url)
            log("removed \(url.lastPathComponent) (\(formatBytes(size)))")
            freedBytes += size
        } catch {
            warn("failed to remove \(url.path): \(error.localizedDescription)")
        }
    }
    if keptBytes > 0 {
        log("freed \(formatBytes(freedBytes)); kept \(formatBytes(keptBytes))")
    } else {
        log("freed \(formatBytes(freedBytes))")
    }
    return 0
}

/// Refuse to prune when we can't tell what an overlay points at — a
/// user with an active overlay would otherwise lose the base out from
/// under them and find out at next boot.
private func pruneAbortSafety(vmDir: URL) -> Int32 {
    warn("aborting prune — couldn't determine the backing file for")
    warn("  \(vmDir.path)/overlay.qcow2")
    warn("run `qemu-vfio-apple reset` on that VM or remove the overlay")
    warn("manually, then re-run prune.")
    return 1
}

func cmdImages(_ opts: Options) -> Int32 {
    _ = opts
    let cache = ensureCacheLayout()
    let fm = FileManager.default

    print("cached images (\(cache.imagesDir.path)):")
    if let entries = try? fm.contentsOfDirectory(at: cache.imagesDir,
                                                 includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles]),
       !entries.isEmpty
    {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        // Split sidecars (`*.qcow2.bad-<ts>`, written by
        // quarantineCorruptCachedImage when the size check tripped) into
        // their own section so users notice them — they'll otherwise sit
        // around silently until the next prune.
        let sorted = entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        let live = sorted.filter { !$0.lastPathComponent.contains(".qcow2.bad-") }
        let bad  = sorted.filter {  $0.lastPathComponent.contains(".qcow2.bad-") }
        for url in live {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = vals?.fileSize ?? 0
            let mtime = vals?.contentModificationDate.map(df.string(from:)) ?? "?"
            print("  \(url.lastPathComponent)  \(formatBytes(size))  \(mtime)")
        }
        if !bad.isEmpty {
            print("")
            print("quarantined (size mismatch; safe to delete or `prune`):")
            for url in bad {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = vals?.fileSize ?? 0
                let mtime = vals?.contentModificationDate.map(df.string(from:)) ?? "?"
                print("  \(url.lastPathComponent)  \(formatBytes(size))  \(mtime)")
            }
        }
    } else {
        print("  (empty)")
    }

    print("")
    print("VM state dirs (\(cache.vmsDir.path)):")
    if let entries = try? fm.contentsOfDirectory(at: cache.vmsDir,
                                                 includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]),
       !entries.isEmpty
    {
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            print("  \(url.lastPathComponent)/")
            let overlay = url.appendingPathComponent("overlay.qcow2")
            if fm.fileExists(atPath: overlay.path) {
                let size = (try? overlay.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print("    overlay.qcow2          \(formatBytes(size))")
            }
            let efi = url.appendingPathComponent("edk2-aarch64-vars.fd")
            if fm.fileExists(atPath: efi.path) {
                let size = (try? efi.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                print("    edk2-aarch64-vars.fd   \(formatBytes(size))")
            }
        }
    } else {
        print("  (empty)")
    }
    return 0
}

// MARK: - Formatting

func formatBytes(_ n: Int) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(n)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 { return "\(n) B" }
    return String(format: "%.1f %@", value, units[unit])
}
