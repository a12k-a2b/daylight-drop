package com.daylight.drop

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.util.Log
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.daylight.drop.transport.AndroidChannelType
import com.daylight.drop.transport.ProtocolConstants
import java.io.File

private const val TAG = "DaylightDropMain"

/**
 * MainActivity: Companion Dashboard for Daylight Drop on DC1 (Sol:OS).
 * Renders on the Sharp NT36523N LivePaper Reflective LCD at 60Hz-120Hz native refresh rate.
 *
 * Adheres strictly to Sol:OS 8-bit monochromatic grayscale tokens:
 * - Canvas background: @color/os_0 (#FFFFFF)
 * - Elevated cards: @color/os_50 (#F7F7F7) with 1px @color/os_100 (#DCD5C9) hairline borders
 * - Primary text ink: @color/os_900 (#1A1A1A) - 17.40:1 contrast ratio (WCAG AAA)
 * - Secondary text ink: @color/os_400 (#535353) - 7.69:1 contrast ratio (WCAG AAA)
 *
 * ZERO-EPD Invariant:
 * Standard HWUI hardware accelerated rendering. Never broadcasts ACTION_REFRESH_SCREEN
 * or invokes waveform screen-clear routines.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvStatusBadge: TextView
    private lateinit var tvActiveRoute: TextView
    private lateinit var tvTargetEndpoint: TextView
    private lateinit var tvThroughput: TextView
    private lateinit var tvRecentItems: TextView
    private lateinit var btnBeamClipboard: Button
    private lateinit var btnOpenStorage: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        // Initialize PeerTargetManager
        PeerTargetManager.init(applicationContext)

        // Ensure foreground companion service is running
        DaylightDropService.start(this)

        // Ensure Direct Share target is registered for system Chooser
        DirectShareManager.publishDirectShareTarget(this)

        initViews()
        setupListeners()
        requestPermissionsIfNeeded()
    }

    private fun requestPermissionsIfNeeded() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            val permissions = mutableListOf<String>()
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                permissions.add(android.Manifest.permission.POST_NOTIFICATIONS)
            }
            if (checkSelfPermission(android.Manifest.permission.READ_MEDIA_IMAGES) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                permissions.add(android.Manifest.permission.READ_MEDIA_IMAGES)
            }
            if (permissions.isNotEmpty()) {
                requestPermissions(permissions.toTypedArray(), 1001)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        updateDashboardState()
        refreshRecentDrops()
    }

    private fun initViews() {
        tvStatusBadge = findViewById(R.id.tvStatusBadge)
        tvActiveRoute = findViewById(R.id.tvActiveRoute)
        tvTargetEndpoint = findViewById(R.id.tvTargetEndpoint)
        tvThroughput = findViewById(R.id.tvThroughput)
        tvRecentItems = findViewById(R.id.tvRecentItems)
        btnBeamClipboard = findViewById(R.id.btnBeamClipboard)
        btnOpenStorage = findViewById(R.id.btnOpenStorage)
    }

    private fun setupListeners() {
        btnBeamClipboard.setOnClickListener {
            Log.i(TAG, "Beam Clipboard clicked")
            val intent = Intent(this, BeamTrampolineActivity::class.java).apply {
                putExtra(BeamTrampolineActivity.EXTRA_TRIGGER_SOURCE, "dashboard_button")
            }
            startActivity(intent)
        }

        btnOpenStorage.setOnClickListener {
            Log.i(TAG, "Open Storage clicked")
            openStorageDirectory()
        }
    }

    fun updateDashboardState() {
        val service = DaylightDropService.instance
        val channel = service?.transportManager?.activeChannel

        when (channel) {
            AndroidChannelType.USB -> {
                tvStatusBadge.text = "USB ACTIVE"
                tvStatusBadge.setBackgroundColor(getColor(R.color.os_900))
                tvActiveRoute.text = getString(R.string.status_connected_usb)
                tvTargetEndpoint.text = "Target: 127.0.0.1:${ProtocolConstants.MAC_PORT} (ADB Reverse) | Local: :${ProtocolConstants.ANDROID_PORT}"
                tvThroughput.text = "Speed: 31+ MB/s (USB-C Offline Tunnel) | Ping: <1ms"
            }
            AndroidChannelType.WIFI -> {
                tvStatusBadge.text = "WI-FI ACTIVE"
                tvStatusBadge.setBackgroundColor(getColor(R.color.os_900))
                tvActiveRoute.text = getString(R.string.status_connected_wifi)
                val endpoint = service.transportManager.resolveTargetEndpoint()
                val target = endpoint?.let { "${it.first}:${it.second}" } ?: "mDNS searching"
                tvTargetEndpoint.text = "Target: $target (mDNS) | Local: :${ProtocolConstants.ANDROID_PORT}"
                tvThroughput.text = "Local 802.11ac Subnet P2P Streaming | Ping: ~4ms"
            }
            null -> {
                tvStatusBadge.text = "READY"
                tvStatusBadge.setBackgroundColor(getColor(R.color.os_400))
                tvActiveRoute.text = getString(R.string.status_offline)
                tvTargetEndpoint.text = "Listening on 0.0.0.0:${ProtocolConstants.ANDROID_PORT} (Awaiting Mac Connection)"
                tvThroughput.text = "Plug in USB-C or connect to same Wi-Fi subnet"
            }
        }
    }

    fun refreshRecentDrops() {
        val incomingDir = File(ProtocolConstants.DEFAULT_ANDROID_INCOMING)
        if (!incomingDir.exists()) {
            incomingDir.mkdirs()
        }

        val files = incomingDir.listFiles()?.filter {
            !it.name.startsWith(ProtocolConstants.TEMP_PREFIX) && !it.name.endsWith(ProtocolConstants.PART_SUFFIX)
        }?.sortedByDescending { it.lastModified() }?.take(5)

        if (files.isNullOrEmpty()) {
            tvRecentItems.text = "No transfers recorded yet."
        } else {
            val sb = StringBuilder()
            for (f in files) {
                sb.append("• ").append(f.name).append(" (").append(formatBytes(f.length())).append(")\n")
            }
            tvRecentItems.text = sb.toString().trimEnd()
        }
    }

    private fun openStorageDirectory() {
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(Uri.parse(ProtocolConstants.DEFAULT_ANDROID_INCOMING), "resource/folder")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Folder view intent failed, opening standard storage intent", e)
            try {
                val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                    type = "*/*"
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                }
                startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "Failed to launch file picker", e2)
            }
        }
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return "%.1f KB".format(kb)
        val mb = kb / 1024.0
        return "%.1f MB".format(mb)
    }
}
