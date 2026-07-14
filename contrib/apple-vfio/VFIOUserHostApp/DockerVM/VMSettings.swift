// VMSettings.swift — UserDefaults-backed configuration for the managed
// headless Docker VM. There is deliberately no settings UI yet; power
// users can override via `defaults write` on the host app's domain,
// e.g.:
//
//   defaults write scottjg.VFIOUserHostApp dockerVM.localBasePath \
//       ~/src/qemu-vfio-apple/contrib/apple-vfio/image-builder/out/ubuntu-docker-image/artifacts/ubuntu-docker-resolute-arm64.qcow2

import Combine
import Foundation

@MainActor
final class VMSettings: ObservableObject {
    static let shared = VMSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let imageRef       = "dockerVM.imageRef"
        static let localBasePath  = "dockerVM.localBasePath"
        static let cpus           = "dockerVM.cpus"
        static let memory         = "dockerVM.memory"
        static let sshPort        = "dockerVM.sshPort"
        static let dockerPort     = "dockerVM.dockerPort"
        static let passthrough    = "dockerVM.passthrough"
        static let startOnLaunch  = "dockerVM.startOnLaunch"
    }

    init() {
        defaults.register(defaults: [
            Key.imageRef: "ghcr.io/scottjg/qemu-vfio-apple-images:ubuntu-docker-resolute-arm64",
            // Docker profile defaults are deliberately smaller than the
            // desktop VM: no prealloc, 8G RAM — dockerd doesn't need the
            // gaming-latency memory pinning and the VM may be always-on.
            Key.cpus: 8,
            Key.memory: "8G",
            Key.sshPort: 2222,
            Key.dockerPort: 2375,
            Key.passthrough: true,
            Key.startOnLaunch: false,
        ])
    }

    /// GHCR OCI image ref for the docker-profile guest image.
    var imageRef: String {
        get { defaults.string(forKey: Key.imageRef) ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.imageRef) }
    }

    /// Local qcow2 base image override. When non-empty the GHCR pull is
    /// skipped entirely — used for testing a locally built artifact
    /// before publishing.
    var localBasePath: String {
        get { defaults.string(forKey: Key.localBasePath) ?? "" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.localBasePath) }
    }

    var cpus: Int {
        get { max(1, defaults.integer(forKey: Key.cpus)) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.cpus) }
    }

    /// RAM in qemu syntax (e.g. "8G").
    var memory: String {
        get { defaults.string(forKey: Key.memory) ?? "8G" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.memory) }
    }

    /// Host loopback port forwarded to guest sshd (22).
    var sshPort: Int {
        get { defaults.integer(forKey: Key.sshPort) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.sshPort) }
    }

    /// Host loopback port forwarded to the guest Docker API (2375).
    var dockerPort: Int {
        get { defaults.integer(forKey: Key.dockerPort) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.dockerPort) }
    }

    /// Auto-detect and pass through the dext-bound GPU slot.
    var passthroughEnabled: Bool {
        get { defaults.bool(forKey: Key.passthrough) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.passthrough) }
    }

    /// Boot the VM automatically when the app launches.
    var startOnLaunch: Bool {
        get { defaults.bool(forKey: Key.startOnLaunch) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.startOnLaunch) }
    }
}
