import Cocoa
import SwiftUI
import DaylightDropTransport

/// Coordinates the NSStatusItem lifecycle, button icon, drop destination, and tray panel toggle.
@MainActor
public final class StatusItemController: NSObject {
    public let statusItem: NSStatusItem
    public let panel: FloatingTrayPanel
    public let dropTargetView: StatusItemDropTargetView
    public let stagingManager: StagingManager
    public let transportManager: TransportManager
    
    public init(
        stagingManager: StagingManager = .shared,
        transportManager: TransportManager = .shared
    ) {
        self.stagingManager = stagingManager
        self.transportManager = transportManager
        
        // 1. Create NSStatusItem with autosaveName for persistent menu bar placement
        // Width 36.0 provides a generous touch target for drag-and-drop while remaining compact
        self.statusItem = NSStatusBar.system.statusItem(withLength: 36.0)
        self.statusItem.autosaveName = "DaylightDrop"
        
        // 2. Create FloatingTrayPanel
        self.panel = FloatingTrayPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 440))
        self.panel.statusItem = self.statusItem
        
        // 3. Setup Status Item Button
        guard let button = statusItem.button else {
            fatalError("Failed to obtain NSStatusBarButton")
        }
        
        // Use custom icon or SF Symbol template
        let icon = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Daylight Drop") ?? NSImage()
        icon.isTemplate = true
        button.image = icon
        button.imagePosition = .imageOnly
        button.toolTip = "Daylight Drop"
        
        // 4. Attach StatusItemDropTargetView for direct drops & F24 spring open
        let dropView = StatusItemDropTargetView(targetButton: button)
        button.addSubview(dropView)
        self.dropTargetView = dropView
        
        super.init()
        
        // 5. Host SwiftUI Tray View inside panel
        let trayView = FloatingTrayView(
            stagingManager: stagingManager,
            onQuit: { [weak self] in
                self?.panel.hide()
                FloatingDropBarPanel.shared.hide()
                NSApp.terminate(nil)
            },
            onOpenFolder: { [weak self] in
                if let dir = self?.stagingManager.incomingDirectory {
                    NSWorkspace.shared.open(dir)
                }
            },
            onToggleDropBar: {
                FloatingDropBarPanel.shared.toggle()
            }
        )
        let hostingView = NSHostingView(rootView: trayView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.panel.contentView = hostingView
        
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        guard let button = statusItem.button else { return }
        
        // Toggle action on button click
        dropTargetView.onToggle = { [weak self, weak button] in
            guard let self = self, let button = button else { return }
            self.panel.toggle(relativeTo: button)
        }
        
        // F24: Spring Open when hovering dragged item
        dropTargetView.onSpringOpen = { [weak self, weak button] in
            guard let self = self, let button = button else { return }
            if !self.panel.isVisible {
                self.panel.show(relativeTo: button)
            }
        }
        
        // Direct drop onto menu bar icon
        dropTargetView.onDrop = { [weak self] urls in
            guard let self = self else { return }
            for url in urls {
                Task {
                    var stagedId: UUID? = nil
                    do {
                        let staged = try self.stagingManager.stageOutboundFile(url: url)
                        stagedId = staged.id
                        self.stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                        let inferType = self.stagingManager.inferType(url: url).rawValue
                        _ = try await self.transportManager.sendFile(fileURL: staged.fileURL, type: inferType)
                        self.stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                    } catch {
                        NSLog("[StatusItemController] Drop beam error: %@", error.localizedDescription)
                        if let id = stagedId {
                            self.stagingManager.updateOutboundStatus(id: id, status: .failed)
                        }
                    }
                }
            }
        }
        
        // F25: Pasteboard Cmd+V handler on tray
        panel.onPasteCommand = { [weak self] in
            self?.handleTrayPaste()
        }
    }
    
    public func handleTrayPaste() {
        let pb = NSPasteboard.general
        
        // 1. Files from Finder (file URLs or NSFilenamesPboardType)
        var candidateURLs: [URL] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            candidateURLs.append(contentsOf: urls.filter { $0.isFileURL })
        }
        if candidateURLs.isEmpty, let filenames = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            candidateURLs.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        }
        
        if !candidateURLs.isEmpty {
            for url in candidateURLs {
                Task {
                    var stagedId: UUID? = nil
                    do {
                        let staged = try self.stagingManager.stageOutboundFile(url: url)
                        stagedId = staged.id
                        self.stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                        let inferType = self.stagingManager.inferType(url: url).rawValue
                        _ = try await self.transportManager.sendFile(fileURL: staged.fileURL, type: inferType)
                        self.stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                    } catch {
                        NSLog("[StatusItemController] Paste file beam error: %@", error.localizedDescription)
                        if let id = stagedId {
                            self.stagingManager.updateOutboundStatus(id: id, status: .failed)
                        }
                    }
                }
            }
            return
        }
        
        // 2. Images from clipboard (HEIC, HEIF, JPEG, PNG, TIFF)
        let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("public.heif"), "heif"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (NSPasteboard.PasteboardType("public.png"), "png"),
            (.tiff, "png")
        ]
        for (imgType, ext) in imageTypes {
            if let imgData = pb.data(forType: imgType) {
                let finalData: Data
                let finalExt: String
                if imgType == .tiff {
                    if let image = NSImage(data: imgData),
                       let tiff = image.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff),
                       let pngData = rep.representation(using: .png, properties: [:]) {
                        finalData = pngData
                        finalExt = "png"
                    } else {
                        finalData = imgData
                        finalExt = "tiff"
                    }
                } else {
                    finalData = imgData
                    finalExt = ext
                }
                
                let filename = "pasted_image_\(Int(Date().timeIntervalSince1970)).\(finalExt)"
                let staged = self.stagingManager.stageOutboundData(data: finalData, filename: filename, type: .screenshot)
                self.stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
                Task {
                    let stagedId: UUID? = staged.id
                    do {
                        _ = try await self.transportManager.sendFile(fileURL: staged.fileURL, type: "screenshot")
                        self.stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                    } catch {
                        NSLog("[StatusItemController] Paste image beam error: %@", error.localizedDescription)
                        if let id = stagedId {
                            self.stagingManager.updateOutboundStatus(id: id, status: .failed)
                        }
                    }
                }
                return
            }
        }
        
        // 3. Text / Rich text / Prompt string
        if let string = pb.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let staged = self.stagingManager.stageOutboundPrompt(prompt: string)
            self.stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
            Task {
                do {
                    _ = try await self.transportManager.sendText(text: string, type: "prompt")
                    self.stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                } catch {
                    self.stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                }
            }
        }
    }
    
    public func toggleTray() {
        guard let button = statusItem.button else { return }
        panel.toggle(relativeTo: button)
    }
    
    public func showTray() {
        guard let button = statusItem.button else { return }
        panel.show(relativeTo: button)
    }
    
    public func hideTray() {
        panel.hide()
    }
}

/// Application delegate configuring accessory mode (LSUIElement = true), hotkeys, and transport engine.
@MainActor
public final class DaylightDropAppDelegate: NSObject, NSApplicationDelegate {
    public static let shared = DaylightDropAppDelegate()
    
    public var statusItemController: StatusItemController?
    public let stagingManager = StagingManager.shared
    public let transportManager = TransportManager.shared
    public let hotKeyManager = CarbonHotKeyManager.shared
    
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // F9: Standalone accessory application (no Dock icon, LSUIElement = true)
        NSApp.setActivationPolicy(.accessory)
        
        // Setup standard Edit menu so Cmd+C/Cmd+V/Cmd+A work in accessory app
        setupStandardEditMenu()
        
        // 1. Initialize StatusItemController & FloatingTrayPanel
        self.statusItemController = StatusItemController(
            stagingManager: stagingManager,
            transportManager: transportManager
        )
        
        // 2. Setup Transport Callbacks
        setupTransportCallbacks()
        
        // 3. Register Carbon Global Hotkeys (F7: Cmd+Shift+D & Cmd+Shift+V)
        setupCarbonHotkeys()
        
        // 4. Start Transport Engine (HTTP Server, Advertiser, Browser, ADB Tracker)
        do {
            try transportManager.start()
            NSLog("[DaylightDropApp] Transport engine started successfully.")
        } catch {
            NSLog("[DaylightDropApp] Error starting transport engine: %@", error.localizedDescription)
        }
    }
    
    private func setupTransportCallbacks() {
        transportManager.onFileReceived = { [weak self] transferId, filename, type, fileURL, sha256 in
            guard let self = self else { return }
            do {
                _ = try self.stagingManager.stageInbound(
                    filename: filename,
                    type: type,
                    sourceURL: fileURL,
                    sha256: sha256
                )
                NSLog("[DaylightDropApp] Staged inbound file: %@", filename)
            } catch {
                NSLog("[DaylightDropApp] Error staging inbound file: %@", error.localizedDescription)
            }
        }
        
        transportManager.onTextReceived = { [weak self] payload in
            guard let self = self else { return }
            self.stagingManager.stageInboundText(
                text: payload.text,
                origin: payload.origin,
                type: payload.type
            )
            NSLog("[DaylightDropApp] Received text payload from origin: %@", payload.origin)
        }
    }
    
    private func setupCarbonHotkeys() {
        hotKeyManager.registerDefaultHotkeys(
            onToggleTray: {
                Task { @MainActor in
                    DaylightDropAppDelegate.shared.statusItemController?.toggleTray()
                }
            }
        )
    }
    
    public func applicationWillTerminate(_ notification: Notification) {
        transportManager.stop()
        hotKeyManager.unregisterAll()
    }
    
    private func setupStandardEditMenu() {
        let mainMenu = NSMenu()
        
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Paste and Match Style", action: Selector(("pasteAsPlainText:")), keyEquivalent: "V")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        
        NSApp.mainMenu = mainMenu
    }
}
