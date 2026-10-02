package com.daylight.drop.transport

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class AndroidChallengerBenchmarkTests {

    @Test
    fun testLargePayloadTransferThroughput() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "bench_android_" + UUID.randomUUID())
        tempDir.mkdirs()
        val testPort = java.net.ServerSocket(0).use { it.localPort }
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-bench-server", incomingDirectory = tempDir)
        server.start()
        
        try {
            Thread.sleep(150)
            val client = AndroidHttpClient(localDeviceId = "mac-bench-client")
            val targetThroughputMBps = 31.0
            val sizesMB = listOf(5, 10, 25)
            
            // Warmup
            val warmupFile = File(tempDir, "warmup.bin")
            warmupFile.writeBytes(ByteArray(1024 * 1024) { 0x42 })
            client.sendDrop(warmupFile, transferId = "tx-warmup", targetHost = "127.0.0.1", targetPort = testPort)

            val results = mutableMapOf<Int, Pair<Double, Double>>() // size -> (median, max)
            
            for (sizeMB in sizesMB) {
                val sizeBytes = sizeMB * 1024 * 1024
                val testFile = File(tempDir, "payload_${sizeMB}mb.bin")
                
                // Create test file with patterned data
                val digest = MessageDigest.getInstance("SHA-256")
                testFile.outputStream().use { fos ->
                    val chunk = ByteArray(64 * 1024)
                    var written = 0
                    while (written < sizeBytes) {
                        for (i in chunk.indices) {
                            chunk[i] = ((written + i) xor ((written + i) shr 8)).toByte()
                        }
                        val toWrite = minOf(chunk.size, sizeBytes - written)
                        fos.write(chunk, 0, toWrite)
                        digest.update(chunk, 0, toWrite)
                        written += toWrite
                    }
                }
                val expectedSha = digest.digest().joinToString("") { "%02x".format(it) }
                
                // Benchmark 3 iterations
                val throughputs = mutableListOf<Double>()
                for (iter in 1..3) {
                    val startTime = System.nanoTime()
                    val response = client.sendDrop(
                        file = testFile,
                        type = "file",
                        origin = "mac-bench-client",
                        transferId = "tx-${sizeMB}mb-$iter",
                        targetHost = "127.0.0.1",
                        targetPort = testPort
                    )
                    val elapsedSeconds = (System.nanoTime() - startTime) / 1_000_000_000.0
                    val throughputMBps = sizeMB / elapsedSeconds
                    throughputs.add(throughputMBps)
                    
                    assertEquals("ok", response.status)
                    assertTrue(response.received)
                    assertEquals(expectedSha, response.sha256)
                    assertEquals(sizeBytes.toLong(), response.bytes)
                    println("[KOTLIN_BENCH] Payload ${sizeMB}MB Iter $iter: Duration = %.3fs | Throughput = %.2f MB/s".format(elapsedSeconds, throughputMBps))
                }
                
                throughputs.sort()
                val medianThroughput = throughputs[throughputs.size / 2]
                val maxThroughput = throughputs.last()
                results[sizeMB] = Pair(medianThroughput, maxThroughput)
                println("[KOTLIN_BENCH_SUMMARY] ${sizeMB}MB: Median = %.2f MB/s | Max = %.2f MB/s | Target >= %.1f MB/s".format(medianThroughput, maxThroughput, targetThroughputMBps))
            }

            println("=== KOTLIN TRANSPORT ENGINE SUMMARY ===")
            for ((size, pair) in results) {
                val pass = if (pair.first >= targetThroughputMBps) "PASS" else "FAIL"
                println("  [%s] %d MB: Median = %.2f MB/s, Max = %.2f MB/s (Target >= %.1f MB/s)".format(pass, size, pair.first, pair.second, targetThroughputMBps))
            }
        } finally {
            server.stop()
            tempDir.deleteRecursively()
        }
    }
}
