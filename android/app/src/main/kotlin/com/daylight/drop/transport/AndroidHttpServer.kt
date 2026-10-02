package com.daylight.drop.transport

import com.daylight.drop.DaylightDropService
import com.daylight.drop.InboundStorageManager
import com.daylight.drop.PeerTargetManager
import org.json.JSONObject
import java.io.*
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "DaylightDropServer"

private object Log {
    fun d(tag: String, msg: String) { try { android.util.Log.d(tag, msg) } catch (_: Throwable) { println("[$tag] D: $msg") } }
    fun i(tag: String, msg: String) { try { android.util.Log.i(tag, msg) } catch (_: Throwable) { println("[$tag] I: $msg") } }
    fun w(tag: String, msg: String, tr: Throwable? = null) { try { android.util.Log.w(tag, msg, tr) } catch (_: Throwable) { println("[$tag] W: $msg $tr") } }
    fun e(tag: String, msg: String, tr: Throwable? = null) { try { android.util.Log.e(tag, msg, tr) } catch (_: Throwable) { System.err.println("[$tag] E: $msg $tr") } }
}

/**
 * Embedded HTTP & WebSocket Server for Daylight DC1 companion service.
 * Listens on port 8766 by default.
 */
class AndroidHttpServer(
    val port: Int = ProtocolConstants.ANDROID_PORT,
    val deviceId: String,
    var incomingDirectory: File = File(ProtocolConstants.DEFAULT_ANDROID_INCOMING),
    val loopSuppression: LoopSuppressionEngine = LoopSuppressionEngine(deviceId)
) {
    private var serverSocket: ServerSocket? = null
    val isRunning = AtomicBoolean(false)
    private val threadPool = Executors.newCachedThreadPool()
    
    var onDropReceived: ((transferId: String, filename: String, type: String, file: File, sha256: String) -> Unit)? = null
    var onTextReceived: ((TextPayload) -> Unit)? = null
    var onWebSocketMessage: ((String) -> Unit)? = null

    private val activeWsSockets = ConcurrentHashMap<Socket, Boolean>()

    fun start() {
        if (isRunning.get()) return
        if (!incomingDirectory.exists()) {
            incomingDirectory.mkdirs()
        }

        try {
            val ss = ServerSocket(port)
            serverSocket = ss
            isRunning.set(true)
            Log.i(TAG, "AndroidHttpServer started on port $port")

            threadPool.execute {
                while (isRunning.get() && !ss.isClosed) {
                    try {
                        val clientSocket = ss.accept()
                        threadPool.execute {
                            handleClientSocket(clientSocket)
                        }
                    } catch (e: Exception) {
                        if (isRunning.get()) {
                            Log.e(TAG, "Accept error", e)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start server on port $port", e)
            throw e
        }
    }

    fun stop() {
        if (!isRunning.compareAndSet(true, false)) return
        try {
            serverSocket?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing server socket", e)
        }
        serverSocket = null
        for (ws in activeWsSockets.keys) {
            try { ws.close() } catch (_: Exception) {}
        }
        activeWsSockets.clear()
        threadPool.shutdownNow()
        Log.i(TAG, "AndroidHttpServer stopped")
    }

    private fun handleClientSocket(socket: Socket) {
        try {
            val input = BufferedInputStream(socket.getInputStream())
            val output = BufferedOutputStream(socket.getOutputStream())

            // Read request line and headers
            val headers = mutableMapOf<String, String>()
            val requestLine = readLine(input) ?: return
            val requestTokens = requestLine.split(" ")
            if (requestTokens.size < 2) {
                sendResponse(output, 400, "{\"status\":\"error\"}")
                socket.close()
                return
            }

            val method = requestTokens[0].uppercase(Locale.US)
            val path = requestTokens[1]

            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                val colonIdx = line.indexOf(":")
                if (colonIdx > 0) {
                    val key = line.substring(0, colonIdx).trim().lowercase(Locale.US)
                    val value = line.substring(colonIdx + 1).trim()
                    headers[key] = value
                }
            }

            when {
                method == "GET" && path == ProtocolConstants.HEALTH_ENDPOINT -> {
                    handleHealth(output)
                    socket.close()
                }
                method == "GET" && path == ProtocolConstants.WS_ENDPOINT -> {
                    handleWebSocket(socket, input, output, headers)
                }
                method == "POST" && path == ProtocolConstants.TEXT_ENDPOINT -> {
                    val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
                    handleTextPost(input, output, headers, contentLength)
                    socket.close()
                }
                method == "POST" && path == ProtocolConstants.DROP_ENDPOINT -> {
                    val contentLength = headers["content-length"]?.toLongOrNull() ?: 0L
                    handleDropPost(input, output, headers, contentLength)
                    socket.close()
                }
                else -> {
                    sendResponse(output, 404, "{\"status\":\"error\",\"message\":\"Not Found\"}")
                    socket.close()
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error handling client socket", e)
            try { socket.close() } catch (_: Exception) {}
        }
    }

    private fun handleHealth(out: OutputStream) {
        val json = JSONObject().apply {
            put("status", "ok")
            put("device_id", deviceId)
            put("device_type", "daylight")
            put("version", ProtocolConstants.PROTOCOL_VERSION)
        }
        sendResponse(out, 200, json.toString())
    }

    private fun handleTextPost(
        input: InputStream,
        output: OutputStream,
        headers: Map<String, String>,
        contentLength: Int
    ) {
        val bodyBytes = ByteArray(contentLength)
        var totalRead = 0
        while (totalRead < contentLength) {
            val count = input.read(bodyBytes, totalRead, contentLength - totalRead)
            if (count == -1) break
            totalRead += count
        }

        val bodyStr = String(bodyBytes, Charsets.UTF_8)
        val json = try {
            JSONObject(bodyStr)
        } catch (e: Exception) {
            sendResponse(output, 400, "{\"status\":\"error\",\"error\":\"invalid_json\"}")
            return
        }

        val id = json.optString("id", UUID.randomUUID().toString())
        val type = json.optString("type", "prompt")
        val text = json.optString("text", "")
        val origin = json.optString("origin", headers[ProtocolConstants.HEADER_DROP_ORIGIN.lowercase(Locale.US)] ?: "")
        if (origin.isNotEmpty()) {
            PeerTargetManager.setMacDeviceId(origin)
        }
        val timestamp = json.optLong("timestamp", System.currentTimeMillis())

        val payload = TextPayload(id, type, text, origin, timestamp)
        val hash = LoopSuppressionEngine.computeSha256(text)

        if (loopSuppression.shouldSuppressIncoming(origin, hash)) {
            val resp = JSONObject().apply {
                put("status", "ok")
                put("received", false)
                put("suppressed", true)
            }
            sendResponse(output, 200, resp.toString())
            return
        }

        loopSuppression.record(hash)
        onTextReceived?.invoke(payload)

        val resp = JSONObject().apply {
            put("status", "ok")
            put("received", true)
            put("id", id)
        }
        sendResponse(output, 200, resp.toString())
    }

    private fun handleDropPost(
        input: InputStream,
        output: OutputStream,
        headers: Map<String, String>,
        contentLength: Long
    ) {
        DaylightDropService.acquireWakeLock(60_000L)
        try {
            val transferId = headers[ProtocolConstants.HEADER_DROP_ID.lowercase(Locale.US)] ?: UUID.randomUUID().toString()
            val dropType = headers[ProtocolConstants.HEADER_DROP_TYPE.lowercase(Locale.US)] ?: "file"
            val rawFilename = headers[ProtocolConstants.HEADER_DROP_FILENAME.lowercase(Locale.US)] ?: "dropped_$transferId.bin"
            val filename = File(rawFilename).name
            val expectedSha256 = headers[ProtocolConstants.HEADER_DROP_SHA256.lowercase(Locale.US)]?.lowercase(Locale.US)
            val origin = headers[ProtocolConstants.HEADER_DROP_ORIGIN.lowercase(Locale.US)] ?: ""

            if (origin.isNotEmpty()) {
                PeerTargetManager.setMacDeviceId(origin)
            }

            if (loopSuppression.isOriginSelf(origin)) {
                val resp = JSONObject().apply {
                    put("status", "ok")
                    put("received", false)
                    put("suppressed", true)
                }
                sendResponse(output, 200, resp.toString())
                return
            }

            if (contentLength == 0L) {
                val emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                if (!expectedSha256.isNullOrEmpty() && expectedSha256 != emptyHash) {
                    val errJson = JSONObject().apply {
                        put("status", "error")
                        put("error", "checksum_mismatch")
                        put("message", "Expected $expectedSha256 but computed $emptyHash")
                    }
                    sendResponse(output, 400, errJson.toString())
                    return
                }

                val safeName = InboundStorageManager.sanitizeFilename(filename)
                val tempFile = File(incomingDirectory, "${ProtocolConstants.TEMP_PREFIX}${transferId}_${safeName}${ProtocolConstants.PART_SUFFIX}")
                val finalFile = InboundStorageManager.resolveUniqueDestinationFile(incomingDirectory, safeName)

                if (tempFile.exists()) tempFile.delete()
                tempFile.createNewFile()

                if (!tempFile.renameTo(finalFile)) {
                    try {
                        Files.move(tempFile.toPath(), finalFile.toPath(), StandardCopyOption.ATOMIC_MOVE)
                    } catch (e: Exception) {
                        tempFile.delete()
                        sendResponse(output, 500, "{\"status\":\"error\",\"message\":\"Failed to rename temp file: ${e.message}\"}")
                        return
                    }
                }

                loopSuppression.record(emptyHash)
                onDropReceived?.invoke(transferId, finalFile.name, dropType, finalFile, emptyHash)

                val successJson = JSONObject().apply {
                    put("status", "ok")
                    put("received", true)
                    put("transfer_id", transferId)
                    put("sha256", emptyHash)
                    put("filename", finalFile.name)
                    put("bytes", 0L)
                }
                sendResponse(output, 200, successJson.toString())
                return
            }

            val safeName = InboundStorageManager.sanitizeFilename(filename)
            val tempFile = File(incomingDirectory, "${ProtocolConstants.TEMP_PREFIX}${transferId}_${safeName}${ProtocolConstants.PART_SUFFIX}")

            if (tempFile.exists()) tempFile.delete()

            val digest = MessageDigest.getInstance("SHA-256")
            var bytesWritten = 0L

            try {
                FileOutputStream(tempFile).use { fos ->
                    val buffer = ByteArray(64 * 1024)
                    var read: Int
                    while (bytesWritten < contentLength || contentLength < 0) {
                        val toRead = if (contentLength > 0) {
                            minOf(buffer.size.toLong(), contentLength - bytesWritten).toInt()
                        } else buffer.size

                        read = input.read(buffer, 0, toRead)
                        if (read == -1) break
                        fos.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        bytesWritten += read

                        if (contentLength > 0 && bytesWritten >= contentLength) break
                    }
                    fos.fd.sync()
                }
            } catch (e: Exception) {
                tempFile.delete()
                sendResponse(output, 500, "{\"status\":\"error\",\"message\":\"Failed to write stream: ${e.message}\"}")
                return
            }

            // Premature EOF verification
            if (contentLength > 0 && bytesWritten < contentLength) {
                tempFile.delete()
                sendResponse(output, 400, "{\"status\":\"error\",\"message\":\"Premature EOF: expected $contentLength bytes but received $bytesWritten\"}")
                return
            }

            val computedHash = digest.digest().joinToString("") { "%02x".format(it) }

            if (!expectedSha256.isNullOrEmpty() && computedHash != expectedSha256) {
                tempFile.delete()
                val errJson = JSONObject().apply {
                    put("status", "error")
                    put("error", "checksum_mismatch")
                    put("message", "Expected $expectedSha256 but computed $computedHash")
                }
                sendResponse(output, 400, errJson.toString())
                return
            }

            val finalFile = InboundStorageManager.resolveUniqueDestinationFile(incomingDirectory, safeName)
            if (!tempFile.renameTo(finalFile)) {
                try {
                    Files.move(tempFile.toPath(), finalFile.toPath(), StandardCopyOption.ATOMIC_MOVE)
                } catch (e: Exception) {
                    tempFile.delete()
                    sendResponse(output, 500, "{\"status\":\"error\",\"message\":\"Failed to rename temp file: ${e.message}\"}")
                    return
                }
            }

            loopSuppression.record(computedHash)
            onDropReceived?.invoke(transferId, finalFile.name, dropType, finalFile, computedHash)

            val successJson = JSONObject().apply {
                put("status", "ok")
                put("received", true)
                put("transfer_id", transferId)
                put("sha256", computedHash)
                put("filename", finalFile.name)
                put("bytes", bytesWritten)
            }
            sendResponse(output, 200, successJson.toString())
        } finally {
            DaylightDropService.releaseWakeLock()
        }
    }

    private fun handleWebSocket(
        socket: Socket,
        input: InputStream,
        output: OutputStream,
        headers: Map<String, String>
    ) {
        val secKey = headers["sec-websocket-key"] ?: run {
            sendResponse(output, 400, "Missing Sec-WebSocket-Key")
            socket.close()
            return
        }

        val magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        val combined = secKey + magicGUID
        val sha1 = MessageDigest.getInstance("SHA-1").digest(combined.toByteArray(Charsets.UTF_8))
        val acceptKey = Base64.getEncoder().encodeToString(sha1)

        val handshake = "HTTP/1.1 101 Switching Protocols\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: Upgrade\r\n" +
                "Sec-WebSocket-Accept: $acceptKey\r\n\r\n"
        output.write(handshake.toByteArray(Charsets.UTF_8))
        output.flush()

        activeWsSockets[socket] = true

        threadPool.execute {
            try {
                while (isRunning.get() && !socket.isClosed) {
                    val b1 = input.read()
                    if (b1 == -1) break
                    val b2 = input.read()
                    if (b2 == -1) break

                    val opcode = b1 and 0x0F
                    val isMasked = (b2 and 0x80) != 0
                    var payloadLen = (b2 and 0x7F)

                    if (payloadLen == 126) {
                        val hi = input.read()
                        val lo = input.read()
                        payloadLen = (hi shl 8) or lo
                    } else if (payloadLen == 127) {
                        // Skip high 4 bytes for large frame length
                        for (i in 0 until 4) input.read()
                        var len = 0
                        for (i in 0 until 4) len = (len shl 8) or input.read()
                        payloadLen = len
                    }

                    val maskKey = ByteArray(4)
                    if (isMasked) {
                        var mRead = 0
                        while (mRead < 4) {
                            val r = input.read(maskKey, mRead, 4 - mRead)
                            if (r == -1) break
                            mRead += r
                        }
                    }

                    val payloadBytes = ByteArray(payloadLen)
                    var pRead = 0
                    while (pRead < payloadLen) {
                        val r = input.read(payloadBytes, pRead, payloadLen - pRead)
                        if (r == -1) break
                        pRead += r
                    }

                    if (isMasked) {
                        for (i in 0 until payloadLen) {
                            payloadBytes[i] = (payloadBytes[i].toInt() xor maskKey[i % 4].toInt()).toByte()
                        }
                    }

                    when (opcode) {
                        0x01 -> { // Text
                            val text = String(payloadBytes, Charsets.UTF_8)
                            onWebSocketMessage?.invoke(text)
                        }
                        0x09 -> { // Ping -> send Pong
                            sendWebSocketFrame(output, 0x0A, payloadBytes)
                        }
                        0x08 -> { // Close
                            break
                        }
                    }
                }
            } catch (_: Exception) {
            } finally {
                activeWsSockets.remove(socket)
                try { socket.close() } catch (_: Exception) {}
            }
        }
    }

    fun broadcastWebSocketMessage(text: String) {
        val data = text.toByteArray(Charsets.UTF_8)
        for (sock in activeWsSockets.keys) {
            try {
                sendWebSocketFrame(sock.getOutputStream(), 0x01, data)
            } catch (_: Exception) {
                activeWsSockets.remove(sock)
            }
        }
    }

    private fun sendWebSocketFrame(out: OutputStream, opcode: Int, payload: ByteArray) {
        out.write(0x80 or (opcode and 0x0F))
        val len = payload.size
        when {
            len <= 125 -> {
                out.write(len)
            }
            len <= 65535 -> {
                out.write(126)
                out.write((len ushr 8) and 0xFF)
                out.write(len and 0xFF)
            }
            else -> {
                out.write(127)
                for (i in 7 downTo 0) {
                    out.write((len ushr (i * 8)) and 0xFF)
                }
            }
        }
        out.write(payload)
        out.flush()
    }

    private fun readLine(input: InputStream): String? {
        val baos = ByteArrayOutputStream()
        while (true) {
            val b = input.read()
            if (b == -1) {
                if (baos.size() == 0) return null
                break
            }
            if (b == '\n'.code) break
            if (b != '\r'.code) baos.write(b)
        }
        return baos.toString(Charsets.UTF_8.name())
    }

    private fun sendResponse(output: OutputStream, statusCode: Int, body: String) {
        val statusText = when (statusCode) {
            200 -> "OK"
            400 -> "Bad Request"
            404 -> "Not Found"
            500 -> "Internal Server Error"
            else -> "HTTP"
        }
        val bodyBytes = body.toByteArray(Charsets.UTF_8)
        val header = "HTTP/1.1 $statusCode $statusText\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: ${bodyBytes.size}\r\n" +
                "Connection: close\r\n\r\n"
        output.write(header.toByteArray(Charsets.UTF_8))
        output.write(bodyBytes)
        output.flush()
    }
}
