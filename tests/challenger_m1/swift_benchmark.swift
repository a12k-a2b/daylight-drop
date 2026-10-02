import Foundation
import CryptoKit
import DaylightDropTransport

func runBenchmark() async throws {
    print("=== EMPIRICAL CHALLENGE 2: THROUGHPUT BENCHMARK (SWIFT ENGINE) ===")
    
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("bench_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    
    let port: UInt16 = 18790
    let server = DaylightHTTPServer(port: port, deviceId: "mac-bench-server", incomingDirectory: tempDir)
    try server.start()
    defer { server.stop() }
    
    // Allow server socket to bind
    try await Task.sleep(nanoseconds: 200_000_000)
    
    let client = DaylightHTTPClient(localDeviceId: "mac-bench-client")
    
    // Benchmark payloads: 5MB, 10MB, 25MB, 50MB
    let testSizesMB = [5, 10, 25, 50]
    let targetThroughputMBps: Double = 31.0
    
    var allPassedTarget = true
    
    for sizeMB in testSizesMB {
        let sizeBytes = sizeMB * 1024 * 1024
        print("\n--- Benchmarking \(sizeMB) MB Payload (\(sizeBytes) bytes) ---")
        
        // Generate test file with pseudo-random content
        let testFileURL = tempDir.appendingPathComponent("payload_\(sizeMB)mb.bin")
        var buffer = [UInt8](repeating: 0, count: sizeBytes)
        for i in 0..<sizeBytes {
            buffer[i] = UInt8((i ^ (i >> 8)) & 0xFF)
        }
        let data = Data(buffer)
        try data.write(to: testFileURL)
        
        let expectedSha256 = LoopSuppressionEngine.computeSha256(data: data)
        print("Generated \(sizeMB)MB file. SHA-256: \(expectedSha256.prefix(16))...")
        
        // Warmup run for 5MB
        if sizeMB == 5 {
            _ = try await client.sendDrop(
                fileURL: testFileURL,
                type: "file",
                origin: "mac-bench-client",
                transferId: "tx-warmup",
                targetHost: "127.0.0.1",
                targetPort: port
            )
        }
        
        // Timed runs (run 3 iterations and take median & max)
        var durations: [Double] = []
        var throughputs: [Double] = []
        
        for iter in 1...3 {
            let txId = "tx-\(sizeMB)mb-\(iter)"
            let startTime = CFAbsoluteTimeGetCurrent()
            
            let resp = try await client.sendDrop(
                fileURL: testFileURL,
                type: "file",
                origin: "mac-bench-client",
                transferId: txId,
                targetHost: "127.0.0.1",
                targetPort: port
            )
            
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            durations.append(duration)
            
            let throughput = Double(sizeMB) / duration
            throughputs.append(throughput)
            
            guard resp.status == "ok", resp.sha256 == expectedSha256 else {
                print("[ERROR] Transfer integrity failure on iteration \(iter)!")
                allPassedTarget = false
                continue
            }
            
            print("Iteration \(iter): Duration = \(String(format: "%.3f", duration))s | Throughput = \(String(format: "%.2f", throughput)) MB/s")
        }
        
        throughputs.sort()
        let medianThroughput = throughputs[throughputs.count / 2]
        let maxThroughput = throughputs.last!
        let status = medianThroughput >= targetThroughputMBps ? "PASS" : "FAIL"
        if medianThroughput < targetThroughputMBps {
            allPassedTarget = false
        }
        
        print("[\(status)] \(sizeMB)MB Payload: Median = \(String(format: "%.2f", medianThroughput)) MB/s | Max = \(String(format: "%.2f", maxThroughput)) MB/s | SLA Target >= \(targetThroughputMBps) MB/s")
    }
    
    print("\n=======================================================")
    if allPassedTarget {
        print("SWIFT TRANSPORT ENGINE VERDICT: PASS (Achieves >= 31 MB/s across all payload tiers)")
    } else {
        print("SWIFT TRANSPORT ENGINE VERDICT: SUB-OPTIMAL (Did not meet 31 MB/s target on some tiers)")
    }
    print("=======================================================")
}

Task {
    do {
        try await runBenchmark()
        exit(0)
    } catch {
        print("[FATAL ERROR] \(error)")
        exit(1)
    }
}

RunLoop.main.run()
