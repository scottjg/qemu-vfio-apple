// PortWatcher.swift — mirror published container ports onto Mac loopback.
//
// With slirp networking, `docker run -p 8080:80` publishes 8080 on the
// *guest's* interfaces — unreachable from macOS unless a hostfwd rule
// exists. Static boot-time hostfwd only covers ssh + the Docker API, so
// this watcher makes `-p` behave like Docker Desktop:
//
//   1. On (re)connect, reconcile: list running containers and mirror
//      every published port.
//   2. Subscribe to `GET /events` (type=container). On `start`, inspect
//      the container and add a `hostfwd_add net0 tcp:127.0.0.1:P-:P`
//      rule per published port; on `die`, remove them.
//
// dockerd's API is the source of truth — no in-guest agent needed.
// Mac-side port conflicts are reported as a note and skipped, never
// failing the container. Guest-loopback-only binds stay unreachable
// (hostfwd targets the guest's slirp address, not guest 127.0.0.1);
// Docker publishes on 0.0.0.0 by default so `-p` is fine.
//
// The event stream drops when dockerd restarts or the connection idles
// out; the run loop then re-reconciles and re-subscribes.

import Foundation

nonisolated final class PortWatcher: @unchecked Sendable {
    private let dockerPort: Int
    private let qmp: QMPClient
    private let onPortsChanged: @Sendable ([ForwardedPort]) -> Void
    private let onNote: @Sendable (String) -> Void

    private let session: URLSession
    private var streamTask: Task<Void, Never>?

    private let lock = NSLock()
    private var byContainer: [String: [ForwardedPort]] = [:]
    private var notedKeys: Set<String> = []

    init(dockerPort: Int,
         qmp: QMPClient,
         onPortsChanged: @escaping @Sendable ([ForwardedPort]) -> Void,
         onNote: @escaping @Sendable (String) -> Void)
    {
        self.dockerPort = dockerPort
        self.qmp = qmp
        self.onPortsChanged = onPortsChanged
        self.onNote = onNote

        // The /events response is an infinite chunked stream; the default
        // 60s idle timeout would kill it whenever no containers churn.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 24 * 3600
        cfg.timeoutIntervalForResource = 365 * 24 * 3600
        self.session = URLSession(configuration: cfg)
    }

    func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stop watching. Does not tear down existing hostfwd rules — on VM
    /// shutdown they die with qemu anyway, and on watcher restart the
    /// reconcile pass adopts a clean slate.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Main loop

    private func run() async {
        while !Task.isCancelled {
            do {
                try await reconcile()
                try await streamEvents()
            } catch {
                // fall through to retry
            }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - Reconcile

    /// Bring the forward set in line with the currently running
    /// containers (missed events while disconnected, containers started
    /// before the watcher).
    private func reconcile() async throws {
        let list = try await getJSON("/containers/json") as? [[String: Any]] ?? []

        var desired: [String: (name: String, ports: [(proto: String, port: Int)])] = [:]
        for c in list {
            guard let id = c["Id"] as? String else { continue }
            let name = (c["Names"] as? [String])?.first
                .map { String($0.dropFirst()) }              // strip leading "/"
                ?? String(id.prefix(12))
            var ports: [(String, Int)] = []
            for p in c["Ports"] as? [[String: Any]] ?? [] {
                guard let pub = p["PublicPort"] as? Int,
                      let proto = p["Type"] as? String
                else { continue }
                ports.append((proto, pub))
            }
            desired[id] = (name, ports)
        }

        lock.lock()
        let current = byContainer
        lock.unlock()

        for id in current.keys where desired[id] == nil {
            removeForwards(for: id)
        }
        for (id, info) in desired where current[id] == nil {
            addForwards(for: id, name: info.name, ports: info.ports)
        }
        publish()
    }

    // MARK: - Event stream

    private func streamEvents() async throws {
        var comps = URLComponents(string: "http://127.0.0.1:\(dockerPort)/events")!
        comps.queryItems = [
            URLQueryItem(name: "filters", value: #"{"type":["container"]}"#),
        ]
        let (bytes, response) = try await session.bytes(from: comps.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let id = obj["id"] as? String
            else { continue }
            let action = obj["Action"] as? String
                ?? obj["status"] as? String
                ?? ""
            switch action {
            case "start":
                await handleContainerStart(id: id)
            case "die":
                removeForwards(for: id)
                publish()
            default:
                break
            }
        }
    }

    private func handleContainerStart(id: String) async {
        guard let info = try? await getJSON("/containers/\(id)/json") as? [String: Any]
        else { return }

        let name = (info["Name"] as? String).map { String($0.dropFirst()) }
            ?? String(id.prefix(12))

        // NetworkSettings.Ports: { "80/tcp": [ {HostIp, HostPort}, … ] | null }
        var ports: [(proto: String, port: Int)] = []
        let netSettings = info["NetworkSettings"] as? [String: Any]
        for (key, value) in netSettings?["Ports"] as? [String: Any] ?? [:] {
            guard let bindings = value as? [[String: Any]] else { continue }
            let proto = key.split(separator: "/").last.map(String.init) ?? "tcp"
            for b in bindings {
                guard let hostPortStr = b["HostPort"] as? String,
                      let hostPort = Int(hostPortStr)
                else { continue }
                ports.append((proto, hostPort))
            }
        }

        addForwards(for: id, name: name, ports: ports)
        publish()
    }

    // MARK: - Forward add/remove

    private func addForwards(for id: String, name: String,
                             ports: [(proto: String, port: Int)])
    {
        var added: [ForwardedPort] = []
        var seen = Set<String>()
        for (proto, port) in ports {
            let key = "\(proto):\(port)"
            guard seen.insert(key).inserted else { continue }  // v4+v6 dupes
            do {
                if let err = try qmp.hostfwdAdd(proto: proto,
                                                hostPort: port,
                                                guestPort: port)
                {
                    note("Port \(port)/\(proto) for \(name) not forwarded: \(err)")
                } else {
                    added.append(ForwardedPort(proto: proto, port: port,
                                               container: name))
                }
            } catch {
                note("Port \(port)/\(proto) for \(name) not forwarded: \(error.localizedDescription)")
            }
        }
        lock.lock()
        byContainer[id] = added   // record even when empty so reconcile diffs work
        lock.unlock()
    }

    private func removeForwards(for id: String) {
        lock.lock()
        let ports = byContainer.removeValue(forKey: id) ?? []
        lock.unlock()
        for fp in ports {
            try? qmp.hostfwdRemove(proto: fp.proto, hostPort: fp.port)
        }
    }

    private func publish() {
        lock.lock()
        let all = byContainer.values
            .flatMap { $0 }
            .sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
        lock.unlock()
        onPortsChanged(all)
    }

    private func note(_ message: String) {
        lock.lock()
        let isNew = notedKeys.insert(message).inserted
        lock.unlock()
        if isNew { onNote(message) }
    }

    // MARK: - Docker API helpers

    private func getJSON(_ path: String) async throws -> Any {
        guard let url = URL(string: "http://127.0.0.1:\(dockerPort)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
