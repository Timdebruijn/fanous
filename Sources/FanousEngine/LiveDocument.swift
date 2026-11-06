// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import FanousCore

// Sections of the `live` document, encoded through `JSONValue(encoding:)`. The keys are the wire names the web UI reads.

/// An optional that encodes as `null` instead of leaving its key out: the live document always carries the key.
@propertyWrapper
struct OrNull<Value: Encodable>: Encodable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

/// `live.metrics`: the 1-second summary, milliseconds to two decimals.
struct LiveMetrics: Encodable {
    var frames, missed, late, textureMisses, idle: Int
    var cpuP50, cpuP99, gpuP50, gpuP99, dmxP99: Double

    init(_ s: MetricsSummary) {
        func ms(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        (frames, missed, late, textureMisses, idle) = (s.frames, s.missed, s.late, s.textureMisses, s.idle)
        (cpuP50, cpuP99, gpuP50, gpuP99, dmxP99) = (ms(s.cpuP50), ms(s.cpuP99), ms(s.gpuP50), ms(s.gpuP99), ms(s.dmxP99))
    }
}

/// `live.library`: the snapshot's counts, without the folders themselves.
struct LiveLibrary: Encodable {
    var root: String
    var rootExists: Bool
    var folders, fileCount, invalidCount: Int
    var scannedAt: Double

    init(_ s: LibrarySnapshot) {
        (root, rootExists, folders, fileCount, invalidCount, scannedAt) = (s.root, s.rootExists, s.folders.count, s.fileCount, s.invalidCount, s.scannedAt)
    }
}

/// `live.layers[]`: the layer's media status, 1-based index.
struct LiveLayer: Encodable {
    var index, folder, file: Int
    @OrNull var name: String?
    var kind, codec: String
    var width, height: Int
    var fps: Double
    var frames, frame: Int
    @OrNull var error: String?
    @OrNull var pixelAspect: Double?
    var sync: JSONValue
    @OrNull var capture: CaptureInput.Counters?

    init(index: Int, status s: LayerMediaStatus, frame: Int, sync: JSONValue) {
        (self.index, folder, file, kind, codec, width, height, fps, frames) = (index + 1, s.folder, s.file, s.kind, s.codec, s.width, s.height, s.fps, s.frames)
        (self.frame, self.sync) = (frame, sync)
        (name, error, pixelAspect, capture) = (s.name, s.error, s.pixelAspect, s.capture)
    }
}

/// `live.displays[]`: at most 64 modes per display.
struct LiveDisplay: Encodable {
    var uuid, name: String
    var width, height: Int
    var hz: Double
    var main, builtin: Bool
    var modes: [DisplayModeConfig]

    init(_ d: DisplayInfo) {
        (uuid, name, width, height, hz, main, builtin) = (d.uuid, d.name, d.pixelWidth, d.pixelHeight, d.hz, d.isMain, d.isBuiltin)
        modes = Array(d.modes.prefix(64))
    }
}

/// `live.citp`, with both multicast groups a console may listen on.
struct LiveCITP: Encodable {
    var port: UInt16
    var clients: [String]
    var streams, beaconsDropped: Int
    var multicast = [CITPMulticast.address, CITPMulticast.addressSince2014]

    init(_ s: CITPServer.Status) { (port, clients, streams, beaconsDropped) = (s.port, s.clients, s.streams, s.beaconsDropped) }
}

/// `live.cue`.
struct LiveCue: Encodable {
    @OrNull var current: Double?
    @OrNull var currentName: String?
    @OrNull var next: Double?
    @OrNull var nextName: String?
    var fading: Bool
    var count: Int

    init(_ s: CueRunner.Status) { (current, currentName, next, nextName, fading, count) = (s.current, s.currentName, s.next, s.nextName, s.fading, s.count) }
}

/// `live.midi`: the map's problems joined into `error`.
struct LiveMIDI: Encodable {
    struct Learning: Encodable {
        var target: String
        @OrNull var cue: Double?
    }
    var connected: [String]
    @OrNull var last: String?
    @OrNull var lastAt: Double?
    @OrNull var learning: Learning?
    @OrNull var learned: String?
    @OrNull var error: String?

    init(_ s: MIDIInput.Status) {
        (connected, last, lastAt, learned) = (s.connected, s.last, s.lastAt, s.learned)
        learning = s.learning.map { Learning(target: $0.target, cue: $0.cue) }
        error = s.error == nil && s.problems.isEmpty ? nil : ([s.error].compactMap { $0 } + s.problems).joined(separator: "; ")
    }
}

/// `live.timecode`.
struct LiveTimecode: Encodable {
    var state, source, value, rate: String
    var frames, seen: Int
    @OrNull var error: String?
    var device: String
    /// The LTC channel's peak over the last tenth of a second (B137); null while LTC is not open.
    @OrNull var level: Double?
}
