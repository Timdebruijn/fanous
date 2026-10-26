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
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let fps: Double
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
    private let mappedUniformBuffers: [MTLBuffer]
    /// 256 bytes per slice draw: enough for 64 slices across the outputs of one display.
    static let mappedUniformsLength = 256 * 64

    private let canvases: [MTLTexture]
    private let canvasPasses: [MTLRenderPassDescriptor]
    private let outputPass = MTLRenderPassDescriptor()
    private let uniformBuffers: [MTLBuffer]
    private let outputUniformBuffers: [MTLBuffer]
    private static let uniformStride = 256
    private let maxLayers: Int
    private var canvasIndex = 0
    private var lastTarget = 0.0
    private var lastSequence: UInt64 = 0
    /// Static-picture reuse (nothing visible changed since the canvas was last drawn): what the last drawn canvas showed.
    private var drawItems: [DrawItem] = []
    private var drawnItems: [DrawItem] = []
    private var drawnSequence: UInt64 = 0
    private var canvasValid = false
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
    nonisolated(unsafe) public var lastGPUError: String = ""

    public init(
        context: MetalContext, canvasWidth: Int, canvasHeight: Int, fps: Double, maxLayers: Int, metrics: MetricsRing,
        parameters: TripleBuffer<ParameterSnapshotSlot>, logger: Logger
    ) throws {
        self.context = context
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.fps = fps
        self.maxLayers = maxLayers
        self.metrics = metrics
        self.parameters = parameters
        self.logger = logger
        drawItems.reserveCapacity(maxLayers * 2)
        drawnItems.reserveCapacity(maxLayers * 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MetalContext.canvasFormat, width: canvasWidth, height: canvasHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        canvases = try (0..<3).map { i in
            guard let texture = context.device.makeTexture(descriptor: descriptor) else { throw RenderError.pipeline("canvas texture") }
            texture.label = "canvas \(i)"
            return texture
        }
        canvasPasses = canvases.map { texture in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return pass
        }
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

    /// The canvas completed by the previous tick (for previews and other outputs).
    public var latestCanvas: MTLTexture { canvases[(canvasIndex + 2) % 3] }

    /// One compositor tick. `target` is the target presentation time (host seconds).
    public func tick(target: Double, drawable: CAMetalDrawable?) {
        ticks.wrappingAdd(1, ordering: .relaxed)
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
            masterSpeed: snapshot.masterSpeed, time: Float(target.truncatingRemainder(dividingBy: 3600)))  // ponytail: one strobe phase jump per hour; per-layer Double phase if it shows
        drawItems.removeAll(keepingCapacity: true)

        // Everything that is not GPU work: hand-off, clocks, audio, decoder requests, frame selection.
        for layer in layers {
            let p = layer.index < snapshot.layers.count ? snapshot.layers[layer.index] : LayerParameters()
            handOff(layer: layer, p: p, target: target)
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
            if let outgoing = layer.outgoing {
                // normal: the old picture stays underneath while the new fades in; other modes (and a fade to
                // no media at all) crossfade the weights
                let underneath = p.blendMode == .normal && layer.current != nil
                prepare(outgoing, p, weight: underneath ? 1 : 1 - progress, retrigger: false, slot: layer.index * 2 + 1, in: &frame)
            }
            if let current = layer.current {
                prepare(current, p, weight: progress, retrigger: retrigger, slot: layer.index * 2, in: &frame)
            }
            if !layer.retireLater.isEmpty {
                layer.retired.withLockIfAvailable { list in
                    list.append(contentsOf: layer.retireLater)
                    layer.retireLater.removeAll(keepingCapacity: true)
                }
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
        if reuse {
            reuseStreak += 1
            reusedCanvases.wrappingAdd(1, ordering: .relaxed)
        } else {
            reuseStreak = 0
            encodeGenerators(commandBuffer, target: target)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: canvasPasses[canvasIndex]) else {
                encoderFailures.wrappingAdd(1, ordering: .relaxed)
                canvasValid = false
                return
            }
            encoder.label = "canvas"
            encoder.setRenderPipelineState(context.layerPipeline)
            encoder.setFragmentSamplerState(context.linearSampler, index: 0)
            encoder.setFragmentSamplerState(context.nearestSampler, index: 1)
            let uniforms = uniformBuffers[canvasIndex]
            for item in drawItems { encode(item, uniforms: uniforms, time: frame.time, with: encoder) }
            encoder.endEncoding()
            Swift.swap(&drawnItems, &drawItems)
            drawnSequence = snapshot.sequence
            drawnGPUErrors = gpuErrors.load(ordering: .relaxed)
            canvasValid = true
        }
        let canvas = reuse ? latestCanvas : canvases[canvasIndex]
        canvasPublished?(canvas, commandBuffer)
        previewTap?(canvas, commandBuffer, target)

        if let target = drawable?.texture ?? offscreenOutput {
            outputPass.colorAttachments[0].texture = target
            if let set = outputSet { OutputPass.holdFrozen(set, canvas: canvases[canvasIndex], outputs: snapshot.outputs, buffer: commandBuffer) }
            if let set = outputSet, let output = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
                output.label = "mapped output"
                OutputPass.draw(
                    set, canvas: canvas, encoder: output, context: context, uniforms: mappedUniformBuffers[canvasIndex],
                    master: snapshot.masterControl == .blackout ? 0 : snapshot.master, masterPattern: snapshot.testPattern, outputs: snapshot.outputs)
                output.endEncoding()
            } else if let output = commandBuffer.makeRenderCommandEncoder(descriptor: outputPass) {
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
        let metrics = self.metrics
        commandBuffer.addCompletedHandler { [self] buffer in
            completed.wrappingAdd(1, ordering: .relaxed)
            if buffer.status == .error {
                gpuErrors.wrappingAdd(1, ordering: .relaxed)
                lastGPUError = "\(buffer.error.map { "\($0)" } ?? "unknown")"
            }
            metrics.complete(slot: slot, gpuMicros: UInt32(max(0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1e6)), late: buffer.gpuEndTime > target)
        }
        commandBuffer.commit()
        if !reuse { canvasIndex = (canvasIndex + 1) % 3 }
    }

    struct TickContext {
        let dt: Double
        let target: Double
        let masterIntensity: Float
        let masterSpeed: Float
        let time: Float
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
        var intensity: Float
        var slot: Int

        static func == (l: DrawItem, r: DrawItem) -> Bool {
            l.playback === r.playback && l.frame === r.frame && l.frameIndex == r.frameIndex && l.intensity == r.intensity && l.slot == r.slot
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
    private func prepare(_ playback: LayerPlayback, _ p: LayerParameters, weight: Float, retrigger: Bool, slot: Int, in ctx: inout TickContext) {
        let last = playback.frameCount - 1
        let inFrame = Int((p.inPoint * Float(last)).rounded())
        let outFrame = Int((p.outPoint * Float(last)).rounded())
        if retrigger { playback.clock.retrigger(mode: p.playMode, inFrame: inFrame, outFrame: outFrame, frameCount: playback.frameCount) }
        if p.playMode == .timecode, playback.frameCount > 1, let timecode, let frames = timecode.frames(at: ctx.target) {
            // chase: (tc − project offset − layer offset) at the file's rate, looped within in/out
            let offsets = timecodeOffsets
            let seconds = (frames - offsets.project - (offsets.layers[slot / 2 + 1] ?? 0)) / timecode.read(at: ctx.target).rate.exactFrameRate
            let lo = Double(min(inFrame, outFrame)), hi = Double(max(inFrame, outFrame))
            var frame = seconds * playback.frameRate
            let span = hi - lo + 1
            if span > 0 { frame = lo + (frame - lo).truncatingRemainder(dividingBy: span) + (frame < lo ? span : 0) }
            playback.clock.position = min(hi, max(lo, frame))
        }
        let speed = Double(p.speed * ctx.masterSpeed) * 100
        let frameIndex = playback.clock.advance(
            dt: ctx.dt, fps: playback.frameRate, speed: speed, mode: p.playMode, inFrame: inFrame, outFrame: outFrame, frameCount: playback.frameCount)
        let direction = (p.playMode.isReverse ? -1 : 1) * (playback.clock.direction < 0 ? -1 : 1)
        if let channel = playback.audioChannel {
            // audio only at 100 % forward (ADR-0019); freeze/scrub/timecode and once-finished are silent
            let playing = frameIndex != nil && !playback.clock.finished && ctx.dt > 0
                && !(p.playMode == .freeze || p.playMode == .scrub || p.playMode == .timecode)
            let active = playing && direction > 0 && abs(speed - 100) < 0.5
            // a forward loop plays [in, out + 1) frames; the audio reads across its wrap (clamped to the audio length)
            var loop: (start: Double, end: Double)?
            if p.playMode == .loopForward, outFrame > inFrame, let reader = playback.decoder?.audio?.reader {
                loop = (Double(inFrame) / playback.frameRate, min(Double(outFrame + 1) / playback.frameRate, reader.duration))
            }
            channel.setState(wantedPTS: playback.clock.position / max(1, playback.frameRate), active: active, volume: p.audioVolume * weight, pan: p.audioPan, loop: loop)
        }
        guard let frameIndex else { return }  // once-then-black has finished
        let intensity = p.intensity * ctx.masterIntensity * weight
        // invisible for a while: the ring and the last frame stay, the clock keeps running, decoding resumes when visible
        guard playback.hold.allowsRequests(visible: intensity > 0, at: ctx.target) else { return }
        playback.decoder?.request(frame: frameIndex, direction: direction)
        guard intensity > 0 else { return }
        guard let frame = playback.frame(at: frameIndex, direction: direction), frame.texture0 != nil else {
            ctx.misses += 1
            return
        }
        if playback.live != nil || p.effect1 == .strobe || p.effect2 == .strobe { ctx.dynamic = true }
        ctx.drawn += 1
        drawItems.append(DrawItem(playback: playback, frame: frame, frameIndex: frameIndex, p: p, intensity: intensity, slot: slot))
    }

    private func encode(_ item: DrawItem, uniforms: MTLBuffer, time: Float, with encoder: MTLRenderCommandEncoder) {
        let p = item.p, playback = item.playback, frame = item.frame
        guard let texture0 = frame.texture0 else { return }
        let mediaWidth = playback.live != nil ? texture0.width : playback.width
        let mediaHeight = playback.live != nil ? texture0.height : playback.height
        let (transform, quad) = Self.geometry(for: p, mediaWidth: mediaWidth, mediaHeight: mediaHeight, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        var u = LayerUniforms()
        u.transform = transform
        u.quadRect = quad
        u.uvRect = SIMD4(p.cropLeft, p.cropTop, 1 - p.cropRight, 1 - p.cropBottom)
        u.colour = SIMD4(p.red, p.green, p.blue, item.intensity)
        u.adjust = SIMD4(p.brightness, p.contrast, p.saturation, p.hue)
        u.effect1 = SIMD4(Float(p.effect1.rawValue), p.effect1A, p.effect1B, 0)
        u.effect2 = SIMD4(Float(p.effect2.rawValue), p.effect2A, p.effect2B, 0)
        u.texel = SIMD4(1 / Float(max(1, mediaWidth)), 1 / Float(max(1, mediaHeight)), Float(mediaWidth) / Float(max(1, mediaHeight)), time)
        u.kind = frame.kind.rawValue
        u.blend = UInt32(p.blendMode.rawValue)
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

    // MARK: Secondary displays

    /// Draws the latest completed canvas through `set` into a drawable of another display (DESIGN.md §4.5):
    /// its own command buffer on the caller's thread; `uniforms` belongs to that caller.
    public func present(_ set: OutputSet, to drawable: CAMetalDrawable, uniforms: MTLBuffer) {
        let snapshot = parameters.read()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commandBuffer = context.queue.makeCommandBuffer() else {
            outputEncoderFailures.wrappingAdd(1, ordering: .relaxed)
            return
        }
        OutputPass.holdFrozen(set, canvas: latestCanvas, outputs: snapshot.outputs, buffer: commandBuffer)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            outputEncoderFailures.wrappingAdd(1, ordering: .relaxed)
            return
        }
        encoder.label = "secondary output"
        OutputPass.draw(
            set, canvas: latestCanvas, encoder: encoder, context: context, uniforms: uniforms,
            master: snapshot.masterControl == .blackout ? 0 : snapshot.master, masterPattern: snapshot.testPattern, outputs: snapshot.outputs)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
    public func readback() -> (width: Int, height: Int, rgba: [UInt8]) {
        let texture = latestCanvas
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
