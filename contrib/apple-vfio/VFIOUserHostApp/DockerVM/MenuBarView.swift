// MenuBarView.swift — content of the MenuBarExtra: VM status +
// start/stop, Docker connection helpers, forwarded ports, log access,
// login-item toggles, and entry points to the setup window.

import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var vm = VMManager.shared
    @ObservedObject private var settings = VMSettings.shared
    @ObservedObject private var activationManager = SystemExtensionActivationManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            statusSection
            statsSection
            Divider()
            dockerSection
            containersSection
            portsSection
            Divider()
            diagnosticsSection
            Divider()
            launchSection
            Divider()
            Button(setupNeedsAttention ? "Setup Required…" : "Setup…") {
                openSetupWindow()
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        // The menu content only exists while the menu is dropped down,
        // so appear/disappear bracket exactly the window where polling
        // guest stats is worth the exec round-trips.
        .onAppear { vm.beginStatsPolling() }
        .onDisappear { vm.endStatsPolling() }
    }

    // MARK: - Status + start/stop

    @ViewBuilder
    private var statusSection: some View {
        Text(statusLine)
        gpuLines
        if showRestartForGPUHint {
            Text("Restart the VM to attach the GPU")
        }

        switch vm.state {
        case .stopped:
            Button("Start Docker VM") { vm.start() }
        case .failed(let message):
            Text(message)
            Button("Start Docker VM") { vm.start() }
        case .pulling, .starting:
            Button("Stop") { vm.stop() }
        case .running:
            Button("Stop Docker VM") { vm.stop() }
        case .stopping:
            Text("Stopping…")
        }
    }

    private var statusLine: String {
        switch vm.state {
        case .stopped:              return "Docker VM: Stopped"
        case .pulling(let detail):  return "Downloading image — \(detail)"
        case .starting(let detail): return "Starting — \(detail)"
        case .running:              return "Docker VM: Running"
        case .stopping:             return "Docker VM: Stopping…"
        case .failed:               return "Docker VM: Error"
        }
    }

    /// Live view of the dext-bound GPU slots, one line each, updated
    /// by the IOKit device watcher on eGPU plug/unplug.
    @ViewBuilder
    private var gpuLines: some View {
        if !settings.passthroughEnabled {
            Text("GPU: passthrough disabled")
        } else if vm.detectedGPUs.isEmpty {
            Text("GPU: none attached")
        } else {
            ForEach(Array(vm.detectedGPUs.enumerated()), id: \.offset) { _, gpu in
                Text("GPU: \(gpu)")
            }
        }
    }

    /// Live in-guest stats (only while running and the guest agent
    /// answers). Values refresh every couple of seconds while the menu
    /// stays open; the sparkline accumulates over the same window.
    @ViewBuilder
    private var statsSection: some View {
        if vm.state == .running, let stats = vm.guestStats {
            Divider()
            ForEach(stats.gpus) { gpu in
                Text("GPU \(gpu.id): \(gpu.label)")
                if let series = vm.gpuHistory[gpu.id], series.count > 1 {
                    Text(Self.sparkline(series))
                }
            }
            Text(stats.systemLabel)
        }
    }

    /// Render 0–100 values as Unicode block-element bars, newest on the
    /// right. Zero still draws the lowest bar so idle time reads as a
    /// flat line rather than blank space.
    private static func sparkline(_ values: [Double]) -> String {
        let bars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        return String(values.map { v -> Character in
            let clamped = min(max(v, 0), 100)
            let idx = min(bars.count - 1, Int(clamped / 100 * Double(bars.count)))
            return bars[idx]
        })
    }

    /// More GPUs are bound than the running VM booted with —
    /// passthrough is fixed at boot, so surface the restart nudge.
    private var showRestartForGPUHint: Bool {
        guard vm.state == .running,
              settings.passthroughEnabled,
              let booted = vm.bootedGPUCount
        else { return false }
        return vm.detectedGPUs.count > booted
    }

    // MARK: - Docker connection

    @ViewBuilder
    private var dockerSection: some View {
        Button("Copy DOCKER_HOST") {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("export DOCKER_HOST=\(vm.dockerHost)", forType: .string)
        }
        Button("Set Up Docker Context") {
            let result = DockerContextSetup.run(dockerHost: vm.dockerHost)
            showInfoAlert(title: "Docker Context", message: result)
        }
    }

    // MARK: - Containers

    /// Running containers, one submenu each with lifecycle controls.
    /// The list refreshes on the same 2 s cadence as the guest stats
    /// while the menu is open.
    @ViewBuilder
    private var containersSection: some View {
        if vm.state == .running, !vm.containers.isEmpty {
            Divider()
            Text("Containers")
            ForEach(vm.containers) { c in
                Menu(c.isPaused ? "\(c.name) (paused)" : c.name) {
                    Text(c.image)
                    Text(c.status)
                    Divider()
                    if c.isPaused {
                        Button("Unpause") { runContainerAction(c, .unpause) }
                    } else {
                        Button("Pause") { runContainerAction(c, .pause) }
                    }
                    Button("Restart") { runContainerAction(c, .restart) }
                    Button("Stop") { runContainerAction(c, .stop) }
                    Divider()
                    Button("Copy Container ID") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(c.shortID, forType: .string)
                    }
                }
            }
        }
    }

    private func runContainerAction(_ container: DockerContainer,
                                    _ action: ContainerAction)
    {
        Task {
            if let error = await vm.performContainerAction(container, action) {
                showInfoAlert(title: "Container \(action.rawValue) failed",
                              message: error)
            }
        }
    }

    // MARK: - Forwarded ports

    @ViewBuilder
    private var portsSection: some View {
        if !vm.forwardedPorts.isEmpty || !vm.portNotes.isEmpty {
            Divider()
            Text("Forwarded Ports")
            ForEach(vm.forwardedPorts) { fp in
                Text(fp.label)
            }
            ForEach(vm.portNotes, id: \.self) { note in
                Text(note)
            }
        }
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        Button("Open Console Log") {
            NSWorkspace.shared.open(vm.consoleLogURL)
        }
        .disabled(!FileManager.default.fileExists(atPath: vm.consoleLogURL.path))

        Button("Reveal VM Data in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([vm.stateDir])
        }
    }

    // MARK: - Launch behaviour

    @ViewBuilder
    private var launchSection: some View {
        Toggle("Start at Login", isOn: loginItemBinding)
        Toggle("Start VM When App Opens", isOn: Binding(
            get: { settings.startOnLaunch },
            set: { settings.startOnLaunch = $0 }))
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    showInfoAlert(title: "Start at Login",
                                  message: "Could not update the login item: \(error.localizedDescription)")
                }
            })
    }

    // MARK: - Setup

    private var setupNeedsAttention: Bool {
        !setupIsComplete()
    }

    private func openSetupWindow() {
        openWindow(id: kSetupWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Setup readiness

let kSetupWindowID = "setup"

/// The pieces of the setup checklist the menubar VM actually depends
/// on: the app must live in /Applications and the dext must be active
/// (GPU passthrough). The CLI-wrapper install is a convenience and
/// doesn't gate the menubar experience.
@MainActor
func setupIsComplete() -> Bool {
    guard case .ok = locationState(BundleLayout.current) else { return false }
    return SystemExtensionActivationManager.shared.isExtensionKnownActive
}

// MARK: - docker context registration

/// Registers a `qemu-vfio-apple` docker context pointing at the
/// forwarded loopback API and makes it the active context, so plain
/// `docker …` works without exporting DOCKER_HOST.
enum DockerContextSetup {
    static func run(dockerHost: String) -> String {
        guard let docker = findDockerCLI() else {
            return """
                No docker CLI found. Install the docker client (e.g. \
                `brew install docker`), or use "Copy DOCKER_HOST" and export \
                it in your shell instead.
                """
        }

        let create = shell(docker, ["context", "create", "qemu-vfio-apple",
                                    "--docker", "host=\(dockerHost)"])
        if create.code != 0 {
            if create.err.contains("already exists") {
                let update = shell(docker, ["context", "update", "qemu-vfio-apple",
                                            "--docker", "host=\(dockerHost)"])
                if update.code != 0 {
                    return "Failed to update the docker context: \(update.err)"
                }
            } else {
                return "Failed to create the docker context: \(create.err)"
            }
        }

        let use = shell(docker, ["context", "use", "qemu-vfio-apple"])
        guard use.code == 0 else {
            return "Context created, but activating it failed: \(use.err)"
        }
        return "docker context \"qemu-vfio-apple\" is now active (\(dockerHost))."
    }

    /// GUI apps inherit launchd's PATH, which won't include Homebrew or
    /// Docker Desktop locations — check the usual suspects explicitly.
    private static func findDockerCLI() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "\(home)/.local/bin/docker",
            "\(home)/.docker/bin/docker",
            "/usr/bin/docker",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/docker" }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    private static func shell(_ tool: URL,
                              _ args: [String]) -> (code: Int32, out: String, err: String)
    {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return (p.terminationStatus,
                out.trimmingCharacters(in: .whitespacesAndNewlines),
                err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
