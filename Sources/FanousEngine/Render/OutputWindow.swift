// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

import AppKit
import Metal
import QuartzCore

/// Borderless window covering one display, drawn through a CAMetalLayer.
@MainActor
public final class OutputWindow {
    public let window: NSWindow
    public let metalLayer: CAMetalLayer

    public init(screen: NSScreen, device: MTLDevice) {
        let frame = screen.frame
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = MetalContext.outputFormat
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = true
        metalLayer.contentsScale = screen.backingScaleFactor
        metalLayer.drawableSize = CGSize(width: frame.width * screen.backingScaleFactor, height: frame.height * screen.backingScaleFactor)
        metalLayer.frame = view.bounds
        view.layer = metalLayer  // layer-hosting view: set the layer before wantsLayer
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    public func close() { window.orderOut(nil) }
}
