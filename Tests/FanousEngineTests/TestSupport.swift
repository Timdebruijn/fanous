// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import FanousCore
import Foundation
import Logging
import Metal
import Security
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import FanousEngine

/// Runs blocking AVFoundation work (`AVAssetWriter.finishWriting` + semaphore, `LibraryIndex.probeMovie`) on a thread of its
/// own. Swift Testing runs a test per core on the cooperative pool; with every pool thread parked in such a wait the
/// completion never arrives and the run hangs (B63). Likely mechanism: the completion is queued on the default-QoS global
/// queue (`com.apple.root.default-qos`), which gets no worker thread while all pool threads at that QoS are blocked.
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

/// Polls `condition` every `every` until it holds or `deadline` has passed; true = it held. For "eventually" checks: a
/// fixed sleep before an assertion encodes how fast this Mac is, and a loaded one (other builds, a parallel run) is
/// slower (B67). Negative checks ("nothing happened") still need a fixed window: there is nothing to poll for.
@discardableResult
nonisolated(nonsending) func waitUntil(_ deadline: Duration = .seconds(10), every: Duration = .milliseconds(10), _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + deadline
    while !condition() {
        guard ContinuousClock.now < end, (try? await Task.sleep(for: every)) != nil else { return condition() }
    }
    return true
}

/// The logger every test hands the engine.
let testLogger = Logger(label: "test")

/// A new P-256 private key, in memory only (no keychain, so no SecurityAgent prompt).
func makeKey() throws -> SecKey {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
        kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw error!.takeRetainedValue() }
    return key
}

/// The role gate with every role open and nothing on disk; 1000 PBKDF2 iterations keep a password test fast.
func testAuth() -> RoleAuth { RoleAuth(settingsURL: nil, shellTokenURL: nil, iterations: 1000, logger: testLogger) }

/// A new project on the standard patch of `layers` layers and `outputs` output fixtures, DMX policy.
func testProject(layers: Int, outputs: Int, libraryRoot: String = "/tmp/lib") -> JSONValue {
    ProjectDocument.initial(patch: .standard(layers: layers, outputs: outputs), layerCount: layers, libraryRoot: libraryRoot, policy: .dmx)
}

/// A store on `project` (a `testProject` of `layers` and `outputs` by default) with `register`'s commands, the plain
/// project commands by default.
func testStore(
    layers: Int = 2, outputs: Int = 1, project: JSONValue? = nil,
    registering register: (StateStore, RoleAuth) -> Void = { ProjectDocument.registerCommands(on: $0, auth: $1) }
) -> (store: StateStore, auth: RoleAuth) {
    let auth = testAuth()
    let store = StateStore(project: project ?? testProject(layers: layers, outputs: outputs), logger: testLogger)
    register(store, auth)
    return (store, auth)
}

/// The engine's REST routes over `store` and `auth`, with the library root, ingest queue, thumbnail cache and log file
/// in a fresh temporary directory (everything under `dir`: `library/`, `cache/`, `queue.json`, `thumbnails/`, `fanousd.log`,
/// none made yet); the metrics routes
/// answer stubs. Needs `.cleansTempFiles`.
func testRoutes(store: StateStore, auth: RoleAuth) throws -> (routes: RESTRoutes, dir: URL) {
    let dir = try tempDir("rest")
    let library = LibraryIndex(root: dir.appending(path: "library"), cacheDirectory: dir.appending(path: "cache"), logger: testLogger)
    let encoder = JSONEncoder()
    let queue = IngestQueue(persistenceURL: dir.appending(path: "queue.json"), logger: testLogger)
    let routes = RESTRoutes(
        auth: auth, store: store, ingestAPI: IngestAPI(library: { library }, queue: queue, encoder: encoder, logger: testLogger),
        library: { library }, encoder: encoder, dmx: DMXStore(patch: .standard(layers: 1, outputs: 1), logger: testLogger),
        thumbnails: dir.appending(path: "thumbnails"), logFile: dir.appending(path: "fanousd.log"), startedAt: Date(),
        metricsJSON: { .json(200, Array("{}".utf8)) }, metricsText: { .text(200, "metrics") })
    return (routes, dir)
}

/// Syphon server `app` (`name`) on number `file`, as the project's `/syphon` list holds it.
func syphonServer(_ file: Int, _ app: String, name: String = "Server") -> LiveCatalog.Entry {
    LiveCatalog.Entry(kind: .syphon, file: file, source: app, name: name)
}

/// The numbers and the apps of `store`'s Syphon list, in its order.
func syphonFiles(_ store: StateStore) -> [Int] { ProjectDocument.liveNumbers(.syphon, from: store.project).map(\.file) }
func syphonApps(_ store: StateStore) -> [String] { ProjectDocument.liveNumbers(.syphon, from: store.project).map(\.source) }

/// `count` outputs added to `store`, each a full 1920×1080 region (ids 1…count).
func addOutputs(_ store: StateStore, _ count: Int) throws {
    for id in 1...count {
        _ = try store.execute("output.add", role: .programmer).get()
        _ = try store.execute("output.set", args: ["id": .number(Double(id)), "path": "/region", "value": ["x": 0, "y": 0, "w": 1920, "h": 1080]], role: .programmer).get()
    }
}

/// `image` as a PNG at `url`.
func writePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination), "PNG not written: \(url.lastPathComponent)")
}

/// An sRGB image of `rgba` (8 bits a channel, rows top to bottom); `alpha` says how to read the fourth byte.
func cgImage(rgba: [UInt8], width: Int, height: Int, alpha: CGImageAlphaInfo = .last) throws -> CGImage {
    try #require(CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: CGDataProvider(data: Data(rgba) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent))
}

/// `buffer` (BGRA, any size) filled with `PatternFrames` frame `frame`.
@discardableResult
func fillPattern(_ buffer: CVPixelBuffer, frame: Int) -> CVPixelBuffer {
    CVPixelBufferLockBaseAddress(buffer, [])
    PatternFrames.fill(
        bgra: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(buffer),
        height: CVPixelBufferGetHeight(buffer), bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), frame: frame)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// A movie of `frames` `PatternFrames` frames at `size` and `fps` in `codec`, with the `TestTone` track when `audio` is set;
/// written off the pool (B63).
func writePatternMovie(
    to url: URL, size: (Int, Int), fps: Int32, frames: Int, codec: MovieWriter.Codec = .proRes422HQ, audio: Bool = false
) async throws {
    try await offPool {
        let writer = try MovieWriter(url: url, width: size.0, height: size.1, fps: fps, codec: codec, audio: audio)
        for frame in 0..<frames { try writer.append(fillPattern(try writer.makePixelBuffer(), frame: frame)) }
        try writer.finish()
    }
}

/// Where `PatternFrames`' white bar starts in `frame`, one decoded frame of a pattern movie of `size` (any codec), drawn
/// through the compositor as on stage: the first column of row 100 (below the counter) whose blue is above 200, which only
/// the bar's is. Frame n has it at x = 8n (mod width − 16), so it tells which frame was decoded; -1: no bar.
func patternBarX(_ frame: DecodedFrame, size: (Int, Int)) throws -> Int {
    let (compositor, parameters) = try makeCompositor(try MetalContext(), size: size)
    compositor.setLayers([.still(frame)])
    parameters.write { slot in
        slot.sequence = 1
        slot.layers[0].intensity = 1
        slot.layers[0].folder = 1
        slot.layers[0].file = 1
        slot.layers[0].fitMode = .stretch
    }
    compositor.tick(target: 3600, drawable: nil)
    let (width, _, rgba) = compositor.readback()
    return (0..<width).first { rgba[(100 * width + $0) * 4 + 2] > 200 } ?? -1
}

extension AVAssetWriter {
    /// `finishWriting`, waited for; throws unless the movie is complete. Blocks: call it off the pool (`offPool`).
    func finishBlocking() throws {
        let done = DispatchSemaphore(value: 0)
        finishWriting { done.signal() }
        done.wait()
        guard status == .completed else { throw MovieWriter.WriterError.failed(error?.localizedDescription ?? "finish") }
    }
}

/// The first frame of `url`'s video track, decoded to `format`.
func firstFrame(of url: URL, format: OSType = kCVPixelFormatType_32BGRA) async throws -> CVPixelBuffer {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
    reader.add(output)
    reader.startReading()
    defer { reader.cancelReading() }
    return try #require(output.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
}

/// A compositor of `size` at `fps` for `maxLayers` layers, over `parameters` or a buffer of its own; no layers set.
func makeCompositor(
    _ context: MetalContext, size: (Int, Int), maxLayers: Int = 1, fps: Double = 60, metrics: MetricsRing = MetricsRing(capacity: 64),
    parameters: TripleBuffer<ParameterSnapshotSlot>? = nil
) throws -> (Compositor, TripleBuffer<ParameterSnapshotSlot>) {
    let parameters = parameters ?? TripleBuffer { ParameterSnapshotSlot(maxLayers: maxLayers) }
    let compositor = try Compositor(
        context: context, canvasWidth: size.0, canvasHeight: size.1, fps: fps, maxLayers: maxLayers, metrics: metrics, parameters: parameters,
        logger: testLogger)
    return (compositor, parameters)
}

extension Compositor {
    /// A shared output-format texture of `size` as the offscreen output, what a display would draw from; returned.
    @discardableResult func attachOffscreenOutput(_ size: (Int, Int)) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.outputFormat, width: size.0, height: size.1, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        offscreenOutput = context.device.makeTexture(descriptor: descriptor)
        return offscreenOutput
    }

    /// Reads the offscreen output (BGRA 8-bit) back.
    func readbackOutput() -> (width: Int, height: Int, bgra: [UInt8]) {
        guard let texture = offscreenOutput, let buffer = blitToShared(texture, bytesPerPixel: 4) else { return (0, 0, []) }
        return (texture.width, texture.height, Array(UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)))
    }
}

extension RenderLayer {
    /// Layer `index` playing `playback`, wanted == loaded: the hand-off asks the (absent) loader for nothing.
    static func playing(_ playback: LayerPlayback?, index: Int = 0) -> RenderLayer {
        let layer = RenderLayer(index: index)
        layer.current = playback
        if let playback { layer.wanted.store(playback.key.packed, ordering: .relaxed) }
        return layer
    }

    /// Layer `index` playing `still` as media 1/`file`, wanted.
    static func still(_ still: DecodedFrame, file: Int = 1, index: Int = 0) -> RenderLayer {
        playing(LayerPlayback(key: MediaKey(folder: 1, file: file), still: still), index: index)
    }
}

/// `body` with an IPv4 address `host`:`port` (any address by default) as the `sockaddr` pointer and length the socket calls take.
func withSockaddr<T>(port: UInt16 = 0, host: String? = nil, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = host.map { inet_addr($0) } ?? INADDR_ANY
    return try withUnsafePointer(to: &address) { p in
        try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}

/// `recv` on `fd` gives up after `seconds`.
func setReceiveTimeout(_ fd: Int32, _ seconds: Double) {
    var wait = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1e6))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
}

/// The port a Network.framework listener reports through `read` (`boundPort`) once it is ready; port 0 in, so the kernel
/// picked it and no other socket holds it (B153).
func listeningPort(_ read: () -> UInt16?, sourceLocation: SourceLocation = #_sourceLocation) async throws -> UInt16 {
    await waitUntil { (read() ?? 0) != 0 }
    return try #require(read().flatMap { $0 == 0 ? nil : $0 }, "the listener never got ready", sourceLocation: sourceLocation)
}

/// One UDP datagram to `host`:`port` from a throwaway socket.
func sendUDP(_ bytes: [UInt8], to port: UInt16, host: String = "127.0.0.1") {
    sendUDP([bytes], to: port, host: host)
}

/// UDP datagrams to `host`:`port`, back-to-back from one throwaway socket (one flow, as a console sends them); `sent`
/// is what `sendto` returned for each. With a `reply` time, `replied` says whether an answer came back to that socket
/// within it.
@discardableResult
func sendUDP(_ datagrams: [[UInt8]], to port: UInt16, host: String = "127.0.0.1", reply: Double = 0) -> (sent: [Int], replied: Bool) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(fd) }
    let sent = datagrams.map { bytes in withSockaddr(port: port, host: host) { sendto(fd, bytes, bytes.count, 0, $0, $1) } }
    guard reply > 0 else { return (sent, false) }
    setReceiveTimeout(fd, reply)
    var buffer = [UInt8](repeating: 0, count: 1500)
    return (sent, recv(fd, &buffer, buffer.count, 0) > 0)
}

/// Removes what `tempDir` and `tempFile` handed out in a test once that test ends. The list is task-local: it reaches
/// child tasks and `Task {}`, not `offPool` or GCD; a path made there is not registered, and the test removes it itself.
/// A test outside such a suite that asks for one gets an issue instead of a silent leak.
struct CleansTempFiles: SuiteTrait, TestTrait, TestScoping {
    final class Paths: Sendable { let urls = Mutex<[URL]>([]) }
    @TaskLocal static var current: Paths?
    var isRecursive: Bool { true }
    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let paths = Paths()
        defer { for url in paths.urls.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) } }
        try await Self.$current.withValue(paths) { try await function() }
    }
}

extension Trait where Self == CleansTempFiles {
    static var cleansTempFiles: Self { Self() }
}

/// A path `prefix`-<UUID>[.`ext`] under the temporary directory, nothing made there yet; removed after the test (see
/// `CleansTempFiles`).
func tempFile(_ prefix: String, ext: String = "") -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)\(ext.isEmpty ? "" : "." + ext)")
    if let paths = CleansTempFiles.current {
        paths.urls.withLock { $0.append(url) }
    } else if Test.current != nil {
        Issue.record("\(prefix): the suite needs the .cleansTempFiles trait")
    }
    return url
}

/// A fresh directory `prefix`-<UUID> under the temporary directory; removed after the test (see `CleansTempFiles`).
func tempDir(_ prefix: String) throws -> URL {
    let url = tempFile(prefix)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A socket on 127.0.0.1, on a `port` the kernel picks, whose `receive` waits at most `timeout` seconds; nil = nothing came.
final class UDPCatcher {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    let port: UInt16
    init(timeout: Double) throws {
        let fd = fd
        setReceiveTimeout(fd, timeout)
        guard withSockaddr(host: "127.0.0.1", { bind(fd, $0, $1) }) == 0, let port = UDPSend.localPort(fd) else { throw POSIXError(.EADDRINUSE) }
        self.port = port
    }
    deinit { close(fd) }
    func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 1500)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer[0..<count]) : nil
    }
}

extension Trait where Self == ConditionTrait {
    /// Runs where `MallocCounter` works, and everywhere under FANOUS_REQUIRE_MALLOC_COUNTER (scripts/check-mallocs.sh), where
    /// `requireMallocCounter()` then fails a test that would count nothing.
    static var mallocCounter: Self { .enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS") }
}

func requireMallocCounter(sourceLocation: SourceLocation = #_sourceLocation) throws {
    try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS", sourceLocation: sourceLocation)
}

/// The counter sees allocations of the measured thread, malloc and Swift objects alike, and not those of another thread
/// in the same window. Loops are `while` loops: a `for` over a range allocates in a debug build.
@Test(.mallocCounter)
func mallocCounterCountsOnlyTheMeasuredThread() async throws {
    try requireMallocCounter()
    final class Other: Sendable { let state = Mutex((stop: false, allocations: 0)) }
    final class Sink { var object: Sink? }
    let other = Other()
    Thread.detachNewThread {
        while !other.state.withLock({ $0.stop }) {
            let block = malloc(16)
            other.state.withLock { $0.allocations += Int(bitPattern: block) & 1 == 0 ? 1 : 0 }  // block used: kept
            free(block)
        }
    }
    defer { other.state.withLock { $0.stop = true } }
    var elsewhere = 0
    let quiet = MallocCounter.count {
        let start = other.state.withLock { $0.allocations }
        let end = ContinuousClock.now + .seconds(5)
        while elsewhere < 1000, ContinuousClock.now < end {
            elsewhere = other.state.withLock { $0.allocations } - start
        }
    }
    #expect(elsewhere >= 1000, "the other thread allocated in the window: \(elsewhere)")
    #expect(quiet == 0, "none of them counted: \(quiet)")

    let blocks = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 100)
    defer { blocks.deallocate() }
    let mallocs = MallocCounter.count {
        var i = 0
        while i < 100 {
            blocks[i] = malloc(16)
            i += 1
        }
    }
    var i = 0
    while i < 100 {
        free(blocks[i])
        i += 1
    }
    #expect(mallocs == 100, "100 mallocs on this thread: \(mallocs)")
    let sink = Sink()
    let objects = MallocCounter.count { sink.object = Sink() }  // swift_allocObject → swift_slowAlloc
    #expect(sink.object != nil)
    #expect(objects == 1, "one Swift object: \(objects)")

    // start(thread:) from another thread (the bench counts the compositor thread from the main thread): the helper's
    // 100 mallocs count, this thread's 50 in the same window do not
    final class Helper: Sendable {
        let thread = Atomic<UInt>(0)
        let ready = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)  // the window is closed: the helper may free and exit
    }
    let helper = Helper()
    Thread.detachNewThread {
        let blocks = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 100)
        helper.thread.store(UInt(bitPattern: pthread_self()), ordering: .releasing)
        helper.ready.signal()
        helper.go.wait()
        var i = 0
        while i < 100 {
            blocks[i] = malloc(16)
            i += 1
        }
        helper.done.signal()
        helper.closed.wait()
        i = 0
        while i < 100 {
            free(blocks[i])
            i += 1
        }
        blocks.deallocate()
    }
    // The semaphore waits are `noasync` (warned in an async context); the synchronous closure hides that diagnostic,
    // and the waits still block this pool thread. No deadlock: every signal comes from the helper, a `Thread` off the
    // pool.
    let helpers = try { () throws -> Int in
        helper.ready.wait()
        MallocCounter.start(thread: try #require(pthread_t(bitPattern: helper.thread.load(ordering: .acquiring))))
        helper.go.signal()
        var i = 0
        while i < 50 {
            blocks[i] = malloc(16)
            i += 1
        }
        helper.done.wait()
        defer { helper.closed.signal() }
        return MallocCounter.stop()
    }()
    i = 0
    while i < 50 {
        free(blocks[i])
        i += 1
    }
    #expect(helpers == 100, "the helper's 100 mallocs, not this thread's 50: \(helpers)")
}
