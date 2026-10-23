// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Tim de Bruijn
// Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md

// Standalone reproduction: CAMetalDisplayLink stops after three presented frames on macOS 27.0.1.
// Build: swiftc -O -o linktest cametaldisplaylink-repro.swift ; run: ./linktest link  (vs ./linktest timer)
import AppKit
import Metal
import QuartzCore

final class Delegate: NSObject, CAMetalDisplayLinkDelegate {
    var count = 0, completed = 0, presented = 0
    let queue: MTLCommandQueue
    init(queue: MTLCommandQueue) { self.queue = queue }
    func render(_ drawable: CAMetalDrawable) {
        guard let cb = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.2, green: 0, blue: 0.3, alpha: 1)
        cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        drawable.addPresentedHandler { [self] _ in presented += 1 }
        cb.present(drawable)
        cb.addCompletedHandler { [self] _ in completed += 1 }
        cb.commit()
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        count += 1
        render(update.drawable)
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "link"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let screen = NSScreen.main!
let frame = NSRect(x: 100, y: 100, width: 400, height: 300)
let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
window.isOpaque = true; window.backgroundColor = .black; window.hasShadow = false
let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
if !mode.contains("nosize") {
    layer.contentsScale = screen.backingScaleFactor
    layer.drawableSize = CGSize(width: 800, height: 600)
}
layer.frame = view.bounds
if mode.contains("count2") { layer.maximumDrawableCount = 2 }
view.layer = layer
view.wantsLayer = true
window.contentView = view
window.orderFrontRegardless()
let delegate = Delegate(queue: queue)
var link: CAMetalDisplayLink?
if mode.hasPrefix("link") {
    let l = CAMetalDisplayLink(metalLayer: layer)
    if mode.contains("lat2") { l.preferredFrameLatency = 2 }
    if mode.contains("nodelegatefirst") { l.add(to: RunLoop.main, forMode: .common); l.delegate = delegate } else { l.delegate = delegate; l.add(to: RunLoop.main, forMode: .common) }
    if mode.contains("after") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { l.isPaused = true; l.isPaused = false } }
    link = l
} else {
    // classic path: our own timer + nextDrawable()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
        delegate.count += 1
        if let drawable = layer.nextDrawable() { delegate.render(drawable) } else { print("nextDrawable timed out") }
    }
    RunLoop.main.add(timer, forMode: .common)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
    print("mode \(mode): \(delegate.count) updates, \(delegate.completed) completed, \(delegate.presented) presented in 2.5 s")
    exit(0)
}
app.run()
