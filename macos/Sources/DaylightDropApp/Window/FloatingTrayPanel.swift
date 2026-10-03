import Cocoa
import SwiftUI

/// Custom floating NSPanel configured at .statusBar level without stealing application focus.
/// Remains rock-solid during drag-out operations and avoids premature dismissal.
public final class FloatingTrayPanel: NSPanel {
    public weak var statusItem: NSStatusItem?
    public var globalEventMonitor: Any?
    public var localEventMonitor: Any?
    
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .utilityWindow
        self.appearance = NSAppearance(named: .aqua)
    }
    
    public override var canBecomeKey: Bool {
        // Allows text input into the ScratchpadView while remaining nonactivating
        return true
    }
    
    public override var canBecomeMain: Bool {
        // Prevents stealing menu bar focus from active foreground app
        return false
    }
    
    public var onPasteCommand: (() -> Void)?
    
    // MARK: - Frame Calculation & Clamping
    
    public func calculateFrame(relativeTo button: NSStatusBarButton, panelSize: NSSize) -> NSRect {
        guard let buttonWindow = button.window else {
            let screen = NSScreen.main ?? NSScreen.screens.first!
            let visibleFrame = screen.visibleFrame
            let originX = visibleFrame.midX - (panelSize.width / 2.0)
            let originY = visibleFrame.maxY - panelSize.height - 6.0
            return NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize)
        }
        let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = screen.visibleFrame
        
        var originX = buttonScreenRect.midX - (panelSize.width / 2.0)
        // If button bounds were not yet laid out (0 width), center near top-right
        if buttonScreenRect.width <= 1.0 {
            originX = visibleFrame.maxX - panelSize.width - 24.0
        }
        // Clamp to screen edges with 8px margin
        originX = max(visibleFrame.minX + 8.0, min(originX, visibleFrame.maxX - panelSize.width - 8.0))
        
        // Position 6px beneath menu bar
        let originY = buttonScreenRect.height > 1.0 ? (buttonScreenRect.minY - panelSize.height - 6.0) : (visibleFrame.maxY - panelSize.height - 6.0)
        
        return NSRect(origin: NSPoint(x: originX, y: originY), size: panelSize)
    }
    
    // MARK: - Presentation Lifecycle
    
    public func show(relativeTo button: NSStatusBarButton, panelSize: NSSize = NSSize(width: 440, height: 480)) {
        let frame = calculateFrame(relativeTo: button, panelSize: panelSize)
        self.setFrame(frame, display: true)
        self.makeKeyAndOrderFront(nil)
        startOutsideClickMonitoring()
    }
    
    public func hide() {
        stopOutsideClickMonitoring()
        self.orderOut(nil)
    }
    
    public func toggle(relativeTo button: NSStatusBarButton, panelSize: NSSize = NSSize(width: 440, height: 480)) {
        if self.isVisible {
            hide()
        } else {
            show(relativeTo: button, panelSize: panelSize)
        }
    }
    
    // MARK: - Outside-Click Dismissal & Drag Protection
    
    public func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }
            
            // 1. SUPPRESS DISMISSAL IF DRAG-OUT IS ACTIVE
            if DragCoordinator.shared.isDraggingActive || DragCoordinator.shared.activeDragURL != nil {
                return
            }
            
            // 2. SUPPRESS DISMISSAL IF CLICK IS ON THE STATUS ITEM BUTTON (avoid double-toggle)
            let mouseLocation = NSEvent.mouseLocation
            if let button = self.statusItem?.button, let buttonWindow = button.window {
                let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
                if buttonScreenRect.contains(mouseLocation) {
                    return
                }
            }
            
            // 3. Otherwise, outside click dismisses the tray
            self.hide()
        }
        
        // F25: Local Event Monitor for In-Tray Cmd+V Paste
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            let isCmd = event.modifierFlags.contains(.command)
            let isV = (event.keyCode == 9) // 9 = 'v'
            
            if isCmd && isV {
                // If user is currently typing in a text field, perform paste directly
                if let textView = self.firstResponder as? NSTextView {
                    textView.pasteAsPlainText(nil)
                    return nil
                }
                // Otherwise notify tray paste handler
                self.onPasteCommand?()
                return nil
            }
            return event
        }
    }
    
    public func stopOutsideClickMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let local = localEventMonitor {
            NSEvent.removeMonitor(local)
            localEventMonitor = nil
        }
    }
}
