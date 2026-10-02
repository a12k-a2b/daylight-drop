import SwiftUI
import AppKit

/// AppKit view conforming to NSDraggingSource to allow dragging files out of the tray into Finder/apps.
public final class DraggableCardNSView: NSView, NSDraggingSource {
    public var fileURL: URL?
    public weak var coordinator: DragCoordinator?
    private var initialMouseDownLocation: NSPoint = .zero
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }
    
    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        coordinator?.notifyDragBegan(url: fileURL)
    }
    
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        coordinator?.notifyDragEnded()
    }
    
    public override func mouseDown(with event: NSEvent) {
        initialMouseDownLocation = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }
    
    public override func mouseDragged(with event: NSEvent) {
        guard let url = fileURL else {
            super.mouseDragged(with: event)
            return
        }
        
        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - initialMouseDownLocation.x, point.y - initialMouseDownLocation.y)
        guard distance > 3.0 else { return }
        
        let draggingItem = NSDraggingItem(pasteboardWriter: url as NSURL)
        
        // Provide drag preview image
        let dragImage: NSImage
        if let thumb = ThumbnailProvider.shared.cachedThumbnail(for: url, targetSize: CGSize(width: 64, height: 64)) {
            dragImage = thumb
        } else {
            dragImage = NSWorkspace.shared.icon(forFile: url.path)
        }
        
        let dragBounds = NSRect(
            x: max(0, point.x - 32),
            y: max(0, point.y - 32),
            width: 64,
            height: 64
        )
        draggingItem.setDraggingFrame(dragBounds, contents: dragImage)
        
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
}

/// SwiftUI wrapper for DraggableCardNSView allowing arbitrary SwiftUI card views to act as drag-out sources.
public struct DraggableCardContainer<Content: View>: NSViewRepresentable {
    public let fileURL: URL
    public let coordinator: DragCoordinator
    public let content: Content
    
    public init(fileURL: URL, coordinator: DragCoordinator = .shared, @ViewBuilder content: () -> Content) {
        self.fileURL = fileURL
        self.coordinator = coordinator
        self.content = content()
    }
    
    public func makeNSView(context: Context) -> DraggableCardNSView {
        let view = DraggableCardNSView()
        view.fileURL = fileURL
        view.coordinator = coordinator
        
        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }
    
    public func updateNSView(_ nsView: DraggableCardNSView, context: Context) {
        nsView.fileURL = fileURL
        nsView.coordinator = coordinator
    }
}
