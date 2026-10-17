// LocalIconCache.swift
// OpenClip
//
// Decode-once cache for local-file icons, so popup re-renders don't hit synchronous disk I/O.
import Foundation
import AppKit

@MainActor
final class LocalIconCache {
    private final class Entry {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    static let shared = LocalIconCache()

    private let cache = NSCache<NSString, Entry>()

    private init() {
        // Soft cap; NSCache also evicts under memory pressure.
        cache.countLimit = 128
    }

    /// SVGs are templates so they tint to the foreground; raster images keep their colors.
    func image(for url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached.image
        }
        guard let image = NSImage(contentsOf: url) else {
            cache.setObject(Entry(nil), forKey: key)
            return nil
        }
        let isSVG = url.pathExtension.lowercased() == "svg"
        image.isTemplate = isSVG
        cache.setObject(Entry(image), forKey: key)
        return image
    }

    func invalidate(for url: URL) {
        let key = url.path as NSString
        cache.removeObject(forKey: key)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
