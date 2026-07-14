// VMManager.swift — lifecycle state machine for the managed headless
// Docker VM.
//
// Model: QEMU runs as a child Process of the menubar app (Docker
// Desktop style). Serial console goes to console.log in the per-VM
// state dir, qemu's own stdout/stderr to qemu.log, and control happens
// over a QMP unix socket. The socket lives under /tmp/qva-<name>/
// because macOS caps sun_path at 104 bytes and the Application Support
// state dir path is longer than that.
//
// Flow for `start()`:
//   1. reattach check — a previous app instance may have left qemu
//      running; if the pidfile is alive and QMP answers, adopt it.
//   2. resolve the base image: local override, or shell the bundled
//      `qemu-vfio-apple pull` (resumable, sha256-verified, prints the
//      cached path on stdout).
//   3. ensure the writable overlay + per-VM EFI vars (same semantics
//      as the CLI's VMLauncher, reimplemented here against the bundled
//      qemu-img).
//   4. spawn qemu headless with loopback-only hostfwd for ssh + the
//      Docker API, connect QMP, and wait for `GET /_ping` to answer.
//   5. flip to .running and start the PortWatcher that mirrors
//      published container ports onto Mac loopback.
//
// `stop()` sends QMP system_powerdown and escalates SIGTERM → SIGKILL
// on timeout. App quit routes through the same path (see AppDelegate).

import AppKit
import Combine
import Foundation

// MARK: - Model types

enum VMState: Equatable {
    case stopped
    case pulling(String)    // downloading the base image (detail line)
    case starting(String)   // booting (phase description)
    case running
    case stopping
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .pulling, .starting, .stopping: return true
        default:                             return false
        }
    }
}

struct ForwardedPort: Identifiable, Equatable, Sendable {
    let proto: String       // "tcp" | "udp"
    let port: Int
    let container: String

    var id: String { "\(proto):\(port)" }
    var label: String { "127.0.0.1:\(port) (\(proto)) — \(container)" }
}

/// One row of `docker ps`, fetched from the guest's Docker API on the
/// forwarded loopback port. Only running (and paused) containers are
/// listed — the menu is a control surface, not a full docker UI.
struct DockerContainer: Identifiable, Equatable, Sendable {
    let id: String          // full 64-char id
    let name: String
    let image: String
    let state: String       // "running" | "paused" | …
    let status: String      // "Up 2 hours (Paused)"

    var shortID: String { String(id.prefix(12)) }
    var isPaused: Bool { state == "paused" }
}

enum ContainerAction: String, Sendable {
    case stop, restart, pause, unpause

    /// Docker API endpoint path (relative to /containers/{id}/).
    var apiPath: String {
        switch self {
        // Bounded stop so a wedged entrypoint can't hang the menu action;
        // docker falls back to SIGKILL after the timeout.
        case .stop:    return "stop?t=10"
        case .restart: return "restart?t=10"
        case .pause:   return "pause"
        case .unpause: return "unpause"
        }
    }
}

/// One in-guest stats sample, collected through the QEMU guest agent.
/// GPU numbers come from amdgpu sysfs or nvidia-smi inside the guest —
/// with passthrough the host has no visibility into the card.
struct GuestStats: Equatable, Sendable {
    struct GPU: Equatable, Sendable, Identifiable {
        let id: String          // "card0" / nvidia index
        let busyPercent: Int?
        let vramUsedBytes: Int64?
        let vramTotalBytes: Int64?

        var label: String {
            var parts: [String] = []
            if let busy = busyPercent { parts.append("\(busy)%") }
            if let used = vramUsedBytes, let total = vramTotalBytes {
                parts.append("VRAM \(Self.gb(used))/\(Self.gb(total)) GB")
            }
            return parts.isEmpty ? "no data" : parts.joined(separator: " · ")
        }

        static func gb(_ bytes: Int64) -> String {
            String(format: "%.1f", Double(bytes) / 1_073_741_824)
        }
    }

    let gpus: [GPU]
    let load1: Double?
    let memUsedBytes: Int64?
    let memTotalBytes: Int64?

    var systemLabel: String {
        var parts: [String] = []
        if let load = load1 { parts.append(String(format: "Load %.2f", load)) }
        if let used = memUsedBytes, let total = memTotalBytes {
            parts.append("Mem \(GPU.gb(used))/\(GPU.gb(total)) GB")
        }
        return parts.isEmpty ? "no data" : parts.joined(separator: " · ")
    }
}

enum VMError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

// MARK: - Bundled tool discovery

/// Locations of the qemu tools embedded in this .app by embed-qemu.sh
/// and the Embed CLI Tools build phase.
struct AppBundleTools {
    let qemu:            URL
    let qemuImg:         URL
    let cli:             URL   // qemu-vfio-apple (used for `pull`)
    let shareDir:        URL
    let efiCode:         URL
    let efiVarsTemplate: URL

    static func locate() throws -> AppBundleTools {
        let fm = FileManager.default
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let share = contents.appendingPathComponent("Resources/share/qemu")

        let qemu    = macos.appendingPathComponent("qemu-system-aarch64")
        let qemuImg = macos.appendingPathComponent("qemu-img")
        let cli     = macos.appendingPathComponent("qemu-vfio-apple")
        let efiCode = share.appendingPathComponent("edk2-aarch64-code.fd")
        let efiVars = [share.appendingPathComponent("edk2-arm-vars.fd"),
                       share.appendingPathComponent("edk2-aarch64-vars.fd")]
            .first { fm.fileExists(atPath: $0.path) }

        var missing: [String] = []
        if !fm.isExecutableFile(atPath: qemu.path)    { missing.append(qemu.lastPathComponent) }
        if !fm.isExecutableFile(atPath: qemuImg.path) { missing.append(qemuImg.lastPathComponent) }
        if !fm.isExecutableFile(atPath: cli.path)     { missing.append(cli.lastPathComponent) }
        if !fm.fileExists(atPath: efiCode.path)       { missing.append(efiCode.lastPathComponent) }
        if efiVars == nil                             { missing.append("edk2-arm-vars.fd") }
        guard missing.isEmpty, let efiVars else {
            throw VMError.message(
                "This build of the app has no bundled QEMU (missing: " +
                "\(missing.joined(separator: ", "))). Rebuild with a dist/ present.")
        }
        return AppBundleTools(qemu: qemu, qemuImg: qemuImg, cli: cli,
                              shareDir: share, efiCode: efiCode,
                              efiVarsTemplate: efiVars)
    }
}

// MARK: - VMManager

@MainActor
final class VMManager: ObservableObject {
    static let shared = VMManager()

    @Published private(set) var state: VMState = .stopped
    @Published private(set) var forwardedPorts: [ForwardedPort] = []
    @Published private(set) var portNotes: [String] = []

    /// Human-readable descriptions of the dext-bound slots the next
    /// boot would pass through, one entry per physical slot (empty when
    /// nothing is bound). Kept fresh by the DextDeviceWatcher, so eGPU
    /// hot-plug updates the menu live.
    @Published private(set) var detectedGPUs: [String] = []

    /// How many passthrough devices the currently running VM was booted
    /// with. nil when unknown (reattached to a pre-existing qemu) or
    /// when no VM is running. Drives the "restart to attach GPU" hint.
    @Published private(set) var bootedGPUCount: Int?

    /// Live guest stats (GPU busy %, VRAM, load, memory), polled via the
    /// QEMU guest agent only while the menubar menu is open. nil when
    /// the VM isn't running or the agent doesn't answer (e.g. a VM that
    /// predates the QGA channel, or early in boot).
    @Published private(set) var guestStats: GuestStats?

    /// Rolling GPU busy % history per GPU id (0–100), one entry per
    /// stats poll, newest last. Drives the sparkline in the menu.
    /// Capped at `gpuHistoryLimit` samples (~1 min at the 2 s poll
    /// interval).
    @Published private(set) var gpuHistory: [String: [Double]] = [:]

    /// Running containers, refreshed on the same menu-open poll cadence
    /// as the guest stats.
    @Published private(set) var containers: [DockerContainer] = []

    /// Fixed VM name → state dir `vms/docker/`. Deliberately distinct
    /// from the CLI's image-derived names so this VM's overlay never
    /// collides with a CLI-managed desktop VM.
    let vmName = "docker"

    private let settings = VMSettings.shared

    private var process: Process?               // child-spawn case
    private var attachedPid: pid_t?             // reattach case
    private var pidExitSource: DispatchSourceProcess?
    private var qmp: QMPClient?
    private var portWatcher: PortWatcher?
    private var deviceWatcher: DextDeviceWatcher?
    private var bootstrapped = false
    private var guestAgent: GuestAgentClient?
    private var statsTask: Task<Void, Never>?
    private var statsMenuOpenCount = 0
    private let gpuHistoryLimit = 30

    var dockerHost: String { "tcp://127.0.0.1:\(settings.dockerPort)" }

    // MARK: Paths

    /// `~/Library/Application Support/<host-app-id>.qemu-vfio-apple/vms/docker/`
    /// — same root as the CLI (Cache.swift) so `qemu-vfio-apple images`
    /// sees this VM too.
    var stateDir: URL {
        let dirName = (Bundle.main.bundleIdentifier ?? "VFIOUserHostApp") + ".qemu-vfio-apple"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(dirName)
            .appendingPathComponent("vms")
            .appendingPathComponent(vmName)
    }

    var consoleLogURL: URL { stateDir.appendingPathComponent("console.log") }
    var qemuLogURL:    URL { stateDir.appendingPathComponent("qemu.log") }
    private var overlayURL: URL { stateDir.appendingPathComponent("overlay.qcow2") }
    private var efiVarsURL: URL { stateDir.appendingPathComponent("edk2-aarch64-vars.fd") }
    private var pidFileURL: URL { stateDir.appendingPathComponent("qemu.pid") }

    /// Live sockets go under a short /tmp dir: macOS unix socket paths
    /// cap at 104 bytes and the Application Support dir blows past that.
    private var socketDir: URL { URL(fileURLWithPath: "/tmp/qva-\(vmName)", isDirectory: true) }
    private var qmpSocketURL: URL { socketDir.appendingPathComponent("qmp.sock") }
    private var qgaSocketURL: URL { socketDir.appendingPathComponent("qga.sock") }

    private var currentPid: pid_t? {
        if let p = process, p.isRunning { return p.processIdentifier }
        return attachedPid
    }

    /// True if quitting the app should power the VM down first.
    var needsShutdownOnQuit: Bool { currentPid != nil }

    // MARK: Bootstrap (called once, when the menubar item appears)

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true

        // Watch for the dext binding/unbinding devices (eGPU hot-plug).
        // The watcher fires once at start, which seeds detectedGPUs.
        let watcher = DextDeviceWatcher {
            Task { @MainActor in
                VMManager.shared.refreshDetectedGPU()
            }
        }
        watcher.start()
        deviceWatcher = watcher

        Task {
            if await tryReattach() { return }
            if settings.startOnLaunch { start() }
        }
    }

    /// Re-run the IORegistry walk and publish what the next boot would
    /// pass through. Called by the device watcher on attach/detach.
    private func refreshDetectedGPU() {
        let db = PciIdsDB.shared
        detectedGPUs = autoDetectPassthroughSlots().compactMap { slot in
            guard let fn0 = slot.first else { return nil }

            // Prefer a friendly pci.ids name ("NVIDIA Corporation GA102
            // [GeForce RTX 3090]") over the raw IOKit description with
            // hex ids. The bundled db can be missing on dev builds, and
            // device-tree-only endpoints may not be in it — fall back to
            // the raw description in both cases.
            var name = fn0.description
            if let db {
                let info = db.lookup(vendor: fn0.vendor, device: fn0.deviceId,
                                     subVendor: 0, subDevice: 0)
                let parts = [info.vendorName.map(Self.shortVendorName),
                             info.deviceName.map(Self.bracketForm)].compactMap { $0 }
                if !parts.isEmpty {
                    // Slot + root suffix keeps two identical GPUs
                    // distinguishable in the menu.
                    var suffix = fn0.slotString
                    if let root = fn0.root { suffix += " @ \(root)" }
                    name = "\(parts.joined(separator: " ")) (\(suffix))"
                }
            }
            // Sibling-function count (HDMI audio etc.) so the menu still
            // says the whole endpoint group is coming along.
            if slot.count > 1 {
                name += " (+\(slot.count - 1) fn)"
            }
            return name
        }
    }

    /// pci.ids embeds a well-known alternate form in brackets on many
    /// entries: vendors ("Advanced Micro Devices, Inc. [AMD/ATI]") and
    /// devices ("Navi 10 [Radeon Pro W5700]", where the bracket holds
    /// the marketing name vs the chip codename). The bracket form is
    /// the one people recognize and it's shorter — prefer it whenever
    /// present, otherwise keep the name as-is.
    nonisolated private static func bracketForm(_ name: String) -> String {
        guard let open = name.firstIndex(of: "["),
              let close = name.firstIndex(of: "]"),
              open < close
        else { return name }
        let inner = name[name.index(after: open)..<close]
        return inner.isEmpty ? name : String(inner)
    }

    /// Compact the verbose legal names pci.ids uses for vendors so the
    /// menu doesn't have to be so wide: bracket form when there is one,
    /// otherwise trailing legalese trimmed ("NVIDIA Corporation" →
    /// "NVIDIA").
    nonisolated private static func shortVendorName(_ name: String) -> String {
        let bracket = bracketForm(name)
        if bracket != name { return bracket }

        var s = name
        let suffixes = ["Corporation", "Corp.", "Corp", "Incorporated",
                        "Inc.", "Inc", "Co., Ltd.", "Co., Ltd", "Ltd.",
                        "Ltd", "LLC", "GmbH", "S.A.", "AG", "Co.", "Co"]
        while true {
            let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            // Only strip whole words: the character before the suffix
            // must be a separator, so e.g. "Fujitsu Microelectronics"
            // isn't chopped by "Co.".
            guard let hit = suffixes.first(where: { suffix in
                guard trimmed.hasSuffix(suffix),
                      trimmed.count > suffix.count else { return false }
                let before = trimmed[trimmed.index(trimmed.endIndex,
                                                   offsetBy: -(suffix.count + 1))]
                return before == " " || before == ","
            }) else {
                s = trimmed
                break
            }
            s = String(trimmed.dropLast(hit.count))
        }
        return s.isEmpty ? name : s
    }

    // MARK: Start

    func start() {
        switch state {
        case .stopped, .failed: break
        default: return
        }
        Task { await startFlow() }
    }

    private func startFlow() async {
        do {
            if await tryReattach() { return }

            let tools = try AppBundleTools.locate()

            // 1. Base image.
            let base: URL
            let localOverride = settings.localBasePath
            if !localOverride.isEmpty {
                let url = URL(fileURLWithPath: (localOverride as NSString).expandingTildeInPath)
                    .standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw VMError.message("Local base image not found: \(url.path)")
                }
                base = url
            } else {
                state = .pulling("Checking image…")
                base = try await pullImage(tools: tools)
            }
            guard canContinueStarting else { return }

            // 2. Overlay + EFI vars.
            state = .starting("Preparing disk…")
            try FileManager.default.createDirectory(at: stateDir,
                                                    withIntermediateDirectories: true)
            try await Self.ensureOverlay(overlay: overlayURL, base: base,
                                         qemuImg: tools.qemuImg)
            try ensureEfiVars(template: tools.efiVarsTemplate)

            // 3. Passthrough + argv. Every dext-bound GPU slot gets
            // passed through, not just the first one found.
            let passthrough = settings.passthroughEnabled
                ? autoDetectPassthroughSlots()
                : []
            bootedGPUCount = passthrough.count
            let argv = buildArgv(tools: tools, passthrough: passthrough)

            // 4. Spawn.
            try prepareSocketDir()
            state = .starting("Booting…")
            let proc = try spawnQemu(tools: tools, argv: argv)
            process = proc
            writePidFile(proc.processIdentifier)

            // 5. QMP + Docker readiness.
            state = .starting("Connecting to VM monitor…")
            qmp = try await connectQMP()

            state = .starting("Waiting for Docker…")
            let ready = await waitForDockerReady(timeoutSeconds: 300)
            guard canContinueStarting else { return }
            guard ready else {
                throw VMError.message("Timed out waiting for the Docker API on 127.0.0.1:\(settings.dockerPort)")
            }

            state = .running
            startPortWatcher()
        } catch {
            // If qemu is up but something later failed, don't leave an
            // orphan running with no UI attached to it.
            if let p = process, p.isRunning {
                p.terminate()
            }
            if case .stopping = state { return }
            if case .stopped  = state { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// startFlow phases bail out quietly when qemu died underneath them
    /// (handleExit already published the failure) or a stop raced in.
    private var canContinueStarting: Bool {
        switch state {
        case .pulling, .starting: return true
        default:                  return false
        }
    }

    // MARK: Stop

    func stop() {
        Task { await stopAndWait() }
    }

    /// Graceful shutdown: QMP system_powerdown → SIGTERM → SIGKILL.
    /// Returns once the qemu process is gone and state is .stopped.
    func stopAndWait() async {
        guard let pid = currentPid else {
            if state.isBusy || state == .running { state = .stopped }
            return
        }
        state = .stopping

        if let qmp {
            _ = await Task.detached { try? qmp.systemPowerdown() }.value
            if await Self.waitForPidExit(pid, timeoutSeconds: 30) {
                finishStopIfNeeded()
                return
            }
        }

        kill(pid, SIGTERM)
        if await Self.waitForPidExit(pid, timeoutSeconds: 10) {
            finishStopIfNeeded()
            return
        }

        kill(pid, SIGKILL)
        _ = await Self.waitForPidExit(pid, timeoutSeconds: 5)
        finishStopIfNeeded()
    }

    /// The termination handler / pid monitor normally drives the final
    /// transition; this covers the reattached-pid case where the kqueue
    /// source may lag the poll loop.
    private func finishStopIfNeeded() {
        if state != .stopped { handleExit(code: nil) }
    }

    // MARK: Exit handling

    private func handleExit(code: Int32?) {
        let wasStopping = (state == .stopping)

        portWatcher?.stop()
        portWatcher = nil
        qmp?.disconnect()
        qmp = nil
        statsTask?.cancel()
        statsTask = nil
        guestAgent?.disconnect()
        guestAgent = nil
        guestStats = nil
        gpuHistory = [:]
        containers = []
        process = nil
        attachedPid = nil
        pidExitSource?.cancel()
        pidExitSource = nil
        removePidFile()
        forwardedPorts = []
        portNotes = []
        bootedGPUCount = nil

        if wasStopping || state == .stopped {
            state = .stopped
        } else {
            state = .failed(exitMessage(code: code))
        }
    }

    private func exitMessage(code: Int32?) -> String {
        let tail = Self.tailOfFile(qemuLogURL, bytes: 4096)
        if tail.contains("Failed to get \"write\" lock") {
            return "The VM disk is locked — another QEMU instance is already running this VM."
        }
        if let lastLine = tail
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.contains("Error") || $0.contains("error") })
        {
            return "QEMU exited: \(lastLine.trimmingCharacters(in: .whitespaces))"
        }
        if let code {
            return "QEMU exited unexpectedly (code \(code)). See qemu.log in the VM data folder."
        }
        return "The VM stopped."
    }

    // MARK: Reattach

    /// If a previous app instance left qemu running (app crash, forced
    /// relaunch), adopt it: verify the pidfile's process is alive and
    /// the QMP socket answers, then treat it as ours.
    private func tryReattach() async -> Bool {
        guard let pid = readPidFile() else { return false }
        guard kill(pid, 0) == 0 else {
            removePidFile()
            return false
        }

        let client = QMPClient(socketPath: qmpSocketURL.path)
        let connected = await Task.detached { () -> Bool in
            (try? client.connect()) != nil
        }.value
        guard connected else {
            // Alive pid but no QMP — not a qemu we can manage. Leave the
            // pidfile so we don't fight whatever owns that process.
            return false
        }

        qmp = client
        attachedPid = pid
        monitorPidExit(pid)
        bootedGPUCount = nil   // unknown — we didn't build this qemu's argv
        state = .running
        startPortWatcher()
        return true
    }

    private func monitorPidExit(_ pid: pid_t) {
        let src = DispatchSource.makeProcessSource(identifier: pid,
                                                   eventMask: .exit,
                                                   queue: .global())
        src.setEventHandler {
            Task { @MainActor in
                VMManager.shared.handleExit(code: nil)
            }
        }
        src.resume()
        pidExitSource = src
    }

    // MARK: Image pull

    private func pullImage(tools: AppBundleTools) async throws -> URL {
        let ref = settings.imageRef
        return try await Self.runPull(cli: tools.cli, imageRef: ref) { line in
            Task { @MainActor in
                let mgr = VMManager.shared
                if case .pulling = mgr.state {
                    mgr.state = .pulling(line)
                }
            }
        }
    }

    /// Run `qemu-vfio-apple pull --image <ref>`. Progress lines stream on
    /// stderr; the cached image path is the last stdout line.
    nonisolated private static func runPull(
        cli: URL,
        imageRef: String,
        onProgress: @escaping @Sendable (String) -> Void) async throws -> URL
    {
        let p = Process()
        p.executableURL = cli
        p.arguments = ["pull", "--image", imageRef]
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let collector = LineCollector()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data) { line in onProgress(line) }
        }

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = nil

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""

        guard status == 0 else {
            let detail = collector.lastLine ?? "exit code \(status)"
            throw VMError.message("Image download failed: \(detail)")
        }
        guard let pathLine = stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }),
              FileManager.default.fileExists(atPath: pathLine)
        else {
            throw VMError.message("Image download did not produce a usable path.")
        }
        return URL(fileURLWithPath: pathLine)
    }

    // MARK: Overlay + EFI vars

    nonisolated private static func ensureOverlay(overlay: URL, base: URL,
                                                  qemuImg: URL) async throws
    {
        let fm = FileManager.default
        if fm.fileExists(atPath: overlay.path) {
            // Rebase if the cached base moved (digest change on re-pull).
            if let backing = try await queryBackingFile(overlay: overlay, qemuImg: qemuImg),
               backing != base.path
            {
                let r = try await runTool(qemuImg, ["rebase", "-u", "-F", "qcow2",
                                                    "-b", base.path, overlay.path])
                guard r.code == 0 else {
                    throw VMError.message("qemu-img rebase failed: \(r.err)")
                }
            }
            return
        }
        try fm.createDirectory(at: overlay.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let r = try await runTool(qemuImg, ["create", "-f", "qcow2", "-F", "qcow2",
                                            "-b", base.path, overlay.path])
        guard r.code == 0 else {
            throw VMError.message("qemu-img create failed: \(r.err)")
        }
    }

    nonisolated private static func queryBackingFile(overlay: URL,
                                                     qemuImg: URL) async throws -> String?
    {
        let r = try await runTool(qemuImg, ["info", "--output=json", overlay.path])
        guard r.code == 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(r.out.utf8))
                as? [String: Any]
        else { return nil }
        return obj["backing-filename"] as? String
            ?? obj["full-backing-filename"] as? String
    }

    private func ensureEfiVars(template: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: efiVarsURL.path) else { return }
        try fm.copyItem(at: template, to: efiVarsURL)
        // Template ships read-only; qemu mutates the copy on boot.
        try? fm.setAttributes([.posixPermissions: 0o644],
                              ofItemAtPath: efiVarsURL.path)
    }

    // MARK: Spawn

    private func prepareSocketDir() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: socketDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: qmpSocketURL)
        try? fm.removeItem(at: qgaSocketURL)
    }

    private func spawnQemu(tools: AppBundleTools, argv: [String]) throws -> Process {
        let fm = FileManager.default
        fm.createFile(atPath: qemuLogURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: qemuLogURL)

        let p = Process()
        p.executableURL = tools.qemu
        p.arguments = argv
        p.currentDirectoryURL = stateDir
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            try? log.close()
            Task { @MainActor in
                VMManager.shared.handleExit(code: code)
            }
        }
        do {
            try p.run()
        } catch {
            throw VMError.message("could not start qemu-system-aarch64: \(error.localizedDescription)")
        }
        return p
    }

    /// Docker-profile argv. Mirrors the CLI's buildQemuArgv with the
    /// headless-service differences: no display/input devices, serial to
    /// a file, QMP socket, loopback-only hostfwd for ssh + Docker,
    /// smaller unpinned RAM (no prealloc), and a balloon so an always-on
    /// idle VM can be shrunk.
    private func buildArgv(tools: AppBundleTools,
                           passthrough: [[PassthroughCandidate]]) -> [String]
    {
        var a: [String] = []

        a += ["-L", tools.shareDir.path]
        a += ["-accel", "hvf,tso=on"]
        a += ["-cpu", "host"]
        a += ["-smp", "\(settings.cpus),sockets=1,cores=\(settings.cpus),threads=1"]
        a += ["-machine", "virt,highmem=on"]
        a += ["-m", settings.memory]

        // UEFI firmware.
        a += ["-drive", "if=pflash,format=raw,readonly=on,file=\(tools.efiCode.path)"]
        a += ["-drive", "if=pflash,format=raw,file=\(efiVarsURL.path)"]

        // Root disk (overlay backed by the cached base).
        a += ["-drive", "if=none,id=hd0,file=\(overlayURL.path),format=qcow2,discard=unmap,detect-zeroes=unmap"]
        a += ["-device", "virtio-blk-pci,drive=hd0"]

        // Network: loopback-only hostfwd. Binding to 127.0.0.1 (not a
        // bare `tcp::PORT`) is what keeps the unauthenticated Docker API
        // off the LAN — same trust model as a local unix socket.
        a += ["-netdev",
              "user,id=net0" +
              ",hostfwd=tcp:127.0.0.1:\(settings.sshPort)-:22" +
              ",hostfwd=tcp:127.0.0.1:\(settings.dockerPort)-:2375"]
        a += ["-device", "virtio-net-pci,netdev=net0"]

        a += ["-device", "virtio-rng-pci"]

        // Balloon so the supervisor (or a future idle policy) can shrink
        // an always-on VM. Requires the unpinned RAM above.
        a += ["-device", "virtio-balloon-pci,deflate-on-oom=on,free-page-reporting=on"]

        // Headless: guest serial console → console.log for debugging.
        a += ["-display", "none"]
        a += ["-serial", "file:\(consoleLogURL.path)"]

        // Control plane.
        a += ["-qmp", "unix:\(qmpSocketURL.path),server=on,wait=off"]

        // Guest agent channel: the docker image ships qemu-guest-agent,
        // which auto-attaches to this virtserialport by its well-known
        // name. Used for the in-guest stats the menu shows (GPU busy %,
        // VRAM, load) — the GPU belongs to the guest, so the host can't
        // sample it directly.
        a += ["-chardev", "socket,id=qga0,path=\(qgaSocketURL.path),server=on,wait=off"]
        a += ["-device", "virtio-serial-pci"]
        a += ["-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"]

        // Passthrough: same multifunction bundling as the CLI launcher —
        // every dext-bound function of a host slot lands on one guest
        // slot with its own dma-companion. Multiple host slots (dual
        // GPUs) get consecutive guest slots counting down from 0x1e so
        // they stay above qemu's auto-assigned range (which fills from
        // slot 1 upward).
        for (i, group) in passthrough.enumerated() where !group.isEmpty {
            let guestSlot = 0x1e - i
            let fn0 = group[0].function
            for c in group {
                let guestFn = Int(c.function) - Int(fn0)
                var props: [String] = [
                    "vfio-apple-pci",
                    "host=\(c.hostBDF)",
                    String(format: "addr=0x%x.%x", guestSlot, guestFn),
                    "dma-companion=on",
                ]
                // Apple Silicon reuses BDFs across host PCI roots, so
                // pin the root-port name whenever we know it — with two
                // GPUs on colliding BDFs qemu can't pick one without it.
                if let root = c.root, !root.isEmpty {
                    props.append("host-root=\(root)")
                }
                if group.count > 1 && c.function == fn0 {
                    props.append("multifunction=on")
                }
                a += ["-device", props.joined(separator: ",")]
            }
        }

        return a
    }

    // MARK: QMP / readiness

    private func connectQMP() async throws -> QMPClient {
        let path = qmpSocketURL.path
        for _ in 0..<60 {
            guard canContinueStarting else {
                throw VMError.message("VM exited during startup")
            }
            let client = QMPClient(socketPath: path)
            let ok = await Task.detached { () -> Bool in
                (try? client.connect()) != nil
            }.value
            if ok { return client }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw VMError.message("Timed out connecting to the VM monitor socket")
    }

    // MARK: Guest stats (menu-open polling)

    /// Balanced begin/end calls from the menu's onAppear/onDisappear
    /// drive a poll loop that only runs while the menu is dropped down —
    /// no reason to exec into the guest every couple of seconds when
    /// nobody is looking.
    func beginStatsPolling() {
        statsMenuOpenCount += 1
        guard statsTask == nil else { return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleGuestStats()
                await self?.sampleContainers()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func endStatsPolling() {
        statsMenuOpenCount = max(0, statsMenuOpenCount - 1)
        guard statsMenuOpenCount == 0 else { return }
        statsTask?.cancel()
        statsTask = nil
        guestStats = nil
        // History would be stale (and full of gaps) by the next open.
        gpuHistory = [:]
        containers = []
    }

    private func sampleGuestStats() async {
        guard state == .running else {
            guestStats = nil
            return
        }

        // Lazily (re)connect. A missing socket or unresponsive agent is
        // normal (reattached VM predating the QGA channel, guest still
        // booting) — the menu just shows no stats.
        let agent: GuestAgentClient
        if let existing = guestAgent, existing.isConnected {
            agent = existing
        } else {
            let fresh = GuestAgentClient(socketPath: qgaSocketURL.path)
            let ok = await Task.detached { (try? fresh.connect()) != nil }.value
            guard ok else {
                guestStats = nil
                return
            }
            guestAgent = fresh
            agent = fresh
        }

        let sample = await Task.detached { () -> GuestStats? in
            guard let out = try? agent.exec(
                ["/bin/sh", "-c", Self.statsScript], timeoutSeconds: 4)
            else { return nil }
            return Self.parseStats(out)
        }.value

        guard let sample else {
            // Exec failed — drop the connection so the next poll re-syncs
            // instead of inheriting a desynced stream.
            agent.disconnect()
            guestAgent = nil
            guestStats = nil
            return
        }
        guestStats = sample

        // Extend the per-GPU busy history that feeds the sparklines.
        // gpu_busy_percent is instantaneous, so each poll is one point.
        for gpu in sample.gpus {
            guard let busy = gpu.busyPercent else { continue }
            var series = gpuHistory[gpu.id, default: []]
            series.append(Double(busy))
            if series.count > gpuHistoryLimit {
                series.removeFirst(series.count - gpuHistoryLimit)
            }
            gpuHistory[gpu.id] = series
        }
    }

    // MARK: Containers (menu-open polling + actions)

    private func sampleContainers() async {
        guard state == .running else {
            containers = []
            return
        }
        let port = settings.dockerPort
        let list = await Task.detached {
            try? await Self.fetchContainers(port: port)
        }.value
        // A transient API failure keeps the previous list — flicker
        // (section disappearing mid-interaction) is worse than a
        // 2-second-stale row.
        if let list { containers = list }
    }

    /// Run a lifecycle action against a container and refresh the list.
    /// Returns an error description, or nil on success — the menu shows
    /// failures in an alert.
    func performContainerAction(_ container: DockerContainer,
                                _ action: ContainerAction) async -> String?
    {
        let port = settings.dockerPort
        let error = await Task.detached { () -> String? in
            do {
                try await Self.postContainerAction(
                    port: port, id: container.id, action: action)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        await sampleContainers()
        return error
    }

    nonisolated private static func fetchContainers(port: Int) async throws -> [DockerContainer] {
        // Default /containers/json lists running + paused only, which is
        // exactly the control surface the menu wants.
        let url = URL(string: "http://127.0.0.1:\(port)/containers/json")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { obj -> DockerContainer? in
            guard let id = obj["Id"] as? String else { return nil }
            // Names come as ["/frontend"]; strip the leading slash.
            let name = (obj["Names"] as? [String])?.first
                .map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
                ?? String(id.prefix(12))
            return DockerContainer(
                id: id,
                name: name,
                image: obj["Image"] as? String ?? "",
                state: obj["State"] as? String ?? "",
                status: obj["Status"] as? String ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func postContainerAction(
        port: Int, id: String, action: ContainerAction) async throws
    {
        let url = URL(string: "http://127.0.0.1:\(port)/containers/\(id)/\(action.apiPath)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Must outlive stop/restart's in-guest 10 s SIGTERM grace period.
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw VMError.message("unexpected response from the Docker API")
        }
        // 204 success; 304 "already in that state" is fine too.
        guard http.statusCode == 204 || http.statusCode == 304 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VMError.message(
                "\(action.rawValue) failed (HTTP \(http.statusCode)): \(body.prefix(200))")
        }
    }

    /// Everything in one round-trip: load, memory, then per-GPU lines
    /// from amdgpu sysfs and/or nvidia-smi (whichever exists in the
    /// guest). Section markers keep host-side parsing trivial.
    nonisolated private static let statsScript = """
        echo ===load; cat /proc/loadavg
        echo ===mem; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
        echo ===amd
        for d in /sys/class/drm/card*/device; do
            [ -f "$d/gpu_busy_percent" ] || continue
            card=$(basename "$(dirname "$d")")
            echo "$card $(cat "$d/gpu_busy_percent" 2>/dev/null) \
        $(cat "$d/mem_info_vram_used" 2>/dev/null) \
        $(cat "$d/mem_info_vram_total" 2>/dev/null)"
        done
        echo ===nvidia
        command -v nvidia-smi >/dev/null 2>&1 && \
            nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total \
                --format=csv,noheader,nounits 2>/dev/null
        exit 0
        """

    nonisolated private static func parseStats(_ out: String) -> GuestStats {
        var load1: Double?
        var memTotal: Int64?
        var memAvailable: Int64?
        var gpus: [GuestStats.GPU] = []

        var section = ""
        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===") {
                section = String(line.dropFirst(3))
                continue
            }
            if line.isEmpty { continue }

            switch section {
            case "load":
                // "0.42 0.31 0.20 1/213 4321"
                load1 = line.split(separator: " ").first.flatMap { Double($0) }
            case "mem":
                // "MemTotal:  8000000 kB"
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 2, let kb = Int64(f[1]) else { break }
                if f[0] == "MemTotal:" { memTotal = kb * 1024 }
                if f[0] == "MemAvailable:" { memAvailable = kb * 1024 }
            case "amd":
                // "card0 34 2147483648 8589934592"
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 1 else { break }
                gpus.append(GuestStats.GPU(
                    id: String(f[0]),
                    busyPercent: f.count > 1 ? Int(f[1]) : nil,
                    vramUsedBytes: f.count > 2 ? Int64(f[2]) : nil,
                    vramTotalBytes: f.count > 3 ? Int64(f[3]) : nil))
            case "nvidia":
                // "0, 34, 2048, 8192" (MiB)
                let f = line.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard f.count >= 4 else { break }
                gpus.append(GuestStats.GPU(
                    id: "nvidia\(f[0])",
                    busyPercent: Int(f[1]),
                    vramUsedBytes: Int64(f[2]).map { $0 * 1_048_576 },
                    vramTotalBytes: Int64(f[3]).map { $0 * 1_048_576 }))
            default:
                break
            }
        }

        let memUsed: Int64? = {
            guard let t = memTotal, let a = memAvailable else { return nil }
            return t - a
        }()
        return GuestStats(gpus: gpus, load1: load1,
                          memUsedBytes: memUsed, memTotalBytes: memTotal)
    }

    private func waitForDockerReady(timeoutSeconds: Int) async -> Bool {
        let port = settings.dockerPort
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            guard canContinueStarting else { return false }
            if await Self.dockerPing(port: port) { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    nonisolated private static func dockerPing(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/_ping") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    // MARK: Port watcher

    private func startPortWatcher() {
        guard let qmp else { return }
        let watcher = PortWatcher(
            dockerPort: settings.dockerPort,
            qmp: qmp,
            onPortsChanged: { ports in
                Task { @MainActor in
                    VMManager.shared.forwardedPorts = ports
                }
            },
            onNote: { note in
                Task { @MainActor in
                    VMManager.shared.addPortNote(note)
                }
            })
        watcher.start()
        portWatcher = watcher
    }

    private func addPortNote(_ note: String) {
        portNotes.append(note)
        if portNotes.count > 5 {
            portNotes.removeFirst(portNotes.count - 5)
        }
    }

    // MARK: Pidfile

    private func readPidFile() -> pid_t? {
        guard let s = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    private func writePidFile(_ pid: pid_t) {
        try? FileManager.default.createDirectory(at: stateDir,
                                                 withIntermediateDirectories: true)
        try? "\(pid)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    // MARK: Helpers

    nonisolated private static func waitForPidExit(_ pid: pid_t,
                                                   timeoutSeconds: Int) async -> Bool
    {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if kill(pid, 0) != 0 { return true }   // ESRCH → gone
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return kill(pid, 0) != 0
    }

    nonisolated private static func runTool(
        _ tool: URL,
        _ args: [String]) async throws -> (code: Int32, out: String, err: String)
    {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
            } catch {
                p.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return (status, out, err)
    }

    nonisolated private static func tailOfFile(_ url: URL, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - LineCollector

/// Accumulates pipe data and emits complete lines (split on \n and \r —
/// the downloader's progress output uses carriage returns).
nonisolated private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var lastLine: String?

    func append(_ data: Data, onLine: (String) -> Void) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
            let lineData = buffer.subdata(in: buffer.startIndex..<idx)
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces),
               !s.isEmpty
            {
                lines.append(s)
            }
        }
        if let last = lines.last { lastLine = last }
        lock.unlock()
        for line in lines { onLine(line) }
    }
}
