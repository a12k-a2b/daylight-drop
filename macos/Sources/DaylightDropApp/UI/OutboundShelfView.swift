import SwiftUI
import AppKit
import DaylightDropTransport

/// "From Mac" Outbound Shelf displaying persistent drop zone and history of outbound files beamed to Daylight.
public struct OutboundShelfView: View {
    @ObservedObject var stagingManager: StagingManager
    public var onFileDropped: (([URL]) -> Void)?
    
    public init(stagingManager: StagingManager = .shared, onFileDropped: (([URL]) -> Void)? = nil) {
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
            
            HStack(spacing: 8) {
                // Fixed Persistent Drop Zone Card (never scrolls away)
                PersistentDropZoneCard(onDrop: handleDrop)
                    .frame(width: 96, height: 116)
                
                // Outbound items horizontal scroll
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(stagingManager.outboundItems) { item in
                            OutboundCardView(item: item)
                                .frame(width: 108, height: 116)
                        }
                    }
                    .padding(.vertical, 2)
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
            .dropDestination(for: URL.self) { items, location in
                guard !items.isEmpty else { return false }
                handleDrop(urls: items)
                return true
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
                        _ = try await TransportManager.shared.sendFile(fileURL: staged.fileURL)
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

/// Persistent dashed drop target card anchored in the outbound shelf.
public struct PersistentDropZoneCard: View {
    @State private var isTargeted: Bool = false
    public let onDrop: ([URL]) -> Void
    
    public init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(isTargeted ? SolOSTokens.os900 : SolOSTokens.os400)
            
            Text("Drop Files\nto Beam")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isTargeted ? SolOSTokens.os900 : SolOSTokens.os400)
                .multilineTextAlignment(.center)
        }
        .frame(width: 92, height: 114)
        .background(isTargeted ? SolOSTokens.os50 : SolOSTokens.os0)
        .clipShape(RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                .strokeBorder(
                    isTargeted ? SolOSTokens.os900 : SolOSTokens.os300,
                    style: StrokeStyle(lineWidth: isTargeted ? 2.0 : 1.2, dash: [4, 4])
                )
        )
        .dropDestination(for: URL.self) { items, location in
            guard !items.isEmpty else { return false }
            onDrop(items)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

public struct OutboundCardView: View {
    let item: StagedItem
    @State private var thumbnail: NSImage? = nil
    
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
                } else if item.type == .prompt {
                    Text(item.previewText ?? item.filename)
                        .font(.system(size: 9))
                        .foregroundColor(SolOSTokens.os400)
                        .lineLimit(3)
                        .padding(4)
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
                .stroke(SolOSTokens.os100, lineWidth: 1)
        )
        .onAppear {
            loadThumbnail()
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
