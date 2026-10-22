// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import LanthornCore
import LanthornEngine
import Logging

func usage() -> String {
    """
    usage: lanthornd [--port N] [--web-root PATH] [--foreground]
           lanthornd channel-map            print docs/channel-map.md to stdout
           lanthornd gdtf FILE              write the GDTF fixture file
      --port N         HTTPS port (default 8443)
      --web-root PATH  directory with the built web UI (default: auto-detect)
      --foreground     run attached to the terminal (default when started by hand)
      --version        print the version and exit
    """
}

switch CommandLine.arguments.dropFirst().first {
case "channel-map":
    print(ChannelMapDocument.markdown(), terminator: "")
    exit(0)
case "gdtf":
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write(Data("usage: lanthornd gdtf FILE\n".utf8))
        exit(64)
    }
    do {
        try Data(GDTFExporter.gdtf()).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("cannot write GDTF: \(error)\n".utf8))
        exit(1)
    }
default:
    break
}

var port: UInt16 = 8443
var webRootOverride: URL?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port":
        guard let value = arguments.next(), let parsed = UInt16(value) else {
            FileHandle.standardError.write(Data("invalid --port\n".utf8))
            exit(64)
        }
        port = parsed
    case "--web-root":
        guard let value = arguments.next() else {
            FileHandle.standardError.write(Data("missing --web-root value\n".utf8))
            exit(64)
        }
        webRootOverride = URL(fileURLWithPath: value)
    case "--foreground":
        break
    case "--version":
        print("lanthornd \(LanthornVersion.string)")
        exit(0)
    case "-h", "--help":
        print(usage())
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument \(argument)\n\(usage())\n".utf8))
        exit(64)
    }
}

do {
    try AppPaths.ensureDirectories()
} catch {
    FileHandle.standardError.write(Data("cannot create directories: \(error)\n".utf8))
    exit(1)
}
EngineLogging.bootstrap(fileURL: AppPaths.logs.appending(path: "lanthornd.log"), level: ProcessInfo.processInfo.environment["LANTHORN_LOG"] == "debug" ? .debug : .info)
let logger = Logger(label: "lanthornd")
let engine = Engine(options: EngineOptions(port: port, webRoot: webRootOverride ?? WebRoot.locate()), logger: logger)
do {
    try engine.start()
} catch {
    logger.critical("engine failed to start", metadata: ["error": "\(error)"])
    exit(1)
}

// launchd stops agents with SIGTERM; Ctrl-C sends SIGINT.
let signalSources = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        engine.stop()
        exit(0)
    }
    source.resume()
    return source
}

// An NSApplication run loop, as ADR-0001: output windows come in Phase 2.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()
