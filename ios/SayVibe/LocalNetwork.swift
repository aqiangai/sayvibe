import Foundation
import Darwin

enum LocalNetwork {
    static func resolveLocalIPv4() -> String? {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let first = addressPointer else {
            return nil
        }

        defer { freeifaddrs(addressPointer) }

        var candidates: [(interface: String, ip: String, score: Int)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let family = interface.ifa_addr?.pointee.sa_family
            let interfaceName = String(cString: interface.ifa_name)

            if
                family == UInt8(AF_INET),
                (flags & IFF_UP) != 0,
                (flags & IFF_LOOPBACK) == 0,
                let addr = interface.ifa_addr
            {
                let host = numericHost(from: addr)
                guard
                    !host.isEmpty,
                    !host.hasPrefix("169.254."),
                    !host.hasPrefix("127.")
                else {
                    pointer = interface.ifa_next
                    continue
                }

                let score = interfacePriorityScore(interfaceName: interfaceName, ip: host)
                candidates.append((interfaceName, host, score))
            }

            pointer = interface.ifa_next
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return ipSortValue(lhs.ip) < ipSortValue(rhs.ip)
            }
            .first?
            .ip
    }

    static func subnetPrefix(for ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.dropLast().map(String.init).joined(separator: ".")
    }

    static func isValidIPv4(_ ip: String) -> Bool {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let value = Int(part), (0...255).contains(value) else {
                return false
            }
        }
        return true
    }

    static func reverseDNS(for ip: String) -> String {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)

        let converted = ip.withCString { inet_pton(AF_INET, $0, &socketAddress.sin_addr) }
        guard converted == 1 else { return "" }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getnameinfo(
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.size),
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NAMEREQD
                )
            }
        }

        guard result == 0 else { return "" }

        let host = String(cString: hostBuffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        return host == ip ? "" : host
    }

    static func ipSortValue(_ ip: String) -> UInt32 {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return UInt32.max }

        var result: UInt32 = 0
        for part in parts {
            guard let value = UInt32(part), value <= 255 else {
                return UInt32.max
            }
            result = (result << 8) + value
        }
        return result
    }

    private static func numericHost(from address: UnsafeMutablePointer<sockaddr>) -> String {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)

        let result = getnameinfo(
            address,
            length,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else { return "" }
        return String(cString: hostBuffer)
    }

    private static func interfacePriorityScore(interfaceName: String, ip: String) -> Int {
        var score = 0

        if interfaceName == "en0" {
            score += 1000
        } else if interfaceName.hasPrefix("en") {
            score += 700
        } else if interfaceName.hasPrefix("bridge") {
            score += 300
        } else if interfaceName.hasPrefix("pdp_ip") {
            score -= 400
        }

        if
            interfaceName.hasPrefix("utun")
            || interfaceName.hasPrefix("ipsec")
            || interfaceName.hasPrefix("llw")
            || interfaceName.hasPrefix("awdl")
            || interfaceName.hasPrefix("gif")
            || interfaceName.hasPrefix("stf")
        {
            score -= 900
        }

        if isPrivateIPv4(ip) {
            score += 150
        } else {
            score -= 200
        }

        if ip.hasPrefix("192.168.") {
            score += 40
        } else if isRFC172Private(ip) {
            score += 25
        } else if ip.hasPrefix("10.") {
            score += 10
        }

        return score
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || isRFC172Private(ip)
    }

    private static func isRFC172Private(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        guard parts[0] == "172", let second = Int(parts[1]) else { return false }
        return (16...31).contains(second)
    }
}
