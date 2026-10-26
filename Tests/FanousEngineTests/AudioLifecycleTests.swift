// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Synchronization
import Testing

@testable import FanousEngine

/// The output device is opened on demand and closed after the last channel went quiet (no audio hardware involved).
@Suite(.serialized) struct AudioLifecycleTests {
    final class Counts: @unchecked Sendable {
        let starts = Atomic<Int>(0)
        let stops = Atomic<Int>(0)
    }

    static func mixer(counts: Counts, idleStop: Double = 0.5) -> AudioMixer {
        let mixer = AudioMixer(channels: 2)
        mixer.idleStopSeconds = idleStop
        mixer.startHook = { counts.starts.wrappingAdd(1, ordering: .relaxed) }
        mixer.stopHook = { counts.stops.wrappingAdd(1, ordering: .relaxed) }
        return mixer
    }

    static func wait(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func nothingStartsUntilAudioOpensOrAChannelTurnsActive() async throws {
        let counts = Counts()
        let mixer = Self.mixer(counts: counts)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!mixer.isRunning && counts.starts.load(ordering: .relaxed) == 0, "constructing a mixer opens no device")

        mixer.channels[0].setState(wantedPTS: 0, active: false, volume: 1, pan: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!mixer.isRunning, "an inactive channel does not start it")

        mixer.channels[0].setState(wantedPTS: 0, active: true, volume: 1, pan: 0)
        try await Self.wait(2) { mixer.isRunning }
        #expect(mixer.isRunning && counts.starts.load(ordering: .relaxed) == 1, "the first active channel starts it, once")
        mixer.channels[0].setState(wantedPTS: 0, active: true, volume: 1, pan: 0)
        mixer.ensureRunning()
        try await Task.sleep(for: .milliseconds(100))
        #expect(counts.starts.load(ordering: .relaxed) == 1)
        mixer.stop()
    }

    @Test func stopsAfterTheLastChannelWentInactiveAndRestartsOnDemand() async throws {
        let counts = Counts()
        let mixer = Self.mixer(counts: counts)
        mixer.channels[0].setState(wantedPTS: 0, active: true, volume: 1, pan: 0)
        try await Self.wait(2) { mixer.isRunning }
        #expect(mixer.isRunning)
        // still active: never stops
        try await Task.sleep(for: .milliseconds(2300))
        #expect(mixer.isRunning && counts.stops.load(ordering: .relaxed) == 0, "an active channel keeps the device open")
        mixer.channels[0].setState(wantedPTS: 0, active: false, volume: 1, pan: 0)
        try await Self.wait(4) { !mixer.isRunning }
        #expect(!mixer.isRunning && counts.stops.load(ordering: .relaxed) == 1, "closed once everything is quiet")
        // playing again opens it again
        mixer.channels[0].setState(wantedPTS: 0, active: true, volume: 1, pan: 0)
        try await Self.wait(2) { mixer.isRunning }
        #expect(mixer.isRunning && counts.starts.load(ordering: .relaxed) == 2)
        mixer.stop()
    }

    @Test func showModeKeepsItOpen() async throws {
        let counts = Counts()
        let mixer = Self.mixer(counts: counts)
        mixer.keepRunning = { true }
        mixer.ensureRunning()
        try await Self.wait(2) { mixer.isRunning }
        try await Task.sleep(for: .milliseconds(2500))
        #expect(mixer.isRunning && counts.stops.load(ordering: .relaxed) == 0, "show mode: never stopped, even with every channel quiet")
        mixer.keepRunning = { false }
        try await Self.wait(4) { !mixer.isRunning }
        #expect(!mixer.isRunning, "and it goes once show mode is off")
    }
}
