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
    
    private static let registeredTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .string,
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("NSFilePromiseReceiver"),
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("public.jpeg")
    ]
    
    public init(targetButton: NSStatusBarButton) {
        self.targetButton = targetButton
        super.init(frame: targetButton.bounds)
        self.autoresizingMask = [.width, .height]
        self.registerForDraggedTypes(Self.registeredTypes)
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.registerForDraggedTypes(Self.registeredTypes)
    }
    
    // MARK: - Normal Mouse Click
    
    public override func mouseDown(with event: NSEvent) {
        if let onToggle = onToggle {
            onToggle()
        } else {
            targetButton?.performClick(nil)
        }
    }
    
    // MARK: - Visual Feedback on Drag Hover
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isHoveringDrag {
            let insetRect = bounds.insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: insetRect, xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
    
    // MARK: - Drag Destination & Spring Open (F24)
    
    @discardableResult
    public func simulateDragEntered() -> NSDragOperation {
        isHoveringDrag = true
        needsDisplay = true
        scheduleSpringOpenTimer()
        return .copy
    }
    
    public func simulateDragExited() {
        isHoveringDrag = false
        needsDisplay = true
        cancelSpringOpenTimer()
    }
    
    public func simulateDrop(urls: [URL]) -> Bool {
        cancelSpringOpenTimer()
        isHoveringDrag = false
        needsDisplay = true
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
        
        // 1. Files from Finder
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let fileURLs = urls.filter { $0.isFileURL }
            if !fileURLs.isEmpty {
                return simulateDrop(urls: fileURLs)
            }
        }
        
        // 2. File promises (Photos.app)
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            cancelSpringOpenTimer()
            isHoveringDrag = false
            let outgoingDir = StagingManager.shared.outgoingDirectory
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: outgoingDir, options: [:], operationQueue: .main) { [weak self] fileURL, error in
                    if error == nil {
                        _ = self?.simulateDrop(urls: [fileURL])
                    }
                }
            }
            return true
        }
        
        // 3. Raw Image Data on drag pasteboard (HEIC, JPEG, PNG, TIFF)
        let imgTypes: [(NSPasteboard.PasteboardType, String)] = [
            (NSPasteboard.PasteboardType("public.heic"), "heic"),
            (NSPasteboard.PasteboardType("public.heif"), "heif"),
            (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
            (.png, "png"),
            (.tiff, "tiff")
        ]
        for (pbType, ext) in imgTypes {
            if let data = pasteboard.data(forType: pbType) {
                cancelSpringOpenTimer()
                isHoveringDrag = false
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd_HHmmss"
                let filename = "dropped_\(df.string(from: Date()))_\(UUID().uuidString.prefix(6)).\(ext)"
                let staged = StagingManager.shared.stageOutboundData(data: data, filename: filename, type: .screenshot)
                return simulateDrop(urls: [staged.fileURL])
            }
        }
        
        // 4. String / text
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
    
    // MARK: - Spring Open Timer Handling (20ms fast trigger)
    
    private func scheduleSpringOpenTimer() {
        cancelSpringOpenTimer()
        
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isHoveringDrag else { return }
            self.onSpringOpen?()
        }
        self.springOpenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.020, execute: workItem)
    }
    
    public func cancelSpringOpenTimer() {
        springOpenWorkItem?.cancel()
        springOpenWorkItem = nil
    }
}
