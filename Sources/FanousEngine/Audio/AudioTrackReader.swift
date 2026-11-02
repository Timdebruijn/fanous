// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

public enum AudioError: Error, CustomStringConvertible {
    case unsupportedFormat(FourCharCode)
    case converter(OSStatus)

    public var description: String {
        switch self {
        case .unsupportedFormat(let f): "unsupported audio format \(fourCCString(f)) (the library stores interleaved LPCM, ADR-0019)"
        case .converter(let s): "AudioConverter error \(s)"
        }
    }
}

/// Random-access audio demux (AVSampleCursor + AVSampleBufferGenerator, like `MovieSource` for video) and
/// conversion to 48 kHz interleaved stereo Float32 (AudioConverter). One instance per layer; used from that
/// layer's decode thread only (one caller at a time).
///
/// After `open`, `read` allocates nothing in Swift: source bytes are staged in a buffer preallocated at init and
/// converted straight into the caller's (the converter's channel map makes the stereo pair). The only per-chunk
/// allocations are AVFoundation's own sample-buffer objects (one request and one `CMSampleBuffer` per 100 ms of
/// source audio).
/// ponytail: LPCM only (what ingest stores); AAC/VBR would need packet descriptions and priming discard. Edit
/// lists are ignored (the track starts at 0). Sample-rate conversion latency (a few frames when the source is not
/// 48 kHz) is not compensated in the reported PTS.
public final class AudioTrackReader: @unchecked Sendable {
    public static let outputSampleRate = 48_000

    /// False for movies without an audio track: `seek` is a no-op and `read` returns no frames.
    public let hasAudio: Bool
    /// Length of the audio track in seconds (0 without audio).
    public let duration: Double
    /// Sample rate of the source track (before conversion to 48 kHz); 0 without audio.
    public let sampleRate: Double
    /// Channel count of the source track; 0 without audio.
    public let channelCount: Int

    private let generator: AVSampleBufferGenerator
    private let track: AVAssetTrack?
    private let converter: AudioConverterRef?
    private let bytesPerFrame: Int
    private let chunkFrames: Int  // source frames per sample-buffer request (100 ms)
    private let staging: UnsafeMutableRawPointer  // raw source bytes of the current chunk
    private let stagingCapacity: Int

    // Reader-thread state.
    private var cursor: AVSampleCursor?
    private var sourceEnded = true
    private var stagedOffset = 0  // frames of `staging` already handed to the converter
    private var stagedFrames = 0
    private var basePTS = 0.0  // media time of the first output frame after the last seek
    private var framesSinceSeek = 0

    /// Loads the first audio track's properties (async, like `MovieSource.open`). A movie without audio
    /// yields a reader with `hasAudio == false`; a track that is not interleaved LPCM throws.
    public static func open(url: URL) async throws -> AudioTrackReader {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return try AudioTrackReader(asset: asset, track: nil, description: nil, duration: 0)
        }
        let (descriptions, timeRange) = try await track.load(.formatDescriptions, .timeRange)
        return try AudioTrackReader(asset: asset, track: track, description: descriptions.first, duration: timeRange.duration.seconds)
    }

    private init(asset: AVAsset, track: AVAssetTrack?, description: CMFormatDescription?, duration: Double) throws {
        self.track = track
        generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
        guard track != nil, let description else {
            hasAudio = false
            self.duration = 0
            sampleRate = 0
            channelCount = 0
            converter = nil
            bytesPerFrame = 0
            chunkFrames = 0
            stagingCapacity = 0
            staging = .allocate(byteCount: 1, alignment: 16)
            return
        }
        guard var source = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
            source.mFormatID == kAudioFormatLinearPCM, source.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
            source.mBytesPerFrame > 0, source.mChannelsPerFrame > 0, source.mSampleRate > 0
        else {
            throw AudioError.unsupportedFormat(CMFormatDescriptionGetMediaSubType(description))
        }
        let channels = Int(source.mChannelsPerFrame)
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(Self.outputSampleRate), mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        var status = AudioConverterNew(&source, &output, &converter)
        guard status == noErr, let converter else { throw AudioError.converter(status) }
        if channels != 2 {
            // mono goes to both sides; more channels keep their first two
            var map: [Int32] = channels == 1 ? [0, 0] : [0, 1]
            status = AudioConverterSetProperty(converter, kAudioConverterChannelMap, UInt32(MemoryLayout<Int32>.size * 2), &map)
            guard status == noErr else {
                AudioConverterDispose(converter)
                throw AudioError.converter(status)
            }
        }
        self.converter = converter
        hasAudio = true
        self.duration = duration
        sampleRate = source.mSampleRate
        channelCount = channels
        bytesPerFrame = Int(source.mBytesPerFrame)
        chunkFrames = max(1, Int(source.mSampleRate / 10))
        stagingCapacity = chunkFrames * bytesPerFrame
        staging = .allocate(byteCount: stagingCapacity, alignment: 16)
        seek(toSeconds: 0)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        staging.deallocate()
    }

    /// Positions the reader so the next `read` starts at `seconds` (clamped to the track; at or past the end
    /// the next `read` returns no frames). Resets the converter.
    public func seek(toSeconds seconds: Double) {
        guard let track, let converter else { return }
        AudioConverterReset(converter)
        stagedOffset = 0
        stagedFrames = 0
        framesSinceSeek = 0
        let target = max(0, seconds)
        cursor = target < duration ? track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: target, preferredTimescale: Int32(sampleRate))) : nil
        sourceEnded = cursor == nil
        basePTS = cursor?.presentationTimeStamp.seconds ?? min(target, duration)
    }

    /// Converts up to `frameCount` frames to 48 kHz interleaved stereo Float32 into `output` (`2 * frameCount`
    /// floats). Returns fewer frames only at the end of the track. `firstFramePTS` is the media time of the
    /// first frame returned, in seconds. Never allocates in Swift (see the type comment).
    public func read(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> (framesRead: Int, firstFramePTS: Double) {
        let firstFramePTS = basePTS + Double(framesSinceSeek) / Double(Self.outputSampleRate)
        guard let converter, frameCount > 0 else { return (0, firstFramePTS) }
        var produced = 0
        while produced < frameCount {
            let wanted = frameCount - produced
            var frames = UInt32(wanted)
            var list = AudioBufferList(
                mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(wanted * 8), mData: output + 2 * produced))
            let status = AudioConverterFillComplexBuffer(converter, Self.inputProc, Unmanaged.passUnretained(self).toOpaque(), &frames, &list, nil)
            let got = Int(frames)
            produced += got
            if got == 0 || status != noErr && got < wanted { break }  // end of track (or a converter failure)
        }
        framesSinceSeek += produced
        return (produced, firstFramePTS)
    }

    // MARK: Converter input

    private static let inputProc: AudioConverterComplexInputDataProc = { _, packets, data, _, userData in
        Unmanaged<AudioTrackReader>.fromOpaque(userData!).takeUnretainedValue().provideInput(packets, data)
    }

    /// Hands the converter the staged source frames, refilling from the track when they run out.
    /// Zero packets means end of track.
    private func provideInput(_ packets: UnsafeMutablePointer<UInt32>, _ data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        if stagedOffset == stagedFrames { refill() }
        let count = min(Int(packets.pointee), stagedFrames - stagedOffset)
        packets.pointee = UInt32(count)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = UInt32(channelCount)
        data.pointee.mBuffers.mDataByteSize = UInt32(count * bytesPerFrame)
        data.pointee.mBuffers.mData = count > 0 ? staging + stagedOffset * bytesPerFrame : nil
        stagedOffset += count
        return noErr
    }

    /// Reads the next `chunkFrames` source frames at the cursor into `staging`.
    private func refill() {
        stagedOffset = 0
        stagedFrames = 0
        guard !sourceEnded, let cursor else { return }
        let request = AVSampleBufferRequest(start: cursor)
        request.direction = .forward
        request.preferredMinSampleCount = chunkFrames
        request.maxSampleCount = chunkFrames
        // LPCM: one sample is one frame; the cursor clamps at the last sample, which is how the end shows up.
        guard let sample = try? generator.makeSampleBuffer(for: request), let block = CMSampleBufferGetDataBuffer(sample) else {
            sourceEnded = true
            return
        }
        let frames = CMSampleBufferGetNumSamples(sample)
        let bytes = CMBlockBufferGetDataLength(block)
        guard frames > 0, bytes == frames * bytesPerFrame, bytes <= stagingCapacity,
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: staging) == noErr
        else {
            sourceEnded = true
            return
        }
        if cursor.stepInDecodeOrder(byCount: Int64(frames)) < Int64(frames) { sourceEnded = true }
        stagedFrames = frames
    }
}
