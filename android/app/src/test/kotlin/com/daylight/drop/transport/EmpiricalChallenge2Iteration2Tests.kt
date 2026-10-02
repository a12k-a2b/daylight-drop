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

class EmpiricalChallenge2Iteration2Tests {

    private val emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: - 1. Interleaved Traffic Stress Tests

    @Test
    fun testInterleavedZeroByteTextAndImageStreams() {
        val serverDir = File(System.getProperty("java.io.tmpdir"), "android_interleaved_srv_" + UUID.randomUUID())
        val clientDir = File(System.getProperty("java.io.tmpdir"), "android_interleaved_cli_" + UUID.randomUUID())
        serverDir.mkdirs()
        clientDir.mkdirs()

        try {
            val testPort = 18861
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = "dc1-interleaved-server",
                incomingDirectory = serverDir
            )

            val receivedDrops = ConcurrentHashMap<String, Triple<String, String, Long>>()
            val receivedTexts = ConcurrentHashMap<String, String>()

            server.onDropReceived = { txId, filename, type, file, sha256 ->
                receivedDrops[txId] = Triple(filename, sha256, file.length())
            }

            server.onTextReceived = { payload ->
                receivedTexts[payload.id] = payload.text
            }

            server.start()
            try {
                Thread.sleep(150)
                val client = AndroidHttpClient(localDeviceId = "mac-interleaved-client")
                val cycles = 10

                for (i in 0 until cycles) {
                    // 1. 0-Byte File Drop
                    val zeroFile = File(clientDir, "empty_$i.txt")
                    zeroFile.createNewFile()
                    val txZeroId = "tx-zero-$i"
                    val zeroResp = client.sendDrop(
                        file = zeroFile,
                        type = "file",
                        origin = "mac-interleaved-client",
                        transferId = txZeroId,
                        targetHost = "127.0.0.1",
                        targetPort = testPort
                    )
                    assertEquals("ok", zeroResp.status)
                    assertTrue(zeroResp.received)
                    assertEquals(0L, zeroResp.bytes)
                    assertEquals(emptyHash, zeroResp.sha256)

                    // 2. Multiline Unicode Prompt Text
                    val promptId = "prompt-interleaved-$i"
                    val promptText = "Interleaved cycle $i prompt:\nLine 2: 🚀 Sol:OS 8-bit Gray Scale\nLine 3: Specially formatted \"quotes\" and brackets [OK]."
                    val payload = TextPayload(
                        id = promptId,
                        type = "prompt",
                        text = promptText,
                        origin = "mac-interleaved-client",
                        timestamp = System.currentTimeMillis()
                    )
                    val promptResp = client.sendText(
                        payload = payload,
                        targetHost = "127.0.0.1",
                        targetPort = testPort
                    )
                    assertTrue(promptResp.contains(promptId))
                    assertTrue(promptResp.contains("\"received\":true"))

                    // 3. Binary Image Stream (128KB)
                    val imgSize = 128 * 1024
                    val imgData = ByteArray(imgSize) { ((it + i) % 256).toByte() }
                    val imgFile = File(clientDir, "screenshot_$i.png")
                    imgFile.writeBytes(imgData)
                    val expectedImgHash = LoopSuppressionEngine.computeSha256(imgData)
                    val txImgId = "tx-img-$i"
                    val imgResp = client.sendDrop(
                        file = imgFile,
                        type = "image",
                        origin = "mac-interleaved-client",
                        transferId = txImgId,
                        targetHost = "127.0.0.1",
                        targetPort = testPort
                    )
                    assertEquals("ok", imgResp.status)
                    assertTrue(imgResp.received)
                    assertEquals(imgSize.toLong(), imgResp.bytes)
                    assertEquals(expectedImgHash, imgResp.sha256)
                }

                Thread.sleep(100)
                assertEquals(cycles * 2, receivedDrops.size)
                assertEquals(cycles, receivedTexts.size)

                // Verify no .part files remain
                val parts = serverDir.listFiles { _, name -> name.endsWith(".part") } ?: emptyArray()
                assertEquals(0, parts.size)
            } finally {
                server.stop()
            }
        } finally {
            serverDir.deleteRecursively()
            clientDir.deleteRecursively()
        }
    }

    @Test
    fun testConcurrentInterleavedStreams() {
        val serverDir = File(System.getProperty("java.io.tmpdir"), "android_conc_interleaved_srv_" + UUID.randomUUID())
        val clientDir = File(System.getProperty("java.io.tmpdir"), "android_conc_interleaved_cli_" + UUID.randomUUID())
        serverDir.mkdirs()
        clientDir.mkdirs()

        try {
            val testPort = 18862
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = "dc1-conc-interleaved-server",
                incomingDirectory = serverDir
            )

            server.start()
            try {
                Thread.sleep(150)
                val totalWorkers = 10
                val executor = Executors.newFixedThreadPool(totalWorkers)
                val latch = CountDownLatch(totalWorkers)
                val successCount = AtomicInteger(0)
                val client = AndroidHttpClient(localDeviceId = "mac-worker")

                for (i in 0 until totalWorkers) {
                    executor.execute {
                        try {
                            // 1. 0-byte drop
                            val zFile = File(clientDir, "w_${i}_zero.txt")
                            zFile.createNewFile()
                            val zResp = client.sendDrop(
                                file = zFile,
                                type = "file",
                                origin = "worker-$i",
                                transferId = "conc-zero-$i",
                                targetHost = "127.0.0.1",
                                targetPort = testPort
                            )
                            if (zResp.status != "ok" || zResp.bytes != 0L || zResp.sha256 != emptyHash) return@execute

                            // 2. prompt
                            val pPayload = TextPayload(
                                id = "conc-p-$i",
                                type = "prompt",
                                text = "Concurrent prompt from worker $i",
                                origin = "worker-$i",
                                timestamp = System.currentTimeMillis()
                            )
                            val pResp = client.sendText(pPayload, targetHost = "127.0.0.1", targetPort = testPort)
                            if (!pResp.contains("conc-p-$i") || !pResp.contains("\"received\":true")) return@execute

                            // 3. image stream (64KB)
                            val iData = ByteArray(64 * 1024) { i.toByte() }
                            val iFile = File(clientDir, "w_${i}_img.png")
                            iFile.writeBytes(iData)
                            val iResp = client.sendDrop(
                                file = iFile,
                                type = "image",
                                origin = "worker-$i",
                                transferId = "conc-img-$i",
                                targetHost = "127.0.0.1",
                                targetPort = testPort
                            )
                            if (iResp.status != "ok" || iResp.bytes != 65536L) return@execute

                            successCount.incrementAndGet()
                        } catch (_: Exception) {
                        } finally {
                            latch.countDown()
                        }
                    }
                }

                assertTrue("All concurrent workers must finish within 10s", latch.await(10, TimeUnit.SECONDS))
                assertEquals(totalWorkers, successCount.get())

                val parts = serverDir.listFiles { _, name -> name.endsWith(".part") } ?: emptyArray()
                assertEquals(0, parts.size)
                executor.shutdown()
            } finally {
                server.stop()
            }
        } finally {
            serverDir.deleteRecursively()
            clientDir.deleteRecursively()
        }
    }

    @Test
    fun testConsecutiveZeroByteFilesAndEmptyPrompt() {
        val serverDir = File(System.getProperty("java.io.tmpdir"), "android_empty_consec_" + UUID.randomUUID())
        val clientDir = File(System.getProperty("java.io.tmpdir"), "android_empty_consec_cli_" + UUID.randomUUID())
        serverDir.mkdirs()
        clientDir.mkdirs()

        try {
            val testPort = 18863
            val server = AndroidHttpServer(
                port = testPort,
                deviceId = "dc1-empty-consec-server",
                incomingDirectory = serverDir
            )

            server.start()
            try {
                Thread.sleep(150)
                val client = AndroidHttpClient(localDeviceId = "mac-empty-client")

                // Step 1: 0-byte file drop #1
                val f1 = File(clientDir, "consec_1.txt")
                f1.createNewFile()
                val r1 = client.sendDrop(f1, "file", "mac-empty-client", "tx-consec-1", "127.0.0.1", testPort)
                assertEquals("ok", r1.status)
                assertEquals(emptyHash, r1.sha256)

                // Step 2: 0-byte file drop #2
                val f2 = File(clientDir, "consec_2.txt")
                f2.createNewFile()
                val r2 = client.sendDrop(f2, "file", "mac-empty-client", "tx-consec-2", "127.0.0.1", testPort)
                assertEquals("ok", r2.status)
                assertEquals(emptyHash, r2.sha256)

                // Step 3: empty text prompt (computes emptyHash)
                val pEmpty = TextPayload("p-empty", "prompt", "", "mac-empty-client", System.currentTimeMillis())
                val r3 = client.sendText(pEmpty, targetHost = "127.0.0.1", targetPort = testPort)
                // Because emptyHash was recorded by f1 and f2 in loopSuppression, empty text prompt should be suppressed
                assertTrue(r3.contains("\"suppressed\":true") || r3.contains("\"received\":false"))

                // Step 4: normal text prompt after empty prompt
                val pNormal = TextPayload("p-normal", "prompt", "Hello World", "mac-empty-client", System.currentTimeMillis())
                val r4 = client.sendText(pNormal, targetHost = "127.0.0.1", targetPort = testPort)
                assertTrue(r4.contains("\"received\":true"))
            } finally {
                server.stop()
            }
        } finally {
            serverDir.deleteRecursively()
            clientDir.deleteRecursively()
        }
    }
}
