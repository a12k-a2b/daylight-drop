import XCTest
import Foundation
import Network
import CryptoKit
@testable import DaylightDropTransport

final class EmpiricalChallenge2Iteration2Tests: XCTestCase {
    
    final class TestBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var val: T
        init(_ initial: T) { self.val = initial }
        func access<R>(_ body: (inout T) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&val)
        }
    }
    
    // MARK: - 1. Interleaved Traffic Stress Tests
    
    /// Test 1: Rapid Interleaved Streams (0-byte files, multiline prompts, and image streams)
    /// Verifies that 0-byte file drops do not deadlock or contaminate subsequent prompt or image streams.
    func testInterleavedZeroByteTextAndImageStreams() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("interleaved_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18851
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-interleaved-server", incomingDirectory: tempDir)
        
        struct RecordedState {
            var drops: [String: (filename: String, hash: String, bytes: Int64)] = [:]
            var texts: [String: String] = [:]
        }
        let box = TestBox(RecordedState())
        
        server.onDropReceived = { txId, filename, type, fileURL, hash in
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int64 ?? 0
            box.access { s in
                s.drops[txId] = (filename, hash, size)
            }
        }
        
        server.onTextReceived = { payload in
            box.access { s in
                s.texts[payload.id] = payload.text
            }
        }
        
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let client = DaylightHTTPClient(localDeviceId: "client-interleaved")
        let emptySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        
        let cycles = 10
        for i in 0..<cycles {
            // 1. 0-Byte File Drop
            let zeroFile = tempDir.appendingPathComponent("empty_\(i).txt")
            FileManager.default.createFile(atPath: zeroFile.path, contents: Data())
            let txZeroId = "tx-zero-\(i)"
            let zeroResp = try await client.sendDrop(
                fileURL: zeroFile,
                type: "file",
                origin: "client-interleaved",
                transferId: txZeroId,
                targetHost: "127.0.0.1",
                targetPort: testPort
            )
            XCTAssertEqual(zeroResp.status, "ok")
            XCTAssertTrue(zeroResp.received)
            XCTAssertEqual(zeroResp.bytes, 0)
            XCTAssertEqual(zeroResp.sha256, emptySha)
            
            // 2. Multiline Unicode Text Prompt
            let promptId = "prompt-interleaved-\(i)"
            let promptText = "Interleaved cycle \(i) prompt:\nLine 2: 🚀 Sol:OS 8-bit Gray Scale\nLine 3: Specially formatted \"quotes\" and brackets [OK]."
            let payload = TextPayload(
                id: promptId,
                type: "prompt",
                text: promptText,
                origin: "client-interleaved",
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
            let promptResp = try await client.sendText(
                payload: payload,
                targetHost: "127.0.0.1",
                targetPort: testPort
            )
            XCTAssertTrue(promptResp.contains(promptId))
            XCTAssertTrue(promptResp.contains("\"received\":true"))
            
            // 3. Binary Image Stream (varying size)
            let imgSize = (i % 2 == 0) ? 64 * 1024 : 256 * 1024
            var imgBytes = [UInt8](repeating: 0x55, count: imgSize)
            for j in stride(from: 0, to: imgSize, by: 1024) {
                imgBytes[j] = UInt8(j % 256)
            }
            let imgData = Data(imgBytes)
            let imgSha = LoopSuppressionEngine.computeSha256(data: imgData)
            let imgFile = tempDir.appendingPathComponent("image_\(i).png")
            try imgData.write(to: imgFile)
            let txImgId = "tx-img-\(i)"
            let imgResp = try await client.sendDrop(
                fileURL: imgFile,
                type: "image",
                origin: "client-interleaved",
                transferId: txImgId,
                targetHost: "127.0.0.1",
                targetPort: testPort
            )
            XCTAssertEqual(imgResp.status, "ok")
            XCTAssertTrue(imgResp.received)
            XCTAssertEqual(imgResp.bytes, Int64(imgSize))
            XCTAssertEqual(imgResp.sha256, imgSha)
        }
        
        // Wait a brief moment for callbacks to complete
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Verification: all 10 zero files and 10 image files received
        let (dropCount, textCount) = box.access { s in (s.drops.count, s.texts.count) }
        XCTAssertEqual(dropCount, cycles * 2)
        XCTAssertEqual(textCount, cycles)
        
        // Verify no .part files remain
        let items = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let partFiles = items.filter { $0.hasSuffix(".part") }
        XCTAssertTrue(partFiles.isEmpty, "Lingering .part files found: \(partFiles)")
    }
    
    /// Test 2: Concurrent Interleaved Bursts across 10 Async Tasks
    func testConcurrentInterleavedStreams() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("concurrent_interleaved_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPort: UInt16 = 18852
        let server = DaylightHTTPServer(port: testPort, deviceId: "mac-concurrent-interleaved", incomingDirectory: tempDir)
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let client = DaylightHTTPClient(localDeviceId: "client-worker")
        let totalWorkers = 10
        let emptySha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for i in 0..<totalWorkers {
                group.addTask {
                    do {
                        // 1. 0-byte drop
                        let zFile = tempDir.appendingPathComponent("w_\(i)_zero.bin")
                        FileManager.default.createFile(atPath: zFile.path, contents: Data())
                        let zResp = try await client.sendDrop(
                            fileURL: zFile,
                            type: "file",
                            origin: "worker-\(i)",
                            transferId: "tx-conc-zero-\(i)",
                            targetHost: "127.0.0.1",
                            targetPort: testPort
                        )
                        guard zResp.status == "ok" && zResp.bytes == 0 && zResp.sha256 == emptySha else { return false }
                        
                        // 2. prompt
                        let pPayload = TextPayload(
                            id: "conc-prompt-\(i)",
                            type: "prompt",
                            text: "Concurrent prompt from worker \(i)",
                            origin: "worker-\(i)",
                            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                        )
                        let pResp = try await client.sendText(
                            payload: pPayload,
                            targetHost: "127.0.0.1",
                            targetPort: testPort
                        )
                        guard pResp.contains("conc-prompt-\(i)") && pResp.contains("\"received\":true") else { return false }
                        
                        // 3. image stream (128KB)
                        let imgData = Data(repeating: UInt8(i + 1), count: 128 * 1024)
                        let iFile = tempDir.appendingPathComponent("w_\(i)_img.png")
                        try imgData.write(to: iFile)
                        let iResp = try await client.sendDrop(
                            fileURL: iFile,
                            type: "image",
                            origin: "worker-\(i)",
                            transferId: "tx-conc-img-\(i)",
                            targetHost: "127.0.0.1",
                            targetPort: testPort
                        )
                        guard iResp.status == "ok" && iResp.bytes == Int64(128 * 1024) else { return false }
                        
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var acc: [Bool] = []
            for await res in group {
                acc.append(res)
            }
            return acc
        }
        
        XCTAssertEqual(results.count, totalWorkers)
        XCTAssertTrue(results.allSatisfy { $0 }, "All concurrent interleaved streams must succeed")
        
        let items = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let partFiles = items.filter { $0.hasSuffix(".part") }
        XCTAssertTrue(partFiles.isEmpty, "Lingering .part files found: \(partFiles)")
    }
    
    // MARK: - 2. Dynamic IP Resolution & Interface Handling
    
    /// Test 3: Verify dynamic IP resolution returns valid IPv4 format and non-loopback when Wi-Fi is active.
    func testDynamicWifiIPResolutionFormatAndFallback() {
        let ip = DaylightDropAdvertiser.getWifiIPv4Address()
        if let ip = ip {
            XCTAssertFalse(ip.isEmpty)
            XCTAssertNotEqual(ip, "127.0.0.1", "Active Wi-Fi address should not be loopback")
            let parts = ip.split(separator: ".")
            XCTAssertEqual(parts.count, 4, "Must be valid IPv4 dotted-quad")
            for part in parts {
                if let num = Int(part) {
                    XCTAssertTrue(num >= 0 && num <= 255)
                } else {
                    XCTFail("Non-numeric octet in IP: \(part)")
                }
            }
        }
        
        // Test Advertiser default fallback
        let advDefault = DaylightDropAdvertiser(port: 18853, deviceId: "mac-adv-def", deviceName: "TestMac")
        XCTAssertFalse(advDefault.ipHint.isEmpty)
        
        let advExplicit = DaylightDropAdvertiser(port: 18854, deviceId: "mac-adv-exp", deviceName: "TestMac", ipHint: "192.168.1.50")
        XCTAssertEqual(advExplicit.ipHint, "192.168.1.50")
    }
}
