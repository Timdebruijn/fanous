// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

// CITP/MSEX (Media Server Extensions) 1.0, 1.1 and 1.2. Every message is
//   CITP header (20) | VersionMajor u8 | VersionMinor u8 | ContentType cookie (4) | payload
// The structs carry the 1.2 field set; fields a given version does not have are left out when encoding
// and come back as defaults when decoding. 1.1 shares the 1.0 layout wherever the spec has no 1.1 variant.

public struct MSEXVersion: Comparable, Hashable, Sendable {
    public var major: UInt8
    public var minor: UInt8

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    public static let v1_0 = MSEXVersion(major: 1, minor: 0)
    public static let v1_1 = MSEXVersion(major: 1, minor: 1)
    public static let v1_2 = MSEXVersion(major: 1, minor: 2)

    public static func < (a: MSEXVersion, b: MSEXVersion) -> Bool { (a.major, a.minor) < (b.major, b.minor) }

    /// Most items a counted list can carry on the wire (u8 count before 1.2, u16 from 1.2).
    var maxCount: Int { self >= .v1_2 ? 0xFFFF : 0xFF }
}

/// MSEXLibraryId: `level` 0 is the built-in root, 1...3 is the depth, `level1...3` pick the sub-library.
/// MSEX 1.0 has no such id, only a library number; it is carried as `level1` of a depth-1 id.
public struct MSEXLibraryID: Equatable, Hashable, Sendable {
    public var level: UInt8
    public var level1: UInt8
    public var level2: UInt8
    public var level3: UInt8

    public init(level: UInt8 = 0, level1: UInt8 = 0, level2: UInt8 = 0, level3: UInt8 = 0) {
        self.level = level
        self.level1 = level1
        self.level2 = level2
        self.level3 = level3
    }

    /// Library `number` directly below the root (what MSEX 1.0 calls LibraryNumber).
    public static func topLevel(_ number: UInt8) -> MSEXLibraryID { MSEXLibraryID(level: 1, level1: number) }
}

/// MSEX/CInf: the client lists the MSEX versions it speaks (always sent with version 1.2).
public struct ClientInformation: Equatable, Sendable {
    public var version: MSEXVersion
    public var supportedVersions: [MSEXVersion]

    public init(version: MSEXVersion = .v1_2, supportedVersions: [MSEXVersion]) {
        self.version = version
        self.supportedVersions = supportedVersions
    }
}

/// MSEX/SInf. 1.0 and 1.1 share the short layout (name, product version, layers); 1.2 adds the fields marked below.
public struct ServerInformation: Equatable, Sendable {
    public var version: MSEXVersion
    /// 1.2: 36-character media server UUID, lets a console cache thumbnails per server.
    public var uuid: String
    public var productName: String
    public var productVersionMajor: UInt8
    public var productVersionMinor: UInt8
    /// 1.2
    public var productVersionBugfix: UInt8
    /// 1.2
    public var supportedVersions: [MSEXVersion]
    /// 1.2 bit field: 1 Media, 2 Effects, 4 Cues, 8 Crossfades, 16 Masks, 32 Blend presets, 64 Effect presets,
    /// 128 Image presets, 256 3D meshes.
    public var supportedLibraryTypes: UInt16
    /// 1.2 cookies, best first; "RGB8" is mandatory, "JPEG" and "PNG " optional.
    public var thumbnailFormats: [String]
    /// 1.2 cookies, best first; "RGB8" is mandatory, "JPEG", "PNG ", "fJPG", "fPNG" optional.
    public var streamFormats: [String]
    /// One DMX source connection string per layer, e.g. "ArtNet/0/0/1".
    public var layerDMXSources: [String]

    public init(
        version: MSEXVersion = .v1_2, uuid: String = "", productName: String, productVersionMajor: UInt8 = 0,
        productVersionMinor: UInt8 = 0, productVersionBugfix: UInt8 = 0, supportedVersions: [MSEXVersion] = [],
        supportedLibraryTypes: UInt16 = 0, thumbnailFormats: [String] = [], streamFormats: [String] = [],
        layerDMXSources: [String] = []
    ) {
        self.version = version
        self.uuid = uuid
        self.productName = productName
        self.productVersionMajor = productVersionMajor
        self.productVersionMinor = productVersionMinor
        self.productVersionBugfix = productVersionBugfix
        self.supportedVersions = supportedVersions
        self.supportedLibraryTypes = supportedLibraryTypes
        self.thumbnailFormats = thumbnailFormats
        self.streamFormats = streamFormats
        self.layerDMXSources = layerDMXSources
    }

    init(version: MSEXVersion, from r: inout CITPReader) throws {
        let wide = version >= .v1_2
        let uuid = try wide ? r.fixedString(36) : ""
        let name = try r.ucs2()
        var info = ServerInformation(version: version, uuid: uuid, productName: name)
        info.productVersionMajor = try r.u8()
        info.productVersionMinor = try r.u8()
        if wide {
            info.productVersionBugfix = try r.u8()
            info.supportedVersions = try r.versions()
            info.supportedLibraryTypes = try r.u16()
            info.thumbnailFormats = try r.cookies()
            info.streamFormats = try r.cookies()
        }
        let layers = Int(try r.u8())
        info.layerDMXSources = try r.array(layers) { try $0.ucs1() }
        self = info
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        if v >= .v1_2 { out.putFixedString(uuid, 36) }
        out.putUCS2(productName)
        out += [productVersionMajor, productVersionMinor]
        if v >= .v1_2 {
            out.append(productVersionBugfix)
            out.putVersions(supportedVersions)
            out.put(supportedLibraryTypes)
            out.putCookies(thumbnailFormats)
            out.putCookies(streamFormats)
        }
        let layers = layerDMXSources.prefix(0xFF)
        out.append(UInt8(layers.count))
        for source in layers { out.putUCS1(source) }
    }
}

/// MSEX/Nack (1.2+): "I do not support the message you sent". `InResponseTo` in the CITP header carries the
/// request's index, so answer with `encoded(requestIndex:)` set to the request's `CITPHeader.requestIndex`.
public struct Nack: Equatable, Sendable {
    public var version: MSEXVersion
    /// Content type of the rejected message, e.g. "GELT".
    public var receivedContentType: String

    public init(version: MSEXVersion = .v1_2, receivedContentType: String) {
        self.version = version
        self.receivedContentType = receivedContentType
    }
}

/// One entry of MSEX/LSta. 1.2 identifies the playing media by library type + id, 1.0/1.1 only by library number.
public struct LayerStatus: Equatable, Sendable {
    public static let playing: UInt32 = 0x01
    public static let playbackReverse: UInt32 = 0x02
    public static let playbackLooping: UInt32 = 0x04
    public static let playbackBouncing: UInt32 = 0x08
    public static let playbackRandom: UInt32 = 0x10
    public static let paused: UInt32 = 0x20

    public var layerNumber: UInt8
    public var physicalOutput: UInt8
    /// 1.2 only (1 = Media, 2 = Effects, ...); decodes as 1 from 1.0/1.1 messages.
    public var mediaLibraryType: UInt8
    /// 1.0/1.1 carry only `level1` (as MediaLibraryNumber); use `MSEXLibraryID.topLevel(_:)` there.
    public var mediaLibraryID: MSEXLibraryID
    public var mediaNumber: UInt8
    public var mediaName: String
    public var mediaPosition: UInt32
    public var mediaLength: UInt32
    public var mediaFPS: UInt8
    /// `playing` is the only flag in 1.0/1.1; 1.2 adds the rest.
    public var statusFlags: UInt32

    public init(
        layerNumber: UInt8, physicalOutput: UInt8 = 0, mediaLibraryType: UInt8 = 1, mediaLibraryID: MSEXLibraryID = .topLevel(0),
        mediaNumber: UInt8 = 0, mediaName: String = "", mediaPosition: UInt32 = 0, mediaLength: UInt32 = 0, mediaFPS: UInt8 = 0,
        statusFlags: UInt32 = 0
    ) {
        self.layerNumber = layerNumber
        self.physicalOutput = physicalOutput
        self.mediaLibraryType = mediaLibraryType
        self.mediaLibraryID = mediaLibraryID
        self.mediaNumber = mediaNumber
        self.mediaName = mediaName
        self.mediaPosition = mediaPosition
        self.mediaLength = mediaLength
        self.mediaFPS = mediaFPS
        self.statusFlags = statusFlags
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        self.init(layerNumber: try r.u8(), physicalOutput: try r.u8())
        if v >= .v1_2 {
            mediaLibraryType = try r.u8()
            mediaLibraryID = try r.libraryID(v)
        } else {
            mediaLibraryID = .topLevel(try r.u8())
        }
        mediaNumber = try r.u8()
        mediaName = try r.ucs2()
        mediaPosition = try r.u32()
        mediaLength = try r.u32()
        mediaFPS = try r.u8()
        statusFlags = try r.u32()
    }

    static func write(_ layers: [LayerStatus], to out: inout [UInt8], as v: MSEXVersion) {
        let layers = layers.prefix(0xFF)
        out.append(UInt8(layers.count))
        for l in layers {
            out += [l.layerNumber, l.physicalOutput]
            if v >= .v1_2 {
                out.append(l.mediaLibraryType)
                out.putLibraryID(l.mediaLibraryID, v)
            } else {
                out.append(l.mediaLibraryID.level1)
            }
            out.append(l.mediaNumber)
            out.putUCS2(l.mediaName)
            out.put(l.mediaPosition)
            out.put(l.mediaLength)
            out.append(l.mediaFPS)
            out.put(l.statusFlags)
        }
    }
}

/// MSEX/GELI: ask for the libraries below `parentID` (1.1+; 1.0 has only the root).
public struct GetElementLibraryInformation: Equatable, Sendable {
    public var version: MSEXVersion
    /// 1 Media, 2 Effects, 3 Cues, 4 Crossfades, 5 Masks, 6 Blend presets, 7 Effect presets, 8 Image presets, 9 3D meshes.
    public var libraryType: UInt8
    public var parentID: MSEXLibraryID
    /// Empty asks for all libraries. One byte each in every version, as the spec has it.
    public var libraryNumbers: [UInt8]

    public init(version: MSEXVersion = .v1_2, libraryType: UInt8 = 1, parentID: MSEXLibraryID = MSEXLibraryID(), libraryNumbers: [UInt8] = []) {
        self.version = version
        self.libraryType = libraryType
        self.parentID = parentID
        self.libraryNumbers = libraryNumbers
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        self.init(version: v, libraryType: try r.u8())
        if v >= .v1_1 { parentID = try r.libraryID(v) }
        libraryNumbers = try r.array(try r.count(v)) { try $0.u8() }
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.append(libraryType)
        if v >= .v1_1 { out.putLibraryID(parentID, v) }
        let numbers = libraryNumbers.prefix(v.maxCount)
        out.putCount(numbers.count, v)
        out += numbers
    }
}

/// One library in MSEX/ELIn.
public struct ElementLibrary: Equatable, Sendable {
    public var id: MSEXLibraryID
    /// 1.2: changes whenever the library or anything below it changes.
    public var serialNumber: UInt32
    public var dmxRangeMin: UInt8
    public var dmxRangeMax: UInt8
    public var name: String
    /// Number of sub-libraries (1.1+).
    public var libraryCount: UInt16
    public var elementCount: UInt16

    public init(
        id: MSEXLibraryID, serialNumber: UInt32 = 0, dmxRangeMin: UInt8 = 0, dmxRangeMax: UInt8 = 0, name: String,
        libraryCount: UInt16 = 0, elementCount: UInt16 = 0
    ) {
        self.id = id
        self.serialNumber = serialNumber
        self.dmxRangeMin = dmxRangeMin
        self.dmxRangeMax = dmxRangeMax
        self.name = name
        self.libraryCount = libraryCount
        self.elementCount = elementCount
    }
}

/// MSEX/ELIn: the libraries answering a GELI. Counts are u8 before 1.2, u16 from 1.2.
public struct ElementLibraryInformation: Equatable, Sendable {
    public var version: MSEXVersion
    public var libraryType: UInt8
    public var libraries: [ElementLibrary]

    public init(version: MSEXVersion = .v1_2, libraryType: UInt8 = 1, libraries: [ElementLibrary]) {
        self.version = version
        self.libraryType = libraryType
        self.libraries = libraries
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        let type = try r.u8()
        let libraries = try r.array(try r.count(v)) { r -> ElementLibrary in
            let id = try r.libraryID(v)
            let serial = try v >= .v1_2 ? r.u32() : 0
            let min = try r.u8()
            let max = try r.u8()
            let name = try r.ucs2()
            let subLibraries = try v >= .v1_1 ? r.count(v) : 0
            let elements = try r.count(v)
            return ElementLibrary(
                id: id, serialNumber: serial, dmxRangeMin: min, dmxRangeMax: max, name: name,
                libraryCount: UInt16(subLibraries), elementCount: UInt16(elements))
        }
        self.init(version: v, libraryType: type, libraries: libraries)
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.append(libraryType)
        let libraries = libraries.prefix(v.maxCount)
        out.putCount(libraries.count, v)
        for l in libraries {
            out.putLibraryID(l.id, v)
            if v >= .v1_2 { out.put(l.serialNumber) }
            out += [l.dmxRangeMin, l.dmxRangeMax]
            out.putUCS2(l.name)
            if v >= .v1_1 { out.putCount(Int(l.libraryCount), v) }
            out.putCount(Int(l.elementCount), v)
        }
    }
}

/// MSEX/GEIn: ask for the element information of `libraryID` (all elements when `elementNumbers` is empty).
public struct GetElementInformation: Equatable, Sendable {
    public var version: MSEXVersion
    public var libraryType: UInt8
    public var libraryID: MSEXLibraryID
    public var elementNumbers: [UInt8]

    public init(version: MSEXVersion = .v1_2, libraryType: UInt8 = 1, libraryID: MSEXLibraryID, elementNumbers: [UInt8] = []) {
        self.version = version
        self.libraryType = libraryType
        self.libraryID = libraryID
        self.elementNumbers = elementNumbers
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        let type = try r.u8()
        let id = try r.libraryID(v)
        self.init(version: v, libraryType: type, libraryID: id, elementNumbers: try r.array(try r.count(v)) { try $0.u8() })
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.append(libraryType)
        out.putLibraryID(libraryID, v)
        let numbers = elementNumbers.prefix(v.maxCount)
        out.putCount(numbers.count, v)
        out += numbers
    }
}

/// One element in MSEX/MEIn.
public struct MediaElement: Equatable, Sendable {
    public var number: UInt8
    /// 1.2
    public var serialNumber: UInt32
    public var dmxRangeMin: UInt8
    public var dmxRangeMax: UInt8
    public var name: String
    public var versionTimestamp: UInt64
    public var width: UInt16
    public var height: UInt16
    public var length: UInt32
    public var fps: UInt8

    public init(
        number: UInt8, serialNumber: UInt32 = 0, dmxRangeMin: UInt8 = 0, dmxRangeMax: UInt8 = 0, name: String,
        versionTimestamp: UInt64 = 0, width: UInt16 = 0, height: UInt16 = 0, length: UInt32 = 0, fps: UInt8 = 0
    ) {
        self.number = number
        self.serialNumber = serialNumber
        self.dmxRangeMin = dmxRangeMin
        self.dmxRangeMax = dmxRangeMax
        self.name = name
        self.versionTimestamp = versionTimestamp
        self.width = width
        self.height = height
        self.length = length
        self.fps = fps
    }
}

/// MSEX/MEIn: media elements (library type 1) of one library. Effects (EEIn) and generic elements (GLEI)
/// are not modelled and arrive as `.unknown`.
public struct MediaElementInformation: Equatable, Sendable {
    public var version: MSEXVersion
    public var libraryID: MSEXLibraryID
    public var elements: [MediaElement]

    public init(version: MSEXVersion = .v1_2, libraryID: MSEXLibraryID, elements: [MediaElement]) {
        self.version = version
        self.libraryID = libraryID
        self.elements = elements
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        let id = try r.libraryID(v)
        let elements = try r.array(try r.count(v)) { r -> MediaElement in
            let number = try r.u8()
            let serial = try v >= .v1_2 ? r.u32() : 0
            let min = try r.u8()
            let max = try r.u8()
            let name = try r.ucs2()
            return MediaElement(
                number: number, serialNumber: serial, dmxRangeMin: min, dmxRangeMax: max, name: name,
                versionTimestamp: try r.u64(), width: try r.u16(), height: try r.u16(), length: try r.u32(), fps: try r.u8())
        }
        self.init(version: v, libraryID: id, elements: elements)
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.putLibraryID(libraryID, v)
        let elements = elements.prefix(v.maxCount)
        out.putCount(elements.count, v)
        for e in elements {
            out.append(e.number)
            if v >= .v1_2 { out.put(e.serialNumber) }
            out += [e.dmxRangeMin, e.dmxRangeMax]
            out.putUCS2(e.name)
            out.put(e.versionTimestamp)
            out.put(e.width)
            out.put(e.height)
            out.put(e.length)
            out.append(e.fps)
        }
    }
}

/// MSEX/GETh: request thumbnails (all elements of the library when `elementNumbers` is empty).
public struct GetElementThumbnail: Equatable, Sendable {
    /// `flags` bit 0: keep the aspect ratio, `width` x `height` are maximums.
    public static let preserveAspectRatio: UInt8 = 0x01

    public var version: MSEXVersion
    /// "RGB8" (BGR in 1.0, RGB from 1.1), "JPEG" or (1.2) "PNG ".
    public var format: String
    public var width: UInt16
    public var height: UInt16
    public var flags: UInt8
    public var libraryType: UInt8
    public var libraryID: MSEXLibraryID
    public var elementNumbers: [UInt8]

    public init(
        version: MSEXVersion = .v1_2, format: String = "JPEG", width: UInt16, height: UInt16, flags: UInt8 = 0,
        libraryType: UInt8 = 1, libraryID: MSEXLibraryID, elementNumbers: [UInt8] = []
    ) {
        self.version = version
        self.format = format
        self.width = width
        self.height = height
        self.flags = flags
        self.libraryType = libraryType
        self.libraryID = libraryID
        self.elementNumbers = elementNumbers
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        let format = try r.cookie()
        let width = try r.u16()
        let height = try r.u16()
        let flags = try r.u8()
        let type = try r.u8()
        let id = try r.libraryID(v)
        self.init(
            version: v, format: format, width: width, height: height, flags: flags, libraryType: type, libraryID: id,
            elementNumbers: try r.array(try r.count(v)) { try $0.u8() })
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.putCookie(format)
        out.put(width)
        out.put(height)
        out.append(flags)
        out.append(libraryType)
        out.putLibraryID(libraryID, v)
        let numbers = elementNumbers.prefix(v.maxCount)
        out.putCount(numbers.count, v)
        out += numbers
    }
}

/// MSEX/EThn: one thumbnail. The spec has no separate 1.2 layout, so 1.2 uses the 1.1 one.
/// The buffer size field is 16 bits: longer buffers are cut to 65535 bytes when encoding.
public struct ElementThumbnail: Equatable, Sendable {
    public var version: MSEXVersion
    public var libraryType: UInt8
    public var libraryID: MSEXLibraryID
    public var elementNumber: UInt8
    public var format: String
    public var width: UInt16
    public var height: UInt16
    public var buffer: [UInt8]

    public init(
        version: MSEXVersion = .v1_2, libraryType: UInt8 = 1, libraryID: MSEXLibraryID, elementNumber: UInt8,
        format: String = "JPEG", width: UInt16, height: UInt16, buffer: [UInt8]
    ) {
        self.version = version
        self.libraryType = libraryType
        self.libraryID = libraryID
        self.elementNumber = elementNumber
        self.format = format
        self.width = width
        self.height = height
        self.buffer = buffer
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        let type = try r.u8()
        let id = try r.libraryID(v)
        let number = try r.u8()
        let format = try r.cookie()
        let width = try r.u16()
        let height = try r.u16()
        let size = Int(try r.u16())
        self.init(
            version: v, libraryType: type, libraryID: id, elementNumber: number, format: format, width: width, height: height,
            buffer: Array(try r.take(size)))
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.append(libraryType)
        out.putLibraryID(libraryID, v)
        out.append(elementNumber)
        out.putCookie(format)
        out.put(width)
        out.put(height)
        let data = buffer.prefix(0xFFFF)
        out.put(UInt16(data.count))
        out += data
    }
}

/// One entry of MSEX/VSrc, the answer to GVSr: a source a console can stream with `RqSt` (same layout in every
/// version: u16 count, then per source u16 id, ucs2 name, u8 output, u8 layer, u16 flags, u16 width, u16 height).
public struct VideoSource: Equatable, Sendable {
    /// `physicalOutput` / `layerNumber` of a source that is not an output / not a layer.
    public static let none: UInt8 = 0xFF
    public var sourceIdentifier: UInt16
    public var name: String
    /// 0-based, `none` when the source is not a physical output.
    public var physicalOutput: UInt8
    /// 0-based, `none` when the source is not a layer.
    public var layerNumber: UInt8
    /// Bit 0: without effects.
    public var flags: UInt16
    public var width: UInt16
    public var height: UInt16

    public init(sourceIdentifier: UInt16, name: String, physicalOutput: UInt8 = none, layerNumber: UInt8 = none, flags: UInt16 = 0, width: UInt16, height: UInt16) {
        self.sourceIdentifier = sourceIdentifier
        self.name = name
        self.physicalOutput = physicalOutput
        self.layerNumber = layerNumber
        self.flags = flags
        self.width = width
        self.height = height
    }

    init(from r: inout CITPReader) throws {
        self.init(
            sourceIdentifier: try r.u16(), name: try r.ucs2(), physicalOutput: try r.u8(), layerNumber: try r.u8(), flags: try r.u16(), width: try r.u16(),
            height: try r.u16())
    }

    static func write(_ sources: [VideoSource], to out: inout [UInt8]) {
        let list = sources.prefix(0xFFFF)
        out.put(UInt16(list.count))
        for s in list {
            out.put(s.sourceIdentifier)
            out.putUCS2(s.name)
            out.append(s.physicalOutput)
            out.append(s.layerNumber)
            out.put(s.flags)
            out.put(s.width)
            out.put(s.height)
        }
    }
}

/// MSEX/RqSt: ask the server to start streaming frames of a source (same layout in every version).
public struct RequestStream: Equatable, Sendable {
    public var version: MSEXVersion
    public var sourceIdentifier: UInt16
    /// "RGB8", "JPEG"; from 1.2 also "PNG ", "fJPG", "fPNG".
    public var frameFormat: String
    /// Preferred minimum size.
    public var frameWidth: UInt16
    public var frameHeight: UInt16
    /// Preferred minimum frame rate.
    public var fps: UInt8
    /// Seconds the stream stays up without a new request; 0 asks for one frame.
    public var timeout: UInt8

    public init(
        version: MSEXVersion = .v1_2, sourceIdentifier: UInt16, frameFormat: String = "JPEG", frameWidth: UInt16, frameHeight: UInt16,
        fps: UInt8, timeout: UInt8
    ) {
        self.version = version
        self.sourceIdentifier = sourceIdentifier
        self.frameFormat = frameFormat
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.fps = fps
        self.timeout = timeout
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        self.init(
            version: v, sourceIdentifier: try r.u16(), frameFormat: try r.cookie(), frameWidth: try r.u16(), frameHeight: try r.u16(),
            fps: try r.u8(), timeout: try r.u8())
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        out.put(sourceIdentifier)
        out.putCookie(frameFormat)
        out.put(frameWidth)
        out.put(frameHeight)
        out.append(fps)
        out.append(timeout)
    }
}

/// MSEX/StFr: one frame, multicast (never TCP from 1.1 on). 1.2 prefixes the media server UUID.
/// For "fJPG"/"fPNG" the fragment preamble is part of `buffer`; the codec does not look inside.
/// The buffer size field is 16 bits: longer buffers are cut to 65535 bytes when encoding.
public struct StreamFrame: Equatable, Sendable {
    public var version: MSEXVersion
    /// 1.2: 36-character UUID of the sending media server.
    public var mediaServerUUID: String
    public var sourceIdentifier: UInt16
    public var frameFormat: String
    public var frameWidth: UInt16
    public var frameHeight: UInt16
    public var buffer: [UInt8]

    public init(
        version: MSEXVersion = .v1_2, mediaServerUUID: String = "", sourceIdentifier: UInt16, frameFormat: String = "JPEG",
        frameWidth: UInt16, frameHeight: UInt16, buffer: [UInt8]
    ) {
        self.version = version
        self.mediaServerUUID = mediaServerUUID
        self.sourceIdentifier = sourceIdentifier
        self.frameFormat = frameFormat
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.buffer = buffer
    }

    init(version v: MSEXVersion, from r: inout CITPReader) throws {
        let uuid = try v >= .v1_2 ? r.fixedString(36) : ""
        let source = try r.u16()
        let format = try r.cookie()
        let width = try r.u16()
        let height = try r.u16()
        let size = Int(try r.u16())
        self.init(
            version: v, mediaServerUUID: uuid, sourceIdentifier: source, frameFormat: format, frameWidth: width, frameHeight: height,
            buffer: Array(try r.take(size)))
    }

    func write(to out: inout [UInt8], as v: MSEXVersion) {
        if v >= .v1_2 { out.putFixedString(mediaServerUUID, 36) }
        out.put(sourceIdentifier)
        out.putCookie(frameFormat)
        out.put(frameWidth)
        out.put(frameHeight)
        let data = buffer.prefix(0xFFFF)
        out.put(UInt16(data.count))
        out += data
    }
}

extension ClientInformation {
    func write(to out: inout [UInt8], as v: MSEXVersion) { out.putVersions(supportedVersions) }
}

extension Nack {
    func write(to out: inout [UInt8], as v: MSEXVersion) { out.putCookie(receivedContentType) }
}

// MARK: - Dispatch

extension CITPPacket {
    /// `body` is the whole body after the CITP header (kept for `.unknown`); `r` is a fresh reader over it.
    static func parseMSEX(_ r: inout CITPReader, body: [UInt8]) throws -> CITPPacket {
        let version = MSEXVersion(major: try r.u8(), minor: try r.u8())
        guard version.major == 1 else { throw CITPError.unsupportedVersion }
        switch try r.cookie() {
        case "CInf": return .clientInformation(ClientInformation(version: version, supportedVersions: try r.versions()))
        case "SInf": return .serverInformation(try ServerInformation(version: version, from: &r))
        case "Nack": return .nack(Nack(version: version, receivedContentType: try r.cookie()))
        case "LSta":
            let count = Int(try r.u8())
            return .layerStatus(try r.array(count) { try LayerStatus(version: version, from: &$0) })
        case "GELI": return .getElementLibraryInformation(try GetElementLibraryInformation(version: version, from: &r))
        case "ELIn": return .elementLibraryInformation(try ElementLibraryInformation(version: version, from: &r))
        case "GEIn": return .getElementInformation(try GetElementInformation(version: version, from: &r))
        case "MEIn": return .mediaElementInformation(try MediaElementInformation(version: version, from: &r))
        case "GETh": return .getElementThumbnail(try GetElementThumbnail(version: version, from: &r))
        case "EThn": return .elementThumbnail(try ElementThumbnail(version: version, from: &r))
        case "GVSr": return .getVideoSources
        case "VSrc":
            let count = Int(try r.u16())
            return .videoSources(try r.array(count) { try VideoSource(from: &$0) })
        case "RqSt": return .requestStream(try RequestStream(version: version, from: &r))
        case "StFr": return .streamFrame(try StreamFrame(version: version, from: &r))
        default: return .unknown(contentType: "MSEX", body: body)  // spec: silently ignore unrecognised cookies
        }
    }

    /// MSEX header (version + cookie) followed by the payload `write` produces.
    static func msex(_ cookie: String, _ v: MSEXVersion, _ write: (inout [UInt8], MSEXVersion) -> Void) -> [UInt8] {
        var out = [v.major, v.minor]
        out.putCookie(cookie)
        write(&out, v)
        return out
    }
}

// MARK: - MSEX byte helpers

extension CITPReader {
    mutating func array<T>(_ n: Int, _ element: (inout CITPReader) throws -> T) throws -> [T] {
        var out: [T] = []
        for _ in 0..<n { out.append(try element(&self)) }
        return out
    }

    /// Element/library count: u8 before 1.2, u16 from 1.2.
    mutating func count(_ v: MSEXVersion) throws -> Int {
        try v >= .v1_2 ? Int(u16()) : Int(u8())
    }

    /// MSEXLibraryId (4 bytes) from 1.1, a bare library number before.
    mutating func libraryID(_ v: MSEXVersion) throws -> MSEXLibraryID {
        if v >= .v1_1 { return MSEXLibraryID(level: try u8(), level1: try u8(), level2: try u8(), level3: try u8()) }
        return .topLevel(try u8())
    }

    /// u8 count, then u16 entries with the major version in the high byte (so minor comes first on the wire).
    mutating func versions() throws -> [MSEXVersion] {
        let n = Int(try u8())
        return try array(n) { r in
            let wire = try r.u16()
            return MSEXVersion(major: UInt8(wire >> 8), minor: UInt8(wire & 0xFF))
        }
    }

    /// u8 count, then 4-byte cookies.
    mutating func cookies() throws -> [String] {
        let n = Int(try u8())
        return try array(n) { try $0.cookie() }
    }
}

extension Array where Element == UInt8 {
    mutating func putCount(_ n: Int, _ v: MSEXVersion) {
        if v >= .v1_2 { put(UInt16(clamping: n)) } else { append(UInt8(clamping: n)) }
    }

    mutating func putLibraryID(_ id: MSEXLibraryID, _ v: MSEXVersion) {
        if v >= .v1_1 { append(contentsOf: [id.level, id.level1, id.level2, id.level3]) } else { append(id.level1) }
    }

    mutating func putVersions(_ versions: [MSEXVersion]) {
        let list = versions.prefix(0xFF)
        append(UInt8(list.count))
        for v in list { put(UInt16(v.major) << 8 | UInt16(v.minor)) }
    }

    mutating func putCookies(_ cookies: [String]) {
        let list = cookies.prefix(0xFF)
        append(UInt8(list.count))
        for c in list { putCookie(c) }
    }
}
