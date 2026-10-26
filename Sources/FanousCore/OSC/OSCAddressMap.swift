// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

/// OSC address space generated from the channel map (DESIGN.md §15.3).
/// Values: float = normalized 0…1 of the raw range, int = raw DMX value.
public enum OSCCommand: Equatable, Sendable {
    case setParameter(FixtureRef, ParameterID, raw: UInt16)
    case setMedia(layer: Int, folder: Int, file: Int)
    case retrigger(layer: Int)
    case cueGo
    case cueBack
    case cueGoto(Double)
    case showLock(Bool)
    case showMode(Bool)
    case timecodeEnable(Bool)
    case projectLoad(String)
}

public enum OSCAddressMap {
    public static let prefix = "/fanous"

    public static func address(_ fixture: FixtureRef, _ parameter: ParameterID) -> String {
        switch fixture {
        case .layer(let n): "\(prefix)/layer/\(n)/\(parameter.key)"
        case .master: "\(prefix)/master/\(parameter.key)"
        case .output(let n): "\(prefix)/output/\(n)/\(parameter.key)"
        }
    }

    /// nil when the address is not ours or malformed.
    public static func command(for message: OSCMessage) -> OSCCommand? {
        guard message.address.hasPrefix(prefix + "/") else { return nil }
        let parts = message.address.dropFirst(prefix.count + 1).split(separator: "/").map(String.init)
        let args = message.arguments
        switch parts.first {
        case "layer":
            guard parts.count == 3, let n = Int(parts[1]), n >= 1 else { return nil }
            switch parts[2] {
            case "media":
                guard args.count >= 2, let folder = args[0].asDouble, let file = args[1].asDouble else { return nil }
                return .setMedia(layer: n, folder: safeInt(folder), file: safeInt(file))
            case "retrigger":
                return .retrigger(layer: n)
            default:
                return parameterCommand(.layer(n), parts[2], args)
            }
        case "master":
            guard parts.count == 2 else { return nil }
            return parameterCommand(.master, parts[1], args)
        case "output":
            guard parts.count == 3, let n = Int(parts[1]), n >= 1 else { return nil }
            return parameterCommand(.output(n), parts[2], args)
        case "cue":
            guard parts.count >= 2 else { return nil }
            switch (parts.count, parts[1]) {
            case (2, "go"): return .cueGo
            case (2, "back"): return .cueBack
            case (2, "goto"): return args.first?.asDouble.flatMap { $0.isFinite ? .cueGoto($0) : nil }
            case (3, _): return parts[2] == "go" ? Double(parts[1]).flatMap { $0.isFinite ? .cueGoto($0) : nil } : nil
            default: return nil
            }
        case "show":
            guard parts.count == 2, let flag = args.first?.asBool else { return nil }
            return parts[1] == "lock" ? .showLock(flag) : parts[1] == "mode" ? .showMode(flag) : nil
        case "timecode":
            guard parts.count == 2, parts[1] == "enable", let flag = args.first?.asBool else { return nil }
            return .timecodeEnable(flag)
        case "project":
            guard parts.count == 2, parts[1] == "load", case .string(let name)? = args.first else { return nil }
            return .projectLoad(name)
        default:
            return nil
        }
    }

    /// `Int(Double)` traps on NaN/inf/huge values, and OSC arrives unauthenticated: non-finite becomes 0, the rest is clamped.
    static func safeInt(_ d: Double) -> Int { d.isFinite ? Int(d.clamped(-1e9, 1e9)) : 0 }

    static func parameterCommand(_ fixture: FixtureRef, _ key: String, _ args: [OSCArgument]) -> OSCCommand? {
        guard let spec = ChannelMap.specs(for: fixture.mode).first(where: { $0.id.key == key }),
            let raw = raw(from: args.first, spec: spec)
        else { return nil }
        return .setParameter(fixture, spec.id, raw: raw)
    }

    static func raw(from argument: OSCArgument?, spec: ParameterSpec) -> UInt16? {
        let max = Double(spec.rawMax)
        switch argument {
        case .float32(let f): return UInt16((Double(f).clamped(0, 1) * max).rounded())
        case .double(let d): return UInt16((d.clamped(0, 1) * max).rounded())
        case .int32(let i): return UInt16(Double(i).clamped(0, max))
        case .int64(let i): return UInt16(Double(i).clamped(0, max))
        case .bool(let b): return b ? spec.rawMax : 0
        default: return nil
        }
    }
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}
