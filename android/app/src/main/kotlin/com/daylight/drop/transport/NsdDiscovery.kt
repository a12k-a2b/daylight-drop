package com.daylight.drop.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import java.net.InetAddress
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "DaylightDropNsd"

/**
 * Registers Daylight Drop mDNS service on DC1 using Android NsdManager.
 */
class DaylightNsdAdvertiser(
    private val context: Context,
    val port: Int = ProtocolConstants.ANDROID_PORT,
    val deviceId: String,
    val deviceName: String,
    val ipHint: String = "127.0.0.1"
) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private var registrationListener: NsdManager.RegistrationListener? = null
    val isRegistered = AtomicBoolean(false)

    companion object {
        fun getLocalWifiIpAddress(): String? {
            try {
                val interfaces = java.net.NetworkInterface.getNetworkInterfaces() ?: return null
                for (nif in interfaces) {
                    if (nif.isLoopback || !nif.isUp) continue
                    val addrs = nif.inetAddresses
                    for (addr in addrs) {
                        if (!addr.isLoopbackAddress && addr is java.net.Inet4Address) {
                            val hostAddress = addr.hostAddress
                            if (hostAddress != null && !hostAddress.startsWith("127.")) {
                                return hostAddress
                            }
                        }
                    }
                }
            } catch (_: Exception) {}
            return null
        }
    }

    fun register() {
        if (nsdManager == null || isRegistered.get()) return

        val localIp = getLocalWifiIpAddress() ?: ipHint

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "Daylight DC1 ($deviceId)"
            serviceType = ProtocolConstants.SERVICE_TYPE
            setPort(this@DaylightNsdAdvertiser.port)
            setAttribute("devId", deviceId)
            setAttribute("devName", deviceName)
            setAttribute("devModel", "DC_1")
            setAttribute("role", ProtocolConstants.ROLE_ANDROID)
            setAttribute("port", this@DaylightNsdAdvertiser.port.toString())
            setAttribute("protoVer", ProtocolConstants.PROTOCOL_VERSION)
            setAttribute("ip", localIp)
            setAttribute("dropPath", ProtocolConstants.DROP_ENDPOINT)
            setAttribute("wsPath", ProtocolConstants.WS_ENDPOINT)
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                isRegistered.set(true)
                Log.i(TAG, "Service registered: ${info.serviceName} on port ${info.port}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                isRegistered.set(false)
                Log.e(TAG, "Service registration failed with code: $errorCode")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                isRegistered.set(false)
                Log.i(TAG, "Service unregistered: ${info.serviceName}")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                isRegistered.set(false)
                Log.e(TAG, "Service unregistration failed: $errorCode")
            }
        }

        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (e: Exception) {
            Log.e(TAG, "Error registering service", e)
        }
    }

    fun unregister() {
        if (!isRegistered.get()) return
        registrationListener?.let {
            try {
                nsdManager?.unregisterService(it)
            } catch (e: Exception) {
                Log.e(TAG, "Error unregistering service", e)
            }
        }
        registrationListener = null
        isRegistered.set(false)
    }
}

/**
 * Discovers Daylight Drop peers with MulticastLock and serialized resolve queue.
 */
class DaylightNsdBrowser(
    private val context: Context,
    private val onPeerDiscovered: (DiscoveredPeer) -> Unit,
    private val onPeerLost: (String) -> Unit
) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private var multicastLock: WifiManager.MulticastLock? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    
    val isBrowsing = AtomicBoolean(false)
    private val peers = ConcurrentHashMap<String, DiscoveredPeer>()
    
    // Serialized resolve queue to prevent FAILURE_ALREADY_ACTIVE (error code 3)
    private val resolveQueue = ConcurrentLinkedQueue<NsdServiceInfo>()
    private val isResolving = AtomicBoolean(false)

    fun startBrowsing() {
        if (nsdManager == null || isBrowsing.get()) return

        // Acquire MulticastLock to keep radio from dropping UDP multicast
        try {
            multicastLock = wifiManager?.createMulticastLock("DaylightDropMulticastLock")?.apply {
                setReferenceCounted(true)
                acquire()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Could not acquire MulticastLock", e)
        }

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                isBrowsing.set(true)
                Log.i(TAG, "Discovery started for $regType")
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                Log.d(TAG, "Service found: ${service.serviceName}")
                val sType = service.serviceType
                if (sType.contains("daylightdrop") || sType.contains("daylight-drop")) {
                    enqueueResolve(service)
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                Log.d(TAG, "Service lost: ${service.serviceName}")
                val name = service.serviceName
                var lostId: String? = null
                for ((id, peer) in peers) {
                    if (peer.deviceName == name || id == name) {
                        lostId = id
                        break
                    }
                }
                if (lostId != null) {
                    peers.remove(lostId)
                    onPeerLost(lostId)
                }
            }

            override fun onDiscoveryStopped(serviceType: String) {
                isBrowsing.set(false)
                Log.i(TAG, "Discovery stopped: $serviceType")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                isBrowsing.set(false)
                Log.e(TAG, "Start discovery failed: $errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                isBrowsing.set(false)
                Log.e(TAG, "Stop discovery failed: $errorCode")
            }
        }

        try {
            nsdManager.discoverServices(
                ProtocolConstants.SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error starting discovery", e)
        }
    }

    fun stopBrowsing() {
        if (!isBrowsing.get()) return
        discoveryListener?.let {
            try {
                nsdManager?.stopServiceDiscovery(it)
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping discovery", e)
            }
        }
        discoveryListener = null
        isBrowsing.set(false)
        resolveQueue.clear()
        isResolving.set(false)
        peers.clear()

        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing MulticastLock", e)
        }
        multicastLock = null
    }

    private fun enqueueResolve(service: NsdServiceInfo) {
        resolveQueue.offer(service)
        processNextResolve()
    }

    private fun processNextResolve() {
        if (!isResolving.compareAndSet(false, true)) {
            return
        }

        val service = resolveQueue.poll()
        if (service == null) {
            isResolving.set(false)
            return
        }

        val resolveListener = object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "Resolve failed for ${serviceInfo.serviceName}: code $errorCode")
                isResolving.set(false)
                processNextResolve()
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                try {
                    handleResolvedService(serviceInfo)
                } finally {
                    isResolving.set(false)
                    processNextResolve()
                }
            }
        }

        try {
            nsdManager?.resolveService(service, resolveListener)
        } catch (e: Exception) {
            Log.e(TAG, "Error invoking resolveService", e)
            isResolving.set(false)
            processNextResolve()
        }
    }

    private fun handleResolvedService(info: NsdServiceInfo) {
        val host: InetAddress? = info.host
        val ip = host?.hostAddress ?: ""
        val port = info.port
        val name = info.serviceName

        val attributes = info.attributes
        fun getAttr(key: String): String? {
            val bytes = attributes[key] ?: return null
            return String(bytes, StandardCharsets.UTF_8)
        }

        val devId = getAttr("devId") ?: name
        val devName = getAttr("devName") ?: name
        val devModel = getAttr("devModel") ?: "Mac"
        val role = getAttr("role") ?: ProtocolConstants.ROLE_MAC
        val protoVer = getAttr("protoVer") ?: ProtocolConstants.PROTOCOL_VERSION

        val peer = DiscoveredPeer(
            deviceId = devId,
            deviceName = devName,
            deviceModel = devModel,
            role = role,
            ip = ip,
            port = if (port > 0) port else ProtocolConstants.MAC_PORT,
            protoVer = protoVer
        )

        peers[devId] = peer
        onPeerDiscovered(peer)
    }

    fun getPeers(): List<DiscoveredPeer> = peers.values.toList()
}
