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

    /// `fill` from a reader at an explicit layer clock.
    func fill(from reader: AudioTrackReader, wanted: Double, producer: Int = 0) {
        fill(wanted: wanted, producer: producer, read: { reader.read(into: $0, frameCount: $1) }, seek: { reader.seek(toSeconds: $0) })
    }
}

@Suite(.cleansTempFiles) struct AudioTests {
    // MARK: Helpers

    /// 320×180 ProRes 422 HQ at 30 fps, `seconds` long, with the `TestTone` track when `audio` is set.
    static func writeMovie(to url: URL, seconds: Int = 3, audio: Bool = true) async throws {
        try await writePatternMovie(to: url, size: (320, 180), fps: 30, frames: seconds * 30, audio: audio)
    }

    /// An audio-only movie, one second, 16-bit LPCM; channel `c` holds the constant `(c + 1) * 3000`. Mono, stereo or
    /// discrete by count unless `layoutTag` names the layout.
    static func writeConstantAudio(to url: URL, rate: Double, channels: Int, layoutTag: AudioChannelLayoutTag? = nil) async throws {
        try await offPool { try writeConstantAudioBlocking(to: url, rate: rate, channels: channels, layoutTag: layoutTag) }
    }

    private static func writeConstantAudioBlocking(to url: URL, rate: Double, channels: Int, layoutTag: AudioChannelLayoutTag?) throws {
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
            layoutTag ?? (channels == 1 ? kAudioChannelLayoutTag_Mono : channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
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
        try writer.finishBlocking()
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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "tone.mov")
        try await Self.writeMovie(to: url)

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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "end.mov")
        try await Self.writeMovie(to: url)

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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "silent.mov")
        try await Self.writeMovie(to: url, seconds: 1, audio: false)

        let reader = try await AudioTrackReader.open(url: url)
        #expect(!reader.hasAudio)
        reader.seek(toSeconds: 0.5)
        #expect(Self.read(reader, frames: 100).framesRead == 0)
    }

    @Test(arguments: [(48_000.0, 1), (48_000.0, 3), (44_100.0, 2)])
    func readerMapsChannelsAndConvertsTheRate(rate: Double, channels: Int) async throws {
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "constant.mov")
        try await Self.writeConstantAudio(to: url, rate: rate, channels: channels)

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

    /// B143: a 5.1 file is mixed to stereo by its layout, so the centre is heard in both sides whichever channel carries it
    /// (MPEG order L R C LFE Ls Rs, AAC order C L R Ls Rs LFE); a discrete six-channel file keeps its first two.
    @Test(arguments: [kAudioChannelLayoutTag_MPEG_5_1_A, kAudioChannelLayoutTag_AAC_5_1, kAudioChannelLayoutTag_DiscreteInOrder | 6])
    func readerMixesFiveOneByItsLayout(tag: AudioChannelLayoutTag) async throws {
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "five-one.mov")
        try await Self.writeConstantAudio(to: url, rate: 48_000, channels: 6, layoutTag: tag)
        let reader = try await AudioTrackReader.open(url: url)
        #expect(reader.channelCount == 6)
        reader.seek(toSeconds: 0.25)
        let result = Self.read(reader, frames: 4800)
        #expect(result.framesRead == 4800)
        for frame in [2400, 4700] {  // the second converter piece (4096 frames each with a matrix) lands at the right offset
            if tag == kAudioChannelLayoutTag_DiscreteInOrder | 6 {
                let left = result.samples[2 * frame] * 32768, right = result.samples[2 * frame + 1] * 32768
                #expect(abs(left - 3000) < 30 && abs(right - 6000) < 30, "\(frame): \(left) \(right)")
            } else {
                Self.expectFiveOneFold(result.samples, frame: frame, tag: tag)
            }
        }
    }

    /// Stereo frame `frame` of `samples` read from a 5.1 file of constants, (i + 1) × 3000 on channel i in `tag`'s order,
    /// folded whatever Apple's coefficients (L + 0.7071 (C + Ls) on macOS 27): something is added to both sides, and the
    /// sides differ by no more than the surrounds do (Rs − Ls is +3000 in both orders): the centre went to both, each
    /// surround to its own; nothing clips.
    static func expectFiveOneFold(_ samples: [Float], frame: Int, tag: AudioChannelLayoutTag, sourceLocation: SourceLocation = #_sourceLocation) {
        let left = samples[2 * frame] * 32768, right = samples[2 * frame + 1] * 32768
        let order = tag == kAudioChannelLayoutTag_MPEG_5_1_A ? ["L", "R", "C", "LFE", "Ls", "Rs"] : ["C", "L", "R", "Ls", "Rs", "LFE"]
        let value: (String) -> Float = { Float(order.firstIndex(of: $0)! + 1) * 3000 }  // the constant the file holds on that channel
        let addedLeft = left - value("L"), addedRight = right - value("R")
        let surrounds = value("Rs") - value("Ls")
        #expect(
            addedLeft > 0 && addedRight > addedLeft && addedRight - addedLeft <= surrounds + 30 && max(left, right) < 32767,
            "\(frame): \(left) \(right)", sourceLocation: sourceLocation)
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

    /// B264: a loop that is no whole number of frames in the 32 bits it is packed in is no loop. A loop end from a huge
    /// frame count over a tiny frame rate trapped `Int(_:)` here, on the compositor thread; one over ~25 h overflowed the packing.
    @Test func unrepresentableLoopIsNoLoop() {
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: 0, loop: (0, 2))
        #expect(channel.loopBits.load(ordering: .relaxed) == 96_000)
        for loop in [(0, 1e15), (0, .nan), (0, 100_000), (-1, 2)] as [(Double, Double)] {
            channel.setState(wantedPTS: 0, active: true, volume: 1, pan: 0, loop: loop)
            #expect(channel.loopBits.load(ordering: .relaxed) == 0, "loop \(loop)")
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

    /// A lag of 30 ms during playback (a stall) is nudged out 2 ms per pull until the audio is on the clock: 15
    /// corrections. The old code stopped at the window's edge after 5 and left 18 to 20 ms for the clip (B394).
    @Test func dropsFramesWhenAudioIsBehindAndConvergesToTheClock() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)  // ring: source frames 0 ..< 12000
        let frames = 480
        Self.pull(channel, frames: frames, wanted: 0)  // the segment's first pull, on the clock: head 480
        #expect(channel.statistics.corrections == 0)

        let lead = 1440  // from here the layer clock runs 30 ms ahead of the audio (a drift during playback)
        var consumedTotal = frames
        var previous = channel.bufferedFrames
        var firstPeak = 0.0
        for k in 1..<17 {
            let wanted = Double(lead + k * frames) / 48_000
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            let out = Self.pull(channel, frames: frames, wanted: wanted)
            let consumed = previous - channel.bufferedFrames
            previous = channel.bufferedFrames
            #expect(consumed >= frames && consumed - frames <= LayerAudioChannel.maxCorrectionFrames, "pull \(k) consumed \(consumed)")
            // gain is steady after the first pull: the output is the source ramp, starting after the dropped frames
            #expect(out.left[0] == Float(consumedTotal + consumed - frames))
            #expect(out.left[frames - 1] == Float(consumedTotal + consumed - 1))
            if k == 1 { firstPeak = channel.statistics.maxDriftMillis }
            if k == 10 { #expect(channel.statistics.corrections == 10, "still correcting inside the window") }
            consumedTotal += consumed
        }
        #expect(abs(firstPeak - 30) < 0.01, "first drifted pull saw \(firstPeak) ms")
        // 30 ms -> 0 at 2 ms per pull: 15 corrections (the last one of the 96 frames left), then no more.
        #expect(channel.statistics.corrections == 15)
        #expect(consumedTotal == 17 * frames + lead)
        channel.resetPeakDrift()
        for k in 17..<21 {
            let wanted = Double(lead + k * frames) / 48_000
            Self.pull(channel, frames: frames, wanted: wanted)
        }
        #expect(channel.statistics.maxDriftMillis < 0.1)
        #expect(channel.statistics.corrections == 15)
        #expect(channel.statistics.underruns == 0)
    }

    /// B394: a retrigger within 100 ms of a start (the compositor says so with `jumped`) is a new segment: the
    /// reader seeks, and the first pull lands on the clock instead of repeating frames until the window's edge. The
    /// old producer reseeked only beyond 100 ms.
    @Test func aRetriggerWithinTheResyncThresholdReseeks() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        for k in 0..<10 { Self.pull(channel, frames: 480, wanted: Double(k * 480) / 48_000) }  // played to 100 ms
        channel.setState(wantedPTS: 0.050, active: true, volume: 1, pan: -1, jumped: true)  // retriggered: the clock is at 50 ms
        var out = Self.pull(channel, frames: 480, wanted: 0.050)  // before the producer has seen it: the old ring (50 ms ahead) is not repeated
        #expect(out.left.allSatisfy { $0 == 0 } && channel.bufferedFrames == LayerAudioChannel.capacity - 4800)
        channel.fill(source, wanted: 0.050)  // asks for a drain
        Self.pull(channel, frames: 480, wanted: 0.050)  // drains, silent
        #expect(channel.bufferedFrames == 0)
        channel.fill(source, wanted: 0.050)  // the new segment, from 50 ms
        #expect(source.next == 2400 + LayerAudioChannel.capacity)
        out = Self.pull(channel, frames: 480, wanted: 0.060)
        #expect(out.left[0] == Float(2880))  // the clock's frame, landed
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)
        // Without the signal a 50 ms jump back is not reseeked: the ring is topped up, not drained.
        channel.setState(wantedPTS: 0.020, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0.020)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
    }

    /// B394, from the review: between two pulls the head runs up to one callback ahead of the clock, and the
    /// consumer leaves a lead inside the window alone. A fill right after a pull, with 1024-frame callbacks, and a
    /// clock that steps back 12 ms (a sync slave's packet jitter) must not drain the ring: an inferred jump-back
    /// reseek at 20 ms did.
    @Test func aFillBetweenPullsDoesNotReseek() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        for k in 0..<20 {
            let wanted = Double(k * 1024) / 48_000
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            Self.pull(channel, frames: 1024, wanted: wanted)  // the head is now 21 ms past the clock
            channel.fill(source, wanted: wanted + 0.001)
            #expect(channel.bufferedFrames == LayerAudioChannel.capacity, "pull \(k)")  // topped up, not drained
        }
        let stepped = Double(20 * 1024) / 48_000 - 0.012
        channel.setState(wantedPTS: stepped, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: stepped)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        Self.pull(channel, frames: 1024, wanted: stepped)
        #expect(channel.statistics.underruns == 0)
    }

    /// B394: a correction keeps its direction. When the clock's jitter makes a nudge overshoot, the drift changes
    /// sign and the correction ends there; it does not nudge back and forth, counting each step.
    @Test func aCorrectionEndsWhenTheDriftChangesSign() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        Self.pull(channel, frames: 480, wanted: 0)
        let lead = 1440  // the clock runs 30 ms ahead: a correction starts
        var previous = channel.bufferedFrames
        for k in 1..<14 {
            Self.pull(channel, frames: 480, wanted: Double(lead + k * 480) / 48_000)
            previous = channel.bufferedFrames
        }
        #expect(channel.statistics.corrections == 13)  // 192 frames of lag left
        // The clock reads 300 frames early on this pull (jitter): the audio is 108 frames ahead now.
        Self.pull(channel, frames: 480, wanted: Double(lead + 14 * 480 - 300) / 48_000)
        #expect(previous - channel.bufferedFrames == 480)  // neither dropped nor repeated
        #expect(channel.statistics.corrections == 13)
        previous = channel.bufferedFrames
        Self.pull(channel, frames: 480, wanted: Double(lead + 15 * 480) / 48_000)  // the clock is back on its line
        #expect(previous - channel.bufferedFrames == 480)  // 192 frames inside the window: left alone
        #expect(channel.statistics.corrections == 13)
    }

    /// B394: a landing that empties the ring (it held the lag plus less than one callback) underruns for the rest of
    /// that callback, and the frames that were not there are a lag inside the window from then on: nudged out.
    @Test func theLagLeftByAnUnderrunIsNudgedOut() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        Self.pull(channel, frames: 11_700, wanted: 0)  // head 11 700
        channel.setState(wantedPTS: 11_700.0 / 48_000, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 11_700.0 / 48_000)  // tail 23 700: the next segment's first contiguous run is 300 frames
        channel.setState(wantedPTS: 2.0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 2.0)  // the producer asks for a drain
        Self.pull(channel, frames: 480, wanted: 2.0)  // drained, silent
        #expect(channel.bufferedFrames == 0)
        // The refill: the first read is the 300 frames to the end of the storage. The callback comes right after
        // it, 100 frames behind the clock: it lands, plays the 200 left and misses 280.
        var reads = 0
        var between: (buffered: Int, underruns: UInt64)?
        channel.fill(wanted: 2.0, read: { buffer, n in
            reads += 1
            if reads == 2 { Self.pull(channel, frames: 480, wanted: 2.0 + 100.0 / 48_000); between = (channel.bufferedFrames, channel.statistics.underruns) }
            return source.read(buffer, n)
        }, seek: { source.seek($0) })
        #expect(between?.buffered == 0 && between?.underruns == 2)  // the drained pull counted the first
        var previous = channel.bufferedFrames
        for k in 1..<5 {
            let wanted = 2.0 + Double(100 + k * 480) / 48_000
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            Self.pull(channel, frames: 480, wanted: wanted)
            let consumed = previous - channel.bufferedFrames
            previous = channel.bufferedFrames
            #expect(consumed - 480 <= LayerAudioChannel.maxCorrectionFrames, "pull \(k) consumed \(consumed)")
        }
        #expect(channel.statistics.corrections == 3)  // 280 frames: 96, 96, 88
        channel.resetPeakDrift()
        Self.pull(channel, frames: 480, wanted: 2.0 + Double(100 + 5 * 480) / 48_000)
        #expect(channel.statistics.maxDriftMillis < 0.1)
        #expect(channel.statistics.corrections == 3)
    }

    /// B394: a segment that starts ahead of the clock (a clock that jumped back less than the window before the
    /// first pull) waits for the clock: silent until it reaches the first frame, then exact, no correction.
    @Test func aSegmentThatStartsAheadWaitsForTheClock() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0.015, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0.015)  // ring from 15 ms (frame 720); the clock is then found at 0
        var out = Self.pull(channel, frames: 480, wanted: 0)  // a whole callback ahead: silent, nothing consumed
        #expect(out.left.allSatisfy { $0 == 0 })
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        out = Self.pull(channel, frames: 480, wanted: 480.0 / 48_000)  // 240 frames ahead: 240 of silence, then the ring
        #expect(out.left[239] == 0 && abs(out.left[240] - 720.0 / 240) < 0.01)  // frame 720, the gain ramping from 0 over the 240 audible frames
        #expect(abs(out.left[479] - 959) < 0.01)
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity - 240)
        out = Self.pull(channel, frames: 480, wanted: 960.0 / 48_000)
        #expect(out.left[0] == Float(960))  // on the clock
        #expect(channel.statistics.corrections == 0 && channel.statistics.underruns == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)
    }

    /// B394: a resume where the pull before the pause ran past the pause point (it consumes a whole callback at the
    /// clock of its start): the audio is ahead on the resume and waits for the clock instead of being repeated.
    @Test func aResumeAheadOfTheClockWaitsForIt() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        Self.pull(channel, frames: 480, wanted: 0)  // frames 0 ..< 480 heard; the head is at 10 ms
        channel.setState(wantedPTS: 0.005, active: false, volume: 1, pan: -1)  // paused at 5 ms
        Self.pull(channel, frames: 480, wanted: 0.005)
        channel.setState(wantedPTS: 0.005, active: true, volume: 1, pan: -1)  // resumed at 5 ms: the ring is 240 frames ahead
        let out = Self.pull(channel, frames: 480, wanted: 0.005)
        #expect(out.left[239] == 0 && abs(out.left[240] - 480.0 / 240) < 0.01)  // frame 480 at the first step of the fade-in: no click
        #expect(abs(out.left[479] - Float(480 + 239)) < 0.01)  // the ramp continues from frame 480 (the gain has ramped to 1 by the last frame)
        #expect(abs(channel.nextFramePTS - 0.015) < 1e-9)
        #expect(channel.statistics.corrections == 0 && channel.statistics.underruns == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)
    }

    /// B393: the output device starts about 30 ms after the producer seeked at the clock, so the segment's first
    /// pull finds the audio behind. It lands on the clock at once, also inside the ±20 ms window, where the old code
    /// left the lag for the whole clip; and a seek later in the clip does the same.
    @Test(arguments: [15, 35]) func theFirstPullOfASegmentLandsOnTheClock(lagMillis: Int) {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)  // ring: source frames 0 ..< 12000
        let frames = 480
        let lag = lagMillis * 48
        var wanted = Double(lag) / 48_000  // the clock ran on while the device started
        var out = Self.pull(channel, frames: frames, wanted: wanted)  // the gain ramps up over this pull: the ring position says where it landed
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity - lag - frames)
        #expect(abs(channel.nextFramePTS - Double(lag + frames) / 48_000) < 1e-9)
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)
        for k in 1..<6 {
            wanted = Double(lag + k * frames) / 48_000
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            out = Self.pull(channel, frames: frames, wanted: wanted)
            #expect(out.left[0] == Float(lag + k * frames))
        }
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)

        // A seek to 1.0 s (the producer restarts the segment) with the clock 10 ms past it by the next pull.
        channel.setState(wantedPTS: 1.0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 1.0)  // drains next pull
        Self.pull(channel, frames: frames, wanted: 1.0)
        channel.fill(source, wanted: 1.0)  // the new segment, at 1.0 s
        out = Self.pull(channel, frames: frames, wanted: 1.010)
        #expect(out.left[0] == Float(48_000 + 480))
        #expect(channel.statistics.corrections == 0)
    }

    /// B393: a pull that falls between the two reads of a new segment's first fill finds less in the ring than the
    /// lag. It must not spend the alignment on that: the next pull lands.
    @Test func aSegmentWhoseFirstReadIsShortStillLandsOnTheClock() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        Self.pull(channel, frames: 11_900, wanted: 0)  // head 11 900
        channel.setState(wantedPTS: 11_900.0 / 48_000, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 11_900.0 / 48_000)  // tail 23 900: the next segment's first contiguous run is 100 frames
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)
        channel.setState(wantedPTS: 2.0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 2.0)  // the producer asks for a drain
        Self.pull(channel, frames: 480, wanted: 2.0)  // drained, silent
        #expect(channel.bufferedFrames == 0)
        // The refill: the first read is the 100 frames to the end of the storage. The callback comes right after it,
        // 10 ms behind the clock, before the second read; then the clock has moved one callback on.
        var reads = 0
        var between: (buffered: Int, corrections: UInt64)?
        channel.fill(wanted: 2.0, read: { buffer, n in
            reads += 1
            if reads == 2 { Self.pull(channel, frames: 480, wanted: 2.010); between = (channel.bufferedFrames, channel.statistics.corrections) }
            return source.read(buffer, n)
        }, seek: { source.seek($0) })
        #expect(between?.buffered == 0 && between?.corrections == 0)  // it took the 100 frames and played nothing
        let out = Self.pull(channel, frames: 480, wanted: 2.020)
        #expect(out.left[0] == Float(96_000 + 960))  // landed: the clock's frame, not 860 frames behind it
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)  // the short ring's 100 frames were taken, not played as a 10 ms lag
    }

    /// B393: a resume after a pause. The clock ran on while the output device started again; the first pull lands.
    @Test func theFirstPullAfterAPauseLandsOnTheClock() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0)
        Self.pull(channel, frames: 480, wanted: 0)
        channel.setState(wantedPTS: 0.010, active: false, volume: 1, pan: -1)  // paused at 10 ms
        Self.pull(channel, frames: 480, wanted: 0.010)  // silent
        channel.setState(wantedPTS: 0.060, active: true, volume: 1, pan: -1)  // resumed; the device took 50 ms to come back
        Self.pull(channel, frames: 480, wanted: 0.060)
        #expect(abs(channel.nextFramePTS - 0.070) < 1e-9)  // landed on the clock
        let out = Self.pull(channel, frames: 480, wanted: 0.070)
        #expect(out.left[0] == Float(3360))
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)
    }

    /// B396: a layer's channel goes to the next file (the loader alternates two per layer). The ring still holds the
    /// previous file, stopped 10 ms into its clip, and the new file starts at 10 ms, where the old ring's head is:
    /// within 100 ms, so the old producer rule saw no reason to reseek, appended the new file's frames to the old
    /// PTS line, and the old frames played first. After `handOver()` nothing of the old ring is heard and the new
    /// file starts over at the clock.
    @Test func aChannelHandedToAnotherFileStartsOver() {
        let old = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: -1)
        channel.fill(old, wanted: 0)  // the old file: frames 0 ..< 12000 at 0 ... 0.25 s
        Self.pull(channel, frames: 480, wanted: 0)  // 10 ms of it heard
        channel.setState(wantedPTS: 0.010, active: false, volume: 0, pan: 0)  // the old file is stopped (releaseAudio)
        Self.pull(channel, frames: 480, wanted: 0.010)

        let token = channel.handOver()
        // The new file's frames are its frame number plus a million, so the two files cannot be confused.
        var next = 0
        let read: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double) = { buffer, n in
            for i in 0..<n { buffer[2 * i] = Float(1_000_000 + next + i); buffer[2 * i + 1] = 0 }
            defer { next += n }
            return (n, Double(next) / 48_000)
        }
        let seek: (Double) -> Void = { next = Int(($0 * 48_000).rounded()) }
        channel.setState(wantedPTS: 0.010, active: true, volume: 1, pan: -1)  // the new file starts at 10 ms: exactly where the old ring's head is
        var out = Self.pull(channel, frames: 480, wanted: 0.010)  // before the new producer's first fill: the old ring would land and play
        #expect(out.left.allSatisfy { $0 == 0 })  // stale segment: silent, nothing consumed
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity - 480 && channel.statistics.underruns == 1)
        channel.fill(wanted: 0.010, producer: token, read: read, seek: seek)  // sees the hand-over: asks for a drain, reads nothing yet
        #expect(next == 0)
        out = Self.pull(channel, frames: 480, wanted: 0.010)  // drains; the old segment is never heard
        #expect(out.left.allSatisfy { $0 == 0 })
        #expect(channel.bufferedFrames == 0)
        channel.fill(wanted: 0.010, producer: token, read: read, seek: seek)  // the new segment, from the clock
        #expect(abs(channel.nextFramePTS - 0.010) < 1e-9)
        out = Self.pull(channel, frames: 480, wanted: 0.020)  // lands: the new file's frame at 20 ms
        #expect(out.left[0] == Float(1_000_000 + 960))
        #expect(out.left.allSatisfy { $0 == 0 || $0 >= 1_000_000 })
        #expect(channel.statistics.corrections == 0)
        #expect(channel.statistics.maxDriftMillis < 0.1)
    }

    /// B397: the channel is handed to file C while file A's decode thread is still inside a fill (a sample read can
    /// stall for tens of milliseconds, B391). Without the guard C's first fill ran at the same time: both wrote the
    /// same ring, A's samples landed under C's PTS line and were heard as C. Now C's fill does nothing until A's
    /// has returned, what A wrote is never heard, and C starts the ring over at its clock. A fill from A after the
    /// hand-over reads nothing at all.
    @Test func aProducerStillInsideAFillFinishesAloneBeforeTheNextFileFillsTheChannel() {
        let channel = LayerAudioChannel()
        let a = channel.handOver()
        var c = 0
        var readsA = 0
        var readsC = 0
        let readC: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double) = { buffer, n in
            for i in 0..<n { buffer[2 * i] = 0.75; buffer[2 * i + 1] = 0.75 }
            readsC += 1
            return (n, 0.010 + Double(readsC - 1) * Double(n) / 48_000)
        }
        let readA: (UnsafeMutablePointer<Float>, Int) -> (framesRead: Int, firstFramePTS: Double) = { buffer, n in
            readsA += 1
            if readsA == 1 {
                // A's read stalls, and meanwhile the compositor swaps: A is released, C gets the channel and its clock (10 ms, where A's
                // frames are too: within the resync window), and C's decode thread asks to fill
                channel.setState(wantedPTS: 0, active: false, volume: 0, pan: 0)
                c = channel.handOver()
                channel.setState(wantedPTS: 0.010, active: true, volume: 1, pan: 0)
                channel.fill(wanted: 0.010, producer: c, read: readC, seek: { _ in })
                #expect(readsC == 0)  // A is still inside: nothing
            }
            for i in 0..<n { buffer[2 * i] = 0.25; buffer[2 * i + 1] = 0.25 }
            return (n, Double(readsA - 1) * Double(n) / 48_000)
        }
        channel.setState(wantedPTS: 0, active: true, volume: 1, pan: 0)
        channel.fill(wanted: 0, producer: a, read: readA, seek: { _ in })  // A's fill, with the swap inside its first read
        #expect(readsA > 0 && channel.bufferedFrames == LayerAudioChannel.capacity)  // A filled the whole ring after the swap
        channel.fill(wanted: 0.010, producer: a, read: readA, seek: { _ in })  // A's thread once more before it sees its flag cleared
        let late = readsA
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity)

        var out = Self.pull(channel, frames: 480, wanted: 0.010)  // A's frames under C's clock: never heard
        #expect(out.left.allSatisfy { $0 == 0 } && channel.statistics.underruns == 1)
        channel.fill(wanted: 0.010, producer: c, read: readC, seek: { _ in })  // C: a new producer, asks for a drain first
        #expect(readsC == 0)
        out = Self.pull(channel, frames: 480, wanted: 0.010)
        #expect(out.left.allSatisfy { $0 == 0 } && channel.bufferedFrames == 0)
        channel.fill(wanted: 0.010, producer: c, read: readC, seek: { _ in })  // C's segment, from its clock
        #expect(readsC > 0 && abs(channel.nextFramePTS - 0.010) < 1e-9)
        out = Self.pull(channel, frames: 480, wanted: 0.010)
        #expect(out.left.allSatisfy { $0 == 0.75 } && out.right.allSatisfy { $0 == 0.75 })
        channel.fill(wanted: 0.020, producer: a, read: readA, seek: { _ in })  // A once more, with room in the ring: ignored
        #expect(readsA == late)
        out = Self.pull(channel, frames: 480, wanted: 0.020)
        #expect(out.left.allSatisfy { $0 == 0.75 } && channel.statistics.corrections == 0)
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
        // 90 ms off at the segment's first audible pull: it lands on the clock (B393), no nudge.
        let landed = Self.pull(channel, frames: 480, wanted: 0.090)
        #expect(landed.left.contains { $0 != 0 })
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity - 4320 - 480)
        #expect(channel.statistics.corrections == 0)
        // 90 ms off during playback (inside the 100 ms window) is nudged, 2 ms per pull.
        let nudged = Self.pull(channel, frames: 480, wanted: 0.190)
        #expect(nudged.left.contains { $0 != 0 })
        #expect(channel.bufferedFrames == LayerAudioChannel.capacity - 4320 - 480 - 480 - LayerAudioChannel.maxCorrectionFrames)
        #expect(channel.statistics.corrections == 1)
    }

    /// The consumer alone (no producer fill, so no reseek): a clock that steps back 30 ms during playback leaves the
    /// audio ahead; it is repeated 2 ms per pull until it is on the clock, 15 corrections (B394: the old code stopped
    /// at the window's edge after 5).
    @Test func repeatsFramesWhenAudioIsAheadUntilItIsOnTheClock() {
        let source = RampSource()
        let channel = LayerAudioChannel()
        channel.setState(wantedPTS: 0.050, active: true, volume: 1, pan: -1)
        channel.fill(source, wanted: 0.050)  // ring starts at 50 ms
        Self.pull(channel, frames: 480, wanted: 0.050)  // landed; the head is at 60 ms

        let frames = 480
        var previous = channel.bufferedFrames
        for k in 0..<17 {
            let wanted = 0.030 + Double(k * frames) / 48_000  // the clock stepped back: 30 ms behind the audio
            channel.setState(wantedPTS: wanted, active: true, volume: 1, pan: -1)
            Self.pull(channel, frames: frames, wanted: wanted)
            let consumed = previous - channel.bufferedFrames
            previous = channel.bufferedFrames
            #expect(consumed <= frames && frames - consumed <= LayerAudioChannel.maxCorrectionFrames, "pull \(k) consumed \(consumed)")
            if k == 7 { #expect(channel.statistics.corrections == 8, "still correcting inside the window") }
        }
        #expect(channel.statistics.corrections == 15)
        channel.resetPeakDrift()
        Self.pull(channel, frames: frames, wanted: 0.030 + 17 * Double(frames) / 48_000)
        #expect(channel.statistics.maxDriftMillis < 0.1)
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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "jump.mov")
        try await Self.writeMovie(to: url)
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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "tail.mov")
        try await Self.writeMovie(to: url)
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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "loop.mov")
        try await Self.writeMovie(to: url, seconds: 1)
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
        let directory = try tempDir("fanous-audio-tests")
        let url = directory.appending(path: "edge.mov")
        try await Self.writeConstantAudio(to: url, rate: 44_100, channels: 2)
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

    @Test func mixerSumsChannels() {
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

        let stats = mixer.statistics
        #expect(stats.callbacks == 2)
        #expect(stats.underruns == 0)
        mixer.resetPeakDrift()
        #expect(mixer.statistics.maxDriftMillis == 0)
    }
}
