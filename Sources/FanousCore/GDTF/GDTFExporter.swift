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
        case .layer(let p):
            switch p {
            case .intensity: return a("Dimmer", "Dim", "Dimmer", "Dimmer", "Percent")
            case .folder: return a("MediaFolder", "Folder", "Media", "Media", "None")
            case .file: return a("MediaFile", "File", "Media", "Media", "None")
            case .playMode: return a("PlayMode", "Play", "Media", "Media", "None")
            case .speed: return a("PlaySpeed", "Speed", "Media", "Media", "Percent")
            case .inPoint: return a("InPoint", "In", "Media", "Media", "Percent")
            case .outPoint: return a("OutPoint", "Out", "Media", "Media", "Percent")
            case .dissolve: return a("Dissolve", "Dissolve", "Media", "Media", "Time")
            case .positionX: return a("XYZ_X", "X", "Position", "XYZ", "Percent")
            case .positionY: return a("XYZ_Y", "Y", "Position", "XYZ", "Percent")
            case .positionZ: return a("XYZ_Z", "Z", "Position", "XYZ", "Percent")
            case .scaleX: return a("Scale_X", "Scale X", "Position", "Scale", "Percent")
            case .scaleY: return a("Scale_Y", "Scale Y", "Position", "Scale", "Percent")
            case .fitMode: return a("FitMode", "Fit", "Position", "Scale", "None")
            case .rotationX: return a("Rot_X", "Rot X", "Position", "Rotation", "Angle")
            case .rotationY: return a("Rot_Y", "Rot Y", "Position", "Rotation", "Angle")
            case .rotationZ: return a("Rot_Z", "Rot Z", "Position", "Rotation", "Angle")
            case .red: return a("ColorRGB_Red", "R", "Color", "RGB", "Percent")
            case .green: return a("ColorRGB_Green", "G", "Color", "RGB", "Percent")
            case .blue: return a("ColorRGB_Blue", "B", "Color", "RGB", "Percent")
            case .brightness: return a("Brightness", "Bright", "Color", "Color", "Percent")
            case .contrast: return a("Contrast", "Contrast", "Color", "Color", "Percent")
            case .saturation: return a("Saturation", "Sat", "Color", "Color", "Percent")
            case .hue: return a("Hue", "Hue", "Color", "Color", "Angle")
            case .blendMode: return a("VideoBlendMode", "Blend", "Video", "Video", "None")
            case .effect1: return a("VideoEffect1Type", "FX1", "Video", "Video", "None")
            case .effect1A: return a("VideoEffect1Parameter1", "FX1 A", "Video", "Video", "Percent")
            case .effect1B: return a("VideoEffect1Parameter2", "FX1 B", "Video", "Video", "Percent")
            case .effect2: return a("VideoEffect2Type", "FX2", "Video", "Video", "None")
            case .effect2A: return a("VideoEffect2Parameter1", "FX2 A", "Video", "Video", "Percent")
            case .effect2B: return a("VideoEffect2Parameter2", "FX2 B", "Video", "Video", "Percent")
            case .cropLeft: return a("CropLeft", "Crop L", "Position", "Crop", "Percent")
            case .cropRight: return a("CropRight", "Crop R", "Position", "Crop", "Percent")
            case .cropTop: return a("CropTop", "Crop T", "Position", "Crop", "Percent")
            case .cropBottom: return a("CropBottom", "Crop B", "Position", "Crop", "Percent")
            case .audioVolume: return a("VideoSoundVolume1", "Volume", "Video", "Video", "Percent")
            case .audioPan: return a("AudioPan", "Pan", "Video", "Video", "Percent")
            case .control: return a("Control1", "Control", "Control", "Control", "None")
            case .sync: return a("VideoSync", "Sync", "Video", "Video", "None")
            }
        case .master(let p):
            switch p {
            case .intensity: return a("Dimmer", "Dim", "Dimmer", "Dimmer", "Percent")
            case .control: return a("Control1", "Control", "Control", "Control", "None")
            case .testPattern: return a("TestPattern", "Pattern", "Control", "Control", "None")
            case .speed: return a("PlaySpeed", "Speed", "Media", "Media", "Percent")
            }
        case .output(let p):
            switch p {
            case .intensity: return a("Dimmer", "Dim", "Dimmer", "Dimmer", "Percent")
            case .control: return a("Control1", "Control", "Control", "Control", "None")
            case .testPattern: return a("TestPattern", "Pattern", "Control", "Control", "None")
            case .blend: return a("BlendBypass", "Blend", "Control", "Control", "None")
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
        x += "  <FixtureType Name=\"\(Attribution.projectName)\" ShortName=\"\(Attribution.projectName)\" LongName=\"\(Attribution.projectName) Media Server\" Manufacturer=\"\(Attribution.projectName)\" Description=\"\(esc(Attribution.projectName)) media server v\(esc(version)): layer, master and output fixtures. \(esc(Attribution.repositoryURL))\" FixtureTypeID=\"\(fixtureTypeID)\" Thumbnail=\"\" RefFT=\"\" CanHaveChildren=\"No\">\n"
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
            for channel in reserved(for: mode) {
                x += "          <DMXChannel DMXBreak=\"1\" Offset=\"\(channel)\" InitialFunction=\"\(geometryName)_NoFeature.NoFeature.Reserved \(channel)\" Highlight=\"None\" Geometry=\"\(geometryName)\">\n"
                x += "            <LogicalChannel Attribute=\"NoFeature\" Snap=\"Yes\" Master=\"None\" MibFade=\"0\" DMXChangeTimeLimit=\"0\">\n"
                x += "              <ChannelFunction Name=\"Reserved \(channel)\" Attribute=\"NoFeature\" OriginalAttribute=\"\" DMXFrom=\"0/1\" Default=\"0/1\" PhysicalFrom=\"0\" PhysicalTo=\"0\" RealFade=\"0\" RealAcceleration=\"0\"/>\n"
                x += "            </LogicalChannel>\n          </DMXChannel>\n"
            }
            x += "        </DMXChannels>\n        <Relations/>\n        <FTMacros/>\n      </DMXMode>\n"
        }
        x += "    </DMXModes>\n"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        x += "    <Revisions>\n      <Revision Text=\"Generated by \(Attribution.projectName) \(esc(version))\" Date=\"\(stamp)\" UserID=\"0\" ModifiedBy=\"\(Attribution.projectName)\"/>\n    </Revisions>\n"
        x += "    <FTPresets/>\n    <Protocols/>\n  </FixtureType>\n</GDTF>\n"
        return x
    }

    static func reserved(for mode: FixtureMode) -> ClosedRange<Int> {
        switch mode {
        case .layer: ChannelMap.reservedLayerChannels
        case .master: ChannelMap.reservedMasterChannels
        case .output: ChannelMap.reservedOutputChannels
        }
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
        if case .bands(let bands, _) = spec.kind {
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
