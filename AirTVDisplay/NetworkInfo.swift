import Foundation
import Darwin

enum NetworkInfo {
    /// MAC of en0 as "aa:bb:cc:dd:ee:ff" (stable deviceid, same source as stock UxPlay on the iMac).
    static func en0MAC() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: p.pointee.ifa_name) == "en0" else { continue }
            let mac: String? = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                let nlen = Int(dl.pointee.sdl_nlen), alen = Int(dl.pointee.sdl_alen)
                guard alen == 6 else { return nil }
                let base = UnsafeRawPointer(dl).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!)
                let b = base.assumingMemoryBound(to: UInt8.self)
                return (0..<alen).map { String(format: "%02x", b[nlen + $0]) }.joined(separator: ":")
            }
            if let mac { return mac }
        }
        return nil
    }

    /// First IPv4 on an enN interface, preferring en0 then en1.
    static func primaryIPv4() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var found: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found["en0"] ?? found["en1"] ?? found.values.first
    }
}
