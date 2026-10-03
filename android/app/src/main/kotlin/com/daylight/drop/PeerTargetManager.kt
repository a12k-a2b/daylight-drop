package com.daylight.drop

import android.content.Context
import com.daylight.drop.transport.AndroidHttpClient
import com.daylight.drop.transport.DropSuccessResponse
import com.daylight.drop.transport.LoopSuppressionEngine
import com.daylight.drop.transport.ProtocolConstants
import com.daylight.drop.transport.TextPayload
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * PeerTargetManager: Singleton coordinating active peer discovery state,
 * target address resolution (Wi-Fi vs USB reverse tunnel fallback),
 * loop suppression engine, and long-lived coroutine scope for ephemeral activities.
 */
object PeerTargetManager {

    val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var localDeviceId: String = "dc1-" + UUID.randomUUID().toString().take(8)
    private var macDeviceId: String = "mac_desktop"
    private var activeHost: String = "127.0.0.1" // Defaults to USB tunnel 127.0.0.1:8765
    private var isMacConnected: Boolean = true   // Optimistic for USB reverse tunnel
    
    var latestReceivedText: String? = null
        set(value) {
            field = value
            if (value != null) {
                onTextUpdated?.invoke(value)
            }
        }
    var onTextUpdated: ((String) -> Unit)? = null
    
    var onTransfersUpdated: (() -> Unit)? = null
    fun notifyTransfersUpdated() {
        onTransfersUpdated?.invoke()
    }

    val loopSuppression by lazy {
        DaylightDropService.instance?.transportManager?.loopSuppression
            ?: LoopSuppressionEngine(localDeviceId = localDeviceId)
    }

    val httpClient by lazy {
        DaylightDropService.instance?.transportManager?.client
            ?: AndroidHttpClient(localDeviceId = localDeviceId)
    }

    fun init(context: Context, deviceId: String? = null) {
        if (!deviceId.isNullOrEmpty()) {
            localDeviceId = deviceId
        }
    }

    fun getLocalDeviceId(): String {
        return DaylightDropService.instance?.transportManager?.deviceId ?: localDeviceId
    }

    fun getMacDeviceId(): String = macDeviceId

    fun setMacDeviceId(id: String) {
        macDeviceId = id
    }

    fun getActiveHost(): String {
        val serviceHost = DaylightDropService.instance?.transportManager?.resolveTargetEndpoint()?.first
        return serviceHost ?: activeHost
    }

    fun setActiveHost(host: String) {
        activeHost = host
    }

    fun getTargetCandidates(): List<Pair<String, Int>> {
        val list = mutableListOf<Pair<String, Int>>()
        val primary = DaylightDropService.instance?.transportManager?.resolveTargetEndpoint()
        if (primary != null) {
            list.add(primary)
        }
        val usbEndpoint = Pair("127.0.0.1", ProtocolConstants.MAC_PORT)
        if (!list.contains(usbEndpoint)) {
            list.add(usbEndpoint)
        }
        if (activeHost.isNotEmpty()) {
            val fallback = Pair(activeHost, ProtocolConstants.MAC_PORT)
            if (!list.contains(fallback)) {
                list.add(fallback)
            }
        }
        return list
    }

    @Throws(IOException::class)
    fun sendTextToMac(payload: TextPayload): String {
        val candidates = getTargetCandidates()
        var lastException: Exception? = null
        for ((host, port) in candidates) {
            try {
                return httpClient.sendText(payload, targetHost = host, targetPort = port)
            } catch (e: Exception) {
                lastException = e
            }
        }
        throw (lastException ?: IOException("No reachable route to Mac"))
    }

    @Throws(IOException::class)
    fun sendDropToMac(
        file: File,
        type: String,
        origin: String = getLocalDeviceId(),
        customFilename: String? = null
    ): DropSuccessResponse {
        val candidates = getTargetCandidates()
        var lastException: Exception? = null
        for ((host, port) in candidates) {
            try {
                return httpClient.sendDrop(
                    file = file,
                    type = type,
                    origin = origin,
                    targetHost = host,
                    targetPort = port,
                    customFilename = customFilename
                )
            } catch (e: Exception) {
                lastException = e
            }
        }
        throw (lastException ?: IOException("No reachable route to Mac"))
    }

    fun isMacAvailable(): Boolean {
        val service = DaylightDropService.instance
        if (service != null) {
            return service.transportManager.activeChannel != null
        }
        return isMacConnected
    }

    fun setMacConnected(connected: Boolean) {
        isMacConnected = connected
    }
}
