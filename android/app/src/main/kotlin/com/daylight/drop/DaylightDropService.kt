package com.daylight.drop

import android.app.*
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Binder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.daylight.drop.transport.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.UUID

private const val TAG = "DaylightDropService"

/**
 * Primary Android Foreground Service for Daylight Drop on DC1 (Sol:OS).
 * Coordinates network transport, mDNS discovery, MediaStore screenshot monitoring,
 * and inbound file/prompt storage.
 */
class DaylightDropService : Service() {

    companion object {
        const val NOTIFICATION_ID = 8766
        const val CHANNEL_SERVICE = "daylight_drop_service_channel"
        const val CHANNEL_PROMPTS = "daylight_prompts"
        const val CHANNEL_DROPS = "daylight_drops"

        const val ACTION_START = "com.daylight.drop.action.START"
        const val ACTION_STOP = "com.daylight.drop.action.STOP"
        const val ACTION_SYNC_SCREENSHOT = "com.daylight.drop.action.SYNC_SCREENSHOT"
        const val ACTION_COPY_CLIPBOARD = "com.daylight.drop.action.COPY_CLIPBOARD"

        var instance: DaylightDropService? = null
            private set

        fun start(context: Context) {
            val intent = Intent(context, DaylightDropService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, DaylightDropService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        fun acquireWakeLock(timeoutMs: Long = 60_000L) {
            instance?.acquireTransferWakeLock(timeoutMs)
        }

        fun releaseWakeLock() {
            instance?.releaseTransferWakeLock()
        }
    }

    private val binder = LocalBinder()
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var multicastLock: WifiManager.MulticastLock? = null
    private var transferWakeLock: PowerManager.WakeLock? = null

    lateinit var transportManager: AndroidTransportManager
        private set
    lateinit var inboundStorageManager: InboundStorageManager
        private set
    lateinit var mediaStoreObserver: MediaStoreObserver
        private set

    private val _serviceStatus = MutableStateFlow("Starting...")
    val serviceStatus: StateFlow<String> = _serviceStatus.asStateFlow()

    inner class LocalBinder : Binder() {
        fun getService(): DaylightDropService = this@DaylightDropService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.i(TAG, "Creating DaylightDropService on DC1")

        createNotificationChannels()
        startAsForeground("Initializing transport...")

        initLocks()
        initSubsystems()

        // Publish dynamic Direct Share shortcut so Mac appears in system Chooser top row
        DirectShareManager.publishDirectShareTarget(applicationContext)
    }

    private fun initLocks() {
        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifiManager?.createMulticastLock("DaylightDropService:MulticastLock")?.apply {
                setReferenceCounted(false)
                acquire()
            }
            Log.d(TAG, "Acquired WifiManager.MulticastLock")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to acquire MulticastLock", e)
        }

        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            transferWakeLock = powerManager?.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "DaylightDropService:TransferWakeLock"
            )?.apply {
                setReferenceCounted(true)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to initialize WakeLock", e)
        }
    }

    private fun initSubsystems() {
        TransferHistoryManager.init(applicationContext)

        val deviceId = "dc1-" + UUID.randomUUID().toString().substring(0, 8)
        transportManager = AndroidTransportManager(
            context = applicationContext,
            deviceId = deviceId,
            deviceName = "Daylight DC1",
            serverPort = ProtocolConstants.ANDROID_PORT
        )

        inboundStorageManager = InboundStorageManager(
            context = applicationContext,
            loopSuppression = transportManager.loopSuppression,
            incomingDir = File(ProtocolConstants.DEFAULT_ANDROID_INCOMING),
            scope = serviceScope
        )

        mediaStoreObserver = MediaStoreObserver(
            context = applicationContext,
            transportManager = transportManager,
            scope = serviceScope,
            onScreenshotDispatched = { file, hash ->
                Log.i(TAG, "Screenshot dispatched: ${file.name} ($hash)")
                TransferHistoryManager.recordSentItem(file, "screenshot")
                PeerTargetManager.notifyTransfersUpdated()
            }
        )

        // Connect server events to inbound storage manager
        transportManager.server.onDropReceived = { transferId, filename, type, file, sha256 ->
            acquireTransferWakeLock(60_000L)
            try {
                inboundStorageManager.handleFileReceived(transferId, filename, type, file, sha256)
                PeerTargetManager.notifyTransfersUpdated()
            } finally {
                releaseTransferWakeLock()
            }
        }

        transportManager.server.onTextReceived = { payload ->
            inboundStorageManager.handleTextReceived(payload)
            PeerTargetManager.notifyTransfersUpdated()
        }

        transportManager.onChannelChanged = { channel ->
            val statusText = when (channel) {
                AndroidChannelType.USB -> "Connected to Mac via USB (Port 8765/8766)"
                AndroidChannelType.WIFI -> "Connected to Mac via Wi-Fi"
                null -> "Ready for drops (Offline)"
            }
            _serviceStatus.value = statusText
            updateForegroundNotification(statusText)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Received ACTION_STOP")
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SYNC_SCREENSHOT -> {
                Log.d(TAG, "Received ACTION_SYNC_SCREENSHOT trigger")
                mediaStoreObserver.checkForNewScreenshot()
            }
            ACTION_COPY_CLIPBOARD -> {
                val text = intent.getStringExtra("text")
                if (!text.isNullOrEmpty()) {
                    copyToClipboard(text)
                }
            }
            else -> {
                Log.i(TAG, "Starting transport manager and media observer")
                transportManager.start()
                mediaStoreObserver.start()
                _serviceStatus.value = "Ready for drops"
                updateForegroundNotification("Ready for drops")
            }
        }
        return START_STICKY
    }

    private fun copyToClipboard(text: String) {
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = ClipData.newPlainText("Daylight Drop", text)
            cm?.setPrimaryClip(clip)
            Log.d(TAG, "Copied text to clipboard from notification action")
        } catch (e: Exception) {
            Log.e(TAG, "Error copying to clipboard", e)
        }
    }

    fun acquireTransferWakeLock(timeoutMs: Long = 60_000L) {
        try {
            transferWakeLock?.acquire(timeoutMs)
        } catch (e: Exception) {
            Log.w(TAG, "Error acquiring WakeLock", e)
        }
    }

    fun releaseTransferWakeLock() {
        try {
            if (transferWakeLock?.isHeld == true) {
                transferWakeLock?.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing WakeLock", e)
        }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java) ?: return

            // 1. Persistent service channel (LOW)
            val serviceChan = NotificationChannel(
                CHANNEL_SERVICE,
                "Daylight Drop Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Maintains connection and background drop synchronization"
                setShowBadge(false)
            }

            // 2. Heads-up prompt channel (HIGH)
            val promptChan = NotificationChannel(
                CHANNEL_PROMPTS,
                "Daylight Drop Prompts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Displays inbound prompts and clipboard items from Mac"
                enableVibration(true)
                setShowBadge(true)
            }

            // 3. Drop notification channel (DEFAULT)
            val dropChan = NotificationChannel(
                CHANNEL_DROPS,
                "Daylight Drop Transfers",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Informs when new files are saved and indexed"
            }

            nm.createNotificationChannels(listOf(serviceChan, promptChan, dropChan))
        }
    }

    private fun startAsForeground(contentText: String) {
        val notification = buildForegroundNotification(contentText)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildForegroundNotification(contentText: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_SERVICE)
            .setContentTitle("Daylight Drop")
            .setContentText(contentText)
            .setSmallIcon(R.drawable.ic_drop_file)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun updateForegroundNotification(contentText: String) {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.notify(NOTIFICATION_ID, buildForegroundNotification(contentText))
    }

    override fun onDestroy() {
        Log.i(TAG, "Destroying DaylightDropService")
        if (::mediaStoreObserver.isInitialized) {
            mediaStoreObserver.stop()
        }
        if (::transportManager.isInitialized) {
            transportManager.stop()
        }

        try {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing MulticastLock", e)
        }

        try {
            if (transferWakeLock?.isHeld == true) {
                transferWakeLock?.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing WakeLock", e)
        }

        serviceScope.cancel()
        instance = null
        super.onDestroy()
    }
}
