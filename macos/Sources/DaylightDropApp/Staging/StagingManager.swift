import Foundation
import Cocoa
import CryptoKit
import DaylightDropTransport

public enum StagedItemType: String, Codable, Sendable {
    case screenshot = "screenshot"
    case note = "note"
    case pdf = "pdf"
    case text = "text"
    case prompt = "prompt"
    case clipboard = "clipboard"
    case file = "file"
}

public enum StagedItemDirection: String, Codable, Sendable {
    case inbound = "inbound"
    case outbound = "outbound"
}

public enum StagedItemStatus: String, Codable, Sendable {
    case queued = "queued"
    case beaming = "beaming"
    case beamed = "beamed"
    case received = "received"
    case failed = "failed"
}

public struct StagedItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let fileURL: URL
    public let type: StagedItemType
    public let timestamp: Date
    public let direction: StagedItemDirection
    public var status: StagedItemStatus
    public let fileSize: Int64
    public var previewText: String?
    public var sha256: String?
    public var origin: String?
    
    public init(
        id: UUID = UUID(),
        filename: String,
        fileURL: URL,
        type: StagedItemType,
        timestamp: Date = Date(),
        direction: StagedItemDirection,
        status: StagedItemStatus,
        fileSize: Int64 = 0,
        previewText: String? = nil,
        sha256: String? = nil,
        origin: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.fileURL = fileURL
        self.type = type
        self.timestamp = timestamp
        self.direction = direction
        self.status = status
        self.fileSize = fileSize
        self.previewText = previewText
        self.sha256 = sha256
        self.origin = origin
    }
}

/// Manages local persistent staging under ~/DaylightDrop/incoming and ~/DaylightDrop/outgoing.
public final class StagingManager: ObservableObject, @unchecked Sendable {
    public static let shared = StagingManager()
    
    public let rootDirectory: URL
    public let incomingDirectory: URL
    public let outgoingDirectory: URL
    
    @Published public private(set) var inboundItems: [StagedItem] = []
    @Published public private(set) var outboundItems: [StagedItem] = []
    
    private let lock = NSLock()
    private let dateFormatter: DateFormatter
    
    public init(customRootURL: URL? = nil) {
        let base = customRootURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DaylightDrop")
        self.rootDirectory = base
        self.incomingDirectory = base.appendingPathComponent("incoming", isDirectory: true)
        self.outgoingDirectory = base.appendingPathComponent("outgoing", isDirectory: true)
        
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        self.dateFormatter = df
        
        createDirectoriesIfNeeded()
        refreshFromDisk()
        cleanupOldItems()
    }
    
    public func createDirectoriesIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: incomingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try? fm.createDirectory(at: outgoingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }
    
    public func refreshFromDisk() {
        lock.lock()
        defer { lock.unlock() }
        
        let fm = FileManager.default
        var inbound: [StagedItem] = []
        if let inUrls = try? fm.contentsOfDirectory(at: incomingDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for url in inUrls {
                let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attrs[.size] as? Int64) ?? 0
                let date = (attrs[.modificationDate] as? Date) ?? Date()
                let type = Self.inferType(from: url)
                var preview: String? = nil
                if type == .text || type == .note || type == .prompt {
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        preview = String(text.prefix(200))
                    }
                }
                inbound.append(StagedItem(
                    filename: url.lastPathComponent,
                    fileURL: url,
                    type: type,
                    timestamp: date,
                    direction: .inbound,
                    status: .received,
                    fileSize: size,
                    previewText: preview
                ))
            }
        }
        
        var outbound: [StagedItem] = []
        if let outUrls = try? fm.contentsOfDirectory(at: outgoingDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            for url in outUrls {
                let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
                let size = (attrs[.size] as? Int64) ?? 0
                let date = (attrs[.modificationDate] as? Date) ?? Date()
                let type = Self.inferType(from: url)
                var preview: String? = nil
                if type == .text || type == .note || type == .prompt {
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        preview = String(text.prefix(200))
                    }
                }
                outbound.append(StagedItem(
                    filename: url.lastPathComponent,
                    fileURL: url,
                    type: type,
                    timestamp: date,
                    direction: .outbound,
                    status: .beamed,
                    fileSize: size,
                    previewText: preview
                ))
            }
        }
        
        inbound.sort { $0.timestamp > $1.timestamp }
        outbound.sort { $0.timestamp > $1.timestamp }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inboundItems = inbound
            self.outboundItems = outbound
        }
    }
    
    // MARK: - Staging Inbound
    
    @discardableResult
    public func stageInbound(
        filename: String,
        type: String,
        sourceURL: URL,
        sha256: String = "",
        origin: String? = nil
    ) throws -> StagedItem {
        let fm = FileManager.default
        createDirectoriesIfNeeded()
        
        let destinationURL = incomingDirectory.appendingPathComponent(filename)
        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: sourceURL, to: destinationURL)
        }
        
        let attrs = (try? fm.attributesOfItem(atPath: destinationURL.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let inferredType = Self.inferType(from: destinationURL, fallbackType: type)
        var preview: String? = nil
        if inferredType == .text || inferredType == .note || inferredType == .prompt {
            if let text = try? String(contentsOf: destinationURL, encoding: .utf8) {
                preview = String(text.prefix(200))
            }
        }
        
        let item = StagedItem(
            filename: filename,
            fileURL: destinationURL,
            type: inferredType,
            timestamp: Date(),
            direction: .inbound,
            status: .received,
            fileSize: size,
            previewText: preview,
            sha256: sha256,
            origin: origin
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inboundItems.insert(item, at: 0)
        }
        cleanupOldItems()
        return item
    }
    
    @discardableResult
    public func stageInboundText(text: String, origin: String, type: String = "note") -> StagedItem {
        createDirectoriesIfNeeded()
        let timestampStr = dateFormatter.string(from: Date())
        let entropy = UUID().uuidString.prefix(6).lowercased()
        let prefix = type == "prompt" ? "prompt" : "note"
        let filename = "\(prefix)_\(timestampStr)_\(entropy).txt"
        let fileURL = incomingDirectory.appendingPathComponent(filename)
        
        // Atomic write via unique .tmp
        let tmpURL = incomingDirectory.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
        try? text.write(to: tmpURL, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.replaceItem(at: fileURL, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try? FileManager.default.moveItem(at: tmpURL, to: fileURL)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        
        // Write to macOS general pasteboard with loop origin tag
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setString(origin, forType: NSPasteboard.PasteboardType("com.daylight.drop.origin"))
            pb.writeObjects([item])
        }
        
        let item = StagedItem(
            filename: filename,
            fileURL: fileURL,
            type: type == "prompt" ? .prompt : .note,
            timestamp: Date(),
            direction: .inbound,
            status: .received,
            fileSize: Int64(text.utf8.count),
            previewText: String(text.prefix(200)),
            origin: origin
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.inboundItems.insert(item, at: 0)
        }
        cleanupOldItems()
        return item
    }
    
    // MARK: - Staging Outbound
    
    @discardableResult
    public func stageOutboundFile(url: URL, type: String? = nil) throws -> StagedItem {
        createDirectoriesIfNeeded()
        let fm = FileManager.default
        let filename = url.lastPathComponent
        let destURL = outgoingDirectory.appendingPathComponent(filename)
        
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: url, to: destURL)
        
        let attrs = (try? fm.attributesOfItem(atPath: destURL.path)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let inferredType = Self.inferType(from: destURL, fallbackType: type)
        var preview: String? = nil
        if inferredType == .text || inferredType == .note || inferredType == .prompt {
            if let text = try? String(contentsOf: destURL, encoding: .utf8) {
                preview = String(text.prefix(200))
            }
        }
        
        let item = StagedItem(
            filename: filename,
            fileURL: destURL,
            type: inferredType,
            timestamp: Date(),
            direction: .outbound,
            status: .queued,
            fileSize: size,
            previewText: preview
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outboundItems.insert(item, at: 0)
        }
        cleanupOldItems()
        return item
    }
    
    @discardableResult
    public func stageOutboundPrompt(prompt: String) -> StagedItem {
        createDirectoriesIfNeeded()
        let timestampStr = dateFormatter.string(from: Date())
        let entropy = UUID().uuidString.prefix(6).lowercased()
        let filename = "prompt_\(timestampStr)_\(entropy).txt"
        let destURL = outgoingDirectory.appendingPathComponent(filename)
        
        // Atomic write via unique .tmp
        let tmpURL = outgoingDirectory.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
        try? prompt.write(to: tmpURL, atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.replaceItem(at: destURL, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try? FileManager.default.moveItem(at: tmpURL, to: destURL)
        }
        if !FileManager.default.fileExists(atPath: destURL.path) {
            try? prompt.write(to: destURL, atomically: true, encoding: .utf8)
        }
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        
        let item = StagedItem(
            filename: filename,
            fileURL: destURL,
            type: .prompt,
            timestamp: Date(),
            direction: .outbound,
            status: .queued,
            fileSize: Int64(prompt.utf8.count),
            previewText: String(prompt.prefix(200))
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outboundItems.insert(item, at: 0)
        }
        cleanupOldItems()
        return item
    }
    
    @discardableResult
    public func stageOutboundData(data: Data, filename: String, type: StagedItemType = .file) -> StagedItem {
        createDirectoriesIfNeeded()
        let destURL = outgoingDirectory.appendingPathComponent(filename)
        let tmpURL = outgoingDirectory.appendingPathComponent(".\(filename).\(UUID().uuidString).tmp")
        try? data.write(to: tmpURL)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.replaceItem(at: destURL, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try? FileManager.default.moveItem(at: tmpURL, to: destURL)
        }
        if !FileManager.default.fileExists(atPath: destURL.path) {
            try? data.write(to: destURL)
        }
        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        
        let item = StagedItem(
            filename: filename,
            fileURL: destURL,
            type: type,
            timestamp: Date(),
            direction: .outbound,
            status: .queued,
            fileSize: Int64(data.count)
        )
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outboundItems.insert(item, at: 0)
        }
        cleanupOldItems()
        return item
    }
    
    public func updateOutboundStatus(id: UUID, status: StagedItemStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.outboundItems.firstIndex(where: { $0.id == id }) {
                self.outboundItems[index].status = status
            }
        }
    }
    
    public func cleanupOldItems(maxCount: Int = 100) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupOldItems(maxCount: maxCount)
            }
            return
        }
        
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        
        if inboundItems.count > maxCount {
            let itemsToRemove = Array(inboundItems.suffix(from: maxCount))
            for item in itemsToRemove {
                try? fm.removeItem(at: item.fileURL)
            }
            self.inboundItems = Array(inboundItems.prefix(maxCount))
        }
        
        if outboundItems.count > maxCount {
            let itemsToRemove = Array(outboundItems.suffix(from: maxCount))
            for item in itemsToRemove {
                try? fm.removeItem(at: item.fileURL)
            }
            self.outboundItems = Array(outboundItems.prefix(maxCount))
        }
    }
    
    // MARK: - Type Inference Helper
    
    public func inferType(from url: URL, fallbackType: String? = nil) -> StagedItemType {
        Self.inferType(from: url, fallbackType: fallbackType)
    }
    
    public func inferType(url: URL) -> StagedItemType {
        Self.inferType(from: url)
    }
    
    public static func inferType(from url: URL, fallbackType: String? = nil) -> StagedItemType {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        
        if name.hasPrefix("screenshot") || ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "webp" || ext == "heic" || ext == "heif" {
            return .screenshot
        }
        if ext == "pdf" {
            return .pdf
        }
        if name.hasPrefix("prompt") {
            return .prompt
        }
        if name.hasPrefix("note") || ext == "txt" || ext == "md" {
            return .note
        }
        if let fallback = fallbackType {
            if fallback == "screenshot" { return .screenshot }
            if fallback == "image" { return .screenshot }
            if fallback == "document" || fallback == "pdf" { return .pdf }
            if fallback == "prompt" { return .prompt }
            if fallback == "clipboard" || fallback == "text" { return .text }
        }
        return .file
    }
}
