// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import CoreGraphics
import Foundation
import ImageIO
import FanousCore
import Logging
import Metal
import Synchronization
import UniformTypeIdentifiers

/// Live inputs (Syphon in v1; NDI/DeckLink plugins later) hand the compositor
/// their newest texture; the compositor samples it directly (DESIGN.md §4.1).
public protocol LiveTextureSource: AnyObject, Sendable {
    var latestTexture: MTLTexture? { get }
    func stop()
}

/// Stills: decoded once by ImageIO into a resident straight-alpha RGBA texture.
public enum StillSource {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp", "exr"]

    public static func load(url: URL, device: MTLDevice) throws -> DecodedFrame {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw MovieError.noSample }
        let width = image.width, height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw MovieError.noSample }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // ponytail: 8-bit sRGB only; 16-bit stills (rgba16Unorm) when a show needs them.
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw MovieError.noSample }
        // the layer shader expects straight alpha (it premultiplies by alpha × intensity itself)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / a))
                pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / a))
                pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / a))
            }
        }
        let texture = try MovieSource.makeTexture(device, .rgba8Unorm, width, height)
        texture.label = url.lastPathComponent
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let frame = DecodedFrame(poolIndex: 0)
        frame.frameIndex = 0
        frame.kind = .rgba
        frame.texture0 = texture
        return frame
    }
}

/// An invisible layer (intensity × master × weight = 0) keeps its ring and last frame but stops asking the decoder
/// for more after `holdAfter` seconds; the first visible tick resumes the requests. The play clock is not involved.
struct InvisibilityHold {
    static let holdAfter = 2.0
    private var since: Double?

    /// False while the layer has been invisible for `holdAfter` seconds or more.
    mutating func allowsRequests(visible: Bool, at time: Double) -> Bool {
        if visible {
            since = nil
            return true
        }
        guard let since else {
            since = time
            return true
        }
        return time - since < Self.holdAfter
    }
}

/// One piece of media playing on a layer slot: a movie (decoder + ring), a
/// still, or a live input. Touched by the compositor thread only, except
/// `stop()` (media loader, after the compositor has let go of it).
public final class LayerPlayback: @unchecked Sendable {
    public let key: MediaKey
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let frameCount: Int
    public let movie: MovieSource?
    public let decoder: LayerDecoder?
    public let ring: FrameRing?
    public let still: DecodedFrame?
    public let live: (any LiveTextureSource)?
    private let liveFrame = DecodedFrame(poolIndex: 0)
    var clock = LayerClock()
    var hold = InvisibilityHold()
    var currentShown = -1
    var previousShown = -1
    var holdFrame: DecodedFrame?
    /// The mixer channel this playback's decoder fills (movies with an audio track only).
    public var audioChannel: LayerAudioChannel? { decoder?.audio?.channel }

    public init(key: MediaKey, movie: MovieSource, decoder: LayerDecoder, ring: FrameRing) {
        self.key = key
        self.movie = movie
        self.decoder = decoder
        self.ring = ring
        still = nil
        live = nil
        width = movie.info.width
        height = movie.info.height
        frameRate = movie.info.frameRate
        frameCount = movie.info.frameCount
    }

    public init(key: MediaKey, still: DecodedFrame) {
        self.key = key
        self.still = still
        movie = nil
        decoder = nil
        ring = nil
        live = nil
        width = still.texture0?.width ?? 1
        height = still.texture0?.height ?? 1
        frameRate = 1
        frameCount = 1
    }

    public init(key: MediaKey, live: any LiveTextureSource) {
        self.key = key
        self.live = live
        movie = nil
        decoder = nil
        ring = nil
        still = nil
        width = 0  // taken from the texture each tick
        height = 0
        frameRate = 1
        frameCount = 1
        liveFrame.kind = .rgba
    }

    /// True once something can be drawn: a still, a live texture, or a decoded ring frame.
    var hasFrame: Bool {
        if still != nil { return true }
        if let live { return live.latestTexture != nil }
        return !(ring?.isEmpty ?? true)
    }

    /// The frame to draw for media frame `index` (compositor thread).
    func frame(at index: Int, direction: Int) -> DecodedFrame? {
        if let still { return still }
        if let live {
            liveFrame.texture0 = live.latestTexture
            return liveFrame.texture0 == nil ? nil : liveFrame
        }
        return select(index: index, direction: direction)
    }

    /// Picks the ring frame for `index`, releasing frames that are no longer
    /// needed. The previously shown frame is kept one tick for the GPU.
    private func select(index: Int, direction: Int) -> DecodedFrame? {
        guard let ring else { return nil }
        var freed = false
        defer { if freed { decoder?.nudge() } }  // a slot is free again: the decode thread may be asleep on a full ring
        let n = frameCount
        func behind(_ f: Int) -> Int { direction > 0 ? (index - f + n) % n : (f - index + n) % n }
        while ring.count > 1, let head = ring.peek(0), let next = ring.peek(1) {
            if head.frameIndex == previousShown || head.frameIndex == currentShown { break }
            if behind(next.frameIndex) <= behind(head.frameIndex) {
                ring.pop()
                freed = true
            } else {
                break
            }
        }
        guard ring.count > 0 else { return holdFrame }
        var best: DecodedFrame?
        for i in 0..<min(ring.count, 3) {
            guard let f = ring.peek(i) else { break }
            if best == nil || behind(f.frameIndex) < behind(best!.frameIndex) { best = f }
        }
        guard let best, behind(best.frameIndex) < ring.capacity + 2 else {
            if holdFrame == nil { holdFrame = best }  // never shown (held invisible): better a stale picture than none until the seek lands
            freed = true
            ring.drain()  // everything buffered is on the wrong side of a seek
            return holdFrame
        }
        if best.frameIndex != currentShown {
            previousShown = currentShown
            currentShown = best.frameIndex
        }
        holdFrame = best
        return best
    }

    /// Lets go of the audio channel (compositor at retire, loader at stop): silence, no producer.
    func releaseAudio() {
        guard let decoder, let channel = decoder.audio?.channel else { return }
        decoder.audioEnabled.store(false, ordering: .relaxed)
        channel.setState(wantedPTS: 0, active: false, volume: 0, pan: 0)
    }

    public func stop() {
        releaseAudio()
        decoder?.stop()
        live?.stop()
    }
}

/// Hand-off box between the media loader and the compositor.
struct PendingPlayback {
    var set = false
    var playback: LayerPlayback?
}

/// One layer slot: the playing media, the outgoing one during a dissolve, and
/// the lock-free hand-off with the media loader (compositor thread owns the
/// `var`s).
/// What the UI shows per layer (`live.layers`): written by the loader when media opens or fails.
public struct LayerMediaStatus: Sendable, Equatable {
    public var folder = 0
    public var file = 0
    public var name: String? = nil
    /// movie, still, live, none, missing
    public var kind = "none"
    public var codec = ""
    public var width = 0
    public var height = 0
    public var fps = 0.0
    public var frames = 0
    public var error: String? = nil
    public init() {}
}

public final class RenderLayer: @unchecked Sendable {
    public let index: Int  // 0-based layer slot
    public let mediaStatus = Mutex<LayerMediaStatus>(LayerMediaStatus())
    var current: LayerPlayback?
    var outgoing: LayerPlayback?
    /// Loaded but not yet shown: becomes `current` once its first frame is decoded (DESIGN.md §4.2).
    var staged: LayerPlayback?
    var dissolveStart = 0.0
    var dissolveDuration = 0.0
    var retriggerLatched = false
    /// Packed MediaKey the compositor wants; the loader compares it with what it loaded last.
    let wanted = Atomic<UInt32>(0)
    /// Set by the loader; the compositor takes it with `withLockIfAvailable` (never blocks).
    let pending = Mutex(PendingPlayback())
    /// Playbacks the compositor has let go of; the loader stops and releases them.
    let retired = Mutex<[LayerPlayback]>([])
    var retireLater: [LayerPlayback] = []

    public init(index: Int) {
        self.index = index
        retireLater.reserveCapacity(4)
    }

    public var currentMedia: MediaKey? { current?.key }
    /// Frame index of the playing media for the UI's position display.
    /// ponytail: unsynchronised read of a compositor-owned value; a stale frame number for one 100 ms tick is harmless.
    public var currentFrame: Int { Int(current?.clock.position ?? 0) }
}

/// Media as a scene addresses it: (folder, file) → a file or a live input.
/// Phase 4 replaces the explicit list with the library index (DESIGN.md §8).
public struct MediaEntry: Codable, Sendable, Equatable {
    public var folder: Int
    public var file: Int
    public var path: String?
    /// Syphon server as "App name/Server name" (folder 0, DESIGN.md §8.2).
    public var syphon: String?

    public init(folder: Int, file: Int, path: String? = nil, syphon: String? = nil) {
        self.folder = folder
        self.file = file
        self.path = path
        self.syphon = syphon
    }

    public var key: MediaKey { MediaKey(folder: folder, file: file) }
}

/// Control-side thread that opens media the compositor asks for and releases
/// what it has dropped (DESIGN.md §4.2: file changes never touch the
/// compositor thread). One per render service.
public final class MediaLoader: @unchecked Sendable {
    public let wake = DispatchSemaphore(value: 0)
    private let layers: [RenderLayer]
    private let media: [MediaKey: MediaEntry]
    private let device: MTLDevice
    private let ringCapacity: Int
    private let logger: Logger
    private let running = Atomic<Bool>(true)
    private var loaded: [UInt32]
    private var thread: Thread?
    /// Creates live inputs ("App/Server" for Syphon); nil until the Syphon wiring is installed.
    public var liveFactory: (@Sendable (String) -> (any LiveTextureSource)?)?
    /// Folder 0 generators (file 100+); nil in tests without a Metal context.
    public var generatorFactory: (@Sendable (Int) -> (any LiveTextureSource)?)?
    /// Two mixer channels per layer slot (the playing media and the one dissolving out); nil = no audio.
    public var mixer: AudioMixer?
    /// Library lookup for keys the scene's explicit list does not cover (DESIGN.md §7.4).
    public var resolver: (@Sendable (MediaKey) -> URL?)?
    private var parity: [Int]
    public let opened = Atomic<Int>(0)
    public let failures = Atomic<Int>(0)

    public init(layers: [RenderLayer], media: [MediaEntry], device: MTLDevice, ringCapacity: Int, logger: Logger) {
        self.layers = layers
        self.media = Dictionary(media.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        self.device = device
        self.ringCapacity = ringCapacity
        self.logger = logger
        loaded = Array(repeating: 0, count: layers.count)
        parity = Array(repeating: 0, count: layers.count)
    }

    public func start() {
        let thread = Thread { [self] in loop() }
        thread.name = "org.fanous.media"
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
    }

    public func stop() {
        running.store(false, ordering: .relaxed)
        wake.signal()
    }

    private func loop() {
        while running.load(ordering: .relaxed) {
            _ = wake.wait(timeout: .now() + .milliseconds(100))
            for (i, layer) in layers.enumerated() {
                let retired = layer.retired.withLock { list -> [LayerPlayback] in
                    let copy = list
                    list.removeAll(keepingCapacity: true)
                    return copy
                }
                for playback in retired { playback.stop() }
                let want = layer.wanted.load(ordering: .relaxed)
                guard want != loaded[i] else { continue }
                loaded[i] = want
                let playback = autoreleasepool { open(MediaKey(packed: want), layer: i) }
                layer.pending.withLock { box in
                    box.playback?.stop()  // replaced before the compositor took it
                    box.set = true
                    box.playback = playback
                }
            }
        }
        for layer in layers {
            layer.pending.withLock { box in
                box.playback?.stop()
                box.playback = nil
                box.set = false
            }
        }
    }

    private func open(_ key: MediaKey, layer: Int) -> LayerPlayback? {
        var status = LayerMediaStatus()
        status.folder = key.folder
        status.file = key.file
        defer { layers[layer].mediaStatus.withLock { $0 = status } }
        guard !key.isNone else { return nil }
        if Generators.isGenerator(key), let generator = generatorFactory?(key.file) {
            opened.wrappingAdd(1, ordering: .relaxed)
            status.kind = "live"
            status.name = "Generator: \(Generators.names[key.file] ?? "\(key.file)")"
            if let texture = generator.latestTexture {
                status.width = texture.width
                status.height = texture.height
            }
            status.codec = "generator"
            return LayerPlayback(key: key, live: generator)
        }
        guard let entry = media[key] ?? resolver?(key).map({ MediaEntry(folder: key.folder, file: key.file, path: $0.path) }) else {
            logger.warning("media not found", metadata: ["layer": "\(layer + 1)", "media": "\(key)"])
            failures.wrappingAdd(1, ordering: .relaxed)
            status.kind = "missing"
            status.error = key.folder == 0
                ? "no built-in content \(key.file) in folder 0 (100–107, 110–113)"
                : "no file \(key.file) in folder \(key.folder)"
            return nil
        }
        do {
            if let syphon = entry.syphon {
                guard let live = liveFactory?(syphon) else { throw RenderError.pipeline("no live input for \(syphon)") }
                opened.wrappingAdd(1, ordering: .relaxed)
                status.kind = "live"
                status.name = "Syphon: \(syphon)"
                return LayerPlayback(key: key, live: live)
            }
            guard let path = entry.path else { throw RenderError.pipeline("media \(key) has no path") }
            let url = URL(fileURLWithPath: path)
            status.name = url.lastPathComponent
            if StillSource.extensions.contains(url.pathExtension.lowercased()) {
                let playback = LayerPlayback(key: key, still: try StillSource.load(url: url, device: device))
                opened.wrappingAdd(1, ordering: .relaxed)
                status.kind = "still"
                status.codec = url.pathExtension.lowercased()
                status.width = playback.width
                status.height = playback.height
                return playback
            }
            let source = try blocking { try await MovieSource.open(url: url, device: self.device, poolSize: self.ringCapacity) }
            let ring = FrameRing(capacity: ringCapacity)
            let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
            if let mixer, layer * 2 + 1 < mixer.channels.count {
                let reader = try blocking { try await AudioTrackReader.open(url: url) }
                if reader.hasAudio {
                    parity[layer] ^= 1
                    decoder.audio = (reader, mixer.channels[layer * 2 + parity[layer]])
                    mixer.ensureRunning()
                }
            }
            decoder.start(name: "org.fanous.decode.\(layer + 1)")
            decoder.request(frame: 0, direction: 1)
            opened.wrappingAdd(1, ordering: .relaxed)
            logger.info("layer \(layer + 1) media \(key)", metadata: ["file": "\(url.lastPathComponent)", "codec": "\(source.info.codecName)", "size": "\(source.info.width)x\(source.info.height)@\(source.info.frameRate)"])
            status.kind = "movie"
            status.codec = source.info.codecName
            status.width = source.info.width
            status.height = source.info.height
            status.fps = source.info.frameRate
            status.frames = source.info.frameCount
            return LayerPlayback(key: key, movie: source, decoder: decoder, ring: ring)
        } catch {
            logger.error("media open failed", metadata: ["layer": "\(layer + 1)", "media": "\(key)", "error": "\(error)"])
            failures.wrappingAdd(1, ordering: .relaxed)
            status.error = "\(error)"
            return nil
        }
    }

    /// `MovieSource.open` and `AudioTrackReader.open` are async (track loading); the loader thread is not a
    /// cooperative thread, so blocking it is fine.
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let box = Mutex<Result<T, Error>?>(nil)
        Task.detached(priority: .userInitiated) {
            let result: Result<T, Error>
            do { result = .success(try await body()) } catch { result = .failure(error) }
            box.withLock { $0 = result }
            done.signal()
        }
        done.wait()
        return try box.withLock { $0 }!.get()
    }
}
