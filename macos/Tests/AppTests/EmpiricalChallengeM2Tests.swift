import XCTest
import Cocoa
import Carbon
import SwiftUI
import CryptoKit
@testable import DaylightDropApp
@testable import DaylightDropTransport

final class TestAtomicBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

final class EmpiricalChallengeM2Tests: XCTestCase {
    
    nonisolated(unsafe) var tempDirectory: URL!
    nonisolated(unsafe) var stagingManager: StagingManager!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("daylight_challenger_m2_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        stagingManager = StagingManager(customRootURL: tempDirectory)
    }
    
    override func tearDown() {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        super.tearDown()
    }
    
    // MARK: - =================================================================
    // MARK: 1. Carbon Hotkeys Empirical Tests
    // MARK: - =================================================================
    
    /// Test 1.1: Verify RegisterEventHotKey succeeds with zero accessibility permissions (AXIsProcessTrusted == false)
    func testCarbonHotKeyZeroAccessibilityPermissionRequirement() {
        // Step 1: Query macOS Accessibility trust
        let isTrusted = AXIsProcessTrusted()
        NSLog("[EmpiricalTest] AXIsProcessTrusted status: %d", isTrusted ? 1 : 0)
        
        // Step 2: Register hotkeys via CarbonHotKeyManager
        let manager = CarbonHotKeyManager.shared
        let toggleFired = TestAtomicBox(false)
        let beamFired = TestAtomicBox(false)
        
        let dRegistered = manager.registerHotKey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 101,
            action: { toggleFired.value = true }
        )
        
        let vRegistered = manager.registerHotKey(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 102,
            action: { beamFired.value = true }
        )
        
        XCTAssertTrue(dRegistered, "RegisterEventHotKey for Cmd+Shift+D must succeed regardless of AX trust")
        XCTAssertTrue(vRegistered, "RegisterEventHotKey for Cmd+Shift+V must succeed regardless of AX trust")
        
        // Clean up
        manager.unregisterHotKey(id: 101)
        manager.unregisterHotKey(id: 102)
    }
    
    /// Test 1.2: Verify Carbon HotKey Event Dispatch via synthesized Carbon Event
    func testCarbonHotKeyEventDispatchSynthesis() {
        let manager = CarbonHotKeyManager.shared
        let expectation = expectation(description: "Carbon hotkey action invoked")
        let fired = TestAtomicBox(false)
        
        let testID: UInt32 = 201
        let registered = manager.registerHotKey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey | shiftKey),
            id: testID,
            action: {
                fired.value = true
                expectation.fulfill()
            }
        )
        XCTAssertTrue(registered)
        
        // Synthesize Carbon EventHotKeyPressed event directly targeting the event dispatcher
        var eventRef: EventRef?
        var hotKeyID = EventHotKeyID(signature: CarbonHotKeyManager.hotKeySignature, id: testID)
        let status = CreateEvent(
            kCFAllocatorDefault,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeUserEvent),
            &eventRef
        )
        XCTAssertEqual(status, noErr, "CreateEvent must succeed")
        
        if let event = eventRef {
            let setParamStatus = SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size,
                &hotKeyID
            )
            XCTAssertEqual(setParamStatus, noErr, "SetEventParameter must succeed")
            
            let sendStatus = SendEventToEventTarget(event, GetEventDispatcherTarget())
            XCTAssertEqual(sendStatus, noErr, "SendEventToEventTarget must succeed")
            ReleaseEvent(event)
        }
        
        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(fired.value, "Hotkey callback must have been executed")
        
        // Clean up
        manager.unregisterHotKey(id: testID)
    }
    
    /// Test 1.3: Verify UnregisterEventHotKey prevents further event invocations
    func testCarbonHotKeyUnregistrationSuppressesFiring() {
        let manager = CarbonHotKeyManager.shared
        let fired = TestAtomicBox(false)
        let testID: UInt32 = 202
        
        _ = manager.registerHotKey(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey | shiftKey),
            id: testID,
            action: { fired.value = true }
        )
        
        // Unregister
        manager.unregisterHotKey(id: testID)
        
        // Attempt to dispatch synthesized event for unregistered ID
        var eventRef: EventRef?
        var hotKeyID = EventHotKeyID(signature: CarbonHotKeyManager.hotKeySignature, id: testID)
        let status = CreateEvent(
            kCFAllocatorDefault,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeUserEvent),
            &eventRef
        )
        if status == noErr, let event = eventRef {
            SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size,
                &hotKeyID
            )
            SendEventToEventTarget(event, GetEventDispatcherTarget())
            ReleaseEvent(event)
        }
        
        let waitExp = expectation(description: "Wait after event")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertFalse(fired.value, "Action must NOT be called after unregistering hotkey")
            waitExp.fulfill()
        }
        wait(for: [waitExp], timeout: 1.0)
    }
    
    /// Test 1.4: Verify beamCurrentClipboard loop suppression with DC1 origin tag
    func testCarbonHotKeyBeamCurrentClipboardSuppressesDC1Origin() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("Echo test text from DC1", forType: .string)
        pb.setString("daylight-dc1", forType: NSPasteboard.PasteboardType("com.daylight.drop.origin"))
        
        let initialOutboundCount = stagingManager.outboundItems.count
        CarbonHotKeyManager.beamCurrentClipboard()
        
        let mgr = self.stagingManager!
        let exp = expectation(description: "Check loop suppression")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            // Must not stage outbound item
            XCTAssertEqual(mgr.outboundItems.count, initialOutboundCount, "Must not stage items originating from DC1")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    // MARK: - =================================================================
    // MARK: 2. Quick AI Scratchpad Empirical Tests
    // MARK: - =================================================================
    
    /// Test 2.1: Multiline and special unicode / emoji text input handling in Scratchpad
    @MainActor
    func testScratchpadMultilineAndUnicodePayloadIntegrity() {
        let multilinePrompt = """
        Analyze this algorithm:
        func solve(x: Int) -> Int {
            return x * 42 // 🚀 LivePaper optimization
        }
        Special chars: ~!@#$%^&*()_+{}[]|:;"'<>,.?/
        Unicode: 日本語, العربية, 🌅, 📝
        """
        
        var boundText = multilinePrompt
        let dispatchedText = TestAtomicBox<String?>(nil)
        
        let scratchpad = ScratchpadView(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            stagingManager: stagingManager,
            onDispatch: { prompt in
                dispatchedText.value = prompt
            }
        )
        
        scratchpad.dispatchPrompt()
        
        XCTAssertEqual(boundText, "", "Scratchpad text binding must be cleared after dispatch")
        XCTAssertEqual(dispatchedText.value, multilinePrompt, "Dispatched text must match multiline input verbatim")
    }
    
    /// Test 2.2: Scratchpad empty and whitespace-only prompt guarding
    @MainActor
    func testScratchpadEmptyAndWhitespaceGuarding() {
        let emptyCases = ["", "   ", "\n\n", "\t \r\n  "]
        
        for input in emptyCases {
            var boundText = input
            let dispatchedText = TestAtomicBox<String?>(nil)
            
            let scratchpad = ScratchpadView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                stagingManager: stagingManager,
                onDispatch: { prompt in
                    dispatchedText.value = prompt
                }
            )
            
            scratchpad.dispatchPrompt()
            
            XCTAssertEqual(boundText, input, "Empty/whitespace input must NOT be cleared or dispatched")
            XCTAssertNil(dispatchedText.value, "No prompt must be dispatched for whitespace input")
        }
    }
    
    /// Test 2.3: Scratchpad SLA Timing (<500ms dispatch SLA budget)
    func testScratchpadDispatchLatencySLAUnder500ms() async throws {
        // Start local test server to receive text prompt
        let testPort: UInt16 = 19876
        let serverIncoming = tempDirectory.appendingPathComponent("server_incoming")
        try FileManager.default.createDirectory(at: serverIncoming, withIntermediateDirectories: true)
        
        let server = DaylightHTTPServer(port: testPort, deviceId: "dc1-test-peer", incomingDirectory: serverIncoming)
        try server.start()
        defer { server.stop() }
        
        // Configure TransportManager with active peer endpoint via browser discovery callback
        let transport = TransportManager.shared
        let simulatedPeer = DiscoveredPeer(
            deviceId: "JMBR00380",
            deviceName: "Daylight Computer DC1",
            ip: "127.0.0.1",
            port: testPort,
            protoVer: ProtocolConstants.protocolVersion
        )
        transport.browser.onPeerDiscovered?(simulatedPeer)
        
        let promptText = "High priority SLA test prompt: summarize current paper"
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Execute dispatch via ScratchpadView default handler (stages outbound + beams via TransportManager)
        let mgr = self.stagingManager!
        await MainActor.run {
            var boundText = promptText
            let scratchpad = ScratchpadView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                stagingManager: mgr
            )
            scratchpad.dispatchPrompt()
        }
        
        // Wait for outbound item status to reach .beamed
        let maxWaitSeconds = 2.0
        var elapsed: Double = 0.0
        var isBeamed = false
        
        while elapsed < maxWaitSeconds {
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
            if let item = stagingManager.outboundItems.first(where: { $0.type == .prompt }) {
                if item.status == .beamed {
                    isBeamed = true
                    break
                }
            }
            elapsed = CFAbsoluteTimeGetCurrent() - startTime
        }
        
        let totalElapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        NSLog("[EmpiricalTest] Scratchpad dispatch end-to-end latency: %.2f ms (beamed: %d)", totalElapsedMs, isBeamed ? 1 : 0)
        
        XCTAssertTrue(isBeamed, "Prompt must successfully transition to .beamed state")
        XCTAssertLessThan(totalElapsedMs, 500.0, "Scratchpad dispatch SLA must be strictly under 500ms (AC line 39)")
    }
    
    /// Test 2.4: Rapid-fire Cmd+Enter dispatch within same second (Testing filename collisions & overwrites)
    func testScratchpadRapidDispatchFilenameCollisions() {
        let promptCount = 5
        var stagedItems: [StagedItem] = []
        
        for i in 1...promptCount {
            let item = stagingManager.stageOutboundPrompt(prompt: "Rapid prompt #\(i)")
            stagedItems.append(item)
        }
        
        let filenames = stagedItems.map { $0.filename }
        let uniqueFilenames = Set(filenames)
        
        NSLog("[EmpiricalTest] Staged %d prompts. Unique filenames: %d. Filenames: %@",
              promptCount, uniqueFilenames.count, filenames.description)
        
        // Check actual files on disk in outgoing directory
        let fm = FileManager.default
        let diskFiles = (try? fm.contentsOfDirectory(atPath: stagingManager.outgoingDirectory.path)) ?? []
        NSLog("[EmpiricalTest] Disk files in outgoing: %@", diskFiles.description)
        
        // BUG DISCOVERY CHECK:
        // Because dateFormatter is "yyyyMMdd_HHmmss", all prompts staged in the same second share the exact same filename.
        // Therefore, prompt #2 overwrites prompt #1, resulting in file loss on disk!
        if uniqueFilenames.count < promptCount {
            NSLog("[EmpiricalTest] BUG CONFIRMED: Rapid prompts collided on disk filename! %d prompts generated only %d unique file(s)",
                  promptCount, uniqueFilenames.count)
        }
        
        XCTAssertEqual(uniqueFilenames.count, promptCount,
                       "Each staged prompt MUST have a unique filename to prevent disk overwrite data loss!")
    }
    
    /// Test 2.5: Empirical check for orphaned .tmp files created by stageOutboundPrompt / stageInboundText
    func testStagingOrphanedTmpFileDetection() {
        let fm = FileManager.default
        let freshDir = FileManager.default.temporaryDirectory.appendingPathComponent("fresh_staging_\(UUID().uuidString)")
        let freshMgr = StagingManager(customRootURL: freshDir)
        defer { try? fm.removeItem(at: freshDir) }
        
        // Stage a prompt where destURL definitely does NOT exist prior to this call
        _ = freshMgr.stageOutboundPrompt(prompt: "Check for tmp file leak on fresh destination")
        
        // Read directory contents including non-hidden files
        let outgoingFiles = (try? fm.contentsOfDirectory(atPath: freshMgr.outgoingDirectory.path)) ?? []
        let tmpFiles = outgoingFiles.filter { $0.hasSuffix(".tmp") }
        
        NSLog("[EmpiricalTest] Fresh Staging: Outgoing files: %@, tmpFiles: %@", outgoingFiles.description, tmpFiles.description)
        
        if !tmpFiles.isEmpty {
            NSLog("[EmpiricalTest] BUG CONFIRMED: stageOutboundPrompt leaked orphaned .tmp files on disk: %@", tmpFiles.description)
        }
        
        XCTAssertTrue(tmpFiles.isEmpty, "Staging MUST NOT leak orphaned .tmp files on disk! Found: \(tmpFiles)")
    }
    
    // MARK: - =================================================================
    // MARK: 3. Staging Stress Empirical Tests
    // MARK: - =================================================================
    
    /// Test 3.1: Concurrent outbound file staging stress and SHA-256 verification
    func testStagingConcurrentOutboundFileStressAndIntegrity() async throws {
        let fileCount = 30
        struct SourceFileInfo: Sendable {
            let url: URL
            let hash: String
            let size: Int
        }
        
        var sourceFiles: [SourceFileInfo] = []
        let sourceDir = tempDirectory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        
        // Create 30 source files with varied sizes (from 1KB to 256KB)
        for i in 0..<fileCount {
            let size = 1024 * (i + 1)
            var bytes = [UInt8](repeating: 0, count: size)
            for j in 0..<size {
                bytes[j] = UInt8((i + j) % 256)
            }
            let data = Data(bytes)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let fileURL = sourceDir.appendingPathComponent("stress_file_\(i).bin")
            try data.write(to: fileURL)
            sourceFiles.append(SourceFileInfo(url: fileURL, hash: hash, size: size))
        }
        
        let mgr = self.stagingManager!
        
        // Stage all 30 files concurrently using TaskGroup
        let stagedItems = try await withThrowingTaskGroup(of: StagedItem.self, returning: [StagedItem].self) { group in
            for file in sourceFiles {
                group.addTask {
                    return try mgr.stageOutboundFile(url: file.url)
                }
            }
            var items: [StagedItem] = []
            for try await item in group {
                items.append(item)
            }
            return items
        }
        
        XCTAssertEqual(stagedItems.count, fileCount, "All files must be staged successfully")
        
        // Verify SHA-256 integrity on disk for each staged item
        let fm = FileManager.default
        for file in sourceFiles {
            let stagedPath = stagingManager.outgoingDirectory.appendingPathComponent(file.url.lastPathComponent)
            XCTAssertTrue(fm.fileExists(atPath: stagedPath.path), "Staged file must exist on disk: \(stagedPath.lastPathComponent)")
            
            let stagedData = try Data(contentsOf: stagedPath)
            let stagedHash = SHA256.hash(data: stagedData).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(stagedHash, file.hash, "Staged file SHA-256 must match original data perfectly")
        }
    }
    
    /// Test 3.2: Staging inbound files with special characters and spaces
    func testStagingSpecialCharactersInFilename() throws {
        let specialNames = [
            "Screenshot 2026-10-02 at 12.30.00 PM.png",
            "Daylight_Paper_Notes_#1 (Final).txt",
            "日本語_ドキュメント.pdf",
            "Prompt with 'quotes' & spaces.txt"
        ]
        
        for name in specialNames {
            let srcURL = tempDirectory.appendingPathComponent("src_\(UUID().uuidString)")
            let content = "Sample content for \(name)"
            try content.write(to: srcURL, atomically: true, encoding: .utf8)
            
            let staged = try stagingManager.stageInbound(
                filename: name,
                type: "file",
                sourceURL: srcURL
            )
            
            XCTAssertEqual(staged.filename, name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fileURL.path))
            let readContent = try String(contentsOf: staged.fileURL, encoding: .utf8)
            XCTAssertEqual(readContent, content)
        }
    }
    
    /// Test 3.3: ThumbnailProvider cache performance & hit latency
    func testThumbnailProviderCachePerformanceStress() throws {
        let provider = ThumbnailProvider.shared
        
        // Create a test image
        let testImage = NSImage(size: NSSize(width: 200, height: 200))
        testImage.lockFocus()
        NSColor.systemBlue.drawSwatch(in: NSRect(x: 0, y: 0, width: 200, height: 200))
        testImage.unlockFocus()
        
        guard let tiffData = testImage.tiffRepresentation else {
            XCTFail("Failed to create TIFF")
            return
        }
        let imgURL = tempDirectory.appendingPathComponent("cached_thumb_test.png")
        try tiffData.write(to: imgURL)
        
        // 1. Initial Generation (Cache Miss)
        let exp1 = expectation(description: "Initial thumbnail generation")
        let startTimeMiss = CFAbsoluteTimeGetCurrent()
        provider.generateThumbnail(for: imgURL, targetSize: CGSize(width: 96, height: 96)) { thumb in
            XCTAssertNotNil(thumb)
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2.0)
        let missDurationMs = (CFAbsoluteTimeGetCurrent() - startTimeMiss) * 1000.0
        
        // 2. Second retrieval (Cache Hit)
        let startTimeHit = CFAbsoluteTimeGetCurrent()
        let cached = provider.cachedThumbnail(for: imgURL, targetSize: CGSize(width: 96, height: 96))
        let hitDurationMs = (CFAbsoluteTimeGetCurrent() - startTimeHit) * 1000.0
        
        NSLog("[EmpiricalTest] Thumbnail Cache Miss: %.2f ms, Cache Hit: %.4f ms", missDurationMs, hitDurationMs)
        
        XCTAssertNotNil(cached, "Thumbnail MUST be retrieved from memory cache")
        XCTAssertLessThan(hitDurationMs, 5.0, "Cache hit retrieval MUST be instantaneous (<5ms)")
    }
    
    /// Test 1.5: Empirical check for image clipboard support in CarbonHotKeyManager.beamCurrentClipboard
    func testCarbonHotKeyBeamClipboardImageDataSupport() {
        let pb = NSPasteboard.general
        pb.clearContents()
        
        let testImage = NSImage(size: NSSize(width: 50, height: 50))
        testImage.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 50, height: 50))
        testImage.unlockFocus()
        
        guard let tiffData = testImage.tiffRepresentation else {
            XCTFail("Failed to create TIFF")
            return
        }
        pb.setData(tiffData, forType: .tiff)
        
        let initialOutboundCount = stagingManager.outboundItems.count
        CarbonHotKeyManager.beamCurrentClipboard(stagingManager: stagingManager)
        
        let mgr = self.stagingManager!
        let exp = expectation(description: "Check if image was staged")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasImageStaged = mgr.outboundItems.contains { $0.type == .screenshot || $0.filename.hasSuffix(".png") }
            NSLog("[EmpiricalTest] beamCurrentClipboard with image data on pasteboard: staged item count = %d (hasImage = %d)",
                  mgr.outboundItems.count - initialOutboundCount, hasImageStaged ? 1 : 0)
            
            // BUG DISCOVERY CHECK:
            // CarbonHotKeyManager only checks URLs and Strings; it omits image pasteboard items entirely!
            if !hasImageStaged {
                NSLog("[EmpiricalTest] BUG CONFIRMED: CarbonHotKeyManager.beamCurrentClipboard does NOT support image data on NSPasteboard!")
            }
            XCTAssertTrue(hasImageStaged, "CarbonHotKeyManager.beamCurrentClipboard MUST support beaming images copied to clipboard (e.g. screenshots)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
    
    /// Test 3.4: Concurrent prompt staging stress (testing collision under concurrency)
    func testStagingConcurrentPromptsThreadSafety() async throws {
        let promptCount = 5
        let mgr = self.stagingManager!
        
        let items = await withTaskGroup(of: StagedItem.self, returning: [StagedItem].self) { group in
            for i in 0..<promptCount {
                group.addTask {
                    return mgr.stageOutboundPrompt(prompt: "Concurrent prompt content \(i)")
                }
            }
            var collected: [StagedItem] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }
        
        XCTAssertEqual(items.count, promptCount, "All 5 prompts must return StagedItems")
        
        let uniqueFilenames = Set(items.map { $0.filename })
        NSLog("[EmpiricalTest] %d concurrent prompts produced %d unique filenames out of %d",
              promptCount, uniqueFilenames.count, promptCount)
        
        // Check disk files
        let fm = FileManager.default
        let diskFiles = (try? fm.contentsOfDirectory(atPath: mgr.outgoingDirectory.path)) ?? []
        NSLog("[EmpiricalTest] Outgoing directory contains %d files on disk out of %d staged: %@",
              diskFiles.count, promptCount, diskFiles.description)
        
        XCTAssertEqual(uniqueFilenames.count, promptCount,
                       "All concurrent prompts must have distinct filenames to avoid disk overwrite collisions!")
    }
}
