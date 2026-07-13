// PassthroughSupport.swift — app-target home for the one global that
// the shared Passthrough.swift (compiled into both the qemu-vfio-apple
// CLI and this app) expects its host target to provide.
//
// In the CLI it comes from Driver.swift; here we derive the dext id
// from the app's own bundle identifier, matching the convention used
// by SystemExtensionActivationManager (`<app-id>.VFIOUserPCIDriver`).

import Foundation

let kDextBundleID = Bundle.main.bundleIdentifier! + ".VFIOUserPCIDriver"
