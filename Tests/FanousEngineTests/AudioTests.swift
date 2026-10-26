// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import Foundation
import Testing

@testable import FanousEngine

/// Frame source for driving a `LayerAudioChannel` without a reader: left = n, right = -n for source frame n.
final class RampSource {
    var next = 0
    func read(_ destination: UnsafeMutablePointer<Float>, _ count: Int) -> (framesRead: Int, firstFramePTS: Double) {
        let first = next
        for i in 0..<count {
            destination[2 * i] = Float(first + i)
            destination[2 * i + 1] = -Float(first + i)
        }
        next += count
        return (count, Double(first) / 48_000)
    }
    func seek(_ seconds: Double) { next = Int((seconds * 48_000).rounded()) }
}

extension LayerAudioChannel {
    /// `fill` with the layer clock given explicitly (the public one extrapolates it with the host clock).
    func fill(_ source: RampSource, wanted: Double) {
        fill(wanted: wanted, read: { source.read($0, $1) }, seek: { source.seek($0) })
    }
}

@Suite struct AudioTests {
    // MARK: Helpers

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 320×180 ProRes 422 HQ at 30 fps, `seconds` long, with the `TestTone` track when `audio` is set.
    static func writeMovie(to url: URL, seconds: Int = 3, audio: Bool = true) throws {
        let fps: Int32 = 30
        let writer = try MovieWriter(url: url, width: 320, height: 180, fps: fps, codec: .proRes422HQ, audio: audio)
        for frame in 0..<(seconds * Int(fps)) {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, writer.pixelBufferPool!, &buffer)
            guard let buffer else { throw MovieWriter.WriterError.failed("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            PatternFrames.fill(
                bgra: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), width: 320, height: 180,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), frame: frame)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try writer.append(buffer)
        }
        try writer.finish()
    }

    /// An audio-only movie, one second, 16-bit LPCM; channel `c` holds the constant `(c + 1) * 3000`.
    static func writeConstantAudio(to url: URL, rate: Double, channels: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag =
            channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw MovieWriter.WriterError.failed("format \(status)") }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
        writer.add(input)
        guard writer.startWriting() else { throw MovieWriter.WriterError.failed("startWriting") }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(rate)
        let samples = (0..<frames * channels).map { Int16(($0 % channels + 1) * 3000) }
        let block = try samples.withUnsafeBytes { try MovieWriter.blockBuffer(copying: $0) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames, presentationTimeStamp: .zero,
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample, input.append(sample) else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "append") }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw MovieWriter.WriterError.failed(writer.error?.localizedDescription ?? "finish") }
    }

    /// Sign changes (negative to non-negative or back) of one channel of an interleaved stereo buffer.
    static func crossings(_ interleaved: [Float], channel: Int, frames: Range<Int>) -> Int {
        var count = 0
        for i in frames.dropFirst() where (interleaved[2 * (i - 1) + channel] < 0) != (interleaved[2 * i + channel] < 0) { count += 1 }
        return count
    }

    static func peak(_ interleaved: [Float], channel: Int, frames: Range<Int>) -> Float {
        frames.reduce(0) { max($0, abs(interleaved[2 * $1 + channel])) }
    }

    static func read(_ reader: AudioTrackReader, frames: Int) -> (samples: [Float], framesRead: Int, pts: Double) {
        var samples = [Float](repeating: 0, count: 2 * frames)
        let (n, pts) = samples.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, frameCount: frames) }
        return (samples, n, pts)
    }

    /// Pulls `frames` frames; returns left and right.
    @discardableResult
    static func pull(_ channel: LayerAudioChannel, frames: Int, wanted: Double) -> (left: [Float], right: [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                channel.pull(into: l.baseAddress!, right: r.baseAddress!, frames: frames, wantedPTS: wanted)
            }
        }
        return (left, right)
    }

    // MARK: AudioTrackReader

    @Test func readerSeeksToOneSecondAndFindsTheTestTone() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tone.mov")
        try Self.writeMovie(to: url)

        let reader = try await AudioTrackReader.open(url: url)
        #expect(reader.hasAudio)
        #expect(reader.sampleRate == 48_000)
        #expect(reader.channelCount == 2)
        #expect(abs(reader.duration - 3) < 0.02)

        reader.seek(toSeconds: 1.0)
        let first = Self.read(reader, frames: 4800)
        #expect(first.framesRead == 4800)
        #expect(abs(first.pts - 1.0) < 0.001)
        // 1 kHz on the left: 2 crossings per period, 100 periods in 0.1 s. 440 Hz on the right: 88.
        let left = Self.crossings(first.samples, channel: 0, frames: 0..<4800)
        let right = Self.crossings(first.samples, channel: 1, frames: 0..<4800)
        #expect(abs(left - 200) <= 10, "left crossings \(left)")
        #expect(abs(right - 88) <= 5, "right crossings \(right)")
        // The click starts exactly at the whole second: full level for 10 ms, half level after. This pins the seek to the sample.
        #expect(Self.peak(first.samples, channel: 0, frames: 0..<480) > 0.9)
        #expect(Self.peak(first.samples, channel: 1, frames: 0..<480) > 0.9)
        #expect(Self.peak(first.samples, channel: 0, frames: 480..<4800) < 0.55)

        // Reads continue where the last one stopped.
        let second = Self.read(reader, frames: 4800)
        #expect(abs(second.pts - 1.1) < 1e-6)
        #expect(second.framesRead == 4800)
        #expect(Self.peak(second.samples, channel: 0, frames: 0..<4800) < 0.55)
    }

    @Test func readerReturnsFewerFramesAtTheEnd() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "end.mov")
        try Self.writeMovie(to: url)

        let reader = try await AudioTrackReader.open(url: url)
        reader.seek(toSeconds: 2.9)
        let tail = Self.read(reader, frames: 10_000)
        #expect(tail.framesRead == 4800)  // 0.1 s left of a 3 s track
        #expect(Self.read(reader, frames: 100).framesRead == 0)
        reader.seek(toSeconds: 99)
        #expect(Self.read(reader, frames: 100).framesRead == 0)
        reader.seek(toSeconds: 0)  // and it can start over
        #expect(Self.read(reader, frames: 100).framesRead == 100)
    }

    @Test func movieWithoutAudioHasNoAudio() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "silent.mov")
        try Self.writeMovie(to: url, seconds: 1, audio: false)

        let reader = try await AudioTrackReader.open(url: url)
        #expect(!reader.hasAudio)
        reader.seek(toSeconds: 0.5)
        #expect(Self.read(reader, frames: 100).framesRead == 0)
    }

    @Test(arguments: [(48_000.0, 1), (48_000.0, 3), (44_100.0, 2)])
    func readerMapsChannelsAndConvertsTheRate(rate: Double, channels: Int) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "constant.mov")
        try Self.writeConstantAudio(to: url, rate: rate, channels: channels)

        let reader = try await AudioTrackReader.open(url: url)
        #expect(reader.sampleRate == rate)
        #expect(reader.channelCount == channels)
        reader.seek(toSeconds: 0.25)
        let result = Self.read(reader, frames: 4800)
        #expect(result.framesRead == 4800)
        #expect(abs(result.pts - 0.25) < 0.001)
        // Mono is duplicated, more than two channels keep the first two; a constant survives rate conversion.
        let expectedLeft = Float(3000) / 32768
        let expectedRight = channels == 1 ? expectedLeft : Float(6000) / 32768
        for i in stride(from: 300, to: 4700, by: 97) {  // past the converter's start-up transient
            #expect(abs(result.samples[2 * i] - expectedLeft) < 0.002)
            #expect(abs(result.samples[2 * i + 1] - expectedRight) < 0.002)
        }
    }

    // MARK: LayerAudioChannel

    @Test func panLawIsBalanceWithUnityAtCentre() {
        let center = LayerAudioChannel.panGains(0)
        #expect(center.left == 1 && center.right == 1)
        let left = LayerAudioChannel.panGains(-1)
        #expect(left.left == 1 && left.right == 0)
        let right = LayerAudioChannel.panGains(1)
        #expect(right.left == 0 && right.right == 1)
        let half = LayerAudioChannel.panGains(0.5)
        #expect(half.left == 0.5 && half.right == 1)
        var previous = LayerAudioChannel.panGains(-1)
        for pan in stride(from: Float(-0.875), through: 1, by: 0.125) {
            let g = LayerAudioChannel.panGains(pan)
            #expect(g.left <= previous.left && g.right >= previous.right)
            previous = g
        }
    }

    @Test func layerClockIsExtrapolatedWithTheHostClock() {
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 5.0, active: true, volume: 1, pan: 0, atHostNanos: 1_000_000_000)
        #expect(abs(channel.wantedPTS(atHostNanos: 1_000_000_000) - 5.0) < 1e-9)
        #expect(abs(channel.wantedPTS(atHostNanos: 1_016_700_000) - 5.0167) < 1e-9)
        // A later tick replaces the whole line: no pairing of a new position with an old time.
        channel.setState(wantedPTS: 7.0, active: true, volume: 1, pan: 0, atHostNanos: 2_000_000_000)
        #expect(abs(channel.wantedPTS(atHostNanos: 2_010_000_000) - 7.01) < 1e-9)
    }

    @Test func inactiveChannelIsSilentAndConsumesNothing() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)

        channel.setState(wantedPTS: 0, active: false, volume: 1, pan: -1)
        let out = Self.pull(channel, frames: 480, wanted: 0)
        #expect(out.left.allSatisfy { $0 == 0 } && out.right.allSatisfy { $0 == 0 })
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        #expect(channel.statistics.callbacks == 0)

        // Back on: the same audio comes out, scaled by volume (pan -1 is all left), added to what is in the buffer.
        channel.setState(wantedPTS: 0, active: true, volume: 0.5, pan: -1)
        Self.pull(channel, frames: 480, wanted: 0)  // the first pull ramps the gain from 0
        let steady = Self.pull(channel, frames: 480, wanted: 480.0 / 48_000)
        #expect(steady.left[0] == 480 * 0.5 && steady.left[479] == 959 * 0.5)
        #expect(steady.right.allSatisfy { abs($0) < 1e-6 })
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity - 960)
    }

    @Test func dropsFramesWhenAudioIsBehindAndConvergesWithinTolerance() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)  // ring: source frames 0 ..< 12000

        let frames = 480
        let lead = 1440  // the layer clock runs 30 ms ahead of the audio
        var consumedTotal = 0
        var previous = channel.bufferedFrames
        var firstPeak = 0.0
        for k in 0..<10 {
            let wanted = Double(lead + k * frames) / 48_000
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            let out = Self.pull(channel, frames: frames, wanted: wanted)
            let consumed = previous - channel.bufferedFrames
            previous = channel.bufferedFrames
            #expect(consumed >= frames && consumed - frames <= LayerAudioChannel.maxCorrectionFrames, "pull \(k) consumed \(consumed)")
            if k > 0 {  // gain is steady after the first pull: the output is the source ramp, starting after the dropped frames
                #expect(out.left[0] == Float(consumedTotal + consumed - frames))
                #expect(out.left[frames - 1] == Float(consumedTotal + consumed - 1))
            }
            if k == 0 { firstPeak = channel.statistics.maxDriftMillis }
            consumedTotal += consumed
        }
        #expect(abs(firstPeak - 30) < 0.01, "first pull saw \(firstPeak) ms")
        // 30 ms -> 20 ms at 2 ms per pull: five corrections, then the drift stays inside the window.
        #expect(channel.statistics.corrections == 5)
        #expect(consumedTotal == 10 * frames + 5 * LayerAudioChannel.maxCorrectionFrames)
        channel.resetPeakDrift()
        for k in 10..<14 {
            let wanted = Double(lead + k * frames) / 48_000
            Self.pull(channel, frames: frames, wanted: wanted)
        }
        #expect(channel.statistics.maxDriftMillis <= 20.0)
        #expect(channel.statistics.corrections == 5)
        #expect(channel.statistics.underruns == 0)
    }

    @Test func staysSilentWhenTheAudioIsFarFromTheClock() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        // The clock jumped a second; the producer has not noticed yet. Do not play (or nudge) stale audio.
        let out = Self.pull(channel, frames: 480, wanted: 1.0)
        #expect(out.left.allSatisfy { $0 == 0 })
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        let stats = channel.statistics
        #expect(stats.underruns == 1 && stats.corrections == 0 && stats.maxDriftMillis == 0)
        // 90 ms off is nudged instead (inside the 100 ms window).
        let nudged = Self.pull(channel, frames: 480, wanted: 0.090)
        #expect(nudged.left.contains { $0 != 0 })
        #expect(channel.statistics.corrections == 1)
    }

    @Test func repeatsFramesWhenAudioIsAhead() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0.050, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0.050)  // ring starts at 50 ms

        let frames = 480
        var previous = channel.bufferedFrames
        for k in 0..<8 {
            let wanted = 0.020 + Double(k * frames) / 48_000  // the clock is 30 ms behind the audio
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            Self.pull(channel, frames: frames, wanted: wanted)
            let consumed = previous - channel.bufferedFrames
            previous = channel.bufferedFrames
            #expect(consumed <= frames && frames - consumed <= LayerAudioChannel.maxCorrectionFrames, "pull \(k) consumed \(consumed)")
        }
        #expect(channel.statistics.corrections == 5)
    }

    @Test func ringKeepsTheRampContinuousAcrossTheWrap() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)  // tail 12000
        Self.pull(channel, frames: 3000, wanted: 0)
        channel.setState(wantedPTS: 3000.0 / 48_000, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 3000.0 / 48_000)  // tail 15000: written at the start of the storage
        Self.pull(channel, frames: 10_000, wanted: 3000.0 / 48_000)  // head 13000
        channel.setState(wantedPTS: 13_000.0 / 48_000, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 13_000.0 / 48_000)  // 10 000 free frames, 9000 of them before the end of the storage: two reads
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        #expect(source.next == 25_000)
        let out = Self.pull(channel, frames: LayerAudioChannel.capacity, wanted: 13_000.0 / 48_000)  // reads across the wrap
        #expect((0..<out.left.count).allSatisfy { out.left[$0] == Float(13_000 + $0) && out.right[$0] == 0 })
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.underruns == 0)
    }

    // MARK: Producer reseek

    @Test func wantedPTSJumpReseeksTheReaderAndRefills() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "jump.mov")
        try Self.writeMovie(to: url)
        let reader = try await AudioTrackReader.open(url: url)

        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(from: reader, wanted: 0)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        #expect(abs(channel.nextFramePTS - 0) < 0.001)

        // The layer jumps 2 s. The producer notices, but only the consumer may move the head: nothing changes yet.
        channel.setState(wantedPTS: 2.0, active: true, volume: 1, pan: -1)
        channel.fill(from: reader, wanted: 2.0)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        #expect(abs(channel.nextFramePTS - 0) < 0.001)

        // The next render callback drains (and, with an empty ring, is silent).
        let gap = Self.pull(channel, frames: 480, wanted: 2.0)
        #expect(gap.left.allSatisfy { $0 == 0 })
        #expect(channel.bufferedFrames == 0)
        #expect(channel.statistics.underruns == 1)

        // Then the producer seeks the reader to the new position and refills.
        channel.fill(from: reader, wanted: 2.0)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        #expect(abs(channel.nextFramePTS - 2.0) < 0.001)

        // The audio that comes out is the click at 2.0 s followed by the quieter tone, in sync: no correction.
        let out = Self.pull(channel, frames: 960, wanted: 2.0)
        #expect(out.left[0..<480].map { abs($0) }.max()! > 0.9)
        #expect(out.left[480..<960].map { abs($0) }.max()! < 0.55)
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 1)  // the 2 s jump itself was never measured: the ring was empty

        // A jump backwards (a loop wrap) does the same.
        channel.setState(wantedPTS: 0.5, active: true, volume: 1, pan: -1)
        channel.fill(from: reader, wanted: 0.5)
        Self.pull(channel, frames: 480, wanted: 0.5)
        channel.fill(from: reader, wanted: 0.5)
        #expect(abs(channel.nextFramePTS - 0.5) < 0.001)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
    }

    @Test func endOfMediaIsNotAnUnderrunAndDoesNotReseekForever() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tail.mov")
        try Self.writeMovie(to: url)
        let reader = try await AudioTrackReader.open(url: url)

        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 2.9, active: true, volume: 1, pan: -1)
        channel.fill(from: reader, wanted: 2.9)
        #expect(channel.bufferedFrames == 4800)  // 0.1 s left
        Self.pull(channel, frames: 4800, wanted: 2.9)
        // The clock holds at the end of the media; the ring is empty and stays that way.
        for _ in 0..<5 {
            channel.setState(wantedPTS: 3.5, active: true, volume: 1, pan: -1)
            channel.fill(from: reader, wanted: 3.5)
            Self.pull(channel, frames: 480, wanted: 3.5)
        }
        #expect(channel.bufferedFrames == 0)
        #expect(channel.statistics.underruns == 0)
    }

    /// B3: a forward loop is read across the wrap, so 120 wraps of a 1 s file never run the ring dry.
    @Test func loopWrapIsGaplessOverManyWraps() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "loop.mov")
        try Self.writeMovie(to: url, seconds: 1)
        let reader = try await AudioTrackReader.open(url: url)

        for looped in [true, false] {
            let channel = LayerAudioChannel()
            let frames = 480  // 10 ms callbacks
            var silent = 0
            channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1, loop: looped ? (0, 1) : nil)
            channel.fill(from: reader, wanted: 0)
            for step in 0..<(120 * 100) {
                let wanted = Double(step * frames % 48_000) / 48_000
                channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1, loop: looped ? (0, 1) : nil)
                // the callback runs before the producer thread gets to react to this tick's clock
                let out = Self.pull(channel, frames: frames, wanted: wanted)
                if step > 0 && out.left.allSatisfy({ $0 == 0 }) { silent += 1 }  // a silent callback (the tone is never 0 for 10 ms)
                channel.fill(from: reader, wanted: wanted)
            }
            print("loop wraps looped=\(looped): underruns \(channel.statistics.underruns), silent callbacks \(silent)")
            if looped {
                #expect(channel.statistics.underruns == 0)
                #expect(silent == 0)
            }
        }
    }

    /// Loop-end edge cases of the gapless wrap: a 44.1 kHz source looped over its whole (converted) length, a loop
    /// a little longer than the audio (padded), and a restart whose clock is already past the loop end.
    @Test func loopEdgeCases() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "edge.mov")
        try Self.writeConstantAudio(to: url, rate: 44_100, channels: 2)
        let reader = try await AudioTrackReader.open(url: url)

        func run(loopEnd: Double, startWanted: Double = 0, laps: Int = 30) -> (underruns: UInt64, silent: Int, channel: LayerAudioChannel) {
            let channel = LayerAudioChannel()
            let frames = 480
            let period = Int((loopEnd * 48_000).rounded())
            var silent = 0
            var step = Int((startWanted * 48_000).rounded()) / frames
            channel.setState(wantedPTS: startWanted, active: true, volume: 1, pan: -1, loop: (0, loopEnd))
            channel.fill(from: reader, wanted: startWanted)
            for _ in 0..<(laps * period / frames) {
                let wanted = Double(step * frames % period) / 48_000
                channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1, loop: (0, loopEnd))
                let out = Self.pull(channel, frames: frames, wanted: wanted)
                if step > 1 && out.left.allSatisfy({ $0 == 0 }) { silent += 1 }
                channel.fill(from: reader, wanted: wanted)
                step += 1
            }
            return (channel.statistics.underruns, silent, channel)
        }

        let whole = run(loopEnd: reader.duration)  // end = the clamped duration, the converter may return a few frames short
        #expect(whole.underruns == 0 && whole.silent == 0, "whole: \(whole.underruns) underruns, \(whole.silent) silent")
        let longer = run(loopEnd: reader.duration + 0.03)  // audio shorter than the loop: padded, never stuck at the end
        #expect(longer.underruns == 0, "longer: \(longer.underruns) underruns")
        #expect(longer.silent <= 30 * 4, "longer: \(longer.silent) silent")  // only the 30 ms of padding per lap is silent
        let past = run(loopEnd: reader.duration, startWanted: reader.duration + 0.016, laps: 3)  // restart just past the end
        #expect(past.underruns == 0 && past.silent == 0, "past: \(past.underruns) underruns, \(past.silent) silent")
    }

    // MARK: AudioMixer

    @Test func mixerSumsChannelsAndAppliesMasterVolume() {
        let mixer = AudioMixer(channels: 3)
        #expect(mixer.channels.count == 3)
        let a = RampSource()
        let b = RampSource()
        for (channel, source, pan) in [(mixer.channels[0], a, Float(-1)), (mixer.channels[1], b, Float(-1))] {
            channel.setState(wantedPTS: 0, active: true, volume: 1, pan: pan)
            channel.fill(source, wanted: 0)
        }
        // mixer.channels[2] stays inactive.
        var left = [Float](repeating: 99, count: 480)  // the render overwrites what is there
        var right = [Float](repeating: 99, count: 480)
        var rendered = 0
        func render() {
            for channel in mixer.channels { channel.setState(wantedPTS: Double(rendered) / 48_000, active: channel !== mixer.channels[2], volume: 1, pan: -1) }
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in mixer.render(frames: 480, left: l.baseAddress!, right: r.baseAddress!) }
            }
            rendered += 480
        }
        render()  // first callback ramps the gains
        render()
        #expect(left[0] == 2 * 480 && left[479] == 2 * 959)
        #expect(right.allSatisfy { abs($0) < 1e-6 })

        mixer.masterVolume = 0.5
        render()  // ramps 1 -> 0.5 across this callback
        render()
        #expect(left[0] == 2 * 1440 * 0.5 && left[479] == 2 * 1919 * 0.5)

        let stats = mixer.statistics
        #expect(stats.callbacks == 4)
        #expect(stats.underruns == 0)
        mixer.resetPeakDrift()
        #expect(mixer.statistics.maxDriftMillis == 0)
    }
}
