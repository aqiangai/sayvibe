import Foundation
import Network

actor LanScanner {
    func scan(localIP: String, relayPort: UInt16) async -> [LanDevice] {
        guard let subnetPrefix = LocalNetwork.subnetPrefix(for: localIP) else {
            return []
        }

        let hosts = (1...254)
            .map { "\(subnetPrefix).\($0)" }
            .filter { $0 != localIP }

        var found: [LanDevice] = []
        let batchSize = 24

        for start in stride(from: 0, to: hosts.count, by: batchSize) {
            if Task.isCancelled { break }

            let chunk = Array(hosts[start..<min(start + batchSize, hosts.count)])
            let scanned = await withTaskGroup(of: LanDevice?.self, returning: [LanDevice].self) { group in
                for ip in chunk {
                    group.addTask {
                        if Task.isCancelled { return nil }
                        let relayPortOpen = await Self.isPortOpen(ip: ip, port: relayPort, timeout: 0.20)
                        guard relayPortOpen else { return nil }

                        let hostName = LocalNetwork.reverseDNS(for: ip)
                        return LanDevice(ip: ip, hostName: hostName, relayPortOpen: relayPortOpen)
                    }
                }

                var devices: [LanDevice] = []
                for await device in group {
                    if let device {
                        devices.append(device)
                    }
                }
                return devices
            }

            found.append(contentsOf: scanned)
        }

        let unique = Dictionary(grouping: found, by: \.ip).compactMap { $0.value.first }
        return unique.sorted {
            if $0.relayPortOpen != $1.relayPortOpen {
                return $0.relayPortOpen && !$1.relayPortOpen
            }
            return LocalNetwork.ipSortValue($0.ip) < LocalNetwork.ipSortValue($1.ip)
        }
    }

    private static func isPortOpen(ip: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "sayvibe.scan.\(ip).\(port)")
            let connection = NWConnection(
                host: NWEndpoint.Host(ip),
                port: NWEndpoint.Port(rawValue: port) ?? .http,
                using: .tcp
            )

            let state = ProbeState()

            @Sendable func finish(_ result: Bool) {
                guard state.markResolved() else { return }
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed(_), .cancelled:
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}

private final class ProbeState: @unchecked Sendable {
    private var resolved = false
    private let lock = NSLock()

    func markResolved() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if resolved {
            return false
        }

        resolved = true
        return true
    }
}
