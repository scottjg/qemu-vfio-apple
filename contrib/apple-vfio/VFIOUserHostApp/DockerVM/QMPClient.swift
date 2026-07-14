// QMPClient.swift — minimal synchronous QMP client over a unix socket.
//
// Speaks just enough of the QEMU Machine Protocol for the menubar app's
// control plane:
//
//   - capabilities negotiation on connect
//   - query-status        ("is the guest actually running?")
//   - system_powerdown    (graceful ACPI shutdown for `Stop`)
//   - human-monitor-command wrapping hostfwd_add / hostfwd_remove for
//     dynamic port mirroring (slirp has no native QMP command for this)
//
// The client is deliberately blocking: QMP is strictly request/response
// for our command set, and every call site already runs off the main
// actor (Task.detached from VMManager, PortWatcher's stream task). A
// receive timeout keeps a wedged qemu from hanging a caller forever.
// Async event messages that arrive between responses are skipped.
//
// Thread-safety: an internal lock serializes command exchanges, so the
// port watcher and lifecycle code can share one connection.

import Foundation

enum QMPError: LocalizedError {
    case socket(String)
    case protocolError(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .socket(let s):        return "QMP socket error: \(s)"
        case .protocolError(let s): return "QMP protocol error: \(s)"
        case .commandFailed(let s): return "QMP command failed: \(s)"
        }
    }
}

nonisolated final class QMPClient: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1
    private var buffer = Data()
    private let lock = NSLock()

    init(socketPath: String) {
        self.path = socketPath
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// Connect, consume the greeting, and negotiate capabilities.
    func connect() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }

        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw QMPError.socket("socket(): \(Self.errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(s)
            throw QMPError.socket("socket path too long (\(path))")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBufferPointer { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(
                    start: src.baseAddress, count: src.count))
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = Self.errnoString()
            Darwin.close(s)
            throw QMPError.socket("connect \(path): \(err)")
        }

        // A wedged qemu shouldn't be able to hang callers forever.
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

        fd = s
        buffer.removeAll()

        do {
            guard let greeting = try readMessageLocked(), greeting["QMP"] != nil else {
                throw QMPError.protocolError("no QMP greeting")
            }
            _ = try commandLocked("qmp_capabilities", arguments: nil)
        } catch {
            closeLocked()
            throw error
        }
    }

    func disconnect() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    @discardableResult
    func command(_ execute: String, arguments: [String: Any]? = nil) throws -> Any {
        lock.lock()
        defer { lock.unlock() }
        return try commandLocked(execute, arguments: arguments)
    }

    /// `query-status` → the guest run state string ("running", "paused",
    /// "shutdown", …).
    func queryStatus() throws -> String {
        let ret = try command("query-status")
        guard let dict = ret as? [String: Any],
              let status = dict["status"] as? String
        else {
            throw QMPError.protocolError("unexpected query-status payload")
        }
        return status
    }

    func systemPowerdown() throws {
        try command("system_powerdown")
    }

    /// Wrap an HMP command; returns HMP's textual output ("" on success
    /// for the hostfwd commands).
    @discardableResult
    func humanMonitorCommand(_ commandLine: String) throws -> String {
        let ret = try command("human-monitor-command",
                              arguments: ["command-line": commandLine])
        return (ret as? String) ?? ""
    }

    /// Add a slirp forward from Mac loopback to the guest. Returns nil on
    /// success, or HMP's error text (e.g. the port is already bound on
    /// the host side).
    func hostfwdAdd(proto: String, hostPort: Int, guestPort: Int,
                    netdev: String = "net0") throws -> String?
    {
        let out = try humanMonitorCommand(
            "hostfwd_add \(netdev) \(proto):127.0.0.1:\(hostPort)-:\(guestPort)")
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func hostfwdRemove(proto: String, hostPort: Int,
                       netdev: String = "net0") throws
    {
        _ = try humanMonitorCommand(
            "hostfwd_remove \(netdev) \(proto):127.0.0.1:\(hostPort)")
    }

    // MARK: - Internals (caller must hold `lock`)

    private func closeLocked() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        buffer.removeAll()
    }

    private func commandLocked(_ execute: String,
                               arguments: [String: Any]?) throws -> Any
    {
        guard fd >= 0 else { throw QMPError.socket("not connected") }

        var msg: [String: Any] = ["execute": execute]
        if let arguments { msg["arguments"] = arguments }
        let data = try JSONSerialization.data(withJSONObject: msg)

        var payload = data
        payload.append(0x0a)  // newline terminator keeps qemu's parser happy
        try writeAllLocked(payload)

        // Read until we get a response (skipping async events).
        while true {
            guard let obj = try readMessageLocked() else {
                throw QMPError.protocolError("connection closed mid-command")
            }
            if let ret = obj["return"] {
                return ret
            }
            if let err = obj["error"] as? [String: Any] {
                let desc = err["desc"] as? String ?? "\(err)"
                throw QMPError.commandFailed(desc)
            }
            // {"event": ...} and greeting re-sends fall through here.
        }
    }

    private func writeAllLocked(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n <= 0 {
                    throw QMPError.socket("write: \(Self.errnoString())")
                }
                offset += n
            }
        }
    }

    /// Read one newline-delimited JSON object from the socket.
    private func readMessageLocked() throws -> [String: Any]? {
        while true {
            // Extract a complete line from the buffer if we have one.
            if let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let trimmed = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty { continue }
                guard let json = try? JSONSerialization.jsonObject(
                        with: Data(trimmed.utf8)) as? [String: Any]
                else {
                    throw QMPError.protocolError("unparseable message: \(trimmed.prefix(200))")
                }
                return json
            }

            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { return nil }  // EOF
            if n < 0 {
                throw QMPError.socket("read: \(Self.errnoString())")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
