import SwiftUI
import AppKit
import DaylightDropTransport

/// Root SwiftUI View presented inside the FloatingTrayPanel.
/// Contains split horizontal shelves ("From Daylight" & "From Mac"),
/// the Quick AI Scratchpad, and handles F25 In-Tray Cmd+V Paste.
public struct FloatingTrayView: View {
    @ObservedObject var stagingManager: StagingManager
    @State private var scratchpadText: String = ""
    @State private var activeChannel: ChannelType? = nil
    @State private var isFullTrayDropTargeted: Bool = false
    
    public var onQuit: (() -> Void)?
    public var onOpenFolder: (() -> Void)?
    public var onToggleDropBar: (() -> Void)?
    
    public init(
        stagingManager: StagingManager = .shared,
        onQuit: (() -> Void)? = nil,
        onOpenFolder: (() -> Void)? = nil,
        onToggleDropBar: (() -> Void)? = nil
    ) {
        self.stagingManager = stagingManager
        self.onQuit = onQuit
        self.onOpenFolder = onOpenFolder
        self.onToggleDropBar = onToggleDropBar
    }
    
    public var body: some View {
        VStack(spacing: 10) {
            // Header Bar
            headerView
            
            // "From Daylight" Inbound Shelf
            InboundShelfView(stagingManager: stagingManager)
            
            Divider()
                .background(SolOSTokens.os100)
                .padding(.horizontal, 12)
            
            // "From Mac" Outbound Shelf
            OutboundShelfView(stagingManager: stagingManager)
            
            Divider()
                .background(SolOSTokens.os100)
                .padding(.horizontal, 12)
            
            // Quick AI Scratchpad
            ScratchpadView(text: $scratchpadText, stagingManager: stagingManager)
                .padding(.bottom, 6)
        }
        .padding(.vertical, 10)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge)
                .fill(SolOSTokens.os150)
                .overlay(
                    RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge)
                        .stroke(SolOSTokens.os100, lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .light)
        .onDrop(of: DropItemHandler.supportedDropTypes, isTargeted: $isFullTrayDropTargeted) { providers in
            DropItemHandler.handleDroppedProviders(providers, stagingManager: stagingManager, onComplete: nil)
        }
        .overlay {
            if isFullTrayDropTargeted {
                dropzoneFullOverlay
            }
        }
        .onKeyPress { keyPress in
            // F25: In-Tray Cmd + V Paste
            if keyPress.key == KeyEquivalent("v") && keyPress.modifiers.contains(.command) {
                // If text editor is focused with text selection, let standard paste handle it
                if isTextEditorFocused {
                    return .ignored
                }
                // Otherwise perform F25 shelf beam
                handlePasteFromClipboard()
                return .handled
            }
            return .ignored
        }
        .onAppear {
            updateChannel()
            TransportManager.shared.onChannelChanged = { channel in
                DispatchQueue.main.async {
                    self.activeChannel = channel
                }
            }
        }
    }
    
    private var dropzoneFullOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge)
                .fill(SolOSTokens.os0.opacity(0.96))
            
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge)
                .strokeBorder(SolOSTokens.os900, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .padding(6)
            
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(SolOSTokens.os900)
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(SolOSTokens.os0)
                }
                
                VStack(spacing: 4) {
                    Text("DROP ANYWHERE TO BEAM")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(SolOSTokens.os900)
                        .tracking(1.0)
                    
                    Text("Release files to stream directly to Daylight Computer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(SolOSTokens.os400)
                }
                
                HStack(spacing: 6) {
                    Text("Finder")
                    Text("•")
                    Text("Apple Photos")
                    Text("•")
                    Text("Desktop")
                    Text("•")
                    Text("Any file format")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SolOSTokens.os400)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(SolOSTokens.os150)
                .clipShape(Capsule())
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isFullTrayDropTargeted)
    }
    
    private var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SolOSTokens.os900)
                
                Text("DAYLIGHT DROP")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(SolOSTokens.os900)
                    .tracking(0.5)
            }
            
            Spacer()
            
            // Connection status pill
            statusPillView
            
            // Detach Floating Drop Bar (Dropzone style)
            if let onToggleDropBar = onToggleDropBar {
                Button(action: onToggleDropBar) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 12))
                        .foregroundColor(SolOSTokens.os400)
                }
                .buttonStyle(.plain)
                .help("Toggle Floating Drop Bar")
            }
            
            // Menu / Actions
            Menu {
                Button("Toggle Floating Drop Bar") {
                    onToggleDropBar?()
                }
                Divider()
                Button("Open Incoming Folder") {
                    if let onOpenFolder = onOpenFolder {
                        onOpenFolder()
                    } else {
                        NSWorkspace.shared.open(stagingManager.incomingDirectory)
                    }
                }
                Button("Open Outgoing Folder") {
                    NSWorkspace.shared.open(stagingManager.outgoingDirectory)
                }
                Divider()
                Button("Quit Daylight Drop") {
                    if let onQuit = onQuit {
                        onQuit()
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundColor(SolOSTokens.os400)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
    }
    
    private var statusPillView: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(activeChannel != nil ? SolOSTokens.os900 : SolOSTokens.os300)
                .frame(width: 6, height: 6)
            
            Text(statusTitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(activeChannel != nil ? SolOSTokens.os900 : SolOSTokens.os300)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(SolOSTokens.os0)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(SolOSTokens.os100, lineWidth: 1)
        )
    }
    
    private var statusTitle: String {
        switch activeChannel {
        case .usb:
            return "USB Connected"
        case .wifi:
            return "Wi-Fi (mDNS)"
        case .none:
            return "Offline"
        }
    }
    
    private func updateChannel() {
        self.activeChannel = TransportManager.shared.activeChannel
    }
    
    public var isTextEditorFocused: Bool {
        if let responder = NSApp.keyWindow?.firstResponder {
            if responder is NSTextView || responder is NSTextField {
                return true
            }
        }
        return false
    }
    
    // MARK: - F25: In-Tray Cmd + V Paste Handler
    
    public func handlePasteFromClipboard() {
        let pb = NSPasteboard.general
        let originType = NSPasteboard.PasteboardType("com.daylight.drop.origin")
        
        // Loop suppression check
        if let origin = pb.string(forType: originType), !origin.isEmpty && (origin == "daylight-dc1" || origin != TransportManager.shared.localDeviceId) {
            NSLog("[FloatingTrayView] Suppressing Cmd+V paste: clipboard content originated from peer (%@)", origin)
            return
        }
        
        // 1. Files from Finder (filter for local file URLs, web URLs stage as text)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURLs = urls.filter { $0.isFileURL }
            let nonFileURLs = urls.filter { !$0.isFileURL }
            
            if !fileURLs.isEmpty {
                for url in fileURLs {
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
                            NSLog("[FloatingTrayView] Cmd+V file beam error: %@", error.localizedDescription)
                            if let id = stagedId {
                                stagingManager.updateOutboundStatus(id: id, status: .failed)
                            }
                        }
                    }
                }
                return
            } else if !nonFileURLs.isEmpty {
                for url in nonFileURLs {
                    let text = url.absoluteString
                    let staged = stagingManager.stageOutboundPrompt(prompt: text)
                    stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                    Task {
                        do {
                            _ = try await TransportManager.shared.sendText(text: text, type: "clipboard")
                            stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                        } catch {
                            NSLog("[FloatingTrayView] Cmd+V web url beam error: %@", error.localizedDescription)
                            stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                        }
                    }
                }
                return
            }
        }
        
        // 2. Copied Image Data (HEIC, HEIF, JPEG, PNG, TIFF)
        var imageData: Data? = nil
        var imageExtension = "png"
        
        if let heic = pb.data(forType: NSPasteboard.PasteboardType("public.heic")) {
            imageData = heic
            imageExtension = "heic"
        } else if let heif = pb.data(forType: NSPasteboard.PasteboardType("public.heif")) {
            imageData = heif
            imageExtension = "heif"
        } else if let jpeg = pb.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            imageData = jpeg
            imageExtension = "jpg"
        } else if let png = pb.data(forType: .png) {
            imageData = png
            imageExtension = "png"
        } else if let tiff = pb.data(forType: .tiff) {
            if let rep = NSBitmapImageRep(data: tiff),
               let converted = rep.representation(using: .png, properties: [:]) {
                imageData = converted
                imageExtension = "png"
            } else {
                imageData = tiff
                imageExtension = "tiff"
            }
        }
        
        if let imgData = imageData {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let timestampStr = df.string(from: Date())
            let entropy = UUID().uuidString.prefix(6).lowercased()
            let filename = "pasted_\(timestampStr)_\(entropy).\(imageExtension)"
            let staged = stagingManager.stageOutboundData(data: imgData, filename: filename, type: .screenshot)
            stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
            
            Task {
                do {
                    _ = try await TransportManager.shared.sendFile(fileURL: staged.fileURL, type: "screenshot")
                    stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                } catch {
                    NSLog("[FloatingTrayView] Cmd+V image beam error: %@", error.localizedDescription)
                    stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                }
            }
            return
        }
        
        // 3. Copied String (including web URLs) -> Populate scratchpad for user review & editing
        if let string = pb.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DispatchQueue.main.async {
                self.scratchpadText = string
            }
        }
    }
}
