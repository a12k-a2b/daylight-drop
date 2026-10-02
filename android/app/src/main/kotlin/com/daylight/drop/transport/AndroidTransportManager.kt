package com.daylight.drop.transport

import android.content.Context
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

enum class AndroidChannelType(val description: String) {
    USB("USB (ADB Tunnel)"),
    WIFI("Wi-Fi (mDNS)")
}

/**
 * Unified Transport Manager for Android companion service on Daylight DC1.
 */
class AndroidTransportManager(
    val context: Context,
    val deviceId: String = "dc1-" + UUID.randomUUID().toString().substring(0, 8),
    val deviceName: String = "Daylight DC1",
    serverPort: Int = ProtocolConstants.ANDROID_PORT,
    incomingDir: File = File(ProtocolConstants.DEFAULT_ANDROID_INCOMING)
) {
    val loopSuppression = LoopSuppressionEngine(deviceId)
    val server = AndroidHttpServer(
        port = serverPort,
        deviceId = deviceId,
        incomingDirectory = incomingDir,
        loopSuppression = loopSuppression
    )
    val client = AndroidHttpClient(localDeviceId = deviceId)
    val advertiser = DaylightNsdAdvertiser(
        context = context,
        port = serverPort,
        deviceId = deviceId,
        deviceName = deviceName
    )
    
    private var activeWifiPeer: DiscoveredPeer? = null
    private val isUsbHealthy = AtomicBoolean(false)
    val isRunning = AtomicBoolean(false)

    var onChannelChanged: ((AndroidChannelType?) -> Unit)? = null
    var onPeerDiscovered: ((DiscoveredPeer) -> Unit)? = null
    var onFileReceived: ((transferId: String, filename: String, type: String, file: File, sha256: String) -> Unit)? = null
    var onTextReceived: ((TextPayload) -> Unit)? = null

    val browser = DaylightNsdBrowser(
        context = context,
        onPeerDiscovered = { peer ->
            if (peer.role == ProtocolConstants.ROLE_MAC || peer.deviceName.contains("Mac")) {
                activeWifiPeer = peer
            }
            onPeerDiscovered?.invoke(peer)
            updateActiveChannel()
        },
        onPeerLost = { peerId ->
            if (activeWifiPeer?.deviceId == peerId) {
                activeWifiPeer = null
            }
            updateActiveChannel()
        }
    )

    init {
        server.onDropReceived = { transferId, filename, type, file, sha256 ->
            onFileReceived?.invoke(transferId, filename, type, file, sha256)
        }
        server.onTextReceived = { payload ->
            onTextReceived?.invoke(payload)
        }
    }

    fun start() {
        if (!isRunning.compareAndSet(false, true)) return
        server.start()
        advertiser.register()
        browser.startBrowsing()
        probeUsbHealth()
    }

    fun stop() {
        if (!isRunning.compareAndSet(true, false)) return
        server.stop()
        advertiser.unregister()
        browser.stopBrowsing()
        isUsbHealthy.set(false)
        activeWifiPeer = null
        onChannelChanged?.invoke(null)
    }

    fun probeUsbHealth() {
        Thread {
            try {
                val health = client.checkHealth(host = "127.0.0.1", port = ProtocolConstants.MAC_PORT)
                if (health.status == "ok") {
                    isUsbHealthy.set(true)
                } else {
                    isUsbHealthy.set(false)
                }
            } catch (_: Exception) {
                isUsbHealthy.set(false)
            }
            updateActiveChannel()
        }.start()
    }

    val activeChannel: AndroidChannelType?
        get() {
            if (isUsbHealthy.get()) return AndroidChannelType.USB
            if (activeWifiPeer != null) return AndroidChannelType.WIFI
            return null
        }

    private fun updateActiveChannel() {
        onChannelChanged?.invoke(activeChannel)
    }

    fun resolveTargetEndpoint(): Pair<String, Int>? {
        if (isUsbHealthy.get()) {
            return Pair("127.0.0.1", ProtocolConstants.MAC_PORT)
        }
        try {
            val health = client.checkHealth(host = "127.0.0.1", port = ProtocolConstants.MAC_PORT)
            if (health.status == "ok") {
                isUsbHealthy.set(true)
                updateActiveChannel()
                return Pair("127.0.0.1", ProtocolConstants.MAC_PORT)
            }
        } catch (e: Exception) {
            android.util.Log.w("AndroidTransportMgr", "USB probe failed: ${e.message}", e)
        }
        val peer = activeWifiPeer
        if (peer != null && peer.ip.isNotEmpty()) {
            return Pair(peer.ip, peer.port)
        }
        return null
    }

    @Throws(Exception::class)
    fun sendFile(file: File, type: String = "document"): DropSuccessResponse {
        val endpoint = resolveTargetEndpoint() ?: throw IllegalStateException("No reachable peer via USB or Wi-Fi")
        return client.sendDrop(
            file = file,
            type = type,
            origin = deviceId,
            targetHost = endpoint.first,
            targetPort = endpoint.second
        )
    }

    @Throws(Exception::class)
    fun sendText(text: String, type: String = "clipboard"): String {
        val endpoint = resolveTargetEndpoint() ?: throw IllegalStateException("No reachable peer via USB or Wi-Fi")
        val payload = TextPayload(
            type = type,
            text = text,
            origin = deviceId
        )
        loopSuppression.recordText(text)
        return client.sendText(
            payload = payload,
            targetHost = endpoint.first,
            targetPort = endpoint.second
        )
    }
}
