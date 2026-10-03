import Cocoa
import SwiftUI
import DaylightDropTransport

/// Floating HUD Drop Bar inspired by Dropzone.
/// Can be pinned anywhere on screen as a generous, persistent drop target.
public final class FloatingDropBarPanel: NSPanel {
    public static let shared = FloatingDropBarPanel()
    
    private init() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let initialWidth: CGFloat = 340
        let initialHeight: CGFloat = 76
        // Position at top-right of main screen by default (below menu bar)
        let initialRect = NSRect(
            x: visible.maxX - initialWidth - 20,
            y: visible.maxY - initialHeight - 12,
            width: initialWidth,
            height: initialHeight
        )
        
        super.init(
            contentRect: initialRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false
        self.animationBehavior = .utilityWindow
        self.appearance = NSAppearance(named: .aqua)
        
        let dropBarView = FloatingDropBarView(
            onClose: { [weak self] in
                self?.hide()
            }
        )
        let hostingView = NSHostingView(rootView: dropBarView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hostingView
    }
    
    public func show() {
        self.makeKeyAndOrderFront(nil)
    }
    
    public func hide() {
        self.orderOut(nil)
    }
    
    public func toggle() {
        if self.isVisible {
            hide()
        } else {
            show()
        }
    }
}

public struct FloatingDropBarView: View {
    @ObservedObject var stagingManager: StagingManager = .shared
    @State private var isTargeted: Bool = false
    public var onClose: (() -> Void)?
    
    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }
    
    public var body: some View {
        HStack(spacing: 10) {
            // Drag handle and brand icon
            VStack(spacing: 3) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(SolOSTokens.os900)
                
                Text("DAYLIGHT")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(SolOSTokens.os400)
                    .tracking(0.5)
            }
            .frame(width: 44)
            
            Divider()
                .background(SolOSTokens.os100)
            
            // Large Drop Zone
            ZStack {
                RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                    .fill(isTargeted ? SolOSTokens.os900 : SolOSTokens.os0)
                
                RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusMedium)
                    .strokeBorder(
                        isTargeted ? SolOSTokens.os0 : SolOSTokens.os300,
                        style: StrokeStyle(lineWidth: isTargeted ? 2.0 : 1.2, dash: [4, 4])
                    )
                
                HStack(spacing: 8) {
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "arrow.down.to.line.compact")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(isTargeted ? SolOSTokens.os0 : SolOSTokens.os900)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isTargeted ? "RELEASE TO BEAM" : "DROP FILES HERE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isTargeted ? SolOSTokens.os0 : SolOSTokens.os900)
                            .tracking(0.6)
                        
                        Text(isTargeted ? "Streaming to Daylight..." : "Dropzone shelf • Finder / Photos")
                            .font(.system(size: 9))
                            .foregroundColor(isTargeted ? SolOSTokens.os150 : SolOSTokens.os400)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: DropItemHandler.supportedDropTypes, isTargeted: $isTargeted) { providers in
                DropItemHandler.handleDroppedProviders(providers, stagingManager: stagingManager, onComplete: nil)
            }
            
            // Close / Unpin button
            Button(action: { onClose?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(SolOSTokens.os400)
                    .padding(5)
                    .background(SolOSTokens.os150)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close Drop Bar")
        }
        .padding(8)
        .frame(width: 340, height: 76)
        .background(
            RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge)
                .fill(SolOSTokens.os50)
                .overlay(
                    RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge)
                        .stroke(SolOSTokens.os900, lineWidth: 1.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: SolOSTokens.cornerRadiusLarge))
        .environment(\.colorScheme, .light)
    }
}
