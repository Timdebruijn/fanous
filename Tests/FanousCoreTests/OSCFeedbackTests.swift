// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Testing

@testable import FanousCore

extension OSCSubscriptions {
    /// Subscribe and ack in one go (the handshake has its own test).
    mutating func add(_ key: Key, prefix: String, now: Double) -> Bool {
        switch subscribe(key, prefix: prefix, cookie: "c\(key)\(prefix)", now: now) {
        case .renewed: true
        case .pending(let cookie): confirm(host: key.host, cookie: cookie, now: now) == key
        case .full: false
        }
    }
}

@Suite struct OSCFeedbackTests {
    @Test func requestsParse() {
        func r(_ address: String, _ args: [OSCArgument] = []) -> OSCFeedbackRequest? {
            OSCFeedback.request(for: OSCMessage(address, args))
        }
        #expect(r("/fanous/get") == .get(prefix: nil, port: nil))
        #expect(r("/fanous/get", [.int32(9000)]) == .get(prefix: nil, port: 9000))
        #expect(r("/fanous/layer/3/intensity/get") == .get(prefix: "/fanous/layer/3/intensity", port: nil))
        #expect(r("/fanous/layer/get", [.float32(9001)]) == .get(prefix: "/fanous/layer", port: 9001))
        #expect(
            r("/fanous/subscribe", [.string("10.0.0.5"), .int32(9000)])
                == .subscribe(host: "10.0.0.5", port: 9000, prefix: "/fanous"))
        #expect(
            r("/fanous/subscribe", [.string("10.0.0.5"), .int32(9000), .string("/fanous/cue/")])
                == .subscribe(host: "10.0.0.5", port: 9000, prefix: "/fanous/cue"))
        #expect(r("/fanous/unsubscribe") == .unsubscribe(host: nil, port: nil, prefix: nil))
        #expect(
            r("/fanous/unsubscribe", [.string("10.0.0.5"), .int32(9000)])
                == .unsubscribe(host: "10.0.0.5", port: 9000, prefix: nil))
        #expect(r("/fanous/ping") == .ping)
        #expect(r("/fanous/subscribe/ack", [.string("c0ffee")]) == .ack(cookie: "c0ffee"))
        #expect(r("/fanous/subscribe/ack") == nil)
        // malformed or not ours
        #expect(r("/fanous/subscribe", [.string("10.0.0.5")]) == nil)
        #expect(r("/fanous/subscribe", [.string("10.0.0.5"), .int32(0)]) == nil)
        #expect(r("/fanous/subscribe", [.string("10.0.0.5"), .int32(9000), .string("/other")]) == nil)
        #expect(r("/fanous/subscribe", [.string("10.0.0.5"), .int32(9000), .string("/fanousx")]) == nil)
        #expect(r("/other/get") == nil)
        #expect(r("/fanous/layer/1/intensity", [.float32(0.5)]) == nil)
        #expect(r("/fanous/cue/go") == nil)
    }

    /// What feedback sends is what a controller sends back to set the same value.
    @Test func parameterValuesRoundTripThroughTheAddressMap() throws {
        let specs = ChannelMap.specs(for: .layer)
        let raw = specs.enumerated().map { i, spec in UInt16(Int(spec.rawMax) * (i + 1) / (specs.count + 1)) }
        var state: OSCFeedback.State = [:]
        OSCFeedback.parameterValues(.layer(3), raw: raw, into: &state)
        for (spec, value) in zip(specs, raw) {
            let address = "/fanous/layer/3/\(spec.id.key)"
            let arguments = try #require(state[address])
            #expect(
                OSCAddressMap.command(for: OSCMessage(address, arguments))
                    == .setParameter(.layer(3), spec.id, raw: value))
        }
        let folder = raw[specs.firstIndex { $0.id == .layer(.folder) }!]
        let file = raw[specs.firstIndex { $0.id == .layer(.file) }!]
        #expect(state["/fanous/layer/3/media"] == [.int32(Int32(folder)), .int32(Int32(file))])
        #expect(
            OSCAddressMap.command(for: OSCMessage("/fanous/layer/3/media", state["/fanous/layer/3/media"]!))
                == .setMedia(layer: 3, folder: Int(folder), file: Int(file)))

        var output: OSCFeedback.State = [:]
        OSCFeedback.parameterValues(.output(2), raw: [65535, 0, 0, 0], into: &output)
        #expect(output["/fanous/output/2/intensity"] == [.float32(1)])
        #expect(output.keys.allSatisfy { !$0.contains("media") })
    }

    @Test func queryAnswersAPrefixOrTheSummary() {
        let state: OSCFeedback.State = [
            "/fanous/layer/1/intensity": [.float32(0.5)], "/fanous/layer/1/scaleX": [.float32(1)],
            "/fanous/layer/10/intensity": [.float32(0)],
            "/fanous/engine/version": [.string("1.0")], "/fanous/show/mode": [.int32(1)],
            "/fanous/cue/current": [.float32(2)],
        ]
        #expect(
            OSCFeedback.query("/fanous/layer/1", in: state).map(\.address) == [
                "/fanous/layer/1/intensity", "/fanous/layer/1/scaleX",
            ])
        #expect(
            OSCFeedback.query("/fanous/layer/1/intensity", in: state) == [
                OSCMessage("/fanous/layer/1/intensity", [.float32(0.5)])
            ])
        #expect(OSCFeedback.query("/fanous/nothing", in: state).isEmpty)
        #expect(
            OSCFeedback.query(nil, in: state).map(\.address) == [
                "/fanous/engine/version", "/fanous/show/mode", "/fanous/cue/current",
            ])

        var big: OSCFeedback.State = [:]
        for n in 1...400 { big["/fanous/layer/\(n)/intensity"] = [.float32(0)] }
        #expect(OSCFeedback.query("/fanous/layer", in: big).count == OSCFeedback.maxQueryMessages)
    }

    @Test func bundlesStayUnderTheLimitAndCarryImmediately() throws {
        let messages = (1...100).map { OSCMessage("/fanous/layer/\($0)/intensity", [.float32(Float($0) / 100)]) }
        let bundles = OSCFeedback.bundles(messages)
        #expect(bundles.count > 1)
        #expect(bundles.allSatisfy { $0.encoded().count <= OSCFeedback.maxBundleBytes })
        #expect(bundles.allSatisfy { $0.timetag == OSCPacket.immediately })
        var back: [OSCMessage] = []
        for bundle in bundles {
            let bytes = bundle.encoded()
            #expect(Array(bytes[8..<16]) == [0, 0, 0, 0, 0, 0, 0, 1])  // the timetag on the wire
            guard case .bundle(let parsed) = try OSCPacket.parse(bytes) else {
                Issue.record("not a bundle")
                continue
            }
            for case .message(let m) in parsed.elements { back.append(m) }
        }
        #expect(back == messages)
        #expect(OSCFeedback.bundles([]).isEmpty)
    }

    @Test func subscriptionsExpireUnlessRenewed() {
        var table = OSCSubscriptions(fixed: OSCFeedbackTarget(host: "10.0.0.9", port: 7000))
        let fixed = OSCSubscriptions.Key(host: "10.0.0.9", port: 7000)
        let a = OSCSubscriptions.Key(host: "10.0.0.5", port: 9000)
        let b = OSCSubscriptions.Key(host: "10.0.0.6", port: 9000)
        var ok = table.add(a, prefix: "/fanous", now: 0) && table.add(b, prefix: "/fanous", now: 0)
        #expect(ok)
        table.renew(host: "10.0.0.5", now: 50)  // a ping
        var gone = table.expire(now: 59.9)
        #expect(gone.isEmpty)
        gone = table.expire(now: 60)
        #expect(gone == [b])
        #expect(Set(table.keys) == [a, fixed])
        ok = table.add(a, prefix: "/fanous/cue", now: 100)  // another subscribe renews too
        gone = table.expire(now: 159)
        #expect(ok && gone.isEmpty)
        gone = table.expire(now: 1e9)
        #expect(gone == [a])
        #expect(table.keys == [fixed])  // the fixed target never expires, nor can it be unsubscribed
        table.unsubscribe(host: "10.0.0.9", port: nil, prefix: nil)
        #expect(table.keys == [fixed])
    }

    @Test func subscribersAreLimited() {
        var table = OSCSubscriptions(fixed: OSCFeedbackTarget(host: "10.0.0.9", port: 7000))
        let late = OSCSubscriptions.Key(host: "10.0.1.1", port: 9000)
        var accepted = (0..<OSCSubscriptions.limit).filter {
            table.add(.init(host: "10.0.0.\($0)", port: 9000), prefix: "/fanous", now: 0)
        }.count
        #expect(accepted == OSCSubscriptions.limit)  // the fixed target does not count
        var ok = table.add(late, prefix: "/fanous", now: 0)
        #expect(!ok)
        ok = table.add(.init(host: "10.0.0.1", port: 9000), prefix: "/fanous", now: 0)
        #expect(ok)  // renewal of a known one
        table.unsubscribe(host: "10.0.0.1", port: nil, prefix: nil)
        ok = table.add(late, prefix: "/fanous", now: 0)
        #expect(ok)
        accepted =
            (1..<OSCSubscriptions.maxPrefixes).filter { table.add(late, prefix: "/fanous/layer/\($0)", now: 0) }
            .count
        ok = table.add(late, prefix: "/fanous/layer/99", now: 0)
        #expect(accepted == OSCSubscriptions.maxPrefixes - 1 && !ok)
    }

    /// Ticks send only what changed under the prefixes, the latest value wins, and invalidate re-sends.
    @Test func changesAreCoalescedPerTick() {
        var table = OSCSubscriptions()
        let key = OSCSubscriptions.Key(host: "10.0.0.5", port: 9000)
        _ = table.add(key, prefix: "/fanous/cue", now: 0)
        var state: OSCFeedback.State = [
            "/fanous/cue/current": [.float32(1)], "/fanous/cue/count": [.int32(3)],
            "/fanous/layer/1/intensity": [.float32(0)],
        ]
        var sent = table.changes(in: state)
        #expect(sent[key]?.map(\.address) == ["/fanous/cue/count", "/fanous/cue/current"])  // the first tick syncs
        sent = table.changes(in: state)
        #expect(sent.isEmpty)
        // a desk moves a value five times between two ticks: one message, the last value
        for v in 1...5 { state["/fanous/cue/current"] = [.float32(Float(v) + 1)] }
        state["/fanous/layer/1/intensity"] = [.float32(1)]  // not subscribed
        sent = table.changes(in: state)
        #expect(sent[key] == [OSCMessage("/fanous/cue/current", [.float32(6)])])
        table.invalidate(prefix: "/fanous/cue")
        sent = table.changes(in: state)
        #expect(sent[key]?.count == 2)
    }

    /// A flood of changes is capped per subscriber per tick, rotating so nothing starves, and converges.
    @Test func floodIsCappedAndRotates() {
        var table = OSCSubscriptions()
        let key = OSCSubscriptions.Key(host: "10.0.0.5", port: 9000)
        _ = table.add(key, prefix: "/fanous", now: 0)
        var state: OSCFeedback.State = [:]
        let count = OSCSubscriptions.maxMessagesPerTick * 2 + 50
        for n in 0..<count { state["/fanous/x/\(n)"] = [.int32(0)] }
        var seen: Set<String> = []
        for _ in 0..<3 {
            let sent = table.changes(in: state)[key] ?? []
            #expect(sent.count <= OSCSubscriptions.maxMessagesPerTick)
            seen.formUnion(sent.map(\.address))
        }
        #expect(seen.count == count)
        let rest = table.changes(in: state)
        #expect(rest.isEmpty)
    }

    /// A subscription streams only after its cookie came back from the same host; pending ones take no slot.
    @Test func subscribeNeedsTheCookieBack() {
        var table = OSCSubscriptions()
        let key = OSCSubscriptions.Key(host: "10.0.0.5", port: 9000)
        var result = table.subscribe(key, prefix: "/fanous", cookie: "abc", now: 0)
        #expect(result == .pending(cookie: "abc"))
        #expect(table.isEmpty)  // nothing streams yet
        var confirmed = table.confirm(host: "10.0.0.6", cookie: "abc", now: 1)  // another host
        #expect(confirmed == nil)
        result = table.subscribe(key, prefix: "/fanous", cookie: "def", now: 0)
        confirmed = table.confirm(host: "10.0.0.5", cookie: "def", now: 1)
        #expect(confirmed == key && table.keys == [key])
        confirmed = table.confirm(host: "10.0.0.5", cookie: "def", now: 1)  // a cookie works once
        #expect(confirmed == nil)
        result = table.subscribe(key, prefix: "/fanous/cue", cookie: "ghi", now: 2)  // confirmed: a renewal
        #expect(result == .renewed)

        // a pending subscription is gone after 5 s
        let other = OSCSubscriptions.Key(host: "10.0.0.7", port: 9000)
        _ = table.subscribe(other, prefix: "/fanous", cookie: "late", now: 10)
        confirmed = table.confirm(host: "10.0.0.7", cookie: "late", now: 10 + OSCSubscriptions.pendingLifetime)
        #expect(confirmed == nil)

        // spoofed subscribes fill neither the 16 slots nor memory
        var spoof = OSCSubscriptions()
        let accepted = (0..<1000).filter { i in
            spoof.subscribe(
                .init(host: "10.9.\(i / 256).\(i % 256)", port: 9000), prefix: "/fanous", cookie: "s\(i)", now: 0)
                != .full
        }.count
        #expect(accepted == OSCSubscriptions.maxPending && spoof.isEmpty)
        let freed = spoof.add(key, prefix: "/fanous", now: OSCSubscriptions.pendingLifetime + 1)
        #expect(freed)  // free again once they expire
    }

    @Test func fixedTargetOutsideTheTreeIsIgnored() {
        #expect(OSCSubscriptions(fixed: OSCFeedbackTarget(host: "10.0.0.9", port: 7000, prefix: "/other")).isEmpty)
        #expect(
            !OSCSubscriptions(fixed: OSCFeedbackTarget(host: "10.0.0.9", port: 7000, prefix: "/fanous/cue")).isEmpty)
    }

    /// 10 requests a second per host with a burst of 20, and a shared cap over all hosts.
    @Test func requestsAreRateLimited() {
        var limiter = OSCRateLimiter()
        let burst = (0..<100).filter { _ in limiter.allow("10.0.0.5", now: 0) }.count
        #expect(burst == 20)
        let other = limiter.allow("10.0.0.6", now: 0)  // another host has its own bucket
        let tooSoon = limiter.allow("10.0.0.5", now: 0.05)
        let refilled = limiter.allow("10.0.0.5", now: 0.1)  // one token per 100 ms
        #expect(other && !tooSoon && refilled)
        let later = (0..<100).filter { _ in limiter.allow("10.0.0.5", now: 1.1) }.count
        #expect(later == 10)

        var spoofed = OSCRateLimiter()
        let total = (0..<5000).filter { i in spoofed.allow("10.\(i / 65536).\(i / 256 % 256).\(i % 256)", now: 0) }
            .count
        #expect(total == Int(OSCRateLimiter.total.burst))
    }
}
