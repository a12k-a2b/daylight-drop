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
    }
    
    public override var canBecomeKey: Bool {
        // Allows text input into the ScratchpadView while remaining nonactivating
        return true
    }
    
    public override var canBecomeMain: Bool {
        // Prevents stealing menu bar focus from active foreground app
        return false
    }
    
    // MARK: - Frame Calculation & Clamping
    
    public func calculateFrame(relativeTo button: NSStatusBarButton, panelSize: NSSize) -> NSRect {
        guard let buttonWindow = button.window else {
            return NSRect(origin: .zero, size: panelSize)
        }
        let buttonScreenRect = buttonWindow.convertToScreen(button.bounds)
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = screen.visibleFrame
        
        var originX = buttonScreenRect.midX - (panelSize.width / 2.0)
        // Clamp to screen edges with 8px margin
        originX = max(visibleFrame.minX + 8.0, min(originX, visibleFrame.maxX - panelSize.width - 8.0))
        
        // Position 6px beneath menu bar
        let originY = buttonScreenRect.minY - panelSize.height - 6.0
        
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
    }
    
    public func stopOutsideClickMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }
}
