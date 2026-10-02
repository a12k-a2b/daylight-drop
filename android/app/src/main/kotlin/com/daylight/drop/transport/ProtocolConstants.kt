package com.daylight.drop.transport

import java.util.UUID

object ProtocolConstants {
    const val PROTOCOL_VERSION = "1.0"

    // Ports
    const val MAC_PORT = 8765
    const val ANDROID_PORT = 8766
    const val ADB_DAEMON_PORT = 5037

    // Service Discovery
    const val SERVICE_TYPE = "_daylightdrop._tcp."
    const val SERVICE_TYPE_NO_DOT = "_daylightdrop._tcp"
    const val LEGACY_SERVICE_TYPE = "_daylight-drop._tcp."
    const val DOMAIN = "local."

    // Endpoints
    const val HEALTH_ENDPOINT = "/api/health"
    const val DROP_ENDPOINT = "/api/drop"
    const val TEXT_ENDPOINT = "/api/text"
    const val WS_ENDPOINT = "/api/ws"

    // Headers
    const val HEADER_DROP_ID = "X-Daylight-Drop-Id"
    const val HEADER_DROP_TYPE = "X-Daylight-Drop-Type"
    const val HEADER_DROP_FILENAME = "X-Daylight-Drop-Filename"
    const val HEADER_DROP_SHA256 = "X-Daylight-Drop-Sha256"
    const val HEADER_DROP_ORIGIN = "X-Daylight-Drop-Origin"

    // Loop Suppression Tags
    const val ORIGIN_TAG = "com.daylight.drop.origin"
    const val TRANSFER_ID_TAG = "com.daylight.drop.transferId"
    const val DEFAULT_LRU_CAPACITY = 256
    const val DEFAULT_TTL_MS = 60_000L

    // Roles
    const val ROLE_MAC = "mac_desktop"
    const val ROLE_ANDROID = "dc1_tablet"

    // Staging
    const val DEFAULT_ANDROID_INCOMING = "/sdcard/Download/DaylightDrop"
    const val TEMP_PREFIX = ".tmp_"
    const val PART_SUFFIX = ".part"
}

data class HealthResponse(
    val status: String = "ok",
    val device_id: String,
    val device_type: String = "daylight",
    val version: String = ProtocolConstants.PROTOCOL_VERSION
)

data class TextPayload(
    val id: String = UUID.randomUUID().toString(),
    val type: String = "prompt", // "prompt" | "clipboard"
    val text: String,
    val origin: String,
    val timestamp: Long = System.currentTimeMillis()
)

data class DropSuccessResponse(
    val status: String = "ok",
    val received: Boolean = true,
    val transfer_id: String,
    val sha256: String,
    val filename: String,
    val bytes: Long
)

data class DropErrorResponse(
    val status: String = "error",
    val error: String,
    val message: String
)

data class DiscoveredPeer(
    val deviceId: String,
    val deviceName: String,
    val deviceModel: String = "DC_1",
    val role: String = "unknown",
    val ip: String,
    val port: Int = ProtocolConstants.MAC_PORT,
    val protoVer: String = ProtocolConstants.PROTOCOL_VERSION,
    val lastSeen: Long = System.currentTimeMillis()
)
