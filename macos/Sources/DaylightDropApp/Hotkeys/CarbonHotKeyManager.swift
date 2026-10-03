import Foundation
import Carbon
import Cocoa
import DaylightDropTransport

/// Global Hotkey Manager using Carbon HIToolbox RegisterEventHotKey.
/// Requires ZERO macOS Accessibility permissions (unlike CGEventTap).
public final class CarbonHotKeyManager: @unchecked Sendable {
    public static let shared = CarbonHotKeyManager()
    
    public typealias HotKeyAction = @Sendable () -> Void
    
    private var actions: [UInt32: HotKeyAction] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let lock = NSLock()
    
    public static let hotKeySignature: OSType = 0x444C4450 // 'DDLP'
    
    public static let toggleTrayID: UInt32 = 1
    public static let beamClipboardID: UInt32 = 2
    
    public init() {
        setupCarbonEventHandler()
    }
    
    private func setupCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        
        let handlerCallback: EventHandlerUPP = { (nextHandler, theEvent, userData) -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                theEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            
            if status == noErr {
                let id = hotKeyID.id
                let manager = CarbonHotKeyManager.shared
                manager.lock.lock()
                let action = manager.actions[id]
                manager.lock.unlock()
                
                if let action = action {
                    DispatchQueue.main.async {
                        action()
                    }
                }
            }
            return noErr
        }
        
        InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerCallback,
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }
    
    @discardableResult
    public func registerHotKey(
        keyCode: UInt32,
        modifiers: UInt32,
        id: UInt32,
        action: @escaping HotKeyAction
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        // Unregister existing if any
        if let existingRef = hotKeyRefs[id] {
            UnregisterEventHotKey(existingRef)
            hotKeyRefs.removeValue(forKey: id)
        }
        
        actions[id] = action
        
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: id)
        var hotKeyRef: EventHotKeyRef?
        
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        
        if status == noErr, let ref = hotKeyRef {
            hotKeyRefs[id] = ref
            return true
        } else {
            actions.removeValue(forKey: id)
            NSLog("[CarbonHotKeyManager] Failed to register hotkey id %u: %d", id, status)
            return false
        }
    }
    
    public func unregisterHotKey(id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
            hotKeyRefs.removeValue(forKey: id)
        }
        actions.removeValue(forKey: id)
    }
    
    public func unregisterAll() {
        lock.lock()
        defer { lock.unlock() }
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }
    
    public func teardown() {
        unregisterAll()
        lock.lock()
        defer { lock.unlock() }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
    
    deinit {
        teardown()
    }
    
    // MARK: - Standard Setup Helper
    
    public func registerDefaultHotkeys(
        onToggleTray: @escaping HotKeyAction,
        onBeamClipboard: HotKeyAction? = nil
    ) {
        // Cmd + Shift + D: Toggle Tray
        // kVK_ANSI_D = 0x02, cmdKey = 0x0100, shiftKey = 0x0200 -> 0x0300
        let cmdShift: UInt32 = UInt32(cmdKey | shiftKey)
        let kVK_ANSI_D: UInt32 = 0x02
        
        registerHotKey(
            keyCode: kVK_ANSI_D,
            modifiers: cmdShift,
            id: Self.toggleTrayID,
            action: onToggleTray
        )
        
        if let onBeamClipboard = onBeamClipboard {
            let kVK_ANSI_V: UInt32 = 0x09
            registerHotKey(
                keyCode: kVK_ANSI_V,
                modifiers: cmdShift,
                id: Self.beamClipboardID,
                action: onBeamClipboard
            )
        }
    }
    
    // MARK: - Clipboard Beam Handler with Loop Suppression
    
    public static func beamCurrentClipboard(stagingManager: StagingManager = .shared) {
        let pb = NSPasteboard.general
        let originType = NSPasteboard.PasteboardType("com.daylight.drop.origin")
        
        // Loop suppression check
        if let origin = pb.string(forType: originType), !origin.isEmpty && (origin == "daylight-dc1" || origin != TransportManager.shared.localDeviceId) {
            NSLog("[CarbonHotKeyManager] Suppressing beam: clipboard content originated from peer (%@)", origin)
            return
        }
        
        // 1. Check for file URLs or web URLs
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
                            _ = try await TransportManager.shared.sendFile(fileURL: staged.fileURL)
                            stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                        } catch {
                            NSLog("[CarbonHotKeyManager] Error beaming file: %@", error.localizedDescription)
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
                            NSLog("[CarbonHotKeyManager] Error beaming web url: %@", error.localizedDescription)
                            stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                        }
                    }
                }
                return
            }
        }
        
        // 2. Check for copied image data (PNG / TIFF with PNG transcoding)
        var imageData: Data? = nil
        var imageExtension = "png"
        
        if let png = pb.data(forType: .png) {
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
                    _ = try await TransportManager.shared.sendFile(fileURL: staged.fileURL, type: "image")
                    stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                } catch {
                    NSLog("[CarbonHotKeyManager] Error beaming image: %@", error.localizedDescription)
                    stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                }
            }
            return
        }
        
        // 3. Check for copied text
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let staged = stagingManager.stageOutboundPrompt(prompt: text)
            stagingManager.updateOutboundStatus(id: staged.id, status: .beaming)
            Task {
                do {
                    _ = try await TransportManager.shared.sendText(text: text, type: "clipboard")
                    stagingManager.updateOutboundStatus(id: staged.id, status: .beamed)
                } catch {
                    NSLog("[CarbonHotKeyManager] Error beaming clipboard text: %@", error.localizedDescription)
                    stagingManager.updateOutboundStatus(id: staged.id, status: .failed)
                }
            }
        }
    }
}
