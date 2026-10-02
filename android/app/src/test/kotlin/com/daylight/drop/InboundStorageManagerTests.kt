package com.daylight.drop

import com.daylight.drop.transport.LoopSuppressionEngine
import com.daylight.drop.transport.ProtocolConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException

class InboundStorageManagerTests {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun testResolveUniqueDestinationFileNoCollision() {
        val dir = tempFolder.newFolder("downloads_nocollision")
        val target = InboundStorageManager.resolveUniqueDestinationFile(dir, "sample.png")
        assertEquals("sample.png", target.name)
        assertEquals(dir.absolutePath, target.parentFile?.absolutePath)
    }



    @Test
    fun testResolveUniqueDestinationFileWithCollision() {
        val dir = tempFolder.newFolder("downloads_collision")
        val file1 = File(dir, "report.pdf").apply { writeText("original") }
        assertTrue(file1.exists())

        // First collision -> report (1).pdf
        val target1 = InboundStorageManager.resolveUniqueDestinationFile(dir, "report.pdf")
        assertEquals("report (1).pdf", target1.name)
        target1.writeText("second")

        // Second collision -> report (2).pdf
        val target2 = InboundStorageManager.resolveUniqueDestinationFile(dir, "report.pdf")
        assertEquals("report (2).pdf", target2.name)

        // File with no extension
        val noExt = File(dir, "README").apply { writeText("readme 0") }
        val targetNoExt = InboundStorageManager.resolveUniqueDestinationFile(dir, "README")
        assertEquals("README (1)", targetNoExt.name)

        // Hidden/dot file
        val dotFile = File(dir, ".env").apply { writeText("secret") }
        val targetDot = InboundStorageManager.resolveUniqueDestinationFile(dir, ".env")
        assertEquals(".env (1)", targetDot.name)
    }

    @Test
    fun testFilenameSanitizationDirectCall() {
        val dirtyName = "test/file\\with?illegal*chars:and\"pipes|<>.pdf"
        val sanitized = InboundStorageManager.sanitizeFilename(dirtyName)

        assertEquals("test_file_with_illegal_chars_and_pipes___.pdf", sanitized)
        assertFalse(sanitized.contains("/"))
        assertFalse(sanitized.contains("\\"))
        assertFalse(sanitized.contains("?"))
        assertFalse(sanitized.contains("*"))
        assertFalse(sanitized.contains(":"))
        assertFalse(sanitized.contains("|"))
        assertFalse(sanitized.contains("\""))
        assertFalse(sanitized.contains("<"))
        assertFalse(sanitized.contains(">"))
        assertTrue(sanitized.endsWith(".pdf"))

        val spaced = InboundStorageManager.sanitizeFilename("   document.docx   ")
        assertEquals("document.docx", spaced)
    }

    @Test
    fun testSaveInboundStreamValidWithChecksum() {
        val dir = tempFolder.newFolder("downloads_stream_valid")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = dir,
            scope = scope
        )

        val payload = "Authentic inbound stream content for Daylight Drop".toByteArray(Charsets.UTF_8)
        val hash = LoopSuppressionEngine.computeSha256(payload)

        val saved = storageManager.saveInboundStream(
            transferId = "tx-valid-01",
            desiredFilename = "notes.txt",
            dropType = "document",
            expectedSha256 = hash,
            origin = "mac-peer",
            input = ByteArrayInputStream(payload),
            contentLength = payload.size.toLong()
        )

        assertTrue("Saved file must exist on disk", saved.exists())
        assertEquals("notes.txt", saved.name)
        assertEquals("Authentic inbound stream content for Daylight Drop", saved.readText())
        assertTrue("Hash must be recorded in loop suppression", loop.shouldSuppress(hash))
    }

    @Test
    fun testSaveInboundStreamCollisionResolution() {
        val dir = tempFolder.newFolder("downloads_stream_collision")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = dir,
            scope = scope
        )

        // Pre-create existing file
        val existing = File(dir, "data.csv").apply { writeText("original data") }
        assertTrue(existing.exists())

        val payload = "new colliding data".toByteArray(Charsets.UTF_8)
        val saved = storageManager.saveInboundStream(
            transferId = "tx-col-01",
            desiredFilename = "data.csv",
            dropType = "document",
            expectedSha256 = null,
            origin = "mac-peer",
            input = ByteArrayInputStream(payload),
            contentLength = payload.size.toLong()
        )

        assertTrue("Original file must be preserved", existing.exists())
        assertEquals("original data", existing.readText())
        assertEquals("data (1).csv", saved.name)
        assertEquals("new colliding data", saved.readText())
    }

    @Test
    fun testSaveInboundStreamChecksumMismatchThrowsAndDeletesTemp() {
        val dir = tempFolder.newFolder("downloads_stream_mismatch")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = dir,
            scope = scope
        )

        val payload = "Corrupted data payload".toByteArray(Charsets.UTF_8)
        val incorrectHash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"

        try {
            storageManager.saveInboundStream(
                transferId = "tx-mismatch",
                desiredFilename = "corrupted.bin",
                dropType = "file",
                expectedSha256 = incorrectHash,
                origin = "mac-peer",
                input = ByteArrayInputStream(payload),
                contentLength = payload.size.toLong()
            )
            fail("Expected IOException on checksum mismatch")
        } catch (e: IOException) {
            assertTrue(e.message?.contains("Checksum mismatch") == true)
        }

        val remainingFiles = dir.listFiles() ?: emptyArray()
        assertTrue("No corrupt or part files should remain", remainingFiles.isEmpty())
    }

    @Test
    fun testSaveInboundStreamPrematureEofThrowsAndDeletesTemp() {
        val dir = tempFolder.newFolder("downloads_stream_eof")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = dir,
            scope = scope
        )

        // Advertised 500 bytes but only 30 bytes in stream
        val partialPayload = ByteArray(30) { 0x33 }

        try {
            storageManager.saveInboundStream(
                transferId = "tx-eof",
                desiredFilename = "incomplete.bin",
                dropType = "file",
                expectedSha256 = null,
                origin = "mac-peer",
                input = ByteArrayInputStream(partialPayload),
                contentLength = 500L
            )
            fail("Expected IOException on premature EOF")
        } catch (e: IOException) {
            assertTrue(e.message?.contains("Premature EOF") == true)
        }

        val remainingFiles = dir.listFiles() ?: emptyArray()
        assertTrue("No incomplete part files should remain after premature EOF", remainingFiles.isEmpty())
    }

    @Test
    fun testMimeTypeNullSafety() {
        val dir = tempFolder.newFolder("downloads_mime")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = dir,
            scope = scope
        )

        val file = File(dir, "test.pdf")
        val mime = storageManager.getMimeType(file)
        assertNotNull(mime)
        assertTrue(mime.isNotEmpty())
    }

    @Test
    fun testConcurrentCollidingDropsPreservedWithoutOverwrite() {
        val dir = tempFolder.newFolder("downloads_concurrent")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val loop = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val storageManager = InboundStorageManager(
            context = object : android.content.ContextWrapper(null) {},
            loopSuppression = loop,
            incomingDir = dir,
            scope = scope
        )

        val threadCount = 10
        val executor = java.util.concurrent.Executors.newFixedThreadPool(threadCount)
        val latch = java.util.concurrent.CountDownLatch(threadCount)
        val readyLatch = java.util.concurrent.CountDownLatch(threadCount)
        val savedFiles = java.util.Collections.synchronizedList(mutableListOf<File>())
        val errors = java.util.Collections.synchronizedList(mutableListOf<Throwable>())

        for (i in 0 until threadCount) {
            executor.submit {
                readyLatch.countDown()
                readyLatch.await()
                try {
                    val content = "Thread-$i unique payload content".toByteArray(Charsets.UTF_8)
                    val saved = storageManager.saveInboundStream(
                        transferId = "tx-conc-$i",
                        desiredFilename = "shared_document.txt",
                        dropType = "document",
                        expectedSha256 = null,
                        origin = "mac-peer-$i",
                        input = ByteArrayInputStream(content),
                        contentLength = content.size.toLong()
                    )
                    savedFiles.add(saved)
                } catch (t: Throwable) {
                    errors.add(t)
                } finally {
                    latch.countDown()
                }
            }
        }

        assertTrue("All threads must finish within timeout", latch.await(10, java.util.concurrent.TimeUnit.SECONDS))
        executor.shutdown()

        assertTrue("No exceptions during concurrent drops: $errors", errors.isEmpty())
        assertEquals("All $threadCount drops must yield saved files", threadCount, savedFiles.size)

        val uniqueNames = savedFiles.map { it.name }.toSet()
        assertEquals("All $threadCount filenames must be unique", threadCount, uniqueNames.size)

        val filesOnDisk = dir.listFiles { _, name -> !name.startsWith(".") } ?: emptyArray()
        assertEquals("Exactly $threadCount files must exist on disk", threadCount, filesOnDisk.size)

        val contentsOnDisk = filesOnDisk.map { it.readText() }.toSet()
        for (i in 0 until threadCount) {
            val expectedContent = "Thread-$i unique payload content"
            assertTrue("Expected content '$expectedContent' must be present in one of the files", contentsOnDisk.contains(expectedContent))
        }
    }
}
