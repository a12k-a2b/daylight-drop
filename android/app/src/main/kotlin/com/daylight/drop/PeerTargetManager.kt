package com.daylight.drop

import android.content.Context
import com.daylight.drop.transport.AndroidHttpClient
import com.daylight.drop.transport.LoopSuppressionEngine
import com.daylight.drop.transport.ProtocolConstants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
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
