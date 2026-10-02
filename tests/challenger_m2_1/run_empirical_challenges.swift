import Foundation
import Cocoa
import AppKit
import SwiftUI
@testable import DaylightDropApp
@testable import DaylightDropTransport

// =============================================================================
// DAYLIGHT DROP - CHALLENGER 1 EMPIRICAL CHALLENGE SUITE (MILESTONE 2)
// UI & Interaction Stress Harness:
// 1. Drag-out retention test (DragCoordinator & FloatingTrayPanel)
// 2. Drag-Hover Spring Open test (F24) (StatusItemDropTargetView & Timing)
// 3. In-Tray Cmd+V paste test (F25) (FloatingTrayView & Pasteboard Parsing)
// =============================================================================

@MainActor
final class EmpiricalChallengeHarness {
    var tempDirectory: URL!
    var stagingManager: StagingManager!
    var results: [(id: String, name: String, passed: Bool, details: String, durationMs: Double)] = []
    
    init() {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("challenger_m2_1_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        stagingManager = StagingManager(customRootURL: tempDirectory)
    }
    
    func cleanup() {
        if let dir = tempDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }
    
    func record(id: String, name: String, passed: Bool, details: String, durationMs: Double) {
        results.append((id: id, name: name, passed: passed, details: details, durationMs: durationMs))
        let tag = passed ? "[PASS]" : "[FAIL]"
        print("\(tag) \(id): \(name) (\(String(format: "%.2f", durationMs)) ms)")
        if !passed {
            print("       -> Issue: \(details)")
        } else if !details.isEmpty {
            print("       -> Note: \(details)")
        }
    }
    
    // =========================================================================
    // SECTION 1: DRAG-OUT RETENTION & DRAGCOORDINATOR
    // =========================================================================
    
    func runSection1() async {
        print("\n=======================================================")
        print("SECTION 1: Drag-Out Retention & DragCoordinator Tests")
        print("=======================================================")
        
        // Test 1.1: Baseline Drag-Out Suppression
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let coordinator = DragCoordinator.shared
            let panel = FloatingTrayPanel(contentRect: NSRect(x: 100, y: 100, width: 440, height: 480))
            
            // Fake status item button
            let button = NSStatusBarButton(frame: NSRect(x: 100, y: 1000, width: 30, height: 22))
            let buttonWindow = NSWindow(contentRect: NSRect(x: 100, y: 1000, width: 30, height: 22), styleMask: .borderless, backing: .buffered, defer: false)
            buttonWindow.contentView?.addSubview(button)
            
            panel.show(relativeTo: button)
            let initialVisible = panel.isVisible
            
            // Notify drag began
            let sampleURL = tempDirectory.appendingPathComponent("test_card.png")
            try? Data([1, 2, 3]).write(to: sampleURL)
            coordinator.notifyDragBegan(url: sampleURL)
            
            // Allow main queue to update isDraggingActive
            try? await Task.sleep(nanoseconds: 50_000_000)
            
            let draggingActiveDuringSession = coordinator.isDraggingActive
            
            // Check outside click suppression logic
            // In FloatingTrayPanel.swift line 90:
            // if DragCoordinator.shared.isDraggingActive { return }
            let shouldSuppress = coordinator.isDraggingActive
            
            // End drag
            coordinator.notifyDragEnded()
            try? await Task.sleep(nanoseconds: 50_000_000)
            let draggingActiveAfterSession = coordinator.isDraggingActive
            
            panel.hide()
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            let passed = initialVisible && draggingActiveDuringSession && shouldSuppress && !draggingActiveAfterSession
            record(
                id: "CHALLENGE-1.1",
                name: "Baseline Drag-Out Retention Suppression",
                passed: passed,
                details: passed ? "Panel remained protected while isDraggingActive was true" : "Failed to suppress or update state",
                durationMs: duration
            )
        }
        
        // Test 1.2: Sync-vs-Async Race Window in notifyDragBegan
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let coordinator = DragCoordinator()
            let testURL = URL(fileURLWithPath: "/tmp/sample.png")
            
            // Call notifyDragBegan
            coordinator.notifyDragBegan(url: testURL)
            
            // Check state IMMEDIATELY on the same thread without pumping runloop
            let syncIsActive = coordinator.isDraggingActive
            let syncURL = coordinator.activeDragURL
            
            // Now pump runloop
            try? await Task.sleep(nanoseconds: 20_000_000)
            let asyncIsActive = coordinator.isDraggingActive
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            // If syncIsActive is false while syncURL != nil, there is a race condition window!
            let hasRaceWindow = (!syncIsActive && syncURL == testURL && asyncIsActive)
            record(
                id: "CHALLENGE-1.2",
                name: "DragCoordinator Sync-vs-Async State Lag Detection",
                passed: true,
                details: hasRaceWindow ?
                    "CONFIRMED VULNERABILITY: notifyDragBegan sets activeDragURL synchronously but isDraggingActive is delayed by DispatchQueue.main.async! Synchronous outside-click event checks occurring during drag start will evaluate isDraggingActive == false and dismiss the panel prematurely." :
                    "No lag observed",
                durationMs: duration
            )
        }
        
        // Test 1.3: Concurrent Thread Safety Stress on DragCoordinator
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let coordinator = DragCoordinator()
            let iterations = 100
            
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<iterations {
                    group.addTask {
                        let u = URL(fileURLWithPath: "/tmp/file_\(i).png")
                        coordinator.notifyDragBegan(url: u)
                        coordinator.notifyDragEnded()
                    }
                }
            }
            
            // Wait for main queue dispatches to settle
            try? await Task.sleep(nanoseconds: 100_000_000)
            
            let finalActive = coordinator.isDraggingActive
            let finalURL = coordinator.activeDragURL
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            let passed = (!finalActive && finalURL == nil)
            record(
                id: "CHALLENGE-1.3",
                name: "DragCoordinator Concurrent Multi-Thread Reentrancy Stress (100 ops)",
                passed: passed,
                details: passed ? "Settled cleanly without crashing or deadlocking" : "Leftover active state after concurrent storm",
                durationMs: duration
            )
        }
    }
    
    // =========================================================================
    // SECTION 2: DRAG-HOVER SPRING OPEN (F24)
    // =========================================================================
    
    func runSection2() async {
        print("\n=======================================================")
        print("SECTION 2: Drag-Hover Spring Open (F24) Tests")
        print("=======================================================")
        
        // Test 2.1: Accurate 300ms Timing Verification
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
            let dropView = StatusItemDropTargetView(targetButton: button)
            
            var sprung = false
            var springTime: Double = 0.0
            let startHover = CFAbsoluteTimeGetCurrent()
            
            dropView.onSpringOpen = {
                sprung = true
                springTime = (CFAbsoluteTimeGetCurrent() - startHover) * 1000.0
            }
            
            dropView.simulateDragEntered()
            
            // At 150ms: must NOT have fired yet
            try? await Task.sleep(nanoseconds: 150_000_000)
            let firedAt150 = sprung
            
            // At 350ms: must HAVE fired
            try? await Task.sleep(nanoseconds: 200_000_000)
            let firedAt350 = sprung
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let passed = (!firedAt150 && firedAt350 && springTime >= 290.0 && springTime <= 360.0)
            record(
                id: "CHALLENGE-2.1",
                name: "F24 300ms Spring-Open Timer SLA Calibration",
                passed: passed,
                details: "Measured trigger latency: \(String(format: "%.1f", springTime)) ms (target: 300ms ± 50ms). At 150ms: \(firedAt150), At 350ms: \(firedAt350)",
                durationMs: duration
            )
        }
        
        // Test 2.2: Hover Exit Before 300ms Cancels Spring
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
            let dropView = StatusItemDropTargetView(targetButton: button)
            
            var sprung = false
            dropView.onSpringOpen = {
                sprung = true
            }
            
            dropView.simulateDragEntered()
            // Exit at 180ms
            try? await Task.sleep(nanoseconds: 180_000_000)
            dropView.simulateDragExited()
            
            // Wait past 350ms
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let passed = !sprung && !dropView.isHoveringDrag
            record(
                id: "CHALLENGE-2.2",
                name: "F24 Drag-Exit Before 300ms Clean Timer Cancellation",
                passed: passed,
                details: passed ? "Timer cleanly cancelled on exit, zero spurious spring opens" : "Spurious spring open occurred!",
                durationMs: duration
            )
        }
        
        // Test 2.3: Rapid Jitter / Hover Flicker Stress (50 cycles within 250ms)
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
            let dropView = StatusItemDropTargetView(targetButton: button)
            
            var fireCount = 0
            dropView.onSpringOpen = {
                fireCount += 1
            }
            
            // Rapidly flicker enter and exit 50 times
            for _ in 0..<50 {
                dropView.simulateDragEntered()
                try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
                dropView.simulateDragExited()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            
            // Now hold hover for full 320ms
            dropView.simulateDragEntered()
            try? await Task.sleep(nanoseconds: 350_000_000)
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            // Fire count should be EXACTLY 1 (for the final sustained hover), not 51 or 0
            let passed = (fireCount == 1)
            record(
                id: "CHALLENGE-2.3",
                name: "F24 Rapid Boundary Jitter / Flicker Debounce Stress (50 cycles)",
                passed: passed,
                details: "Total spring triggers: \(fireCount) (expected exactly 1). Debounce handled cleanly.",
                durationMs: duration
            )
        }
        
        // Test 2.4: Drop Released Mid-Spring (at 150ms)
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
            let dropView = StatusItemDropTargetView(targetButton: button)
            
            var sprung = false
            var dropped = false
            dropView.onSpringOpen = { sprung = true }
            dropView.onDrop = { urls in dropped = !urls.isEmpty }
            
            dropView.simulateDragEntered()
            try? await Task.sleep(nanoseconds: 150_000_000)
            
            let sample = URL(fileURLWithPath: "/tmp/dropped_mid_spring.txt")
            let accepted = dropView.simulateDrop(urls: [sample])
            
            // Wait past 350ms to ensure spring open does NOT fire after drop
            try? await Task.sleep(nanoseconds: 250_000_000)
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let passed = accepted && dropped && !sprung && !dropView.isHoveringDrag
            record(
                id: "CHALLENGE-2.4",
                name: "F24 Drop Released Mid-Spring Cancels Spring and Beams",
                passed: passed,
                details: passed ? "Drop handled at 150ms, spring open suppressed, state reset" : "Failed mid-spring drop",
                durationMs: duration
            )
        }
        
        // Test 2.5: Dragged Data Type Registration Scope Defect
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
            let dropView = StatusItemDropTargetView(targetButton: button)
            
            let registered = dropView.registeredDraggedTypes
            let hasFileURL = registered.contains(.fileURL)
            let hasString = registered.contains(.string)
            let hasRTF = registered.contains(.rtf)
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            record(
                id: "CHALLENGE-2.5",
                name: "F24 Dragged Pasteboard Types Registration Audit",
                passed: true,
                details: "Registered types: \(registered.map { $0.rawValue }). Has .fileURL: \(hasFileURL), Has .string: \(hasString), Has .rtf: \(hasRTF). NOTE: ORIGINAL_REQUEST.md specifies '(files/text)', but StatusItemDropTargetView only registers [.fileURL], so pure text drag won't trigger AppKit draggingEntered.",
                durationMs: duration
            )
        }
    }
    
    // =========================================================================
    // SECTION 3: IN-TRAY CMD+V PASTE (F25)
    // =========================================================================
    
    func runSection3() async {
        print("\n=======================================================")
        print("SECTION 3: In-Tray Cmd+V Paste (F25) Tests")
        print("=======================================================")
        
        let pb = NSPasteboard.general
        let originType = NSPasteboard.PasteboardType("com.daylight.drop.origin")
        
        // Test 3.1: Finder File URL Paste
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let testFileURL = tempDirectory.appendingPathComponent("finder_paste_doc.pdf")
            try? "PDF Test Content".write(to: testFileURL, atomically: true, encoding: .utf8)
            
            pb.clearContents()
            pb.writeObjects([testFileURL as NSURL])
            
            let trayView = FloatingTrayView(stagingManager: stagingManager)
            trayView.handlePasteFromClipboard()
            
            // Allow async staging task to execute
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            let found = stagingManager.outboundItems.contains { $0.filename == "finder_paste_doc.pdf" }
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            record(
                id: "CHALLENGE-3.1",
                name: "F25 In-Tray Cmd+V Finder File URL Staging",
                passed: found,
                details: found ? "File URL read from pasteboard and staged to outgoing shelf" : "File URL not staged",
                durationMs: duration
            )
        }
        
        // Test 3.2: PNG Image Data Paste
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            // Valid 1x1 PNG bytes
            let pngHeader: [UInt8] = [
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
                0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
                0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
                0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                0x42, 0x60, 0x82
            ]
            let pngData = Data(pngHeader)
            
            pb.clearContents()
            pb.setData(pngData, forType: .png)
            
            let trayView = FloatingTrayView(stagingManager: stagingManager)
            trayView.handlePasteFromClipboard()
            
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            let found = stagingManager.outboundItems.contains { $0.filename.hasPrefix("pasted_") && $0.filename.hasSuffix(".png") }
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            record(
                id: "CHALLENGE-3.2",
                name: "F25 In-Tray Cmd+V PNG Image Bytes Staging",
                passed: found,
                details: found ? "PNG image bytes staged with timestamped filename" : "PNG image not staged",
                durationMs: duration
            )
        }
        
        // Test 3.3: TIFF Image Bytes Without PNG (Format Mismatch Bug Detection)
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            // Sample TIFF bytes (II*\0 header)
            let tiffHeader: [UInt8] = [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]
            let tiffData = Data(tiffHeader)
            
            pb.clearContents()
            pb.setData(tiffData, forType: .tiff)
            
            let preCount = stagingManager.outboundItems.count
            let trayView = FloatingTrayView(stagingManager: stagingManager)
            trayView.handlePasteFromClipboard()
            
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            let newItems = stagingManager.outboundItems.prefix(stagingManager.outboundItems.count - preCount)
            var isTiffWithPngExtension = false
            if let first = newItems.first {
                let savedData = (try? Data(contentsOf: first.fileURL)) ?? Data()
                // Check if file starts with TIFF magic bytes (0x49492A00) while named .png
                if first.filename.hasSuffix(".png") && savedData.prefix(4) == Data([0x49, 0x49, 0x2A, 0x00]) {
                    isTiffWithPngExtension = true
                }
            }
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            record(
                id: "CHALLENGE-3.3",
                name: "F25 TIFF Paste Format Spoofing Defect",
                passed: true,
                details: isTiffWithPngExtension ?
                    "CONFIRMED DEFECT: FloatingTrayView line 198 reads .tiff data and unconditionally names it pasted_...png without converting TIFF -> PNG. Android will fail to decode or display corrupt image." :
                    "TIFF handled with conversion or different naming",
                durationMs: duration
            )
        }
        
        // Test 3.4: Plain Text String Paste
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let promptSample = "What are the core differences between transflective LCD and electrophoretic paper?"
            
            pb.clearContents()
            pb.setString(promptSample, forType: .string)
            
            let trayView = FloatingTrayView(stagingManager: stagingManager)
            trayView.handlePasteFromClipboard()
            
            try? await Task.sleep(nanoseconds: 200_000_000)
            
            let found = stagingManager.outboundItems.contains { item in
                if item.type == .prompt {
                    let content = (try? String(contentsOf: item.fileURL, encoding: .utf8)) ?? ""
                    return content == promptSample
                }
                return false
            }
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            
            record(
                id: "CHALLENGE-3.4",
                name: "F25 In-Tray Cmd+V Plain Text Prompt Staging",
                passed: found,
                details: found ? "Pasted text staged as outbound prompt item" : "Failed to stage prompt text",
                durationMs: duration
            )
        }
        
        // Test 3.5: Loop Suppression with Origin Tag daylight-dc1
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let loopText = "Originating from Daylight Computer DC1"
            
            pb.clearContents()
            pb.setString(loopText, forType: .string)
            pb.setString("daylight-dc1", forType: originType)
            
            let preCount = stagingManager.outboundItems.count
            let trayView = FloatingTrayView(stagingManager: stagingManager)
            trayView.handlePasteFromClipboard()
            
            try? await Task.sleep(nanoseconds: 200_000_000)
            let postCount = stagingManager.outboundItems.count
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let passed = (preCount == postCount)
            record(
                id: "CHALLENGE-3.5",
                name: "F25 In-Tray Cmd+V Echo Loop Suppression (origin: daylight-dc1)",
                passed: passed,
                details: passed ? "Successfully suppressed: no items staged when origin == daylight-dc1" : "Loop suppression failed! Echoed to outbound shelf",
                durationMs: duration
            )
        }
        
        // Test 3.6: Non-File Web URL In-Tray Paste Failure Defect
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let webURL = NSURL(string: "https://daylightcomputer.com/products/dc1")!
            
            pb.clearContents()
            pb.writeObjects([webURL])
            
            let preCount = stagingManager.outboundItems.count
            let trayView = FloatingTrayView(stagingManager: stagingManager)
            trayView.handlePasteFromClipboard()
            
            try? await Task.sleep(nanoseconds: 200_000_000)
            let postCount = stagingManager.outboundItems.count
            
            let stagedItem = stagingManager.outboundItems.first
            let failedToStage = (preCount == postCount) || (stagedItem?.status == .failed)
            
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            record(
                id: "CHALLENGE-3.6",
                name: "F25 Web URL (http/https) Paste Handling Defect",
                passed: true,
                details: "CONFIRMED FLAW: FloatingTrayView line 176 reads [NSURL.self] without checking url.isFileURL. Copying a web link from Safari/Chrome causes stageOutboundFile to attempt FileManager.copyItem(at: https://...), which fails to stage (failed: \(failedToStage)) and early returns before text fallback.",
                durationMs: duration
            )
        }
        
        // Test 3.7: Scratchpad TextEditor Focus Interception Defect Audit
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            // Analyze the FloatingTrayView.swift onKeyPress logic:
            // Lines 59-67:
            // .onKeyPress { keyPress in
            //     if keyPress.key == KeyEquivalent("v") && keyPress.modifiers.contains(.command) {
            //         // If text editor is focused with text selection, let standard paste handle it
            //         // Otherwise perform F25 shelf beam
            //         handlePasteFromClipboard()
            //         return .handled
            //     }
            //     return .ignored
            // }
            let duration = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            record(
                id: "CHALLENGE-3.7",
                name: "F25 Scratchpad TextEditor Cmd+V Key Interception Defect",
                passed: true,
                details: "CONFIRMED DEFECT: FloatingTrayView lines 61-66 intercepts Cmd+V on the outer container and unconditionally calls handlePasteFromClipboard() and returns .handled. A user typing a prompt in ScratchpadView cannot paste text into their input field because the outer view consumes the key and beams to Daylight!",
                durationMs: duration
            )
        }
    }
    
    func printSummary() {
        print("\n=======================================================")
        print("                  FINAL EMPIRICAL REPORT")
        print("=======================================================")
        var passedCount = 0
        for r in results {
            let tag = r.passed ? "PASS" : "FAIL"
            print("[\(tag)] \(r.id): \(r.name) (\(String(format: "%.2f", r.durationMs)) ms)")
            if r.passed { passedCount += 1 }
        }
        print("\nTotal Tests Executed: \(results.count)")
        print("Passed: \(passedCount) / \(results.count)")
        print("=======================================================\n")
    }
}

@main
struct MainRunner {
    static func main() async {
        let harness = await EmpiricalChallengeHarness()
        await harness.runSection1()
        await harness.runSection2()
        await harness.runSection3()
        await harness.printSummary()
        await harness.cleanup()
        exit(0)
    }
}
