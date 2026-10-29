// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import FanousCore
import Logging
import Metal
import QuartzCore
import simd
import Synchronization

/// Composites all layers of one canvas and, when a drawable is given, runs the
/// output pass (DESIGN.md §4.3–4.5). Allocation-free in steady state.
public final class Compositor: @unchecked Sendable {
    public let context: MetalContext
    public private(set) var canvasWidth: Int
    public private(set) var canvasHeight: Int
    public private(set) var fps: Double
    public let metrics: MetricsRing
    public let parameters: TripleBuffer<ParameterSnapshotSlot>
    public private(set) var layers: [RenderLayer] = []
    /// Signalled when a layer wants other media (the media loader waits on it).
    nonisolated(unsafe) public var loaderWake: DispatchSemaphore?
    /// Runs after the canvas pass on the same command buffer (Syphon output publishes the completed canvas).
    nonisolated(unsafe) public var canvasPublished: ((MTLTexture, MTLCommandBuffer) -> Void)?
    /// Without a drawable the output pass renders into this texture instead (tests, headless previews).
    nonisolated(unsafe) public var offscreenOutput: MTLTexture?
    /// Browser previews (DESIGN.md §11.3): draws the canvas into a small pixel buffer on the same command buffer.
    nonisolated(unsafe) public var previewTap: ((MTLTexture, MTLCommandBuffer, Double) -> Void)?
    /// Timecode for layers in the Timecode play mode (DESIGN.md §15.1); offsets in frames of the timecode rate.
    nonisolated(unsafe) public var timecode: TimecodeClock?
    nonisolated(unsafe) public var timecodeOffsets = TimecodeOffsets(project: 0, layers: [:])
    /// Output regions of the master display (DESIGN.md §9): nil = the whole drawable shows the canvas.
    /// Replaced as one reference by Control; the tick reads it once.
    nonisolated(unsafe) public var outputSet: OutputSet?
    /// Engine only: with nothing consuming the canvas (no drawable, preview, Syphon client or CITP stream) a tick
    /// still runs hand-off, clocks, audio and decoder requests, but encodes no GPU work. Off by default (tests read back).
    nonisolated(unsafe) public var skipsIdleWork = false
    /// True while a browser preview or CITP console wants canvas frames.
    nonisolated(unsafe) public var previewWanted: (() -> Bool)?
    /// True while a Syphon client is attached.
    nonisolated(unsafe) public var canvasPublishedWanted: (() -> Bool)?
    /// Multi-server sync (DESIGN.md §23): the group table and the packet slot. Set before the first tick.
    nonisolated(unsafe) var sync: (receiver: SyncReceiver, sender: SyncSender)?
    /// The receiver's table as this tick reads it, with this tick's local masters added as they are prepared.
    private var syncTable = SyncTable()
    /// This tick's master clocks.
    private var syncClocks: [SyncPacket.Layer] = []
    /// Written by `prepare` for the layer being prepared.
    private var syncStatus = LayerSyncStatus()
    private let mappedUniformBuffers: [MTLBuffer]
    /// 256 bytes per slice draw: enough for 64 slices across the outputs of one display.
    static let mappedUniformsLength = 256 * 64

    /// One canvas: its three textures (triple-buffered, one index for all canvases) and their render passes.
    final class CanvasTarget {
        let id: Int
        let width: Int
        let height: Int
        let label: String
        let textures: [MTLTexture]
        let passes: [MTLRenderPassDescriptor]
        /// Passes in a row that drew nothing: after three every texture is black, so an empty canvas is not cleared again.
        var emptyPasses = 0
        init(device: MTLDevice, id: Int, width: Int, height: Int) throws {
            self.id = id
            self.width = width
            self.height = height
            label = "canvas \(id)"
            (textures, passes) = try Compositor.makeCanvases(device: device, width: width, height: height)
        }
    }

    /// Canvas 1 first (DESIGN.md §4.3: one render pass per canvas per tick). Replaced only by `reconfigure`.
    private var targets: [CanvasTarget]
    /// Canvas id per layer index (a project setting, `layer.set`); layers beyond the list are on canvas 1, a layer on a
    /// canvas that does not exist (yet) is not drawn. Replaced as a whole by Control.
    public var layerCanvas: [Int] {
        get { layerCanvasBox.withLock { $0 } }
        set { layerCanvasBox.withLock { $0 = newValue } }
    }
    private let layerCanvasBox = Mutex<[Int]>([])
    /// `layerCanvas` as this tick reads it: taken once per tick (no lock wait on the render thread).
    private var tickLayerCanvas: [Int] = []
    /// Canvas ids that render, canvas 1 first.
    public var canvasIDs: [Int] { targets.map(\.id) }
    /// Texture index the outputs and taps of the running tick read (the drawn one, or the latest on reuse).
    private var tickIndex = 2
    private let outputPass = MTLRenderPassDescriptor()
    private let uniformBuffers: [MTLBuffer]
    private let outputUniformBuffers: [MTLBuffer]
    static let uniformStride = 256
    private let maxLayers: Int
    private var canvasIndex = 0
    private var lastTarget = 0.0
    /// The thread that ran the last tick (the driver's); the bench counts its allocations (§4.6, B97).
    /// `pthread_t` bits, 0 before the first tick.
    package let tickThread = Atomic<UInt>(0)
    private var lastSequence: UInt64 = 0
    /// Static-picture reuse (nothing visible changed since the canvas was last drawn): what the last drawn canvas showed.
    private var drawItems: [DrawItem] = []
    private var drawnItems: [DrawItem] = []
    private var drawnSequence: UInt64 = 0
    private var drawnTime: Float = 0
    /// This tick reused the last canvas: its own selection is still in `drawItems` (`drawLayer`).
    private var reusedThisTick = false
    private var canvasValid = false
    /// `drawThumbnails`: 3 × `maxLayers` × 2 uniform slots, made on first use; the third the next call writes.
    private var thumbnailUniforms: MTLBuffer?
    private var thumbnailRing = 0
    private var reuseStreak = 0
    private var drawnGPUErrors = 0
    private let logger: Logger
    public let ticks = Atomic<Int>(0)
    public let encoderFailures = Atomic<Int>(0)
    public let completed = Atomic<Int>(0)
    public let gpuErrors = Atomic<Int>(0)
    public let outputEncoderFailures = Atomic<Int>(0)
    /// Ticks that encoded no GPU work because nobody watched, and ticks that reused the last canvas (nothing changed).
    public let idleTicks = Atomic<Int>(0)
    public let reusedCanvases = Atomic<Int>(0)
    /// Ring index and Master intensity (Float bits) of the latest completed canvases, from one tick: a secondary display's
    /// Freeze keeps the Master its canvases were drawn with, which can be a tick older than the Master it reads (B100).
    /// Stored just before `canvasIndex` moves on. Master 0 until a tick completes (start, new canvases): a Freeze waits.
    private let completedCanvas = Atomic<UInt64>(Compositor.packCompleted(index: 2, master: 0))
    private static func packCompleted(index: Int, master: Float) -> UInt64 { UInt64(index) << 32 | UInt64(master.bitPattern) }
    nonisolated(unsafe) public var lastGPUError: String = ""
    /// Committed command buffers not yet booked, with their metrics slot and target time (B105): a completion handler
    /// costs 3 mallocs per tick, polling the status costs none. Filled round-robin, so the entry at `nextInFlight` is
    /// the oldest. Each tick books the finished ones first, so GPU time, late flags, `completed` and `gpuErrors` arrive
    /// a few ticks late. Holding a completed buffer pins nothing: Metal releases its drawable and textures at completion
    /// (measured, PR #88 review). When ticks stop, the last buffers stay unbooked: dropped on purpose, nothing waits on them.
    private struct InFlight {
        var buffer: MTLCommandBuffer?
        var slot = 0
        var target = 0.0
    }
    private var inFlight = [InFlight](repeating: InFlight(), count: 8)
    private var nextInFlight = 0
    /// Ticks that found all 8 entries unfinished and waited for the oldest (the GPU 8 buffers behind).
    public let completionWaits = Atomic<Int>(0)

    public init(
        context: MetalContext, canvasWidth: Int, canvasHeight: Int, fps: Double, maxLayers: Int, metrics: MetricsRing,
        parameters: TripleBuffer<ParameterSnapshotSlot>, logger: Logger
    ) throws {
        self.context = context
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fps = fps
        canvasSize = Atomic(Self.pack(canvasWidth, canvasHeight))
        self.maxLayers = maxLayers
        self.metrics = metrics
        self.parameters = parameters
        self.logger = logger
        drawItems.reserveCapacity(maxLayers * 2)
        drawnItems.reserveCapacity(maxLayers * 2)
        syncClocks.reserveCapacity(SyncPacket.maxLayers)
        targets = [try CanvasTarget(device: context.device, id: 1, width: canvasWidth, height: canvasHeight)]
        outputPass.colorAttachments[0].loadAction = .dontCare
        outputPass.colorAttachments[0].storeAction = .store
        // two uniform slots per layer: the playing media and the outgoing one during a dissolve
        uniformBuffers = try (0..<3).map { _ in
            guard let buffer = context.device.makeBuffer(length: Self.uniformStride * maxLayers * 2, options: .storageModeShared) else { throw RenderError.pipeline("uniforms") }
            return buffer
        }
        outputUniformBuffers = try (0..<3).map { _ in
            guard let buffer = context.device.makeBuffer(length: 256, options: .storageModeShared) else { throw RenderError.pipeline("output uniforms") }
            return buffer
        }
        mappedUniformBuffers = try (0..<3).map { _ in
            guard let buffer = context.device.makeBuffer(length: Self.mappedUniformsLength, options: .storageModeShared) else { throw RenderError.pipeline("mapped uniforms") }
            return buffer
        }
        outputPass.colorAttachments[0].loadAction = .clear
        outputPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    fileprivate static func makeCanvases(device: MTLDevice, width: Int, height: Int) throws -> ([MTLTexture], [MTLRenderPassDescriptor]) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let textures = try (0..<3).map { i in
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.pipeline("canvas texture \(width)×\(height)") }
            texture.label = "canvas \(i)"
            return texture
        }
        let passes = textures.map { texture in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return pass
        }
        return (textures, passes)
    }

    /// New size and rate of canvas 1 (B31); the other canvases stay.
    public func reconfigure(width: Int, height: Int, fps: Double) throws {
        let others = targets.dropFirst().map { ProjectDocument.CanvasLayout.Size(id: $0.id, width: $0.width, height: $0.height) }
        try reconfigure(ProjectDocument.CanvasLayout(fps: fps, canvases: [.init(id: targets[0].id, width: width, height: height)] + others))
    }

    /// New canvases, sizes and rate (B31, multiple canvases). Only while no driver ticks or presents
    /// (`OutputCoordinator.setCanvases` stops them); throws before changing anything when the textures cannot be made,
    /// so the old canvases keep running. A canvas whose size did not change keeps its textures.
    public func reconfigure(_ layout: ProjectDocument.CanvasLayout) throws {
        // Metal asserts (instead of returning nil) beyond its texture limit; refuse here so the old canvas runs on
        guard !layout.canvases.isEmpty, layout.fps > 0 else { throw RenderError.pipeline("a layout needs a canvas and a rate") }
        for c in layout.canvases where !(1...16384).contains(c.width) || !(1...16384).contains(c.height) {
            throw RenderError.pipeline("canvas \(c.width)×\(c.height) at \(layout.fps) fps is not possible")
        }
        let made = try layout.canvases.map { c in
            try targets.first { $0.id == c.id && $0.width == c.width && $0.height == c.height } ?? CanvasTarget(device: context.device, id: c.id, width: c.width, height: c.height)
        }
        // Clear the new canvases to black (latestCanvas is defined before the first tick) on the shared queue and
        // wait: command buffers on one queue run in commit order, so every in-flight tick has finished with the
        // old textures and the uniform slots when this one completes.
        guard let commandBuffer = context.queue.makeCommandBuffer() else { throw RenderError.pipeline("canvas clear") }
        for target in made where !targets.contains(where: { $0 === target }) {
            for pass in target.passes {
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.pipeline("canvas clear") }
                encoder.endEncoding()
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        targets = made
        canvasWidth = made[0].width
        canvasHeight = made[0].height
        self.fps = layout.fps
        canvasSize.store(Self.pack(canvasWidth, canvasHeight), ordering: .releasing)
        completedCanvas.store(Self.packCompleted(index: 2, master: 0), ordering: .releasing)
        canvasIndex = 0
        tickIndex = 2
        canvasValid = false
        lastTarget = 0
    }

    private let canvasSize: Atomic<UInt64>
    private static func pack(_ width: Int, _ height: Int) -> UInt64 { UInt64(width) << 32 | UInt64(height) }
    /// Canvas size for other threads (the media loader making generators): both values from one change.
    public var canvasSizeSnapshot: (width: Int, height: Int) {
        let packed = canvasSize.load(ordering: .acquiring)
        return (Int(packed >> 32), Int(packed & 0xFFFF_FFFF))
    }

    /// A generator made before a canvas change (or at canvas 1's size for a layer on another canvas) is re-made at the
    /// size of its layer's canvas.
    private func fitGenerator(_ playback: LayerPlayback?, to target: CanvasTarget) {
        guard let generator = playback?.live as? GeneratorSource,
            generator.texture.width != target.width || generator.texture.height != target.height
        else { return }
        generator.resize(width: target.width, height: target.height)
    }

    /// Index into `targets` of a layer's canvas, nil when that canvas does not render.
    private func target(forLayer index: Int) -> Int? {
        let id = index < tickLayerCanvas.count ? tickLayerCanvas[index] : 1
        return targets.firstIndex { $0.id == id }
    }

    public func setLayers(_ layers: [RenderLayer]) { self.layers = Array(layers.prefix(maxLayers)) }

    private var firstTarget = 0.0

    /// Folder 0 generators that are visible this tick, redrawn on its command buffer before the canvas pass samples them.
    /// Kinds 100–107 never change (drawn once when created), the clock (112) only when the second changes; a generator
    /// on a layer at intensity 0 is not in `drawItems`, and is drawn on the first tick it becomes visible.
    private func encodeGenerators(_ commandBuffer: MTLCommandBuffer, target: Double) {
        var u = GeneratorUniforms()
        var prepared = false
        var local = tm()
        var localSecond = -1
        for item in drawItems {
            guard let generator = item.playback.live as? GeneratorSource, !generator.isStatic else { continue }
            if generator.kind == 112 {
                if localSecond < 0 {
                    var now = time(nil)
                    localtime_r(&now, &local)
                    localSecond = Int(now)
                }
                if generator.drawnSecond == localSecond { continue }
                generator.drawnSecond = localSecond
            }
            if !prepared {
                prepared = true
                if firstTarget == 0 { firstTarget = target }
                let frame = ticks.load(ordering: .relaxed)
                u.frame = UInt32(truncatingIfNeeded: frame)
                u.time = Float((target - firstTarget).truncatingRemainder(dividingBy: 86_400))
                // test card: incoming timecode when it runs, otherwise the running time at the canvas rate
                if let timecode, let frames = timecode.frames(at: target) {
                    let tc = Timecode(frameCount: Int(frames), rate: timecode.read(at: target).rate)
                    u.putTime(h: tc.hours, m: tc.minutes, s: tc.seconds, f: tc.frames, at: 0)
                } else {
                    let elapsed = max(0, target - firstTarget)
                    let whole = Int(elapsed)
                    u.putTime(h: whole / 3600 % 24, m: whole / 60 % 60, s: whole % 60, f: Int((elapsed - Double(whole)) * fps), at: 0)
                }
                var n = frame % 1_000_000
                for i in (11..<17).reversed() {
                    u.put(n % 10, at: i)
                    n /= 10
                }
            }
            if generator.kind == 112 {
                var clock = u
                clock.putTime(h: Int(local.tm_hour), m: Int(local.tm_min), s: Int(local.tm_sec), f: -1, at: 0)
                generator.encode(into: commandBuffer, uniforms: clock)
            } else {
                generator.encode(into: commandBuffer, uniforms: u)
            }
        }
    }

    private func needsPixels(drawable: CAMetalDrawable?) -> Bool {
        !skipsIdleWork || drawable != nil || offscreenOutput != nil || previewWanted?() == true || canvasPublishedWanted?() == true
    }

    /// Canvas 1 as completed by the previous tick (for previews and other outputs).
    public var latestCanvas: MTLTexture { targets[0].textures[(canvasIndex + 2) % 3] }

    /// A canvas as completed by the previous tick; nil when it does not render.
    public func latestCanvas(id: Int) -> MTLTexture? { targets.first { $0.id == id }?.textures[(canvasIndex + 2) % 3] }

    /// Every canvas of one completed tick, by id, and the Master they were drawn with: the targets and one load of the
    /// index and Master (secondary displays).
    private func completedCanvases() -> (targets: [CanvasTarget], index: Int, master: Float) {
        let packed = completedCanvas.load(ordering: .acquiring)
        return (targets, Int(packed >> 32), Float(bitPattern: UInt32(truncatingIfNeeded: packed)))
    }

    /// Compositor thread, during a tick (previews, taps): the canvas this tick shows; nil when it does not render.
    public func tickCanvas(_ id: Int) -> MTLTexture? { targets.first { $0.id == id }?.textures[tickIndex] }

    /// One compositor tick. `target` is the target presentation time (host seconds).
    public func tick(target: Double, drawable: CAMetalDrawable?) {
        ticks.wrappingAdd(1, ordering: .relaxed)
        tickThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
        for i in inFlight.indices { harvest(i) }
        let cpuStart = CACurrentMediaTime()
        var record = FrameRecord()
        record.target = target
        let interval = 1 / fps
        let dt: Double
        if lastTarget > 0 {
            let ticks = ((target - lastTarget) / interval).rounded()
            record.missed = UInt16(max(0, min(65535, ticks - 1)))
            dt = target - lastTarget
        } else {
            dt = interval
        }
        lastTarget = target

        let snapshot = parameters.read()
        if snapshot.sequence != lastSequence {
            lastSequence = snapshot.sequence
            if snapshot.receivedAt > 0 { record.dmxToPhotonMicros = UInt32(max(0, min(4e9, (target - snapshot.receivedAt) * 1e6))) }
        }

        let wantsPixels = needsPixels(drawable: drawable)
        var frame = TickContext(
            dt: snapshot.masterControl == .freezeAll ? 0 : dt, target: target, masterIntensity: snapshot.masterControl == .blackout ? 0 : snapshot.master,
            masterSpeed: snapshot.masterSpeed, time: Float(target.truncatingRemainder(dividingBy: 3600)), now: cpuStart)  // ponytail: one strobe phase jump per hour; per-layer Double phase if it shows
        drawItems.removeAll(keepingCapacity: true)

        layerCanvasBox.withLockIfAvailable { tickLayerCanvas = $0 }  // busy: last tick's assignment once more
        sync?.receiver.table.withLockIfAvailable { syncTable.copy(from: $0) }  // busy: last tick's table once more
        syncClocks.removeAll(keepingCapacity: true)
        // Everything that is not GPU work: hand-off, clocks, audio, decoder requests, frame selection.
        for layer in layers {
            let p = layer.index < snapshot.layers.count ? snapshot.layers[layer.index] : LayerParameters()
            handOff(layer: layer, p: p, target: target)
            let canvas = self.target(forLayer: layer.index) ?? -1
            if canvas >= 0 {
                fitGenerator(layer.current, to: targets[canvas])
                fitGenerator(layer.outgoing, to: targets[canvas])
            }
            var progress: Float = 1
            if let outgoing = layer.outgoing {
                let elapsed = target - layer.dissolveStart
                if layer.dissolveDuration <= 0 || elapsed >= layer.dissolveDuration {
                    retire(outgoing, from: layer)
                    layer.outgoing = nil
                } else {
                    progress = Float(elapsed / layer.dissolveDuration)
                }
            }
            let retrigger = p.retrigger && !layer.retriggerLatched
            layer.retriggerLatched = p.retrigger
            syncStatus = LayerSyncStatus(role: p.sync)
            if let outgoing = layer.outgoing {
                // normal: the old picture stays underneath while the new fades in; other modes (and a fade to
                // no media at all) crossfade the weights
                let underneath = p.blendMode == .normal && layer.current != nil
                prepare(outgoing, p, weight: underneath ? 1 : 1 - progress, retrigger: false, slot: layer.index * 2 + 1, canvas: canvas, in: &frame)
            }
            if let current = layer.current {
                prepare(current, p, weight: progress, retrigger: retrigger, slot: layer.index * 2, canvas: canvas, in: &frame)
                if case .master(let group) = p.sync { publishMaster(current, p, group: group, layer: layer.index, in: frame) }
            }
            if syncStatus != layer.syncStatusWritten {  // a layer with Sync off costs no lock
                let status = syncStatus
                if layer.syncStatus.withLockIfAvailable({ $0 = status }) != nil { layer.syncStatusWritten = status }
            }
            if !layer.retireLater.isEmpty {
                layer.retired.withLockIfAvailable { list in
                    list.append(contentsOf: layer.retireLater)
                    layer.retireLater.removeAll(keepingCapacity: true)
                }
            }
        }
        if let sync, !syncClocks.isEmpty {
            // the sender thread sends the slot; local slaves read the table from the next tick on
            let tick = UInt32(truncatingIfNeeded: ticks.load(ordering: .relaxed))
            let sendTime = CACurrentMediaTime()
            sync.sender.slots.write { slot in
                slot.packet.tick = tick
                slot.packet.sendTime = sendTime
                slot.packet.layers.removeAll(keepingCapacity: true)
                slot.packet.layers.append(contentsOf: syncClocks)
            }
            sync.sender.wake.signal()
            sync.receiver.table.withLockIfAvailable { table in
                for clock in syncClocks { table.offer(clock, from: sync.receiver.machine, at: frame.now) }
            }
        }

        guard wantsPixels else {
            // nobody watches: no command buffer; the metrics still count the frame, marked idle
            canvasValid = false
            idleTicks.wrappingAdd(1, ordering: .relaxed)
            record.idle = true
            record.layersDrawn = 0
            record.textureMisses = frame.misses
            record.cpuMicros = UInt32((CACurrentMediaTime() - cpuStart) * 1e6)
            _ = metrics.write(record)
            return
        }

        guard let commandBuffer = context.queue.makeCommandBuffer() else {
            encoderFailures.wrappingAdd(1, ordering: .relaxed)
            return
        }
        // a picture that did not change since the canvas was drawn is not drawn again (but at least once a second)
        let reuse = skipsIdleWork && canvasValid && !frame.dynamic && snapshot.sequence == drawnSequence && reuseStreak < Int(fps) && drawItems == drawnItems
            && gpuErrors.load(ordering: .relaxed) == drawnGPUErrors
        reusedThisTick = reuse
        if reuse {
            reuseStreak += 1
            reusedCanvases.wrappingAdd(1, ordering: .relaxed)
        } else {
            reuseStreak = 0
            encodeGenerators(commandBuffer, target: target)
            // one pass per canvas; each draws only the layers assigned to it (a canvas without any still clears)
            let uniforms = uniformBuffers[canvasIndex]
            for (index, canvas) in targets.enumerated() {
                // an empty canvas that is already black in all three textures is not cleared again
                let empty = !drawItems.contains { $0.canvas == index }
                canvas.emptyPasses = empty ? canvas.emptyPasses + 1 : 0
                if empty && canvas.emptyPasses > 3 { continue }
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: canvas.passes[canvasIndex]) else {
                    encoderFailures.wrappingAdd(1, ordering: .relaxed)
                    canvasValid = false
                    return
                }
                encoder.label = canvas.label
                encoder.setRenderPipelineState(context.layerPipeline)
                encoder.setFragmentSamplerState(context.linearSampler, index: 0)
                encoder.setFragmentSamplerState(context.nearestSampler, index: 1)
                for item in drawItems where item.canvas == index {
                    encode(item, uniforms: uniforms, time: frame.time, canvasWidth: canvas.width, canvasHeight: canvas.height, with: encoder)
                }
                encoder.endEncoding()
            }
            Swift.swap(&drawnItems, &drawItems)
            drawnSequence = snapshot.sequence
            drawnTime = frame.time
            drawnGPUErrors = gpuErrors.load(ordering: .relaxed)
            canvasValid = true
        }
        tickIndex = reuse ? (canvasIndex + 2) % 3 : canvasIndex
        let canvas = targets[0].textures[tickIndex]
        canvasPublished?(canvas, commandBuffer)
        previewTap?(canvas, commandBuffer, target)

        if let target = drawable?.texture ?? offscreenOutput {
            outputPass.colorAttachments[0].texture = target
            if let set = outputSet { OutputPass.holdFrozen(set, canvas: { tickCanvas($0) }, outputs: snapshot.outputs, master: frame.masterIntensity, buffer: commandBuffer) }
            if let set = outputSet, let output = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
                output.label = "mapped output"
                OutputPass.draw(
                    set, canvas: { tickCanvas($0) }, encoder: output, context: context, uniforms: mappedUniformBuffers[canvasIndex],
                    master: snapshot.masterControl == .blackout ? 0 : snapshot.master, masterPattern: snapshot.testPattern, outputs: snapshot.outputs)
                output.endEncoding()
            } else if let output = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
                // the Master pattern at full level only here, without an output set (tests, fanous-bench); the engine's
                // displays always have one (OutputCoordinator), so on stage patterns follow the Dimmer and Blackout
                output.label = "output"
                let buffer = outputUniformBuffers[canvasIndex]
                buffer.contents().assumingMemoryBound(to: OutputUniforms.self).pointee = {
                    var o = OutputUniforms()
                    o.size = SIMD2(Float(target.width), Float(target.height))
                    o.pattern = UInt32(snapshot.testPattern.rawValue)
                    o.index = 1
                    return o
                }()
                output.setRenderPipelineState(context.outputPipeline)
                output.setFragmentBuffer(buffer, offset: 0, index: 0)
                output.setFragmentTexture(canvas, index: 0)
                output.setFragmentSamplerState(context.linearSampler, index: 0)
                output.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                output.endEncoding()
            } else {
                outputEncoderFailures.wrappingAdd(1, ordering: .relaxed)
            }
            if let drawable { commandBuffer.present(drawable) }
        }

        record.layersDrawn = frame.drawn
        record.textureMisses = frame.misses
        record.cpuMicros = UInt32((CACurrentMediaTime() - cpuStart) * 1e6)
        let slot = metrics.write(record)
        commandBuffer.commit()
        if let oldest = inFlight[nextInFlight].buffer {
            completionWaits.wrappingAdd(1, ordering: .relaxed)
            oldest.waitUntilCompleted()
            harvest(nextInFlight)
        }
        inFlight[nextInFlight] = InFlight(buffer: commandBuffer, slot: slot, target: target)
        nextInFlight = (nextInFlight + 1) % inFlight.count
        if !reuse {
            completedCanvas.store(Self.packCompleted(index: canvasIndex, master: frame.masterIntensity), ordering: .releasing)
            canvasIndex = (canvasIndex + 1) % 3
        }
    }

    /// Books entry `i` of `inFlight` if its buffer finished: GPU time and lateness into its metrics record, the counters.
    private func harvest(_ i: Int) {
        guard let buffer = inFlight[i].buffer, buffer.status == .completed || buffer.status == .error else { return }
        completed.wrappingAdd(1, ordering: .relaxed)
        if buffer.status == .error {
            gpuErrors.wrappingAdd(1, ordering: .relaxed)
            lastGPUError = "\(buffer.error.map { "\($0)" } ?? "unknown")"
        }
        let gpuMicros = UInt32(max(0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1e6))
        metrics.complete(slot: inFlight[i].slot, gpuMicros: gpuMicros, late: buffer.gpuEndTime > inFlight[i].target)
        inFlight[i].buffer = nil
    }

    struct TickContext {
        let dt: Double
        let target: Double
        let masterIntensity: Float
        let masterSpeed: Float
        let time: Float
        /// Host time at the start of the tick: the age of sync entries is taken against it.
        let now: Double
        var drawn: UInt16 = 0
        var misses: UInt16 = 0
        /// Something on the canvas changes without its frame or the parameters changing (live texture, strobe).
        var dynamic = false
    }

    /// One layer picture to composite this tick; two equal lists mean the same canvas.
    struct DrawItem: Equatable {
        var playback: LayerPlayback
        var frame: DecodedFrame
        var frameIndex: Int
        var p: LayerParameters
        /// Layer intensity × crossfade weight: the alpha. The Master scales the colour instead (B108).
        var intensity: Float
        var master: Float
        var slot: Int
        /// Index into `targets`; −1 = the layer's canvas does not render.
        var canvas: Int

        static func == (l: DrawItem, r: DrawItem) -> Bool {
            l.playback === r.playback && l.frame === r.frame && l.frameIndex == r.frameIndex && l.intensity == r.intensity && l.master == r.master && l.slot == r.slot && l.canvas == r.canvas
        }
    }

    /// Media hand-off with the loader: ask for what the parameters want, take what has been loaded.
    private func handOff(layer: RenderLayer, p: LayerParameters, target: Double) {
        let wanted = p.mediaKey.packed
        if layer.wanted.load(ordering: .relaxed) != wanted {
            layer.wanted.store(wanted, ordering: .relaxed)
            loaderWake?.signal()
        }
        let taken: PendingPlayback? = layer.pending.withLockIfAvailable { box in
            guard box.set else { return nil }
            let copy = box
            box.set = false
            box.playback = nil
            return copy
        } ?? nil
        if let taken {
            if let replaced = layer.staged { retire(replaced, from: layer) }
            if let incoming = taken.playback {
                // start at the in point and let the decoder fill the ring before the swap
                let last = incoming.frameCount - 1
                incoming.clock.retrigger(
                    mode: p.playMode, inFrame: Int((p.inPoint * Float(last)).rounded()), outFrame: Int((p.outPoint * Float(last)).rounded()),
                    frameCount: incoming.frameCount)
                incoming.decoder?.request(frame: Int(incoming.clock.position), direction: p.playMode.isReverse ? -1 : 1)
                layer.staged = incoming
            } else {
                layer.staged = nil
                swap(in: nil, layer: layer, p: p, target: target)  // no media: cut or fade to nothing now
            }
        }
        if let staged = layer.staged, staged.hasFrame {
            layer.staged = nil
            swap(in: staged, layer: layer, p: p, target: target)
        }
    }

    /// The previous frame stays until the first new one is ready, then the cut or dissolve starts.
    private func swap(in incoming: LayerPlayback?, layer: RenderLayer, p: LayerParameters, target: Double) {
        if let current = layer.current {
            if p.dissolve > 0 {
                if let old = layer.outgoing { retire(old, from: layer) }
                layer.outgoing = current
                layer.dissolveStart = target
                layer.dissolveDuration = Double(p.dissolve)
            } else {
                retire(current, from: layer)
            }
        }
        layer.current = incoming
        incoming?.decoder?.audioEnabled.store(true, ordering: .relaxed)
        if incoming?.decoder?.audio != nil { incoming?.decoder?.nudge() }  // the decode thread sleeps without audio to feed
    }

    private func retire(_ playback: LayerPlayback, from layer: RenderLayer) {
        playback.releaseAudio()
        layer.retireLater.append(playback)  // flushed to the loader at the end of the tick
    }

    /// Advances the clock, drives audio and the decoder, picks the frame; queues the picture when it is visible.
    private func prepare(_ playback: LayerPlayback, _ p: LayerParameters, weight: Float, retrigger: Bool, slot: Int, canvas: Int, in ctx: inout TickContext) {
        let last = playback.frameCount - 1
        let inFrame = Int((p.inPoint * Float(last)).rounded())
        let outFrame = Int((p.outPoint * Float(last)).rounded())
        // a slave file follows its group's master and ignores its own play mode, speed, in/out, chase and retrigger;
        // only the current file: a dissolve's outgoing picture keeps its own clock
        var master: SyncTable.Entry?
        if case .slave(let group) = p.sync, slot % 2 == 0, playback.frameCount > 1, playback.live == nil {
            master = syncTable.entries[group - 1]
            syncStatus.state = .noMaster  // no entry ever: its own clock, as if Sync were off
            if let master {
                let age = ctx.now - master.receivedAt
                var state = SlaveClock.state(age: age, interval: 1 / fps)
                if ctx.dt > 0 {  // freeze-all holds a slave like every other layer; the first tick after relocks
                    let follow = SlaveClock.follow(
                        &playback.clock, entry: master.clock, age: age, dt: ctx.dt, interval: 1 / fps, fps: playback.frameRate,
                        frameCount: playback.frameCount)
                    state = follow.state
                    syncStatus.offsetMs = follow.offsetMs
                }
                syncStatus.state = syncTable.conflict(group: group, now: ctx.now) == nil ? state : .conflict
                syncStatus.master = master
            }
        }
        if master == nil, playback.following {
            // the master's direction and end were never this layer's own
            playback.clock.direction = 1
            playback.clock.finished = false
        }
        playback.following = master != nil
        if retrigger && master == nil { playback.clock.retrigger(mode: p.playMode, inFrame: inFrame, outFrame: outFrame, frameCount: playback.frameCount) }
        if master == nil, p.playMode == .timecode, playback.frameCount > 1, let timecode, let frames = timecode.frames(at: ctx.target) {
            // chase: (tc − project offset − layer offset) at the file's rate, looped within in/out
            let offsets = timecodeOffsets
            let seconds = (frames - offsets.project - (offsets.layers[slot / 2 + 1] ?? 0)) / timecode.read(at: ctx.target).rate.exactFrameRate
            let lo = Double(min(inFrame, outFrame)), hi = Double(max(inFrame, outFrame))
            var frame = seconds * playback.frameRate
            let span = hi - lo + 1
            if span > 0 { frame = lo + (frame - lo).truncatingRemainder(dividingBy: span) + (frame < lo ? span : 0) }
            playback.clock.position = min(hi, max(lo, frame))
        }
        let speed: Double
        let frameIndex: Int?
        let direction: Int
        if let master {
            speed = Double(abs(master.clock.rate / master.clock.fps)) * 100
            frameIndex = playback.clock.finished && p.playMode.endsBlack ? nil : Int(playback.clock.position)
            direction = playback.clock.direction < 0 ? -1 : 1
        } else {
            speed = Double(p.speed * ctx.masterSpeed) * 100
            frameIndex = playback.clock.advance(
                dt: ctx.dt, fps: playback.frameRate, speed: speed, mode: p.playMode, inFrame: inFrame, outFrame: outFrame, frameCount: playback.frameCount)
            direction = (p.playMode.isReverse ? -1 : 1) * (playback.clock.direction < 0 ? -1 : 1)
        }
        if let channel = playback.audioChannel {
            // audio only at 100 % forward (ADR-0019); freeze/scrub/timecode and once-finished are silent
            let playing = frameIndex != nil && !playback.clock.finished && ctx.dt > 0
                && (master != nil || !(p.playMode == .freeze || p.playMode == .scrub || p.playMode == .timecode))
            let active = playing && direction > 0 && abs(speed - 100) < 0.5
            // a forward loop plays [in, out + 1) frames; the audio reads across its wrap (not when the audio is shorter than that)
            var loop: (start: Double, end: Double)?
            if master == nil, p.playMode == .loopForward, outFrame > inFrame, let reader = playback.decoder?.audio?.reader,
                Double(outFrame + 1) / playback.frameRate <= reader.duration + 1 / playback.frameRate
            {
                loop = (Double(inFrame) / playback.frameRate, Double(outFrame + 1) / playback.frameRate)
            }
            channel.setState(wantedPTS: playback.clock.position / max(1, playback.frameRate), active: active, volume: p.audioVolume * weight, pan: p.audioPan, loop: loop)
        }
        guard let frameIndex else { return }  // once-then-black has finished
        let intensity = p.intensity * weight
        let visible = intensity * ctx.masterIntensity > 0
        // invisible for a while: the ring and the last frame stay, the clock keeps running, decoding resumes when visible
        guard playback.hold.allowsRequests(visible: visible, at: ctx.target) else { return }
        playback.decoder?.request(frame: frameIndex, direction: direction)
        guard visible else { return }
        guard let frame = playback.frame(at: frameIndex, direction: direction), frame.texture0 != nil else {
            ctx.misses += 1
            return
        }
        if playback.live != nil || p.effect1 == .strobe || p.effect2 == .strobe { ctx.dynamic = true }
        ctx.drawn += 1
        drawItems.append(DrawItem(playback: playback, frame: frame, frameIndex: frameIndex, p: p, intensity: intensity, master: ctx.masterIntensity, slot: slot, canvas: canvas))
    }

    /// A master file's clock after this tick's advance (DESIGN.md §23.2): into the packet, and into this tick's table so
    /// a local slave prepared after it sees the same tick. `rate` is how the clock really moves, 0 when it does not.
    private func publishMaster(_ playback: LayerPlayback, _ p: LayerParameters, group: Int, layer: Int, in ctx: TickContext) {
        guard let sync, playback.frameCount > 1, playback.live == nil, syncClocks.count < SyncPacket.maxLayers else { return }
        let clock = playback.clock
        let direction: Double = (p.playMode.isReverse ? -1 : 1) * (clock.direction < 0 ? -1 : 1)
        let last = Float(playback.frameCount - 1)
        let range = (p.outPoint * last).rounded() > (p.inPoint * last).rounded()  // as `prepare`; in ≥ out: the clock stands
        let moving = ctx.dt > 0 && range && !clock.finished && !(p.playMode == .freeze || p.playMode == .scrub || p.playMode == .timecode)
        let entry = SyncPacket.Layer(
            group: UInt8(group), layer: UInt8(layer + 1), mediaKey: UInt16(truncatingIfNeeded: playback.key.packed), fps: Float(playback.frameRate),
            position: clock.position, direction: Int8(direction), finished: clock.finished,
            rate: moving ? Float(Double(p.speed * ctx.masterSpeed) * playback.frameRate * direction) : 0)
        syncClocks.append(entry)
        syncTable.offer(entry, from: sync.receiver.machine, at: ctx.now)
    }

    /// u0 v0 u1 v1 after crop, v0 at the picture's top: for a bottom-up texture (Syphon) the top of the picture
    /// is at v = 1, so v0 and v1 swap and the crop sides swap with them.
    static func uvRect(cropLeft: Float, cropTop: Float, cropRight: Float, cropBottom: Float, bottomUp: Bool) -> SIMD4<Float> {
        bottomUp
            ? SIMD4(cropLeft, 1 - cropTop, 1 - cropRight, cropBottom)
            : SIMD4(cropLeft, cropTop, 1 - cropRight, 1 - cropBottom)
    }

    private func encode(_ item: DrawItem, uniforms: MTLBuffer, time: Float, canvasWidth: Int, canvasHeight: Int, with encoder: MTLRenderCommandEncoder) {
        let p = item.p, playback = item.playback, frame = item.frame
        guard let texture0 = frame.texture0 else { return }
        let mediaWidth = playback.live != nil ? texture0.width : playback.width
        let mediaHeight = playback.live != nil ? texture0.height : playback.height
        let (transform, quad) = Self.geometry(for: p, mediaWidth: mediaWidth, mediaHeight: mediaHeight, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        var u = LayerUniforms()
        u.transform = transform
        u.quadRect = quad
        u.uvRect = Self.uvRect(cropLeft: p.cropLeft, cropTop: p.cropTop, cropRight: p.cropRight, cropBottom: p.cropBottom, bottomUp: frame.bottomUp)
        u.colour = SIMD4(p.red, p.green, p.blue, item.intensity)
        u.adjust = SIMD4(p.brightness, p.contrast, p.saturation, p.hue)
        u.effect1 = SIMD4(Float(p.effect1.rawValue), p.effect1A, p.effect1B, frame.bottomUp ? 1 : 0)  // w: rows bottom-up
        u.effect2 = SIMD4(Float(p.effect2.rawValue), p.effect2A, p.effect2B, 0)
        u.texel = SIMD4(1 / Float(max(1, mediaWidth)), 1 / Float(max(1, mediaHeight)), Float(mediaWidth) / Float(max(1, mediaHeight)), time)
        u.kind = frame.kind.rawValue
        u.blend = UInt32(p.blendMode.rawValue)
        u.master = item.master
        let offset = item.slot * Self.uniformStride
        (uniforms.contents() + offset).assumingMemoryBound(to: LayerUniforms.self).pointee = u
        let blur = (p.effect1 == .blur && p.effect1A > 0) || (p.effect2 == .blur && p.effect2A > 0)
        let edge = p.effect1 == .edge || p.effect2 == .edge
        encoder.setRenderPipelineState(context.layerPipelines[(blur ? 1 : 0) | (edge ? 2 : 0)])
        encoder.setVertexBuffer(uniforms, offset: offset, index: 0)
        encoder.setFragmentBuffer(uniforms, offset: offset, index: 0)
        encoder.setFragmentTexture(texture0, index: 0)
        encoder.setFragmentTexture(frame.texture1 ?? texture0, index: 1)
        encoder.setFragmentTexture(frame.texture2 ?? texture0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Layer quad in canvas units (half-height = 1, x spans ±aspect) and the
    /// perspective transform to clip space: fit → crop → scale → rotate XYZ →
    /// translate → camera at z = 2 (DESIGN.md §4.3).
    static func geometry(for p: LayerParameters, mediaWidth: Int, mediaHeight: Int, canvasWidth: Int, canvasHeight: Int) -> (simd_float4x4, SIMD4<Float>) {
        let aspect = Float(canvasWidth) / Float(max(1, canvasHeight))
        let mediaAspect = Float(mediaWidth) / Float(max(1, mediaHeight))
        var w: Float, h: Float
        switch p.fitMode {
        case .fit:
            if mediaAspect > aspect { w = aspect; h = aspect / mediaAspect } else { h = 1; w = mediaAspect }
        case .fill:
            if mediaAspect > aspect { h = 1; w = mediaAspect } else { w = aspect; h = aspect / mediaAspect }
        case .stretch:
            w = aspect; h = 1
        case .native:
            h = Float(mediaHeight) / Float(max(1, canvasHeight)); w = Float(mediaWidth) / Float(max(1, canvasHeight))
        }
        let quad = SIMD4(-w + 2 * w * p.cropLeft, -h + 2 * h * p.cropBottom, w - 2 * w * p.cropRight, h - 2 * h * p.cropTop)
        let scale = simd_float4x4(diagonal: SIMD4(p.scaleX, p.scaleY, 1, 1))
        let (cx, sx) = (cos(p.rotationX), sin(p.rotationX))
        let (cy, sy) = (cos(p.rotationY), sin(p.rotationY))
        let (cz, sz) = (cos(p.rotationZ), sin(p.rotationZ))
        let rx = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, cx, sx, 0), SIMD4(0, -sx, cx, 0), SIMD4(0, 0, 0, 1))
        let ry = simd_float4x4(SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0), SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1))
        let rz = simd_float4x4(SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(p.positionX * 2 * aspect, p.positionY * 2, p.positionZ, 1)
        // camera distance 2: z = +1 doubles the size, z = −1 shows it at two thirds; near plane 0.2 in front of the camera
        let distance: Float = 2, near: Float = 0.1
        let projection = simd_float4x4(SIMD4(1 / aspect, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, -1 / distance, -1 / distance), SIMD4(0, 0, 1 - near, 1))
        return (projection * translate * rz * ry * rx * scale, quad)
    }

    // MARK: Layer preview

    /// Draws layer `index` (0-based) alone as the last canvas pass drew it (transform, crop, colour, effects, intensity,
    /// both quads of a dissolve), with normal blending over black, into `pass` (canvas format, canvas aspect, any size).
    /// Render thread, after the canvas pass of the tick (`previewTap`); a layer with nothing on the canvas stays black.
    /// `uniforms` (the caller's) holds 3 × 2 slots of `uniformStride`; `ring` (0…2) picks the pair this call writes.
    /// False (nothing encoded, the caller keeps its last frame) while the target's aspect is not the canvas aspect: after
    /// `reconfigure` and before `PreviewHub.rebuild` makes the streamer again at the new size.
    ///
    /// Frame lifetime: the items are this tick's `prepare` selection (`drawItems` on a reuse tick, which equals the
    /// drawn list; `drawnItems` right after a canvas pass, swapped in from `drawItems`), never an older list. A ring
    /// frame selected this tick is `currentShown`, which the ring does not pop while shown nor for one change after
    /// (`previousShown`, `LayerPlayback.select`), and stills and live textures are held by their playback, so they outlive this command buffer exactly as they do for
    /// the canvas pass encoded on it.
    func drawLayer(_ index: Int, into pass: MTLRenderPassDescriptor, uniforms: MTLBuffer, ring: Int, commandBuffer: MTLCommandBuffer) -> Bool {
        // drawn as on its own canvas (multiple canvases): that canvas's aspect and geometry
        guard let target = pass.colorAttachments[0].texture, let t = self.target(forLayer: index) else { return false }
        let canvasWidth = targets[t].width, canvasHeight = targets[t].height
        guard abs(Double(target.width * canvasHeight) / Double(max(1, target.height * canvasWidth)) - 1) < 0.02,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else { return false }
        encoder.label = "layer preview"
        encodeAlone(index, uniforms: uniforms, slotBase: ring * 2, canvasWidth: canvasWidth, canvasHeight: canvasHeight, with: encoder)
        encoder.endEncoding()
        return true
    }

    /// Layer `index`'s items of this tick (see `drawLayer`) with Normal blending; their uniforms at `slotBase` and, for
    /// the outgoing picture of a dissolve, `slotBase + 1`.
    private func encodeAlone(_ index: Int, uniforms: MTLBuffer, slotBase: Int, canvasWidth: Int, canvasHeight: Int, with encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentSamplerState(context.nearestSampler, index: 1)
        for var item in reusedThisTick ? drawItems : drawnItems where item.slot / 2 == index {
            item.p.blendMode = .normal  // multiply or darken over black would show nothing
            item.slot = slotBase + item.slot % 2
            encode(item, uniforms: uniforms, time: drawnTime, canvasWidth: canvasWidth, canvasHeight: canvasHeight, with: encoder)
        }
    }

    // MARK: Thumbnail atlas (B29)

    /// Render thread, after the canvas pass of the tick: per render layer the size of its canvas (canvas 1's when that
    /// canvas does not render) and whether it shows something this tick (media with intensity > 0 on a canvas that renders).
    func thumbnailCanvases() -> [(width: Int, height: Int, visible: Bool)] {
        let items = reusedThisTick ? drawItems : drawnItems
        return layers.map { layer in
            if let item = items.first(where: { $0.slot / 2 == layer.index && $0.canvas >= 0 }) {
                return (targets[item.canvas].width, targets[item.canvas].height, true)
            }
            let t = targets[target(forLayer: layer.index) ?? 0]
            return (t.width, t.height, false)
        }
    }

    /// Draws each layer with a cell (`cells` indexed like `thumbnailCanvases`) alone into that cell of `pass`'s texture
    /// (canvas format), as `drawLayer` does, in one render pass that clears everything else to black. Same frame
    /// lifetime as `drawLayer`. Uniforms: three rotating thirds of a buffer the compositor keeps for this.
    func drawThumbnails(_ cells: [ThumbnailAtlas.Cell?], into pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) -> Bool {
        if thumbnailUniforms == nil { thumbnailUniforms = context.device.makeBuffer(length: Self.uniformStride * maxLayers * 2 * 3, options: .storageModeShared) }
        guard let uniforms = thumbnailUniforms, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "thumbnail atlas"
        let items = reusedThisTick ? drawItems : drawnItems
        for (i, layer) in layers.enumerated() where i < cells.count {
            guard let cell = cells[i], let canvas = items.first(where: { $0.slot / 2 == layer.index && $0.canvas >= 0 })?.canvas else { continue }
            encoder.setViewport(MTLViewport(originX: Double(cell.x), originY: Double(cell.y), width: Double(cell.width), height: Double(cell.height), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: cell.x, y: cell.y, width: cell.width, height: cell.height))
            encodeAlone(
                layer.index, uniforms: uniforms, slotBase: (thumbnailRing * maxLayers + i) * 2, canvasWidth: targets[canvas].width, canvasHeight: targets[canvas].height,
                with: encoder)
        }
        encoder.endEncoding()
        thumbnailRing = (thumbnailRing + 1) % 3
        return true
    }

    // MARK: Secondary displays

    /// Draws the latest completed canvas through `set` into a drawable of another display (DESIGN.md §4.5):
    /// its own command buffer on the caller's thread; `uniforms` belongs to that caller.
    public func present(_ set: OutputSet, to drawable: CAMetalDrawable, uniforms: MTLBuffer) {
        guard let commandBuffer = context.queue.makeCommandBuffer() else {
            outputEncoderFailures.wrappingAdd(1, ordering: .relaxed)
            return
        }
        guard encodePresent(set, into: drawable.texture, uniforms: uniforms, commandBuffer: commandBuffer) else {
            commandBuffer.commit()  // a Freeze may have encoded its copies: they must run, or the held textures stay undefined
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// `present` up to the drawable (tests draw into a texture of their own): holds and draws into `texture` on
    /// `commandBuffer`; false (counted) when no encoder could be made.
    func encodePresent(_ set: OutputSet, into texture: MTLTexture, uniforms: MTLBuffer, commandBuffer: MTLCommandBuffer) -> Bool {
        // not the compositor thread: the DMX side's copy, never `read()`; reserved first, so the lock covers only the copy (B71)
        var outputs: [OutputParameters] = []
        outputs.reserveCapacity(ParameterSnapshotSlot.maxOutputs)
        let (master, masterPattern) = parameters.withLatest {
            outputs.append(contentsOf: $0.outputs)
            return ($0.masterControl == .blackout ? 0 : $0.master, $0.testPattern)
        }
        // one tick's canvases for the whole draw (the compositor may complete another meanwhile) and their Master
        let (frame, index, canvasMaster) = completedCanvases()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        OutputPass.holdFrozen(set, canvas: { id in frame.first { $0.id == id }?.textures[index] }, outputs: outputs, master: canvasMaster, buffer: commandBuffer)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            outputEncoderFailures.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        encoder.label = "secondary output"
        OutputPass.draw(
            set, canvas: { id in frame.first { $0.id == id }?.textures[index] }, encoder: encoder, context: context, uniforms: uniforms,
            master: master, masterPattern: masterPattern, outputs: outputs)
        encoder.endEncoding()
        return true
    }

    /// Reads the offscreen output (BGRA 8-bit) back; tests only.
    public func readbackOutput() -> (width: Int, height: Int, bgra: [UInt8]) {
        guard let texture = offscreenOutput else { return (0, 0, []) }
        let bytesPerRow = texture.width * 4
        guard let buffer = context.device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
            let commandBuffer = context.queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder()
        else { return (0, 0, []) }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return (texture.width, texture.height, Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: bytesPerRow * texture.height)))
    }

    // MARK: Diagnostics

    /// Reads the most recently completed canvas back as 8-bit RGBA (tests and thumbnails; allocates, blocks on the GPU).
    public func readback(canvas id: Int? = nil) -> (width: Int, height: Int, rgba: [UInt8]) {
        guard let texture = id.map({ latestCanvas(id: $0) }) ?? Optional(latestCanvas) else { return (0, 0, []) }
        let bytesPerRow = texture.width * 8
        guard let buffer = context.device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared),
            let commandBuffer = context.queue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder()
        else { return (0, 0, []) }
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * texture.height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let halves = buffer.contents().assumingMemoryBound(to: Float16.self)
        var rgba = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        for i in rgba.indices { rgba[i] = UInt8(max(0, min(255, (Float(halves[i]) * 255).rounded()))) }
        return (texture.width, texture.height, rgba)
    }
}
