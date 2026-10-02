package com.daylight.drop.transport

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.UUID

class AndroidChallengerCorruptionTests {

    private fun computeSha256(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(bytes).joinToString("") { "%02x".format(it) }
    }

    @Test
    fun testCorruptionScenarios() {
        val tempDir = File(System.getProperty("java.io.tmpdir"), "corrupt_android_" + UUID.randomUUID())
        tempDir.mkdirs()
        
        val testPort = ServerSocket(0).use { it.localPort }
        val server = AndroidHttpServer(port = testPort, deviceId = "dc1-corrupt-server", incomingDirectory = tempDir)
        server.start()

        val okClient = OkHttpClient()

        try {
            Thread.sleep(150)

            // 1. Mismatched SHA-256 header
            val payload1 = "Valid payload bytes for test 1".toByteArray()
            val bogusSha1 = "0000000000000000000000000000000000000000000000000000000000000000"
            val req1 = Request.Builder()
                .url("http://127.0.0.1:$testPort/api/drop")
                .post(payload1.toRequestBody("application/octet-stream".toMediaType()))
                .header(ProtocolConstants.HEADER_DROP_ID, "corrupt-tx-1")
                .header(ProtocolConstants.HEADER_DROP_TYPE, "file")
                .header(ProtocolConstants.HEADER_DROP_FILENAME, "test1.bin")
                .header(ProtocolConstants.HEADER_DROP_SHA256, bogusSha1)
                .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-tester")
                .build()

            okClient.newCall(req1).execute().use { resp ->
                assertEquals(400, resp.code)
                val body = resp.body?.string() ?: ""
                assertTrue(body.contains("checksum_mismatch"))
            }
            assertFalse(File(tempDir, ".tmp_corrupt-tx-1_test1.bin.part").exists())
            assertFalse(File(tempDir, "test1.bin").exists())

            // 2. In-Transit Bit-Flip Corruption
            val origPayload = ByteArray(65536) { 0x41 }
            val origSha = computeSha256(origPayload)
            val corruptPayload = origPayload.clone()
            corruptPayload[32768] = 0x42 // flip 1 byte

            val req2 = Request.Builder()
                .url("http://127.0.0.1:$testPort/api/drop")
                .post(corruptPayload.toRequestBody("application/octet-stream".toMediaType()))
                .header(ProtocolConstants.HEADER_DROP_ID, "corrupt-tx-2")
                .header(ProtocolConstants.HEADER_DROP_TYPE, "file")
                .header(ProtocolConstants.HEADER_DROP_FILENAME, "test2.bin")
                .header(ProtocolConstants.HEADER_DROP_SHA256, origSha)
                .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-tester")
                .build()

            okClient.newCall(req2).execute().use { resp ->
                assertEquals(400, resp.code)
                val body = resp.body?.string() ?: ""
                assertTrue(body.contains("checksum_mismatch"))
            }
            assertFalse(File(tempDir, ".tmp_corrupt-tx-2_test2.bin.part").exists())
            assertFalse(File(tempDir, "test2.bin").exists())

            // 3. Path Traversal Filename Sanitization
            val evilFilename = "../../../../tmp/evil_android.sh"
            val safePayload = "echo safe\n".toByteArray()
            val safeSha = computeSha256(safePayload)

            val req3 = Request.Builder()
                .url("http://127.0.0.1:$testPort/api/drop")
                .post(safePayload.toRequestBody("application/octet-stream".toMediaType()))
                .header(ProtocolConstants.HEADER_DROP_ID, "traversal-tx-3")
                .header(ProtocolConstants.HEADER_DROP_TYPE, "file")
                .header(ProtocolConstants.HEADER_DROP_FILENAME, evilFilename)
                .header(ProtocolConstants.HEADER_DROP_SHA256, safeSha)
                .header(ProtocolConstants.HEADER_DROP_ORIGIN, "mac-tester")
                .build()

            okClient.newCall(req3).execute().use { resp ->
                assertEquals(200, resp.code)
                val body = resp.body?.string() ?: ""
                assertTrue(body.contains("\"filename\":\"evil_android.sh\""))
            }
            val sanitizedFile = File(tempDir, "evil_android.sh")
            assertTrue(sanitizedFile.exists())
            assertFalse(File("/tmp/evil_android.sh").exists())
            sanitizedFile.delete()

            // 4. Truncated Stream / Socket Disconnect
            val s = Socket("127.0.0.1", testPort)
            val headerStr = "POST /api/drop HTTP/1.1\r\n" +
                    "Host: 127.0.0.1\r\n" +
                    "X-Daylight-Drop-Id: abort-tx-4\r\n" +
                    "X-Daylight-Drop-Type: file\r\n" +
                    "X-Daylight-Drop-Filename: aborted.bin\r\n" +
                    "X-Daylight-Drop-Sha256: 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef\r\n" +
                    "X-Daylight-Drop-Origin: mac-tester\r\n" +
                    "Content-Length: 1048576\r\n" +
                    "Content-Type: application/octet-stream\r\n\r\n"
            s.getOutputStream().write(headerStr.toByteArray())
            s.getOutputStream().write(ByteArray(32768) { 0x55 })
            s.close()
            Thread.sleep(300)

            assertFalse("Part file must be cleaned up on socket disconnect", File(tempDir, ".tmp_abort-tx-4_aborted.bin.part").exists())
            assertFalse(File(tempDir, "aborted.bin").exists())

            // 5. Zero-Byte Empty File with EOF shutdown
            val sZero = Socket("127.0.0.1", testPort)
            val emptySha = computeSha256(ByteArray(0))
            val zeroReq = "POST /api/drop HTTP/1.1\r\n" +
                    "Host: 127.0.0.1\r\n" +
                    "X-Daylight-Drop-Id: zero-tx-5\r\n" +
                    "X-Daylight-Drop-Type: file\r\n" +
                    "X-Daylight-Drop-Filename: zero.txt\r\n" +
                    "X-Daylight-Drop-Sha256: $emptySha\r\n" +
                    "X-Daylight-Drop-Origin: mac-tester\r\n" +
                    "Content-Length: 0\r\n" +
                    "Connection: close\r\n\r\n"
            sZero.getOutputStream().write(zeroReq.toByteArray())
            sZero.shutdownOutput()
            val respStr = sZero.getInputStream().bufferedReader().readText()
            sZero.close()
            assertTrue(respStr.contains("200 OK"))
            assertTrue(File(tempDir, "zero.txt").exists())
            assertEquals(0L, File(tempDir, "zero.txt").length())

        } finally {
            server.stop()
            tempDir.deleteRecursively()
        }
    }
}
