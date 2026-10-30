// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// Art-Net 4 (protocol version 14). Receiver side plus the builders tests and
/// discovery need. Art-Net™ Designed by and Copyright Artistic Licence Engineering Ltd.
public enum ArtNet {
    public static let port: UInt16 = 6454
    public static let header: [UInt8] = Array("Art-Net\0".utf8)
    public static let protocolVersion: UInt16 = 14

    public enum OpCode: UInt16, Sendable {
        case poll = 0x2000
        case pollReply = 0x2100
        case dmx = 0x5000
        case nzs = 0x5100
        case sync = 0x5200
    }

    public enum Packet: Equatable, Sendable {
        case poll(ArtPoll)
        case pollReply
        case dmx(ArtDmx)
        case sync
        case other(opCode: UInt16)
    }

    public enum ParseError: Error, Equatable { case tooShort, badHeader, badVersion, badLength }

    public static func parse(_ bytes: [UInt8]) throws -> Packet {
        guard bytes.count >= 10 else { throw ParseError.tooShort }
        guard Array(bytes[0..<8]) == header else { throw ParseError.badHeader }
        let opCode = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        switch OpCode(rawValue: opCode) {
        case .dmx:
            guard bytes.count >= 18 else { throw ParseError.tooShort }
            try checkVersion(bytes)
            let length = Int(bytes[16]) << 8 | Int(bytes[17])
            guard length >= 2, length <= 512, bytes.count >= 18 + length else { throw ParseError.badLength }
            let portAddress = UInt16(bytes[15] & 0x7F) << 8 | UInt16(bytes[14])
            return .dmx(ArtDmx(sequence: bytes[12], physical: bytes[13], portAddress: portAddress, data: Array(bytes[18..<18 + length])))
        case .poll:
            guard bytes.count >= 14 else { throw ParseError.tooShort }
            try checkVersion(bytes)
            return .poll(ArtPoll(flags: bytes[12], diagPriority: bytes[13]))
        case .pollReply:
            return .pollReply
        case .sync:
            guard bytes.count >= 14 else { throw ParseError.tooShort }
            try checkVersion(bytes)
            return .sync
        default:
            return .other(opCode: opCode)
        }
    }

    static func checkVersion(_ bytes: [UInt8]) throws {
        let version = UInt16(bytes[10]) << 8 | UInt16(bytes[11])
        guard version >= protocolVersion else { throw ParseError.badVersion }
    }

    static func opCodeBytes(_ op: OpCode) -> [UInt8] { [UInt8(op.rawValue & 0xFF), UInt8(op.rawValue >> 8)] }
}

public struct ArtPoll: Equatable, Sendable {
    public var flags: UInt8
    public var diagPriority: UInt8

    public init(flags: UInt8 = 0, diagPriority: UInt8 = 0) {
        self.flags = flags
        self.diagPriority = diagPriority
    }

    public func encoded() -> [UInt8] {
        ArtNet.header + ArtNet.opCodeBytes(.poll) + [0, UInt8(ArtNet.protocolVersion), flags, diagPriority]
    }
}

public struct ArtDmx: Equatable, Sendable {
    public var sequence: UInt8
    public var physical: UInt8
    /// 15-bit port-address: Net (7 bits) << 8 | Sub-Net (4 bits) << 4 | Universe (4 bits).
    public var portAddress: UInt16
    public var data: [UInt8]

    public init(sequence: UInt8 = 0, physical: UInt8 = 0, portAddress: UInt16, data: [UInt8]) {
        self.sequence = sequence
        self.physical = physical
        self.portAddress = portAddress & 0x7FFF
        self.data = Array(data.prefix(512))
    }

    public var universeID: UniverseID { UniverseID(.artnet, Int(portAddress)) }

    public func encoded() -> [UInt8] {
        var payload = data
        if payload.count < 2 { payload += [UInt8](repeating: 0, count: 2 - payload.count) }
        if payload.count % 2 == 1 { payload.append(0) }
        let length = payload.count
        return ArtNet.header + ArtNet.opCodeBytes(.dmx)
            + [0, UInt8(ArtNet.protocolVersion), sequence, physical, UInt8(portAddress & 0xFF), UInt8(portAddress >> 8)]
            + [UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }
}

/// ArtPollReply as a media server ("StMedia") with up to four output ports per
/// reply; more universes use BindIndex 1…n (ADR: one reply per Net/Sub-Net group).
public struct ArtPollReply: Equatable, Sendable {
    public struct Port: Equatable, Sendable {
        public var universe: UInt8  // low nibble of the port-address
        public var receiving: Bool
        public init(universe: UInt8, receiving: Bool) {
            self.universe = universe & 0xF
            self.receiving = receiving
        }
    }

    public var ipAddress: [UInt8]
    public var firmwareVersion: UInt16
    public var net: UInt8
    public var subnet: UInt8
    /// 0xFFFF until an OEM code is registered with Artistic Licence (DESIGN.md OPEN-25).
    public var oem: UInt16
    public var estaManufacturer: UInt16
    public var shortName: String
    public var longName: String
    public var nodeReport: String
    public var ports: [Port]
    public var mac: [UInt8]
    public var bindIndex: UInt8

    public static let styleMediaServer: UInt8 = 0x03
    public static let estaPrototype: UInt16 = 0x7FF0

    public init(
        ipAddress: [UInt8], firmwareVersion: UInt16 = 1, net: UInt8, subnet: UInt8, oem: UInt16 = 0xFFFF,
        estaManufacturer: UInt16 = estaPrototype, shortName: String, longName: String, nodeReport: String,
        ports: [Port], mac: [UInt8] = [0, 0, 0, 0, 0, 0], bindIndex: UInt8 = 1
    ) {
        precondition(ipAddress.count == 4 && mac.count == 6 && ports.count <= 4)
        self.ipAddress = ipAddress
        self.firmwareVersion = firmwareVersion
        self.net = net & 0x7F
        self.subnet = subnet & 0xF
        self.oem = oem
        self.estaManufacturer = estaManufacturer
        self.shortName = shortName
        self.longName = longName
        self.nodeReport = nodeReport
        self.ports = ports
        self.mac = mac
        self.bindIndex = bindIndex
    }

    /// One reply per group of four ports sharing Net and Sub-Net.
    public static func replies(
        universes: [UniverseID], ipAddress: [UInt8], shortName: String, longName: String, nodeReport: String,
        mac: [UInt8] = [0, 0, 0, 0, 0, 0], oem: UInt16 = 0xFFFF
    ) -> [ArtPollReply] {
        let addresses = universes.filter { $0.transport == .artnet }.map(\.number).sorted()
        var groups: [(net: UInt8, subnet: UInt8, universes: [UInt8])] = []
        for address in addresses {
            let net = UInt8(address >> 8), subnet = UInt8(address >> 4 & 0xF), universe = UInt8(address & 0xF)
            if let last = groups.indices.last, groups[last].net == net, groups[last].subnet == subnet,
                groups[last].universes.count < 4
            {
                groups[last].universes.append(universe)
            } else {
                groups.append((net, subnet, [universe]))
            }
        }
        if groups.isEmpty { groups = [(0, 0, [])] }
        return groups.enumerated().map { index, group in
            ArtPollReply(
                ipAddress: ipAddress, net: group.net, subnet: group.subnet, oem: oem, shortName: shortName, longName: longName,
                nodeReport: nodeReport, ports: group.universes.map { Port(universe: $0, receiving: true) }, mac: mac,
                bindIndex: UInt8(index + 1))
        }
    }

    public func encoded() -> [UInt8] {
        var out = ArtNet.header + ArtNet.opCodeBytes(.pollReply)
        out += ipAddress
        out += [0x36, 0x19]  // port 0x1936 little-endian
        out += [UInt8(firmwareVersion >> 8), UInt8(firmwareVersion & 0xFF)]
        out += [net, subnet]
        out += [UInt8(oem >> 8), UInt8(oem & 0xFF)]
        out += [0]  // UbeaVersion
        out += [0xD0]  // Status1: indicators normal, port-address set by network
        out += [UInt8(estaManufacturer & 0xFF), UInt8(estaManufacturer >> 8)]
        out += [UInt8].fixed(shortName, 18)
        out += [UInt8].fixed(longName, 64)
        out += [UInt8].fixed(nodeReport, 64)
        out += [0, UInt8(ports.count)]  // NumPorts
        var portTypes = [UInt8](repeating: 0, count: 4), goodInput = [UInt8](repeating: 0, count: 4)
        var goodOutput = [UInt8](repeating: 0, count: 4), swIn = [UInt8](repeating: 0, count: 4)
        var swOut = [UInt8](repeating: 0, count: 4)
        for (i, port) in ports.enumerated() {
            portTypes[i] = 0x80  // can output DMX512 from Art-Net (i.e. we consume ArtDmx)
            goodOutput[i] = port.receiving ? 0x80 : 0
            swOut[i] = port.universe
        }
        out += portTypes + goodInput + goodOutput + swIn + swOut
        out += [0, 0, 0]  // AcnPriority, SwMacro, SwRemote
        out += [0, 0, 0]  // Spare
        out += [Self.styleMediaServer]
        out += mac
        out += ipAddress  // BindIp
        out += [bindIndex]
        out += [0x08]  // Status2: 15-bit port-address supported
        out += [0, 0, 0, 0]  // GoodOutputB
        out += [0]  // Status3
        out += [0, 0, 0, 0, 0, 0]  // DefaultRespUID
        out += [0, 0, 0, 0, 0]  // User, RefreshRate, BackgroundQueuePolicy
        out += [UInt8](repeating: 0, count: 10)  // Filler
        assert(out.count == 239)
        return out
    }
}
