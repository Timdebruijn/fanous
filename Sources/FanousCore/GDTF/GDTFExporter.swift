// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation

/// GDTF 1.2 (DIN SPEC 15800:2022) description of the Fanous fixture type,
/// generated from `ChannelMap` so consoles and the server can never disagree.
public enum GDTFExporter {
    /// Stable for the life of the fixture type; footprints never change (ADR-0008).
    public static let fixtureTypeID = "7D2B8C8E-5E42-4C5B-9C4B-1F2A3B4C5D6E"
    public static let dataVersion = "1.2"
    public static let geometryName = "Base"

    struct Attribute {
        let name: String
        let pretty: String
        let featureGroup: String
        let feature: String
        let unit: String
    }

    static func attribute(for id: ParameterID) -> Attribute {
        func a(_ name: String, _ pretty: String, _ group: String, _ feature: String, _ unit: String) -> Attribute {
            Attribute(name: name, pretty: pretty, featureGroup: group, feature: feature, unit: unit)
        }
        switch id {
        case .layer(.intensity), .master(.intensity), .output(.intensity): return a("Dimmer", "Dim", "Dimmer", "Dimmer", "Percent")
        case .layer(.control), .master(.control), .output(.control): return a("Control1", "Control", "Control", "Control", "None")
        case .master(.testPattern), .output(.testPattern): return a("TestPattern", "Pattern", "Control", "Control", "None")
        case .layer(.speed), .master(.speed): return a("PlaySpeed", "Speed", "Media", "Media", "Percent")
        case .layer(.folder): return a("MediaFolder", "Folder", "Media", "Media", "None")
        case .layer(.file): return a("MediaFile", "File", "Media", "Media", "None")
        case .layer(.playMode): return a("PlayMode", "Play", "Media", "Media", "None")
        case .layer(.inPoint): return a("InPoint", "In", "Media", "Media", "Percent")
        case .layer(.outPoint): return a("OutPoint", "Out", "Media", "Media", "Percent")
        case .layer(.dissolve): return a("Dissolve", "Dissolve", "Media", "Media", "Time")
        case .layer(.positionX): return a("XYZ_X", "X", "Position", "XYZ", "Percent")
        case .layer(.positionY): return a("XYZ_Y", "Y", "Position", "XYZ", "Percent")
        case .layer(.positionZ): return a("XYZ_Z", "Z", "Position", "XYZ", "Percent")
        case .layer(.scaleX): return a("Scale_X", "Scale X", "Position", "Scale", "Percent")
        case .layer(.scaleY): return a("Scale_Y", "Scale Y", "Position", "Scale", "Percent")
        case .layer(.fitMode): return a("FitMode", "Fit", "Position", "Scale", "None")
        case .layer(.rotationX): return a("Rot_X", "Rot X", "Position", "Rotation", "Angle")
        case .layer(.rotationY): return a("Rot_Y", "Rot Y", "Position", "Rotation", "Angle")
        case .layer(.rotationZ): return a("Rot_Z", "Rot Z", "Position", "Rotation", "Angle")
        case .layer(.red): return a("ColorRGB_Red", "R", "Color", "RGB", "Percent")
        case .layer(.green): return a("ColorRGB_Green", "G", "Color", "RGB", "Percent")
        case .layer(.blue): return a("ColorRGB_Blue", "B", "Color", "RGB", "Percent")
        case .layer(.brightness): return a("Brightness", "Bright", "Color", "Color", "Percent")
        case .layer(.contrast): return a("Contrast", "Contrast", "Color", "Color", "Percent")
        case .layer(.saturation): return a("Saturation", "Sat", "Color", "Color", "Percent")
        case .layer(.hue): return a("Hue", "Hue", "Color", "Color", "Angle")
        case .layer(.blendMode): return a("VideoBlendMode", "Blend", "Video", "Video", "None")
        case .layer(.effect1): return a("VideoEffect1Type", "FX1", "Video", "Video", "None")
        case .layer(.effect1A): return a("VideoEffect1Parameter1", "FX1 A", "Video", "Video", "Percent")
        case .layer(.effect1B): return a("VideoEffect1Parameter2", "FX1 B", "Video", "Video", "Percent")
        case .layer(.effect2): return a("VideoEffect2Type", "FX2", "Video", "Video", "None")
        case .layer(.effect2A): return a("VideoEffect2Parameter1", "FX2 A", "Video", "Video", "Percent")
        case .layer(.effect2B): return a("VideoEffect2Parameter2", "FX2 B", "Video", "Video", "Percent")
        case .layer(.cropLeft): return a("CropLeft", "Crop L", "Position", "Crop", "Percent")
        case .layer(.cropRight): return a("CropRight", "Crop R", "Position", "Crop", "Percent")
        case .layer(.cropTop): return a("CropTop", "Crop T", "Position", "Crop", "Percent")
        case .layer(.cropBottom): return a("CropBottom", "Crop B", "Position", "Crop", "Percent")
        case .layer(.audioVolume): return a("VideoSoundVolume1", "Volume", "Video", "Video", "Percent")
        case .layer(.audioPan): return a("AudioPan", "Pan", "Video", "Video", "Percent")
        case .layer(.sync): return a("VideoSync", "Sync", "Video", "Video", "None")
        case .output(.blend): return a("BlendBypass", "Blend", "Control", "Control", "None")
        case .output(.preset): return a("MappingPreset", "Map", "Control", "Control", "None")
        case .output(.fade): return a("MappingFade", "Map fade", "Control", "Control", "Time")
        case .keystone(let p):
            switch p {
            case .topLeftX: return a("KeystoneTopLeftX", "TL X", "Position", "Keystone", "Percent")
            case .topLeftY: return a("KeystoneTopLeftY", "TL Y", "Position", "Keystone", "Percent")
            case .topRightX: return a("KeystoneTopRightX", "TR X", "Position", "Keystone", "Percent")
            case .topRightY: return a("KeystoneTopRightY", "TR Y", "Position", "Keystone", "Percent")
            case .bottomRightX: return a("KeystoneBottomRightX", "BR X", "Position", "Keystone", "Percent")
            case .bottomRightY: return a("KeystoneBottomRightY", "BR Y", "Position", "Keystone", "Percent")
            case .bottomLeftX: return a("KeystoneBottomLeftX", "BL X", "Position", "Keystone", "Percent")
            case .bottomLeftY: return a("KeystoneBottomLeftY", "BL Y", "Position", "Keystone", "Percent")
            }
        }
    }

    public static func descriptionXML(version: String = FanousVersion.string, date: Date = Date()) -> String {
        var attributes: [String: Attribute] = [:]
        var groups: [String: Set<String>] = [:]
        for mode in FixtureMode.allCases {
            for spec in ChannelMap.specs(for: mode) {
                let attribute = attribute(for: spec.id)
                attributes[attribute.name] = attribute
                groups[attribute.featureGroup, default: []].insert(attribute.feature)
            }
        }
        attributes["NoFeature"] = Attribute(name: "NoFeature", pretty: "NoFeature", featureGroup: "Control", feature: "Control", unit: "None")
        groups["Control", default: []].insert("Control")

        var x = ""
        x += "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
        x += "<GDTF DataVersion=\"\(dataVersion)\">\n"
        x += "  <FixtureType Name=\"\(Attribution.projectName)\" ShortName=\"\(Attribution.projectName)\" LongName=\"\(Attribution.projectName) Media Server\" Manufacturer=\"\(Attribution.projectName)\" Description=\"\(esc(Attribution.projectName)) media server v\(esc(version)): layer, master, output and keystone fixtures. \(esc(Attribution.repositoryURL))\" FixtureTypeID=\"\(fixtureTypeID)\" Thumbnail=\"\" RefFT=\"\" CanHaveChildren=\"No\">\n"
        x += "    <AttributeDefinitions>\n      <ActivationGroups/>\n      <FeatureGroups>\n"
        for group in groups.keys.sorted() {
            x += "        <FeatureGroup Name=\"\(group)\" Pretty=\"\(group)\">\n"
            for feature in groups[group]!.sorted() { x += "          <Feature Name=\"\(feature)\"/>\n" }
            x += "        </FeatureGroup>\n"
        }
        x += "      </FeatureGroups>\n      <Attributes>\n"
        for name in attributes.keys.sorted() {
            let attribute = attributes[name]!
            x += "        <Attribute Name=\"\(attribute.name)\" Pretty=\"\(esc(attribute.pretty))\" Feature=\"\(attribute.featureGroup).\(attribute.feature)\" PhysicalUnit=\"\(attribute.unit)\"/>\n"
        }
        x += "      </Attributes>\n    </AttributeDefinitions>\n"
        x += "    <Wheels/>\n    <PhysicalDescriptions/>\n"
        x += "    <Models>\n      <Model Name=\"\(geometryName)\" Length=\"0.1\" Width=\"0.1\" Height=\"0.1\" PrimitiveType=\"Cube\"/>\n    </Models>\n"
        x += "    <Geometries>\n      <Geometry Name=\"\(geometryName)\" Model=\"\(geometryName)\" Position=\"{1,0,0,0}{0,1,0,0}{0,0,1,0}{0,0,0,1}\"/>\n    </Geometries>\n"
        x += "    <DMXModes>\n"
        for mode in FixtureMode.allCases {
            x += "      <DMXMode Name=\"\(mode.displayName) (\(mode.footprint)ch)\" Description=\"\(mode.displayName) fixture, \(mode.footprint) channels\" Geometry=\"\(geometryName)\">\n        <DMXChannels>\n"
            for spec in ChannelMap.specs(for: mode) { x += channelXML(spec) }
            for channel in ChannelMap.reserved(for: mode).map(Array.init) ?? [] {
                x += "          <DMXChannel DMXBreak=\"1\" Offset=\"\(channel)\" InitialFunction=\"\(geometryName)_NoFeature.NoFeature.Reserved \(channel)\" Highlight=\"None\" Geometry=\"\(geometryName)\">\n"
                x += "            <LogicalChannel Attribute=\"NoFeature\" Snap=\"Yes\" Master=\"None\" MibFade=\"0\" DMXChangeTimeLimit=\"0\">\n"
                x += "              <ChannelFunction Name=\"Reserved \(channel)\" Attribute=\"NoFeature\" OriginalAttribute=\"\" DMXFrom=\"0/1\" Default=\"0/1\" PhysicalFrom=\"0\" PhysicalTo=\"0\" RealFade=\"0\" RealAcceleration=\"0\"/>\n"
                x += "            </LogicalChannel>\n          </DMXChannel>\n"
            }
            x += "        </DMXChannels>\n        <Relations/>\n        <FTMacros/>\n      </DMXMode>\n"
        }
        x += "    </DMXModes>\n"
        let c = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
        let stamp = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        x += "    <Revisions>\n      <Revision Text=\"Generated by \(Attribution.projectName) \(esc(version))\" Date=\"\(stamp)\" UserID=\"0\" ModifiedBy=\"\(Attribution.projectName)\"/>\n    </Revisions>\n"
        x += "    <FTPresets/>\n    <Protocols/>\n  </FixtureType>\n</GDTF>\n"
        return x
    }

    static func channelXML(_ spec: ParameterSpec) -> String {
        let attribute = attribute(for: spec.id)
        let bytes = spec.bits / 8
        let offset = spec.channels.map(String.init).joined(separator: ",")
        let function = esc(spec.name)
        var x = "          <DMXChannel DMXBreak=\"1\" Offset=\"\(offset)\" InitialFunction=\"\(geometryName)_\(attribute.name).\(attribute.name).\(function)\" Highlight=\"None\" Geometry=\"\(geometryName)\">\n"
        x += "            <LogicalChannel Attribute=\"\(attribute.name)\" Snap=\"\(spec.isContinuous ? "No" : "Yes")\" Master=\"None\" MibFade=\"0\" DMXChangeTimeLimit=\"0\">\n"
        let physicalFrom = spec.physical(fromRaw: 0), physicalTo = spec.physical(fromRaw: spec.rawMax)
        x += "              <ChannelFunction Name=\"\(function)\" Attribute=\"\(attribute.name)\" OriginalAttribute=\"\" DMXFrom=\"0/\(bytes)\" Default=\"\(spec.defaultRaw)/\(bytes)\" PhysicalFrom=\"\(num(physicalFrom))\" PhysicalTo=\"\(num(physicalTo))\" RealFade=\"0\" RealAcceleration=\"0\">\n"
        if case .bands(var bands, let fallback) = spec.kind {
            // A ChannelSet has no DMXTo: it runs to the next set's DMXFrom − 1. Close the last band with the
            // band the engine decodes for the unbanded rest, so a console does not stretch the last one to 255.
            if let last = bands.last, last.to < 255, let rest = bands.first(where: { $0.value == fallback }) {
                bands.append(Band(from: last.to + 1, to: 255, name: rest.name, value: rest.value))
            }
            for band in bands {
                x += "                <ChannelSet Name=\"\(esc(band.name))\" DMXFrom=\"\(band.from)/1\" PhysicalFrom=\"\(band.value)\" PhysicalTo=\"\(band.value)\"/>\n"
            }
        }
        x += "              </ChannelFunction>\n            </LogicalChannel>\n          </DMXChannel>\n"
        return x
    }

    static func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The .gdtf file: a zip containing description.xml.
    public static func gdtf(version: String = FanousVersion.string, date: Date = Date()) -> [UInt8] {
        ZipWriter.archive([ZipWriter.Entry("description.xml", Array(descriptionXML(version: version, date: date).utf8))], date: date)
    }
}
