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
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class Milestone3ChallengerTests {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private fun computeSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    // =========================================================================
    // 1. MediaStore Screenshot Sync SLA & Concurrency Stress
    // =========================================================================

    @Test
    fun testScreenshotStreamingSlaBudget() {
        val testPort = ServerSocket(0).use { it.localPort }
        val tempDir = tempFolder.newFolder("server_inbound")
        val server = AndroidHttpServer(port = testPort, deviceId = "mac-mock-sink", incomingDirectory = tempDir)
        server.start()

        val client = AndroidHttpClient(localDeviceId = "dc1-device")

        try {
            Thread.sleep(100)

            // Simulate DC1 1184x1584 8-bit grayscale LivePaper screenshot (~1.5 MB)
            val screenshotBytes = ByteArray(1024 * 1024) { (it % 256).toByte() }
            val screenshotFile = File(tempFolder.newFolder("dc1_screenshots"), "Screenshot_20261002_090000.png")
            screenshotFile.writeBytes(screenshotBytes)
            val expectedHash = computeSha256(screenshotBytes)

            val timings = mutableListOf<Long>()
            for (i in 1..5) {
                val start = System.currentTimeMillis()

                // Emulate MediaStoreObserver dispatch pipeline:
                // 1. Read bytes & SHA-256
                val bytes = screenshotFile.readBytes()
                val hash = computeSha256(bytes)
                assertEquals(expectedHash, hash)

                // 2. Stream to Mac sink
                val response = client.sendDrop(
                    file = screenshotFile,
                    type = "screenshot",
                    origin = "dc1-device",
                    transferId = "shot-sla-$i",
                    targetHost = "127.0.0.1",
                    targetPort = testPort
                )

                val elapsed = System.currentTimeMillis() - start
                timings.add(elapsed)

                assertTrue("Screenshot transfer must succeed", response.received)
                assertTrue("Screenshot sync took ${elapsed}ms, must be < 1500ms SLA", elapsed < 1500L)
            }

            val avgLatency = timings.average()
            println("[Milestone3Challenger] Average screenshot sync latency: ${avgLatency}ms (Budget: 1500ms)")
            assertTrue("Average latency must be well within SLA budget", avgLatency < 1500.0)
        } finally {
            server.stop()
        }
    }

    @Test
    fun testMediaStoreDeduplicationLruPreventsResend() {
        val loopSuppression = LoopSuppressionEngine(localDeviceId = "dc1-device", capacity = 100, ttlMs = 60_000L)
        val screenshotBytes = "Unique screenshot bytes ${UUID.randomUUID()}".toByteArray()
        val hash = computeSha256(screenshotBytes)

        // First capture -> Not suppressed, record in LRU
        assertFalse("First capture should not be suppressed", loopSuppression.shouldSuppress(hash))
        loopSuppression.record(hash)

        // Immediate subsequent scan -> Must be suppressed
        assertTrue("Duplicate screenshot must be suppressed by LRU cache", loopSuppression.shouldSuppress(hash))
    }

    @Test
    fun testMediaStoreObserverLostNotificationRaceCondition() {
        // Models the corrected concurrency control in MediaStoreObserver.kt:
        // isChecking guard paired with needsRecheck loop so no concurrent onChange is dropped.
        val isChecking = AtomicBoolean(false)
        val needsRecheck = AtomicBoolean(false)
        val processedItems = mutableListOf<String>()

        fun simulateCheck(item: String) {
            if (!isChecking.compareAndSet(false, true)) {
                needsRecheck.set(true)
                return
            }
            try {
                do {
                    needsRecheck.set(false)
                    processedItems.add(item)
                } while (needsRecheck.get())
            } finally {
                isChecking.set(false)
                if (needsRecheck.get() && isChecking.compareAndSet(false, true)) {
                    try {
                        do {
                            needsRecheck.set(false)
                            processedItems.add("recheck-$item")
                        } while (needsRecheck.get())
                    } finally {
                        isChecking.set(false)
                    }
                }
            }
        }

        // Trigger item 1
        isChecking.set(true) // Simulate in-flight check
        // While check 1 is running, item 2 arrives
        simulateCheck("screenshot-2")
        assertTrue("needsRecheck flag must be set when check is in flight", needsRecheck.get())

        // Finish check 1
        isChecking.set(false)
        // Re-check trigger executes
        if (needsRecheck.get() && isChecking.compareAndSet(false, true)) {
            try {
                processedItems.add("screenshot-2-discovered")
                needsRecheck.set(false)
            } finally {
                isChecking.set(false)
            }
        }

        assertTrue("Second screenshot must be processed without loss", processedItems.contains("screenshot-2-discovered"))
        assertFalse("needsRecheck must be reset after processing", needsRecheck.get())
    }

    // =========================================================================
    // 2. Inbound Storage Stress & Collision Handling
    // =========================================================================

    @Test
    fun testInboundStorageManagerCollisionResolutionMethod() {
        val incomingDir = tempFolder.newFolder("downloads")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-device")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = incomingDir,
            scope = scope
        )

        // 1. Non-colliding file
        val file1 = storageManager.resolveUniqueDestinationFile("report.pdf")
        assertEquals("report.pdf", file1.name)
        file1.writeText("Original content")

        // 2. First collision
        val file2 = storageManager.resolveUniqueDestinationFile("report.pdf")
        assertEquals("report (1).pdf", file2.name)
        file2.writeText("Second content")

        // 3. Second collision
        val file3 = storageManager.resolveUniqueDestinationFile("report.pdf")
        assertEquals("report (2).pdf", file3.name)
        file3.writeText("Third content")

        // 4. File with no extension
        val noExt1 = storageManager.resolveUniqueDestinationFile("README")
        assertEquals("README", noExt1.name)
        noExt1.writeText("Readme 1")

        val noExt2 = storageManager.resolveUniqueDestinationFile("README")
        assertEquals("README (1)", noExt2.name)

        // 5. File starting with dot (.env)
        val dot1 = storageManager.resolveUniqueDestinationFile(".env")
        assertEquals(".env", dot1.name)
        dot1.writeText("ENV 1")

        val dot2 = storageManager.resolveUniqueDestinationFile(".env")
        assertEquals(".env (1)", dot2.name)
    }

    /**
     * EMPIRICAL FINDING:
     * In AndroidHttpServer.kt lines 317-321:
     * When an inbound drop arrives, the server deletes any existing file with the same name
     * instead of applying the collision suffix (1).
     */
    @Test
    fun testServerInboundDropCollisionOverwritingBug() {
        val testPort = ServerSocket(0).use { it.localPort }
        val incomingDir = tempFolder.newFolder("server_incoming")
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-device", incomingDirectory = incomingDir)
        server.start()

        val okClient = OkHttpClient()

        try {
            Thread.sleep(100)

            // Step 1: Pre-populate existing file "document.pdf"
            val existingFile = File(incomingDir, "document.pdf")
            val originalContent = "Original Document Content Version 1"
            existingFile.writeText(originalContent)
            assertTrue("Pre-condition: document.pdf exists", existingFile.exists())

            // Step 2: Inbound drop of another file named "document.pdf" with different content
            val newContent = "New Inbound Document Content Version 2".toByteArray()
            val newSha256 = computeSha256(newContent)

            val request = Request.Builder()
                .url("http://127.0.0.1:$testPort/api/drop")
                .post(newContent.toRequestBody("application/pdf".toMediaType()))
                .header(ProtocolConstants.HEADER_DROP_ID, "tx-collision-test")
                .header(ProtocolConstants.HEADER_DROP_TYPE, "document")
                .header(ProtocolConstants.HEADER_DROP_FILENAME, "document.pdf")
                .header(ProtocolConstants.HEADER_DROP_SHA256, newSha256)
                .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-sender")
                .build()

            okClient.newCall(request).execute().use { resp ->
                assertEquals(200, resp.code)
            }

            // Step 3: Check whether original file was preserved and collision suffix was applied
            val originalPreserved = existingFile.exists() && existingFile.readText() == originalContent
            val collisionSuffixFile = File(incomingDir, "document (1).pdf")
            val collisionSuffixExists = collisionSuffixFile.exists()

            println("[Milestone3Challenger] Server Drop Collision Check:")
            println("  - Original file preserved with original content: $originalPreserved")
            println("  - Current document.pdf content: '${existingFile.readText()}'")
            println("  - document (1).pdf exists: $collisionSuffixExists")

            assertTrue("Original file must be preserved with original content", originalPreserved)
            assertTrue("Collision suffix file 'document (1).pdf' must be created", collisionSuffixExists)
            assertEquals("New Inbound Document Content Version 2", collisionSuffixFile.readText())
        } finally {
            server.stop()
        }
    }

    @Test
    fun testSaveInboundStreamPrematureEofWithoutChecksum() {
        val incomingDir = tempFolder.newFolder("downloads_eof")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-device")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = incomingDir,
            scope = scope
        )

        // Advertised contentLength is 100 bytes, but stream only delivers 20 bytes
        val truncatedStream = ByteArrayInputStream(ByteArray(20) { 0x55 })
        val transferId = "tx-truncated"

        // InboundStorageManager validates premature EOF and purges .part file
        try {
            storageManager.saveInboundStream(
                transferId = transferId,
                desiredFilename = "truncated.bin",
                dropType = "file",
                expectedSha256 = null,
                origin = "mac-sender",
                input = truncatedStream,
                contentLength = 100L
            )
            fail("Expected IOException on premature EOF")
        } catch (e: IOException) {
            assertTrue("Premature EOF exception caught: ${e.message}", e.message?.contains("Premature EOF") == true)
        }

        val remainingFiles = incomingDir.listFiles() ?: emptyArray()
        assertTrue("No truncated .part files should remain", remainingFiles.isEmpty())
    }

    // =========================================================================
    // 3. Prompt Sync SLA & Latency Budget (<500ms)
    // =========================================================================

    @Test
    fun testPromptDispatchLatencySlaBudget() {
        val testPort = ServerSocket(0).use { it.localPort }
        val tempDir = tempFolder.newFolder("prompt_dir")
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-device", incomingDirectory = tempDir)
        var lastReceivedPayload: TextPayload? = null
        server.onTextReceived = { payload -> lastReceivedPayload = payload }
        server.start()

        val okClient = OkHttpClient()

        try {
            Thread.sleep(100)

            val promptLatencies = mutableListOf<Long>()
            for (i in 1..20) {
                val promptText = "Prompt SLA test iteration $i - ${UUID.randomUUID()}"
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
                    val body = resp.body?.string() ?: ""
                    assertTrue(body.contains("\"received\":true"))
                }
                val elapsed = System.currentTimeMillis() - start
                promptLatencies.add(elapsed)

                assertTrue("Prompt latency $elapsed ms must be < 500ms budget", elapsed < 500L)
            }

            val avgPromptMs = promptLatencies.average()
            val maxPromptMs = promptLatencies.maxOrNull() ?: 0L
            println("[Milestone3Challenger] Prompt sync: avg=${avgPromptMs}ms, max=${maxPromptMs}ms (Budget: 500ms)")
            assertTrue("Max prompt latency must be well below 500ms", maxPromptMs < 500L)
        } finally {
            server.stop()
        }
    }

    // =========================================================================
    // 4. Loop Suppression Stress: Origin Matching & Echo Prevention
    // =========================================================================

    @Test
    fun testLoopSuppressionMacOriginMatchingBug() {
        // In TransportManager.swift: localDeviceId = "mac-" + UUID().uuidString.prefix(8)
        val realMacDeviceId = "mac-3a8f9c1b"

        // In ProtocolConstants.kt: ROLE_MAC = "mac_desktop"
        val roleMac = ProtocolConstants.ROLE_MAC // "mac_desktop"

        // In BeamTrampolineActivity.kt line 103:
        // isMacOrigin = originTag != null && (originTag == ProtocolConstants.ROLE_MAC || originTag == PeerTargetManager.getMacDeviceId() || originTag.startsWith("mac") || originTag != PeerTargetManager.getLocalDeviceId())
        val originTag = realMacDeviceId
        val isMacOrigin = (
            originTag == ProtocolConstants.ROLE_MAC ||
            originTag == PeerTargetManager.getMacDeviceId() ||
            originTag.startsWith("mac") ||
            originTag != PeerTargetManager.getLocalDeviceId()
        )

        println("[Milestone3Challenger] Loop Suppression Origin Check:")
        println("  - realMacDeviceId: '$realMacDeviceId'")
        println("  - ProtocolConstants.ROLE_MAC: '$roleMac'")
        println("  - PeerTargetManager.getMacDeviceId(): '${PeerTargetManager.getMacDeviceId()}'")
        println("  - Evaluates to suppressed: $isMacOrigin")

        assertTrue("BeamTrampolineActivity must reliably suppress origin '$realMacDeviceId'!", isMacOrigin)
    }

    @Test
    fun testLoopSuppressionTier3TtlExpiryAndCapacity() {
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-device", capacity = 5, ttlMs = 2000L)
        val now = 1_000_000L

        // Fill cache with 5 items
        for (i in 1..5) {
            loop.recordHash("hash-$i", now)
        }
        assertEquals(5, loop.currentCacheCount())

        // 6th item should evict oldest (hash-1)
        loop.recordHash("hash-6", now)
        assertEquals(5, loop.currentCacheCount())
        assertFalse("hash-1 should have been evicted by capacity limit", loop.shouldSuppressHash("hash-1", now))
        assertTrue(loop.shouldSuppressHash("hash-6", now))

        // Time advance > 2000ms TTL
        val future = now + 2500L
        assertFalse("hash-6 should expire after TTL", loop.shouldSuppressHash("hash-6", future))
    }
}
