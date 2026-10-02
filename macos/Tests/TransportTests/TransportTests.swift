import XCTest
import Foundation
import CryptoKit
@testable import DaylightDropTransport

final class TransportTests: XCTestCase {
    
    // MARK: - 1. Protocol Constants Tests
    
    func testProtocolConstants() {
        XCTAssertEqual(ProtocolConstants.protocolVersion, "1.0")
        XCTAssertEqual(ProtocolConstants.macPort, 8765)
        XCTAssertEqual(ProtocolConstants.androidPort, 8766)
        XCTAssertEqual(ProtocolConstants.adbDaemonPort, 5037)
        XCTAssertEqual(ProtocolConstants.serviceType, "_daylightdrop._tcp")
        XCTAssertEqual(ProtocolConstants.serviceTypeWithDot, "_daylightdrop._tcp.")
        
        XCTAssertEqual(ProtocolConstants.healthEndpoint, "/api/health")
        XCTAssertEqual(ProtocolConstants.dropEndpoint, "/api/drop")
        XCTAssertEqual(ProtocolConstants.textEndpoint, "/api/text")
        XCTAssertEqual(ProtocolConstants.webSocketEndpoint, "/api/ws")
        
        XCTAssertEqual(ProtocolConstants.headerDropId, "X-Daylight-Drop-Id")
        XCTAssertEqual(ProtocolConstants.headerDropType, "X-Daylight-Drop-Type")
        XCTAssertEqual(ProtocolConstants.headerDropFilename, "X-Daylight-Drop-Filename")
        XCTAssertEqual(ProtocolConstants.headerDropSha256, "X-Daylight-Drop-Sha256")
        XCTAssertEqual(ProtocolConstants.headerDropOrigin, "X-Daylight-Drop-Origin")
        
        XCTAssertEqual(ProtocolConstants.originPasteboardType, "com.daylight.drop.origin")
    }
    
    // MARK: - 2. Loop Suppression Tests
    
    func testLoopSuppressionOrigin() {
        let engine = LoopSuppressionEngine(localDeviceId: "mac-12345")
        XCTAssertTrue(engine.isOriginSelf("mac-12345"))
        XCTAssertFalse(engine.isOriginSelf("dc1-67890"))
        XCTAssertFalse(engine.isOriginSelf(""))
    }
    
    func testLoopSuppressionLRUAndTTL() {
        let engine = LoopSuppressionEngine(localDeviceId: "mac-12345", capacity: 3, ttl: 2.0)
        let now = Date()
        
        let text1 = "Hello Daylight"
        let hash1 = LoopSuppressionEngine.computeSha256(text: text1)
        
        // Before recording: should not suppress
        XCTAssertFalse(engine.shouldSuppress(hash: hash1, at: now))
        
        // Record hash1
        engine.record(hash: hash1, at: now)
        XCTAssertTrue(engine.shouldSuppress(hash: hash1, at: now))
        XCTAssertTrue(engine.shouldSuppress(text: text1, at: now))
        
        // Add hash2 and hash3
        let hash2 = LoopSuppressionEngine.computeSha256(text: "Text 2")
        let hash3 = LoopSuppressionEngine.computeSha256(text: "Text 3")
        engine.record(hash: hash2, at: now)
        engine.record(hash: hash3, at: now)
        XCTAssertEqual(engine.currentCacheCount(), 3)
        
        // Add hash4 -> triggers LRU eviction of hash1
        let hash4 = LoopSuppressionEngine.computeSha256(text: "Text 4")
        engine.record(hash: hash4, at: now)
        XCTAssertEqual(engine.currentCacheCount(), 3)
        XCTAssertFalse(engine.shouldSuppress(hash: hash1, at: now), "Oldest item hash1 should be evicted")
        XCTAssertTrue(engine.shouldSuppress(hash: hash2, at: now))
        XCTAssertTrue(engine.shouldSuppress(hash: hash4, at: now))
        
        // Test TTL expiration (advance time by 3 seconds)
        let futureDate = now.addingTimeInterval(3.0)
        XCTAssertFalse(engine.shouldSuppress(hash: hash4, at: futureDate), "Item should expire after TTL")
    }
    
    // MARK: - 3. ADB Device Tracker Parser & Command Formatting
    
    func testADBDeviceParser() {
        let output = """
        JMBR00380\tdevice\tusb:1048576X product:vext_jagar model:DC_1 device:jagar transport_id:162
        JMBR00405\tdevice\tusb:17825792X product:vext_jagar model:DC_1 device:jagar transport_id:307
        emulator-5580\toffline
        """
        let entries = ADBDeviceTracker.parseDeviceEntries(output)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].serial, "JMBR00380")
        XCTAssertEqual(entries[0].state, "device")
        XCTAssertEqual(entries[1].serial, "JMBR00405")
        XCTAssertEqual(entries[1].state, "device")
        XCTAssertEqual(entries[2].serial, "emulator-5580")
        XCTAssertEqual(entries[2].state, "offline")
    }
    
    func testADBCommandFormattingAndLifecycle() {
        var recordedCommands: [[String]] = []
        let tracker = ADBDeviceTracker(
            adbExecutable: "/bin/echo",
            commandExecutor: { args in
                recordedCommands.append(args)
                return (0, "ok")
            }
        )
        
        var attachedSerial: String?
        var detachedSerial: String?
        tracker.onDeviceAttached = { serial, _ in attachedSerial = serial }
        tracker.onDeviceDetached = { serial in detachedSerial = serial }
        
        // Simulate device arrival
        tracker.handleDeviceListUpdate("JMBR00380\tdevice\n")
        XCTAssertEqual(attachedSerial, "JMBR00380")
        XCTAssertTrue(tracker.activeTunnelSerials.contains("JMBR00380"))
        
        // Verify executed commands: reverse 8765:8765 and forward 8766:8766
        XCTAssertEqual(recordedCommands.count, 2)
        XCTAssertEqual(recordedCommands[0], ["-s", "JMBR00380", "reverse", "tcp:8765", "tcp:8765"])
        XCTAssertEqual(recordedCommands[1], ["-s", "JMBR00380", "forward", "tcp:8766", "tcp:8766"])
        
        // Simulate device departure
        tracker.handleDeviceListUpdate("")
        XCTAssertEqual(detachedSerial, "JMBR00380")
        XCTAssertFalse(tracker.activeTunnelSerials.contains("JMBR00380"))
        
        // Verify teardown commands: forward --remove and reverse --remove
        XCTAssertEqual(recordedCommands.count, 4)
        XCTAssertEqual(recordedCommands[2], ["-s", "JMBR00380", "forward", "--remove", "tcp:8766"])
        XCTAssertEqual(recordedCommands[3], ["-s", "JMBR00380", "reverse", "--remove", "tcp:8765"])
    }
    
    // MARK: - 4. Embedded HTTP Server & Client Integration Tests
    
    func testHTTPServerHealthEndpoint() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18765
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-test-host", incomingDirectory: tempDir)
        try server.start()
        defer { server.stop() }
        
        // Allow socket to bind
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let client = DaylightHTTPClient(localDeviceId: "client-test")
        let health = try await client.checkHealth(host: "127.0.0.1", port: testPort)
        
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.device_id, "mac-test-host")
        XCTAssertEqual(health.device_type, "macos")
        XCTAssertEqual(health.version, "1.0")
    }
    
    func testHTTPServerTextEndpointAndSuppression() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18766
        let loop = LoopSuppressionEngine(localDeviceId: "mac-test-host")
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-test-host", incomingDirectory: tempDir, loopSuppression: loop)
        
        var receivedTextPayload: TextPayload?
        server.onTextReceived = { payload in
            receivedTextPayload = payload
        }
        
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let client = DaylightHTTPClient(localDeviceId: "dc1-origin-device")
        
        // 1. Send normal prompt from foreign device
        let payload1 = TextPayload(id: "test-id-1", type: "prompt", text: "Summarize notes", origin: "dc1-origin-device")
        let res1 = try await client.sendText(payload: payload1, targetHost: "127.0.0.1", targetPort: testPort)
        XCTAssertTrue(res1.contains("\"received\":true"))
        XCTAssertEqual(receivedTextPayload?.text, "Summarize notes")
        
        // 2. Send prompt originating from self -> should be suppressed
        let payload2 = TextPayload(id: "test-id-2", type: "prompt", text: "Echo loop test", origin: "mac-test-host")
        let res2 = try await client.sendText(payload: payload2, targetHost: "127.0.0.1", targetPort: testPort)
        XCTAssertTrue(res2.contains("\"suppressed\":true"))
    }
    
    func testHTTPServerDropFileValid() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18767
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-test-host", incomingDirectory: tempDir)
        
        var receivedDropFilename: String?
        var receivedSha256: String?
        server.onDropReceived = { _, filename, _, _, sha256 in
            receivedDropFilename = filename
            receivedSha256 = sha256
        }
        
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let clientDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clientDir) }
        
        // Create source file
        let sourceFile = clientDir.appendingPathComponent("sample_document.pdf")
        let sampleContent = "Daylight Drop Test Content: \(UUID().uuidString)".data(using: .utf8)!
        try sampleContent.write(to: sourceFile)
        let expectedSha256 = LoopSuppressionEngine.computeSha256(data: sampleContent)
        
        let client = DaylightHTTPClient(localDeviceId: "dc1-origin")
        let response = try await client.sendDrop(
            fileURL: sourceFile,
            type: "document",
            origin: "dc1-origin",
            transferId: "tx-999",
            targetHost: "127.0.0.1",
            targetPort: testPort
        )
        
        XCTAssertEqual(response.status, "ok")
        XCTAssertTrue(response.received)
        XCTAssertEqual(response.filename, "sample_document.pdf")
        XCTAssertEqual(response.sha256, expectedSha256)
        XCTAssertEqual(receivedDropFilename, "sample_document.pdf")
        XCTAssertEqual(receivedSha256, expectedSha256)
        
        // Verify final destination file exists and temp file is cleaned up
        let destinationFile = tempDir.appendingPathComponent("sample_document.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFile.path))
        let partFile = tempDir.appendingPathComponent(".tmp_tx-999_sample_document.pdf.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
    }
    
    func testHTTPServerDropFileChecksumMismatchRejection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18768
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-test-host", incomingDirectory: tempDir)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Hand-craft a POST request with an invalid SHA-256 header
        let url = URL(string: "http://127.0.0.1:\(testPort)/api/drop")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bad-tx", forHTTPHeaderField: ProtocolConstants.headerDropId)
        request.setValue("bad_checksum.bin", forHTTPHeaderField: ProtocolConstants.headerDropFilename)
        request.setValue("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", forHTTPHeaderField: ProtocolConstants.headerDropSha256)
        request.setValue("dc1-remote", forHTTPHeaderField: ProtocolConstants.headerDropOrigin)
        let body = "Valid payload data that does not match fffff...".data(using: .utf8)!
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 400, "Server must return 400 Bad Request on checksum mismatch")
        
        let respStr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(respStr.contains("checksum_mismatch"))
        
        // Temporary part file must be deleted on checksum failure
        let partFile = tempDir.appendingPathComponent(".tmp_bad-tx_bad_checksum.bin.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
    }
    
    func testEndToEndClientServerLargeDropAndThroughput() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18769
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-server", incomingDirectory: tempDir)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        // Generate a 4MB binary payload
        let payloadSize = 4 * 1024 * 1024
        var sampleBytes = [UInt8](repeating: 0x41, count: payloadSize)
        // Add variations
        for i in stride(from: 0, to: payloadSize, by: 4096) {
            sampleBytes[i] = UInt8(i % 256)
        }
        let sampleData = Data(sampleBytes)
        let sourceFile = tempDir.appendingPathComponent("large_book.epub")
        try sampleData.write(to: sourceFile)
        let expectedSha256 = LoopSuppressionEngine.computeSha256(data: sampleData)
        
        let client = DaylightHTTPClient(localDeviceId: "dc1-sender")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        let response = try await client.sendDrop(
            fileURL: sourceFile,
            type: "document",
            origin: "dc1-sender",
            transferId: "tx-large-1",
            targetHost: "127.0.0.1",
            targetPort: testPort
        )
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let throughputMBps = (Double(payloadSize) / (1024.0 * 1024.0)) / duration
        
        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.sha256, expectedSha256)
        XCTAssertEqual(response.bytes, Int64(payloadSize))
        XCTAssertGreaterThan(throughputMBps, 5.0, "Throughput should exceed 5 MB/s on loopback")
    }
    
    func testHTTPServerDropZeroByteFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18770
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-zero-host", incomingDirectory: tempDir)
        
        var receivedDropFilename: String?
        var receivedSha256: String?
        server.onDropReceived = { _, filename, _, _, hash in
            receivedDropFilename = filename
            receivedSha256 = hash
        }
        
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let clientDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clientDir) }
        
        // Create 0-byte source file
        let zeroFile = clientDir.appendingPathComponent("empty_test.txt")
        FileManager.default.createFile(atPath: zeroFile.path, contents: Data())
        let expectedEmptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        
        let client = DaylightHTTPClient(localDeviceId: "dc1-origin")
        let response = try await client.sendDrop(
            fileURL: zeroFile,
            type: "file",
            origin: "dc1-origin",
            transferId: "tx-zero-001",
            targetHost: "127.0.0.1",
            targetPort: testPort
        )
        
        XCTAssertEqual(response.status, "ok")
        XCTAssertTrue(response.received)
        XCTAssertEqual(response.filename, "empty_test.txt")
        XCTAssertEqual(response.sha256, expectedEmptySha256)
        XCTAssertEqual(response.bytes, 0)
        XCTAssertEqual(receivedDropFilename, "empty_test.txt")
        XCTAssertEqual(receivedSha256, expectedEmptySha256)
        
        // Verify final 0-byte file exists and temp part file does not exist
        let destinationFile = tempDir.appendingPathComponent("empty_test.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationFile.path))
        let partFile = tempDir.appendingPathComponent(".tmp_tx-zero-001_empty_test.txt.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partFile.path))
        
        let fileAttr = try FileManager.default.attributesOfItem(atPath: destinationFile.path)
        let fileSize = fileAttr[.size] as? Int64 ?? -1
        XCTAssertEqual(fileSize, 0)
    }
    
    func testHTTPServerDropCollisionDisambiguation() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let clientDir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: clientDir1, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clientDir1) }
        
        let clientDir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: clientDir2, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clientDir2) }
        
        let testPort: UInt16 = 18771
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-collision-host", incomingDirectory: tempDir)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let client = DaylightHTTPClient(localDeviceId: "dc1-origin")
        
        // Drop 1: "notes.txt" with content 1
        let file1 = clientDir1.appendingPathComponent("notes.txt")
        let content1 = "First version content of notes".data(using: .utf8)!
        try content1.write(to: file1)
        
        let resp1 = try await client.sendDrop(
            fileURL: file1,
            type: "document",
            origin: "dc1-origin",
            transferId: "tx-col-1",
            targetHost: "127.0.0.1",
            targetPort: testPort
        )
        XCTAssertEqual(resp1.status, "ok")
        XCTAssertEqual(resp1.filename, "notes.txt")
        
        // Drop 2: "notes.txt" with content 2 (same filename!)
        let file2 = clientDir2.appendingPathComponent("notes.txt")
        let content2 = "Second version content of notes".data(using: .utf8)!
        try content2.write(to: file2)
        
        let resp2 = try await client.sendDrop(
            fileURL: file2,
            type: "document",
            origin: "dc1-origin",
            transferId: "tx-col-2",
            targetHost: "127.0.0.1",
            targetPort: testPort
        )
        XCTAssertEqual(resp2.status, "ok")
        XCTAssertEqual(resp2.filename, "notes (1).txt")
        
        // Verify both files exist on disk with untouched contents
        let dest1 = tempDir.appendingPathComponent("notes.txt")
        let dest2 = tempDir.appendingPathComponent("notes (1).txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest2.path))
        XCTAssertEqual(try String(contentsOf: dest1, encoding: .utf8), "First version content of notes")
        XCTAssertEqual(try String(contentsOf: dest2, encoding: .utf8), "Second version content of notes")
    }
    
    func testDynamicWifiIPResolution() {
        let ip = DaylightDropAdvertiser.getWifiIPv4Address()
        if let ip = ip {
            XCTAssertFalse(ip.isEmpty)
            XCTAssertNotEqual(ip, "127.0.0.1", "Should not be loopback when active interface is queried")
            let parts = ip.split(separator: ".")
            XCTAssertEqual(parts.count, 4, "Must be valid IPv4 dotted quad")
        }
    }
    
    func testDynamicADBPathResolution() {
        let adbPath = ADBDeviceTracker.resolveAdbPath()
        XCTAssertFalse(adbPath.isEmpty)
        XCTAssertTrue(adbPath.hasSuffix("adb"))
        if FileManager.default.fileExists(atPath: adbPath) {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: adbPath))
        }
    }
}

