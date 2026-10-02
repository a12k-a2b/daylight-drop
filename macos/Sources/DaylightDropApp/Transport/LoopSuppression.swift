import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

/// 3-Tier Loop Suppression Engine to prevent infinite ping-pong echo loops
/// between macOS and Daylight DC1 Android devices.
public final class LoopSuppressionEngine: @unchecked Sendable {
    public let localDeviceId: String
    private let capacity: Int
    private let ttl: TimeInterval
    private let lock = NSLock()
    
    // In-memory cache mapping content SHA-256 hex string to timestamp recorded
    private var cache: [String: Date] = [:]
    private var keysInOrder: [String] = []
    
    public init(
        localDeviceId: String,
        capacity: Int = ProtocolConstants.defaultLruCapacity,
        ttl: TimeInterval = ProtocolConstants.defaultTtlSeconds
    ) {
        self.localDeviceId = localDeviceId
        self.capacity = capacity
        self.ttl = ttl
    }
    
    // MARK: - Tier 1: Protocol Origin Checking
    
    /// Returns true if the incoming origin matches this local device ID.
    public func isOriginSelf(_ origin: String) -> Bool {
        return origin == localDeviceId
    }
    
    // MARK: - Tier 2: Pasteboard Metadata Tagging
    
    #if canImport(AppKit)
    public func tagPasteboard(pasteboard: NSPasteboard = .general, origin: String? = nil, transferId: String? = nil) {
        let tagOrigin = origin ?? localDeviceId
        let tagTransferId = transferId ?? UUID().uuidString
        let originType = NSPasteboard.PasteboardType(ProtocolConstants.originPasteboardType)
        let transferIdType = NSPasteboard.PasteboardType(ProtocolConstants.transferIdPasteboardType)
        
        pasteboard.setString(tagOrigin, forType: originType)
        pasteboard.setString(tagTransferId, forType: transferIdType)
    }
    
    public func getPasteboardOrigin(pasteboard: NSPasteboard = .general) -> String? {
        let originType = NSPasteboard.PasteboardType(ProtocolConstants.originPasteboardType)
        return pasteboard.string(forType: originType)
    }
    
    public func isPasteboardFromSelf(pasteboard: NSPasteboard = .general) -> Bool {
        guard let origin = getPasteboardOrigin(pasteboard: pasteboard) else { return false }
        return isOriginSelf(origin)
    }
    #endif
    
    // MARK: - Tier 3: In-Memory SHA-256 LRU Deduplication
    
    /// Computes the 64-character lowercase hexadecimal SHA-256 of raw data.
    public static func computeSha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Computes the 64-character lowercase hexadecimal SHA-256 of text.
    public static func computeSha256(text: String) -> String {
        guard let data = text.data(using: .utf8) else { return "" }
        return computeSha256(data: data)
    }
    
    /// Records a content hash into the LRU cache.
    public func record(hash: String, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        
        // Remove existing key to refresh order
        if cache[hash] != nil {
            keysInOrder.removeAll { $0 == hash }
        } else if keysInOrder.count >= capacity {
            // Evict oldest
            if !keysInOrder.isEmpty {
                let oldest = keysInOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
        }
        
        cache[hash] = date
        keysInOrder.append(hash)
        
        // Prune expired entries
        pruneExpired(currentTime: date)
    }
    
    /// Records content text by computing its SHA-256.
    public func record(text: String, at date: Date = Date()) {
        let hash = Self.computeSha256(text: text)
        record(hash: hash, at: date)
    }
    
    /// Returns true if the hash was recorded within TTL seconds.
    public func shouldSuppress(hash: String, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let timestamp = cache[hash] else {
            return false
        }
        
        if date.timeIntervalSince(timestamp) > ttl {
            // Expired entry
            cache.removeValue(forKey: hash)
            keysInOrder.removeAll { $0 == hash }
            return false
        }
        
        return true
    }
    
    /// Returns true if the text content was recorded within TTL seconds.
    public func shouldSuppress(text: String, at date: Date = Date()) -> Bool {
        let hash = Self.computeSha256(text: text)
        return shouldSuppress(hash: hash, at: date)
    }
    
    /// Evaluates all 3 tiers: if origin is self or hash is suppressed, returns true.
    public func shouldSuppressIncoming(origin: String, hash: String, at date: Date = Date()) -> Bool {
        if isOriginSelf(origin) {
            return true
        }
        return shouldSuppress(hash: hash, at: date)
    }
    
    public func currentCacheCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        keysInOrder.removeAll()
    }
    
    private func pruneExpired(currentTime: Date) {
        var expiredKeys: [String] = []
        for (key, timestamp) in cache {
            if currentTime.timeIntervalSince(timestamp) > ttl {
                expiredKeys.append(key)
            }
        }
        for key in expiredKeys {
            cache.removeValue(forKey: key)
            keysInOrder.removeAll { $0 == key }
        }
    }
}
