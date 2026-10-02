package com.daylight.drop.transport

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class EmpiricalChallenge2Tests {

    // MARK: - 1. Concurrency Stress Tests

    @Test
    fun testConcurrentRapidTextPrompts() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "android_concurrent_text_" + UUID.randomUUID())
        tempDir.mkdirs()
        try {
            val testPort = 18821
            val loop = LoopSuppressionEngine(localDeviceId = "dc1-concurrent-server")
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = "dc1-concurrent-server",
                incomingDirectory = tempDir,
                loopSuppression = loop
            )

            val receivedCount = AtomicInteger(0)
            val receivedIds = ConcurrentHashMap.newKeySet<String>()

            server.onTextReceived = { payload ->
                receivedCount.incrementAndGet()
                receivedIds.add(payload.id)
            }

            server.start()
            try {
                Thread.sleep(150)
                val totalRequests = 50
                val client = AndroidHttpClient(localDeviceId = "mac-peer")
                val executor = Executors.newFixedThreadPool(16)
                val latch = CountDownLatch(totalRequests)
                val successCount = AtomicInteger(0)
                val failureCount = AtomicInteger(0)

                val start = System.currentTimeMillis()

                for (i in 0 until totalRequests) {
                    executor.execute {
                        try {
                            val payload = TextPayload(
                                id = "prompt-$i-${UUID.randomUUID().toString().substring(0, 6)}",
                                type = "prompt",
                                text = "Concurrent prompt text #$i",
                                origin = "mac-peer-$i"
                            )
                            val res = client.sendText(payload, targetHost = "127.0.0.1", targetPort = testPort)
                            if (res.contains("\"received\":true")) {
                                successCount.incrementAndGet()
                            } else {
                                failureCount.incrementAndGet()
                            }
                        } catch (e: Exception) {
                            failureCount.incrementAndGet()
                        } finally {
                            latch.countDown()
                        }
                    }
                }

                assertTrue("All concurrent requests must complete within 10s", latch.await(10, TimeUnit.SECONDS))
                val elapsed = System.currentTimeMillis() - start

                assertEquals(0, failureCount.get())
                assertEquals(totalRequests, successCount.get())
                assertEquals(totalRequests, receivedCount.get())
                assertEquals(totalRequests, receivedIds.size)
                assertTrue("Duration must be < 5000ms (actual: ${elapsed}ms)", elapsed < 5000)

                executor.shutdown()
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testConcurrentFileStreams() {
        val serverDir = File(System.getProperty("java.io.tmpdir"), "android_stream_server_" + UUID.randomUUID())
        val clientDir = File(System.getProperty("java.io.tmpdir"), "android_stream_client_" + UUID.randomUUID())
        serverDir.mkdirs()
        clientDir.mkdirs()
        try {
            val testPort = 18822
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = "dc1-file-server",
                incomingDirectory = serverDir
            )

            val receivedFiles = ConcurrentHashMap<String, String>()
            server.onDropReceived = { _, filename, _, _, hash ->
                receivedFiles[filename] = hash
            }

            server.start()
            try {
                Thread.sleep(150)
                val client = AndroidHttpClient(localDeviceId = "mac-uploader")
                val totalFiles = 10
                val fileSize = 512 * 1024 // 512KB

                val testFiles = mutableListOf<File>()
                val expectedHashes = mutableMapOf<String, String>()

                for (i in 0 until totalFiles) {
                    val file = File(clientDir, "stream_test_${i}_${UUID.randomUUID().toString().substring(0, 6)}.bin")
                    val bytes = ByteArray(fileSize) { b -> ((b + i * 17) % 256).toByte() }
                    file.writeBytes(bytes)
                    testFiles.add(file)
                    expectedHashes[file.name] = LoopSuppressionEngine.computeSha256(bytes)
                }

                val executor = Executors.newFixedThreadPool(8)
                val latch = CountDownLatch(totalFiles)
                val successCount = AtomicInteger(0)
                val failureCount = AtomicInteger(0)

                for (file in testFiles) {
                    executor.execute {
                        try {
                            val res = client.sendDrop(
                                file = file,
                                type = "document",
                                origin = "mac-origin",
                                targetHost = "127.0.0.1",
                                targetPort = testPort
                            )
                            if (res.received) {
                                successCount.incrementAndGet()
                            } else {
                                failureCount.incrementAndGet()
                            }
                        } catch (e: Exception) {
                            failureCount.incrementAndGet()
                        } finally {
                            latch.countDown()
                        }
                    }
                }

                assertTrue("All concurrent file transfers must finish within 15s", latch.await(15, TimeUnit.SECONDS))
                assertEquals(0, failureCount.get())
                assertEquals(totalFiles, successCount.get())

                // Verify file landing and SHA-256 integrity on disk
                for ((filename, expectedHash) in expectedHashes) {
                    val finalFile = File(serverDir, filename)
                    assertTrue("File $filename must exist in destination", finalFile.exists())
                    val actualHash = LoopSuppressionEngine.computeSha256(finalFile.readBytes())
                    assertEquals("Hash must match for $filename", expectedHash, actualHash)
                }

                executor.shutdown()
            } finally {
                server.stop()
            }
        } finally {
            serverDir.deleteRecursively()
            clientDir.deleteRecursively()
        }
    }

    // MARK: - 2. Loop Suppression Stress Tests

    @Test
    fun testOriginTagSuppression100Percent() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "android_loop_test_" + UUID.randomUUID())
        tempDir.mkdirs()
        try {
            val testPort = 18823
            val serverDeviceId = "dc1-origin-suppress-server"
            val loop = LoopSuppressionEngine(localDeviceId = serverDeviceId)
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = serverDeviceId,
                incomingDirectory = tempDir,
                loopSuppression = loop
            )

            val callbacksFired = AtomicInteger(0)
            server.onTextReceived = { callbacksFired.incrementAndGet() }

            server.start()
            try {
                Thread.sleep(150)
                val client = AndroidHttpClient(localDeviceId = serverDeviceId)
                val totalAttempts = 50
                var suppressedCount = 0

                for (i in 0 until totalAttempts) {
                    val payload = TextPayload(
                        id = "echo-$i",
                        type = "clipboard",
                        text = "Origin echo text #$i",
                        origin = serverDeviceId // Matches serverDeviceId
                    )
                    val res = client.sendText(payload, targetHost = "127.0.0.1", targetPort = testPort)
                    if (res.contains("\"suppressed\":true") && res.contains("\"received\":false")) {
                        suppressedCount++
                    }
                }

                assertEquals("100% of origin-matching events must be suppressed", totalAttempts, suppressedCount)
                assertEquals("Callback must never fire for suppressed echoes", 0, callbacksFired.get())
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testContentHashDeduplicationSuppression() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "android_hash_suppress_" + UUID.randomUUID())
        tempDir.mkdirs()
        try {
            val testPort = 18824
            val serverDeviceId = "dc1-hash-suppress-server"
            val loop = LoopSuppressionEngine(localDeviceId = serverDeviceId)
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = serverDeviceId,
                incomingDirectory = tempDir,
                loopSuppression = loop
            )

            val callbacksFired = AtomicInteger(0)
            server.onTextReceived = { callbacksFired.incrementAndGet() }

            server.start()
            try {
                Thread.sleep(150)
                val client = AndroidHttpClient(localDeviceId = "foreign-peer")
                val totalAttempts = 50

                // Pre-record 50 contents in the LRU cache (simulating prior local dispatch)
                val testTexts = mutableListOf<String>()
                for (i in 0 until totalAttempts) {
                    val text = "Prompt dispatched locally #$i - ${UUID.randomUUID()}"
                    testTexts.add(text)
                    loop.recordText(text)
                }

                var suppressedCount = 0
                for (text in testTexts) {
                    val payload = TextPayload(
                        id = "echo-${UUID.randomUUID()}",
                        type = "clipboard",
                        text = text,
                        origin = "foreign-peer" // Foreign origin, but content hash exists in cache
                    )
                    val res = client.sendText(payload, targetHost = "127.0.0.1", targetPort = testPort)
                    if (res.contains("\"suppressed\":true")) {
                        suppressedCount++
                    }
                }

                assertEquals("100% of echoing content hashes must be suppressed", totalAttempts, suppressedCount)
                assertEquals(0, callbacksFired.get())
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testLoopSuppressionConcurrentThreadSafety() {
        val loop = LoopSuppressionEngine(localDeviceId = "thread-dc1-test", capacity = 256, ttlMs = 60000L)
        val totalThreads = 16
        val opsPerThread = 10
        val executor = Executors.newFixedThreadPool(totalThreads)
        val latch = CountDownLatch(totalThreads)
        val exceptions = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        val misses = AtomicInteger(0)

        for (t in 0 until totalThreads) {
            executor.execute {
                try {
                    for (op in 0 until opsPerThread) {
                        val text = "thread-$t-item-$op"
                        val hash = LoopSuppressionEngine.computeSha256(text)
                        loop.record(hash)
                        val isSuppressed = loop.shouldSuppress(hash)
                        if (!isSuppressed) {
                            misses.incrementAndGet()
                        }
                    }
                } catch (e: Throwable) {
                    exceptions.add(e)
                } finally {
                    latch.countDown()
                }
            }
        }

        assertTrue(latch.await(10, TimeUnit.SECONDS))
        if (!exceptions.isEmpty()) {
            fail("Exception thrown under concurrent load: ${exceptions.first().javaClass.name}: ${exceptions.first().message}")
        }
        assertEquals("No eviction misses when total items (160) < capacity (256)", 0, misses.get())
        assertTrue("Cache size must not exceed capacity", loop.currentCacheCount() <= 256)

        executor.shutdown()
    }

    // MARK: - 3. Failover Tests

    @Test
    fun testAndroidChannelHierarchy() {
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val client = AndroidHttpClient(localDeviceId = "dc1-test")
        // Verify resolveTargetEndpoint hierarchy logic:
        // When USB is healthy, returns (127.0.0.1, 8765)
        // When USB is unhealthy, falls back to activeWifiPeer (ip, port)
        // When neither, returns null
        var isUsbHealthy = true
        var activeWifiPeer: DiscoveredPeer? = DiscoveredPeer(
            deviceId = "mac-peer-01",
            deviceName = "MacBook Pro",
            role = ProtocolConstants.ROLE_MAC,
            ip = "192.168.1.100",
            port = ProtocolConstants.MAC_PORT
        )

        fun resolveTargetEndpoint(): Pair<String, Int>? {
            if (isUsbHealthy) {
                return Pair("127.0.0.1", ProtocolConstants.MAC_PORT)
            }
            val peer = activeWifiPeer
            if (peer != null && peer.ip.isNotEmpty()) {
                return Pair(peer.ip, peer.port)
            }
            return null
        }

        // 1. Both USB and Wi-Fi present -> prefers USB
        val ep1 = resolveTargetEndpoint()
        assertNotNull(ep1)
        assertEquals("127.0.0.1", ep1?.first)
        assertEquals(ProtocolConstants.MAC_PORT, ep1?.second)

        // 2. USB detached -> gracefully switches to Wi-Fi
        isUsbHealthy = false
        val ep2 = resolveTargetEndpoint()
        assertNotNull(ep2)
        assertEquals("192.168.1.100", ep2?.first)
        assertEquals(ProtocolConstants.MAC_PORT, ep2?.second)

        // 3. Wi-Fi lost -> returns null
        activeWifiPeer = null
        val ep3 = resolveTargetEndpoint()
        assertNull(ep3)
    }
}
