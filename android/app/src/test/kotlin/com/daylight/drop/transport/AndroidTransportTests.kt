package com.daylight.drop.transport

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID

class AndroidTransportTests {

    // MARK: - 1. Protocol Constants Tests

    @Test
    fun testProtocolConstants() {
        assertEquals("1.0", ProtocolConstants.PROTOCOL_VERSION)
        assertEquals(8765, ProtocolConstants.MAC_PORT)
        assertEquals(8766, ProtocolConstants.ANDROID_PORT)
        assertEquals(5037, ProtocolConstants.ADB_DAEMON_PORT)
        assertEquals("_daylightdrop._tcp.", ProtocolConstants.SERVICE_TYPE)
        assertEquals("/api/health", ProtocolConstants.HEALTH_ENDPOINT)
        assertEquals("/api/drop", ProtocolConstants.DROP_ENDPOINT)
        assertEquals("/api/text", ProtocolConstants.TEXT_ENDPOINT)
        assertEquals("/api/ws", ProtocolConstants.WS_ENDPOINT)
        assertEquals("X-Daylight-Drop-Id", ProtocolConstants.HEADER_DROP_ID)
        assertEquals("X-Daylight-Drop-Type", ProtocolConstants.HEADER_DROP_TYPE)
        assertEquals("X-Daylight-Drop-Filename", ProtocolConstants.HEADER_DROP_FILENAME)
        assertEquals("X-Daylight-Drop-Sha256", ProtocolConstants.HEADER_DROP_SHA256)
        assertEquals("X-Daylight-Drop-Origin", ProtocolConstants.HEADER_DROP_ORIGIN)
        assertEquals("com.daylight.drop.origin", ProtocolConstants.ORIGIN_TAG)
    }

    // MARK: - 2. Loop Suppression Tests

    @Test
    fun testLoopSuppressionOriginSelf() {
        val engine = LoopSuppressionEngine(localDeviceId = "dc1-test-device")
        assertTrue(engine.isOriginSelf("dc1-test-device"))
        assertFalse(engine.isOriginSelf("mac-remote-device"))
        assertFalse(engine.isOriginSelf(""))
    }

    @Test
    fun testLoopSuppressionLRUEvictionAndTTL() {
        val engine = LoopSuppressionEngine(localDeviceId = "dc1-test-device", capacity = 3, ttlMs = 2000L)
        val now = 1000000L

        val text1 = "Hello Daylight SolOS"
        val hash1 = LoopSuppressionEngine.computeSha256(text1)

        assertFalse(engine.shouldSuppress(hash1, now))

        // Record hash1
        engine.record(hash1, now)
        assertTrue(engine.shouldSuppress(hash1, now))
        assertTrue(engine.shouldSuppressText(text1, now))

        // Add hash2 and hash3
        val hash2 = LoopSuppressionEngine.computeSha256("Text 2")
        val hash3 = LoopSuppressionEngine.computeSha256("Text 3")
        engine.record(hash2, now)
        engine.record(hash3, now)
        assertEquals(3, engine.currentCacheCount())

        // Add hash4 -> triggers LRU eviction of hash1
        val hash4 = LoopSuppressionEngine.computeSha256("Text 4")
        engine.record(hash4, now)
        assertEquals(3, engine.currentCacheCount())
        assertFalse("Oldest entry hash1 should be evicted", engine.shouldSuppress(hash1, now))
        assertTrue(engine.shouldSuppress(hash2, now))
        assertTrue(engine.shouldSuppress(hash4, now))

        // Test TTL expiration (advance time by 3 seconds)
        val futureTime = now + 3000L
        assertFalse("Entry should expire after TTL", engine.shouldSuppress(hash4, futureTime))
    }

    // MARK: - 3. AndroidHttpServer & AndroidHttpClient Tests

    @Test
    fun testServerHealthEndpoint() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "test_health_" + UUID.randomUUID())
        tempDir.mkdirs()
        try {
            val testPort = 18776
            val server = AndroidHttpServer(port = testPort, deviceId = "dc1-test-server", incomingDirectory = tempDir)
            server.start()
            try {
                Thread.sleep(100)
                val client = AndroidHttpClient(localDeviceId = "mac-client")
                val health = client.checkHealth(host = "127.0.0.1", port = testPort)

                assertEquals("ok", health.status)
                assertEquals("dc1-test-server", health.device_id)
                assertEquals("daylight", health.device_type)
                assertEquals("1.0", health.version)
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testServerTextEndpointAndSuppression() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "test_text_" + UUID.randomUUID())
        tempDir.mkdirs()
        try {
            val testPort = 18777
            val loop = LoopSuppressionEngine(localDeviceId = "dc1-test-server")
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = "dc1-test-server",
                incomingDirectory = tempDir,
                loopSuppression = loop
            )
            var receivedPayload: TextPayload? = null
            server.onTextReceived = { payload -> receivedPayload = payload }
            server.start()
            try {
                Thread.sleep(100)
                val client = AndroidHttpClient(localDeviceId = "mac-client")

                // 1. Foreign text payload
                val payload1 = TextPayload(id = "p-1", type = "prompt", text = "AI prompt test", origin = "mac-client")
                val res1 = client.sendText(payload1, targetHost = "127.0.0.1", targetPort = testPort)
                assertTrue(res1.contains("\"received\":true"))
                assertNotNull(receivedPayload)
                assertEquals("AI prompt test", receivedPayload?.text)

                // 2. Loop suppression from self
                val payload2 = TextPayload(id = "p-2", type = "prompt", text = "Self origin echo", origin = "dc1-test-server")
                val res2 = client.sendText(payload2, targetHost = "127.0.0.1", targetPort = testPort)
                assertTrue(res2.contains("\"suppressed\":true"))
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testServerDropFileValidAndRoundTrip() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "test_drop_" + UUID.randomUUID())
        val sourceDir = File(System.getProperty("java.io.tmpdir"), "test_source_" + UUID.randomUUID())
        tempDir.mkdirs()
        sourceDir.mkdirs()
        try {
            val testPort = 18778
            val server = AndroidHttpServer(port = testPort, deviceId = "dc1-test-server", incomingDirectory = tempDir)
            var receivedFile: File? = null
            var receivedHash: String? = null
            server.onDropReceived = { _, _, _, file, hash ->
                receivedFile = file
                receivedHash = hash
            }
            server.start()
            try {
                Thread.sleep(100)
                val sourceFile = File(sourceDir, "source_screenshot.png")
                val content = "Fake Screenshot Content for Sol:OS ${UUID.randomUUID()}".toByteArray(Charsets.UTF_8)
                sourceFile.writeBytes(content)
                val expectedSha256 = LoopSuppressionEngine.computeSha256(content)

                val client = AndroidHttpClient(localDeviceId = "mac-sender")
                val response = client.sendDrop(
                    file = sourceFile,
                    type = "screenshot",
                    origin = "mac-sender",
                    transferId = "tx-1234",
                    targetHost = "127.0.0.1",
                    targetPort = testPort
                )

                assertEquals("ok", response.status)
                assertTrue(response.received)
                assertEquals("source_screenshot.png", response.filename)
                assertEquals(expectedSha256, response.sha256)
                assertEquals(content.size.toLong(), response.bytes)

                // Verify file delivered
                val finalFile = File(tempDir, "source_screenshot.png")
                assertTrue(finalFile.exists())
                assertEquals(expectedSha256, receivedHash)

                // Temporary part file must be deleted
                val partFile = File(tempDir, ".tmp_tx-1234_source_screenshot.png.part")
                assertFalse(partFile.exists())
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
            sourceDir.deleteRecursively()
        }
    }

    @Test
    fun testServerDropFileChecksumMismatchRejection() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "test_mismatch_" + UUID.randomUUID())
        tempDir.mkdirs()
        try {
            val testPort = 18779
            val server = AndroidHttpServer(port = testPort, deviceId = "dc1-test-server", incomingDirectory = tempDir)
            server.start()
            try {
                Thread.sleep(100)
                // Use raw OkHttp to send bad SHA-256 header
                val okClient = okhttp3.OkHttpClient()
                val badBody = "Actual data".toByteArray()
                val requestBody = badBody.toRequestBody("application/octet-stream".toMediaType())
                val request = okhttp3.Request.Builder()
                    .url("http://127.0.0.1:$testPort/api/drop")
                    .post(requestBody)
                    .header(ProtocolConstants.HEADER_DROP_ID, "bad-tx-1")
                    .header(ProtocolConstants.HEADER_DROP_FILENAME, "corrupt.bin")
                    .header(ProtocolConstants.HEADER_DROP_SHA256, "0000000000000000000000000000000000000000000000000000000000000000")
                    .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-remote")
                    .build()

                okClient.newCall(request).execute().use { resp ->
                    assertEquals(400, resp.code)
                    val bodyStr = resp.body?.string() ?: ""
                    assertTrue(bodyStr.contains("checksum_mismatch"))
                }

                // Temporary file must be removed
                val partFile = File(tempDir, ".tmp_bad-tx-1_corrupt.bin.part")
                assertFalse(partFile.exists())
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun testServerDropZeroByteFile() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "test_zero_drop_" + UUID.randomUUID())
        val sourceDir = File(System.getProperty("java.io.tmpdir"), "test_zero_source_" + UUID.randomUUID())
        tempDir.mkdirs()
        sourceDir.mkdirs()
        try {
            val testPort = 18780
            val server = AndroidHttpServer(port = testPort, deviceId = "dc1-zero-server", incomingDirectory = tempDir)
            var receivedFile: File? = null
            var receivedHash: String? = null
            server.onDropReceived = { _, _, _, file, hash ->
                receivedFile = file
                receivedHash = hash
            }
            server.start()
            try {
                Thread.sleep(100)
                val emptySourceFile = File(sourceDir, "empty_source.txt")
                emptySourceFile.writeBytes(ByteArray(0))
                val expectedEmptySha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

                val client = AndroidHttpClient(localDeviceId = "mac-sender")
                val response = client.sendDrop(
                    file = emptySourceFile,
                    type = "file",
                    origin = "mac-sender",
                    transferId = "tx-zero-android",
                    targetHost = "127.0.0.1",
                    targetPort = testPort
                )

                assertEquals("ok", response.status)
                assertTrue(response.received)
                assertEquals("empty_source.txt", response.filename)
                assertEquals(expectedEmptySha256, response.sha256)
                assertEquals(0L, response.bytes)

                val finalFile = File(tempDir, "empty_source.txt")
                assertTrue(finalFile.exists())
                assertEquals(0L, finalFile.length())
                assertEquals(expectedEmptySha256, receivedHash)

                val partFile = File(tempDir, ".tmp_tx-zero-android_empty_source.txt.part")
                assertFalse(partFile.exists())
            } finally {
                server.stop()
            }
        } finally {
            tempDir.deleteRecursively()
            sourceDir.deleteRecursively()
        }
    }
}
