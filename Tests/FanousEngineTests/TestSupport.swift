// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import Logging
import Metal
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
        logger: Logger(label: "test"))
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

/// The ports `freeUDPPort` handed out in this process (B115).
private let handedOut = Mutex<Set<UInt16>>([])

/// A UDP port that is free right now: bind port 0 exclusively (no SO_REUSEADDR/SO_REUSEPORT), read back the port the
/// kernel assigned, release it. Unlike a random pick, it never lands on a port another socket holds; Network.framework
/// listeners share ports, so such a port would cross-talk silently. Still check-then-release: the window is short, but
/// the kernel assigns at random (2000 probes: 110 repeats), so two tests that probe before either binds can get the same
/// port; their listeners then share it and every unicast datagram goes to the older one (B115, measured). A port is
/// therefore handed out once per process. ponytail: another process probing in the same window is not covered.
func freeUDPPort() throws -> UInt16 {
    repeat {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        let port = UInt16(bigEndian: address.sin_port)
        if handedOut.withLock({ $0.insert(port).inserted }) { return port }
    } while true
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
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr(host)
    let sent = datagrams.map { bytes in
        withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }
    guard reply > 0 else { return (sent, false) }
    var wait = timeval(tv_sec: Int(reply), tv_usec: Int32((reply - reply.rounded(.down)) * 1e6))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 1500)
    return (sent, recv(fd, &buffer, buffer.count, 0) > 0)
}

/// Removes what `tempDir` and `tempFile` handed out in a test once that test ends. The list is task-local: it reaches
/// child tasks and `Task {}`, not `offPool` or GCD; a path made there is not registered, and the test removes it itself.
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
    CleansTempFiles.current?.urls.withLock { $0.append(url) }
    return url
}

/// A fresh directory `prefix`-<UUID> under the temporary directory; removed after the test (see `CleansTempFiles`).
func tempDir(_ prefix: String) throws -> URL {
    let url = tempFile(prefix)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A socket on 127.0.0.1:`port` whose `receive` waits at most `timeout` seconds; nil = nothing came.
final class UDPCatcher {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    init(port: UInt16, timeout: Double) throws {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let bound = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
    }
    deinit { close(fd) }
    func receive() -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 1500)
        let count = recv(fd, &buffer, buffer.count, 0)
        return count > 0 ? Array(buffer[0..<count]) : nil
    }
}

/// The counter sees allocations of the measured thread, malloc and Swift objects alike, and not those of another thread
/// in the same window. Loops are `while` loops: a `for` over a range allocates in a debug build.
@Test(.enabled(if: MallocCounter.availableOrRequired, "malloc_logger not exported by libsystem_malloc on this macOS"))
func mallocCounterCountsOnlyTheMeasuredThread() async throws {
    try #require(MallocCounter.available, "malloc_logger not exported by libsystem_malloc on this macOS")
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
