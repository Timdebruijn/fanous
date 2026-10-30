// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Darwin
import FanousCore
import Foundation

/// Runtime facts about this machine. Phase 0 only logs them; tiers come in Phase 2.
public enum SystemInfo {
    public static var chipName: String { sysctlString("machdep.cpu.brand_string") ?? "unknown" }
    public static var physicalMemoryBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }
    public static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    public static var hostName: String { ProcessInfo.processInfo.hostName }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Non-loopback IPv4 addresses of all interfaces, for the certificate's SAN.
    public static var ipv4Addresses: [String] { ipv4Interfaces.filter { !$0.loopback }.map(\.address) }

    /// Every IPv4 address with its interface and netmask, loopback included (universe interfaces, B28).
    public static var ipv4Interfaces: [NetworkInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        // a netmask's sa_len may be cut after its last non-zero byte: bytes past it are zero
        func numeric(_ address: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let address else { return nil }
            let length = Int(address.pointee.sa_len)
            return UnsafeRawPointer(address).withMemoryRebound(to: UInt8.self, capacity: max(length, 8)) { bytes in
                (4..<8).map { $0 < length ? String(bytes[$0]) : "0" }.joined(separator: ".")
            }
        }
        var result: [NetworkInterface] = []
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard entry.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET), let address = numeric(entry.pointee.ifa_addr),
                let netmask = numeric(entry.pointee.ifa_netmask)
            else { continue }
            let flags = entry.pointee.ifa_flags
            let loopback = flags & UInt32(IFF_LOOPBACK) != 0
            let multicast = flags & UInt32(IFF_MULTICAST) != 0 && !loopback && flags & UInt32(IFF_UP) != 0
            let broadcast = flags & UInt32(IFF_BROADCAST) != 0
            result.append(
                NetworkInterface(
                    name: String(cString: entry.pointee.ifa_name), address: address, netmask: netmask, multicast: multicast, broadcast: broadcast,
                    loopback: loopback))
        }
        return result
    }
}
