//
//  VFIOUserHostAppApp.swift
//  VFIOUserHostApp
//
//  Menubar-primary host app for the VFIOUserPCIDriver dext. Two jobs:
//
//    1. Setup: install/activate the DriverKit extension and the CLI
//       wrappers via the setup checklist window (ContentView). The app
//       must live in /Applications for the dext to load, hence the
//       at-launch "move to /Applications" prompt.
//
//    2. Run the managed headless Docker VM from the menubar: boot the
//       docker-profile guest in the background against the bundled
//       qemu-system-aarch64, expose the Docker API on loopback, and
//       mirror published container ports (see DockerVM/).
//
//  The app is an LSUIElement (no Dock icon). The setup window opens
//  from the menubar item, and automatically at launch while setup is
//  incomplete.
//

import AppKit
import SwiftUI

/// Drives the at-launch "move to /Applications" prompt before any UI
/// appears, and gates app termination on a graceful VM shutdown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MoveToApplications.runIfNeeded()
    }

    /// If the managed VM is running, power it down before quitting:
    /// QMP system_powerdown with SIGTERM/SIGKILL escalation (see
    /// VMManager.stopAndWait). `.terminateLater` keeps the app alive
    /// until the reply.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let vm = VMManager.shared
        guard vm.needsShutdownOnQuit else { return .terminateNow }
        Task { @MainActor in
            await vm.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct VFIOUserHostAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vmManager = VMManager.shared

    var body: some Scene {
        Window("QEMU VFIO Setup", id: kSetupWindowID) {
            ContentView()
        }
        .windowResizability(.contentSize)
        // Don't restore/open the setup window on launch; the menubar
        // label's onAppear opens it only while setup is incomplete.
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarStatusLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The status-item label. Also the app's launch hook: the label view is
/// installed immediately at startup (unlike the menu content), so its
/// onAppear is where we reattach/autostart the VM and pop the setup
/// window when the checklist isn't green yet.
private struct MenuBarStatusLabel: View {
    @ObservedObject private var vm = VMManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbolName)
            .onAppear {
                vm.bootstrap()
                if !setupIsComplete() {
                    openWindow(id: kSetupWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    private var symbolName: String {
        switch vm.state {
        case .running:                        return "shippingbox.fill"
        case .pulling, .starting, .stopping:  return "shippingbox.circle"
        case .failed:                         return "exclamationmark.triangle"
        case .stopped:                        return "shippingbox"
        }
    }
}
