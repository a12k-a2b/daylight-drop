import Cocoa
import DaylightDropTransport

/// Custom view embedded in NSStatusItem.button to handle direct file drops
/// and implement F24 Drag-Hover Spring Open.
public final class StatusItemDropTargetView: NSView {
    public weak var targetButton: NSStatusBarButton?
    public var onToggle: (() -> Void)?
    public var onSpringOpen: (() -> Void)?
    public var onDrop: (([URL]) -> Void)?
    
    private var springOpenWorkItem: DispatchWorkItem?
    public private(set) var isHoveringDrag: Bool = false
    
    public init(targetButton: NSStatusBarButton) {
        self.targetButton = targetButton
        super.init(frame: targetButton.bounds)
        self.autoresizingMask = [.width, .height]
        self.registerForDraggedTypes([.fileURL, .string])
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.registerForDraggedTypes([.fileURL, .string])
    }
    
    // MARK: - Normal Mouse Click
    
    public override func mouseDown(with event: NSEvent) {
        if let onToggle = onToggle {
            onToggle()
        } else {
            targetButton?.performClick(nil)
        }
    }
    
    // MARK: - Drag Destination & Spring Open (F24)
    
    @discardableResult
    public func simulateDragEntered() -> NSDragOperation {
        isHoveringDrag = true
        scheduleSpringOpenTimer()
        return .copy
    }
    
    public func simulateDragExited() {
        isHoveringDrag = false
        cancelSpringOpenTimer()
    }
    
    public func simulateDrop(urls: [URL]) -> Bool {
        cancelSpringOpenTimer()
        isHoveringDrag = false
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return simulateDragEntered()
    }
    
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }
    
    public override func draggingExited(_ sender: NSDraggingInfo?) {
        simulateDragExited()
    }
    
    public override func draggingEnded(_ sender: NSDraggingInfo) {
        simulateDragExited()
    }
    
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty {
                return simulateDrop(urls: fileURLs)
            }
        }
        
        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cancelSpringOpenTimer()
            isHoveringDrag = false
            let staged = StagingManager.shared.stageOutboundPrompt(prompt: string)
            StagingManager.shared.updateOutboundStatus(id: staged.id, status: .beaming)
            Task {
                do {
                    _ = try await TransportManager.shared.sendText(text: string, type: "clipboard")
                    StagingManager.shared.updateOutboundStatus(id: staged.id, status: .beamed)
                } catch {
                    StagingManager.shared.updateOutboundStatus(id: staged.id, status: .failed)
                }
            }
            return true
        }
        
        return false
    }
    
    // MARK: - Spring Open Timer Handling (300ms)
    
    private func scheduleSpringOpenTimer() {
        cancelSpringOpenTimer()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isHoveringDrag else { return }
            self.onSpringOpen?()
        }
        self.springOpenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.300, execute: workItem)
    }
    
    public func cancelSpringOpenTimer() {
        springOpenWorkItem?.cancel()
        springOpenWorkItem = nil
    }
}
