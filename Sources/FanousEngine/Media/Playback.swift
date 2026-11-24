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

/// A live input's newest frame: its plane(s) and how the layer shader reads them (DESIGN.md §8.2.1).
/// Class references and two small values: returning one allocates nothing.
public struct LiveFrame {
    public var texture0: MTLTexture
    /// The second plane (`.planarYCbCr`: CbCr as `rg8Unorm` beside a Y `r8Unorm`), nil for one-texture kinds.
    public var texture1: MTLTexture?
    /// `.rgba` (Syphon, generators, BGRA), `.v216` (8-bit `2vuy` as `rgba8Unorm` at half width), `.yuy2` (`yuvs`, the
    /// same with the pairs swapped) or `.planarYCbCr`.
    public var kind: SourcePixelKind
    /// Row 0 is the bottom of the picture (OpenGL order, as Syphon surfaces are): the compositor samples it upside
    /// down so the layer is upright.
    public var bottomUp: Bool

    public init(texture0: MTLTexture, texture1: MTLTexture? = nil, kind: SourcePixelKind = .rgba, bottomUp: Bool = false) {
        self.texture0 = texture0
        self.texture1 = texture1
        self.kind = kind
        self.bottomUp = bottomUp
    }
}

/// Live inputs (Syphon, generators; cameras and screens next, NDI/DeckLink plugins later) hand the compositor
/// their newest frame; the compositor samples it directly (DESIGN.md §4.1).
public protocol LiveTextureSource: AnyObject, Sendable {
    /// The newest frame, nil before the first one. One read per tick: a source that swaps frames on another thread
    /// returns the planes, kind and orientation of one frame together (under its own lock), never a mix of two.
    var latestFrame: LiveFrame? { get }
    func stop()
}

/// Stills: decoded once by ImageIO into a resident straight-alpha RGBA texture.
public enum StillSource {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp", "exr"]

    /// The file's first image as ImageIO decodes it; nil when it does not (a layer's still, an image mask).
    static func image(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    public static func load(url: URL, device: MTLDevice) throws -> DecodedFrame {
        guard let image = image(url) else { throw MovieError.noSample }
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
    /// Shown width of one pixel over its height (anamorphic movies, `MovieInfo.pixelAspect`); 1 for stills and live inputs.
    public let pixelAspect: Double
    public let frameRate: Double
    public let frameCount: Int
    public let decoder: LayerDecoder?
    public let ring: FrameRing?
    public let still: DecodedFrame?
    public let live: (any LiveTextureSource)?
    /// The media as upright RGBA at its own size with four mip levels, written by the compositor's convert pass on a
    /// tick where the layer blurs or edges and read by those taps (DESIGN.md §4.3, B2). Made the first time the layer
    /// asks for one (the loader allocates on its thread, the compositor adopts it on a later tick; until then, and for
    /// a live input, the draw samples the source per tap as before). Compositor thread owns both `var`s.
    public private(set) var scratch: MTLTexture?
    /// One single-level view per level of `scratch`, made with it: the compositor's downsample kernel reads level
    /// n − 1 and writes level n through these (B2). Empty when any view could not be made: the taps then read level 0.
    public private(set) var scratchLevels: [MTLTexture] = []
    /// Compositor thread: a scratch texture was asked of the loader (once per playback; a refusal leaves the source path).
    var scratchRequested = false

    /// The compositor takes the loader's texture (B2): two stores, no allocation.
    public func adopt(_ set: ScratchSet?) {
        scratch = set?.texture
        scratchLevels = set?.levels ?? []
    }

    /// The scratch texture for a media of this size (B2): canvas format, four mip levels (the blur reads up to 1/8),
    /// private storage, with every level as a single-level view. Nil when Metal refuses the texture or any view (the
    /// layer then draws without one).
    public static func makeScratchSet(device: MTLDevice, width: Int, height: Int) -> ScratchSet? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: width, height: height, mipmapped: true)
        descriptor.mipmapLevelCount = min(4, descriptor.mipmapLevelCount)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]  // the downsample kernel writes the mip levels
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "scratch"
        let levels = (0..<texture.mipmapLevelCount).compactMap {
            texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D, levels: $0..<($0 + 1), slices: 0..<1)
        }
        return levels.count == texture.mipmapLevelCount ? ScratchSet(texture: texture, levels: levels) : nil
    }
    private let liveFrame = DecodedFrame(poolIndex: 0)
    var clock = LayerClock()
    /// The clock followed a sync master last tick (DESIGN.md §23.3).
    var following = false
    var hold = InvisibilityHold()
    var currentShown = -1
    var previousShown = -1
    var holdFrame: DecodedFrame?
    /// `holdFrame`'s media frame as it was when it was taken (B371): after a drain its slot is free and the decode thread
    /// may relabel it while it is still shown (B386), so the stale count compares this. −1 = none.
    var holdFrameIndex = -1
    /// The mixer channel this playback's decoder fills (movies with an audio track only).
    public var audioChannel: LayerAudioChannel? { decoder?.audioChannel }

    public init(key: MediaKey, movie: MovieSource, decoder: LayerDecoder, ring: FrameRing) {
        self.key = key
        self.decoder = decoder
        self.ring = ring
        still = nil
        live = nil
        width = movie.info.width
        height = movie.info.height
        pixelAspect = movie.info.pixelAspect
        frameRate = movie.info.frameRate
        frameCount = movie.info.frameCount
    }

    /// `pixelAspect`: the movie's, when the still is one decoded movie frame (the thumbnailer); 1 for a real still.
    public init(key: MediaKey, still: DecodedFrame, pixelAspect: Double = 1) {
        self.key = key
        self.still = still
        decoder = nil
        ring = nil
        live = nil
        width = still.texture0?.width ?? 1
        height = still.texture0?.height ?? 1
        self.pixelAspect = pixelAspect
        frameRate = 1
        frameCount = 1
    }

    public init(key: MediaKey, live: any LiveTextureSource) {
        self.key = key
        self.live = live
        decoder = nil
        ring = nil
        still = nil
        width = 0  // taken from the texture each tick
        height = 0
        pixelAspect = 1
        frameRate = 1
        frameCount = 1
    }

    /// True once something can be drawn: a still, a live texture, or a decoded ring frame.
    var hasFrame: Bool {
        if still != nil { return true }
        if let live { return live.latestFrame != nil }
        return !(ring?.isEmpty ?? true)
    }

    /// The frame to draw for media frame `index` (compositor thread).
    func frame(at index: Int, direction: Int) -> DecodedFrame? {
        if let still { return still }
        if let live {
            let latest = live.latestFrame  // once: the fields below are one frame's
            liveFrame.texture0 = latest?.texture0
            liveFrame.texture1 = latest?.texture1
            liveFrame.kind = latest?.kind ?? .rgba
            liveFrame.bottomUp = latest?.bottomUp ?? false
            return latest == nil ? nil : liveFrame
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
        var best: DecodedFrame?  // the whole ring: with frames decoded ahead the clock's frame can be anywhere in it (B372)
        for i in 0..<ring.count {
            guard let f = ring.peek(i) else { break }
            if best == nil || behind(f.frameIndex) < behind(best!.frameIndex) { best = f }
        }
        guard let best, behind(best.frameIndex) < ring.capacity + 2 else {
            if holdFrame == nil, let best { (holdFrame, holdFrameIndex) = (best, best.frameIndex) }  // never shown (held invisible): better a stale picture than none until the seek lands
            freed = true
            ring.drain()  // everything buffered is on the wrong side of a seek
            return holdFrame
        }
        if best.frameIndex != currentShown {
            previousShown = currentShown
            currentShown = best.frameIndex
        }
        holdFrame = best
        holdFrameIndex = best.frameIndex
        return best
    }

    /// Lets go of the audio channel (compositor at retire, loader at stop): silence, no producer.
    func releaseAudio() {
        guard let decoder, let channel = decoder.audioChannel else { return }
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

/// A scratch texture with its level views (B2), made by the loader and handed to the compositor through a lock.
public struct ScratchSet: @unchecked Sendable {
    public let texture: MTLTexture
    public let levels: [MTLTexture]
}

/// A scratch texture the loader made for a playback (B2); the compositor adopts it when that playback is still its own.
struct PendingScratch {
    var set = false
    var playback: LayerPlayback?
    /// Nil: Metal refused; the playback keeps the source path.
    var answer: ScratchSet?
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
    /// Non-square pixels (B147): `width` is the shown width; nil = 1, like the library's metadata (B146).
    public var pixelAspect: Double? = nil
    public var error: String? = nil
    /// A capture layer's counters (frames, dropped, outOfBuffers, unusable), nil for other media.
    public var capture: CaptureInput.Counters? = nil
    public init() {}
}

public final class RenderLayer: @unchecked Sendable {
    public let index: Int  // 0-based layer slot
    public let mediaStatus = Mutex<LayerMediaStatus>(LayerMediaStatus())
    /// The Sync channel's role and a slave's state (DESIGN.md §23.4); the compositor writes it when it changes.
    let syncStatus = Mutex(LayerSyncStatus())
    /// Compositor thread: what it last wrote into `syncStatus`.
    var syncStatusWritten = LayerSyncStatus()
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
    /// The playback the compositor wants a scratch texture for (B2); the loader takes it and answers in `pendingScratch`.
    let scratchRequest = Mutex<LayerPlayback?>(nil)
    /// Set by the loader; the compositor takes it with `withLockIfAvailable` (never blocks).
    let pendingScratch = Mutex(PendingScratch())
    var retireLater: [LayerPlayback] = []
    /// Since start: ticks on which this layer's movie was queued with a frame other than its clock's, one per playback
    /// (a dissolve's two pictures count apart) (B371). Written by the compositor, read by `/metrics`.
    public let staleFrames = Atomic<Int>(0)

    public init(index: Int) {
        self.index = index
        retireLater.reserveCapacity(4)
    }

    /// Frame index of the playing media for the UI's position display.
    /// ponytail: unsynchronised read of a compositor-owned value; a stale frame number for one 100 ms tick is harmless.
    /// The clock's frame (B372): a looping clock stays inside its shown frame's window, so the in and out points
    /// are not needed for it.
    public var currentFrame: Int { current.map { $0.clock.frame(lo: 0, hi: $0.frameCount - 1) } ?? 0 }
}

/// Media as a scene addresses it: (folder, file) → a file or a live input.
/// Phase 4 replaces the explicit list with the library index (DESIGN.md §8).
public struct MediaEntry: Codable, Sendable, Equatable {
    public var folder: Int
    public var file: Int
    public var path: String?
    /// Capture device by `AVCaptureDevice.uniqueID` (folder 0, DESIGN.md §8.2.1).
    public var capture: String?
    /// Display by its CoreGraphics UUID (folder 0, DESIGN.md §8.2.1).
    public var screen: String?

    public init(folder: Int, file: Int, path: String? = nil, capture: String? = nil, screen: String? = nil) {
        self.folder = folder
        self.file = file
        self.path = path
        self.capture = capture
        self.screen = screen
    }

    public var key: MediaKey { MediaKey(folder: folder, file: file) }
}

/// Control-side thread that opens media the compositor asks for and releases
/// what it has dropped (DESIGN.md §4.2: file changes never touch the
/// compositor thread). One per render service. Movie and still files are
/// opened on threads of their own, a few at a time, so a slow volume holds up
/// only its own layer (B277).
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
    /// Creates a Syphon live input by the directory's id (a numbered server of folder 0, B61, where two servers can
    /// share a name); nil until the Syphon wiring is installed.
    public var liveFactory: (@Sendable (_ uuid: String) -> (any LiveTextureSource)?)?
    /// Folder 0 files 150–169 (B61); nil = no numbered Syphon servers (tests, bench). Set before `start`.
    public var syphonCatalog: LiveCatalog?
    /// Folder 0 files 1–20 (B73); nil = no numbered capture devices. Set before `start`.
    public var captureCatalog: LiveCatalog?
    /// Folder 0 files 21–28 (B73 step 3); nil = no numbered displays. Set before `start`.
    public var screensCatalog: LiveCatalog?
    /// Folder 0 generators (file 100+); nil in tests without a Metal context.
    public var generatorFactory: (@Sendable (Int) -> (any LiveTextureSource)?)?
    /// Opens a capture device by uid (a numbered device or a scene entry's `capture:`); throws the layer's status text
    /// (permission, no device). Called once per device while a layer shows it: the layers share the input.
    public var captureFactory: (@Sendable (_ uid: String) throws -> CaptureInput)?
    /// Opens a display by uuid (a numbered display or a scene entry's `screen:`), as `captureFactory` (a `ScreenInput`).
    public var screenFactory: (@Sendable (_ uuid: String) throws -> CaptureInput)?
    /// Two mixer channels per layer slot (the playing media and the one dissolving out); nil = no audio.
    public var mixer: AudioMixer?
    /// Library lookup for keys the scene's explicit list does not cover (DESIGN.md §7.4).
    public var resolver: (@Sendable (MediaKey) -> URL?)?

    /// A movie's or a still's file as an open thread hands it to the loader thread (B277): no decoder made yet.
    enum OpenedFile: @unchecked Sendable {
        case still(DecodedFrame)
        case movie(MovieSource, audio: AudioTrackReader?)
    }
    /// Opens a library or scene file on an open thread of its own (B277), the audio track too when `audio`; tests stand
    /// in one that blocks.
    var openFile: @Sendable (_ url: URL, _ audio: Bool) throws -> OpenedFile
    /// B277: a layer stops waiting for an open that has not answered within this. It says "not answering" and takes the
    /// next selection; the open's thread runs on (one blocked in `open(2)` on a gone volume cannot be stopped) and its
    /// media still plays when it answers and nothing newer was selected on the layer.
    var openDeadline: Duration = .seconds(2)
    /// B389: the first ProRes movie opened starts the decoder warm-up when it has not run. The engine sets it; a
    /// test's loader leaves the decoder alone.
    public var warmsDecoders = false
    /// B277: file opens that normally run at once within their deadline (measured: 4 at a time opens 8 ProRes files about
    /// twice as fast as one at a time, 8 at a time no faster; a layer that leaves its open for a clear or a live input
    /// frees its slot while that thread may still run), and open threads alive at most, given-up ones included: never
    /// more, and with that many on volumes that do not answer, further file opens wait until one does.
    var maxOpens = 4
    var maxOpenThreads = 8
    /// Loader thread: the open each layer waits for; nil when none, or given up.
    private var opening: [(id: Int, key: MediaKey, url: URL, deadline: ContinuousClock.Instant)?]
    /// Loader thread: the id of each layer's newest open (file or not). An answer is played only when its id is the
    /// newest and the layer still wants its key, so neither an older open nor one the layer has moved away from (a
    /// selection still waiting for a slot) replaces the last selection.
    private var newest: [Int]
    private var lastID = 0
    /// Loader thread: open threads started whose answer has not been taken.
    private var openThreads = 0
    /// Loader thread: the packed key of the playback last handed to each layer (what it shows), which the live-input
    /// checks follow while a file selection is still opening, was given up or failed late.
    private var shown: [UInt32]
    /// Loader thread: why the layer's selection did not come (given up, or failed after the give-up); shown with the
    /// picture's own status until the next hand-over, so the capture poll does not clear it.
    private var notCome: [String?]
    typealias Answer = (layer: Int, id: Int, key: MediaKey, url: URL, result: Result<OpenedFile, Error>)
    /// What the open threads hand back. They hold this box, not the loader, so a thread stuck on a gone volume keeps no
    /// stopped loader alive; after the stop it hands nothing back.
    private final class Answers: Sendable {
        let list = Mutex<[Answer]>([])
        let stopped = Atomic<Bool>(false)
    }
    private let answers = Answers()

    public init(layers: [RenderLayer], media: [MediaEntry], device: MTLDevice, ringCapacity: Int, logger: Logger) {
        self.layers = layers
        // an entry without a source (an old scene file's `syphon` entry, whose key is no longer decoded) would hide a
        // numbered live input on its number and fail to open: skipped
        let sourced = media.filter { entry in
            guard entry.path == nil, entry.capture == nil, entry.screen == nil else { return true }
            logger.warning("scene media \(entry.key) has no source, skipped")
            return false
        }
        self.media = Dictionary(sourced.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        self.device = device
        self.ringCapacity = ringCapacity
        self.logger = logger
        loaded = Array(repeating: 0, count: layers.count)
        syphonOpen = Array(repeating: nil, count: layers.count)
        captureOpen = Array(repeating: nil, count: layers.count)
        opening = Array(repeating: nil, count: layers.count)
        newest = Array(repeating: 0, count: layers.count)
        shown = Array(repeating: 0, count: layers.count)
        notCome = Array(repeating: nil, count: layers.count)
        openFile = { url, audio in
            if StillSource.extensions.contains(url.pathExtension.lowercased()) { return .still(try StillSource.load(url: url, device: device)) }
            let source = try blockingAwait(priority: .userInitiated) { try await MovieSource.open(url: url, device: device, poolSize: ringCapacity) }
            return .movie(source, audio: audio ? try blockingAwait(priority: .userInitiated) { try await AudioTrackReader.open(url: url) } : nil)
        }
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

    /// What changed since the loader thread last looked (`changed(_:)`).
    public struct Changes: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// B61: a numbered Syphon server started, went or came back. A layer on one that went says "not running" and
        /// keeps its last picture; one whose server (re)appears connects without being selected again.
        public static let syphonServers = Changes(rawValue: 1 << 0)
        /// The camera permission was answered (or authorized from the Inputs screen): layers on a capture entry that
        /// could not open try again.
        public static let capturePermission = Changes(rawValue: 1 << 1)
        /// B73: a numbered capture device came, went, came back or is in use by another app. As for Syphon, a layer on
        /// one that went says "not running" and keeps its last picture; one that (re)appears opens without being
        /// selected again.
        public static let captureDevices = Changes(rawValue: 1 << 2)
        /// B73 step 3: a numbered display came, went (or was bound as an output) or came back; as `captureDevices`.
        public static let screens = Changes(rawValue: 1 << 3)
        /// B51: the library root changed; every layer on library media opens its folder/file again through `resolver`
        /// (a file the new root lacks shows "missing"). Generators, scene entries and "none" are left alone.
        public static let library = Changes(rawValue: 1 << 4)
        /// The library changed (a scan, a probe that made a file playable): layers showing "missing" whose folder/file
        /// now resolves open it. Cheap when nothing is missing; signalled on every library change.
        public static let missingLibrary = Changes(rawValue: 1 << 5)
    }
    private let pendingChanges = Atomic<UInt8>(0)

    public func changed(_ c: Changes) {
        pendingChanges.bitwiseOr(c.rawValue, ordering: .relaxed)
        wake.signal()
    }

    /// Loader thread: the capture or screen input each layer shows (by uid or uuid), polled for its status ("no signal").
    private var captureOpen: [(uid: String, input: CaptureInput)?]
    /// Loader thread: the open input of each device by uid (`.capture`) and of each display by uuid (`.screens`), so a
    /// second layer on it shares the session.
    private var captureShared: [LiveCatalog.Kind: [String: WeakCapture]] = [:]
    private struct WeakCapture { weak var input: CaptureInput? }
    /// Loader thread: the directory id of the numbered Syphon server each layer is connected to.
    private var syphonOpen: [String?]

    /// "Camera: <name>", "Display: <name>".
    private static func liveName(_ kind: LiveCatalog.Kind, _ name: String) -> String { "\(kind == .screens ? "Display" : "Camera"): \(name)" }

    /// Loader thread: the layers on a numbered capture device or display after its catalog changed.
    /// - one whose source went reads "not running" and keeps its input (the last frame); a display's stream is halted
    ///   (it may be bound as an output now, which would show only the engine's excluded windows);
    /// - one is opened again when its source is running but not open, or open under another uid (an unplug and a replug
    ///   on another port in one update), or its session failed or stopped;
    /// - one whose open source still runs on another number (a renumber, B137) is opened again too: the number shows
    ///   what is on it now, never the input that left it.
    private func liveSourcesChanged(_ kind: LiveCatalog.Kind) {
        let catalog = kind == .screens ? screensCatalog : captureCatalog
        let runningElsewhere = Set((catalog?.entries ?? []).filter(\.running).map(\.source))
        for i in shown.indices where isNumbered(MediaKey(packed: shown[i]), kind) {
            let source = catalog?.entry(file: MediaKey(packed: shown[i]).file)
            let open = captureOpen[i]
            if let source, source.running, let open, open.uid == source.source, open.input.alive {
                layers[i].mediaStatus.withLock { $0.name = Self.liveName(kind, source.name) }  // a rename; in use by another app too
                continue
            }
            // gone, back under another uid, or a failed session: never shared again
            if let open, captureShared[kind]?[open.uid]?.input === open.input { captureShared[kind]?[open.uid] = nil }
            if source?.running == true || open.map({ runningElsewhere.contains($0.uid) }) == true {
                // came back, no longer in use elsewhere, or moved to another number: opened again below, unless the
                // layer's selection is a file that has not come (B277: it keeps the last frame)
                if loaded[i] == shown[i] { loaded[i] = .max }
            } else {
                if kind == .screens { open?.input.halt("not running") }
                captureOpen[i] = nil  // the input stays on the layer: the last frame
                layers[i].mediaStatus.withLock { $0.error = "not running" }
            }
        }
    }

    /// Folder 0 files of `kind` (Syphon: 150–169) that no scene entry claims (scene entries win on the same number).
    private func isNumbered(_ key: MediaKey, _ kind: LiveCatalog.Kind) -> Bool {
        key.folder == 0 && kind.files.contains(key.file) && media[key] == nil
    }

    private func loop() {
        while running.load(ordering: .relaxed) {
            _ = wake.wait(timeout: .now() + .milliseconds(100))
            let changes = Changes(rawValue: pendingChanges.exchange(0, ordering: .relaxed))
            let all = changes.contains(.library)
            if changes.contains(.missingLibrary) || all {
                for i in loaded.indices {
                    let key = MediaKey(packed: loaded[i])
                    guard !key.isNone, key.folder != 0, media[key] == nil else { continue }
                    // a missing number is retried only where it is what the layer shows (B277: not a file that has not come)
                    if all || (loaded[i] == shown[i] && layers[i].mediaStatus.withLock { $0.kind == "missing" } && resolver?(key) != nil) {
                        loaded[i] = .max  // never a packed key: opened again below
                    }
                }
            }
            if changes.contains(.syphonServers) {
                for i in shown.indices where isNumbered(MediaKey(packed: shown[i]), .syphon) {
                    let server = syphonCatalog?.entry(file: MediaKey(packed: shown[i]).file)
                    if server?.runtimeID == syphonOpen[i] {
                        // same connection (or still gone): only a rename (SyphonServerUpdate) can have changed
                        if let server { layers[i].mediaStatus.withLock { $0.name = "Syphon: \(server.label)" } }
                    } else if server?.runtimeID == nil, !(syphonOpen[i].map { id in syphonCatalog?.entries.contains { $0.runtimeID == id } == true } ?? false) {
                        syphonOpen[i] = nil
                        layers[i].mediaStatus.withLock { $0.error = "not running" }
                    } else {
                        // back, or its server moved to another number (a renumber, B137): the number shows what is on it now;
                        // not while the layer's selection is a file that has not come (B277)
                        if loaded[i] == shown[i] { loaded[i] = .max }  // never a packed key: opened again below
                    }
                }
            }
            if changes.contains(.captureDevices) { liveSourcesChanged(.capture) }
            if changes.contains(.screens) { liveSourcesChanged(.screens) }
            if changes.contains(.capturePermission) {
                for i in loaded.indices where captureOpen[i] == nil {
                    let key = MediaKey(packed: loaded[i])
                    if media[key]?.capture != nil || isNumbered(key, .capture) { loaded[i] = .max }  // never a packed key: opened again below
                }
            }
            for (i, open) in captureOpen.enumerated() {
                guard let input = open?.input else { continue }
                let (error, fps): (String?, Double) =
                    switch input.status {
                    case .starting: (nil, 0)
                    case .running(let fps): (nil, (fps * 100).rounded() / 100)
                    case .noSignal: ("no signal", 0)  // the last frame stays on the layer
                    case .stopped: ("not running", 0)
                    case .failed(let reason): (reason, 0)
                    }
                let format = input.format, counters = input.counters
                layers[i].mediaStatus.withLock { status in
                    if status.error != notCome[i] ?? error { status.error = notCome[i] ?? error }
                    if status.fps != fps { status.fps = fps }
                    if status.codec != format.subtype { status.codec = format.subtype }
                    (status.width, status.height) = (format.width, format.height)  // a card follows its input
                    status.capture = counters
                }
            }
            takeAnswers()
            giveUpLateOpens()
            for (i, layer) in layers.enumerated() {
                let retired = layer.retired.withLock { list -> [LayerPlayback] in
                    let copy = list
                    list.removeAll(keepingCapacity: true)
                    return copy
                }
                for playback in retired { playback.stop() }
                let asking = layer.scratchRequest.withLock { $0.take() }
                if let asking {
                    let answer = LayerPlayback.makeScratchSet(device: device, width: asking.width, height: asking.height)
                    layer.pendingScratch.withLock { box in
                        box.set = true
                        box.playback = asking
                        box.answer = answer
                    }
                }
                let want = layer.wanted.load(ordering: .relaxed)
                guard want != loaded[i] else { continue }
                var file: URL?
                let playback = autoreleasepool { open(MediaKey(packed: want), layer: i, file: &file) }
                if let file {
                    // B277: the layer's open in flight answers or is given up first, and with all open slots taken the
                    // layer keeps its picture and asks again on the next pass
                    guard opening[i] == nil, opening.count(where: { $0 != nil }) < maxOpens, openThreads < maxOpenThreads else { continue }
                    loaded[i] = want
                    startOpen(MediaKey(packed: want), url: file, layer: i)
                } else {
                    // not a file: at once, also with an open in flight (its answer is no longer the newest, and it is
                    // not given up over this selection's status)
                    loaded[i] = want
                    opening[i] = nil
                    lastID += 1
                    newest[i] = lastID
                    hand(playback, of: want, to: i)
                }
            }
        }
        answers.list.withLock { list in
            answers.stopped.store(true, ordering: .relaxed)  // under the lock: no thread appends after this
            list.removeAll()
        }
        for layer in layers {
            layer.pending.withLock { box in
                box.playback?.stop()
                box.playback = nil
                box.set = false
            }
        }
    }

    /// Loader thread: hands `playback` (nil: no media) of selection `key` to the compositor through the layer's lock; the
    /// live-input checks follow `key` from now on.
    private func hand(_ playback: LayerPlayback?, of key: UInt32, to layer: Int) {
        shown[layer] = key
        notCome[layer] = nil
        layers[layer].pending.withLock { box in
            box.playback?.stop()  // replaced before the compositor took it
            box.set = true
            box.playback = playback
        }
    }

    /// Loader thread (B277): opens `url` for `layer` on a thread of its own; `takeAnswers` finishes it.
    private func startOpen(_ key: MediaKey, url: URL, layer: Int) {
        lastID += 1
        let id = lastID
        newest[layer] = id
        opening[layer] = (id, key, url, .now + openDeadline)
        openThreads += 1
        let audio = mixer.map { layer * 2 + 1 < $0.channels.count } ?? false
        let openFile = openFile, answers = answers, wake = wake
        let thread = Thread {
            let signpost = Signposts.id(Thread.current)
            Signposts.begin("open", id: signpost)
            let result = Result { try autoreleasepool { try openFile(url, audio) } }
            Signposts.end("open", id: signpost)
            answers.list.withLock { list in
                if !answers.stopped.load(ordering: .relaxed) { list.append((layer, id, key, url, result)) }
            }
            wake.signal()
        }
        thread.name = "org.fanous.media.open"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Loader thread (B277): the opens that answered. One that is its layer's newest and whose key the layer still wants
    /// is finished and handed over, even one that was given up; any other (the layer moved on, or its newer selection
    /// waits for a slot) is dropped before a decoder is made for it. A given-up open that fails writes the layer's status
    /// and logs but hands nothing: the layer keeps its picture, as it did at the give-up (a decision; a failure within
    /// the deadline still cuts to black, B299).
    private func takeAnswers() {
        let taken = answers.list.withLock { list -> [Answer] in
            guard !list.isEmpty else { return [] }  // no allocation on a pass without answers
            defer { list.removeAll(keepingCapacity: true) }
            return list
        }
        for answer in taken {
            let i = answer.layer
            openThreads -= 1
            let givenUp = opening[i]?.id != answer.id
            if !givenUp { opening[i] = nil }
            guard answer.id == newest[i], layers[i].wanted.load(ordering: .relaxed) == answer.key.packed else {
                if answer.id == newest[i] {
                    loaded[i] = .max  // never a packed key: what the layer wants now is opened below
                    if notCome[i] != nil {  // its error is about a selection the layer has left
                        notCome[i] = nil
                        layers[i].mediaStatus.withLock { $0.error = nil }
                    }
                }
                logger.info("media open answered after a newer selection, dropped", metadata: ["layer": "\(i + 1)", "media": "\(answer.key)"])
                continue
            }
            if givenUp, case .failure(let error) = answer.result {  // the picture and its status stay, with the error
                logger.error("media open failed", metadata: ["layer": "\(i + 1)", "media": "\(answer.key)", "error": "\(error)"])
                notCome(i, answer.key, "\(answer.url.lastPathComponent): \(error.clientText)")
                continue
            }
            let playback = autoreleasepool { finish(answer.key, layer: i, url: answer.url, answer.result) }
            (syphonOpen[i], captureOpen[i]) = (nil, nil)
            hand(playback, of: answer.key.packed, to: i)
        }
    }

    /// Loader thread (B277): a layer whose open has not answered within `openDeadline` stops waiting for it. It keeps
    /// its picture and that picture's status (a failed open cuts to black; this is not worse), adds why the selection did
    /// not come, and takes the next selection.
    private func giveUpLateOpens() {
        let now = ContinuousClock.now
        for i in opening.indices {
            guard let open = opening[i], now >= open.deadline else { continue }
            opening[i] = nil
            logger.warning("media open not answering: the layer keeps its picture; the file plays if it answers before another is selected", metadata: [
                "layer": "\(i + 1)", "media": "\(open.key)", "file": "\(open.url.lastPathComponent)", "after": "\(openDeadline)",
            ])
            notCome(i, open.key, "\(open.url.lastPathComponent) is not answering: the volume is slow or gone")
        }
    }

    /// Loader thread (B277): the layer's status keeps describing its picture and gains why `key` did not come.
    private func notCome(_ layer: Int, _ key: MediaKey, _ text: String) {
        notCome[layer] = "\(key) \(text)"
        layers[layer].mediaStatus.withLock { $0.error = notCome[layer] }
    }

    /// Loader thread: the playback of `key` on `layer`, or nil (status says why). A movie or a still file is not opened
    /// here: `file` is set to it and the caller opens it on a thread of its own (B277), which a slow volume can hold up.
    private func open(_ key: MediaKey, layer: Int, file: inout URL?) -> LayerPlayback? {
        var status = LayerMediaStatus()
        status.folder = key.folder
        status.file = key.file
        // a file leaves the books on what the layer shows until its playback is handed over (takeAnswers)
        let books = (syphonOpen[layer], captureOpen[layer])
        defer { if file == nil { layers[layer].mediaStatus.withLock { $0 = status } } else { (syphonOpen[layer], captureOpen[layer]) = books } }
        syphonOpen[layer] = nil
        captureOpen[layer] = nil
        guard !key.isNone else { return nil }
        Signposts.begin("open")
        defer { Signposts.end("open") }
        if isNumbered(key, .syphon), let server = syphonCatalog?.entry(file: key.file) {
            status.kind = "live"
            status.codec = "syphon"
            status.name = "Syphon: \(server.label)"
            guard let uuid = server.runtimeID else {
                status.error = "not running"  // black until it starts; then the catalog change opens it
                return nil
            }
            guard let live = liveFactory?(uuid) else {
                logger.warning("Syphon server could not connect", metadata: ["layer": "\(layer + 1)", "syphon": "\(server.label)"])
                status.error = "could not connect"
                return nil
            }
            syphonOpen[layer] = uuid
            logger.info("layer \(layer + 1) media \(key)", metadata: ["syphon": "\(server.label)"])
            return LayerPlayback(key: key, live: live)
        }
        if Generators.isGenerator(key), let generator = generatorFactory?(key.file) {
            status.kind = "live"
            status.name = "Generator: \(Generators.names[key.file] ?? "\(key.file)")"
            if let texture = generator.latestFrame?.texture0 {
                status.width = texture.width
                status.height = texture.height
            }
            status.codec = "generator"
            return LayerPlayback(key: key, live: generator)
        }
        var numbered: MediaEntry?
        if isNumbered(key, .capture), let device = captureCatalog?.entry(file: key.file) {
            status.kind = "live"
            status.name = "Camera: \(device.name)"
            guard device.running else {
                status.error = "not running"  // black until it connects; then the catalog change opens it
                return nil
            }
            // a session of ours is shared first: in use may be another app that opened the device after us
            guard !device.inUse || captureShared[.capture]?[device.source]?.input?.alive == true else {
                status.error = "in use by another app"  // opened again when the other app lets go
                return nil
            }
            numbered = MediaEntry(folder: 0, file: key.file, capture: device.source)
        }
        if isNumbered(key, .screens), let display = screensCatalog?.entry(file: key.file) {
            status.kind = "live"
            status.name = Self.liveName(.screens, display.name)
            guard display.running else {
                status.error = "not running"  // black until it connects (or its output lets go); then the catalog change opens it
                return nil
            }
            numbered = MediaEntry(folder: 0, file: key.file, screen: display.source)
        }
        guard let entry = numbered ?? media[key] ?? resolver?(key).map({ MediaEntry(folder: key.folder, file: key.file, path: $0.path) }) else {
            logger.warning("media not found", metadata: ["layer": "\(layer + 1)", "media": "\(key)"])
            status.kind = "missing"
            status.error = key.folder != 0 ? "no file \(key.file) in folder \(key.folder)"
                : LiveCatalog.Kind.syphon.files.contains(key.file) ? "no Syphon server numbered \(key.file) (folder 0, 150–169)"
                : LiveCatalog.Kind.capture.files.contains(key.file) ? "no capture device numbered \(key.file) (folder 0, 1–20)"
                : LiveCatalog.Kind.screens.files.contains(key.file) ? "no display numbered \(key.file) (folder 0, 21–28)"
                : "no built-in content \(key.file) in folder 0 (100–107, 110–113, Syphon 150–169)"
            return nil
        }
        do {
            if let uid = entry.capture ?? entry.screen {
                let kind: LiveCatalog.Kind = entry.capture != nil ? .capture : .screens
                status.kind = "live"
                if status.name == nil { status.name = Self.liveName(kind, uid) }
                let input: CaptureInput
                if let shared = captureShared[kind]?[uid]?.input, shared.share() {
                    input = shared  // a second layer on the device or display: one session
                } else {
                    guard let factory = kind == .capture ? captureFactory : screenFactory else { throw RenderError.pipeline("no capture input for \(uid)") }
                    input = try factory(uid)
                    captureShared[kind, default: [:]][uid] = WeakCapture(input: input)
                }
                if numbered == nil { status.name = Self.liveName(kind, input.name) }  // format, size and counters: polled once it runs
                status.capture = CaptureInput.Counters()
                captureOpen[layer] = (uid, input)
                logger.info("layer \(layer + 1) media \(key)", metadata: ["capture": "\(input.name)"])
                return LayerPlayback(key: key, live: input)
            }
            guard let path = entry.path else { throw RenderError.pipeline("media \(key) has no path") }
            file = URL(fileURLWithPath: path)
            return nil
        } catch {
            logger.error("media open failed", metadata: ["layer": "\(layer + 1)", "media": "\(key)", "error": "\(error)"])
            status.error = error.clientText  // no file path for the monitor role (B25)
            return nil
        }
    }

    /// Loader thread: the playback of a file an open thread opened (or failed to) for `layer`; writes the layer's status.
    private func finish(_ key: MediaKey, layer: Int, url: URL, _ opened: Result<OpenedFile, Error>) -> LayerPlayback? {
        var status = LayerMediaStatus()
        status.folder = key.folder
        status.file = key.file
        status.name = url.lastPathComponent
        defer { layers[layer].mediaStatus.withLock { $0 = status } }
        do {
            let (source, reader): (MovieSource, AudioTrackReader?)
            switch try opened.get() {
            case .still(let still):
                let playback = LayerPlayback(key: key, still: still)
                status.kind = "still"
                status.codec = url.pathExtension.lowercased()
                status.width = playback.width
                status.height = playback.height
                return playback
            case .movie(let movie, let audio): (source, reader) = (movie, audio)
            }
            // B389: a ProRes movie the library had not shown yet (a scene's file, one still being probed)
            if warmsDecoders, MovieSource.proResCodecs.contains(source.info.codec) { DecoderWarmUp.startOnce(logger: logger) }
            let ring = FrameRing(capacity: ringCapacity)
            let decoder = LayerDecoder(source: source, ring: ring, logger: logger)
            if let mixer, let reader, reader.hasAudio, layer * 2 + 1 < mixer.channels.count {
                decoder.audioReader = reader
                decoder.audioChannels = Array(mixer.channels[layer * 2 ..< layer * 2 + 2])  // the compositor picks one at the swap (B399)
                mixer.ensureRunning()
            }
            // B342: a file whose frames fail shows it like a failed open; a dissolve's outgoing movie leaves the new one's alone
            decoder.failing = { [renderLayer = layers[layer]] error in
                renderLayer.mediaStatus.withLock { if $0.folder == key.folder, $0.file == key.file, $0.error != error { $0.error = error } }
            }
            decoder.start(name: "org.fanous.decode.\(layer + 1)")
            decoder.request(frame: 0, direction: 1)
            logger.info("layer \(layer + 1) media \(key)", metadata: ["file": "\(url.lastPathComponent)", "codec": "\(source.info.codecName)", "size": "\(source.info.width)x\(source.info.height)@\(source.info.frameRate)"])
            if source.softwareDecoder { logger.warning("software ProRes decoder: the hardware one refused this frame size (B5)", metadata: ["layer": "\(layer + 1)", "file": "\(url.lastPathComponent)", "size": "\(source.info.width)x\(source.info.height)"]) }
            status.kind = "movie"
            status.codec = source.info.codecName
            status.width = Int((Double(source.info.width) * source.info.pixelAspect).rounded())  // shown size, like the library's naturalSize
            status.height = source.info.height
            if abs(source.info.pixelAspect - 1) > 0.005 { status.pixelAspect = source.info.pixelAspect }  // same rule as the library (B146)
            status.fps = source.info.frameRate
            status.frames = source.info.frameCount
            return LayerPlayback(key: key, movie: source, decoder: decoder, ring: ring)
        } catch {
            logger.error("media open failed", metadata: ["layer": "\(layer + 1)", "media": "\(key)", "error": "\(error)"])
            status.error = error.clientText  // no file path for the monitor role (B25)
            return nil
        }
    }
}
