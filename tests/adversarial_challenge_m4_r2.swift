import Foundation
import DaylightDropTransport

@main
struct AdversarialChallengeM4R2 {
    static func main() async {
        print("======================================================================")
        print("DAYLIGHT DROP — REVIEWER 1 ADVERSARIAL STRESS TEST (MILESTONE 4 R2)")
        print("======================================================================")

        var totalTests = 0
        var passedTests = 0

        func assertPass(_ name: String, _ condition: Bool, _ details: String = "") {
            totalTests += 1
            if condition {
                passedTests += 1
                print("  [PASS] \(name) \(details)")
            } else {
                print("  [FAIL] \(name) \(details)")
            }
        }

        // ----------------------------------------------------------------------
        // Test 1: Adversarial Filename Sanitization
        // ----------------------------------------------------------------------
        print("\n--- Test Suite 1: Adversarial Filename Sanitization ---")
        let traversal1 = DaylightHTTPServer.sanitizeFilename("../../../../etc/passwd")
        assertPass("Path traversal unix", traversal1 == "passwd", "Result: '\(traversal1)'")

        let traversal2 = DaylightHTTPServer.sanitizeFilename("..\\..\\Windows\\System32\\calc.exe")
        let testDir = URL(fileURLWithPath: "/tmp/incoming")
        let fullURL = testDir.appendingPathComponent(traversal2)
        assertPass("Path traversal windows confined", fullURL.deletingLastPathComponent().path == testDir.path && !traversal2.contains("\\"), "Result: '\(traversal2)'")

        let invalidChars = DaylightHTTPServer.sanitizeFilename("file?with*invalid:chars|and\"quotes<.txt")
        let expectedClean = "file_with_invalid_chars_and_quotes_.txt"
        assertPass("Invalid characters replacement", invalidChars == expectedClean, "Result: '\(invalidChars)'")

        let whitespaceName = DaylightHTTPServer.sanitizeFilename("   document.pdf   \n")
        assertPass("Whitespace trimming", whitespaceName == "document.pdf", "Result: '\(whitespaceName)'")

        let longName = String(repeating: "a", count: 300) + ".txt"
        let sanitizedLong = DaylightHTTPServer.sanitizeFilename(longName)
        assertPass("Filename length truncation (<=255)", sanitizedLong.count <= 255, "Length: \(sanitizedLong.count)")

        // ----------------------------------------------------------------------
        // Test 2: Concurrent Direct commitInboundFile Stress Test (20 Tasks)
        // ----------------------------------------------------------------------
        print("\n--- Test Suite 2: Concurrent Direct commitInboundFile Stress (20 Tasks) ---")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("adv_m4_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let threadCount = 20
        let baseFilename = "concurrent_stress.pdf"
        var threadPayloads: [Int: Data] = [:]
        var threadTempURLs: [Int: URL] = [:]

        for i in 0..<threadCount {
            let payload = "Thread-\(i) distinct payload data: \(UUID().uuidString)\n".data(using: .utf8)!
            threadPayloads[i] = payload
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("temp_\(i)_\(UUID().uuidString).tmp")
            try! payload.write(to: tempFile)
            threadTempURLs[i] = tempFile
        }

        var committedURLs: [Int: URL] = [:]
        let lock = NSLock()

        await withTaskGroup(of: (Int, URL?).self) { group in
            for i in 0..<threadCount {
                let tempURL = threadTempURLs[i]!
                group.addTask {
                    do {
                        let finalURL = try DaylightHTTPServer.commitInboundFile(
                            tempURL: tempURL,
                            directory: tempDir,
                            desiredFilename: baseFilename
                        )
                        return (i, finalURL)
                    } catch {
                        print("  [ERROR] Task \(i) failed to commit: \(error)")
                        return (i, nil)
                    }
                }
            }

            for await (idx, finalURL) in group {
                if let url = finalURL {
                    lock.lock()
                    committedURLs[idx] = url
                    lock.unlock()
                }
            }
        }

        assertPass("All 20 tasks committed successfully", committedURLs.count == threadCount, "Committed: \(committedURLs.count)/\(threadCount)")

        // Verify distinct filenames
        let uniqueCommittedPaths = Set(committedURLs.values.map { $0.path })
        assertPass("All 20 committed files have unique paths", uniqueCommittedPaths.count == threadCount, "Unique: \(uniqueCommittedPaths.count)")

        // Verify all 20 files exist on disk with untouched payload contents
        var allContentsValid = true
        var payloadChecks = 0
        for i in 0..<threadCount {
            if let committedURL = committedURLs[i],
               let dataOnDisk = try? Data(contentsOf: committedURL) {
                if dataOnDisk != threadPayloads[i] {
                    allContentsValid = false
                } else {
                    payloadChecks += 1
                }
            } else {
                allContentsValid = false
            }
        }
        assertPass("All 20 files on disk retain exact distinct contents (zero data loss/corruption)", allContentsValid && payloadChecks == threadCount, "Verified: \(payloadChecks)/\(threadCount)")

        // ----------------------------------------------------------------------
        // Test 3: Disambiguation with Existing Number Gaps
        // ----------------------------------------------------------------------
        print("\n--- Test Suite 3: Disambiguation with Existing Gap ---")
        let gapDir = FileManager.default.temporaryDirectory.appendingPathComponent("adv_gap_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: gapDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gapDir) }

        let orig = gapDir.appendingPathComponent("item.txt")
        let gap2 = gapDir.appendingPathComponent("item (2).txt")
        try! "orig".data(using: .utf8)!.write(to: orig)
        try! "gap2".data(using: .utf8)!.write(to: gap2)

        let newTemp = FileManager.default.temporaryDirectory.appendingPathComponent("tmp_gap.tmp")
        try! "new_item".data(using: .utf8)!.write(to: newTemp)

        let resolvedURL = try! DaylightHTTPServer.commitInboundFile(tempURL: newTemp, directory: gapDir, desiredFilename: "item.txt")
        assertPass("Fills gap with item (1).txt without overwriting item (2).txt", resolvedURL.lastPathComponent == "item (1).txt", "Result: \(resolvedURL.lastPathComponent)")
        assertPass("Existing item (2).txt untouched", (try? String(contentsOf: gap2, encoding: .utf8)) == "gap2")

        // ----------------------------------------------------------------------
        // Test 4: Extensionless and Dotfile Disambiguation
        // ----------------------------------------------------------------------
        print("\n--- Test Suite 4: Extensionless and Dotfiles ---")
        let extDir = FileManager.default.temporaryDirectory.appendingPathComponent("adv_ext_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extDir) }

        let f1 = extDir.appendingPathComponent("README")
        try! "first".data(using: .utf8)!.write(to: f1)
        let t1 = FileManager.default.temporaryDirectory.appendingPathComponent("t1.tmp")
        try! "second".data(using: .utf8)!.write(to: t1)
        let r1 = try! DaylightHTTPServer.commitInboundFile(tempURL: t1, directory: extDir, desiredFilename: "README")
        assertPass("Extensionless disambiguation", r1.lastPathComponent == "README (1)", "Result: \(r1.lastPathComponent)")

        let d1 = extDir.appendingPathComponent(".gitignore")
        try! "first_git".data(using: .utf8)!.write(to: d1)
        let t2 = FileManager.default.temporaryDirectory.appendingPathComponent("t2.tmp")
        try! "second_git".data(using: .utf8)!.write(to: t2)
        let r2 = try! DaylightHTTPServer.commitInboundFile(tempURL: t2, directory: extDir, desiredFilename: ".gitignore")
        assertPass("Dotfile disambiguation", r2.lastPathComponent.contains("(1)"), "Result: \(r2.lastPathComponent)")

        // ----------------------------------------------------------------------
        // Test 5: End-to-End Concurrent HTTP POST Drops to DaylightHTTPServer
        // ----------------------------------------------------------------------
        print("\n--- Test Suite 5: End-to-End Concurrent HTTP POST Drops (10 Clients) ---")
        let srvDir = FileManager.default.temporaryDirectory.appendingPathComponent("adv_srv_test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: srvDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srvDir) }

        let srvPort: UInt16 = 19888
        let server = DaylightHTTPServer(port: srvPort, deviceId: "mac-reviewer-adv", incomingDirectory: srvDir)
        try! server.start()
        try? await Task.sleep(nanoseconds: 200_000_000)

        let client = DaylightHTTPClient(localDeviceId: "dc1-origin-adv")
        let httpDrops = 10
        let httpClashName = "http_collision.txt"
        var httpResponses: [DropSuccessResponse] = []
        let httpLock = NSLock()

        await withTaskGroup(of: DropSuccessResponse?.self) { group in
            for idx in 0..<httpDrops {
                group.addTask {
                    let clientTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cli_\(idx)_\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: clientTempDir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: clientTempDir) }

                    let sourceFile = clientTempDir.appendingPathComponent(httpClashName)
                    let content = "HTTP Client-\(idx) content: \(UUID().uuidString)\n".data(using: .utf8)!
                    try! content.write(to: sourceFile)

                    do {
                        let resp = try await client.sendDrop(
                            fileURL: sourceFile,
                            type: "document",
                            origin: "dc1-origin-adv",
                            transferId: "tx-adv-\(idx)-\(UUID().uuidString)",
                            targetHost: "127.0.0.1",
                            targetPort: srvPort
                        )
                        return resp
                    } catch {
                        print("  [ERROR] HTTP Client \(idx) error: \(error)")
                        return nil
                    }
                }
            }

            for await resp in group {
                if let r = resp {
                    httpLock.lock()
                    httpResponses.append(r)
                    httpLock.unlock()
                }
            }
        }

        server.stop()

        assertPass("All 10 HTTP drops succeeded with status 'ok'", httpResponses.filter { $0.status == "ok" }.count == httpDrops, "Success count: \(httpResponses.count)/\(httpDrops)")

        let assignedFilenames = httpResponses.compactMap { $0.filename }
        let uniqueAssigned = Set(assignedFilenames)
        assertPass("All 10 HTTP drops assigned unique filenames", uniqueAssigned.count == httpDrops, "Assigned: \(assignedFilenames.sorted())")

        let diskFiles = (try? FileManager.default.contentsOfDirectory(atPath: srvDir.path)) ?? []
        assertPass("Exactly 10 files exist on disk in incoming directory", diskFiles.count == httpDrops, "Files found: \(diskFiles.sorted())")

        // ----------------------------------------------------------------------
        // Final Summary
        // ----------------------------------------------------------------------
        print("\n======================================================================")
        print("ADVERSARIAL STRESS TEST SUMMARY:")
        print("Total Tests: \(totalTests)")
        print("Passed     : \(passedTests)")
        print("Failed     : \(totalTests - passedTests)")
        print("======================================================================")

        if totalTests == passedTests {
            print("OVERALL ADVERSARIAL VERDICT: APPROVE (100% Pass)\n")
        } else {
            print("OVERALL ADVERSARIAL VERDICT: REQUEST_CHANGES\n")
            exit(1)
        }
    }
}
