import Foundation
import Cocoa
import QuickLookThumbnailing

/// Asynchronous high-performance thumbnail generator with memory caching using QuickLook.
public final class ThumbnailProvider: @unchecked Sendable {
    public static let shared = ThumbnailProvider()
    
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.daylight.drop.thumbnails", qos: .userInitiated)
    
    public init() {
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }
    
    public func cachedThumbnail(for url: URL, targetSize: CGSize) -> NSImage? {
        let key = cacheKey(for: url, size: targetSize)
        return cache.object(forKey: key as NSString)
    }
    
    public func generateThumbnail(
        for url: URL,
        targetSize: CGSize = CGSize(width: 96, height: 96),
        completion: @escaping @MainActor @Sendable (NSImage?) -> Void
    ) {
        let key = cacheKey(for: url, size: targetSize)
        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async {
                completion(cached)
            }
            return
        }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if file is directly loadable image
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "webp", "gif", "tiff"].contains(ext) {
                if let image = NSImage(contentsOf: url) {
                    let resized = self.resizeImage(image, targetSize: targetSize)
                    self.cache.setObject(resized, forKey: key as NSString, cost: self.cost(for: resized))
                    DispatchQueue.main.async {
                        completion(resized)
                    }
                    return
                }
            }
            
            // Use QLThumbnailGenerator
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: targetSize,
                scale: NSScreen.main?.backingScaleFactor ?? 2.0,
                representationTypes: .thumbnail
            )
            
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, error in
                if let rep = rep {
                    let img = rep.nsImage
                    self.cache.setObject(img, forKey: key as NSString, cost: self.cost(for: img))
                    DispatchQueue.main.async {
                        completion(img)
                    }
                } else {
                    // Fallback to system icon for file type
                    let fallback = self.fallbackIcon(for: url)
                    DispatchQueue.main.async {
                        completion(fallback)
                    }
                }
            }
        }
    }
    
    private func cost(for image: NSImage) -> Int {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        return max(width * height * 4, 1024)
    }
    
    private func cacheKey(for url: URL, size: CGSize) -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let modTime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileSize = (attrs[.size] as? Int64) ?? 0
        return "\(url.path)_\(modTime)_\(fileSize)_\(Int(size.width))x\(Int(size.height))"
    }
    
    private func resizeImage(_ image: NSImage, targetSize: CGSize) -> NSImage {
        let targetRect = NSRect(origin: .zero, size: targetSize)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(in: targetRect, from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        resized.unlockFocus()
        return resized
    }
    
    private func fallbackIcon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            if let img = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "PDF") {
                return img
            }
        } else if ["txt", "md"].contains(ext) {
            if let img = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Text") {
                return img
            }
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
