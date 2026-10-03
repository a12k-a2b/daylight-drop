import SwiftUI
import AppKit
import QuickLookUI
import DaylightDropTransport

/// "From Daylight" Inbound Shelf displaying received screenshots, reading notes, PDFs, and text cards.
/// Wrapped in DraggableCardContainer for instant drag-out retention.
public struct InboundShelfView: View {
    @ObservedObject var stagingManager: StagingManager
    @State private var hoveredCardId: UUID? = nil
    
    public init(stagingManager: StagingManager = .shared) {
        self.stagingManager = stagingManager
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FROM DAYLIGHT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SolOSTokens.os400)
                    .tracking(0.8)
                Spacer()
                Text("\(stagingManager.inboundItems.count) items")
                    .font(.system(size: 10))
                    .foregroundColor(SolOSTokens.os300)
            }
            .padding(.horizontal, 12)
            
            if stagingManager.inboundItems.isEmpty {
                emptyPlaceholderView
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(stagingManager.inboundItems) { item in
                            InboundCardView(item: item)
                                .frame(width: 108, height: 116)
                                .onDrag {
                                    DragCoordinator.shared.notifyDragBegan(url: item.fileURL)
                                    return NSItemProvider(object: item.fileURL as NSURL)
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
                .frame(height: 120)
            }
        }
    }
    
    private var emptyPlaceholderView: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "ipad.and.arrow.forward")
                    .font(.system(size: 20))
                    .foregroundColor(SolOSTokens.os300)
                Text("Screenshots and notes from DC1 will appear here")
                    .font(.system(size: 11))
                    .foregroundColor(SolOSTokens.os300)
            }
            .frame(height: 90)
            Spacer()
        }
        .background(
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                .fill(SolOSTokens.os50)
                .overlay(
                    RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                        .stroke(SolOSTokens.os100, lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
    }
}

public struct InboundCardView: View {
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
                } else if item.type == .note || item.type == .prompt {
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
                
                // Copy button and drag grip overlay on hover
                if isHovered || copiedFeedback {
                    VStack {
                        HStack {
                            Image(systemName: "hand.draw")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(SolOSTokens.os0)
                                .padding(4)
                                .background(SolOSTokens.os900.opacity(0.85))
                                .clipShape(Circle())
                                .padding(4)
                                .help("Drag out to Finder, Slack, or Obsidian")
                            Spacer()
                            Button(action: copyToClipboard) {
                                Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(SolOSTokens.os0)
                                    .padding(4)
                                    .background(SolOSTokens.os900.opacity(0.85))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(4)
                        }
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
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        ThumbnailProvider.shared.generateThumbnail(for: item.fileURL, targetSize: CGSize(width: 108, height: 68)) { img in
            self.thumbnail = img
        }
    }
    
    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        
        let originType = NSPasteboard.PasteboardType("com.daylight.drop.origin")
        let origin = item.origin ?? TransportManager.shared.activeUsbSerial ?? TransportManager.shared.activeWifiPeer?.deviceId ?? "daylight-dc1"
        
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
