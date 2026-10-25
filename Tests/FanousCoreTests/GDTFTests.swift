// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import Foundation
import Testing

@testable import FanousCore

final class XMLCollector: NSObject, XMLParserDelegate {
    var elements: [(name: String, attributes: [String: String])] = []
    var error: Error?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        elements.append((name, attributes))
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) { error = parseError }
}

@Suite struct GDTFTests {
    static func parsed() -> XMLCollector {
        let collector = XMLCollector()
        let parser = XMLParser(data: Data(GDTFExporter.descriptionXML(version: "test", date: Date(timeIntervalSince1970: 1_790_000_000)).utf8))
        parser.delegate = collector
        #expect(parser.parse())
        #expect(collector.error == nil)
        return collector
    }

    @Test func xmlIsWellFormedWithThreeModes() {
        let xml = Self.parsed()
        #expect(xml.elements.first?.name == "GDTF" && xml.elements.first?.attributes["DataVersion"] == "1.2")
        let fixtureType = xml.elements.first { $0.name == "FixtureType" }!
        #expect(fixtureType.attributes["FixtureTypeID"] == GDTFExporter.fixtureTypeID)
        #expect(xml.elements.filter { $0.name == "DMXMode" }.count == 3)
        #expect(xml.elements.contains { $0.name == "Revision" && $0.attributes["Date"] == "2026-09-21T14:13:20" })
    }

    @Test func everyModeCoversItsFootprintExactlyOnce() {
        let xml = Self.parsed()
        var mode = ""
        var offsets: [String: [Int]] = [:]
        for element in xml.elements {
            if element.name == "DMXMode" { mode = element.attributes["Name"]! }
            if element.name == "DMXChannel" {
                offsets[mode, default: []] += element.attributes["Offset"]!.split(separator: ",").map { Int($0)! }
            }
        }
        #expect(offsets["Layer (64ch)"]!.sorted() == Array(1...64))
        #expect(offsets["Master (8ch)"]!.sorted() == Array(1...8))
        #expect(offsets["Output (8ch)"]!.sorted() == Array(1...8))
    }

    @Test func attributesAndInitialFunctionsResolve() {
        let xml = Self.parsed()
        let attributes = Set(xml.elements.filter { $0.name == "Attribute" }.map { $0.attributes["Name"]! })
        let features = Set(xml.elements.filter { $0.name == "Attribute" }.map { $0.attributes["Feature"]! })
        var featureGroup = ""
        var definedFeatures = Set<String>()
        for element in xml.elements {
            if element.name == "FeatureGroup" { featureGroup = element.attributes["Name"]! }
            if element.name == "Feature" { definedFeatures.insert("\(featureGroup).\(element.attributes["Name"]!)") }
        }
        #expect(features.isSubset(of: definedFeatures))
        var functionNames = Set<String>()
        for element in xml.elements where element.name == "ChannelFunction" {
            #expect(attributes.contains(element.attributes["Attribute"]!))
            functionNames.insert("\(element.attributes["Attribute"]!).\(element.attributes["Name"]!)")
            let bytes = Int(element.attributes["DMXFrom"]!.split(separator: "/")[1])!
            let defaultValue = Int(element.attributes["Default"]!.split(separator: "/")[0])!
            #expect(defaultValue <= (bytes == 2 ? 65535 : 255))
        }
        for element in xml.elements where element.name == "DMXChannel" {
            let initial = element.attributes["InitialFunction"]!
            #expect(initial.hasPrefix("Base_"))
            // "<Geometry>_<Attribute>.<Attribute>.<ChannelFunction>": the DMXChannel name, then logical channel, then function.
            let parts = initial.dropFirst(5).split(separator: ".", maxSplits: 1).map(String.init)
            #expect(functionNames.contains(parts[1]), "InitialFunction \(initial) resolves")
        }
        for element in xml.elements where element.name == "LogicalChannel" {
            #expect(attributes.contains(element.attributes["Attribute"]!))
        }
        #expect(xml.elements.filter { $0.name == "ChannelSet" }.count > 40)
    }

    @Test func zipIsValid() throws {
        #expect(ZipWriter.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        let bytes = GDTFExporter.gdtf(version: "test")
        #expect(Array(bytes.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        let url = FileManager.default.temporaryDirectory.appending(path: "fanous-test-\(UUID().uuidString).gdtf")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: output))
        #expect(output.contains("description.xml"))
    }

    @Test func channelMapDocumentListsEveryParameter() {
        let markdown = ChannelMapDocument.markdown()
        for mode in FixtureMode.allCases {
            for spec in ChannelMap.specs(for: mode) { #expect(markdown.contains("| \(spec.name) |")) }
        }
        #expect(markdown.components(separatedBy: "| Reserved |").count == 4)
        #expect(markdown.contains("| 6–7 | Speed | 16 | 32768 |"))
    }
}
