#!/usr/bin/env swift
// Renders an HTML or SVG file to a PNG of exact pixel dimensions using WebKit.
// Usage: render_html_png.swift <input> <output.png> <width> <height> [scale]

import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: render_html_png.swift <input> <output.png> <width> <height> [scale]\n".data(using: .utf8)!)
    exit(2)
}

let inputURL = URL(fileURLWithPath: args[1]).standardizedFileURL
let outputURL = URL(fileURLWithPath: args[2]).standardizedFileURL
guard let width = Double(args[3]), let height = Double(args[4]) else { exit(2) }
let scale = args.count > 5 ? (Double(args[5]) ?? 1) : 1

let pixelWidth = Int((width * scale).rounded())
let pixelHeight = Int((height * scale).rounded())

final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var finished = false
    var failure: String?

    override init() {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Double(pixelWidth), height: Double(pixelHeight)), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.pageZoom = CGFloat(scale)
    }

    func load() {
        webView.loadFileURL(inputURL, allowingReadAccessTo: inputURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.snapshot() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        finished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failure = error.localizedDescription
        finished = true
    }

    private func snapshot() {
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        webView.takeSnapshot(with: config) { image, error in
            defer { self.finished = true }
            guard let image else {
                self.failure = error?.localizedDescription ?? "snapshot returned no image"
                return
            }
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                self.failure = "could not allocate bitmap"
                return
            }
            rep.size = NSSize(width: pixelWidth, height: pixelHeight)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                       from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let data = rep.representation(using: .png, properties: [:]) else {
                self.failure = "PNG encoding failed"
                return
            }
            do { try data.write(to: outputURL) } catch { self.failure = error.localizedDescription }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let renderer = Renderer()
renderer.load()

let deadline = Date().addingTimeInterval(60)
while !renderer.finished && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

if let failure = renderer.failure {
    FileHandle.standardError.write("error: \(failure)\n".data(using: .utf8)!)
    exit(1)
}
if !renderer.finished {
    FileHandle.standardError.write("error: timed out rendering \(inputURL.path)\n".data(using: .utf8)!)
    exit(1)
}
