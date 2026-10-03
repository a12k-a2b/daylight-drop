import XCTest
import Cocoa
import SwiftUI
@testable import DaylightDropKit
@testable import DaylightDropTransport

@MainActor
final class VisualSnapshotTests: XCTestCase {
    
    nonisolated(unsafe) var tempDir: URL!
    nonisolated(unsafe) var stagingManager: StagingManager!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("daylight_snapshot_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        stagingManager = StagingManager(customRootURL: tempDir)
    }
    
    override func tearDown() {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }
    
    private func createTestImage(size: NSSize, title: String, subtitle: String) -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        
        // Background
        NSColor(white: 0.95, alpha: 1.0).setFill()
        NSRect(origin: .zero, size: size).fill()
        
        // Border
        NSColor(white: 0.82, alpha: 1.0).setStroke()
        let border = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        border.lineWidth = 1.5
        border.stroke()
        
        // Inner badge
        NSColor(white: 0.2, alpha: 1.0).setFill()
        let badgeRect = NSRect(x: 12, y: size.height - 32, width: 68, height: 18)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        badgePath.fill()
        
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let badgeStr = NSAttributedString(string: "DAYLIGHT", attributes: badgeAttrs)
        badgeStr.draw(at: NSPoint(x: 18, y: size.height - 30))
        
        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor(white: 0.1, alpha: 1.0)
        ]
        let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
        titleStr.draw(at: NSPoint(x: 14, y: size.height - 58))
        
        // Subtitle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(white: 0.4, alpha: 1.0)
        ]
        let subStr = NSAttributedString(string: subtitle, attributes: subAttrs)
        subStr.draw(at: NSPoint(x: 14, y: size.height - 78))
        
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }
    
    private func setupMockItems() {
        let incomingDir = tempDir.appendingPathComponent("incoming", isDirectory: true)
        let outgoingDir = tempDir.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.createDirectory(at: incomingDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outgoingDir, withIntermediateDirectories: true)
        
        // 1. Inbound Screenshot
        let screenData = createTestImage(size: NSSize(width: 296, height: 396), title: "Sol:OS Dashboard", subtitle: "LivePaper 120Hz")
        let screenURL = incomingDir.appendingPathComponent("Screenshot_20261003_101214.png")
        try? screenData.write(to: screenURL)
        
        // 2. Inbound Markdown Note
        let noteText = """
        # Jesse Meeting Notes
        • Daylight DC1 LivePaper display
        • Pure 8-bit grayscale Sol:OS tokens
        • Bi-directional beam & instant drag-out
        • Zero EPD waveform clear flashes
        """
        let noteURL = incomingDir.appendingPathComponent("Jesse_LivePaper_Notes.md")
        try? noteText.write(to: noteURL, atomically: true, encoding: .utf8)
        
        // 3. Outbound Mockup
        let outImageData = createTestImage(size: NSSize(width: 240, height: 240), title: "Dropzone Shelf", subtitle: "Pinned HUD Target")
        let outImageURL = outgoingDir.appendingPathComponent("Dropzone_Shelf_Mockup.png")
        try? outImageData.write(to: outImageURL)
        
        // 4. Outbound Text Prompt
        let promptText = "Synthesize minimum-jerk velocity profiles for 8-bit capacitive touch interactions on DC1 LivePaper display."
        let promptURL = outgoingDir.appendingPathComponent("Prompt_MinimumJerk.txt")
        try? promptText.write(to: promptURL, atomically: true, encoding: .utf8)
        
        stagingManager.refreshFromDisk()
    }
    
    private func renderViewToPNG<V: View>(view: V, size: NSSize, scale: CGFloat = 2.0) -> Data? {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)
        
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.display()
        hostingView.layoutSubtreeIfNeeded()
        
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        if let image = renderer.nsImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            rep.size = size
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
    
    func testGenerateAllVisualSnapshots() {
        setupMockItems()
        
        // Give time for file attributes and thumbnail cache
        let exp = expectation(description: "Wait for items to populate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        
        let screenshotsDir = URL(fileURLWithPath: "/Users/anjan/.gemini/antigravity/scratch/daylight_drop/docs/screenshots")
        try? FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        
        // 1. macOS Tray Overview
        let trayView = FloatingTrayView(
            stagingManager: stagingManager,
            initialText: "Read Jesse's notes on LivePaper transflective display specs and synthesize summary for morning standup"
        )
        .padding(10)
        
        let traySize = NSSize(width: 460, height: 580)
        if let trayPNG = renderViewToPNG(view: trayView, size: traySize) {
            let outURL = screenshotsDir.appendingPathComponent("mac_tray_overview.png")
            try? trayPNG.write(to: outURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
            print("Successfully saved mac_tray_overview.png (\(trayPNG.count) bytes)")
        } else {
            XCTFail("Failed to render mac_tray_overview.png")
        }
        
        // 2. macOS Full Dropzone Overlay ("DROP ANYWHERE TO BEAM")
        let dropzoneView = FloatingTrayView(
            stagingManager: stagingManager,
            initialDropTargeted: true
        )
        .padding(10)
        
        if let dropzonePNG = renderViewToPNG(view: dropzoneView, size: traySize) {
            let outURL = screenshotsDir.appendingPathComponent("mac_dropzone_overlay.png")
            try? dropzonePNG.write(to: outURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
            print("Successfully saved mac_dropzone_overlay.png (\(dropzonePNG.count) bytes)")
        } else {
            XCTFail("Failed to render mac_dropzone_overlay.png")
        }
        
        // 3. macOS Floating Drop Bar HUD (Dropzone-style pinned shelf)
        let dropBarView = FloatingDropBarView(initialTargeted: false)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(SolOSTokens.os150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(SolOSTokens.os100, lineWidth: 1)
                    )
            )
            .padding(10)
        
        let barSize = NSSize(width: 360, height: 96)
        if let barPNG = renderViewToPNG(view: dropBarView, size: barSize) {
            let outURL = screenshotsDir.appendingPathComponent("mac_floating_drop_bar.png")
            try? barPNG.write(to: outURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
            print("Successfully saved mac_floating_drop_bar.png (\(barPNG.count) bytes)")
        } else {
            XCTFail("Failed to render mac_floating_drop_bar.png")
        }
    }
}
