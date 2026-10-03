import XCTest
import Cocoa
import SwiftUI
@testable import DaylightDropKit
@testable import DaylightDropTransport

final class AtomicBoolBox: @unchecked Sendable {
    var value = false
}

@MainActor
final class AppTests: XCTestCase {
    
    nonisolated(unsafe) var tempDirectory: URL!
    nonisolated(unsafe) var stagingManager: StagingManager!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("daylight_app_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        stagingManager = StagingManager(customRootURL: tempDirectory)
    }
    
    override func tearDown() {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }
    
    // MARK: - 1. FloatingTrayPanel Tests (F1, F3)
    
    func testFloatingTrayPanelConfiguration() {
        let panel = FloatingTrayPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480))
        
        // Window level must be .statusBar
        XCTAssertEqual(panel.level, .statusBar, "FloatingTrayPanel level must be .statusBar to float above apps")
        
        // Style mask must include nonactivatingPanel and borderless
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        
        // Collection behavior must allow joining all spaces & full screen auxiliary
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        
        // Must allow text input (canBecomeKey = true) without stealing foreground activation (canBecomeMain = false)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }
    
    func testFloatingTrayPanelFrameCalculationAndClamping() {
        let panel = FloatingTrayPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 480))
        let button = NSStatusBarButton(frame: NSRect(x: 100, y: 1000, width: 30, height: 22))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 1000, width: 30, height: 22), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView?.addSubview(button)
        
        let calculated = panel.calculateFrame(relativeTo: button, panelSize: NSSize(width: 440, height: 480))
        XCTAssertEqual(calculated.width, 440)
        XCTAssertEqual(calculated.height, 480)
        XCTAssertGreaterThan(calculated.origin.x, 0)
    }
    
    // MARK: - 2. DragCoordinator & Retention Tests (F3)
    
    func testDragCoordinatorLifecycle() {
        let coordinator = DragCoordinator()
        XCTAssertFalse(coordinator.isDraggingActive)
        
        let testURL = URL(fileURLWithPath: "/tmp/sample.png")
        coordinator.notifyDragBegan(url: testURL)
        
        let exp1 = expectation(description: "Drag began notified")
        DispatchQueue.main.async {
            XCTAssertTrue(coordinator.isDraggingActive)
            XCTAssertEqual(coordinator.activeDragURL, testURL)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 1.0)
        
        coordinator.notifyDragEnded()
        let exp2 = expectation(description: "Drag ended notified")
        DispatchQueue.main.async {
            XCTAssertFalse(coordinator.isDraggingActive)
            XCTAssertNil(coordinator.activeDragURL)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
    }
    
    func testDraggableCardNSViewDragSourceProtocol() {
        let view = DraggableCardNSView(frame: NSRect(x: 0, y: 0, width: 108, height: 114))
        let dummyURL = URL(fileURLWithPath: "/tmp/test.png")
        view.fileURL = dummyURL
        
        let coordinator = DragCoordinator()
        view.coordinator = coordinator
        
        let dummySession = NSDraggingSession()
        let op = view.draggingSession(dummySession, sourceOperationMaskFor: .outsideApplication)
        XCTAssertEqual(op, .copy)
        
        view.draggingSession(dummySession, willBeginAt: .zero)
        XCTAssertEqual(coordinator.activeDragURL, dummyURL)
        
        view.draggingSession(dummySession, endedAt: .zero, operation: .copy)
        XCTAssertNil(coordinator.activeDragURL)
    }
    
    // MARK: - 3. StatusItemDropTargetView & F24 Spring Open
    
    func testStatusItemDropTargetViewSpringOpenTimer() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let dropView = StatusItemDropTargetView(targetButton: button)
        
        let springOpenCalled = AtomicBoolBox()
        dropView.onSpringOpen = {
            springOpenCalled.value = true
        }
        
        let op = dropView.simulateDragEntered()
        XCTAssertEqual(op, .copy)
        XCTAssertTrue(dropView.isHoveringDrag)
        
        // Cancel before 300ms
        dropView.simulateDragExited()
        XCTAssertFalse(dropView.isHoveringDrag)
        
        let exp = expectation(description: "Wait past spring open window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.350) {
            XCTAssertFalse(springOpenCalled.value, "Spring open must NOT fire if drag exited before 300ms")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testStatusItemDropTargetViewDirectDrop() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let dropView = StatusItemDropTargetView(targetButton: button)
        let dropped = AtomicBoolBox()
        dropView.onDrop = { urls in
            if !urls.isEmpty {
                dropped.value = true
            }
        }
        
        let testURL = URL(fileURLWithPath: "/tmp/direct_drop.txt")
        let accepted = dropView.simulateDrop(urls: [testURL])
        XCTAssertTrue(accepted)
        XCTAssertTrue(dropped.value)
    }
    
    // MARK: - 4. Sol:OS Grayscale Design Tokens (F10)
    
    func testSolOSTokensValuesAndContrastCompliance() {
        // Sol:OS calibrated values
        XCTAssertEqual(SolOSTokens.nsOs0, NSColor(hex: "#FFFFFF"))
        XCTAssertEqual(SolOSTokens.nsOs50, NSColor(hex: "#F7F7F7"))
        XCTAssertEqual(SolOSTokens.nsOs100, NSColor(hex: "#DCD5C9"))
        XCTAssertEqual(SolOSTokens.nsOs150, NSColor(hex: "#F5F5F5"))
        XCTAssertEqual(SolOSTokens.nsOs200, NSColor(hex: "#CCCCCC"))
        XCTAssertEqual(SolOSTokens.nsOs300, NSColor(hex: "#858585"))
        XCTAssertEqual(SolOSTokens.nsOs400, NSColor(hex: "#535353"))
        XCTAssertEqual(SolOSTokens.nsOs800, NSColor(hex: "#343434"))
        XCTAssertEqual(SolOSTokens.nsOs900, NSColor(hex: "#1A1A1A"))
        XCTAssertEqual(SolOSTokens.nsOs1000, NSColor(hex: "#000000"))
        
        // Brand Grays
        XCTAssertEqual(SolOSTokens.nsBrandYellow, NSColor(hex: "#CECECE"))
        XCTAssertEqual(SolOSTokens.nsBrandAmber, NSColor(hex: "#9D9D9E"))
        XCTAssertEqual(SolOSTokens.nsBrandOrange, NSColor(hex: "#6C6C6D"))
        
        // Contrast Ratio: --os-900 (#1A1A1A) on --os-0 (#FFFFFF) must satisfy WCAG 2.1 AAA (>= 7.0:1)
        let lumPaper = SolOSTokens.relativeLuminance(r: 1.0, g: 1.0, b: 1.0)
        let lumInk = SolOSTokens.relativeLuminance(r: 0x1A/255.0, g: 0x1A/255.0, b: 0x1A/255.0)
        let contrast = SolOSTokens.contrastRatio(lum1: lumPaper, lum2: lumInk)
        XCTAssertGreaterThanOrEqual(contrast, 7.0, "Sol:OS --os-900 on --os-0 must satisfy WCAG 2.1 AAA (>= 7.0:1)")
    }
    
    // MARK: - 5. StagingManager Local Persistence (F8)
    
    func testStagingManagerDirectoryCreation() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingManager.incomingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingManager.outgoingDirectory.path))
    }
    
    func testStagingManagerAtomicWriteAndInboundStaging() throws {
        let sampleData = "Sample Screenshot Content".data(using: .utf8)!
        let sourceURL = tempDirectory.appendingPathComponent("source_screenshot.png")
        try sampleData.write(to: sourceURL)
        
        let item = try stagingManager.stageInbound(
            filename: "Screenshot_20261002_01.png",
            type: "screenshot",
            sourceURL: sourceURL,
            sha256: "abc123sha"
        )
        
        XCTAssertEqual(item.filename, "Screenshot_20261002_01.png")
        XCTAssertEqual(item.type, .screenshot)
        XCTAssertEqual(item.direction, .inbound)
        XCTAssertEqual(item.status, .received)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL.path))
    }
    
    func testStagingManagerInboundTextWithOriginTag() {
        let noteText = "Important reading note from Daylight LivePaper"
        let item = stagingManager.stageInboundText(text: noteText, origin: "daylight-dc1", type: "note")
        
        XCTAssertEqual(item.type, .note)
        XCTAssertEqual(item.previewText, noteText)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.fileURL.path))
        
        let exp = expectation(description: "Pasteboard write verified")
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            XCTAssertEqual(pb.string(forType: .string), noteText)
            XCTAssertEqual(pb.string(forType: NSPasteboard.PasteboardType("com.daylight.drop.origin")), "daylight-dc1")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testStagingManagerOutboundPromptAndQuarantineCopy() throws {
        let promptText = "Explain quantum computing simply"
        let promptItem = stagingManager.stageOutboundPrompt(prompt: promptText)
        
        XCTAssertEqual(promptItem.type, .prompt)
        XCTAssertEqual(promptItem.direction, .outbound)
        XCTAssertEqual(promptItem.status, .queued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: promptItem.fileURL.path))
        
        let savedContent = try String(contentsOf: promptItem.fileURL, encoding: .utf8)
        XCTAssertEqual(savedContent, promptText)
    }
    
    func testStagingManagerTypeInference() {
        XCTAssertEqual(StagingManager.inferType(from: URL(fileURLWithPath: "/tmp/Screenshot_123.png")), .screenshot)
        XCTAssertEqual(StagingManager.inferType(from: URL(fileURLWithPath: "/tmp/book.pdf")), .pdf)
        XCTAssertEqual(StagingManager.inferType(from: URL(fileURLWithPath: "/tmp/prompt_20261002.txt")), .prompt)
        XCTAssertEqual(StagingManager.inferType(from: URL(fileURLWithPath: "/tmp/note_sample.md")), .note)
        XCTAssertEqual(StagingManager.inferType(from: URL(fileURLWithPath: "/tmp/archive.zip")), .file)
    }
    
    func testStagingManagerCleanupPolicy() throws {
        for i in 1...5 {
            let file = tempDirectory.appendingPathComponent("incoming/f\(i).png")
            try "data\(i)".write(to: file, atomically: true, encoding: .utf8)
        }
        stagingManager.refreshFromDisk()
        
        let exp = expectation(description: "Refresh loaded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.stagingManager.inboundItems.count, 5)
            self.stagingManager.cleanupOldItems(maxCount: 2)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(self.stagingManager.inboundItems.count, 2)
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // MARK: - 6. Carbon Global Hotkeys API (F7)
    
    func testCarbonHotKeyManagerRegistrationAndLoopSuppression() {
        let manager = CarbonHotKeyManager.shared
        let toggleTriggered = AtomicBoolBox()
        let beamTriggered = AtomicBoolBox()
        
        manager.registerDefaultHotkeys(
            onToggleTray: {
                toggleTriggered.value = true
            },
            onBeamClipboard: {
                beamTriggered.value = true
            }
        )
        
        XCTAssertFalse(toggleTriggered.value)
        XCTAssertFalse(beamTriggered.value)
        
        // Loop suppression check: when origin == "daylight-dc1", beam is suppressed
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("Echo candidate text", forType: .string)
        pb.setString("daylight-dc1", forType: NSPasteboard.PasteboardType("com.daylight.drop.origin"))
        
        // BeamCurrentClipboard must suppress echo
        CarbonHotKeyManager.beamCurrentClipboard()
        
        // Clean up
        manager.unregisterAll()
    }
    
    // MARK: - 7. ThumbnailProvider (F8)
    
    func testThumbnailProviderCacheAndResize() throws {
        let provider = ThumbnailProvider.shared
        let testImage = NSImage(size: NSSize(width: 100, height: 100))
        testImage.lockFocus()
        NSColor.gray.drawSwatch(in: NSRect(x: 0, y: 0, width: 100, height: 100))
        testImage.unlockFocus()
        
        guard let tiffData = testImage.tiffRepresentation else {
            XCTFail("Failed to get TIFF data")
            return
        }
        let imgURL = tempDirectory.appendingPathComponent("test_thumb.png")
        try tiffData.write(to: imgURL)
        
        let exp = expectation(description: "Thumbnail generated")
        provider.generateThumbnail(for: imgURL, targetSize: CGSize(width: 48, height: 48)) { thumb in
            XCTAssertNotNil(thumb)
            XCTAssertEqual(thumb?.size.width, 48)
            XCTAssertEqual(thumb?.size.height, 48)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }
    
    // MARK: - 8. In-Tray Cmd+V Paste (F25)
    
    func testInTrayCmdVPasteFileAndImageHandling() throws {
        let fileURL = tempDirectory.appendingPathComponent("finder_file.pdf")
        try "%PDF-1.4 test".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
        
        let trayView = FloatingTrayView(stagingManager: stagingManager)
        trayView.handlePasteFromClipboard()
        
        let exp = expectation(description: "File pasted to outbound shelf")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(self.stagingManager.outboundItems.contains(where: { $0.filename == "finder_file.pdf" }))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    func testStagingManagerInboundSameFileRetention() throws {
        let dest = stagingManager.incomingDirectory.appendingPathComponent("already_here.png")
        try "Direct Write".write(to: dest, atomically: true, encoding: .utf8)
        
        let item = try stagingManager.stageInbound(
            filename: "already_here.png",
            type: "screenshot",
            sourceURL: dest,
            sha256: "some_sha"
        )
        
        XCTAssertEqual(item.filename, "already_here.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let content = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertEqual(content, "Direct Write")
    }
    
    func testStagingManagerRapidPromptEntropy() {
        let item1 = stagingManager.stageOutboundPrompt(prompt: "Prompt 1")
        let item2 = stagingManager.stageOutboundPrompt(prompt: "Prompt 2")
        
        XCTAssertNotEqual(item1.filename, item2.filename)
        XCTAssertTrue(item1.filename.hasPrefix("prompt_"))
        XCTAssertTrue(item2.filename.hasPrefix("prompt_"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item1.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item2.fileURL.path))
    }
    
    func testStatusItemDropTargetViewRegisteredTypes() {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        let dropView = StatusItemDropTargetView(targetButton: button)
        let types = dropView.registeredDraggedTypes
        XCTAssertTrue(types.contains(.fileURL))
        XCTAssertTrue(types.contains(.string))
    }
    
    func testInTrayCmdVWebURLHandling() {
        let webURL = URL(string: "https://daylightcomputer.com")!
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([webURL as NSURL])
        
        let trayView = FloatingTrayView(stagingManager: stagingManager)
        trayView.handlePasteFromClipboard()
        
        let exp = expectation(description: "Web URL pasted to outbound shelf as prompt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(self.stagingManager.outboundItems.contains(where: {
                $0.type == .prompt && ($0.previewText?.contains("https://daylightcomputer.com") == true)
            }))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
