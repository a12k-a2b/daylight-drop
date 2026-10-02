import Foundation
import Combine

/// Coordinates active drag-out sessions from the floating tray into external applications.
/// When isDraggingActive is true, global mouse event monitors must SUPPRESS tray dismissal.
public final class DragCoordinator: ObservableObject, @unchecked Sendable {
    public static let shared = DragCoordinator()
    
    @Published public var isDraggingActive: Bool = false
    public private(set) var activeDragURL: URL? = nil
    
    private let lock = NSLock()
    
    public init() {}
    
    public func notifyDragBegan(url: URL? = nil) {
        lock.lock()
        activeDragURL = url
        lock.unlock()
        if Thread.isMainThread {
            self.isDraggingActive = true
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isDraggingActive = true
            }
        }
    }
    
    public func notifyDragEnded() {
        lock.lock()
        activeDragURL = nil
        lock.unlock()
        if Thread.isMainThread {
            self.isDraggingActive = false
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isDraggingActive = false
            }
        }
    }
}
