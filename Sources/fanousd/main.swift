// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Foundation
import FanousCore
import FanousEngine
import Logging

func usage() -> String {
    """
    usage: fanousd [--port N] [--web-root PATH] [--foreground] [--no-network]
           fanousd channel-map            print docs/channel-map.md to stdout
           fanousd gdtf FILE              write the GDTF fixture file
           fanousd reset-tls              delete the TLS key and certificate (regenerated at next start)
           fanousd ingest DIR OUT.mov [--fps N] [--codec prores4444|prores422hq|hapq|hap|hapalpha]
                                            convert an image sequence to a movie (Phase 3 stub)
      --port N         HTTPS port (default 8443)
      --web-root PATH  directory with the built web UI (default: auto-detect)
      --foreground     run attached to the terminal (default when started by hand)
      --scene FILE     render a scene (JSON: canvasWidth, canvasHeight, fps, layerCount, media[{folder,file,path|syphon}], display);
                       its canvas size and fps override the project's for this run
      --no-network     no Art-Net, sACN, OSC, CITP or Bonjour, HTTPS on 127.0.0.1 only (tests; next to another engine)
      --version        print the version and exit
    environment:
      FANOUS_HOME=DIR  use DIR (absolute) instead of the home directory for Application Support, logs, cache, TLS
                       (keychain tag included) and the default library (DIR/Library/..., DIR/Movies/Fanous Library)
      FANOUS_LOG=debug debug logging
    """
}

switch CommandLine.arguments.dropFirst().first {
case "channel-map":
    print(ChannelMapDocument.markdown(), terminator: "")
    exit(0)
case "protocol-dts":
    print(ProtocolTypes.typescript(commands: Engine.commandSpecs()), terminator: "")
    exit(0)
case "reset-tls":
    // an ignored FANOUS_HOME would make this reset the real install's identity
    if let problem = AppPaths.homeOverrideProblem {
        FileHandle.standardError.write(Data("\(problem); nothing reset\n".utf8))
        exit(64)
    }
    TLSIdentity.reset(directory: AppPaths.tls)
    print("TLS identity removed; a new one is generated at the next start")
    exit(0)
case "ingest":
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: fanousd ingest DIR OUT.mov [--fps N] [--codec prores4444|prores422hq|hapq|hap|hapalpha]\n".utf8))
        exit(64)
    }
    func option(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let codec: MovieWriter.Codec =
        switch option("--codec") ?? "prores4444" {
        case "prores422hq": .proRes422HQ
        case "prores422": .proRes422
        case "hapq": .hap(.hapQ)
        case "hap": .hap(.hap)
        case "hapalpha": .hap(.hapAlpha)
        default: .proRes4444
        }
    do {
        let frames = try SequenceIngest.frames(in: URL(fileURLWithPath: args[0]))
        let count = try SequenceIngest.convert(frames: frames, to: URL(fileURLWithPath: args[1]), fps: Int32(option("--fps") ?? "25") ?? 25, codec: codec)
        print("wrote \(count) frames to \(args[1])")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("ingest failed: \(error)\n".utf8))
        exit(1)
    }
case "gdtf":
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write(Data("usage: fanousd gdtf FILE\n".utf8))
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
var sceneFile: URL?
var network = true
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
    case "--no-network":
        network = false
    case "--scene":
        guard let value = arguments.next() else {
            FileHandle.standardError.write(Data("missing --scene value\n".utf8))
            exit(64)
        }
        sceneFile = URL(fileURLWithPath: value)
    case "--version":
        print("fanousd \(FanousVersion.string)")
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
// One engine per user (DESIGN.md §2.1): an flock on engine.lock held for the whole run; a second start exits with
// the owner's pid. launchd (KeepAlive) retries a refused start every 10 s, which is the intended outcome.
let lockFile = AppPaths.applicationSupport.appending(path: "engine.lock")
let lockDescriptor = open(lockFile.path, O_RDWR | O_CREAT, 0o600)
if lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
    let owner = (try? String(contentsOf: lockFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    FileHandle.standardError.write(Data("fanousd is already running (pid \(owner.isEmpty ? "?" : owner)): one engine per user\n".utf8))
    exit(75)
}
_ = ftruncate(lockDescriptor, 0)
_ = "\(getpid())\n".withCString { pwrite(lockDescriptor, $0, strlen($0), 0) }
EngineLogging.bootstrap(fileURL: AppPaths.logs.appending(path: "fanousd.log"), level: ProcessInfo.processInfo.environment["FANOUS_LOG"] == "debug" ? .debug : .info)
let logger = Logger(label: "fanousd")
if let problem = AppPaths.homeOverrideProblem { logger.warning("\(problem)") }
if let home = AppPaths.homeOverride { logger.notice("FANOUS_HOME: data, logs, TLS and the default library under \(home.path)") }
var scene: SceneConfig?
if let sceneFile {
    do { scene = try SceneConfig.load(sceneFile) } catch {
        FileHandle.standardError.write(Data("cannot load scene: \(error)\n".utf8))
        exit(1)
    }
}
let engine = Engine(options: EngineOptions(port: port, webRoot: webRootOverride ?? WebRoot.locate(), scene: scene, network: network), logger: logger)
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
