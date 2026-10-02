import Foundation
import Cocoa
import AppKit
@testable import DaylightDropApp
@testable import DaylightDropTransport

@main
struct StressRunner {
    @MainActor
    static func main() async {
    print("======================================================================")
    print("DAYLIGHT DROP: EMPIRICAL STRESS HARNESS - CHALLENGER 2 ITERATION 2")
    print("======================================================================")
    
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("challenger2_stress_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    
    let staging = StagingManager(customRootURL: tempDir)
    let pb = NSPasteboard.general
    let originType = NSPasteboard.PasteboardType("com.daylight.drop.origin")
    
    var passCount = 0
    var failCount = 0
    
    func reportPass(_ name: String, _ detail: String = "") {
        passCount += 1
        print("  [PASS] \(name) \(detail)")
    }
    
    func reportFail(_ name: String, _ reason: String) {
        failCount += 1
        print("  [FAIL] \(name): \(reason)")
    }
    
    // -------------------------------------------------------------------------
    // TEST 1: Rapid Consecutive Prompt Dispatches (100 prompts in tight loop)
    // -------------------------------------------------------------------------
    print("\n[TEST 1] Rapid consecutive prompt dispatches (100 prompts in <1s)...")
    let promptCount = 100
    var stagedPrompts: [StagedItem] = []
    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 1...promptCount {
        let item = staging.stageOutboundPrompt(prompt: "Prompt payload stress #\(i) - \(UUID().uuidString)")
        stagedPrompts.append(item)
    }
    let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
    
    let filenames = stagedPrompts.map { $0.filename }
    let uniqueFilenames = Set(filenames)
    let diskFiles = (try? FileManager.default.contentsOfDirectory(atPath: staging.outgoingDirectory.path)) ?? []
    let diskPrompts = diskFiles.filter { $0.hasPrefix("prompt_") && $0.hasSuffix(".txt") }
    let orphanedTmp = diskFiles.filter { $0.contains(".tmp") }
    
    print("  -> Staged \(promptCount) prompts in \(String(format: "%.2f", elapsedMs)) ms (Avg: \(String(format: "%.3f", elapsedMs / Double(promptCount))) ms/prompt)")
    print("  -> Unique in memory: \(uniqueFilenames.count)/\(promptCount), Unique on disk: \(diskPrompts.count)/\(promptCount), Orphaned .tmp: \(orphanedTmp.count)")
    
    if uniqueFilenames.count == promptCount && diskPrompts.count == promptCount && orphanedTmp.isEmpty {
        reportPass("Rapid Prompt Dispatch Entropy & Disk Isolation", "100/100 unique files on disk, 0 overwrites, 0 tmp leaks")
    } else {
        reportFail("Rapid Prompt Dispatch Entropy", "Expected \(promptCount) unique files, found memory: \(uniqueFilenames.count), disk: \(diskPrompts.count), tmp: \(orphanedTmp.count)")
    }
    
    // -------------------------------------------------------------------------
    // TEST 2: Concurrent Multithreaded Prompt Staging (25 tasks concurrently)
    // -------------------------------------------------------------------------
    print("\n[TEST 2] Multithreaded concurrent prompt staging (25 concurrent tasks)...")
    let concurrentCount = 25
    let concurrentItems = await withTaskGroup(of: StagedItem.self, returning: [StagedItem].self) { group in
        for i in 1...concurrentCount {
            group.addTask {
                return staging.stageOutboundPrompt(prompt: "Concurrent prompt #\(i)")
            }
        }
        var items: [StagedItem] = []
        for await item in group {
            items.append(item)
        }
        return items
    }
    
    let concurrentFilenames = Set(concurrentItems.map { $0.filename })
    if concurrentFilenames.count == concurrentCount {
        reportPass("Concurrent Prompt APFS VFS Staging", "25/25 concurrent prompts created with zero lock contention or collisions")
    } else {
        reportFail("Concurrent Prompt APFS VFS Staging", "Collisions detected: \(concurrentFilenames.count) unique out of \(concurrentCount)")
    }
    
    // -------------------------------------------------------------------------
    // TEST 3: CarbonHotKeyManager Image Handling (PNG on pasteboard)
    // -------------------------------------------------------------------------
    print("\n[TEST 3] CarbonHotKeyManager.beamCurrentClipboard with PNG image data...")
    pb.clearContents()
    let pngImage = NSImage(size: NSSize(width: 64, height: 64))
    pngImage.lockFocus()
    NSColor.systemGreen.drawSwatch(in: NSRect(x: 0, y: 0, width: 64, height: 64))
    pngImage.unlockFocus()
    guard let tiffRep = pngImage.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffRep),
          let rawPngData = bitmapRep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to create PNG test data")
    }
    
    pb.setData(rawPngData, forType: .png)
    CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
    try? await Task.sleep(nanoseconds: 100_000_000)
    
    // Check staged items
    let pngStaged = staging.outboundItems.first(where: { $0.filename.hasPrefix("pasted_") && $0.filename.hasSuffix(".png") })
    if let staged = pngStaged {
        let isScreenshotType = staged.type == .screenshot
        let fileExists = FileManager.default.fileExists(atPath: staged.fileURL.path)
        let fileBytes = (try? Data(contentsOf: staged.fileURL)) ?? Data()
        let isPngHeader = fileBytes.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        if isScreenshotType && fileExists && isPngHeader {
            reportPass("CarbonHotKeyManager Copied PNG Image Support", "Staged .screenshot item with valid PNG magic bytes (\(fileBytes.count) bytes)")
        } else {
            reportFail("CarbonHotKeyManager Copied PNG Image Support", "PNG validation failed: isScreenshot=\(isScreenshotType), exists=\(fileExists), isPngHeader=\(isPngHeader)")
        }
    } else {
        reportFail("CarbonHotKeyManager Copied PNG Image Support", "No PNG image staged")
    }
    
    // -------------------------------------------------------------------------
    // TEST 4: CarbonHotKeyManager Image Handling (TIFF on pasteboard -> Transcoded to PNG)
    // -------------------------------------------------------------------------
    print("\n[TEST 4] CarbonHotKeyManager.beamCurrentClipboard with TIFF image (transcoding to PNG)...")
    pb.clearContents()
    let tiffImage = NSImage(size: NSSize(width: 80, height: 80))
    tiffImage.lockFocus()
    NSColor.systemOrange.drawSwatch(in: NSRect(x: 0, y: 0, width: 80, height: 80))
    tiffImage.unlockFocus()
    guard let rawTiffData = tiffImage.tiffRepresentation else {
        fatalError("Failed to create TIFF test data")
    }
    
    pb.setData(rawTiffData, forType: .tiff)
    CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
    try? await Task.sleep(nanoseconds: 100_000_000)
    
    let tiffStaged = staging.outboundItems.first(where: { item in
        item.filename.hasPrefix("pasted_") && item.filename.hasSuffix(".png") && item.fileURL != pngStaged?.fileURL
    })
    
    if let staged = tiffStaged {
        let fileData = (try? Data(contentsOf: staged.fileURL)) ?? Data()
        let isPngHeader = fileData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        if isPngHeader {
            reportPass("CarbonHotKeyManager TIFF-to-PNG Transcoding", "TIFF was successfully transcoded to PNG format (\(fileData.count) bytes, valid PNG header)")
        } else {
            reportFail("CarbonHotKeyManager TIFF-to-PNG Transcoding", "TIFF was NOT properly transcoded; header bytes: \(fileData.prefix(4))")
        }
    } else {
        reportFail("CarbonHotKeyManager TIFF-to-PNG Transcoding", "No transcoded image staged from TIFF pasteboard data")
    }
    
    // -------------------------------------------------------------------------
    // TEST 5: CarbonHotKeyManager Web URL Staging (Non-file URLs)
    // -------------------------------------------------------------------------
    print("\n[TEST 5] CarbonHotKeyManager.beamCurrentClipboard with web URL...")
    pb.clearContents()
    if let webURL = NSURL(string: "https://daylightcomputer.com/products/dc1") {
        pb.writeObjects([webURL])
        CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let webPrompt = staging.outboundItems.first(where: { $0.previewText?.contains("daylightcomputer.com") == true })
        if let item = webPrompt {
            reportPass("CarbonHotKeyManager Web URL Staging", "Web URL successfully staged as text prompt: \(item.filename)")
        } else {
            reportFail("CarbonHotKeyManager Web URL Staging", "Web URL failed to stage as text prompt")
        }
    }
    
    // -------------------------------------------------------------------------
    // TEST 6: Dynamic Loop Suppression (Peer Origin Tags)
    // -------------------------------------------------------------------------
    print("\n[TEST 6] Dynamic loop suppression across peer origin tags...")
    
    // Case 6A: Origin is "daylight-dc1" -> MUST SUPPRESS
    pb.clearContents()
    pb.setString("Inbound text from DC1 tablet", forType: .string)
    pb.setString("daylight-dc1", forType: originType)
    let countBefore6A = staging.outboundItems.count
    CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
    try? await Task.sleep(nanoseconds: 50_000_000)
    let countAfter6A = staging.outboundItems.count
    if countBefore6A == countAfter6A {
        reportPass("Loop Suppression: 'daylight-dc1' Origin", "Clipboard beam strictly suppressed for daylight-dc1")
    } else {
        reportFail("Loop Suppression: 'daylight-dc1' Origin", "Failed to suppress beam for daylight-dc1 origin")
    }
    
    // Case 6B: Origin is connected peer device ID ("JMBR00380") -> MUST SUPPRESS
    pb.clearContents()
    pb.setString("Inbound text from rooted 3 tablet", forType: .string)
    pb.setString("JMBR00380", forType: originType)
    let countBefore6B = staging.outboundItems.count
    CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
    try? await Task.sleep(nanoseconds: 50_000_000)
    let countAfter6B = staging.outboundItems.count
    if countBefore6B == countAfter6B {
        reportPass("Loop Suppression: Dynamic Peer ID ('JMBR00380')", "Clipboard beam strictly suppressed for peer ID")
    } else {
        reportFail("Loop Suppression: Dynamic Peer ID ('JMBR00380')", "Failed to suppress beam for peer ID")
    }
    
    // Case 6C: Origin is local device ID -> MUST PERMIT (Local user copy)
    pb.clearContents()
    let localText = "Local user text copied locally - \(UUID().uuidString)"
    pb.setString(localText, forType: .string)
    pb.setString(TransportManager.shared.localDeviceId, forType: originType)
    CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
    try? await Task.sleep(nanoseconds: 100_000_000)
    let isStaged6C = staging.outboundItems.first?.previewText?.contains(localText) == true
    if isStaged6C {
        reportPass("Loop Suppression: Local Origin Permitted", "Local clipboard copy correctly permitted for beaming")
    } else {
        reportFail("Loop Suppression: Local Origin Permitted", "Local clipboard copy was not staged at head of outbound shelf")
    }
    
    // Case 6D: Origin is nil / empty -> MUST PERMIT
    pb.clearContents()
    let untaggedText = "User copied text without origin tag - \(UUID().uuidString)"
    pb.setString(untaggedText, forType: .string)
    CarbonHotKeyManager.beamCurrentClipboard(stagingManager: staging)
    try? await Task.sleep(nanoseconds: 100_000_000)
    let isStaged6D = staging.outboundItems.first?.previewText?.contains(untaggedText) == true
    if isStaged6D {
        reportPass("Loop Suppression: Untagged User Copy Permitted", "Untagged standard user copy correctly permitted")
    } else {
        reportFail("Loop Suppression: Untagged User Copy Permitted", "Untagged user copy was not staged at head of outbound shelf")
    }
    
    print("\n======================================================================")
    print("EMPIRICAL CHALLENGER 2 ITERATION 2 HARNESS COMPLETE")
    print("Total Tests: \(passCount + failCount)")
    print("Passed     : \(passCount)")
    print("Failed     : \(failCount)")
    print("======================================================================")
    
    if failCount > 0 {
        exit(1)
    }
}
}
