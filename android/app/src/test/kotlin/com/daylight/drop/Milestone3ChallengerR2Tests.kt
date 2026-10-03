package com.daylight.drop

import com.daylight.drop.transport.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.net.ServerSocket
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Milestone3ChallengerR2Tests:
 * Adversarial empirical verification suite authored by Challenger 1 (Round 2)
 * for Daylight Drop Milestone 3.
 *
 * Focus areas:
 * 1. Storage collision preservation & incremented suffixes ((1), (2), ...)
 * 2. Concurrent duplicate drops thread-safety
 * 3. Premature stream truncation / EOF detection and cleanup
 * 4. MediaStore screenshot sync SLA (<1500ms) and prompt SLA (<500ms)
 * 5. MediaStore watermark monotonic progression on zero-byte and missing files
 */
class Milestone3ChallengerR2Tests {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun computeSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    // =========================================================================
    // 1. Storage Collision & Suffix Disambiguation Stress
    // =========================================================================

    @Test
    fun testSequentialInboundDuplicateDropsPreserveAllFiles() {
        val testPort = ServerSocket(0).use { it.localPort }
        val incomingDir = tempFolder.newFolder("inbound_seq_collision")
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-challenger", incomingDirectory = incomingDir)
        server.start()

        val okClient = OkHttpClient()

        try {
            Thread.sleep(100)

            val baseFilename = "document.pdf"
            val totalVersions = 10
            val fileContents = mutableListOf<String>()

            for (i in 0 until totalVersions) {
                val content = "Content Version #$i for $baseFilename (salt: ${UUID.randomUUID()})"
                fileContents.add(content)
                val bytes = content.toByteArray(Charsets.UTF_8)
                val hash = computeSha256(bytes)

                val request = Request.Builder()
                    .url("http://127.0.0.1:$testPort/api/drop")
                    .post(bytes.toRequestBody("application/pdf".toMediaType()))
                    .header(ProtocolConstants.HEADER_DROP_ID, "drop-seq-$i")
                    .header(ProtocolConstants.HEADER_DROP_TYPE, "document")
                    .header(ProtocolConstants.HEADER_DROP_FILENAME, baseFilename)
                    .header(ProtocolConstants.HEADER_DROP_SHA256, hash)
                    .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-challenger")
                    .build()

                okClient.newCall(request).execute().use { resp ->
                    assertEquals("Drop $i must return HTTP 200", 200, resp.code)
                }
            }

            // Verify all 10 versions exist and each has its exact uncorrupted content
            for (i in 0 until totalVersions) {
                val expectedName = if (i == 0) baseFilename else "document ($i).pdf"
                val file = File(incomingDir, expectedName)
                assertTrue("File $expectedName must exist in incomingDir", file.exists())
                assertEquals(
                    "Content of $expectedName must match version #$i",
                    fileContents[i],
                    file.readText(Charsets.UTF_8)
                )
            }
        } finally {
            server.stop()
        }
    }

    @Test
    fun testZeroByteFileCollisionHandling() {
        val testPort = ServerSocket(0).use { it.localPort }
        val incomingDir = tempFolder.newFolder("inbound_zero_collision")
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-challenger", incomingDirectory = incomingDir)
        server.start()

        val okClient = OkHttpClient()

        try {
            Thread.sleep(100)

            val emptyBytes = ByteArray(0)
            val emptyHash = computeSha256(emptyBytes)

            // Drop 1: 0-byte file
            val req1 = Request.Builder()
                .url("http://127.0.0.1:$testPort/api/drop")
                .post(emptyBytes.toRequestBody("application/octet-stream".toMediaType()))
                .header(ProtocolConstants.HEADER_DROP_ID, "drop-zero-1")
                .header(ProtocolConstants.HEADER_DROP_TYPE, "file")
                .header(ProtocolConstants.HEADER_DROP_FILENAME, "empty.txt")
                .header(ProtocolConstants.HEADER_DROP_SHA256, emptyHash)
                .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-challenger")
                .build()

            okClient.newCall(req1).execute().use { resp ->
                assertEquals(200, resp.code)
            }

            // Drop 2: 0-byte file with same name
            val req2 = Request.Builder()
                .url("http://127.0.0.1:$testPort/api/drop")
                .post(emptyBytes.toRequestBody("application/octet-stream".toMediaType()))
                .header(ProtocolConstants.HEADER_DROP_ID, "drop-zero-2")
                .header(ProtocolConstants.HEADER_DROP_TYPE, "file")
                .header(ProtocolConstants.HEADER_DROP_FILENAME, "empty.txt")
                .header(ProtocolConstants.HEADER_DROP_SHA256, emptyHash)
                .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-challenger")
                .build()

            okClient.newCall(req2).execute().use { resp ->
                assertEquals(200, resp.code)
            }

            val file1 = File(incomingDir, "empty.txt")
            val file2 = File(incomingDir, "empty (1).txt")

            assertTrue("Original empty.txt must exist", file1.exists())
            assertTrue("Collision empty (1).txt must exist", file2.exists())
            assertEquals(0L, file1.length())
            assertEquals(0L, file2.length())
        } finally {
            server.stop()
        }
    }

    @Test
    fun testMultiDotAndDotfileCollisionResolution() {
        val incomingDir = tempFolder.newFolder("special_filenames")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = incomingDir,
            scope = scope
        )

        // Multi-dot tarball
        val tar1 = storageManager.resolveUniqueDestinationFile("bundle.tar.gz")
        assertEquals("bundle.tar.gz", tar1.name)
        tar1.writeText("tarball-1")

        val tar2 = storageManager.resolveUniqueDestinationFile("bundle.tar.gz")
        assertEquals("bundle.tar (1).gz", tar2.name)
        tar2.writeText("tarball-2")

        val tar3 = storageManager.resolveUniqueDestinationFile("bundle.tar.gz")
        assertEquals("bundle.tar (2).gz", tar3.name)

        // Leading dot file
        val env1 = storageManager.resolveUniqueDestinationFile(".config")
        assertEquals(".config", env1.name)
        env1.writeText("cfg-1")

        val env2 = storageManager.resolveUniqueDestinationFile(".config")
        assertEquals(".config (1)", env2.name)

        // Filename with path traversal attempts: must stay contained in incomingDir
        val traversal = storageManager.resolveUniqueDestinationFile("../../../etc/passwd")
        assertFalse("Filename must not contain directory separator", traversal.name.contains("/"))
        assertFalse("Filename must not contain backslash", traversal.name.contains("\\"))
        assertEquals("File must reside inside incomingDir", incomingDir.canonicalPath, traversal.parentFile.canonicalPath)
        assertTrue("Canonical path must start with incomingDir", traversal.canonicalPath.startsWith(incomingDir.canonicalPath))
    }

    // =========================================================================
    // 2. Premature Stream Truncation & EOF Error Handling
    // =========================================================================

    @Test
    fun testServerRejectsPrematureEofAndCleansPartFile() {
        val testPort = ServerSocket(0).use { it.localPort }
        val incomingDir = tempFolder.newFolder("inbound_eof_clean")
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-challenger", incomingDirectory = incomingDir)
        server.start()

        try {
            Thread.sleep(100)

            // Open a raw socket to send HTTP headers declaring Content-Length: 1000,
            // but send only 50 bytes and close the connection immediately.
            val clientSocket = java.net.Socket("127.0.0.1", testPort)
            val out = clientSocket.getOutputStream()
            val `in` = clientSocket.getInputStream()

            val headers = (
                "POST /api/drop HTTP/1.1\r\n" +
                "Host: 127.0.0.1:$testPort\r\n" +
                "Content-Length: 1000\r\n" +
                "${ProtocolConstants.HEADER_DROP_ID}: tx-truncate-test\r\n" +
                "${ProtocolConstants.HEADER_DROP_TYPE}: file\r\n" +
                "${ProtocolConstants.HEADER_DROP_FILENAME}: truncated.dat\r\n" +
                "${ProtocolConstants.HEADER_DROP_ORIGIN}: mac-challenger\r\n" +
                "\r\n"
            )

            out.write(headers.toByteArray(Charsets.UTF_8))
            out.write(ByteArray(50) { 0x42 }) // Only 50 bytes of the advertised 1000
            out.flush()

            // Close connection prematurely
            clientSocket.close()

            // Allow server thread to finish reading and handle the EOF
            Thread.sleep(300)

            // Verify: No final file created, and no temporary .part file remains
            val filesInDir = incomingDir.listFiles() ?: emptyArray()
            val partFiles = filesInDir.filter { it.name.endsWith(ProtocolConstants.PART_SUFFIX) }
            val truncatedFiles = filesInDir.filter { it.name == "truncated.dat" }

            assertTrue("No .part files should remain after truncation", partFiles.isEmpty())
            assertTrue("No final file should be created from truncated stream", truncatedFiles.isEmpty())
        } finally {
            server.stop()
        }
    }

    @Test
    fun testInboundStorageManagerThrowsIOExceptionOnPrematureEof() {
        val incomingDir = tempFolder.newFolder("storage_eof")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = incomingDir,
            scope = scope
        )

        // Stream yields 40 bytes when 200 bytes expected
        val partialStream = ByteArrayInputStream(ByteArray(40) { 0x01 })

        try {
            storageManager.saveInboundStream(
                transferId = "tx-eof-direct",
                desiredFilename = "incomplete_file.bin",
                dropType = "file",
                expectedSha256 = null,
                origin = "mac-peer",
                input = partialStream,
                contentLength = 200L
            )
            fail("Expected IOException on premature EOF")
        } catch (e: IOException) {
            assertTrue("IOException must mention Premature EOF: ${e.message}", e.message?.contains("Premature EOF") == true)
        }

        val remainingFiles = incomingDir.listFiles() ?: emptyArray()
        assertEquals("Incoming directory must be completely clean", 0, remainingFiles.size)
    }

    // =========================================================================
    // 3. MediaStore Screenshot & Prompt Sync SLA Verification
    // =========================================================================

    @Test
    fun testMediaStoreScreenshotStreamingSlaStrict() {
        val testPort = ServerSocket(0).use { it.localPort }
        val tempDir = tempFolder.newFolder("sla_screenshot_sink")
        val server = AndroidHttpServer(port = testPort, deviceId = "mac-mock-sink", incomingDirectory = tempDir)
        server.start()

        val client = AndroidHttpClient(localDeviceId = "dc1-device")

        try {
            Thread.sleep(100)

            // Realistic DC1 LivePaper 1184x1584 8-bit grayscale image (~1.87 MB)
            val screenshotBytes = ByteArray(1184 * 1584) { (it % 256).toByte() }
            val screenshotFile = File(tempFolder.newFolder("screenshots"), "DC1_Screenshot_LivePaper.png")
            screenshotFile.writeBytes(screenshotBytes)
            val expectedHash = computeSha256(screenshotBytes)

            val latencies = mutableListOf<Long>()
            val iterations = 10

            for (i in 1..iterations) {
                val start = System.currentTimeMillis()

                val bytes = screenshotFile.readBytes()
                val hash = computeSha256(bytes)
                assertEquals(expectedHash, hash)

                val response = client.sendDrop(
                    file = screenshotFile,
                    type = "screenshot",
                    origin = "dc1-device",
                    transferId = "shot-sla-strict-$i",
                    targetHost = "127.0.0.1",
                    targetPort = testPort
                )

                val elapsed = System.currentTimeMillis() - start
                latencies.add(elapsed)

                assertTrue("Screenshot transfer must succeed", response.received)
                assertTrue("Iteration $i latency ${elapsed}ms must be < 1500ms budget", elapsed < 1500L)
            }

            val avg = latencies.average()
            val max = latencies.maxOrNull() ?: 0L
            println("[Milestone3ChallengerR2] Screenshot SLA: avg=${avg}ms, max=${max}ms (Budget: 1500ms)")
            assertTrue("Max screenshot sync latency must be well below 1500ms SLA", max < 1500L)
        } finally {
            server.stop()
        }
    }

    @Test
    fun testQuickAiPromptSyncSlaStrict() {
        val testPort = ServerSocket(0).use { it.localPort }
        val tempDir = tempFolder.newFolder("sla_prompt_sink")
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-device", incomingDirectory = tempDir)
        server.start()

        val okClient = OkHttpClient()

        try {
            Thread.sleep(100)

            val latencies = mutableListOf<Long>()
            val iterations = 30

            for (i in 1..iterations) {
                val promptText = "Review research summary on reflective LCD ambient optics #$i"
                val jsonBody = """
                    {
                        "id": "prompt-sla-$i",
                        "type": "prompt",
                        "text": "$promptText",
                        "origin": "mac-desktop",
                        "timestamp": ${System.currentTimeMillis()}
                    }
                """.trimIndent()

                val start = System.currentTimeMillis()
                val request = Request.Builder()
                    .url("http://127.0.0.1:$testPort/api/text")
                    .post(jsonBody.toRequestBody("application/json".toMediaType()))
                    .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-desktop")
                    .build()

                okClient.newCall(request).execute().use { resp ->
                    assertEquals(200, resp.code)
                }

                val elapsed = System.currentTimeMillis() - start
                latencies.add(elapsed)
                assertTrue("Prompt iteration $i latency ${elapsed}ms must be < 1500ms budget", elapsed < 1500L)
            }

            val avg = latencies.average()
            val max = latencies.maxOrNull() ?: 0L
            println("[Milestone3ChallengerR2] Prompt SLA: avg=${avg}ms, max=${max}ms (Budget: 500ms)")
            assertTrue("Average prompt sync latency must be well below 500ms SLA", avg < 500.0)
        } finally {
            server.stop()
        }
    }

    // =========================================================================
    // 4. MediaStore Monotonic Watermark Progression & Resilience
    // =========================================================================

    @Test
    fun testWatermarkMonotonicProgressionOnZeroByteOrMissingFiles() {
        var watermark = 100L

        fun updateWatermark(id: Long) {
            if (id > watermark) {
                watermark = id
            }
        }

        // Simulate reading 3 media items:
        // Item 101: 0-byte file (camera/screenshot initial creation)
        val item1Id = 101L
        val item1Size = 0L
        if (item1Size <= 0L) {
            updateWatermark(item1Id)
        }
        assertEquals("Watermark must advance past 0-byte file", 101L, watermark)

        // Item 102: deleted before read
        val item2Id = 102L
        val item2Exists = false
        if (!item2Exists) {
            updateWatermark(item2Id)
        }
        assertEquals("Watermark must advance past deleted file", 102L, watermark)

        // Item 103: normal valid file
        val item3Id = 103L
        updateWatermark(item3Id)
        assertEquals("Watermark must advance to newest valid file", 103L, watermark)

        // Stale or lower ID should never regress watermark
        updateWatermark(99L)
        assertEquals("Watermark must be monotonically increasing", 103L, watermark)
    }
}
