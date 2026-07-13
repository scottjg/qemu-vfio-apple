// GuestAgent.swift — minimal QEMU Guest Agent (QGA) client over the
// virtio-serial unix socket.
//
// The docker image ships qemu-guest-agent, and VMManager adds a
// virtserialport named org.qemu.guest_agent.0 to the VM. That gives the
// app an exec channel into the guest with no network or credentials —
// which is how the menubar stats (GPU busy %, VRAM, load, memory) get
// collected: the GPU is passed through, so only the guest can see it.
//
// QGA speaks newline-delimited JSON like QMP but with no greeting and
// no capability negotiation, so this is a separate (smaller) client
// rather than a QMPClient mode. Same blocking + lock design: callers
// run off the main actor and a receive timeout bounds a wedged agent.

import Foundation

enum QGAError: LocalizedError {
    case socket(String)
    case protocolError(String)
    case commandFailed(String)
    case execTimeout

    var errorDescription: String? {
        switch self {
        case .socket(let s):        return "guest agent socket error: \(s)"
        case .protocolError(let s): return "guest agent protocol error: \(s)"
        case .commandFailed(let s): return "guest agent command failed: \(s)"
        case .execTimeout:          return "guest command timed out"
        }
    }
}

nonisolated final class GuestAgentClient: @unchecked Sendable {
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

    /// Connect and sync the stream. guest-sync makes the agent discard
    /// any half-parsed input from a previous client and proves there's
    /// actually an agent on the other end (the chardev accepts our
    /// connection even when nothing in the guest is listening — only
    /// the sync response tells them apart).
    func connect() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fd < 0 else { return }

        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw QGAError.socket("socket(): \(Self.errnoString())") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(s)
            throw QGAError.socket("socket path too long (\(path))")
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
            throw QGAError.socket("connect \(path): \(err)")
        }

        // Short timeout: an absent agent just never answers, and stats
        // are optional — fail fast instead of hanging the poller.
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

        fd = s
        buffer.removeAll()

        do {
            let id = Int.random(in: 1...Int(Int32.max))
            try writeAllLocked(Self.encode("guest-sync", arguments: ["id": id]))
            while true {
                guard let obj = try readMessageLocked() else {
                    throw QGAError.protocolError("connection closed during guest-sync")
                }
                if let ret = obj["return"] as? Int, ret == id { break }
                // Stale responses from a previous client fall through.
            }
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

    /// Run a command in the guest and return its stdout. Blocks until
    /// the command exits or the deadline passes (guest-exec is async:
    /// spawn returns a pid which we poll with guest-exec-status).
    func exec(_ argv: [String], timeoutSeconds: Double = 5) throws -> String {
        precondition(!argv.isEmpty)
        lock.lock()
        defer { lock.unlock() }

        var args: [String: Any] = [
            "path": argv[0],
            "capture-output": true,
        ]
        if argv.count > 1 {
            args["arg"] = Array(argv.dropFirst())
        }
        let spawn = try commandLocked("guest-exec", arguments: args)
        guard let dict = spawn as? [String: Any], let pid = dict["pid"] as? Int else {
            throw QGAError.protocolError("guest-exec returned no pid")
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let st = try commandLocked("guest-exec-status", arguments: ["pid": pid])
            guard let status = st as? [String: Any] else {
                throw QGAError.protocolError("unexpected guest-exec-status payload")
            }
            if status["exited"] as? Bool == true {
                let out: String
                if let b64 = status["out-data"] as? String,
                   let data = Data(base64Encoded: b64)
                {
                    out = String(data: data, encoding: .utf8) ?? ""
                } else {
                    out = ""
                }
                if let code = status["exitcode"] as? Int, code != 0 {
                    throw QGAError.commandFailed(
                        "\(argv[0]) exited \(code): \(out.prefix(200))")
                }
                return out
            }
            guard Date() < deadline else { throw QGAError.execTimeout }
            Thread.sleep(forTimeInterval: 0.1)
        }
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
        guard fd >= 0 else { throw QGAError.socket("not connected") }
        try writeAllLocked(Self.encode(execute, arguments: arguments))
        while true {
            guard let obj = try readMessageLocked() else {
                throw QGAError.protocolError("connection closed mid-command")
            }
            if let ret = obj["return"] {
                return ret
            }
            if let err = obj["error"] as? [String: Any] {
                let desc = err["desc"] as? String ?? "\(err)"
                throw QGAError.commandFailed(desc)
            }
        }
    }

    private static func encode(_ execute: String,
                               arguments: [String: Any]?) -> Data
    {
        var msg: [String: Any] = ["execute": execute]
        if let arguments { msg["arguments"] = arguments }
        var data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
        data.append(0x0a)
        return data
    }

    private func writeAllLocked(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n <= 0 {
                    throw QGAError.socket("write: \(Self.errnoString())")
                }
                offset += n
            }
        }
    }

    private func readMessageLocked() throws -> [String: Any]? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0a) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let trimmed = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if trimmed.isEmpty { continue }
                guard let json = try? JSONSerialization.jsonObject(
                        with: Data(trimmed.utf8)) as? [String: Any]
                else {
                    throw QGAError.protocolError("unparseable message: \(trimmed.prefix(200))")
                }
                return json
            }

            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            if n < 0 {
                throw QGAError.socket("read: \(Self.errnoString())")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
