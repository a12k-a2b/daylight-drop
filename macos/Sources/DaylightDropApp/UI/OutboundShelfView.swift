import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DaylightDropTransport

/// Helper for handling cross-app drag & drop (Finder file URLs, Apple Photos file promises, raw HEIC/JPEG data).
public struct DropItemHandler {
    public static let supportedDropTypes: [UTType] = [
        .fileURL,
        .image,
        .heic,
        .heif,
        .jpeg,
        .png,
        .tiff,
        .pdf,
        .text,
        .plainText,
        .data,
        .item
    ]
    
    public typealias DropCompletion = @MainActor @Sendable ([URL]) -> Void
    
    public static func handleDroppedProviders(
        _ providers: [NSItemProvider],
        stagingManager: StagingManager = .shared,
        onComplete: DropCompletion? = nil
    ) -> Bool {
        guard !providers.isEmpty else { return false }
        
        for provider in providers {
            // 1. File Promise (Photos.app, Safari downloads, Mail attachments)
            if provider.hasItemConformingToTypeIdentifier("com.apple.pasteboard.promised-file-url") {
                provider.loadItem(forTypeIdentifier: "com.apple.pasteboard.promised-file-url", options: nil) { item, error in
                    if let receiver = item as? NSFilePromiseReceiver {
                        let outgoingDir = stagingManager.outgoingDirectory
                        receiver.receivePromisedFiles(atDestination: outgoingDir, options: [:], operationQueue: .main) { fileURL, error in
                            if error == nil {
                                Task { @MainActor in
                                    stageAndBeam(urls: [fileURL], stagingManager: stagingManager, onComplete: onComplete)
                                }
                            }
                        }
                    }
                }
                continue
            }
            
            // 2. Standard File URL (Finder, Desktop, etc.)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    var targetURL: URL? = nil
                    if let url = item as? URL {
                        targetURL = url
                    } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        targetURL = url
                    } else if let str = item as? String, let url = URL(string: str) {
                        targetURL = url
                    }
                    
                    if let url = targetURL, url.isFileURL {
                        Task { @MainActor in
                            stageAndBeam(urls: [url], stagingManager: stagingManager, onComplete: onComplete)
                        }
                    }
                }
                continue
            }
            
            // 3. Raw Image Data (HEIC, JPEG, PNG, TIFF, WebP, etc.)
            let candidateImageUTTypes = [
                UTType.heic,
                UTType.heif,
                UTType.jpeg,
                UTType.png,
                UTType.tiff,
                UTType.gif,
                UTType.webP,
                UTType.image
            ]
            var matchedImage = false
            for imgType in candidateImageUTTypes {
                if provider.hasItemConformingToTypeIdentifier(imgType.identifier) {
                    matchedImage = true
                    provider.loadDataRepresentation(forTypeIdentifier: imgType.identifier) { data, error in
                        guard let data = data else { return }
                        let ext = imgType.preferredFilenameExtension ?? "png"
                        let df = DateFormatter()
                        df.dateFormat = "yyyyMMdd_HHmmss"
                        let filename = "dropped_\(df.string(from: Date()))_\(UUID().uuidString.prefix(6)).\(ext)"
                        let staged = stagingManager.stageOutboundData(data: data, filename: filename, type: .screenshot)
                        Task { @MainActor in
                            stageAndBeam(urls: [staged.fileURL], stagingManager: stagingManager, onComplete: onComplete)
                        }
                    }
                    break
                }
            }
            if matchedImage { continue }
            
            // 4. Fallback URL object
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let url = url, url.isFileURL {
                        Task { @MainActor in
                            stageAndBeam(urls: [url], stagingManager: stagingManager, onComplete: onComplete)
                        }
                    }
                }
                continue
            }
            
            // 5. Text / String dropped
            if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { str, error in
                    guard let text = str, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    DispatchQueue.main.async {
                        let staged = stagingManager.stageOutboundPrompt(prompt: text)
                        stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                        Task {
                            do {
                                _ = try await TransportManager.shared.sendText(text: text, type: "clipboard")
                                stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                            } catch {
                                stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                            }
                        }
                    }
                }
            }
        }
        
        return true
    }
    
    @MainActor
    private static func stageAndBeam(
        urls: [URL],
        stagingManager: StagingManager,
        onComplete: DropCompletion?
    ) {
        if let onComplete = onComplete {
            onComplete(urls)
        } else {
            for url in urls {
                Task {
                    var stagedId: UUID? = nil
                    do {
                        let staged = try stagingManager.stageOutboundFile(url: url)
                        stagedId = staged.id
                        stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                        let inferType = stagingManager.inferType(url: url).rawValue
                        _ = try await TransportManager.shared.sendFile(fileURL: staged.fileURL, type: inferType)
                        stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                    } catch {
                        NSLog("[DropItemHandler] Error sending file: %@", error.localizedDescription)
                        if let id = stagedId {
                            stagingManager.updateOutboundStatus(id: id, status: .failed)
                        }
                    }
                }
            }
        }
    }
}

/// "From Mac" Outbound Shelf displaying persistent drop zone and history of outbound files beamed to Daylight.
public struct OutboundShelfView: View {
    @ObservedObject var stagingManager: StagingManager
    public var onFileDropped: DropItemHandler.DropCompletion?
    
    public init(stagingManager: StagingManager = .shared, onFileDropped: DropItemHandler.DropCompletion? = nil) {
        self.stagingManager = stagingManager
        self.onFileDropped = onFileDropped
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FROM MAC")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SolOSTokens.os400)
                    .tracking(0.8)
                Spacer()
                Text("\(stagingManager.outboundItems.count) beamed")
                    .font(.system(size: 10))
                    .foregroundColor(SolOSTokens.os300)
            }
            .padding(.horizontal, 12)
            
            Group {
                if stagingManager.outboundItems.isEmpty {
                    FullWidthDropZoneBanner(onDrop: handleDrop)
                        .frame(height: 114)
                } else {
                    HStack(spacing: 8) {
                        // Fixed Persistent Drop Zone Card (never scrolls away)
                        PersistentDropZoneCard(onDrop: handleDrop)
                            .frame(width: 110, height: 114)
                        
                        // Outbound items horizontal scroll
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(stagingManager.outboundItems) { item in
                                    OutboundCardView(item: item)
                                        .frame(width: 108, height: 114)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                    .fill(SolOSTokens.os150)
                    .overlay(
                        RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                            .strokeBorder(SolOSTokens.os300, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
            )
            .padding(.horizontal, 12)
            .onDrop(of: DropItemHandler.supportedDropTypes, isTargeted: nil) { providers in
                DropItemHandler.handleDroppedProviders(providers, stagingManager: stagingManager, onComplete: handleDrop)
            }
            .frame(height: 132)
        }
    }
    
    private func handleDrop(urls: [URL]) {
        if let onFileDropped = onFileDropped {
            onFileDropped(urls)
        } else {
            for url in urls {
                Task {
                    var stagedId: UUID? = nil
                    do {
                        let staged = try stagingManager.stageOutboundFile(url: url)
                        stagedId = staged.id
                        stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                        let inferType = stagingManager.inferType(url: url).rawValue
                        _ = try await TransportManager.shared.sendFile(fileURL: staged.fileURL, type: inferType)
                        stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                    } catch {
                        NSLog("[OutboundShelfView] Error sending file: %@", error.localizedDescription)
                        if let id = stagedId {
                            stagingManager.updateOutboundStatus(id: id, status: .failed)
                        }
                    }
                }
            }
        }
    }
}

/// Full-width drop zone banner shown in the outbound shelf when no items are beamed yet.
public struct FullWidthDropZoneBanner: View {
    @State private var isTargeted: Bool = false
    public let onDrop: DropItemHandler.DropCompletion?
    
    public init(onDrop: DropItemHandler.DropCompletion? = nil) {
        self.onDrop = onDrop
    }
    
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                .fill(isTargeted ? SolOSTokens.os50 : SolOSTokens.os0)
            
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                .strokeBorder(
                    isTargeted ? SolOSTokens.os900 : SolOSTokens.os300,
                    style: StrokeStyle(lineWidth: isTargeted ? 2.0 : 1.2, dash: [5, 4])
                )
            
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isTargeted ? SolOSTokens.os900 : SolOSTokens.os150)
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(isTargeted ? SolOSTokens.os0 : SolOSTokens.os900)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text("DROP FILES HERE TO BEAM")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(SolOSTokens.os900)
                        .tracking(0.6)
                    
                    Text("Drag from Finder, Photos, or Desktop • Or press ⌘V")
                        .font(.system(size: 9.5))
                        .foregroundColor(SolOSTokens.os400)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SolOSTokens.os300)
            }
            .padding(.horizontal, 14)
        }
        .onDrop(of: DropItemHandler.supportedDropTypes, isTargeted: $isTargeted) { providers in
            DropItemHandler.handleDroppedProviders(providers, stagingManager: .shared, onComplete: onDrop)
        }
    }
}

/// Persistent dashed drop target card anchored in the outbound shelf.
public struct PersistentDropZoneCard: View {
    @State private var isTargeted: Bool = false
    public let onDrop: DropItemHandler.DropCompletion?
    
    public init(onDrop: DropItemHandler.DropCompletion? = nil) {
        self.onDrop = onDrop
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus.circle.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(isTargeted ? SolOSTokens.os900 : SolOSTokens.os400)
            
            VStack(spacing: 1) {
                Text("Drop to Beam")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isTargeted ? SolOSTokens.os900 : SolOSTokens.os900)
                
                Text("Finder / Photos")
                    .font(.system(size: 8))
                    .foregroundColor(SolOSTokens.os400)
            }
            .multilineTextAlignment(.center)
        }
        .frame(width: 110, height: 114)
        .background(isTargeted ? SolOSTokens.os50 : SolOSTokens.os0)
        .clipShape(RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                .strokeBorder(
                    isTargeted ? SolOSTokens.os900 : SolOSTokens.os300,
                    style: StrokeStyle(lineWidth: isTargeted ? 2.0 : 1.2, dash: [4, 4])
                )
        )
        .onDrop(of: DropItemHandler.supportedDropTypes, isTargeted: $isTargeted) { providers in
            DropItemHandler.handleDroppedProviders(providers, stagingManager: .shared, onComplete: onDrop)
        }
    }
}

public struct OutboundCardView: View {
    let item: StagedItem
    @State private var thumbnail: NSImage? = nil
    @State private var isHovered: Bool = false
    @State private var copiedFeedback: Bool = false
    
    public init(item: StagedItem) {
        self.item = item
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Preview area
            ZStack {
                SolOSTokens.os50
                
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 108, height: 68)
                        .clipped()
                } else if item.type == .screenshot {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(SolOSTokens.os400)
                } else if item.type == .pdf {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 24))
                        .foregroundColor(SolOSTokens.os400)
                } else if item.type == .prompt || item.type == .note || item.type == .text {
                    Text(item.previewText ?? item.filename)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(SolOSTokens.os900)
                        .lineLimit(3)
                        .padding(4)
                        .background(SolOSTokens.os150)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 24))
                        .foregroundColor(SolOSTokens.os400)
                }
                
                // Status badge
                VStack {
                    HStack {
                        if item.status == .failed {
                            Button(action: { retryBeam() }) {
                                HStack(spacing: 2) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 8))
                                    Text("Retry")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .foregroundColor(SolOSTokens.os0)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(SolOSTokens.os800)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        } else {
                            statusBadge(status: item.status)
                                .padding(4)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                // Action buttons overlay on hover
                if isHovered || copiedFeedback {
                    VStack {
                        HStack(spacing: 3) {
                            Button(action: { NSWorkspace.shared.open(item.fileURL) }) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(SolOSTokens.os0)
                                    .padding(4)
                                    .background(SolOSTokens.os900.opacity(0.85))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Open in default app")
                            
                            Spacer()
                            
                            Button(action: shareItem) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(SolOSTokens.os0)
                                    .padding(4)
                                    .background(SolOSTokens.os900.opacity(0.85))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Share...")
                            
                            Button(action: copyToClipboard) {
                                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(SolOSTokens.os0)
                                    .padding(4)
                                    .background(SolOSTokens.os900.opacity(0.85))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }
                        .padding(4)
                        Spacer()
                    }
                }
            }
            .frame(width: 108, height: 68)
            .clipped()
            
            Divider()
                .background(SolOSTokens.os100)
            
            // Metadata label area
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(SolOSTokens.os900)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                HStack {
                    Text(formattedTime(date: item.timestamp))
                        .font(.system(size: 9))
                        .foregroundColor(SolOSTokens.os400)
                    Spacer()
                    Text(formattedSize(bytes: item.fileSize))
                        .font(.system(size: 9))
                        .foregroundColor(SolOSTokens.os300)
                }
            }
            .padding(5)
            .frame(width: 108, height: 44)
            .background(SolOSTokens.os0)
        }
        .frame(width: 108, height: 114)
        .clipShape(RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                .stroke(isHovered ? SolOSTokens.os900 : SolOSTokens.os100, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(item.fileURL)
        }
        .contextMenu {
            Button("Open in Default App") {
                NSWorkspace.shared.open(item.fileURL)
            }
            Button("Copy to Clipboard") {
                copyToClipboard()
            }
            Button("Share...") {
                shareItem()
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func shareItem() {
        let picker = NSSharingServicePicker(items: [item.fileURL])
        if let window = NSApp.keyWindow, let contentView = window.contentView {
            picker.show(relativeTo: NSRect(x: 0, y: 0, width: 100, height: 100), of: contentView, preferredEdge: .minY)
        }
    }
    
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        
        let originType = NSPasteboard.PasteboardType("com.daylight.drop.origin")
        let origin = item.origin ?? "mac_desktop"
        
        let itemProvider = NSPasteboardItem()
        itemProvider.setString(origin, forType: originType)
        
        if item.type == .screenshot || item.type == .pdf || item.type == .file {
            itemProvider.setString(item.fileURL.absoluteString, forType: .fileURL)
            pb.writeObjects([itemProvider, item.fileURL as NSURL])
        } else if let preview = item.previewText {
            itemProvider.setString(preview, forType: .string)
            pb.writeObjects([itemProvider])
        } else if let content = try? String(contentsOf: item.fileURL) {
            itemProvider.setString(content, forType: .string)
            pb.writeObjects([itemProvider])
        }
        
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copiedFeedback = false
        }
    }
    
    private func loadThumbnail() {
        ThumbnailProvider.shared.generateThumbnail(for: item.fileURL, targetSize: CGSize(width: 108, height: 68)) { img in
            self.thumbnail = img
        }
    }
    
    private func retryBeam() {
        StagingManager.shared.updateOutboundStatus(id: item.id, status: .beaming)
        Task {
            do {
                if item.type == .prompt || item.type == .text {
                    let text = (try? String(contentsOf: item.fileURL, encoding: .utf8)) ?? item.previewText ?? ""
                    _ = try await TransportManager.shared.sendText(text: text, type: item.type.rawValue)
                } else {
                    _ = try await TransportManager.shared.sendFile(fileURL: item.fileURL, type: item.type.rawValue)
                }
                StagingManager.shared.updateOutboundStatus(id: item.id, status: .beamed)
            } catch {
                NSLog("[OutboundCardView] Retry failed: %@", error.localizedDescription)
                StagingManager.shared.updateOutboundStatus(id: item.id, status: .failed)
            }
        }
    }
    
    private func statusBadge(status: StagedItemStatus) -> some View {
        let (title, bg): (String, Color) = {
            switch status {
            case .queued:
                return ("Queued", SolOSTokens.os300)
            case .beaming:
                return ("Beaming...", SolOSTokens.brandAmber)
            case .beamed:
                return ("Beamed", SolOSTokens.os900)
            case .received:
                return ("Received", SolOSTokens.os900)
            case .failed:
                return ("Failed", SolOSTokens.os800)
            }
        }()
        
        return Text(title)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(SolOSTokens.os0)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(bg.opacity(0.85))
            .clipShape(Capsule())
    }
    
    private func formattedTime(date: Date) -> String {
        let df = DateFormatter()
        df.timeStyle = .short
        return df.string(from: date)
    }
    
    private func formattedSize(bytes: Int64) -> String {
        if bytes <= 0 { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
    }
}
