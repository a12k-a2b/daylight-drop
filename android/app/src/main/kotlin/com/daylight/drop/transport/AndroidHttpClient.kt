package com.daylight.drop.transport

import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Outbound HTTP client for Daylight DC1 companion service.
 * Connects to macOS on port 8765 (via Wi-Fi IP or 127.0.0.1:8765 over ADB reverse tunnel).
 */
class AndroidHttpClient(
    val localDeviceId: String,
    private val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()
) {
    // MARK: - Health Check

    @Throws(IOException::class)
    fun checkHealth(
        host: String = "127.0.0.1",
        port: Int = ProtocolConstants.MAC_PORT
    ): HealthResponse {
        val url = "http://$host:$port${ProtocolConstants.HEALTH_ENDPOINT}"
        val request = Request.Builder()
            .url(url)
            .get()
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw IOException("Health check failed with HTTP ${response.code}")
            }
            val body = response.body?.string() ?: throw IOException("Empty response body")
            val json = JSONObject(body)
            return HealthResponse(
                status = json.optString("status", "ok"),
                device_id = json.optString("device_id", ""),
                device_type = json.optString("device_type", "macos"),
                version = json.optString("version", ProtocolConstants.PROTOCOL_VERSION)
            )
        }
    }

    // MARK: - File Drop

    @Throws(IOException::class)
    fun sendDrop(
        file: File,
        type: String = "document",
        origin: String = localDeviceId,
        transferId: String = UUID.randomUUID().toString(),
        targetHost: String = "127.0.0.1",
        targetPort: Int = ProtocolConstants.MAC_PORT
    ): DropSuccessResponse {
        if (!file.exists()) {
            throw IOException("File does not exist: ${file.absolutePath}")
        }

        val sha256 = LoopSuppressionEngine.computeSha256(file.readBytes())
        val filename = file.name
        val requestBody = file.asRequestBody("application/octet-stream".toMediaType())

        val url = "http://$targetHost:$targetPort${ProtocolConstants.DROP_ENDPOINT}"
        val request = Request.Builder()
            .url(url)
            .post(requestBody)
            .header(ProtocolConstants.HEADER_DROP_ID, transferId)
            .header(ProtocolConstants.HEADER_DROP_TYPE, type)
            .header(ProtocolConstants.HEADER_DROP_FILENAME, filename)
            .header(ProtocolConstants.HEADER_DROP_SHA256, sha256)
            .header(ProtocolConstants.HEADER_DROP_ORIGIN, origin)
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            val body = response.body?.string() ?: ""
            if (!response.isSuccessful) {
                if (body.contains("checksum_mismatch")) {
                    throw IOException("Checksum mismatch reported by server: $body")
                }
                throw IOException("Drop failed with HTTP ${response.code}: $body")
            }

            val json = try { JSONObject(body) } catch (_: Exception) { JSONObject() }
            return DropSuccessResponse(
                status = json.optString("status", "ok"),
                received = json.optBoolean("received", true),
                transfer_id = json.optString("transfer_id", transferId),
                sha256 = json.optString("sha256", sha256),
                filename = json.optString("filename", filename),
                bytes = json.optLong("bytes", file.length())
            )
        }
    }

    // MARK: - Text / Prompt

    @Throws(IOException::class)
    fun sendText(
        payload: TextPayload,
        targetHost: String = "127.0.0.1",
        targetPort: Int = ProtocolConstants.MAC_PORT
    ): String {
        val json = JSONObject().apply {
            put("id", payload.id)
            put("type", payload.type)
            put("text", payload.text)
            put("origin", payload.origin)
            put("timestamp", payload.timestamp)
        }

        val requestBody = json.toString().toRequestBody("application/json".toMediaType())
        val url = "http://$targetHost:$targetPort${ProtocolConstants.TEXT_ENDPOINT}"

        val request = Request.Builder()
            .url(url)
            .post(requestBody)
            .header(ProtocolConstants.HEADER_DROP_ORIGIN, payload.origin)
            .build()

        okHttpClient.newCall(request).execute().use { response ->
            val body = response.body?.string() ?: ""
            if (!response.isSuccessful) {
                throw IOException("Text transfer failed with HTTP ${response.code}: $body")
            }
            return body
        }
    }
}
